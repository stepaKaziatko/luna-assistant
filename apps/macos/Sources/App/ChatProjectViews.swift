import SwiftUI
import AppKit

// MARK: - Проекты: чип на странице запроса и раздел настроек (LUNA-75)
//
// Логика — в ChatProjects.swift (без окна, под тестами). Здесь только вид.

#if !APPSTORE

/// Чип рядом с чипом модели: в каком проекте уйдёт вопрос Claude Code.
struct ProjectChip: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isPresented.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.activeChatProject == nil ? "folder" : "folder.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: state.activeChatProject == nil ? "#5C6370" : "#E07950"))
                Text(state.activeChatProject?.name
                     ?? String(localized: "projects.chip.none", defaultValue: "No project"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: "#7B8089"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(Color(hex: "#5C6370"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(state.activeChatProject?.path ?? "")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectPickerView(state: state, isPresented: $isPresented)
                .frame(width: 280)
        }
    }
}

/// Список: «Без проекта» и привязанные проекты; пропавшие — серые, выбрать их нельзя.
struct ProjectPickerView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @State private var folders: [UUID: ChatProjectFolder] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "projects.picker.title", defaultValue: "Project"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#8A8F98"))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(title: String(localized: "projects.chip.none", defaultValue: "No project"),
                        detail: nil, selected: state.activeChatProject == nil, enabled: true) {
                        choose(nil)
                    }
                    ForEach(state.chatProjects.projects) { project in
                        let folder = folders[project.id] ?? .ready(claudeMD: false, agentsMD: false)
                        row(title: project.name, detail: Self.detail(folder, path: project.path),
                            selected: state.activeChatProject?.id == project.id, enabled: folder.isUsable) {
                            choose(project.id)
                        }
                        .help(project.path)
                    }
                }
            }
            .frame(maxHeight: 220)
            if state.chatProjects.projects.isEmpty {
                Text(String(localized: "projects.picker.empty",
                            defaultValue: "No projects yet: add a folder in Settings → Projects."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8A8F98"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "projects.picker.hint",
                            defaultValue: "Claude Code runs in the project folder, with its CLAUDE.md, settings, hooks and MCP servers."))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#5C6370"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(hex: "#16171B"))
        .onAppear { inspect() }
    }

    private func inspect() {
        var result: [UUID: ChatProjectFolder] = [:]
        for project in state.chatProjects.projects { result[project.id] = ChatProjectFolder.inspect(project.path) }
        folders = result
        // Выбранный проект пропал — «Без проекта».
        state.reconcileChatProjectSelection()
    }

    private func choose(_ id: UUID?) {
        state.selectChatProject(id)
        isPresented = false
        SoundEngine.shared.play("blip")
    }

    static func detail(_ folder: ChatProjectFolder, path: String) -> String {
        switch folder {
        case .missing:  return String(localized: "projects.state.missing", defaultValue: "Folder not found")
        case .noAccess: return String(localized: "projects.state.no-access", defaultValue: "No access")
        case .ready:    return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func row(title: String, detail: String?, selected: Bool, enabled: Bool,
                     action: @escaping () -> Void) -> some View {
        let accent = Color(hex: ChatProvider.claudeCode.accentHex)
        return Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundColor(selected ? accent : Color(hex: enabled ? "#C8CDD4" : "#5C6370"))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#5C6370"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? accent.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Settings → Проекты

struct ProjectsSettingsView: View {
    @ObservedObject var state: AppState
    @State private var folders: [UUID: ChatProjectFolder] = [:]
    /// Найденные кнопкой «Найти проекты»; nil — поиска не было.
    @State private var found: [ChatProjectImport.Candidate]? = nil
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "projects.settings.about",
                        defaultValue: "A project is a folder on your Mac. Pick it next to the model when you ask Claude Code: it then runs in that folder, with the project's CLAUDE.md, settings, hooks and MCP servers. Agents that work in a project show it on their page."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(String(localized: "projects.settings.list", defaultValue: "Projects")) {
                VStack(alignment: .leading, spacing: 8) {
                    if state.chatProjects.projects.isEmpty {
                        Text(String(localized: "projects.settings.empty",
                                    defaultValue: "No projects yet."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    ForEach(state.chatProjects.projects) { project in
                        ProjectSettingsRow(state: state, project: project,
                                           folder: folders[project.id] ?? .ready(claudeMD: false, agentsMD: false))
                        if project.id != state.chatProjects.projects.last?.id { Divider() }
                    }
                    HStack(spacing: 10) {
                        Button(String(localized: "projects.settings.add", defaultValue: "Add folder…")) { addFolder() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "projects.settings.discover",
                                      defaultValue: "Find Claude Code and Codex projects")) { discover() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                .padding(6)
            }

            if let found { foundBox(found) }
        }
        .onAppear { inspect() }
        .onChange(of: state.chatProjectsRevision) { _, _ in inspect() }
    }

    @ViewBuilder
    private func foundBox(_ candidates: [ChatProjectImport.Candidate]) -> some View {
        GroupBox(String(localized: "projects.settings.found", defaultValue: "Found")) {
            VStack(alignment: .leading, spacing: 6) {
                if candidates.isEmpty {
                    Text(String(localized: "projects.settings.found.none", defaultValue: "Nothing found."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(candidates, id: \.path) { candidate in
                        Toggle(isOn: Binding(
                            get: { picked.contains(candidate.path) },
                            set: { on in if on { picked.insert(candidate.path) } else { picked.remove(candidate.path) } }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
                                    .font(.system(size: 12))
                                Text("\((candidate.path as NSString).abbreviatingWithTildeInPath) · \(Self.sourceName(candidate.source))")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    if !candidates.isEmpty {
                        Button(String(localized: "projects.settings.found.add", defaultValue: "Add")) { addPicked(candidates) }
                            .buttonStyle(.borderedProminent)
                            .disabled(picked.isEmpty)
                    }
                    Button(String(localized: "projects.settings.found.close", defaultValue: "Close")) {
                        found = nil
                        picked = []
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(6)
        }
    }

    static func sourceName(_ source: ChatProject.Source) -> String {
        switch source {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .manual: return String(localized: "projects.source.manual", defaultValue: "added by you")
        }
    }

    private func inspect() {
        var result: [UUID: ChatProjectFolder] = [:]
        for project in state.chatProjects.projects { result[project.id] = ChatProjectFolder.inspect(project.path) }
        folders = result
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "projects.settings.add.prompt", defaultValue: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var list = state.chatProjects
        list.add(path: url.path, source: .manual)
        state.chatProjects = list
        if found != nil { discover() }
    }

    /// По клику, не в фоне: только пути из `~/.claude.json` и `~/.codex/config.toml`.
    private func discover() {
        let candidates = ChatProjectImport.discover(existing: state.chatProjects)
        found = candidates
        picked = Set(candidates.map(\.path))
    }

    private func addPicked(_ candidates: [ChatProjectImport.Candidate]) {
        var list = state.chatProjects
        for candidate in candidates where picked.contains(candidate.path) {
            list.add(path: candidate.path, source: candidate.source)
        }
        state.chatProjects = list
        found = nil
        picked = []
    }
}

private struct ProjectSettingsRow: View {
    @ObservedObject var state: AppState
    let project: ChatProject
    let folder: ChatProjectFolder
    @State private var name = ""

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: folder.isUsable ? "folder.fill" : "folder.badge.questionmark")
                .foregroundColor(folder.isUsable ? Color(hex: "#E07950") : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .onSubmit(commit)
                HStack(spacing: 6) {
                    Text((project.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    switch folder {
                    case .ready(let claudeMD, let agentsMD):
                        if claudeMD { badge("CLAUDE.md") }
                        if agentsMD { badge("AGENTS.md") }
                    case .missing:
                        warning(String(localized: "projects.state.missing", defaultValue: "Folder not found"))
                    case .noAccess:
                        warning(String(localized: "projects.state.no-access", defaultValue: "No access"))
                    }
                }
            }
            Spacer(minLength: 8)
            Button(String(localized: "projects.settings.remove", defaultValue: "Remove")) {
                var list = state.chatProjects
                list.remove(id: project.id)
                state.chatProjects = list
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onAppear { name = project.name }
        .onChange(of: project.name) { _, value in name = value }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard name != project.name else { return }
        var list = state.chatProjects
        list.rename(id: project.id, to: name)
        state.chatProjects = list
        name = list.project(id: project.id)?.name ?? project.name
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.orange)
    }
}

#endif
