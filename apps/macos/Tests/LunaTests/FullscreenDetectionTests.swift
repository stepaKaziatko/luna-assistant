import CoreGraphics
import XCTest
@testable import Luna

/// Определение полноэкранного режима по списку окон: фикстуры — записи `CGWindowListCopyWindowInfo` без записи экрана.
final class FullscreenDetectionTests: XCTestCase {
    /// MacBook 14": экран 1512×982, полоса выреза 32; координаты списка окон — от верхнего левого угла.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let bar: CGFloat = 32
    private let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    private let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))

    private func window(_ owner: String, _ rect: CGRect, level: Int = 0) -> ScreenWindow {
        ScreenWindow(level: level, owner: owner, bounds: rect)
    }

    /// То, что есть на любом Space: строка меню, Dock и окна Window Server и WindowManager на уровнях рабочего стола.
    private func system(on screen: CGRect) -> [ScreenWindow] {
        [
            window("Window Server", CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: bar), level: 24),
            window("Dock", CGRect(x: screen.minX, y: screen.maxY - 70, width: screen.width, height: 70), level: 20),
            window("Dock", screen, level: desktopLevel),
            window("WindowManager", screen, level: iconLevel),
            window("Window Server", screen, level: desktopLevel),
        ]
    }

    private func wallpaper(on screen: CGRect) -> [ScreenWindow] {
        [window("Wallpaper", screen, level: desktopLevel), window("Finder", screen, level: iconLevel)]
    }

    private func isFullscreen(_ windows: [ScreenWindow], on screen: CGRect? = nil) -> Bool {
        FullscreenDetection.isFullscreen(windows: windows, screen: screen ?? self.screen, menuBarHeight: bar, desktopIconLevel: iconLevel)
    }

    func testOrdinarySpaceIsNotFullscreen() {
        let windows = system(on: screen) + wallpaper(on: screen) + [
            window("Safari", CGRect(x: 120, y: 80, width: 1100, height: 760)),
            window("Terminal", CGRect(x: 300, y: 200, width: 800, height: 500)),
        ]
        XCTAssertFalse(isFullscreen(windows))
    }

    func testSingleFullscreenWindowUnderNotchBar() {
        let windows = system(on: screen) + [window("Safari", CGRect(x: 0, y: bar, width: 1512, height: 982 - bar))]
        XCTAssertTrue(isFullscreen(windows), "окно под полосой выреза до низа, обоев нет")
    }

    func testChromeFullscreenAsStackedWindows() {
        let windows = system(on: screen) + [
            window("Google Chrome", CGRect(x: 0, y: bar, width: 1512, height: 40)),
            window("Google Chrome", CGRect(x: 0, y: bar + 40, width: 1512, height: 46)),
            window("Google Chrome", CGRect(x: 0, y: bar + 86, width: 1512, height: 982 - bar - 86)),
        ]
        XCTAssertTrue(isFullscreen(windows), "окна одного владельца сложены до низа экрана")
    }

    func testStackedWindowsOfDifferentOwnersDoNotCount() {
        let windows = system(on: screen) + [
            window("Google Chrome", CGRect(x: 0, y: bar, width: 1512, height: 400)),
            window("Safari", CGRect(x: 0, y: bar + 400, width: 1512, height: 982 - bar - 400)),
        ]
        XCTAssertFalse(isFullscreen(windows))
    }

    func testZoomedWindowWithWallpaperIsNotFullscreen() {
        let windows = system(on: screen) + wallpaper(on: screen) + [
            window("Safari", CGRect(x: 0, y: bar, width: 1512, height: 982 - bar)),
        ]
        XCTAssertFalse(isFullscreen(windows), "развёрнутое окно: обои рабочего стола видны")
    }

    func testDesktopKeepersDoNotPreventFullscreen() {
        // Только окна Dock, WindowManager и Window Server на уровнях рабочего стола — это не рабочий стол.
        let windows = system(on: screen) + [window("Preview", CGRect(x: 0, y: 0, width: 1512, height: 982))]
        XCTAssertTrue(isFullscreen(windows))
    }

    func testEmptyListIsNotFullscreen() {
        XCTAssertFalse(isFullscreen([]))
    }

    func testOffsetScreenIsJudgedByItsFrame() {
        // Второй монитор справа и выше главного: в координатах списка окон y отрицательный.
        let external = CGRect(x: 1512, y: -1080, width: 1920, height: 1080)
        let video = window("IINA", CGRect(x: 1512, y: -1080 + bar, width: 1920, height: 1080 - bar))
        XCTAssertTrue(isFullscreen(system(on: external) + [video], on: external), "полноэкранное на втором мониторе")
        XCTAssertFalse(isFullscreen(system(on: external) + [video], on: screen), "главный экран этим окном не занят")
        XCTAssertFalse(
            isFullscreen(system(on: external) + wallpaper(on: external) + [video], on: external),
            "обои второго монитора видны"
        )
    }

    func testDisplayRectFlipsToWindowListCoordinates() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(FullscreenDetection.displayRect(screen: main, mainScreen: main), main)
        let above = CGRect(x: 1512, y: 982, width: 1920, height: 1080)
        XCTAssertEqual(FullscreenDetection.displayRect(screen: above, mainScreen: main), CGRect(x: 1512, y: -1080, width: 1920, height: 1080))
    }

    func testWindowListRecordParsing() throws {
        let bounds = CGRect(x: 0, y: 32, width: 1512, height: 950)
        let record: [String: Any] = [
            kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: 0, kCGWindowOwnerName as String: "Safari",
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
        XCTAssertEqual(ScreenWindow(info: record, ownPID: 7), ScreenWindow(level: 0, owner: "Safari", bounds: bounds))
        XCTAssertNil(ScreenWindow(info: record, ownPID: 42), "свои окна Luna не считаются")
        XCTAssertNil(ScreenWindow(info: [kCGWindowOwnerName as String: "Safari"], ownPID: 7), "запись без уровня и рамки")
    }
}

