import AppKit
import SwiftUI

/// Внешность аватара: оттенок и рисунок кратеров.
struct AvatarLook: Equatable {
    let hue: Double
    let saturation: Double
    let seed: UInt64
    var accessory: AvatarAccessory = .none

    /// Luna по умолчанию — серебристая; выбранный пользователем облик — `LunaSettings.lunaLook`.
    static let luna = AvatarLook(hue: 0.62, saturation: 0.1, seed: 0x4c75_6e61)

    /// Сессии одного проекта — одного цвета, различаются кратерами.
    static func session(_ session: AgentSession) -> AvatarLook {
        AvatarLook(hue: Double(stableHash(session.project) % 360) / 360, saturation: 0.55, seed: stableHash(session.id))
    }

    var lit: Color { Color(hue: hue, saturation: saturation * 0.5, brightness: 1) }
    var shade: Color { Color(hue: hue, saturation: saturation, brightness: 0.72) }
    var ink: Color { Color(hue: hue, saturation: min(1, saturation + 0.25), brightness: 0.15) }
}

/// Маленькая луна с глазами. Рисуется в Canvas по кадрам: дышит, моргает, озирается за работой,
/// подпрыгивает и смотрит на курсор, когда зовёт человека. Кадры идут в общем такте острова
/// (`IslandClock`). Схема движка (плавное следование
/// за целью, не зависящее от частоты кадров, моргание по таймеру) — как у Coucou (MIT, © Louis Raillé);
/// персонаж свой.
struct MoonAvatar: View {
    let look: AvatarLook
    let mood: AvatarMood
    var size: CGFloat = 20

    @StateObject private var engine = AvatarEngine()
    private var motion = Motion()

    init(look: AvatarLook, mood: AvatarMood, size: CGFloat = 20) {
        self.look = look
        self.mood = mood
        self.size = size
    }

