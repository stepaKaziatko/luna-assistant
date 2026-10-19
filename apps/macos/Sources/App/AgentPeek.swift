import Foundation
import CoreGraphics

// MARK: - Block under the cursor
//
// Hold the cursor on the resting island and the same black figure grows downward into a block:
// counters and a tile for every urgent agent. This file is the part of it that needs no window:
// when the block may appear and go away (`AgentPeekPolicy`, time given by the caller) and where
// everything in it lies (`AgentPeekLayout`, one geometry for the drawing and for the clicks).
// Tested by `scripts/test-agent-peek.sh`.
//
// The block takes no focus and no keys. A click in it is read by the window controller from the
// layout below and never reaches the panel, so the app the person works in stays the active one.

// MARK: - Policy

/// When the block shows and hides. A value: the window controller feeds it on every tick of the
/// pointer poll it already runs, so it adds no timer of its own.
struct AgentPeekPolicy: Equatable {

    /// The pointer must stay on the island this long before the block grows.
    static let showDelay: TimeInterval = 0.45
    /// The pointer must stay off the figure (the block included) this long before it folds.
    static let hideDelay: TimeInterval = 0.5

    /// What the policy reads on a tick.
    struct Context: Equatable {
        /// The pointer is on the figure: the resting island, or the island with the block.
        var pointerOver = false
        /// The island rests as the compact one (not hidden, not open).
        var restingCompact = false
        /// Sessions of every kind the block could show.
        var sessions = 0
        /// "Open on hover" is on: hovering opens the whole island, the block is not needed.
        var openOnHover = false
        /// Luna is being dragged off the island.
        var dragging = false
        /// The voice mode runs.
        var listening = false
        /// A request card waits: the island already says it.
        var requestPending = false
    }

    private(set) var visible = false
    private var overSince: Date?
    private var awaySince: Date?
    /// After a click or an opening the block does not come back until the pointer has left.
    private var suppressed = false

    /// Whether the block may be on screen at all, whatever the pointer does.
    static func allowed(_ c: Context) -> Bool {
        c.restingCompact && c.sessions >= 1 && !c.openOnHover && !c.dragging
            && !c.listening && !c.requestPending
    }

    /// One tick. Returns whether `visible` changed.
    @discardableResult
    mutating func update(_ c: Context, now: Date) -> Bool {
        let before = visible
        guard Self.allowed(c) else {
            visible = false
            overSince = nil
            awaySince = nil
            // The pointer may stay where it is: coming back to an allowed island is a fresh entry.
            suppressed = c.pointerOver && suppressed
            return before != visible
        }
        if suppressed {
            if !c.pointerOver { suppressed = false }
            return false
        }
        if visible {
            overSince = nil
            if c.pointerOver {
                awaySince = nil
            } else {
                let since = awaySince ?? now
                awaySince = since
                if now.timeIntervalSince(since) >= Self.hideDelay {
                    visible = false
                    awaySince = nil
                }
            }
        } else {
            awaySince = nil
            if c.pointerOver {
                let since = overSince ?? now
                overSince = since
                if now.timeIntervalSince(since) >= Self.showDelay {
                    visible = true
                    overSince = nil
                }
            } else {
                overSince = nil
            }
        }
        return before != visible
    }

    /// A click, or the island opened: the block goes at once and waits for the pointer to leave.
    mutating func dismiss() {
        visible = false
        overSince = nil
        awaySince = nil
        suppressed = true
    }
}

// MARK: - Layout

/// What a click in the block landed on.
enum AgentPeekHit: Equatable {
    /// The tile at this index of `AgentNotchSummary.tiles`.
    case tile(Int)
    /// "All agents".
    case allAgents
}

/// Sizes and places of the block. Coordinates are those of the figure: origin at its top left,
/// y down. The strip at the top is the resting island itself; the block lies under it.
struct AgentPeekLayout: Equatable {

    /// The tallest the whole figure with the block may be, the strip included.
    static let maxHeight: CGFloat = 170
    static let minBlockWidth: CGFloat = 340

    static let side: CGFloat = 8
    static let gap: CGFloat = 6
    static let topPadding: CGFloat = 2
    static let counterHeight: CGFloat = 22
    static let tileHeight: CGFloat = 42
    static let bottomPadding: CGFloat = 8
    static let allAgentsWidth: CGFloat = 92
    static let columns = 2

    /// The height of the resting island (the notch's height, or the bar's).
    let stripHeight: CGFloat
    /// The width of the resting figure: the block is never narrower.
    let restingWidth: CGFloat
    /// Tiles drawn, the "+N" one included.
    let cells: Int

    init(stripHeight: CGFloat, restingWidth: CGFloat, cells: Int) {
        self.stripHeight = stripHeight
        self.restingWidth = restingWidth
        self.cells = max(1, min(cells, AgentNotchSummary.maxTiles))
    }

    /// Not narrower than the resting figure (it grows out of it), and wide enough for two tiles.
    var width: CGFloat { max(restingWidth, Self.minBlockWidth) }

    var rows: Int { (cells + Self.columns - 1) / Self.columns }

    var height: CGFloat {
        stripHeight + Self.topPadding + Self.counterHeight + Self.gap
            + CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.gap + Self.bottomPadding
    }

    var tileWidth: CGFloat { (width - 2 * Self.side - Self.gap) / CGFloat(Self.columns) }

    var counterRow: CGRect {
        CGRect(x: Self.side, y: stripHeight + Self.topPadding,
               width: width - 2 * Self.side, height: Self.counterHeight)
    }

    var allAgentsButton: CGRect {
        CGRect(x: width - Self.side - Self.allAgentsWidth, y: counterRow.minY,
               width: Self.allAgentsWidth, height: Self.counterHeight)
    }

    func tileFrame(_ index: Int) -> CGRect {
        let row = index / Self.columns, col = index % Self.columns
        let top = counterRow.maxY + Self.gap
        return CGRect(x: Self.side + CGFloat(col) * (tileWidth + Self.gap),
                      y: top + CGFloat(row) * (Self.tileHeight + Self.gap),
                      width: tileWidth, height: Self.tileHeight)
    }

    /// The block itself: the part of the figure under the strip.
    var blockArea: CGRect {
        CGRect(x: 0, y: stripHeight, width: width, height: height - stripHeight)
    }

    /// What lies under a point of the figure; nil for the empty part of the block and for
    /// the strip (a click there is a click on the island).
    func hit(at point: CGPoint) -> AgentPeekHit? {
        guard blockArea.contains(point) else { return nil }
        if allAgentsButton.contains(point) { return .allAgents }
        for i in 0..<cells where tileFrame(i).contains(point) { return .tile(i) }
        return nil
    }
}
