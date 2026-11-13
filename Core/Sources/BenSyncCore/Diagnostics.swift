import Foundation
import CSQLite

public enum DiagnosticOperation: String, Codable, Sendable { case scan, download, create, modify, delete }

/// Deliberately no destination identifier, free text, URL, path, or filename.
/// Neither exported diagnostics nor persisted metrics can accept those fields.
public struct DiagnosticEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let recordedAt: Date
    public let operation: DiagnosticOperation
    public let errorKind: BackendError.Kind?
    public let durationMilliseconds: Double
    public let transferredBytes: Int64
    public let itemCount: Int?
    public init(operation: DiagnosticOperation, errorKind: BackendError.Kind? = nil, durationMilliseconds: Double,
                transferredBytes: Int64 = 0, itemCount: Int? = nil, recordedAt: Date = Date()) {
        id = UUID(); self.recordedAt = recordedAt; self.operation = operation; self.errorKind = errorKind
        self.durationMilliseconds = durationMilliseconds; self.transferredBytes = transferredBytes; self.itemCount = itemCount
    }
}

public struct DiagnosticTotals: Codable, Sendable {
    public var operationCount: Int64 = 0
    public var errorCount: Int64 = 0
    public var uploadedBytes: Int64 = 0
    public var downloadedBytes: Int64 = 0
    public var totalDurationMilliseconds: Double = 0
}
public struct DiagnosticsSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let recordedAt: Date
    public let isEnabled: Bool
    public let totals: DiagnosticTotals
    public let recent: [DiagnosticEvent]
}

/// Bounded local operational metrics; never network telemetry. WAL records
/// small operation summaries instead of repeatedly rewriting a large log file.
public final class DiagnosticsStore {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); throw BackendError(.internalError, "Cannot open local diagnostics.")
        }
        sqlite3_busy_timeout(db, 10_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL, totals BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL)")
        try execute("INSERT OR IGNORE INTO settings(id,enabled,totals) VALUES (1,1,?)", data: JSONEncoder().encode(DiagnosticTotals()))
    }
    deinit { sqlite3_close(db) }
    private func statement<T>(_ sql: String, data: Data? = nil, read: (OpaquePointer) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw databaseError() }
        defer { sqlite3_finalize(stmt) }
        if let data {
            let bound = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard bound == SQLITE_OK else { throw databaseError() }
        }
        var values = [T]()
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw databaseError() }
            values.append(try read(stmt))
        }
    }
    private func execute(_ sql: String, data: Data? = nil) throws { _ = try statement(sql, data: data) { _ in () } }
    private func databaseError() -> BackendError { BackendError(.internalError, "Cannot update local diagnostics.") }
    private func decoded<T: Decodable>(_ type: T.Type, _ stmt: OpaquePointer, column: Int32 = 0) throws -> T {
        guard let pointer = sqlite3_column_blob(stmt, column) else { throw databaseError() }
        return try JSONDecoder().decode(type, from: Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, column))))
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func snapshot() throws -> DiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        // A read transaction keeps totals and recent events from different
        // processes on the same SQLite snapshot, without taking a writer lock.
        try execute("BEGIN")
        do {
            let result = try statement("SELECT enabled,totals FROM settings WHERE id=1") {
                (sqlite3_column_int($0, 0) != 0, try decoded(DiagnosticTotals.self, $0, column: 1))
            }
            guard let state = result.first else { throw databaseError() }
            let recent = try statement("SELECT payload FROM events ORDER BY seq DESC LIMIT 200") { try decoded(DiagnosticEvent.self, $0) }
            try execute("COMMIT")
            return DiagnosticsSnapshot(schemaVersion: 1, recordedAt: Date(), isEnabled: state.0, totals: state.1, recent: recent)
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func setEnabled(_ enabled: Bool) throws {
        try transaction {
            try execute(enabled ? "UPDATE settings SET enabled=1 WHERE id=1" : "UPDATE settings SET enabled=0 WHERE id=1")
            if !enabled {
                try execute("DELETE FROM events")
                try execute("UPDATE settings SET totals=? WHERE id=1", data: JSONEncoder().encode(DiagnosticTotals()))
            }
        }
    }
    public func record(_ event: DiagnosticEvent) throws {
        guard event.durationMilliseconds.isFinite, event.durationMilliseconds >= 0,
              event.transferredBytes >= 0, (event.itemCount ?? 0) >= 0 else {
            throw BackendError(.invalid, "Invalid diagnostic counters.")
        }
        try transaction {
            let result = try statement("SELECT enabled,totals FROM settings WHERE id=1") {
                (sqlite3_column_int($0, 0) != 0, try decoded(DiagnosticTotals.self, $0, column: 1))
            }
            guard let state = result.first else { throw databaseError() }
            guard state.0 else { return }
            var totals = state.1
            func adding(_ a: Int64, _ b: Int64) -> Int64 { let result = a.addingReportingOverflow(b); return result.overflow ? .max : result.partialValue }
            totals.operationCount = adding(totals.operationCount, 1)
            if event.errorKind != nil && event.errorKind != .cancelled { totals.errorCount = adding(totals.errorCount, 1) }
            if event.operation == .download { totals.downloadedBytes = adding(totals.downloadedBytes, event.transferredBytes) }
            if event.operation == .create || event.operation == .modify { totals.uploadedBytes = adding(totals.uploadedBytes, event.transferredBytes) }
            totals.totalDurationMilliseconds = min(Double.greatestFiniteMagnitude, totals.totalDurationMilliseconds + event.durationMilliseconds)
            try execute("UPDATE settings SET totals=? WHERE id=1", data: JSONEncoder().encode(totals))
            try execute("INSERT INTO events(payload) VALUES (?)", data: JSONEncoder().encode(event))
            try execute("DELETE FROM events WHERE seq <= (SELECT MAX(seq)-200 FROM events)")
        }
    }
}
