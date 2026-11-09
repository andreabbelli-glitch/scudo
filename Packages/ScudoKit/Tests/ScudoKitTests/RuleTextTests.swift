import Foundation
import Testing
@testable import ScudoKit
import ScudoShared

@Suite("Rule text")
struct RuleTextTests {
    @Test func linesDropCommentsHeadersAndBlanks() {
        let text = """
        [Adblock Plus 2.0]
        ! Title: Test list
        ! Version: 1.2.3

        ||ads.example.com^
          ##.banner  \r
        example.org#@#.sponsor
        """
        #expect(RuleText.lines(of: text) == ["||ads.example.com^", "##.banner", "example.org#@#.sponsor"])
    }

    @Test func metadataIsReadFromHeader() {
        let text = "[Adblock Plus 2.0]\n! Title: AdGuard Base filter\n! Version: 2.3.4.5\n||a.com^\n! Title: not this one"
        let metadata = RuleText.metadata(of: text)
        #expect(metadata.title == "AdGuard Base filter")
        #expect(metadata.version == "2.3.4.5")
    }

    @Test func htmlIsNotAFilterList() {
        #expect(!RuleText.looksLikeFilterList(Data("<!DOCTYPE html><html></html>".utf8)))
        #expect(!RuleText.looksLikeFilterList(Data()))
        #expect(RuleText.looksLikeFilterList(Data("! Title: x\n||a.com^".utf8)))
    }

    @Test func exceptionsAreRecognized() {
        #expect(RuleText.isException("@@||example.com^"))
        #expect(RuleText.isException("example.com#@#.ad"))
        #expect(!RuleText.isException("||example.com^"))
        #expect(!RuleText.isException("example.com##.ad"))
    }

    @Test(arguments: [
        ("example.com", "example.com"),
        ("https://www.Example.com/path?q=1#x", "example.com"),
        ("  m.example.co.uk:8443 ", "m.example.co.uk"),
        ("*.example.org", "example.org"),
        ("user@shop.example.it/", "shop.example.it"),
        ("perché.it", "perché.it"),
    ])
    func domainsAreNormalized(input: String, expected: String) {
        #expect(DomainInput.normalize(input) == expected)
    }

    @Test(arguments: ["", "localhost", "exa mple.com", "-bad.com", "a..b.com", "http://", "1.2.3.4", "ex_ample.com"])
    func invalidDomainsAreRejected(input: String) {
        #expect(DomainInput.normalize(input) == nil)
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func missingKeysFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(ScudoSettings.self, from: Data(#"{"allowlist":["a.com"]}"#.utf8))
        #expect(decoded.allowlist == ["a.com"])
        #expect(decoded.enabledFilterIDs == FilterCatalog.defaultEnabledIDs)
        #expect(decoded.automaticUpdates)
    }

    @Test func customRulesAreSplitBetweenBlockers() {
        var settings = ScudoSettings.defaults
        settings.customRules = "! comment\n||tracker.example^\n@@||cdn.example.com^\nsite.it#@#.ad\nsite.it##.ad\n"
        #expect(settings.customRuleLines(for: .security) == ["||tracker.example^", "@@||cdn.example.com^", "site.it#@#.ad", "site.it##.ad"])
        #expect(settings.customRuleLines(for: .ads) == ["@@||cdn.example.com^", "site.it#@#.ad"])
    }

    @Test func catalogIdentifiersAreUniqueAndEveryBlockerHasDefaults() {
        let ids = FilterCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for kind in BlockerKind.allCases {
            #expect(!ScudoSettings.defaults.enabledLists(for: kind).isEmpty)
        }
    }
}
