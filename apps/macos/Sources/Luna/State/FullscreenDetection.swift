import CoreGraphics

// Определение полноэкранного режима перенесено из capa-the-notch 0.3.1
// (`Sources/CapacityNotchCore/FullscreenDetection.swift`, https://github.com/maximfakel/capa-the-notch),
// с переводом комментариев и разбором записи списка окон.
//
// MIT License. Copyright (c) 2026 Capacity Notch contributors.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of
// the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

/// Окно на экране так, как его описывает `CGWindowListCopyWindowInfo` без разрешения на запись экрана:
/// уровень, владелец и рамка в координатах списка окон (начало — верхний левый угол главного экрана, y вниз).
struct ScreenWindow: Equatable {
    var level: Int
    var owner: String
    var bounds: CGRect

    /// Запись списка окон; nil — запись чужого формата или окно самой Luna (`ownPID`).
    init?(info: [String: Any], ownPID: Int) {
        guard (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
              let level = info[kCGWindowLayer as String] as? Int,
              // В живом списке рамка — `NSDictionary`, в фикстурах — словарь Swift.
              let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
        else { return nil }
        self.init(level: level, owner: info[kCGWindowOwnerName as String] as? String ?? "", bounds: bounds)
    }

    init(level: Int, owner: String, bounds: CGRect) {
        self.level = level
        self.owner = owner
        self.bounds = bounds
    }
}

/// Показывает ли экран острова полноэкранное приложение. Чистая функция по списку окон.
///
/// Измерено автором образца на macOS 26.6. Полноэкранное окно занимает экран во всю ширину и достаёт до низа,
/// начинаясь у верхнего края или под вырезом, — одно или вместе с другими окнами своего приложения. Развёрнутое
/// окно может так же. Чего развёрнутое окно не может — убрать рабочий стол: у полноэкранного Space нет ни обоев,
/// ни значков рабочего стола, а у обычного есть хотя бы что-то одно. Dock и Window Server держат окна на уровнях
/// рабочего стола в обоих случаях, поэтому не считаются; на macOS 27 то, что держал Dock, держит WindowManager.
enum FullscreenDetection {
    private static let keepersOfDesktopLevels: Set = ["Dock", "WindowManager", "Window Server"]

    /// `screen` — рамка экрана в координатах списка окон, `menuBarHeight` — высота полосы у верхнего края,
    /// `desktopIconLevel` — `CGWindowLevelForKey(.desktopIconWindow)`.
    static func isFullscreen(windows: [ScreenWindow], screen: CGRect, menuBarHeight: CGFloat, desktopIconLevel: Int) -> Bool {
        let onScreen = windows.filter { $0.bounds.intersects(screen) }

        // Окна одного приложения во всю ширину, сложенные одно под другим от верха до низа. Полноэкранный Chrome —
        // не одно окно: полоса вкладок, панель и страница — отдельные окна, и ни одно не занимает экран целиком.
        // Спрашивается только ширина, а не место: при смене Space все окна съезжают вбок, последние точки —
        // за полсекунды (macOS 27.0), и полноэкранное окно на полпути — всё ещё полноэкранное.
        let spanning = Dictionary(grouping: onScreen.filter { window in
            window.level == 0 && window.bounds.width >= screen.width
        }, by: \.owner)
        let covered = spanning.values.contains { windows in
            var reached = screen.minY + menuBarHeight + 1
            for window in windows.sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
                guard window.bounds.minY <= reached else { break }
                reached = max(reached, window.bounds.maxY)
            }
            return reached >= screen.maxY
        }
        guard covered else { return false }

        // Обои и значки тоже съезжают со своим Space и стоят в начале экрана, только когда он встал на место;
        // уезжающие — это покидаемый рабочий стол, а не показанный.
        let desktopShows = onScreen.contains { window in
            window.level <= desktopIconLevel
                && !keepersOfDesktopLevels.contains(window.owner)
                && window.bounds.origin == screen.origin
        }
        return !desktopShows
    }

    /// Рамка экрана в координатах списка окон: AppKit отсчитывает y от низа главного экрана, список окон —
    /// от его верха.
    static func displayRect(screen: CGRect, mainScreen: CGRect) -> CGRect {
        CGRect(x: screen.minX, y: mainScreen.maxY - screen.maxY, width: screen.width, height: screen.height)
    }
}
