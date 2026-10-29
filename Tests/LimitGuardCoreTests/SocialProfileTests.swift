import Foundation
import Testing
@testable import LimitGuardCore

struct SocialProfileTests {
    @Test func hasSixteenProfiles() {
        #expect(SocialProfile.all.count == 16)
    }

    @Test func urlsAreHTTPSWithAHost() {
        for profile in SocialProfile.all {
            #expect(profile.url.scheme == "https", "\(profile.name)")
            #expect(profile.url.host?.isEmpty == false, "\(profile.name)")
        }
    }

    @Test func idsNamesAndURLsAreUnique() {
        let all = SocialProfile.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        #expect(Set(all.map(\.url)).count == all.count)
    }
}
