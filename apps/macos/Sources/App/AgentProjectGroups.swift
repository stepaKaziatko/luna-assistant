import Foundation

// MARK: - Агенты по проектам
//
// Переключатель «По проектам» на странице «Агенты» (UserDefaults `agentsGroupByProject`,
// по умолчанию выключен). Только Foundation: собирается тестами (scripts/test-chat-projects.sh).

struct AgentProjectGroup: Equatable, Identifiable, Sendable {
    /// nil — группа «Другие»: сессии вне списка проектов.
    let project: ChatProject?
    let sessions: [AgentSessionInfo]

    var id: String { project?.id.uuidString ?? "other" }
}

enum AgentProjectGrouping {
    static let defaultsKey = "agentsGroupByProject"

    /// Группы по проекту агента (`ChatProjectMatch`). Внутри группы порядок списка сохраняется
    /// (он уже по `AgentRank`); группы — по самой срочной сессии в них, при равенстве по имени,
    /// «Другие» — последней.
    static func groups(_ sessions: [AgentSessionInfo], projects: [ChatProject]) -> [AgentProjectGroup] {
        var order: [UUID?] = []
        var buckets: [UUID?: [AgentSessionInfo]] = [:]
        var byID: [UUID: ChatProject] = [:]
        for session in sessions {
            let project = ChatProjectMatch.project(projectDir: session.who.projectDir, cwd: session.who.cwd,
                                                   in: projects)
            let key = project?.id
            if let project { byID[project.id] = project }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(session)
        }
        let groups = order.map { key in
            AgentProjectGroup(project: key.flatMap { byID[$0] }, sessions: buckets[key] ?? [])
        }
        return groups.sorted { a, b in
            let ra = a.sessions.map(\.rank).min() ?? .quiet
            let rb = b.sessions.map(\.rank).min() ?? .quiet
            if ra != rb { return ra < rb }
            switch (a.project, b.project) {
            case (nil, _?): return false
            case (_?, nil): return true
            case (let pa?, let pb?):
                return pa.name.localizedStandardCompare(pb.name) == .orderedAscending
            case (nil, nil): return false
            }
        }
    }

    /// Порядок плиток на экране — по нему же ходят стрелки острова.
    static func displayOrder(_ sessions: [AgentSessionInfo], projects: [ChatProject], grouped: Bool) -> [String] {
        guard grouped else { return sessions.map(\.id) }
        return groups(sessions, projects: projects).flatMap { $0.sessions.map(\.id) }
    }
}
