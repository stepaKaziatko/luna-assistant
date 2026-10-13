import Foundation
import CoreGraphics

// MARK: - Desktop space

/// One y-down space for the whole desktop, like Quartz: x as in AppKit, y measured down
/// from the top of the menu-bar screen. The cursor and every Luna (island or desktop)
/// use it, so the gaze stays right whichever screen each one sits on.
enum DesktopSpace {
    static func topDown(_ appKitPoint: CGPoint, desktopTop: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: desktopTop - appKitPoint.y)
    }
}

// MARK: - Alert state machine phase

/// Phase of the desktop Luna lifecycle.
enum DesktopPhase: Equatable {
    /// No panel on screen; `UserDefaults["mochiOnDesktop"]` is `false`.
    case home
    /// Panel animating from notch to saved desktop position.
    case flyingOut
    /// Panel live on the desktop — normal operating state.
    case onDesktop
    /// `pendingApproval`/`pendingQuestion` just went non-nil; panel animating toward notch.
    case retracting
    /// Alert cleared while retract animation was still running.
    case alertResolvedDuringRetract
    /// Retract complete; notch Luna is showing the alert.
    case atNotchForAlert
}

// MARK: - Pure geometry / logic (no AppKit — fully unit-testable)

/// Stateless helpers for `DesktopMochiController`.
enum DesktopMochiLogic {
    static let panelSize:          CGFloat      = 120
    static let sleepTimeout:       TimeInterval = 120
    static let sleepMouseDistance: CGFloat      = 150
    static let clampMargin:        CGFloat      = 24
    /// Полуоси видимого тела в долях панели: R = 0.3·панель, тело — яйцо LunaLook.
    /// Зона клика на 8 % меньше тела, чтобы промах у края не шлёпал Luna.
    static let bodyHalfWidthFraction:  CGFloat  = LunaLook.rxK * 0.3 * 0.92
    static let bodyHalfHeightFraction: CGFloat  = LunaLook.ryK * 0.3 * 0.92

    /// Whether Luna should enter sleeping state.
    static func shouldSleep(lastAgentActiveInterval: TimeInterval,
                             mouseDistanceToPanelCenter: CGFloat) -> Bool {
        lastAgentActiveInterval > sleepTimeout && mouseDistanceToPanelCenter >= sleepMouseDistance
    }

    /// Hit-test the egg-shaped body inside a square panel (AppKit y-up local coords).
    /// The body is a superellipse, the test is its inscribed ellipse: clicks land on the
    /// visible body and not on the corners of the panel.
    static func isOverBody(localPoint: CGPoint, panelSize: CGFloat) -> Bool {
        let cx = panelSize / 2
        let cy = panelSize / 2
        let a  = panelSize * bodyHalfWidthFraction
        let b  = panelSize * bodyHalfHeightFraction
        let dx = (localPoint.x - cx) / a
        let dy = (localPoint.y - cy) / b
        return dx * dx + dy * dy <= 1
    }

    /// Eye-tracking origin: panel center in `DesktopSpace`, the coordinate space of
    /// `AppState.mousePosition`.
    static func lookOrigin(panelMinX:  CGFloat,
                           panelMinY:  CGFloat,
                           desktopTop: CGFloat,
                           panelSize:  CGFloat) -> CGPoint {
        DesktopSpace.topDown(CGPoint(x: panelMinX + panelSize / 2, y: panelMinY + panelSize / 2),
                             desktopTop: desktopTop)
    }

    /// Whether Luna should immediately retract after landing (alert was active during the flight).
    static func shouldRetractOnLanding(alertActive: Bool) -> Bool { alertActive }

    /// Clamp a panel origin so the panel stays inside `visibleFrame` with `margin` on each side.
    static func clampOrigin(_ origin:      CGPoint,
                             panelSize:    CGFloat,
                             visibleFrame: CGRect,
                             margin:       CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visibleFrame.minX + margin), visibleFrame.maxX - panelSize - margin),
            y: min(max(origin.y, visibleFrame.minY + margin), visibleFrame.maxY - panelSize - margin)
        )
    }
}
