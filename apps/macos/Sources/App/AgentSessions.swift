import Foundation

// MARK: - Agent sessions
//
// The model behind the "Agents" page of the island: one tile per live agent session.
// `PillSessionRegistry` answers a different question — what the pill of a client may do
// when a turn ends — and knows nothing about steps, phases or waiting. This file does,
// and it stays free of AppKit and SwiftUI so the whole behaviour is tested without a window
// (`scripts/test-agent-sessions.sh`).
//
// HookServer feeds it the same hook events it already handles (`AgentSessionBook.apply`),
// and derives "waits for you" from its own queues at the moment a snapshot is built:
// the flag is never stored, so it cannot outlive the request that raised it.

// MARK: - Key

/// A session is told apart by pill and session id: two `claude` under one VS Code are two sessions.
struct AgentSessionKey: Hashable, Sendable {
    let pill: String
    let session: String

    var id: String { "\(pill)|\(session)" }

    /// The key of the session an event, a permission request or a question came from.
    /// A client that sends no session id gets one from pill and cwd, as `RecapStore` does,
    /// so two anonymous sessions in different projects stay apart.
    static func make(pill: String, sessionId: String, cwd: String) -> AgentSessionKey {
        let unnamed = sessionId.isEmpty || sessionId == "unknown"
        return AgentSessionKey(pill: pill, session: unnamed ? "\(pill)+\(cwd)" : sessionId)
    }
}

// MARK: - Phase, steps, waiting

enum AgentPhase: String, Equatable, Sendable {
    /// The session is open and no turn is running.
    case idle
    case working
    /// A turn ended on its own.
    case finished
    case error
}

/// What a step is about, for its icon on the tile.
enum AgentStepKind: String, Equatable, Sendable {
    case prompt, read, edit, shell, search, web, agent, plan, mcp, failure, message, other

    /// The kind of a tool call by its name (Claude Code, Codex and the tools of other agents
    /// after the relay renamed them). Empty or unknown names give the generic kind.
    static func of(tool: String) -> AgentStepKind {
        switch tool {
        case "Read", "NotebookRead", "LS":                         return .read
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return .edit
        case "Bash":                                               return .shell
        case "Grep", "Glob":                                       return .search
        case "WebSearch", "WebFetch":                              return .web
        case "Task", "spawn_agent":                                return .agent
        case "TodoWrite", "update_plan":                           return .plan
        default:
            return tool.hasPrefix("mcp__") ? .mcp : .other
        }
    }
}

struct AgentStep: Equatable, Sendable {
    let kind: AgentStepKind
    let text: String
}

/// What the agent waits for the person to answer.
enum AgentWait: Equatable, Sendable {
    case permission(tool: String)
    case question
}

/// A permission request the app holds, as the preview page reads it. Only a view of
/// `HookServer.approvals`: the queue stays the one source of truth, and the page answers
/// through the same `sendApprovalDecision(_:for:)` the card uses.
struct AgentRequest: Equatable, Identifiable, Sendable {
    /// The id of the queued request: a decision is accepted for this id only.
    let id: UUID
    /// `AgentSessionKey.id` of the session that asks.
    let sessionKey: String
    let pill: String
    let tool: String
    /// The command or the tool name: what the card shows in its code block.
    let command: String
    /// 1-based place in the queue; 1 is the request on the card.
    let position: Int
    /// Requests waiting in total.
    let total: Int

    /// Only the head of the queue may be answered: the order of answers does not change.
    var isHead: Bool { position == 1 }
}

// MARK: - Hook events → phase

enum AgentTransition: Equatable, Sendable {
    case idle, working, finished, error
    /// The session is gone.
    case end
    /// The event does not move the phase.
    case none

    /// The phase an event leads to. `Notification` and the subagent events never move it:
    /// a notification is not a turn boundary, and a subagent finishing says nothing about
    /// the turn of the session that started it.
    static func of(event name: String) -> AgentTransition {
        switch name {
        case "SessionStart", "Interrupt":
            return .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
             "PermissionRequest", "Question":
            return .working
        case "Stop":
            return .finished
        case "StopFailure":
            return .error
        case "SessionEnd":
            return .end
        default:
            return .none
        }
    }
}

// MARK: - Who

/// What a tile says about the session; the hook server fills it per event.
struct AgentSessionWho: Equatable, Sendable {
    /// Project name; the agent's own name for a third-party agent (it sends no cwd).
    var project: String
    /// "Claude Code", "Codex"…
    var agent: String
    /// The app that hosts the session (a terminal, an editor): bundle id, empty when unknown.
    var hostBundleId: String = ""
    /// The working directory the agent reported, whatever the agent: the tile of a third-party
    /// agent carries the agent's name, but "go to the agent" still needs the folder. Empty when unknown.
    var cwd: String = ""
    /// The controlling terminal of the process that sent the hook (`/dev/ttys003`), found by Luna
    /// itself (`ProcessTTY`). Empty when unknown or not a valid device name.
    var tty: String = ""
}

// MARK: - Snapshot

