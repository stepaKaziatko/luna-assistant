import SwiftUI

// MARK: - Agents page
//
// "Who is working right now, who waits for me, who has finished": one tile per live agent
// session, fed by `AppState.agentSessions` (see AgentSessions.swift). The page does no work of
// its own while it is not shown: every animation sits under `islandViewActive`, and the clock
// that refreshes "5 min ago" runs only while the page is the active one.

struct AgentsView: View {
    @ObservedObject var state: AppState
    @Environment(\.islandViewActive) private var viewActive

    @State private var now = Date()
    /// Whether the page has been on screen since it last went away: only then are the sessions
    /// that finished meanwhile "seen".
    @State private var shown = false
    @State private var hooksInstalled = true

    /// Tiles that move their Luna at the same time; the rest are still pictures.
    private static let maxLively = 6
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentsSummaryBar(summary: state.agentsSummary, groupByProject: $state.agentsGroupByProject)
                .padding(.horizontal, 4)
            if state.agentSessions.isEmpty {
                AgentsEmptyState(hooksInstalled: hooksInstalled)
            } else {
                tiles
            }
        }
        .padding(.top, 2)
        .padding(.horizontal, 2)
        .onAppear { if viewActive { becameShown() } }
        .onChange(of: viewActive) { _, active in
            if active { becameShown() } else { wentAway() }
        }
        .onDisappear { wentAway() }
        // The clock of the page: "5 min ago" and the sessions that went silent, every 30 s,
        // and only while the page is the one on screen.
        .task(id: viewActive) {
            guard viewActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                now = Date()
                HookServer.shared.publishAgentSessions(now: now)
            }
        }
    }

    private var tiles: some View {
        let livelyIds = livelyTileIds
        // The pick lives in `AppState` (by session id): the arrows of the island move it, a click sets it,
        // and the session that goes takes it along.
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Self.columns, spacing: 8) {
                    if state.agentsGroupByProject {
                        // «По проектам» (LUNA-75): тот же порядок, что у стрелок (`AppState.agentTileOrder`).
                        ForEach(AgentProjectGrouping.groups(state.agentSessions, projects: state.chatProjects.projects)) { group in
                            Section {
                                ForEach(group.sessions) { session in tile(session, lively: livelyIds) }
                            } header: {
                                groupHeader(group)
                            }
                        }
                    } else {
                        ForEach(state.agentSessions) { session in tile(session, lively: livelyIds) }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            // The tile picked with the keys comes into view (no animation: a still page stays still).
            .onChange(of: state.agentsSelectionId) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func tile(_ session: AgentSessionInfo, lively: Set<String>) -> some View {
        AgentTile(session: session,
                  animated: lively.contains(session.id),
                  selected: state.agentsSelectionId == session.id,
                  now: now,
                  onTap: {
                      state.agentsSelectionId = session.id
                      state.openAgent(id: session.id)
                  })
        .id(session.id)
    }

    private func groupHeader(_ group: AgentProjectGroup) -> some View {
        HStack(spacing: 4) {
            Image(systemName: group.project == nil ? "tray" : "folder.fill")
                .font(.system(size: 9))
            Text(group.project?.name ?? String(localized: "agents.group.other", defaultValue: "Other"))
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundColor(Color(hex: "#8E939C"))
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .help(group.project?.path ?? "")
    }

    /// The first `maxLively` tiles that work, wait or have failed: the list is in display
    /// order, so the ones that need you move first.
    private var livelyTileIds: Set<String> {
        Set(state.agentSessions.filter(AgentLook.isLively).prefix(Self.maxLively).map(\.id))
    }

    private func becameShown() {
        shown = true
        now = Date()
        hooksInstalled = Self.anyHooksInstalled()
        HookServer.shared.publishAgentSessions(now: now)
    }

    private func wentAway() {
        guard shown else { return }
        shown = false
        HookServer.shared.markAgentsSeen()
    }

    private static func anyHooksInstalled() -> Bool {
        var installed = HookServer.claudeHooksInstalled()
        #if !APPSTORE
        installed = installed || HookServer.codexHooksInstalled() || HookServer.geminiHooksInstalled()
            || HookServer.copilotHooksInstalled() || HookServer.museHooksInstalled()
        #endif
        return installed
    }
}

// MARK: - Counters

private struct AgentsSummaryBar: View {
    let summary: AgentsSummary
    @Binding var groupByProject: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(String(localized: "agents.title", defaultValue: "Agents"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            groupToggle
            Spacer(minLength: 0)
            counter(summary.waiting, AgentLook.waiting, "bell.fill",
                    String(localized: "agents.summary.waiting", defaultValue: "Waiting for you"))
            counter(summary.working, AgentLook.working, "bolt.fill",
                    String(localized: "agents.summary.working", defaultValue: "Working"))
            counter(summary.finished, AgentLook.finished, "checkmark.circle.fill",
                    String(localized: "agents.summary.finished", defaultValue: "Finished"))
            counter(summary.errors, AgentLook.error, "exclamationmark.triangle.fill",
                    String(localized: "agents.summary.errors", defaultValue: "Errors"))
        }
        .frame(height: 20)
    }

    /// «По проектам»: плитки собираются в группы по проекту агента (Settings → Проекты).
    private var groupToggle: some View {
        Button { groupByProject.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: groupByProject ? "folder.fill" : "folder")
                    .font(.system(size: 9))
                Text(String(localized: "agents.group.toggle", defaultValue: "By project"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(Color(hex: groupByProject ? "#F5F6F8" : "#8E939C"))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.white.opacity(groupByProject ? 0.14 : 0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(groupByProject ? .isSelected : [])
    }

    private func counter(_ count: Int, _ hex: String, _ symbol: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundColor(count > 0 ? Color(hex: hex) : Color(hex: "#4B4F57"))
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(count)")
    }
}

// MARK: - Empty state

private struct AgentsEmptyState: View {
    let hooksInstalled: Bool

    var body: some View {
        VStack(spacing: 6) {
            LunaStill(state: .sleeping)
                .frame(width: 34, height: 34)
                .opacity(0.8)
            Text(String(localized: "agents.empty.title", defaultValue: "No agents in sight"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text(String(localized: "agents.empty.hint",
                        defaultValue: "Start Claude Code in an editor or a terminal — the session will appear here."))
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .multilineTextAlignment(.center)
            if !hooksInstalled {
                Text(String(localized: "agents.empty.hooks",
                            defaultValue: "Hooks are not installed yet: Settings → Agents."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: AgentLook.waiting))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
