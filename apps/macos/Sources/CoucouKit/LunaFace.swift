import SwiftUI
import CoreGraphics

/// Лицо Luna: форма глаз для всех `EyeShape`. Одни и те же очертания рисуют остров,
/// гардероб, приветствие и загрузка файла — каждый своим контекстом (`GraphicsContext` или
/// `CGContext`), поэтому форма описана путями, а не вызовами рисования.
///
/// Ось Y вниз, начало — центр глаза, `w`/`h` — ширина и высота глаза в точках.
enum LunaFace {

    /// Чем красить: чернилами тела, сердцем или звездой (у них свой цвет).
    enum Tone { case ink, heart, star }

    struct Glyph {
        var fills: [CGPath] = []
        var strokes: [(path: CGPath, width: CGFloat)] = []
        var tone: Tone = .ink
    }

    static let heartColor = (r: CGFloat(1.0), g: CGFloat(0.302), b: CGFloat(0.427))   // #FF4D6D
    static let starColor  = (r: CGFloat(0.969), g: CGFloat(0.702), b: CGFloat(0.169)) // #F7B32B

    /// Очертания глаза. `open` — раскрытие века (мигание), `sd` — -1 левый, +1 правый,
    /// `time` — секунды: крутят спираль и звезду.
    static func glyph(_ shape: EyeShape, w: CGFloat, h: CGFloat,
                      open: CGFloat = 1, sd: CGFloat = 1, time: CGFloat = 0) -> Glyph {
        var g = Glyph()
        switch shape {
        case .wide:
            return glyph(.pill, w: w * 1.16, h: h * 1.12, open: open, sd: sd, time: time)

        case .pill:
            // Овал-«фонарик»: при моргании сплющивается, но не тоньше трети ширины.
            let hh = max(h * open, w * 0.34)
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: -w / 2, y: -hh / 2, width: w, height: hh))
            g.fills = [p]