/// One tile, as the page draws it. Equatable: a publish of an equal snapshot is skipped,
/// so an event that changes nothing visible costs the page nothing.
struct AgentSessionInfo: Equatable, Identifiable, Sendable {
    let key: AgentSessionKey
    let who: AgentSessionWho
    let phase: AgentPhase
    /// Set while the app holds a request of this session (permission or question).
    let wait: AgentWait?
    /// Up to `AgentSessionBook.maxSteps`, the newest last. The tile shows the last `tileSteps`.
    let steps: [AgentStep]
    /// The last answer of the agent, one short line.
    let finalLine: String?
    /// When the phase or the wait last changed: "turn ended 5 min ago" counts from here.
    let since: Date
    let firstSeen: Date
    /// A turn ended and the page has not been shown since: the tile stays green.
    let finishedUnseen: Bool
    let rateLimited: Bool

    var id: String { key.id }
    var pill: String { key.pill }

    /// The group the tile belongs to; the order and the counters follow it.
    var rank: AgentRank {
        if wait != nil { return .waiting }
        switch phase {
        case .error:    return .error
        case .finished: return finishedUnseen ? .finishedUnseen : .quiet
        case .working:  return .working
        case .idle:     return .quiet
        }
    }
}

/// Display order: the one that waits for you first.
enum AgentRank: Int, Comparable, Sendable {
    case waiting = 0, error, finishedUnseen, working, quiet

    static func < (a: AgentRank, b: AgentRank) -> Bool { a.rawValue < b.rawValue }
}

struct AgentsSummary: Equatable, Sendable {
    var waiting = 0
    var working = 0
    var finished = 0
    var errors = 0

    init(_ sessions: [AgentSessionInfo] = []) {
        for s in sessions {
            if s.wait != nil { waiting += 1; continue }
            switch s.phase {
            case .working:  working += 1
            case .finished: finished += 1
            case .error:    errors += 1
            case .idle:     break
            }
        }
    }

    var total: Int { waiting + working + finished + errors }
}

// MARK: - Default host

enum AgentHost {
    static let vsCode = "com.microsoft.VSCode"
    static let cursor = "com.todesktop.230313mzl4w4u92"

    /// The bundle id of the app a session lives in. A client that did not name its app
    /// (VS Code sends only `term_program`) is told by its pill.
    static func bundleId(pill: String, reported: String) -> String {
        if !reported.isEmpty { return reported }
        switch pill {
        case "integration_claude": return vsCode
        case "agent_cursor":       return cursor
        default:                   return ""
        }
    }
}

// MARK: - Book

/// Every live session of every pill. A value type: the hook server owns one copy and every
/// change goes through a `mutating` call.
struct AgentSessionBook: Sendable {

    /// Steps the book keeps for one session: the preview page shows them all.
    static let maxSteps = 20
    /// Steps on a tile.
    static let tileSteps = 5
    /// A turn that sends no event for this long lost its `Stop`: no longer "working".
    static let maxTurnSilence = PillSessionRegistry.maxTurnSilence
    /// A session between turns that is silent this long is gone: some agents never send
    /// `SessionEnd`, and their tiles must not pile up.
    static let maxIdleSilence: TimeInterval = 2 * 3600
    /// Nobody keeps a session without a word for this long.
    static let maxSilence = PillSessionRegistry.maxSilence
    /// Characters of a step or an answer on a tile.
    static let maxTextLength = 80

    private struct Record {
        var who: AgentSessionWho
        var phase: AgentPhase
        var steps: [AgentStep] = []
        var finalLine: String? = nil
        var firstSeen: Date
        var lastEvent: Date
        var since: Date
        var finishedUnseen = false
        var rateLimited = false
        var order: Int
    }

    private var records: [AgentSessionKey: Record] = [:]
    private var nextOrder = 0

    var isEmpty: Bool { records.isEmpty }

    // MARK: Recording