    var body: some View {
        Group {
            if motion.isStill {
                // Без таймера вовсе: неподвижный аватар ничего не стоит.
                Canvas { context, canvasSize in
                    AvatarPainter.draw(&context, size: canvasSize, look: look, mood: mood, pose: AvatarEngine.stillPose(mood))
                }
            } else {
                // Спящему хватает редких кадров: он только дышит.
                TimelineView(IslandClock.schedule(every: mood == .sleeping ? 3 : 1)) { timeline in
                    Canvas { context, canvasSize in
                        let pose = engine.step(to: timeline.date.timeIntervalSinceReferenceDate, mood: mood, still: false)
                        AvatarPainter.draw(&context, size: canvasSize, look: look, mood: mood, pose: pose)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Куда смотреть аватарам: верхняя середина острова в координатах экрана. Обновляет панель.
@MainActor
enum IslandPointer {
    static var anchor: CGPoint?

    /// Смещение курсора от острова: x вправо, y вниз.
    static var offset: CGPoint? {
        guard let anchor else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - anchor.x, y: anchor.y - mouse.y)
    }
}

struct AvatarPose: Equatable {
    /// Взгляд: −1…1 по каждой оси, y вниз.
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0
    /// Раскрытие глаз: 0 — закрыты.
    var open: CGFloat = 1
    /// Сдвиг тела по вертикали в радиусах; отрицательный — вверх.
    var lift: CGFloat = 0
    /// Растяжение по вертикали: дыхание.
    var stretch: CGFloat = 1
    /// Угол спутника на орбите.
    var orbit: CGFloat = 0
    /// Пульс значка, 0…1.
    var pulse: CGFloat = 0
}

/// Состояние между кадрами. `@Published` нет намеренно: движок меняется внутри отрисовки
/// и не должен перезапускать её.
@MainActor
final class AvatarEngine: ObservableObject {
    private var pose = AvatarPose()
    private var lastTime: TimeInterval?
    /// Случайная фаза: аватары рядом не дышат в такт.
    private let phase = TimeInterval.random(in: 0...5)
    private var blinkStart: TimeInterval = -1
    private var nextBlink: TimeInterval = 0

    func step(to now: TimeInterval, mood: AvatarMood, still: Bool) -> AvatarPose {
        guard !still else { return Self.stillPose(mood) }
        guard let last = lastTime else {
            lastTime = now
            nextBlink = now + .random(in: 1.5...3.5)
            pose = Self.stillPose(mood)
            return pose
        }
        // После паузы кадров время не «прыгает»; спящий аватар тикает раз в 0,2 с.
        let dt = min(0.25, now - last)
        lastTime = now
        let t = now + phase

        var target = Self.stillPose(mood)
        // Взгляд на курсор насыщается мягко: дальний курсор не выворачивает глаза.
        let pointer = IslandPointer.offset.map { CGPoint(x: tanh($0.x / 260), y: tanh($0.y / 200)) }
            ?? CGPoint(x: target.lookX, y: target.lookY)
        switch mood {
        case .sleeping:
            target.stretch = 1 + sin(t * 1.8) * 0.035
        case .working:
            target.lookX = sin(t * 1.7) * 0.75
            target.lookY = 0.1 + sin(t * 2.9) * 0.2
            pose.orbit = CGFloat(t * 2.6)
        case .listening:
            target.lookX = pointer.x
            target.lookY = pointer.y
        case .waiting:
            target.lookX = pointer.x
            target.lookY = pointer.y
            target.lift = -abs(sin(t * 5.2)) * 0.14
            pose.pulse = CGFloat((sin(t * 4) + 1) / 2)
        case .happy:
            target.lift = -abs(sin(t * 3.2)) * 0.05
        case .error:
            break
        }

        // Экспоненциальное следование за целью: одинаково на 30 и на 120 кадрах в секунду.
        let k = CGFloat(1 - pow(0.0025, dt))
        pose.lookX += (target.lookX - pose.lookX) * k
        pose.lookY += (target.lookY - pose.lookY) * k
        pose.stretch += (target.stretch - pose.stretch) * k
        pose.lift = target.lift

        if mood == .sleeping {
            pose.open += (0 - pose.open) * k
        } else {
            if now >= nextBlink {
                blinkStart = now
                nextBlink = now + 2.2 + .random(in: 0...3.2)
            }
            pose.open = Self.blink(now - blinkStart)
        }
        return pose
    }

    /// Закрываются за 70 мс, открываются за 130.
    private static func blink(_ elapsed: TimeInterval) -> CGFloat {
        switch elapsed {
        case ..<0: 1
        case ..<0.07: 1 - 0.94 * CGFloat(elapsed / 0.07)
        case ..<0.2: 0.06 + 0.94 * CGFloat((elapsed - 0.07) / 0.13)
        default: 1
        }
    }

    /// Поза без движения: для первого кадра и для «Уменьшения движения».
    static func stillPose(_ mood: AvatarMood) -> AvatarPose {
        switch mood {
        case .sleeping: AvatarPose(lookY: 0.2, open: 0)
        case .listening: AvatarPose()
        case .working: AvatarPose(lookY: 0.1, orbit: 0.6)
        case .waiting: AvatarPose(lookY: -0.3, pulse: 1)
        case .happy: AvatarPose(lookY: -0.1)
        case .error: AvatarPose(lookY: 0.35)
        }
    }
}

enum AvatarPainter {
    static func draw(_ context: inout GraphicsContext, size: CGSize, look: AvatarLook, mood: AvatarMood, pose: AvatarPose) {
        let side = min(size.width, size.height)
        let radius = side * 0.4
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + side * 0.03 + pose.lift * radius)
        if mood == .sleeping { context.opacity = 0.72 }

        // Спутник кружит вокруг работающего агента: полвитка — за телом.
        let satellite = satellitePosition(center: center, side: side, angle: pose.orbit)
        if mood == .working, !satellite.front { drawSatellite(&context, at: satellite.point, side: side, look: look, dimmed: true) }
        if look.accessory == .ring { drawRing(&context, center: center, radius: radius, look: look, front: false) }

        let stretch = pose.stretch
        let body = Path(ellipseIn: CGRect(
            x: center.x - radius * (1 - (stretch - 1) * 0.57), y: center.y - radius * stretch,
            width: 2 * radius * (1 - (stretch - 1) * 0.57), height: 2 * radius * stretch
        ))
        context.fill(body, with: .color(look.shade))
        // Освещённая сторона: круг, сдвинутый к свету; остаётся тёмный серп справа внизу.
        context.drawLayer { layer in
            layer.clip(to: body)
            let lit = CGRect(x: center.x - radius * 1.36, y: center.y - radius * 1.34, width: 2.1 * radius, height: 2.1 * radius)
            layer.fill(Path(ellipseIn: lit), with: .color(look.lit))
            for crater in craters(seed: look.seed) {
                let r = radius * crater.radius
                let point = CGPoint(x: center.x + crater.x * radius, y: center.y + crater.y * radius)
                layer.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)), with: .color(look.shade.opacity(0.45)))
            }
        }

        drawEyes(&context, center: center, radius: radius, look: look, mood: mood, pose: pose)
        switch look.accessory {
        case .none: break
        case .ring: drawRing(&context, center: center, radius: radius, look: look, front: true)
        case .cap: drawCap(&context, center: center, radius: radius)
        case .glasses: drawGlasses(&context, center: center, radius: radius, look: look)
        }

        if mood == .working, satellite.front { drawSatellite(&context, at: satellite.point, side: side, look: look, dimmed: false) }
        if let badge = badgeColor(mood) {
            context.opacity = 1
            let r = side * (0.13 + 0.025 * pose.pulse)
            let point = CGPoint(x: size.width / 2 + radius * 0.78, y: size.height / 2 - radius * 0.7)
            let dot = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: dot.insetBy(dx: -side * 0.035, dy: -side * 0.035)), with: .color(.black))
            context.fill(Path(ellipseIn: dot), with: .color(badge))
        }
    }

    private static func drawEyes(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, look: AvatarLook, mood: AvatarMood, pose: AvatarPose) {
        let ink = GraphicsContext.Shading.color(look.ink)
        let stroke = StrokeStyle(lineWidth: max(1, radius * 0.13), lineCap: .round)
        for sign in [-1.0, 1.0] as [CGFloat] {
            let eye = CGPoint(
                x: center.x + sign * radius * 0.32 + pose.lookX * radius * 0.17,
                y: center.y - radius * 0.04 + pose.lookY * radius * 0.15
            )
            let half = radius * 0.17
            if mood == .happy {
                // Радость — дужки «^ ^».
                var arc = Path()
                arc.move(to: CGPoint(x: eye.x - half, y: eye.y + half * 0.5))
                arc.addQuadCurve(to: CGPoint(x: eye.x + half, y: eye.y + half * 0.5), control: CGPoint(x: eye.x, y: eye.y - half * 1.5))
                context.stroke(arc, with: ink, style: stroke)
            } else if pose.open < 0.2 {
                // Закрытые глаза — дужки вниз.
                var arc = Path()
                arc.move(to: CGPoint(x: eye.x - half, y: eye.y))
                arc.addQuadCurve(to: CGPoint(x: eye.x + half, y: eye.y), control: CGPoint(x: eye.x, y: eye.y + half * 1.1))
                context.stroke(arc, with: ink, style: stroke)
            } else {
                let open = mood == .error ? pose.open * 0.55 : pose.open
                let height = max(radius * 0.1, radius * 0.44 * open * (mood == .waiting ? 1.15 : 1))
                let width = radius * 0.22
                let rect = CGRect(x: eye.x - width / 2, y: eye.y - height / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: ink)
            }
        }
    }

    /// Кольцо, как у Сатурна: дальняя половина рисуется до тела, ближняя — поверх.
    private static func drawRing(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, look: AvatarLook, front: Bool) {
        let tilt: CGFloat = -0.3
        var arc = Path()
        for step in 0...24 {
            // В экранных координатах y растёт вниз: нижняя половина эллипса — ближняя.
            let angle = (front ? 0 : CGFloat.pi) + CGFloat.pi * CGFloat(step) / 24
            let x = cos(angle) * radius * 1.2
            let y = sin(angle) * radius * 0.36
            let point = CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + radius * 0.12 + x * sin(tilt) + y * cos(tilt))
            if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
        }
        let width = max(1, radius * 0.12)
        if front {
            // Тёмная кайма отделяет кольцо от светлого тела; на чёрном фоне острова её не видно.
            context.stroke(arc, with: .color(look.ink.opacity(0.55)), style: StrokeStyle(lineWidth: width * 2, lineCap: .butt, lineJoin: .round))
        }
        context.stroke(arc, with: .color(.white.opacity(front ? 1 : 0.45)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// Ночной колпак набекрень: околыш по макушке, конус свисает вправо, на конце помпон.
    private static func drawCap(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x * radius, y: center.y + y * radius) }
        var cone = Path()
        cone.move(to: point(-0.74, -0.62))
        cone.addQuadCurve(to: point(0.1, -1.16), control: point(-0.5, -1.2))
        cone.addQuadCurve(to: point(0.98, -0.5), control: point(0.86, -1.14))
        cone.addQuadCurve(to: point(0.62, -0.74), control: point(0.74, -0.8))
        cone.addQuadCurve(to: point(-0.74, -0.62), control: point(0, -1.0))
        context.fill(cone, with: .color(Color(hue: 0.66, saturation: 0.6, brightness: 0.82)))

        var band = Path()
        band.move(to: point(-0.76, -0.6))
        band.addQuadCurve(to: point(0.66, -0.7), control: point(-0.02, -1.02))
        context.stroke(band, with: .color(.white), style: StrokeStyle(lineWidth: max(1.2, radius * 0.2), lineCap: .round))

        let pom = radius * 0.17
        let tip = point(0.98, -0.44)
        context.fill(Path(ellipseIn: CGRect(x: tip.x - pom, y: tip.y - pom, width: 2 * pom, height: 2 * pom)), with: .color(.white))
    }

    /// Круглые очки: оправа стоит на месте, глаза двигаются за стёклами. Оправа цветная —
    /// иначе она сливается с глазами того же тёмного тона.
    private static func drawGlasses(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, look: AvatarLook) {
        let lens = radius * 0.31
        var frame = Path()
        for sign in [-1.0, 1.0] as [CGFloat] {
            let eye = CGPoint(x: center.x + sign * radius * 0.37, y: center.y - radius * 0.02)
            frame.addEllipse(in: CGRect(x: eye.x - lens, y: eye.y - lens, width: 2 * lens, height: 2 * lens))
        }
        context.fill(frame, with: .color(.white.opacity(0.28)))
        frame.move(to: CGPoint(x: center.x - radius * 0.06, y: center.y - radius * 0.06))
        frame.addLine(to: CGPoint(x: center.x + radius * 0.06, y: center.y - radius * 0.06))
        context.stroke(
            frame, with: .color(Color(hue: 0.03, saturation: 0.75, brightness: 0.62)),
            style: StrokeStyle(lineWidth: max(1, radius * 0.09), lineCap: .round)
        )
    }

    private static func drawSatellite(_ context: inout GraphicsContext, at point: CGPoint, side: CGFloat, look: AvatarLook, dimmed: Bool) {
        let r = side * 0.055
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
            with: .color(look.lit.opacity(dimmed ? 0.45 : 1))
        )
    }

    /// Наклонённая орбита; `front` — спутник перед телом.
    private static func satellitePosition(center: CGPoint, side: CGFloat, angle: CGFloat) -> (point: CGPoint, front: Bool) {
        let x = cos(angle) * side * 0.46
        let y = sin(angle) * side * 0.15
        let tilt: CGFloat = -0.32
        return (CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + x * sin(tilt) + y * cos(tilt)), sin(angle) >= 0)
    }

    private static func badgeColor(_ mood: AvatarMood) -> Color? {
        switch mood {
        case .waiting: .orange
        case .error: .red
        case .happy: .green
        case .sleeping, .listening, .working: nil
        }
    }

    /// Два-три кратера на освещённой стороне; положение — от зерна внешности.
    static func craters(seed: UInt64) -> [(x: CGFloat, y: CGFloat, radius: CGFloat)] {
        var state = seed | 1
        func next() -> CGFloat {
            // xorshift64: детерминированная последовательность из зерна.
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return CGFloat(state % 1000) / 1000
        }
        return (0..<(2 + Int(next() * 2))).map { _ in
            let angle = CGFloat.pi * (0.55 + next() * 0.7)
            let distance = 0.55 + next() * 0.25
            return (cos(angle) * distance, sin(angle) * distance * -1, 0.09 + next() * 0.08)
        }
    }
}
