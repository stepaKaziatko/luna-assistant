import XCTest
@testable import Luna

final class ContextTests: XCTestCase {
    private let chrome = AppInfo(bundleId: "com.google.Chrome", name: "Google Chrome")

    private func captured(url: String? = nil, title: String? = nil, selection: String? = nil) -> CapturedContext {
        CapturedContext(app: chrome, details: .init(url: url, title: title, selection: selection))
    }

    // MARK: - Что уходит в ядро

    func testPayloadCarriesEverythingCaptured() {
        let context = captured(url: "https://github.com/owner/repo", title: "owner/repo", selection: "текст")

        XCTAssertEqual(
            context.payload,
            TaskContext(app: chrome, selection: "текст", title: "owner/repo", url: "https://github.com/owner/repo")
        )
    }

    func testDismissedSourceLeavesOnlySelection() {
        var context = captured(url: "https://example.com", title: "Example", selection: "текст")
        context.sourceDismissed = true

        XCTAssertEqual(context.payload, TaskContext(app: nil, selection: "текст", title: nil, url: nil))
    }

    func testDismissedSelectionLeavesOnlySource() {
        var context = captured(url: "https://example.com", selection: "текст")
        context.selectionDismissed = true

        XCTAssertEqual(context.payload, TaskContext(app: chrome, selection: nil, title: nil, url: "https://example.com"))
    }

    func testEverythingDismissedMeansNoContext() {
        var context = captured(selection: "текст")
        context.sourceDismissed = true
        context.selectionDismissed = true

        XCTAssertNil(context.payload)
    }

    // MARK: - Подписи

    func testSourceLabelPrefersHostThenTitleThenApp() {
        XCTAssertEqual(captured(url: "https://www.github.com/owner/repo", title: "owner/repo").source?.sourceLabel, "github.com")
        XCTAssertEqual(captured(title: "Заметки — план").source?.sourceLabel, "Заметки — план")
        XCTAssertEqual(captured().source?.sourceLabel, "Google Chrome")
        // У внутренних страниц браузера хоста нет.
        XCTAssertEqual(captured(url: "about:blank", title: "Новая вкладка").source?.sourceLabel, "Новая вкладка")
    }

    func testPreviewFlattensAndTruncates() {
        XCTAssertEqual("первая\n  вторая\tтретья".preview(limit: 40), "первая вторая третья")
        XCTAssertEqual("abcdefgh".preview(limit: 5), "abcde…")
    }

    // MARK: - Браузеры

    func testBrowserFamilies() {
        XCTAssertEqual(BrowserProbe.family(bundleId: "com.apple.Safari"), .safari)
        XCTAssertEqual(BrowserProbe.family(bundleId: "com.google.Chrome"), .chromium)
        XCTAssertEqual(BrowserProbe.family(bundleId: "company.thebrowser.Browser"), .chromium)
        XCTAssertNil(BrowserProbe.family(bundleId: "org.mozilla.firefox"))
    }

    func testScriptTargetsBrowserByPid() {
        let safari = BrowserProbe.script(pid: 4242, family: .safari)
        XCTAssertTrue(safari.contains("Application(4242)"))
        XCTAssertTrue(safari.contains("app.documents[0]"))

        let chrome = BrowserProbe.script(pid: 4242, family: .chromium)
        XCTAssertTrue(chrome.contains("Application(4242)"))
        XCTAssertTrue(chrome.contains("app.windows[0].activeTab"))
        XCTAssertTrue(chrome.contains(#"tab.url() + "\n" + tab.title()"#))
    }

    func testParsePage() {
        XCTAssertEqual(
            BrowserProbe.parse(status: 0, output: "https://github.com/owner/repo\nowner/repo: Short description\n", errorOutput: ""),
            .page(url: "https://github.com/owner/repo", title: "owner/repo: Short description")
        )
        XCTAssertEqual(
            BrowserProbe.parse(status: 0, output: "https://example.com\n\n", errorOutput: ""),
            .page(url: "https://example.com", title: nil)
        )
    }

    func testParseNoPage() {
        XCTAssertEqual(BrowserProbe.parse(status: 0, output: "\n", errorOutput: ""), .none)
        XCTAssertEqual(BrowserProbe.parse(status: 1, output: "", errorOutput: "execution error: Safari got an error (-1728)"), .none)
    }

    func testParseNotAuthorized() {
        let stderr = "execution error: Error: Error: Not authorized to send Apple events to Safari. (-1743)"
        XCTAssertEqual(BrowserProbe.parse(status: 1, output: "", errorOutput: stderr), .notAuthorized)
    }
}
