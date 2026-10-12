import Foundation
import SwiftUI
import AppKit

// Кадровый тест персонажа: рисует настоящий BotEngine через ImageRenderer и проверяет кадры.
// Зелёные тесты логики ничего не говорят о том, что персонаж нарисован верно; этот говорит.
// Сеть и upstream не нужны.

private let canvas: CGFloat = 200          // кадр 200 × 200 pt, R = 0.3 · 200 = 60
private let margin: CGFloat = 4            // запас от края кадра
private var failures: [String] = []

private func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { failures.append(message()) }
}

// MARK: - Кадр

struct Pixels {
    let w: Int, h: Int
    var rgba: [UInt8]

    func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * w + x) * 4 + 3] }

    /// Количество непрозрачных точек и охватывающий прямоугольник (в точках кадра).
    var coverage: (count: Int, bounds: CGRect) {
        var minX = w, minY = h, maxX = -1, maxY = -1, n = 0
        for y in 0..<h { for x in 0..<w where alpha(x, y) > 24 {
            n += 1
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard n > 0 else { return (0, .zero) }
        return (n, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// Сколько точек отличаются от другого кадра заметно (по любому каналу или по альфе).
    func differences(from other: Pixels) -> Int {
        var n = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(rgba[i + c]) - Int(other.rgba[i + c]))) }
            if d > 24 { n += 1 }
        }
        return n
    }

    /// Средний цвет непрозрачных точек (0…1).
    var meanColor: (r: Double, g: Double, b: Double) {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 200 {
            r += Double(rgba[i]); g += Double(rgba[i + 1]); b += Double(rgba[i + 2]); n += 1
        }
        guard n > 0 else { return (0, 0, 0) }
        return (r / n / 255, g / n / 255, b / n / 255)
    }
}

@MainActor
private func rasterize<V: View>(_ view: V, size: CGFloat) -> Pixels? {
    let renderer = ImageRenderer(content: view.frame(width: size, height: size))
    renderer.scale = 1
    guard let cg = renderer.cgImage else { return nil }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Pixels(w: w, h: h, rgba: buf)
}

/// Один кадр движка в заданной позе, как его рисует остров (все четыре прохода).
struct EngineFrame: View {
    var state: BotState = .idle
    var outfit: Outfit = .none
    var yaw: CGFloat = 0
    var pitch: CGFloat = 0
    var eye: EyeShape? = nil
    var mini = false
    var miniHex: String? = nil

    var body: some View {
        Canvas { ctx, size in
            let e = BotEngine()
            e.isMini = mini
            if let hx = miniHex { e.bodyColor = Color(hex: hx).testCGColor }
            e.nextBlink = .greatestFiniteMagnitude
            e.miniNextBehavior = .greatestFiniteMagnitude
            e.setState(state, force: true)
            e.col = e.cfg.color.testTuple
            e.tint = e.cfg.tint
            e.badge = e.cfg.badge
            e.badgeS = e.cfg.badge == nil ? 0 : 1
            e.yaw = yaw; e.pitch = pitch; e.tilt = e.cfg.tilt
            if let eye { e.eyeOverride = eye; e.eyeOverrideUntil = .greatestFiniteMagnitude }
            if outfit != .none { e.outfit = outfit; e.outfitPresence = 1 }
            e.drawHandsBehind(context: ctx, size: size)
            e.drawOutfitBehind(context: ctx, size: size)
            e.draw(context: ctx, size: size)
            e.drawOutfitFront(context: ctx, size: size)
            e.drawHandsAndExtras(context: ctx, size: size)
        }
    }
}

