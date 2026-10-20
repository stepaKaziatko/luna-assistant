import SwiftUI
import AppKit

// MARK: - Preview page of an agent
//
// One session in detail: who and where, the last steps, and, when the agent waits for you, its
// question or permission request with the same buttons as the card. The page owns no queue: the
// requests are read off `HookServer`'s (`AppState.agentRequests`, `pendingQuestion`), and an
// answer goes through the same entry points as the card's, with the id of the request on screen,
// so answering in one place takes the request off the other and a late click does nothing.
//
// The page does no work of its own while it is not the one on screen: its clock and its avatar
// sit under `islandViewActive`. It never takes the focus; only "Go to the agent" hands it to
// another app, on a click (`AgentJump`).

struct AgentPreviewView: View {
    @ObservedObject var state: AppState
    @Environment(\.islandViewActive) private var viewActive

    @State private var now = Date()
    /// The request this page answered itself: its disappearance is not news.
    @State private var answeredHere: UUID? = nil
    @State private var notice: AgentPreviewLogic.Notice? = nil
    @State private var noticeToken = 0

    private var session: AgentSessionInfo? {
        guard let id = state.previewAgentId else { return nil }
        return state.agentSessions.first { $0.id == id }
    }

    /// What this session finished is no longer news once its page is on screen. Hovering the block
    /// under the cursor is not looking: only the page does this.
    private func markSeen() {
        guard let session, session.finishedUnseen else { return }
        HookServer.shared.markAgentsSeen(for: session.key)
    }

    private func request(for session: AgentSessionInfo) -> AgentPreviewLogic.Request {
        AgentPreviewLogic.request(sessionKey: session.id, requests: state.agentRequests,
                                  questionOwner: state.pendingQuestionOwner,
                                  questionId: state.pendingQuestionId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                backButton
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            if let session {
                let current = request(for: session)
                HStack(alignment: .top, spacing: 12) {
                    leftColumn(session)
                        .frame(width: 208, alignment: .topLeading)
                    rightColumn(session, request: current)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .onChange(of: current) { old, new in requestChanged(session: session, old: old, new: new) }
            } else {
                closedPage
            }
        }
        .padding(.top, 2)
        .padding(.horizontal, 4)
        .onChange(of: viewActive) { _, active in
            if active { now = Date(); markSeen() }
        }
        .onAppear { if viewActive { markSeen() } }
        // The page of an agent that is shown is the page that looked at what it finished: a turn
        // that ends while it is open, or another agent opened on it, is seen too.
        .onChange(of: session?.finishedUnseen) { _, unseen in if unseen == true, viewActive { markSeen() } }
        .onChange(of: state.previewAgentId) { _, _ in if viewActive { markSeen() } }
        // The clock of the page: "5 min ago" and sessions gone silent, every 30 s, only while the
        // page is the one on screen.
        .task(id: viewActive) {
            guard viewActive else { return }
            now = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                now = Date()
                HookServer.shared.publishAgentSessions(now: now)
            }
        }
        // A notice lives three seconds.
        .task(id: noticeToken) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }

    // MARK: Back