        case .dot:
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: -w * 0.45, y: -w * 0.45, width: w * 0.9, height: w * 0.9))
            g.fills = [p]

        case .line:
            // Недовольство: пологая дуга, концы наклонены к носу.
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -w * 0.8, y: -w * 0.05))
            p.addQuadCurve(to: CGPoint(x: w * 0.8, y: -w * 0.05), control: CGPoint(x: 0, y: w * 0.42))
            var t = CGAffineTransform(rotationAngle: -sd * 0.2)
            g.strokes = [(p.copy(using: &t) ?? p, w * 0.34)]

        case .flat:
            // Усталость или ошибка: ровная чёрточка, внешние концы чуть ниже.
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -w * 0.7, y: 0))
            p.addLine(to: CGPoint(x: w * 0.7, y: 0))
            var t = CGAffineTransform(rotationAngle: sd * 0.16)
            g.strokes = [(p.copy(using: &t) ?? p, w * 0.34)]

        case .happy:
            // Радость: полумесяц рогами вниз.
            let r = w * 0.85
            g.fills = [LunaLook.crescent(r1: r, biteOffset: CGPoint(x: 0, y: w * 0.42), biteRadius: r,
                                         center: CGPoint(x: 0, y: h * 0.12))]

        case .closed:
            // Сон: полумесяц рогами вверх, как лодочка.
            let r = w * 0.8
            g.fills = [LunaLook.crescent(r1: r, biteOffset: CGPoint(x: 0, y: -w * 0.4), biteRadius: r,
                                         center: CGPoint(x: 0, y: -h * 0.08))]

        case .spiral:
            let p = CGMutablePath()
            var a: CGFloat = 0
            while a < 4.4 * .pi {
                let r = w * 0.06 + a * w * 0.058
                let aa = a + time * 9 * sd
                let pt = CGPoint(x: cos(aa) * r, y: sin(aa) * r)
                if a == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                a += 0.2
            }
            g.strokes = [(p, w * 0.22)]

        case .heart:
            g.fills = [heart(size: w * 1.2)]
            g.tone = .heart

        case .star:
            var t = CGAffineTransform(rotationAngle: time * 1.5 * sd)
            let s = LunaLook.sparkle(outer: w * 1.15, waist: 0.2)
            g.fills = [s.copy(using: &t) ?? s]
            g.tone = .star

        case .tired:
            // Полуприкрытый глаз: нижняя половина овала под тяжёлым веком.
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -w * 0.5, y: -h * 0.02))
            p.addLine(to: CGPoint(x: w * 0.5, y: -h * 0.02))
            p.addQuadCurve(to: CGPoint(x: -w * 0.5, y: -h * 0.02), control: CGPoint(x: 0, y: h * 0.72))
            p.closeSubpath()
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: -w * 0.64, y: -h * 0.12))
            lid.addLine(to: CGPoint(x: w * 0.64, y: -h * 0.12))
            g.fills = [p]
            g.strokes = [(lid, w * 0.2)]

        case .wink:
            return sd < 0
                ? glyph(.pill, w: w, h: h, open: open, sd: sd, time: time)
                : glyph(.happy, w: w, h: h, open: open, sd: sd, time: time)

        case .cup:
            // Плоский верх, круглый низ: чашка, в которую падает письмо.
            let hh = max(h * open, w * 0.3)
            let cr = min(w / 2, hh / 2)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -w / 2, y: -hh / 2))
            p.addLine(to: CGPoint(x: w / 2, y: -hh / 2))
            p.addLine(to: CGPoint(x: w / 2, y: hh / 2 - cr))
            p.addQuadCurve(to: CGPoint(x: w / 2 - cr, y: hh / 2), control: CGPoint(x: w / 2, y: hh / 2))
            p.addLine(to: CGPoint(x: -w / 2 + cr, y: hh / 2))
            p.addQuadCurve(to: CGPoint(x: -w / 2, y: hh / 2 - cr), control: CGPoint(x: -w / 2, y: hh / 2))
            p.closeSubpath()
            g.fills = [p]
        }
        return g
    }

    private static func heart(size s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: s * 0.38))
        p.addCurve(to: CGPoint(x: 0, y: -s * 0.38),
                   control1: CGPoint(x: -s * 1.05, y: -s * 0.15),
                   control2: CGPoint(x: -s * 0.5, y: -s * 0.95))
        p.addCurve(to: CGPoint(x: 0, y: s * 0.38),
                   control1: CGPoint(x: s * 0.5, y: -s * 0.95),
                   control2: CGPoint(x: s * 1.05, y: -s * 0.15))
        p.closeSubpath()
        return p
    }

    // MARK: Рисование

    /// Рисует глаз в `GraphicsContext`. `halo` > 0 — ширина мягкого свечения вокруг глаза.
    static func render(_ g: Glyph, in ctx: inout GraphicsContext, ink: Color, halo: CGFloat = 0) {
        let color: Color
        switch g.tone {
        case .ink:   color = ink
        case .heart: color = Color(red: heartColor.r, green: heartColor.g, blue: heartColor.b)
        case .star:  color = Color(red: starColor.r, green: starColor.g, blue: starColor.b)
        }
        let fillGlow = g.tone == .ink ? halo : 0
        for f in g.fills {
            let p = Path(f)
            if fillGlow > 0 {
                ctx.stroke(p, with: .color(color.opacity(0.2)),
                           style: StrokeStyle(lineWidth: fillGlow, lineCap: .round, lineJoin: .round))
            }
            ctx.fill(p, with: .color(color))
        }
        for s in g.strokes {
            let p = Path(s.path)
            if fillGlow > 0 {
                ctx.stroke(p, with: .color(color.opacity(0.2)),
                           style: StrokeStyle(lineWidth: s.width + fillGlow, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(p, with: .color(color),
                       style: StrokeStyle(lineWidth: s.width, lineCap: .round, lineJoin: .round))
        }
    }

    /// То же в `CGContext` (приветствие рисует им). Начало координат уже сдвинуто в центр глаза.
    static func render(_ g: Glyph, in cg: CGContext, ink: CGColor, halo: CGFloat = 0) {
        let color: CGColor
        switch g.tone {
        case .ink:   color = ink
        case .heart: color = CGColor(red: heartColor.r, green: heartColor.g, blue: heartColor.b, alpha: 1)
        case .star:  color = CGColor(red: starColor.r, green: starColor.g, blue: starColor.b, alpha: 1)
        }
        let fillGlow = g.tone == .ink ? halo : 0
        let soft = color.copy(alpha: 0.2) ?? color
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for f in g.fills {
            if fillGlow > 0 {
                cg.addPath(f); cg.setStrokeColor(soft); cg.setLineWidth(fillGlow); cg.strokePath()
            }
            cg.addPath(f); cg.setFillColor(color); cg.fillPath()
        }
        for s in g.strokes {
            if fillGlow > 0 {
                cg.addPath(s.path); cg.setStrokeColor(soft); cg.setLineWidth(s.width + fillGlow); cg.strokePath()
            }
            cg.addPath(s.path); cg.setStrokeColor(color); cg.setLineWidth(s.width); cg.strokePath()
        }
    }
}
