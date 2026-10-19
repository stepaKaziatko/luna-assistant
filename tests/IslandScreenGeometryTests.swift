import Foundation

@main
enum IslandScreenGeometryTests {
    static func main() {
        // Regression: absent auxiliary areas must never mean "screen-wide notch".
        for screenWidth: CGFloat in [1080, 1920, 2560, 3840] {
            let geometry = IslandScreenGeometry(
                screenWidth: screenWidth, safeAreaTop: 0,
                auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 30
            )
            precondition(!geometry.hasNotch)
            precondition(geometry.width == 80)
            precondition(geometry.height == 24)
        }

        // A shorter menu bar must also contain the resting island.
        let shortMenuBar = IslandScreenGeometry(
            screenWidth: 1920, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 22
        )
        precondition(shortMenuBar.height == 22)

        // Real MacBook notch measurements retain their physical dimensions.
        let macBook = IslandScreenGeometry(
            screenWidth: 1512, safeAreaTop: 32,
            auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660, menuBarHeight: 32
        )
        precondition(macBook.hasNotch)
        precondition(macBook.width == 192 && macBook.height == 32)

        // Incomplete or invalid measurements use the notch fallback, not the screen.
        for auxiliaryWidth: CGFloat? in [nil, 0, 1000] {
            let geometry = IslandScreenGeometry(
                screenWidth: 1512, safeAreaTop: 32,
                auxiliaryLeftWidth: auxiliaryWidth, auxiliaryRightWidth: auxiliaryWidth,
                menuBarHeight: 32
            )
            precondition(geometry.width == 184 && geometry.height == 32)
        }
        // Compact/greeting destinations share the measured resting height.
        for height: CGFloat in [22, 24, 32, 38] {
            let compact = IslandRestingLayout(width: 240, height: height)
            precondition(compact.botCenterY == height / 2)
            precondition(compact.botDiameter == min(20, height - 6))
            precondition(compact.botCenterY - compact.botDiameter / 2 >= 3)
            precondition(compact.botCenterY + compact.botDiameter / 2 <= height - 3)
            precondition(compact.miniGridCenterX == 200)
            precondition(compact.miniGridScale * 28 <= height - 4)
        }
        // The block under the cursor grows the figure, not the strip: what sits in the strip is
        // computed from the strip, so it is the same with the block and without it.
        for (nw, strip): (CGFloat, CGFloat) in [(184, 32), (192, 32), (200, 38), (184, 38), (80, 24)] {
            let bare = IslandRestingLayout.compact(notchWidth: nw, stripHeight: strip)
            precondition(bare.width == nw + 160, "compact figure without the block is the notch and two wings")
            precondition(IslandRestingLayout.compactWidth(notchWidth: nw) == nw + 160)
            // The same call is made while the block is open: the strip height is what is passed.
            let withBlock = IslandRestingLayout.compact(notchWidth: nw, stripHeight: strip)
            precondition(withBlock.botCenterY == bare.botCenterY && withBlock.botCenterY == strip / 2)
            precondition(withBlock.botDiameter == bare.botDiameter)
            precondition(withBlock.miniGridScale == bare.miniGridScale)
            precondition(withBlock.miniGridCenterX == bare.miniGridCenterX && bare.miniGridCenterX == nw + 160 - 40)
            // A layout wrongly fed the figure's height with the block would move Luna to its middle.
            let wrong = IslandRestingLayout(width: bare.width, height: strip + 120)
            precondition(wrong.botCenterY != bare.botCenterY)
        }
        // On a screen without a notch the bar is 80 wide: compact is 240 and the minis shrink by the strip.
        let bar = IslandRestingLayout.compact(notchWidth: 80, stripHeight: 24)
        precondition(bar.width == 240 && bar.miniGridScale == 20.0 / 28.0 && bar.botCenterY == 12)
        print("Island screen geometry, resting layout and strip under the block: all cases passed")
    }
}