    private var backButton: some View {
        Button {
            state.closeAgentPreview()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(localized: "agentPreview.back", defaultValue: "Back"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Color(hex: "#B0B5BE"))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Closed

    private var closedPage: some View {
        VStack(spacing: 8) {
            LunaStill(state: .sleeping)
                .frame(width: 34, height: 34)
                .opacity(0.8)
            Text(String(localized: "agentPreview.closed.title", defaultValue: "Session closed"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            SecondaryButton(verbatim: String(localized: "agentPreview.back", defaultValue: "Back")) {
                state.closeAgentPreview()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Left: who, where, what

    private func leftColumn(_ session: AgentSessionInfo) -> some View {
        let pillColor = PillCatalog.definition(for: session.pill)?.color ?? "#C0C4CC"
        let host = AgentHostApps.name(for: session.who.hostBundleId)
        let folder = AgentPreviewLogic.folderName(cwd: session.who.cwd, project: session.who.project)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                avatar(session, pillColor: pillColor)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.who.project)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 4) {
                        if let icon = AgentHostApps.icon(for: session.who.hostBundleId) {
                            Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                        }
                        Text(host.map { "\(session.who.agent) · \($0)" } ?? session.who.agent)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            if let project = ChatProjectMatch.project(projectDir: session.who.projectDir, cwd: session.who.cwd,
                                                      in: state.chatProjects.projects) {
                // Папка агента — в привязанном проекте (LUNA-75).
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                    Text(String(localized: "agentPreview.project", defaultValue: "Project: \(project.name)"))
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C"))
                .help(session.who.cwd.isEmpty ? project.path : session.who.cwd)
            } else if let folder {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(folder).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C"))
                .help(session.who.cwd)
            }
            Text(AgentLook.status(session, now: now))
                .font(.system(size: 11, weight: session.wait == nil ? .regular : .semibold))
                .foregroundColor(AgentLook.accentHex(session).map { Color(hex: $0) } ?? Color(hex: "#8E939C"))
                .lineLimit(2)
            if session.phase == .finished, session.wait == nil, let line = session.finalLine {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            jumpButton(session)
        }
    }

    @ViewBuilder
    private func avatar(_ session: AgentSessionInfo, pillColor: String) -> some View {
        let botState = AgentLook.botState(session)
        if viewActive, AgentLook.isLively(session) {
            // The only moving Luna of the page.
            MiniBotCanvasView(task: AgentTask(id: session.id, name: session.who.project, color: pillColor,
                                              state: botState, steps: [], source: .agent))
                .frame(width: 40 / 0.6, height: 40 / 0.6)
                .frame(width: 40, height: 40, alignment: .center)
        } else {
            LunaStill(state: botState, bodyHex: pillColor)
                .frame(width: 40, height: 40)
        }
    }

    // MARK: Go to the agent

    private func jumpButton(_ session: AgentSessionInfo) -> some View {
        let plan = AgentJumpPlan.make(pill: session.pill, sessionId: session.key.session, who: session.who)
        let hint = jumpHintText(for: session, available: plan.isAvailable)
        return VStack(alignment: .leading, spacing: 3) {
            if let hint {
                Text(hint)
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(hex: "#F5A524"))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrimaryButton(verbatim: String(localized: "agentPreview.jump", defaultValue: "Go to the agent")) {
                goToAgent(session)
            }
            .disabled(!plan.isAvailable)
            .opacity(plan.isAvailable ? 1 : 0.4)
        }
    }

    /// The click (and ⌘↩, the same entry in `AppState`), and the only place the focus leaves Luna.
    /// The island folds once the jump is under way; what the jump has to say stays in `AppState`
    /// for the next time the page opens.
    private func goToAgent(_ session: AgentSessionInfo) {
        state.goToAgent(session)
    }

    private func jumpHintText(for session: AgentSessionInfo, available: Bool) -> String? {
        if !available {
            return String(localized: "agentPreview.hint.unavailable", defaultValue: "I don't know where this agent runs")
        }
        guard let note = state.agentJumpNote, note.sessionId == session.id else { return nil }
        switch note.hint {
        case .needsAutomation(let app):
            return String(localized: "agentPreview.hint.automation",
                          defaultValue: "Allow Luna to control \(app) in System Settings → Privacy & Security → Automation to jump straight to the tab.")
        case .tabUnavailable(let app):
            return String(localized: "agentPreview.hint.tab-unavailable",
                          defaultValue: "\(app) cannot select a tab: only the app is brought forward.")
        case .folderMissing:
            return String(localized: "agentPreview.hint.folder-missing", defaultValue: "Project folder not found")
        case .unavailable:
            return String(localized: "agentPreview.hint.unavailable", defaultValue: "I don't know where this agent runs")
        }
    }

    // MARK: Right: steps, question, request

    @ViewBuilder
    private func rightColumn(_ session: AgentSessionInfo, request: AgentPreviewLogic.Request) -> some View {
        switch request {
        case .question(let id):
            ScrollView(.vertical, showsIndicators: false) {
                QuestionPanel(question: state.pendingQuestion, questionId: id, showsAsker: false,
                              onAnswered: { answeredHere = $0 })
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .approval(let req):
            approvalCard(req)
        case .queued(let req):
            queuedCard(req)
        case .none:
            VStack(alignment: .leading, spacing: 4) {
                if let notice { noticeLine(notice) }
                if let reason = AgentPreviewLogic.noCards(pill: session.pill, hostBundleId: session.who.hostBundleId,
                                                          terminalCardsEnabled: ClaudeHost.terminalCardsEnabled),
                   session.wait == nil, session.phase != .idle || !session.steps.isEmpty {
                    noCardsLine(reason)
                }
                stepList(session)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#141518")))
            }
        }
    }

    private func noticeLine(_ notice: AgentPreviewLogic.Notice) -> some View {
        let text: String
        switch notice {
        case .requestGone:
            text = String(localized: "agentPreview.request.gone",
                          defaultValue: "The request is already gone — it was answered elsewhere")
        case .handedToTerminal:
            text = String(localized: "agentPreview.request.terminal", defaultValue: "The request went to the terminal")
        }
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color(hex: "#F5A524"))
    }

    private func noCardsLine(_ reason: AgentPreviewLogic.NoCards) -> some View {
        let text: String
        switch reason {
        case .terminalCardsOff:
            text = String(localized: "agentPreview.nocards.terminal",
                          defaultValue: "Luna does not get questions and requests of this session: turn on terminal cards in Settings → Agents or answer in the terminal.")
        case .observedOnly:
            text = String(localized: "agentPreview.nocards.observed",
                          defaultValue: "This agent is only shown here: answer it in its own app.")
        }
        return Text(text)
            .font(.system(size: 10))
            .foregroundColor(Color(hex: "#8E939C"))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Steps

    private func stepList(_ session: AgentSessionInfo) -> some View {
        Group {
            if session.steps.isEmpty {
                Text(String(localized: "agentPreview.steps.empty", defaultValue: "No steps yet"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            // Oldest first, the newest at the bottom.
                            ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                                AgentStepRow(step: step, isLast: index == session.steps.count - 1)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { scrollToNewest(proxy, session) }
                    .onChange(of: session.steps.count) { _, _ in scrollToNewest(proxy, session) }
                    .onChange(of: session.steps.last) { _, _ in scrollToNewest(proxy, session) }
                }
            }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy, _ session: AgentSessionInfo) {
        guard !session.steps.isEmpty else { return }
        proxy.scrollTo(session.steps.count - 1, anchor: .bottom)
    }

    // MARK: Permission request

    private func approvalCard(_ req: AgentRequest) -> some View {
        // The button picked with the keys (←/→), for this request only.
        let picked = state.keyChoice(for: .approval(id: req.id, offersAlways: ApprovalChoices.offersAlways(pillId: req.pill)))?.index
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                AgentWho(task: nil, label: "needs permission")
                if req.total > 1 {
                    Text(verbatim: "1/\(req.total)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .monospacedDigit()
                }
            }
            CodeBlock(text: req.command)
                .lineLimit(5)
            HStack(spacing: 8) {
                SecondaryButton("Deny") { decide("deny", req) }
                    .keyPickCapsule(picked == 0)
                PrimaryButton("Allow") { decide("allow", req) }
                    .keyPickCapsule(picked == 1)
                if ApprovalChoices.offersAlways(pillId: req.pill) {
                    SecondaryButton("Always") { decide("always", req) }
                        .keyPickCapsule(picked == 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func decide(_ decision: String, _ req: AgentRequest) {
        answeredHere = req.id
        HookServer.shared.sendApprovalDecision(decision, for: req.id)
    }

    /// A request that is not at the head of the queue: read only. The order of answers is the
    /// queue's, and the page does not change it.
    private func queuedCard(_ req: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentWho(task: nil, label: "needs permission")
            CodeBlock(text: req.command)
                .lineLimit(4)
            Text(String(localized: "agentPreview.queue",
                        defaultValue: "In the queue: \(req.position) of \(req.total). You can answer when its turn comes."))
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#F5A524"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: A request went away

    private func requestChanged(session: AgentSessionInfo,
                                old: AgentPreviewLogic.Request, new: AgentPreviewLogic.Request) {
        // An answer given with the keys is this page's own answer too.
        let own = old.answerId != nil && old.answerId == state.keyAnsweredId ? old.answerId : answeredHere
        let news = AgentPreviewLogic.notice(old: old, new: new, answeredHere: own,
                                            sessionKey: session.id,
                                            questionOwnerNow: state.pendingQuestionOwner)
        guard let news, new == .none else {
            // A fresh request replaces the message.
            if new != .none { notice = nil }
            return
        }
        notice = news
        noticeToken += 1
    }
}

// MARK: - A step

struct AgentStepRow: View {
    let step: AgentStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: AgentLook.symbol(step.kind))
                .font(.system(size: 10))
                .foregroundColor(Color(hex: step.kind == .failure ? AgentLook.error : "#8E939C"))
                .frame(width: 14, height: 15)
            Text(step.text)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: isLast ? "#F5F6F8" : "#C5C8CD"))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
