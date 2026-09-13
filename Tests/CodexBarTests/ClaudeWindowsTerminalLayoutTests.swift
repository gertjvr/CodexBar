import Testing
@testable import CodexBarCore

struct ClaudeWindowsTerminalLayoutTests {
    @Test
    func `Windows cursor positioned rows keep session and weekly quotas separate`() throws {
        let text = "\u{1B}[27;3HCurrent\u{1B}[1Csession"
            + "\u{1B}[28;3H████\u{1B}[12X\u{1B}[13C76%\u{1B}[1Cused"
            + "\u{1B}[29;3HResets\u{1B}[1C8:30pm\u{1B}[1C(Australia/Brisbane)"
            + "\u{1B}[31;3HCurrent\u{1B}[1Cweek\u{1B}[1C(all\u{1B}[1Cmodels)"
            + "\u{1B}[32;3H████\u{1B}[46C9%\u{1B}[1Cused"
            + "\u{1B}[33;3HResets\u{1B}[1CSep\u{1B}[1C18,\u{1B}[1C1am\u{1B}[1C(Australia/Brisbane)"
        let snapshot = try ClaudeStatusProbe.parse(text: text)
        #expect(snapshot.sessionPercentLeft == 24)
        #expect(snapshot.weeklyPercentLeft == 91)
        #expect(snapshot.primaryResetDescription?.contains("8:30pm") == true)
        #expect(snapshot.secondaryResetDescription?.contains("Sep 18") == true)
    }

    @Test
    func `cursor redraw replaces old percentages and clears erased text`() {
        let text = "\u{1B}[1;1HCurrent session\u{1B}[2;1H76% used"
            + "\u{1B}[2;1H9% used\u{1B}[K"
        #expect(TerminalScreenText.render(text).split(separator: "\n").map(String.init) == [
            "Current session", "9% used",
        ])
        let plain = "Current session\n76% used\nCurrent week (all models)\n9% used"
        #expect(TerminalScreenText.render(plain) == plain)
    }
}
