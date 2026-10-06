import SwiftUI
import XCTest
@testable import Luna

/// Контур фигуры острова: прямой верх вместе с плечами, вогнутые плечи снаружи тела, скруглённый низ.
final class IslandShapeTests: XCTestCase {
    /// Тело 206×32 в рамке вида от x0 = 100: плечи — за рамкой, слева и справа.
    private let x0: CGFloat = 100
    private let width: CGFloat = 206
    private let top: CGFloat = 0

    private func path(height: CGFloat = 32, radius: CGFloat = 12) -> Path {
        IslandShape(width: width, height: height, bottomRadius: radius)
            .path(in: CGRect(x: x0, y: top, width: width, height: height))
    }

    private var x1: CGFloat { x0 + width }

    func testShouldersAreConcaveOutsideBody() {
        let path = path()
        XCTAssertTrue(path.contains(CGPoint(x: x0 - 3, y: top + 3)), "плечо у тела слева — чёрное")
        XCTAssertTrue(path.contains(CGPoint(x: x1 + 3, y: top + 3)), "плечо у тела справа — чёрное")
        XCTAssertFalse(path.contains(CGPoint(x: x0 - 15, y: top + 15)), "под плечом слева — строка меню")
        XCTAssertFalse(path.contains(CGPoint(x: x1 + 15, y: top + 15)), "под плечом справа — строка меню")
        XCTAssertFalse(path.contains(CGPoint(x: x0 - 25, y: top + 1)), "дальше плеча фигуры нет")
    }

    func testTopIsStraightAcrossShoulders() {
        let path = path()
        XCTAssertTrue(path.contains(CGPoint(x: x0 - 10, y: top + 0.5)))
        XCTAssertTrue(path.contains(CGPoint(x: x1 + 10, y: top + 0.5)))
        let bounds = path.boundingRect
        XCTAssertEqual(bounds.minX, x0 - 20, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, x1 + 20, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, top, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, top + 32, accuracy: 0.01)
    }

    func testBottomIsRounded() {
        let shape = IslandShape(width: width, height: 32, bottomRadius: 12)
        XCTAssertGreaterThanOrEqual(shape.radius, 8)
        let path = path()
        XCTAssertFalse(path.contains(CGPoint(x: x0 + 1, y: top + 32 - 1)), "угол тела скруглён слева")
        XCTAssertFalse(path.contains(CGPoint(x: x1 - 1, y: top + 32 - 1)), "угол тела скруглён справа")
        XCTAssertTrue(path.contains(CGPoint(x: x0 + width / 2, y: top + 32 - 1)), "середина низа — чёрная")
        XCTAssertTrue(path.contains(CGPoint(x: x0 + 1, y: top + 20)), "бок тела отвесный")
    }

    func testLowShapeGivesWayRadiusFirst() {
        let low = IslandShape(width: 205, height: 24, bottomRadius: 13)
        XCTAssertEqual(low.shoulder, 20)
        XCTAssertLessThanOrEqual(low.shoulder + low.radius, 24, "плечо и угол вместе не выше тела")
        XCTAssertEqual(low.radius, 4)
        // Совсем низкая фигура: радиус ушёл, плечо — не выше тела.
        let thin = IslandShape(width: 205, height: 12, bottomRadius: 13)
        XCTAssertEqual(thin.shoulder, 12)
        XCTAssertEqual(thin.radius, 0)
        // Узкая фигура: плечо не шире половины тела.
        let narrow = IslandShape(width: 16, height: 32, bottomRadius: 13)
        XCTAssertEqual(narrow.shoulder, 8)
        XCTAssertLessThanOrEqual(narrow.radius, 8)
    }

    func testAnimatableDataInterpolatesSizeAndRadius() {
        let from = IslandShape(width: 206, height: 32, bottomRadius: 13)
        let to = IslandShape(width: 720, height: 400, bottomRadius: 20)
        var middle = from
        var data = from.animatableData
        var delta = to.animatableData
        delta -= from.animatableData
        delta.scale(by: 0.5)
        data += delta
        middle.animatableData = data
        XCTAssertEqual(middle.width, 463, accuracy: 0.001)
        XCTAssertEqual(middle.height, 216, accuracy: 0.001)
        XCTAssertEqual(middle.bottomRadius, 16.5, accuracy: 0.001)
    }
}

