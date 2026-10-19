import SwiftUI
import AppKit

// MARK: - Host apps

/// Name and icon of the app a session lives in (VS Code, Cursor, a terminal…), from its bundle
/// id through `NSWorkspace`: no permission is asked. Cached — the lookups touch the disk.
@MainActor
enum AgentHostApps {
    private static var icons: [String: NSImage?] = [:]
    private static var names: [String: String?] = [:]

    static func icon(for bundleId: String) -> NSImage? {
        if let cached = icons[bundleId] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleId] = .some(image)
        return image
    }

    static func name(for bundleId: String) -> String? {
        if let cached = names[bundleId] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        names[bundleId] = .some(name)
        return name
    }
}

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
        case .finished: return .finished
        case .error:    return .error
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
        }
    }
}

// MARK: - Tile

/// One agent session: Luna in the colour of the agent, project, agent and host app, the last
/// steps as icons (the newest on the right) and a status line. A frame says what it needs
/// from you: orange — it waits for you, green — a turn ended, red — an error.
struct AgentTile: View {
    let session: AgentSessionInfo
    /// Whether this tile may animate its Luna (the page caps the number of moving ones).
    let animated: Bool
    let selected: Bool
    let now: Date
    let onTap: () -> Void

    @State private var hovered = false

    private var accent: Color? { AgentLook.accentHex(session).map { Color(hex: $0) } }
    private var pillColor: String { PillCatalog.definition(for: session.pill)?.color ?? "#C0C4CC" }
    private var calm: Bool { session.rank == .quiet }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    avatar
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.who.project)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(1).truncationMode(.tail)
                        Text(session.who.agent)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 2)
                    hostIcon
                }
                HStack(spacing: 4) {
                    ForEach(Array(session.steps.suffix(AgentSessionBook.tileSteps).enumerated()), id: \.offset) { _, step in
                        Image(systemName: AgentLook.symbol(step.kind))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .frame(width: 14, height: 14)
                            .help(step.text)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 14)
                Text(AgentLook.status(session, now: now))
                    .font(.system(size: 10, weight: session.wait == nil ? .regular : .semibold))
                    .foregroundColor(accent ?? Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 74)
            .background(background)
            .opacity(calm ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.who.project), \(session.who.agent), \(AgentLook.status(session, now: now))")
    }

    // MARK: Parts

    @ViewBuilder
    private var avatar: some View {
        let state = AgentLook.botState(session)
        if animated {
            MiniBotCanvasView(task: AgentTask(id: session.id, name: session.who.project, color: pillColor,
                                              state: state, steps: [], source: .agent))
                .frame(width: 26 / 0.6, height: 26 / 0.6)
                .frame(width: 26, height: 26, alignment: .center)
        } else {
            LunaStill(state: state, bodyHex: pillColor)
                .frame(width: 26, height: 26)
        }
    }

    @ViewBuilder
    private var hostIcon: some View {
        if let icon = AgentHostApps.icon(for: session.who.hostBundleId) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 14, height: 14)
                .help(AgentHostApps.name(for: session.who.hostBundleId) ?? "")
        }
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: hovered ? "#1B1C20" : "#141518"))
            if let accent, session.rank == .waiting {
                // Louder than the rest: the one that needs you glows.
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.16))
            }
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.map { $0.opacity(session.rank == .working ? 0.35 : 0.95) }
                        ?? Color.white.opacity(selected ? 0.3 : 0.05),
                        lineWidth: session.rank == .waiting ? 2 : (accent == nil ? 1 : 1.5))
        }
    }
}
