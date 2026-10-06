import CoreGraphics

/// Где стоит остров: геометрия выреза его экрана и поправка на округление окна. AppKit ставит рамку окна
/// в целые точки, и середина окна может разойтись с серединой выреза на полточки: `correction` —
/// `notch.centerX − panel.frame.midX`, на неё сдвигается фигура внутри окна.
struct IslandPlacement: Equatable {
    var notch: NotchGeometry
    var correction: CGFloat

    /// До первой расстановки: экран без выреза со строкой меню обычной высоты.
    static let unplaced = IslandPlacement(notch: NotchGeometry(notchWidth: 0, barHeight: 24, centerX: 0), correction: 0)
}

/// Естественные ширины крыльев pill — их замеряет вид (`PillView`); 0 — крыло пустое.
struct PillWings: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
}

/// Раскладка свёрнутого острова — чистые числа, тестируются без окна.
///
/// С вырезом: левое крыло (Luna и фраза), промежуток ровно шириной с вырез, правое крыло (счётчики и аватары
/// сессий). Крылья шириной по содержимому, поэтому тело может стоять несимметрично относительно выреза.
/// Без выреза: оба крыла одной строкой по центру псевдо-острова. Покой — та же раскладка без событий:
/// тело чуть шире выреза (или псевдо-остров), высотой с полосу.
struct IslandLayout: Equatable {
    /// Запас покоя с каждой стороны выреза; крыло не уже него.
    static let restMargin: CGFloat = 10
    /// Ширина стандартного выреза: по ней — псевдо-остров на экране без выреза.
    static let standardNotchWidth: CGFloat = 185
    /// Самое широкое крыло: фраза до 220 pt с аватаром Luna, счётчики с четырьмя аватарами и «+N».
    static let maxWing: CGFloat = 270
    /// Самый широкий вырез, под который окно pill помещается в окно раскрытого острова.
    static let maxNotchWidth: CGFloat = 250

    var leftWing: CGFloat
    /// Промежуток между крыльями: ширина выреза, без выреза — 0.
    var gap: CGFloat
    var rightWing: CGFloat
    /// Тело фигуры без плеч.
    var body: CGSize
    /// Сдвиг середины тела от середины выреза по x: крылья разной ширины.
    var bodyOffset: CGFloat
    /// Высота строки содержимого и размеры элементов — под полосу.
    var rowHeight: CGFloat
    var lunaAvatar: CGFloat
    var sessionAvatar: CGFloat
    var chipFont: CGFloat

    /// `left`, `right` — естественные ширины крыльев, 0 — крыло пустое (или событий нет: покой).
    static func make(notchWidth: CGFloat, barHeight: CGFloat, left: CGFloat = 0, right: CGFloat = 0) -> IslandLayout {
        let notch = max(0, notchWidth)
        let bar = max(0, barHeight)
        let leftWing = clampWing(left)
        let rightWing = clampWing(right)
        let width: CGFloat
        let offset: CGFloat
        if notch > 0 {
            width = leftWing + notch + rightWing
            offset = (rightWing - leftWing) / 2
        } else {
            // Одна строка по центру, не уже псевдо-острова в покое.
            width = max(standardNotchWidth + 2 * restMargin, leftWing + rightWing)
            offset = 0
        }
        return IslandLayout(
            leftWing: leftWing, gap: notch, rightWing: rightWing,
            body: CGSize(width: width, height: bar), bodyOffset: offset,
            rowHeight: min(28, bar),
            // На полосе MacBook (32–38) — как раньше, на строке меню (22–24) — меньше.
            lunaAvatar: max(10, min(22, bar - 6)),
            sessionAvatar: max(10, min(20, bar - 8)),
            chipFont: max(9, min(11, (bar - 4) / 2))
        )
    }

    private static func clampWing(_ natural: CGFloat) -> CGFloat {
        min(maxWing, max(restMargin, natural))
    }
}