/// Попадание по контуру фигуры в координатах экрана: тело и плечи — да, строка меню рядом и скруглённые углы — нет.
final class IslandContourTests: XCTestCase {
    /// Тело покоя 206×32 по середине выреза x = 500, верхний край экрана — y = 1000 (y вверх, как у AppKit).
    private let body = CGSize(width: 206, height: 32)
    private let center: CGFloat = 500
    private let top: CGFloat = 1000
    private var x0: CGFloat { center - body.width / 2 }
    private var x1: CGFloat { center + body.width / 2 }
    private var bottom: CGFloat { top - body.height }

    private func hit(_ x: CGFloat, _ y: CGFloat, center: CGFloat? = nil, radius: CGFloat = IslandShape.bottomRadius(collapsed: true)) -> Bool {
        IslandShape.contains(CGPoint(x: x, y: y), body: body, centerX: center ?? self.center, top: top, bottomRadius: radius)
    }

    func testBodyIsInside() {
        XCTAssertTrue(hit(center, top - body.height / 2), "середина тела")
        XCTAssertTrue(hit(x0 + 5, top - body.height / 2), "левое крыло у края тела")
        XCTAssertTrue(hit(center, top), "верхняя кромка у края экрана")
    }

    func testShouldersAtTopEdgeAreInside() {
        XCTAssertTrue(hit(x1 + 5, top - 3), "правое плечо у верхнего края")
        XCTAssertTrue(hit(x0 - 5, top - 3), "левое плечо у верхнего края")
        XCTAssertTrue(hit(x1 + IslandShape.shoulderSize / 2, top - 0.5), "плечо вровень с краем экрана")
    }

    func testMenuBarBesideShouldersIsOutside() {
        let shoulder = IslandShape.shoulderSize
        XCTAssertFalse(hit(x1 + shoulder + 5, top - body.height / 2), "строка меню в 5 pt за правым плечом")
        XCTAssertFalse(hit(x0 - shoulder - 5, top - body.height / 2), "строка меню в 5 pt за левым плечом")
        XCTAssertFalse(hit(x1 + 15, top - 15), "под вогнутым плечом — строка меню")
        XCTAssertFalse(hit(center, top + 5), "выше края экрана фигуры нет")
        XCTAssertFalse(hit(center, bottom - 1), "ниже тела фигуры нет")
    }

    func testRoundedBottomCornersAreOutside() {
        XCTAssertFalse(hit(x0 + 1, bottom + 1), "скруглённый нижний угол pill")
        XCTAssertFalse(hit(x1 - 1, bottom + 1), "правый нижний угол pill")
        XCTAssertTrue(hit(x0 + 1, bottom + 12), "выше скругления — тело")
        // Раскрытая фигура: тело 720×300, радиус низа 20.
        let card = CGSize(width: 720, height: 300)
        let left = center - card.width / 2
        func cardHit(_ x: CGFloat, _ y: CGFloat) -> Bool {
            IslandShape.contains(
                CGPoint(x: x, y: y), body: card, centerX: center, top: top, bottomRadius: IslandShape.bottomRadius(collapsed: false)
            )
        }
        XCTAssertFalse(cardHit(left + 4, top - card.height + 4), "скруглённый нижний угол карточки")
        XCTAssertTrue(cardHit(left + 4, top - card.height + 24), "выше скругления — тело")
    }

    func testContourFollowsShiftedBody() {
        // Крылья разной ширины: тело сдвинуто вправо на 40 — контур вместе с ним.
        let shifted = center + 40
        XCTAssertTrue(hit(x1 + 40 + 5, top - 3, center: shifted), "плечо сдвинутого тела")
        XCTAssertFalse(hit(x0 + 5, top - body.height / 2, center: shifted), "где было левое крыло — уже не фигура")
        XCTAssertFalse(hit(x1 + 40 + IslandShape.shoulderSize + 5, top - body.height / 2, center: shifted))
    }
}
