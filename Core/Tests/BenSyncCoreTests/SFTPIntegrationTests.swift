import Foundation
import Testing
@testable import BenSyncCore

private struct SFTPFixture {
    let temporary: TemporaryDirectory
    let remoteURL: URL
    let backend: SFTPBackend
    let root: String
    init() throws {
        let temporary = try TemporaryDirectory()
        let remote = temporary.url.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let backend = SFTPBackend(localServer: URL(fileURLWithPath: "/usr/libexec/sftp-server"))
        self.temporary = temporary; remoteURL = remote; self.backend = backend
        root = try backend.canonicalRoot(remote.path)
    }
    func remote(_ name: String) -> String { RemotePath.append(root, name) }
}

@Suite("System SFTP server integration", .timeLimit(.minutes(2)))
struct SFTPIntegrationTests {
    @Test func streamedUploadAndDownloadCrossManyPipelineWindows() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        let bytes = Data((0..<(2 * 1024 * 1024 + 137)).map { UInt8(truncatingIfNeeded: $0 * 31 + $0 / 251) })
        let source = f.temporary.url.appendingPathComponent("source"), target = f.temporary.url.appendingPathComponent("hydrated")
        try bytes.write(to: source)
        let upload = Progress(totalUnitCount: -1)
        try f.backend.upload(source, to: f.remote("large.bin"), replacing: nil, progress: upload)
        #expect(upload.totalUnitCount == Int64(bytes.count))
        #expect(upload.completedUnitCount == Int64(bytes.count))
        let download = Progress(totalUnitCount: -1)
        try f.backend.download(f.remote("large.bin"), to: target, progress: download)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(download.completedUnitCount == Int64(bytes.count))
        #expect(try f.backend.list(f.root).map(\.name) == ["large.bin"])
    }

    @Test func zeroLengthUnicodeAndNewlineNamesRoundTripWithoutShellParsing() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        let source = try f.temporary.write("empty-source", "")
        let name = "工程 'quoted' $dollar\nline.txt"
        try f.backend.upload(source, to: f.remote(name), replacing: nil, progress: Progress(totalUnitCount: -1))
        let listing = try f.backend.list(f.root)
        #expect(listing.map(\.name) == [name])
        #expect(listing.first?.size == 0)
        let target = f.temporary.url.appendingPathComponent("empty-download")
        try f.backend.download(f.remote(name), to: target, progress: Progress(totalUnitCount: -1))
        #expect(try Data(contentsOf: target).isEmpty)
    }

    @Test func staleReplacementLeavesRemoteAndLocalBytesUntouched() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        let remote = f.remoteURL.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: remote)
        let old = try f.backend.stat(f.remote("notes.txt"))
        try Data("longer remote edit".utf8).write(to: remote)
        let local = try f.temporary.write("local-change", "unsynced local edit")
        expectBackendError(.conflict) {
            try f.backend.upload(local, to: f.remote("notes.txt"), replacing: old.version, progress: Progress(totalUnitCount: -1))
        }
        #expect(try Data(contentsOf: remote) == Data("longer remote edit".utf8))
        #expect(try Data(contentsOf: local) == Data("unsynced local edit".utf8))
        #expect(try f.backend.list(f.root).map(\.name) == ["notes.txt"])
    }

    @Test func atomicReplacementPreservesPermissionsAndLeavesNoTemporaryFile() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        let remote = f.remoteURL.appendingPathComponent("notes.txt")
        try Data("old".utf8).write(to: remote)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: remote.path)
        let before = try f.backend.stat(f.remote("notes.txt"))
        let local = try f.temporary.write("new-source", "replacement bytes")
        try f.backend.upload(local, to: f.remote("notes.txt"), replacing: before.version, progress: Progress(totalUnitCount: -1))
        let after = try f.backend.stat(f.remote("notes.txt"))
        #expect(try Data(contentsOf: remote) == Data("replacement bytes".utf8))
        #expect(after.permissions & 0o777 == 0o640)
        #expect(try f.backend.list(f.root).map(\.name) == ["notes.txt"])
    }

    @Test func newUploadRefusesAnExistingFile() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        let target = f.remoteURL.appendingPathComponent("existing.txt")
        try Data("keep existing".utf8).write(to: target)
        let local = try f.temporary.write("new-source", "incoming")
        expectBackendError(.collision) {
            try f.backend.upload(local, to: f.remote("existing.txt"), replacing: nil, progress: Progress(totalUnitCount: -1))
        }
        #expect(try Data(contentsOf: target) == Data("keep existing".utf8))
    }

    @Test func listingAndHydrationCannotFollowAnEscapingSymlink() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        let outside = try f.temporary.write("outside/secret.txt", "synthetic outside bytes").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: f.remoteURL.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(try f.backend.list(f.root).isEmpty)
        expectBackendError(.permission) { _ = try f.backend.list(f.remote("escape")) }
        expectBackendError(.permission) {
            try f.backend.download(f.remote("escape/secret.txt"), to: f.temporary.url.appendingPathComponent("forbidden-download"), progress: Progress(totalUnitCount: -1))
        }
        let local = try f.temporary.write("incoming", "must not escape")
        expectBackendError(.permission) {
            try f.backend.upload(local, to: f.remote("escape/new.txt"), replacing: nil, progress: Progress(totalUnitCount: -1))
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }

    @Test func directoryMoveAndNonRecursiveRemovalProtectUnexpectedRemoteChildren() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        try f.backend.createDirectory(f.remote("old"))
        let contents = try f.temporary.write("source", "keep")
        try f.backend.upload(contents, to: f.remote("old/file.txt"), replacing: nil, progress: Progress(totalUnitCount: -1))
        try f.backend.move(f.remote("old"), to: f.remote("new"))
        #expect(try f.backend.list(f.remote("new")).map(\.name) == ["file.txt"])
        do { try f.backend.remove(f.remote("new"), kind: .directory); Issue.record("A nonempty directory must not be removed.") }
        catch { #expect(FileManager.default.fileExists(atPath: f.remoteURL.appendingPathComponent("new/file.txt").path)) }
        try f.backend.remove(f.remote("new/file.txt"), kind: .file)
        try f.backend.remove(f.remote("new"), kind: .directory)
        #expect(try f.backend.list(f.root).isEmpty)
    }

    @Test func cancelledTransferDoesNotLeavePartialDownloadedBytes() throws {
        let f = try SFTPFixture(); defer { f.backend.disconnect() }
        let remote = f.remoteURL.appendingPathComponent("large.bin")
        try Data(repeating: 7, count: 128 * 1024).write(to: remote)
        let target = f.temporary.url.appendingPathComponent("cancelled-download")
        let progress = Progress(totalUnitCount: -1); progress.cancel()
        expectBackendError(.cancelled) { try f.backend.download(f.remote("large.bin"), to: target, progress: progress) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
