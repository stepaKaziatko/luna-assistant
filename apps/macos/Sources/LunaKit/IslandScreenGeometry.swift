import Foundation

/// Resting island dimensions, using a physical notch only when the screen has one.
struct IslandScreenGeometry {
    static let fallbackNotchWidth: CGFloat = 184
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24

    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat,
         auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
         menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measuredWidth = screenWidth - left - right
                width = measuredWidth > 0 && measuredWidth < screenWidth
                    ? measuredWidth : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }
}

/// Shared by the compact view and the greeting's collapse destination.
///
/// `height` is the height of the resting strip (the notch's, or the bar's), never the height of
/// the figure: while the block under the cursor grows the figure downward, everything in the
/// strip (Luna, the minis) stays where it is.
struct IslandRestingLayout {
    /// Room on each side of the notch for Luna (left) and the minis (right).
    static let wing: CGFloat = 80

    /// The width of the compact figure: the notch and a wing on each side.
    static func compactWidth(notchWidth: CGFloat) -> CGFloat { notchWidth + 2 * wing }

    /// The layout of the compact island resting on a notch (or a bar) of this size.
    static func compact(notchWidth: CGFloat, stripHeight: CGFloat) -> IslandRestingLayout {
        IslandRestingLayout(width: compactWidth(notchWidth: notchWidth), height: stripHeight)
    }

    let width: CGFloat
    let height: CGFloat

    var botDiameter: CGFloat { min(20, max(0, height - 6)) }
    var botCenterY: CGFloat { height / 2 }
    var miniGridScale: CGFloat { min(1, max(0, height - 4) / 28) }
    var miniGridCenterX: CGFloat { width - 40 }
}
