import XCTest
@testable import Luna

/// Раскладка свёрнутого острова: покой, крылья вокруг выреза, псевдо-остров без выреза.
final class IslandLayoutTests: XCTestCase {
    private let margin = IslandLayout.restMargin

    func testRestWithNotchIsNotchPlusMargins() {
        let rest = IslandLayout.make(notchWidth: 186, barHeight: 32)
        XCTAssertEqual(rest.body, CGSize(width: 186 + 2 * margin, height: 32))
        XCTAssertEqual(rest.gap, 186)
        XCTAssertEqual(rest.leftWing, margin)
        XCTAssertEqual(rest.rightWing, margin)
        XCTAssertEqual(rest.bodyOffset, 0)
    }

    func testRestWithoutNotchIsPseudoIsland() {
        let rest = IslandLayout.make(notchWidth: 0, barHeight: 24)
        XCTAssertEqual(rest.body, CGSize(width: 185 + 2 * margin, height: 24))
        XCTAssertEqual(rest.gap, 0)
        XCTAssertEqual(rest.bodyOffset, 0)
    }

    func testWingsNeverOverlapNotch() {
        let center: CGFloat = 755.5
        for (left, right) in [(39.0, 120.0), (267.0, 10.0), (0.0, 0.0), (500.0, 500.0)] as [(CGFloat, CGFloat)] {
            let layout = IslandLayout.make(notchWidth: 186, barHeight: 32, left: left, right: right)
            XCTAssertEqual(layout.gap, 186)
            XCTAssertEqual(layout.body.width, 186 + layout.leftWing + layout.rightWing)
            // Тело на экране: середина — центр выреза со сдвигом.
            let bodyMinX = center + layout.bodyOffset - layout.body.width / 2
            let bodyMaxX = center + layout.bodyOffset + layout.body.width / 2
            let leftWing = bodyMinX...(bodyMinX + layout.leftWing)
            let rightWing = (bodyMaxX - layout.rightWing)...bodyMaxX
            let notch = (center - 93)...(center + 93)
            XCTAssertEqual(leftWing.upperBound, notch.lowerBound, accuracy: 0.001, "левое крыло кончается у выреза")
            XCTAssertEqual(rightWing.lowerBound, notch.upperBound, accuracy: 0.001, "правое крыло начинается у выреза")
            XCTAssertLessThanOrEqual(layout.leftWing, IslandLayout.maxWing)
            XCTAssertLessThanOrEqual(layout.rightWing, IslandLayout.maxWing)
        }
    }

    func testWingIsNotNarrowerThanRestMargin() {
        let layout = IslandLayout.make(notchWidth: 186, barHeight: 32, left: 39, right: 0)
        XCTAssertEqual(layout.leftWing, 39)
        XCTAssertEqual(layout.rightWing, margin, "пустое правое крыло — запас покоя")
        XCTAssertEqual(layout.bodyOffset, (margin - 39) / 2, "тело сдвинуто к более широкому крылу")
        let rest = IslandLayout.make(notchWidth: 186, barHeight: 32)
        XCTAssertGreaterThanOrEqual(layout.body.width, rest.body.width, "с событиями не уже покоя")
    }

    func testWithoutNotchWingsCloseIntoOneRow() {
        let short = IslandLayout.make(notchWidth: 0, barHeight: 24, left: 39, right: 60)
        XCTAssertEqual(short.gap, 0)
        XCTAssertEqual(short.bodyOffset, 0, "строка по центру")
        XCTAssertEqual(short.body.width, 185 + 2 * margin, "короткая строка — не уже псевдо-острова")
        let long = IslandLayout.make(notchWidth: 0, barHeight: 24, left: 200, right: 150)
        XCTAssertEqual(long.body.width, 350)
        XCTAssertEqual(long.bodyOffset, 0)
    }

    func testHeightIsBarAndItemsFitIt() {
        for bar in [22, 24, 32, 38] as [CGFloat] {
            let layout = IslandLayout.make(notchWidth: bar > 30 ? 186 : 0, barHeight: bar, left: 39, right: 100)
            XCTAssertEqual(layout.body.height, bar)
            XCTAssertLessThanOrEqual(layout.rowHeight, bar)
            XCTAssertLessThanOrEqual(layout.lunaAvatar, bar)
            XCTAssertLessThanOrEqual(layout.sessionAvatar, bar)
        }
        // На полосе MacBook аватары как раньше, на строке меню — меньше.
        let notched = IslandLayout.make(notchWidth: 186, barHeight: 32)
        XCTAssertEqual(notched.lunaAvatar, 22)
        XCTAssertEqual(notched.sessionAvatar, 20)
        XCTAssertEqual(notched.chipFont, 11)
        let flat = IslandLayout.make(notchWidth: 0, barHeight: 22)
        XCTAssertLessThan(flat.lunaAvatar, 22)
        XCTAssertLessThan(flat.sessionAvatar, 20)
        XCTAssertLessThan(flat.chipFont, 11)
    }

    func testPillPanelFitsExpandedPanel() {
        let widest = NotchGeometry(notchWidth: IslandLayout.maxNotchWidth, barHeight: 38, centerX: 0)
        XCTAssertLessThanOrEqual(Layout.pillPanel(for: widest).width, Layout.expandedPanel.width)
        let notched = NotchGeometry(notchWidth: 186, barHeight: 32, centerX: 0)
        let panel = Layout.pillPanel(for: notched)
        XCTAssertEqual(panel.height, 32)
        XCTAssertGreaterThanOrEqual(panel.width, 186 + 2 * IslandLayout.maxWing + 2 * IslandShape.shoulderSize)
        let flat = Layout.pillPanel(for: NotchGeometry(notchWidth: 0, barHeight: 24, centerX: 0))
        XCTAssertGreaterThanOrEqual(flat.width, 185 + 2 * margin + 2 * IslandShape.shoulderSize)
    }
}
