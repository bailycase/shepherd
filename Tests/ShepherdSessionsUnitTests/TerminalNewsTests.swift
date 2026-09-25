import Testing
@testable import ShepherdSessions

/// A terminal's news: every read of output is news, except what it prints to redraw itself just
/// after a resize.
@Suite("Terminal news")
struct TerminalNewsTests {
    private let start = ContinuousClock.now

    @Test func everyReadOfOutputIsNewsWithoutAResize() {
        var news = TerminalNews()
        news.output(at: start)
        news.output(at: start + .milliseconds(5))
        #expect(news.sequence == 2)
    }

    @Test(arguments: [
        (Duration.zero, 0),
        (.milliseconds(40), 0),
        (TerminalNews.redrawWindow - .milliseconds(1), 0),
        (TerminalNews.redrawWindow, 1),
        (TerminalNews.redrawWindow + .seconds(5), 1),
    ] as [(Duration, UInt64)])
    func outputSoonAfterAResizeIsARedraw(after delay: Duration, news expected: UInt64) {
        var news = TerminalNews()
        news.resized(at: start)
        news.output(at: start + delay)
        #expect(news.sequence == expected)
    }

    /// A window dragged across many sizes keeps its shell's redraws quiet to the end; a command
    /// still printing after it is news again.
    @Test func eachResizeExtendsTheQuietAndOutputAfterItIsNews() {
        var news = TerminalNews()
        for step in 0..<5 {
            let now = start + .milliseconds(300 * step)
            news.resized(at: now)
            news.output(at: now + .milliseconds(20))
        }
        #expect(news.sequence == 0)
        news.output(at: start + .milliseconds(1200) + TerminalNews.redrawWindow)
        news.output(at: start + .milliseconds(1300) + TerminalNews.redrawWindow)
        #expect(news.sequence == 2)
    }
}
