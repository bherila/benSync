import Foundation
import Darwin

public struct SSHProfile: Codable, Identifiable, Equatable, Sendable {
    public var alias: String
    public var source: String
    public var id: String { alias }
    public init(alias: String, source: String) { self.alias = alias; self.source = source }
}

/// Discover literal aliases only. OpenSSH itself resolves Host/Match semantics
/// when connecting; discovery never evaluates Match exec or runs a shell.
public enum SSHProfiles {
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                systemConfig: URL = URL(fileURLWithPath: "/etc/ssh/ssh_config")) throws -> [SSHProfile] {
        var visited = Set<String>(), profiles = [SSHProfile](), names = Set<String>()
        let userBase = home.appendingPathComponent(".ssh")
        func read(_ url: URL, depth: Int, base: URL) throws {
            guard depth < 32 else { throw BackendError(.invalid, "SSH Include nesting exceeds 32 levels.") }
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard visited.insert(key).inserted else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let contents = try String(contentsOf: url, encoding: .utf8)
            for line in contents.components(separatedBy: .newlines) {
                let tokens = tokenize(line)
                guard let first = tokens.first else { continue }
                let values = Array(tokens.dropFirst())
                switch first.lowercased() {
                case "host":
                    for alias in values where !alias.isEmpty && !alias.hasPrefix("-") && !alias.contains(where: { "*?![]".contains($0) || $0.isWhitespace }) {
                        if names.insert(alias).inserted { profiles.append(.init(alias: alias, source: url.path)) }
                    }
                case "include":
                    for value in values {
                        let expanded = value.hasPrefix("~/") ? home.appendingPathComponent(String(value.dropFirst(2))).path : value
                        let pattern = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
                        var matches = glob_t()
                        let result = glob(pattern, GLOB_TILDE, nil, &matches)
                        defer { globfree(&matches) }
                        if result == 0, let paths = matches.gl_pathv {
                            for i in 0..<Int(matches.gl_pathc) {
                                if let path = paths[i] { try read(URL(fileURLWithPath: String(cString: path)), depth: depth + 1, base: base) }
                            }
                        }
                    }
                default: break
                }
            }
        }
        try read(userBase.appendingPathComponent("config"), depth: 0, base: userBase)
        try read(systemConfig, depth: 0, base: URL(fileURLWithPath: "/etc/ssh"))
        return profiles.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    static func tokenize(_ line: String) -> [String] {
        var result = [String](), token = "", quote: Character?, escaped = false
        for character in line {
            if escaped { token.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let q = quote { if character == q { quote = nil } else { token.append(character) }; continue }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "#" { break }
            if character.isWhitespace || (character == "=" && (result.isEmpty || (result.count == 1 && token.isEmpty))) {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(character) }
        }
        if !token.isEmpty { result.append(token) }
        return result
    }
}
