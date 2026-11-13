import Foundation
import Testing
@testable import BenSyncCore

@Suite("SSH profile discovery")
struct SSHProfilesTests {
    @Test func discoversLiteralAliasesAcrossIncludesWithoutExecutingMatch() throws {
        let temporary = try TemporaryDirectory()
        let marker = temporary.url.appendingPathComponent("must-not-exist")
        try temporary.write(".ssh/config", """
        Host primary secondary
            HostName ignored.example.test
        Include profiles/*.conf "space directory/included config"
        Host *.example.test !excluded -bad wildcard? [abc]
        Match exec "touch \(marker.path)"
            User ignored
        Host="quoted-alias" # trailing comment
        Host = spaced-equals
        Host primary
        """)
        try temporary.write(".ssh/profiles/one.conf", "Host included\nInclude config\n")
        try temporary.write(".ssh/space directory/included config", "hOsT 'space-path-profile'\n")
        try temporary.write("system_config", "Host system-profile\n")
        let profiles = try SSHProfiles.discover(home: temporary.url, systemConfig: temporary.url.appendingPathComponent("system_config"))
        #expect(Set(profiles.map(\.alias)) == ["primary", "secondary", "included", "space-path-profile", "quoted-alias", "spaced-equals", "system-profile"])
        #expect(profiles.filter { $0.alias == "primary" }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(profiles.first { $0.alias == "included" }?.source.hasSuffix("one.conf") == true)
    }

    @Test func tildeIncludesAndCyclesStayBounded() throws {
        let temporary = try TemporaryDirectory()
        try temporary.write(".ssh/config", "Include ~/.ssh/other\nHost local\n")
        try temporary.write(".ssh/other", "Include config\nHost included\n")
        let profiles = try SSHProfiles.discover(home: temporary.url, systemConfig: temporary.url.appendingPathComponent("absent"))
        #expect(Set(profiles.map(\.alias)) == ["local", "included"])
    }

    @Test func missingConfigurationIsAnEmptyList() throws {
        let temporary = try TemporaryDirectory()
        #expect(try SSHProfiles.discover(home: temporary.url, systemConfig: temporary.url.appendingPathComponent("missing")).isEmpty)
    }

    @Test func discoveryDoesNotReadPrivateKeyOrIdentityContents() throws {
        let temporary = try TemporaryDirectory()
        try temporary.write(".ssh/config", "Host fixture\n IdentityFile ~/.ssh/missing-private-key\n ProxyJump jump.example.test\n")
        let profiles = try SSHProfiles.discover(home: temporary.url, systemConfig: temporary.url.appendingPathComponent("missing"))
        #expect(profiles.map(\.alias) == ["fixture"])
    }

    @Test func tokenizationPreservesQuotedCommentCharactersAndEscapedWhitespace() {
        #expect(SSHProfiles.tokenize("Include \"dir#one/file\" dir\\ two/file # comment") == ["Include", "dir#one/file", "dir two/file"])
        #expect(SSHProfiles.tokenize("Host = profile-a profile-b") == ["Host", "profile-a", "profile-b"])
        #expect(SSHProfiles.tokenize("Host=profile-a") == ["Host", "profile-a"])
    }
}

@Suite("Directory exclusion semantics")
struct ExclusionsTests {
    @Test func bareNamesMatchDirectoriesAtAnyDepthAndTheirDescendants() {
        let rules = Exclusions(["node_modules"])
        #expect(rules.excludes("node_modules", kind: .directory))
        #expect(rules.excludes("web/node_modules", kind: .directory))
        #expect(rules.excludes("web/node_modules/pkg/index.js", kind: .file))
        #expect(!rules.excludes("node_modules", kind: .file))
        #expect(!rules.excludes("web/node_modules.txt", kind: .file))
        #expect(!rules.excludes("my_node_modules/file", kind: .file))
    }

    @Test func pathPatternsAreRootRelativeAndRespectDirectoryBoundaries() {
        let rules = Exclusions(["apps/*/cache"])
        #expect(rules.excludes("apps/web/cache", kind: .directory))
        #expect(rules.excludes("apps/web/cache/result.bin", kind: .file))
        #expect(!rules.excludes("nested/apps/web/cache", kind: .directory))
        #expect(!rules.excludes("apps/web/sub/cache", kind: .directory))
    }

    @Test func whitespaceBlankLinesAndTrailingSlashesAreNormalized() throws {
        let rules = Exclusions([" node_modules/ ", "", "  ", ".git/"])
        try rules.validate()
        #expect(rules.patterns == ["node_modules", ".git"])
    }

    @Test func invalidTraversalAndNulPatternsAreRejected() {
        expectBackendError(.invalid) { try Exclusions(["../outside"]).validate() }
        expectBackendError(.invalid) { try Exclusions(["nested/../outside"]).validate() }
        expectBackendError(.invalid) { try Exclusions(["bad\0name"]).validate() }
    }

    @Test func remotePathsRejectTraversalWithoutRejectingUnicodeOrSpaces() throws {
        for name in ["", ".", "..", "a/b", "a\0b"] { expectBackendError(.invalid) { try RemotePath.validateName(name) } }
        try RemotePath.validateName("工程 notes.txt")
        #expect(try RemotePath.absolute(root: "/remote", relative: "folder/工程 notes.txt") == "/remote/folder/工程 notes.txt")
        expectBackendError(.invalid) { _ = try RemotePath.absolute(root: "/remote", relative: "../outside") }
        expectBackendError(.invalid) { _ = try RemotePath.absolute(root: "/remote", relative: "/outside") }
    }
}
