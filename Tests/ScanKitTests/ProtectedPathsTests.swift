import Testing
@testable import ScanKit

struct ProtectedPathsTests {
    private let rules = ProtectedPaths(home: "/Users/me")

    @Test(arguments: [
        "/", "/System", "/System/Library/Fonts", "/usr", "/usr/lib/dyld", "/bin/ls",
        "/Library", "/Applications", "/Users", "/private/var", "/private/etc/hosts",
        "/Users/me", "/Users/me/Library", "/Users/me/Documents", "/Users/me/Downloads",
        "/Volumes/Backup",
    ])
    func refuses(_ path: String) {
        #expect(rules.refusal(forPath: path) != nil)
    }

    @Test(arguments: [
        "/Applications/Xcode.app", "/Library/Caches", "/usr/local/Cellar", "/Users/other",
        "/Users/me/Library/Caches", "/Users/me/Downloads/big.dmg", "/Users/me/dev",
        "/Volumes/Backup/old", "/private/var/folders", "/opt/homebrew",
    ])
    func allows(_ path: String) {
        #expect(rules.refusal(forPath: path) == nil)
    }

    @Test func appliesTheSameRulesThroughTheDataVolume() {
        #expect(rules.refusal(forPath: "/System/Volumes/Data") != nil)
        #expect(rules.refusal(forPath: "/System/Volumes/Data/Users/me") != nil)
        #expect(rules.refusal(forPath: "/System/Volumes/Data/Library") != nil)
        #expect(rules.refusal(forPath: "/System/Volumes/Data/Users/me/dev") == nil)
        #expect(rules.refusal(forPath: "/System/Volumes/Data/Library/Caches") == nil)
    }
}
