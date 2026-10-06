import AppKit
import XCTest
@testable import Luna

final class NotchGeometryTests: XCTestCase {
    private let thickness: CGFloat = 22

    /// Экран с вырезом: области строки меню слева и справа от выреза заданы шириной левой и правой.
    private func notched(
        frame: NSRect, safeTop: CGFloat, leftWidth: CGFloat, rightWidth: CGFloat, menuBar: CGFloat = 38
    ) -> NotchGeometry {
        let barY = frame.maxY - safeTop
        let left = NSRect(x: frame.minX, y: barY, width: leftWidth, height: safeTop)
        let right = NSRect(x: frame.maxX - rightWidth, y: barY, width: rightWidth, height: safeTop)
        let visible = NSRect(x: frame.minX, y: frame.minY + 75, width: frame.width, height: frame.height - 75 - menuBar)
        return NotchGeometry(
            frame: frame, visibleFrame: visible, safeAreaTop: safeTop,
            auxiliaryTopLeft: left, auxiliaryTopRight: right, menuBarThickness: thickness
        )
    }

    /// Экран без выреза; `menuBar` 0 — строка меню скрывается.
    private func flat(frame: NSRect, menuBar: CGFloat, left: NSRect? = nil, right: NSRect? = nil, safeTop: CGFloat = 0) -> NotchGeometry {
        let visible = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - menuBar)
        return NotchGeometry(
            frame: frame, visibleFrame: visible, safeAreaTop: safeTop,
            auxiliaryTopLeft: left, auxiliaryTopRight: right, menuBarThickness: thickness
        )
    }

    func testNotchAtDefaultScale() {
        // MacBook Pro 14", стандартный масштаб: 1512×982, области 663 и 664.
        let geometry = notched(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32, leftWidth: 663, rightWidth: 664)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notchWidth, 185, accuracy: 2)
        XCTAssertTrue((32...38).contains(geometry.barHeight))
        XCTAssertEqual(geometry.barHeight, 32)
        XCTAssertEqual(geometry.centerX, (663 + 848) / 2)
    }

    func testNotchWithMoreSpace() {
        // «Больше места»: 1800×1169, вырез шире в точках.
        let geometry = notched(frame: NSRect(x: 0, y: 0, width: 1800, height: 1169), safeTop: 38, leftWidth: 790, rightWidth: 790)
        XCTAssertEqual(geometry.notchWidth, 220, accuracy: 2)
        XCTAssertTrue((32...38).contains(geometry.barHeight))
        XCTAssertEqual(geometry.centerX, 900)
    }

    func testNoNotchWithVisibleMenuBar() {
        let frame = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let geometry = flat(frame: frame, menuBar: 25)
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.notchWidth, 0)
        XCTAssertEqual(geometry.centerX, frame.midX)
        XCTAssertEqual(geometry.barHeight, 25)
    }

    func testNoNotchWithHiddenMenuBarFallsBackToThickness() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = flat(frame: frame, menuBar: 0)
        XCTAssertEqual(geometry.notchWidth, 0)
        XCTAssertEqual(geometry.barHeight, thickness)
        XCTAssertEqual(geometry.centerX, frame.midX)
    }

    func testMeaninglessAuxiliaryAreaMeansNoNotch() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        // Левая область нулевой ширины.
        let zero = flat(
            frame: frame, menuBar: 38,
            left: NSRect(x: 0, y: 950, width: 0, height: 32), right: NSRect(x: 848, y: 950, width: 664, height: 32), safeTop: 32
        )
        XCTAssertEqual(zero.notchWidth, 0)
        XCTAssertEqual(zero.centerX, frame.midX)
        // Левая область шире половины экрана.
        let wide = flat(
            frame: frame, menuBar: 38,
            left: NSRect(x: 0, y: 950, width: 900, height: 32), right: NSRect(x: 848, y: 950, width: 664, height: 32), safeTop: 32
        )
        XCTAssertEqual(wide.notchWidth, 0)
        XCTAssertEqual(wide.centerX, frame.midX)
        XCTAssertEqual(wide.barHeight, 38)
        // Областей нет, хотя отступ сверху есть.
        let missing = flat(frame: frame, menuBar: 38, safeTop: 32)
        XCTAssertEqual(missing.notchWidth, 0)
        XCTAssertEqual(missing.centerX, frame.midX)
    }

    func testOffsetScreenUsesScreenCoordinates() {
        // Встроенный экран справа и выше главного монитора: центр — в координатах экрана, а не в локальных.
        let frame = NSRect(x: 2560, y: 400, width: 1512, height: 982)
        let geometry = notched(frame: frame, safeTop: 32, leftWidth: 663, rightWidth: 664)
        XCTAssertEqual(geometry.notchWidth, 185, accuracy: 2)
        XCTAssertEqual(geometry.centerX, 2560 + (663 + 848) / 2)
        // Монитор без выреза слева от главного.
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(flat(frame: left, menuBar: 24).centerX, -960)
    }

    func testFlatOverride() {
        let frame = NSRect(x: 100, y: 0, width: 1512, height: 982)
        XCTAssertEqual(NotchGeometry.flat(frame: frame, barHeight: 24), NotchGeometry(notchWidth: 0, barHeight: 24, centerX: 856))
    }
}