    /// Takes one hook event. `step` is the label of the step the event leads to (the hook
    /// server has it localized), `finalText` the answer of the agent on `Stop`, `message` the
    /// text of a `Notification`. A `Stop`, `StopFailure` or `Interrupt` of a session never heard
    /// of creates nothing: Luna may start in the middle of a session, and a session it only
    /// ever saw end owns no tile.
    mutating func apply(event name: String, key: AgentSessionKey, who: AgentSessionWho,
                        tool: String = "", step: String? = nil, finalText: String? = nil,
                        message: String = "", now: Date = Date()) {
        prune(now: now)
        let transition = AgentTransition.of(event: name)

        if transition == .end {
            records.removeValue(forKey: key)
            return
        }

        // A question is asked through its own hook: the card shows it, the tile must not
        // flicker with a step for it.
        if name == "PreToolUse", tool == "AskUserQuestion" {
            records[key]?.lastEvent = now
            return
        }

        let opens: Bool
        switch name {
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
             "PostToolUseFailure", "Notification", "PermissionRequest", "Question":
            opens = true
        default:
            opens = false
        }
        if records[key] == nil {
            guard opens else { return }
            records[key] = Record(who: who, phase: .idle, firstSeen: now, lastEvent: now,
                                  since: now, order: nextOrder)
            nextOrder += 1
        }
        guard var rec = records[key] else { return }
        let before = rec.phase

        // The name and the host follow the latest event; a missing host, folder or terminal
        // keeps the known one.
        rec.who = AgentSessionWho(
            project: who.project, agent: who.agent,
            hostBundleId: who.hostBundleId.isEmpty ? rec.who.hostBundleId : who.hostBundleId,
            cwd: who.cwd.isEmpty ? rec.who.cwd : who.cwd,
            tty: who.tty.isEmpty ? rec.who.tty : who.tty)
        rec.lastEvent = now

        switch transition {
        case .working:
            rec.phase = .working
            if name == "UserPromptSubmit" {
                rec.finalLine = nil
                rec.finishedUnseen = false
                rec.rateLimited = false
            }
            if before != .working { rec.finishedUnseen = false }
            if name == "PostToolUseFailure" {
                rec.steps.append(AgentStep(kind: .failure, text: step ?? "failed"))
            } else if let step, !step.isEmpty, name != "PostToolUse" {
                let kind: AgentStepKind = name == "UserPromptSubmit" ? .prompt : .of(tool: tool)
                rec.steps.append(AgentStep(kind: kind, text: Self.oneLine(step)))
            }
        case .finished:
            rec.phase = .finished
            rec.finishedUnseen = true
            rec.rateLimited = false
            let text = Self.oneLine(finalText ?? "")
            rec.finalLine = text.isEmpty ? nil : text
        case .error:
            rec.phase = .error
            rec.finishedUnseen = false
        case .idle:
            rec.phase = .idle
            rec.finishedUnseen = false
        case .none:
            Self.applyAuxiliary(name: name, step: step, message: message, to: &rec)
        case .end:
            break
        }

        if rec.steps.count > Self.maxSteps { rec.steps.removeFirst(rec.steps.count - Self.maxSteps) }
        if rec.phase != before { rec.since = now }
        records[key] = rec
    }

    /// `Notification` and the subagent events: they add a line or a flag, never a phase.
    private static func applyAuxiliary(name: String, step: String?, message: String, to rec: inout Record) {
        switch name {
        case "Notification":
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                rec.rateLimited = true
            } else if message.hasSuffix("?") {
                rec.steps.append(AgentStep(kind: .message, text: oneLine(message)))
            }
        case "SubagentStart", "SubagentStop":
            if let step, !step.isEmpty { rec.steps.append(AgentStep(kind: .agent, text: oneLine(step))) }
        default:
            break
        }
    }

    /// The page was shown: what finished before is no longer news. Returns whether anything changed.
    @discardableResult
    mutating func markFinishedSeen() -> Bool {
        var changed = false
        for key in records.keys where records[key]?.finishedUnseen == true {
            records[key]?.finishedUnseen = false
            changed = true
        }
        return changed
    }

    // MARK: Reading

    /// The tiles, in display order. `waits` is what the hook server holds right now.
    func snapshot(waits: [AgentSessionKey: AgentWait] = [:], now: Date = Date()) -> [AgentSessionInfo] {
        var list: [(info: AgentSessionInfo, order: Int)] = []
        for (key, rec) in records {
            let wait = waits[key]
            let silence = now.timeIntervalSince(rec.lastEvent)
            var phase = rec.phase
            if phase == .working, silence > Self.maxTurnSilence { phase = .idle }
            if wait == nil {
                if silence > Self.maxSilence { continue }
                if phase != .working, silence > Self.maxIdleSilence { continue }
            }
            // A session that stopped working by silence gets "since" of that moment, not of its last word.
            let since = (phase != rec.phase) ? rec.lastEvent.addingTimeInterval(Self.maxTurnSilence) : rec.since
            let info = AgentSessionInfo(
                key: key, who: rec.who, phase: phase, wait: wait,
                steps: rec.steps, finalLine: rec.finalLine, since: since,
                firstSeen: rec.firstSeen,
                finishedUnseen: rec.finishedUnseen && phase == .finished,
                rateLimited: rec.rateLimited)
            list.append((info, rec.order))
        }
        list.sort { a, b in
            if a.info.rank != b.info.rank { return a.info.rank < b.info.rank }
            // Order of appearance, not of the last event: tiles must not jump with every tool call.
            if a.info.firstSeen != b.info.firstSeen { return a.info.firstSeen < b.info.firstSeen }
            return a.order < b.order
        }
        return list.map(\.info)
    }

    // MARK: Pruning

    private mutating func prune(now: Date) {
        for (key, rec) in records {
            let silence = now.timeIntervalSince(rec.lastEvent)
            let working = rec.phase == .working && silence <= Self.maxTurnSilence
            if silence > Self.maxSilence || (!working && silence > Self.maxIdleSilence) {
                records.removeValue(forKey: key)
            }
        }
    }

    // MARK: Text

    /// One line, whitespace collapsed, cut to `maxTextLength`.
    static func oneLine(_ text: String, limit: Int = maxTextLength) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}
