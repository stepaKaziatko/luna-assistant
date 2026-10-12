import CoreGraphics

/// Облик Luna: форма тела, палитра и украшения в одном месте.
///
/// Персонаж рисуется в нескольких местах (`BotEngine`, наряды, приветствие, загрузка файла,
/// значки гардероба, лист кадров). Числа формы и цвета берутся отсюда, чтобы они не
/// расходились. Файл не зависит от SwiftUI и AppKit: его собирают и тесты, и iOS-таргеты.
///
/// Облик — «ночной малыш»: вертикальное «яйцо», сине-фиолетовое тело, светящиеся глаза
/// цвета сливок, над головой полумесяц и звёздочка.
enum LunaLook {

    // MARK: Форма

    /// Полуоси тела в долях R. Яйцо выше, чем шире (прежний облик был шире, чем выше).
    static let rxK: CGFloat = 0.86
    static let ryK: CGFloat = 1.04
    /// Показатель суперэллипса: |x/rx|^n + |y/ry|^n = 1. 2 — эллипс, больше — «квадратнее».
    static let exponent: CGFloat = 2.4
    /// Отношение ширины тела к высоте.
    static var aspect: CGFloat { rxK / ryK }

    /// Суперэллипс с заданными полуосями и показателем.
    static func superellipse(rx: CGFloat, ry: CGFloat,
                             exponent n: CGFloat = LunaLook.exponent,
                             steps: Int = 96) -> CGPath {
        let e = 2 / n
        let p = CGMutablePath()
        for i in 0...steps {
            let a = CGFloat(i) / CGFloat(steps) * .pi * 2
            let ca = cos(a), sa = sin(a)
            let x = rx * (ca >= 0 ? pow(ca, e) : -pow(-ca, e))
            let y = ry * (sa >= 0 ? pow(sa, e) : -pow(-sa, e))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    // MARK: Палитра

    typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

    /// Тело: от лунного синего сверху-справа к ночному фиолетовому снизу-слева.
    static let bodyTop: RGB    = (0.46, 0.52, 0.86)   // #7585DB
    static let bodyBottom: RGB = (0.17, 0.20, 0.46)   // #2B3375
    /// Серединный цвет тела: для плоских заливок (мини-Luna без цвета агента, значки).
    static let bodyMidHex = "#4A5499"
    /// Глаза: тёплый кремовый, светятся на тёмном теле.
    static let glow: RGB = (1.0, 0.949, 0.769)        // #FFF2C4
    /// Глаза на светлом теле (цвет агента у мини-Luna, тыква): тёмные чернила.
    static let ink: RGB = (0.063, 0.075, 0.133)       // #101322
    /// Полумесяц и звёздочка над головой.
    static let charm: RGB = (1.0, 0.929, 0.620)       // #FFED9E
    /// Румянец: холодный, звёздная пыль, а не розовый.
    static let blush: RGB = (0.72, 0.78, 1.0)
    /// Контур света у рук и значков.
    static let rim: RGB = (1.0, 0.949, 0.769)

    /// Светлота цвета (0…1): по ней выбирают, какие глаза на теле читаются.
    static func luminance(_ c: RGB) -> CGFloat { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    /// На телах светлее этого порога глаза рисуются тёмными, на остальных — светящимися.
    static let darkInkThreshold: CGFloat = 0.42

    // MARK: Украшения над головой

    /// Полумесяц: внешний круг без «укуса». Координаты — ось Y вниз, центр — центр круга.
    static func crescent(r1: CGFloat, biteOffset: CGPoint, biteRadius r2: CGFloat,
                         center: CGPoint = .zero) -> CGPath {
        let d = hypot(biteOffset.x, biteOffset.y)
        let p = CGMutablePath()
        guard d > 0.0001, d < r1 + r2, d > abs(r1 - r2) else {
            p.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
            return p
        }
        let theta = atan2(biteOffset.y, biteOffset.x)
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)       // от центра внешнего круга до хорды
        let phi = acos(max(-1, min(1, a / r1)))            // половина угла хорды у внешнего круга
        let omega = acos(max(-1, min(1, (d - a) / r2)))    // то же у круга «укуса»
        let n = 28
        // Дальняя от «укуса» дуга внешнего круга.
        for i in 0...n {
            let t = theta + phi + CGFloat(i) / CGFloat(n) * (2 * .pi - 2 * phi)
            let pt = CGPoint(x: center.x + r1 * cos(t), y: center.y + r1 * sin(t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        // Обратно по ближней к центру дуге круга «укуса».
        for i in 0...n {
            let t = theta + .pi + omega - CGFloat(i) / CGFloat(n) * 2 * omega
            p.addLine(to: CGPoint(x: center.x + biteOffset.x + r2 * cos(t),
                                  y: center.y + biteOffset.y + r2 * sin(t)))
        }
        p.closeSubpath()
        return p
    }

    /// Четырёхлучевая звёздочка ✦ с вогнутыми гранями.
    static func sparkle(outer o: CGFloat, waist: CGFloat = 0.16) -> CGPath {
        let c = o * waist
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -o))
        p.addQuadCurve(to: CGPoint(x: o, y: 0), control: CGPoint(x: c, y: -c))
        p.addQuadCurve(to: CGPoint(x: 0, y: o), control: CGPoint(x: c, y: c))
        p.addQuadCurve(to: CGPoint(x: -o, y: 0), control: CGPoint(x: -c, y: c))
        p.addQuadCurve(to: CGPoint(x: 0, y: -o), control: CGPoint(x: -c, y: -c))
        p.closeSubpath()
        return p
    }

    /// Положение и размеры полумесяца и звёздочки в координатах тела (ось Y вниз,
    /// начало — центр тела, `R` — базовый радиус).
    struct Charm {
        let moonCenter: CGPoint
        let moonRadius: CGFloat
        let moonTilt: CGFloat
        let starCenter: CGPoint
        let starRadius: CGFloat

        /// Самая высокая точка украшений над центром тела (положительное число).
        var reach: CGFloat {
            max(-(moonCenter.y - moonRadius), -(starCenter.y - starRadius))
        }
    }

    static func charm(R: CGFloat) -> Charm {
        Charm(moonCenter: CGPoint(x: R * 0.34, y: -R * ryK * 1.05),
              moonRadius: R * 0.26,
              moonTilt: 0.35,
              starCenter: CGPoint(x: -R * 0.18, y: -R * (ryK + 0.12)),
              starRadius: R * 0.13)
    }

    /// Путь полумесяца в координатах тела.
    static func moonPath(_ c: Charm) -> CGPath {
        let r = c.moonRadius
        let bite = crescent(r1: r, biteOffset: CGPoint(x: r * 0.55, y: -r * 0.15), biteRadius: r)
        var t = CGAffineTransform(translationX: c.moonCenter.x, y: c.moonCenter.y).rotated(by: c.moonTilt)
        return bite.copy(using: &t) ?? bite
    }

    /// Путь звёздочки в координатах тела.
    static func starPath(_ c: Charm) -> CGPath {
        var t = CGAffineTransform(translationX: c.starCenter.x, y: c.starCenter.y)
        let s = sparkle(outer: c.starRadius)
        return s.copy(using: &t) ?? s
    }
}