/// Когда спрашиваются окна: только при вырезе у экрана острова и только по событию.
@MainActor
final class FullscreenWatchTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func record(_ owner: String, _ rect: CGRect, level: Int = 0) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: level, kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
        ]
    }

    private var fullscreenList: [[String: Any]] {
        [record("Safari", CGRect(x: 0, y: 32, width: 1512, height: 950))]
    }

    func testNoNotchMeansNoWindowQueries() {
        var asked = 0
        let watch = FullscreenWatch(source: { asked += 1; return self.fullscreenList })
        watch.target = { nil }
        watch.check()
        watch.spaceChanged()
        XCTAssertEqual(asked, 0, "без выреза список окон не спрашивается")
        XCTAssertEqual(watch.queries, 0)
        XCTAssertFalse(watch.isFullscreen)
    }

    func testNotchScreenAsksWindowsOnEvent() {
        var asked = 0
        var changes: [Bool] = []
        let watch = FullscreenWatch(source: { asked += 1; return self.fullscreenList })
        watch.target = { (self.screen, 32) }
        watch.onChange = { changes.append($0) }
        XCTAssertEqual(asked, 0, "до события окна не спрашиваются")

        watch.check()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(watch.queries, 1)
        XCTAssertTrue(watch.isFullscreen)
        XCTAssertEqual(changes, [true])

        watch.reset()
        XCTAssertFalse(watch.isFullscreen, "смена экрана — полноэкранного нет до события")
        XCTAssertEqual(changes, [true, false])
    }

    func testMissingWindowListMeansNoFullscreen() {
        let watch = FullscreenWatch(source: { nil })
        watch.target = { (self.screen, 32) }
        watch.check()
        XCTAssertFalse(watch.isFullscreen)
        XCTAssertEqual(watch.queries, 1)
    }

    func testSpaceChangeChecksAgainWhileSpaceSettles() {
        var asked = 0
        let watch = FullscreenWatch(source: { asked += 1; return [] })
        watch.target = { (self.screen, 32) }
        watch.spaceChanged()
        XCTAssertEqual(asked, 1, "первая проверка — сразу")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertGreaterThanOrEqual(asked, 3, "повторы, пока Space встаёт на место")
        let before = asked
        // Экран без выреза: серия отменяется, окна больше не спрашиваются.
        watch.target = { nil }
        watch.spaceChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(asked, before)
        XCTAssertEqual(FullscreenWatch.settleDelays.last, 2.5, "повторы — не дольше 2,5 с")
    }
}
