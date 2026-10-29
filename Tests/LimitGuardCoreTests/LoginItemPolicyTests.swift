import Foundation
import Testing
@testable import LimitGuardCore

@Suite("LoginItemPolicy")
struct LoginItemPolicyTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    private func sync(_ path: String, debug: Bool = false) -> Bool {
        LoginItemPolicy.shouldSync(bundleURL: URL(fileURLWithPath: path), isDebugBuild: debug, home: home)
    }

    @Test func installedCopiesSync() {
        #expect(sync("/Applications/Cybokron Limit Guard.app"))
        #expect(sync("/Users/test/Applications/Cybokron Limit Guard.app"))
    }

    @Test func otherLocationsDoNot() {
        #expect(!sync("/Users/test/Documents/GitHub/x/build/debug/Cybokron Limit Guard.app"))
        #expect(!sync("/Volumes/Cybokron Limit Guard/Cybokron Limit Guard.app"))
        #expect(!sync("/Users/other/Applications/Cybokron Limit Guard.app"))
        #expect(!sync("/Applications.evil/Cybokron Limit Guard.app"))
        #expect(!sync("/Applications/CybokronLimitGuard"))
    }

    @Test func aDebugBuildNeverSyncs() {
        #expect(!sync("/Applications/Cybokron Limit Guard.app", debug: true))
    }
}
