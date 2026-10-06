import AppKit

/// Полоса у верхнего края экрана и вырез камеры в ней: от них остров ставится на экран.
/// Чистые числа без `NSScreen` — тестируются без экрана. Замысел — `NotchGeometry` из capa-the-notch 0.3.1 (MIT),
/// код написан заново.
struct NotchGeometry: Equatable {
    /// Ширина выреза; 0 — выреза нет.
    var notchWidth: CGFloat
    /// Высота полосы у верхнего края: вырез на MacBook, строка меню на остальных экранах.
    var barHeight: CGFloat
    /// Середина выреза по x в координатах экрана; без выреза — середина экрана.
    var centerX: CGFloat

    var hasNotch: Bool { notchWidth > 0 }

    init(notchWidth: CGFloat, barHeight: CGFloat, centerX: CGFloat) {
        self.notchWidth = notchWidth
        self.barHeight = barHeight
        self.centerX = centerX
    }

    /// Геометрия по данным экрана. `auxiliaryTopLeft` и `auxiliaryTopRight` — области строки меню слева и справа
    /// от выреза (nil — выреза нет), `menuBarThickness` — `NSStatusBar.system.thickness`: высота полосы, когда
    /// строку меню экрана не узнать (скрывается автоматически, полноэкранный режим).
    init(
        frame: NSRect, visibleFrame: NSRect, safeAreaTop: CGFloat,
        auxiliaryTopLeft: NSRect?, auxiliaryTopRight: NSRect?, menuBarThickness: CGFloat
    ) {
        if safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight, left.width > 0, right.width > 0 {
            let width = frame.width - 2 * left.width
            // Бессмысленные области (шире половины экрана, наложились друг на друга) — считаем, что выреза нет.
            if width > 0, width < frame.width, left.maxX <= right.minX {
                self.init(notchWidth: width, barHeight: safeAreaTop, centerX: (left.maxX + right.minX) / 2)
                return
            }
        }
        let menuBar = frame.maxY - visibleFrame.maxY
        self.init(notchWidth: 0, barHeight: menuBar > 0 ? menuBar : menuBarThickness, centerX: frame.midX)
    }

    /// Экран без выреза: полоса заданной высоты, середина — середина экрана. Нужна debug-подмене.
    static func flat(frame: NSRect, barHeight: CGFloat) -> NotchGeometry {
        NotchGeometry(notchWidth: 0, barHeight: barHeight, centerX: frame.midX)
    }
}

extension NSScreen {
    /// Геометрия выреза и полосы этого экрана, считанная заново.
    var notchGeometry: NotchGeometry {
        NotchGeometry(
            frame: frame, visibleFrame: visibleFrame, safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeft: auxiliaryTopLeftArea, auxiliaryTopRight: auxiliaryTopRightArea,
            menuBarThickness: NSStatusBar.system.thickness
        )
    }
}