extension Color { var testCGColor: CGColor { NSColor(self).cgColor } }
extension CGColor {
    var testTuple: (CGFloat, CGFloat, CGFloat) {
        let c = NSColor(cgColor: self)!.usingColorSpace(.sRGB)!
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
}

/// Только рисунок глаза, без тела: проверяет, что очертания не пустые.
struct GlyphFrame: View {
    let shape: EyeShape
    var body: some View {
        Canvas { ctx, size in
            var c = ctx
            c.translateBy(x: size.width / 2, y: size.height / 2)
            let g = LunaFace.glyph(shape, w: 40, h: 48, open: 1, sd: 1, time: 0.4)
            LunaFace.render(g, in: &c, ink: .white, halo: 12)
        }
    }
}

// MARK: - Проверки

@MainActor
private func runChecks() {
    let R = canvas * 0.3

    // Без отрисовки не бывает кадрового теста: если рендер недоступен, падаем явно.
    guard let probe = rasterize(EngineFrame(), size: canvas) else {
        failures.append("ImageRenderer не отдал кадр: проверка отрисовки невозможна")
        return
    }
    let base = probe.coverage
    check(base.count > 2000, "кадр покоя пуст или почти пуст: \(base.count) точек")

    // 1. Тело непустое и укладывается в холст с запасом, для всех 11 состояний.
    for state in BotState.allCases {
        guard let px = rasterize(EngineFrame(state: state), size: canvas) else {
            failures.append("нет кадра для \(state)"); continue
        }
        let cov = px.coverage
        check(cov.count > 2000, "\(state): тело не нарисовано (\(cov.count) точек)")
        let inside = CGRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
        check(inside.contains(cov.bounds), "\(state): кадр вылезает за холст с запасом \(margin) pt: \(cov.bounds)")
        // Яйцо выше, чем шире: тело плюс полумесяц над головой — не квадрат.
        check(cov.bounds.height > cov.bounds.width * 1.05,
              "\(state): силуэт не вытянут по вертикали: \(cov.bounds.size)")
    }

    // 2. Наряды: кадр с нарядом отличается от кадра без него в четырёх позах.
    let poses: [(String, CGFloat, CGFloat)] = [("front", 0, 0), ("L", -0.5, 0), ("R", 0.5, 0), ("up", 0.15, 0.4)]
    let outfits = Outfit.allCases.filter { $0 != .auto && $0 != .none }
    check(outfits.count == 11, "ожидалось 11 нарядов, найдено \(outfits.count)")
    for (poseName, yaw, pitch) in poses {
        guard let bare = rasterize(EngineFrame(yaw: yaw, pitch: pitch), size: canvas) else {
            failures.append("нет кадра без наряда (\(poseName))"); continue
        }
        for outfit in outfits {
            guard let dressed = rasterize(EngineFrame(outfit: outfit, yaw: yaw, pitch: pitch), size: canvas) else {
                failures.append("нет кадра \(outfit) (\(poseName))"); continue
            }
            let diff = dressed.differences(from: bare)
            check(diff > 150, "\(outfit) в позе \(poseName) не отличается от кадра без наряда (\(diff) точек)")
        }
    }

    // 3. Глаза лежат внутри тела (геометрией: охватывающий прямоугольник со свечением).
    let body = LunaLook.superellipse(rx: R * LunaLook.rxK, ry: R * LunaLook.ryK)
    let allEyes: [EyeShape] = [.pill, .wide, .dot, .line, .flat, .happy, .closed, .spiral,
                               .heart, .star, .tired, .wink, .cup]
    check(allEyes.count == 13, "форм глаз должно быть 13")
    // Поворот головы до 0.25 рад: дальше глаз уходит за край и обрезается телом по замыслу.
    for (yaw, pitch) in [(CGFloat(0), CGFloat(0)), (0.25, -0.15), (-0.25, 0.2)] {
        let frames = mEyeFrames(MochiH(R: R, yaw: yaw, pitch: pitch)).filter { $0.visible }
        check(!frames.isEmpty, "ни одного видимого глаза при yaw \(yaw)")
        for f in frames {
            for shape in allEyes {
                let ew = R * MochiConst.eyeW, eh = R * MochiConst.eyeH
                let g = LunaFace.glyph(shape, w: ew, h: eh, open: 1, sd: f.sd, time: 0.4)
                var box = CGRect.null
                for p in g.fills { box = box.union(p.boundingBoxOfPath) }
                for s in g.strokes { box = box.union(s.path.boundingBoxOfPath.insetBy(dx: -s.width / 2, dy: -s.width / 2)) }
                guard !box.isNull else { continue }
                box = box.insetBy(dx: -ew * 0.15, dy: -ew * 0.15)   // свечение
                var corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                               CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
                if shape == .star || shape == .spiral {
                    // Вращается: вписанный круг, а не углы охватывающего квадрата.
                    let r = max(box.width, box.height) / 2
                    corners = [CGPoint(x: box.midX + r, y: box.midY), CGPoint(x: box.midX - r, y: box.midY),
                               CGPoint(x: box.midX, y: box.midY + r), CGPoint(x: box.midX, y: box.midY - r)]
                }
                for c in corners {
                    let p = CGPoint(x: f.x + c.x * f.fx, y: f.y + c.y * f.fy)
                    check(body.contains(p), "глаз \(shape) выходит за тело (yaw \(yaw), sd \(f.sd)): \(p)")
                }
            }
        }
    }

    // 4. Каждая из 13 форм глаза даёт непустой рисунок.
    for shape in allEyes {
        guard let px = rasterize(GlyphFrame(shape: shape), size: 120) else {
            failures.append("нет кадра глаза \(shape)"); continue
        }
        check(px.coverage.count > 40, "глаз \(shape) не нарисован (\(px.coverage.count) точек)")
        // и в составе персонажа кадр с этим глазом отличается от кадра с закрытыми
        if let withEye = rasterize(EngineFrame(eye: shape), size: canvas),
           let other = rasterize(EngineFrame(eye: shape == .dot ? .wide : .dot), size: canvas), shape != .dot, shape != .wide {
            check(withEye.differences(from: other) > 20, "глаз \(shape) не меняет кадр персонажа")
        }
    }

    // 5. Мини-Luna: цвет агента виден, формы совпадают с главным персонажем по высоте тела.
    if let red = rasterize(EngineFrame(mini: true, miniHex: "#E86A6A"), size: canvas),
       let blue = rasterize(EngineFrame(mini: true, miniHex: "#3E86E0"), size: canvas) {
        let a = red.meanColor, b = blue.meanColor
        let d = sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2))
        check(d > 0.25, "мини-Luna разных агентов почти не различаются по цвету (\(d))")
        check(a.r > a.b, "мини-Luna красного агента не красная")
        let h = red.coverage.bounds.height
        check(abs(h - 2 * R * LunaLook.ryK) < 6, "высота мини-тела \(h) не совпадает с яйцом \(2 * R * LunaLook.ryK)")
    } else {
        failures.append("нет кадров мини-Luna")
    }

    // 6. Состояния читаются: у каждого состояния с оттенком кадр отличается от покоя.
    for state in [BotState.working, .thinking, .approval, .error, .finished, .ratelimit, .dizzy] {
        if let idle = rasterize(EngineFrame(state: .idle), size: canvas),
           let px = rasterize(EngineFrame(state: state), size: canvas) {
            check(px.differences(from: idle) > 500, "\(state) почти не отличается от покоя")
        }
    }
}

@main
enum CharacterFrameTests {
    @MainActor
    static func main() {
        runChecks()
        if failures.isEmpty {
            print("CharacterFrameTests: all cases passed")
        } else {
            for f in failures { FileHandle.standardError.write(Data(("FAIL: " + f + "\n").utf8)) }
            exit(1)
        }
    }
}
