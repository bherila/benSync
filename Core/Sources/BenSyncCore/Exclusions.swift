import Foundation
import Darwin

/// Directory exclusions only. A bare glob matches a directory at any depth;
/// a pattern containing '/' matches a root-relative directory path.
public struct Exclusions: Sendable {
    public let patterns: [String]
    public init(_ patterns: [String]) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
    }
    public func validate() throws {
        guard patterns.allSatisfy({ !$0.contains("\0") && !$0.split(separator: "/").contains("..") }) else {
            throw BackendError(.invalid, "Exclusions must be directory names or relative glob patterns without '..'.")
        }
    }
    public func excludes(_ path: String, kind: NodeKind) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let directories = kind == .directory ? parts : Array(parts.dropLast())
        var prefix = ""
        for component in directories {
            prefix = RemotePath.append(prefix, component)
            for pattern in patterns {
                let value = pattern.contains("/") ? prefix : component
                if fnmatch(pattern, value, FNM_PATHNAME) == 0 { return true }
            }
        }
        return false
    }
}
