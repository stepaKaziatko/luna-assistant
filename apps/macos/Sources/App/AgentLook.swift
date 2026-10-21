import Foundation

// Вынесено из AgentTile.swift без AppKit и SwiftUI, чтобы вид плитки (рамка, аватар, статус)
// проверялся без окна (`scripts/test-agent-notch.sh`).

// MARK: - Look of a tile

/// Colours and words of a tile, apart from the view so the page and the tile agree.
enum AgentLook {
    static let waiting = "#F5A524"
    static let finished = "#34D399"
    static let error = "#F4505E"
    static let working = "#3B9EFF"

    /// The accent of the tile's frame, nil for a quiet tile.
    static func accentHex(_ s: AgentSessionInfo) -> String? {
        switch s.rank {
        case .waiting:        return waiting
        case .error:          return error
        case .finishedUnseen: return finished
        case .working:        return working
        case .quiet:          return nil
        }
    }

    /// The state of the little Luna on the tile.
    static func botState(_ s: AgentSessionInfo) -> BotState {
        if let wait = s.wait {
            switch wait {
            case .permission: return .approval
            case .question:   return .question
            }
        }
        if s.rateLimited { return .ratelimit }
        switch s.phase {
        case .idle:     return .idle
        case .working:  return .working
        // Зелёная метка «готово» — пока ход не просмотрен; просмотренный аватар спокоен.
        case .finished: return s.finishedUnseen ? .finished : .idle
        case .error:    return .error
        case .stopped:  return .idle
        }
    }

    /// Whether the little Luna moves: one that works, waits or has failed. A finished or
    /// idle one is a still picture.
    static func isLively(_ s: AgentSessionInfo) -> Bool {
        s.wait != nil || s.phase == .working || s.phase == .error
    }

    static func symbol(_ kind: AgentStepKind) -> String {
        switch kind {
        case .prompt:  return "text.bubble"
        case .read:    return "doc.text"
        case .edit:    return "pencil"
        case .shell:   return "terminal"
        case .search:  return "magnifyingglass"
        case .web:     return "globe"
        case .agent:   return "person.2"
        case .plan:    return "checklist"
        case .mcp:     return "puzzlepiece.extension"
        case .failure: return "exclamationmark.triangle"
        case .message: return "questionmark.bubble"
        case .other:   return "wrench.and.screwdriver"
        }
    }

    /// "5 min. ago", "just now".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "agents.time.now", defaultValue: "now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// The line under the steps: what the session is doing, or waiting for.
    static func status(_ s: AgentSessionInfo, now: Date) -> String {
        if let wait = s.wait {
            switch wait {
            case .permission(let tool):
                return String(localized: "agents.status.waiting-permission",
                              defaultValue: "Waiting: permission \(tool)")
            case .question:
                return String(localized: "agents.status.waiting-question", defaultValue: "Waiting: question")
            }
        }
        switch s.phase {
        case .working:
            if s.rateLimited { return String(localized: "agents.status.rate-limit", defaultValue: "Rate limit") }
            return s.steps.last(where: { $0.kind != .prompt })?.text
                ?? String(localized: "agents.status.working", defaultValue: "Working")
        case .finished:
            return String(localized: "agents.status.finished",
                          defaultValue: "Turn finished · \(ago(s.since, now: now))")
        case .error:
            return String(localized: "agents.status.error", defaultValue: "Error · \(ago(s.since, now: now))")
        case .idle:
            return String(localized: "agents.status.idle", defaultValue: "Session open")
        case .stopped:
            return String(localized: "agents.status.stopped", defaultValue: "Stopped · \(ago(s.since, now: now))")
        }
    }
}
