import Testing
@testable import LimitGuardCore

@Suite struct ContinueTextTests {
    let table = ["tr": "devam et", "en": "continue"]

    @Test func turkishSampleGivesDevamEt() {
        let r = ContinueText.resolve(sample: "Lütfen bu projedeki testleri çalıştır ve başarısız olanları düzelt, sonra bana kısa bir özet ver.", table: table, fallback: "continue")
        #expect(r.text == "devam et")
        #expect(r.language == "tr")
    }

    @Test func englishSampleGivesContinue() {
        let r = ContinueText.resolve(sample: "Please run the tests in this project and fix the failing ones, then give me a short summary.", table: table, fallback: "go on")
        #expect(r.text == "continue")
        #expect(r.language == "en")
    }

    @Test func shortAmbiguousGivesFallback() {
        let r = ContinueText.resolve(sample: "ok", table: table, fallback: "fallback")
        #expect(r.text == "fallback")
        #expect(r.language == nil)
    }

    @Test func customTableEntryUsed() {
        var t = table
        t["de"] = "weiter"
        let r = ContinueText.resolve(sample: "Bitte führe die Tests in diesem Projekt aus und behebe die fehlgeschlagenen, danach gib mir eine kurze Zusammenfassung.", table: t, fallback: "continue")
        #expect(r.text == "weiter")
        #expect(r.language == "de")
    }
}
