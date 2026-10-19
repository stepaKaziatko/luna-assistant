import Foundation
import CoreGraphics

// MARK: - Agents in the notch
//
// What the resting island ("the notch") says about the agents: one count per kind of news, the
// kind that wins, and the little Luna of the right wing, one per session. A pure function of
// `[AgentSessionInfo]` (`AppState.agentSessions`): nothing is stored here, so nothing can go stale,
// and the same file is tested without a window (`scripts/test-agent-notch.sh`).
//
// "News" is what the person may need to look at: a session that waits for them, one that failed,
// one that finished a turn they have not looked at yet (`AgentRank.finishedUnseen`), and, as the
// weakest, one that works. A session that is open and quiet is no news: it lives on the Agents page
// and in the block under the cursor, not on the notch.

/// One place on the notch or in the block under the cursor: a session, or "and N more".
enum AgentNotchCell: Equatable, Sendable {
    case session(AgentSessionInfo)
    case more(Int)

    /// A stable identity for a view: the session's, or one for the "+N" cell.
    var id: String {
        switch self {
        case .session(let s): return s.id
        case .more:           return "more"
        }
    }
}

/// Where the little Luna of the right wing stand. The wing is a 28 × 28 box (a cell is 12 pt and
/// the gap 4) centred on `IslandRestingLayout.miniGridCenterX`; a few of them are not pushed into
/// the corner of an empty 2 × 2 grid but centred.
enum AgentWing {
    /// Offsets of the centres of `count` cells from the centre of the box, in order: the most
    /// urgent first (top left). 0 to 4 cells; more are clamped to four.
    static func offsets(count: Int) -> [CGPoint] {
        let d: CGFloat = 8
        switch min(max(count, 0), 4) {
        case 0:  return []
        case 1:  return [CGPoint(x: 0, y: 0)]
        case 2:  return [CGPoint(x: -d, y: 0), CGPoint(x: d, y: 0)]
        case 3:  return [CGPoint(x: -d, y: -d), CGPoint(x: d, y: -d), CGPoint(x: 0, y: d)]
        default: return [CGPoint(x: -d, y: -d), CGPoint(x: d, y: -d), CGPoint(x: -d, y: d), CGPoint(x: d, y: d)]
        }
    }
}

struct AgentNotchSummary: Equatable, Sendable {

    /// Cells in the right wing. More agents than this: `maxMinis - 1` sessions and a "+N" cell.
    static let maxMinis = 4
    /// Tiles in the block under the cursor, the "+N" tile included.
    static let maxTiles = 4

    // Counts by rank. `finishedUnseen` is a turn that ended and has not been looked at; a
    // finished turn that has been seen is quiet.
    let waiting: Int
    let error: Int
    let finishedUnseen: Int
    let working: Int
    /// Open sessions with no news. Not part of the notch, but the block shows them.
    let quiet: Int

    /// The kind of news that wins: waits for you, then a failure, then a finished turn, then work.
    /// Nil when nothing but quiet sessions (or none) are there. The only place the priority is written.
    let dominant: AgentRank?

    /// The session the notch Luna takes her mood from: the first one of the dominant kind.
    let lead: AgentSessionInfo?

    /// The wing: sessions with news in the order of the Agents page, at most `maxMinis` cells.
    let minis: [AgentNotchCell]

    /// The block under the cursor: every session (quiet ones too), at most `maxTiles` cells.
    let tiles: [AgentNotchCell]

    init(_ sessions: [AgentSessionInfo]) {
        // The book already hands the sessions over in display order (rank, then order of
        // appearance); sorting the same way keeps the result right for any other order too.
        let ordered = sessions.enumerated()
            .sorted { a, b in
                if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
                if a.element.firstSeen != b.element.firstSeen { return a.element.firstSeen < b.element.firstSeen }
                return a.offset < b.offset
            }
            .map(\.element)

        var waiting = 0, error = 0, finished = 0, working = 0, quiet = 0
        for s in ordered {
            switch s.rank {
            case .waiting:        waiting += 1
            case .error:          error += 1
            case .finishedUnseen: finished += 1
            case .working:        working += 1
            case .quiet:          quiet += 1
            }
        }
        self.waiting = waiting
        self.error = error
        self.finishedUnseen = finished
        self.working = working
        self.quiet = quiet

        if waiting > 0 { dominant = .waiting }
        else if error > 0 { dominant = .error }
        else if finished > 0 { dominant = .finishedUnseen }
        else if working > 0 { dominant = .working }
        else { dominant = nil }
        lead = dominant.flatMap { rank in ordered.first { $0.rank == rank } }

        let news = ordered.filter { $0.rank != .quiet }
        minis = Self.cells(news, limit: Self.maxMinis)
        tiles = Self.cells(ordered, limit: Self.maxTiles)
    }

    /// All of them when they fit, otherwise `limit - 1` and a cell for the rest.
    private static func cells(_ sessions: [AgentSessionInfo], limit: Int) -> [AgentNotchCell] {
        guard sessions.count > limit else { return sessions.map { .session($0) } }
        return sessions.prefix(limit - 1).map { .session($0) } + [.more(sessions.count - (limit - 1))]
    }

    // MARK: Reading

    /// Sessions of the notch's kinds of news.
    var newsCount: Int { waiting + error + finishedUnseen + working }

    /// Every open session, quiet ones too.
    var total: Int { newsCount + quiet }

    /// News that keeps the notch on screen (the island does not fold to its hidden size on a
    /// timer): someone waits, failed, or finished and was not looked at. Work alone does not.
    var holdsNotch: Bool { waiting + error + finishedUnseen > 0 }

    /// The text of a "+N" cell in the wing: a digit, "9+" above nine.
    static func moreDigits(_ n: Int) -> String { n > 9 ? "9+" : "\(n)" }

    /// One line for the log when the summary changes, not per frame. `minis` counts the cells of
    /// the wing ("+N" included).
    var logLine: String {
        "notch: waiting=\(waiting) error=\(error) finished=\(finishedUnseen) working=\(working) minis=\(minis.count)"
    }
}
