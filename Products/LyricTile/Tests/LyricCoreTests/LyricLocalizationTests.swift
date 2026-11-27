import Testing
@testable import LyricCore

struct LyricLocalizationTests {
    @Test func followsTheFirstSupportedSystemLanguage() {
        #expect(LyricLocalization.resolve(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .chinese)
        #expect(LyricLocalization.resolve(preferredLanguages: ["en-GB", "zh-Hans"]) == .english)
        #expect(LyricLocalization.resolve(preferredLanguages: ["fr-FR", "zh-Hant-TW", "en"]) == .chinese)
        #expect(LyricLocalization.resolve(preferredLanguages: [" ZH_CN "]) == .chinese)
        #expect(LyricLocalization.resolve(preferredLanguages: ["en_US"]) == .english)
        #expect(LyricLocalization.resolve(preferredLanguages: ["de-DE"]) == .english)
        #expect(LyricLocalization.resolve(preferredLanguages: []) == .english)
        #expect(LyricLocalization.resolve(preferredLanguages: ["zhinvalid"]) == .english)
    }

    @Test func explicitLanguageDoesNotDependOnTheTestHost() {
        #expect(LyricLocalization.text("设置…", "Settings…", language: .english) == "Settings…")
        #expect(LyricLocalization.text("播放", "Play", language: .english) == "Play")
        #expect(LyricLocalization.text("歌词暂未同步", "Lyrics are not synced", language: .chinese) == "歌词暂未同步")
        #expect(LyricLocalization.text("连接 Apple Music", "Connect to Apple Music", language: .english) == "Connect to Apple Music")
    }
}
