import SwiftUI

/// Фигура острова — продолжение выреза камеры. Прямой верх идёт вровень с верхним краем экрана и шире тела
/// на два вогнутых плеча: ими фигура плавно переходит в строку меню. Бока отвесные, низ скруглён.
///
/// Тело — `width × height` по середине рамки вида от её верхнего края; плечи рисуются за рамкой.
/// Размер видимой фигуры (`islandSize`) задаёт тело; наведение и клики ловятся по контуру вместе с плечами
/// (`contains`).
/// Замысел контура и порядок, в котором на низкой фигуре уступают радиус и плечо, — `SurfaceOutline`
/// из capa-the-notch 0.3.1 (MIT); код написан заново, кривые и коэффициенты не переносились.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat

    /// Ширина и высота вогнутого плеча снаружи тела.
    static let shoulderSize: CGFloat = 20

    /// Радиус низа свёрнутого острова и раскрытого. У pill он не больше запаса покоя: скругление не заходит
    /// под вырез, и прямоугольник выреза закрыт целиком.
    static func bottomRadius(collapsed: Bool) -> CGFloat {
        collapsed ? IslandLayout.restMargin : 20
    }

    /// Попадает ли точка экрана в фигуру вместе с плечами: по этому контуру ловятся наведение, удержание
    /// и правый клик. `body` — тело без плеч, его середина — `centerX`, прямой верх — `top` (верхний край экрана).
    /// Координаты экрана AppKit: y растёт вверх. Контур — тот же путь, что рисует остров.
    static func contains(
        _ point: CGPoint, body: CGSize, centerX: CGFloat, top: CGFloat, bottomRadius: CGFloat
    ) -> Bool {
        // Курсор у самого края экрана может стоять на верхней кромке фигуры: это ещё фигура.
        let depth = top - point.y
        guard depth >= -1, body.width > 0, body.height > 0 else { return false }
        let shape = IslandShape(width: body.width, height: body.height, bottomRadius: bottomRadius)
        let rect = CGRect(x: centerX - body.width / 2, y: 0, width: body.width, height: body.height)
        return shape.path(in: rect).contains(CGPoint(x: point.x, y: max(depth, 0.5)))
    }

    /// Пружина острова тянет размер тела и радиус низа: фигура перетекает, не меняя типа.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), bottomRadius) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            bottomRadius = newValue.second
        }
    }

    /// Плечо на низкой или узкой фигуре: не выше тела и не шире его половины.
    var shoulder: CGFloat { max(0, min(Self.shoulderSize, height, width / 2)) }

    /// Радиус низа: уступает первым — плечо и угол вместе не выше тела.
    var radius: CGFloat { max(0, min(bottomRadius, width / 2, height - shoulder)) }

    func path(in rect: CGRect) -> Path {
        let x0 = rect.midX - width / 2
        let x1 = rect.midX + width / 2
        let top = rect.minY
        let bottom = top + height
        let s = shoulder
        let r = radius
        // Четверть окружности кубической кривой.
        let k: CGFloat = 0.5523

        var path = Path()
        path.move(to: CGPoint(x: x0 - s, y: top))
        path.addLine(to: CGPoint(x: x1 + s, y: top))
        // Правое плечо: дуга с центром (x1 + s, top + s) — вогнута, уходит от строки меню вниз к боку тела.
        path.addCurve(
            to: CGPoint(x: x1, y: top + s),
            control1: CGPoint(x: x1 + s - k * s, y: top),
            control2: CGPoint(x: x1, y: top + s - k * s)
        )
        path.addLine(to: CGPoint(x: x1, y: bottom - r))
        path.addCurve(
            to: CGPoint(x: x1 - r, y: bottom),
            control1: CGPoint(x: x1, y: bottom - r + k * r),
            control2: CGPoint(x: x1 - r + k * r, y: bottom)
        )
        path.addLine(to: CGPoint(x: x0 + r, y: bottom))
        path.addCurve(
            to: CGPoint(x: x0, y: bottom - r),
            control1: CGPoint(x: x0 + r - k * r, y: bottom),
            control2: CGPoint(x: x0, y: bottom - r + k * r)
        )
        path.addLine(to: CGPoint(x: x0, y: top + s))
        // Левое плечо — зеркально правому, центр (x0 − s, top + s).
        path.addCurve(
            to: CGPoint(x: x0 - s, y: top),
            control1: CGPoint(x: x0, y: top + s - k * s),
            control2: CGPoint(x: x0 - s + k * s, y: top)
        )
        path.closeSubpath()
        return path
    }
}
