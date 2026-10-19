import Foundation

// The real IslandTypes.swift is compiled with this test; it needs the eye shape of the bot, which lives
// in BotEngine. A stub is enough here.
enum EyeShape: String { case round }

@main
enum IntegrationPagesTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let github = "integration_github"
    static let token = "github-token"

    /// The default of `AppState.activeIntegrations` and the way it is kept in UserDefaults (a JSON array of ids).
    static let defaultActive: Set<String> = ["integration_resend", "integration_n8n", "integration_vercel", "integration_github"]

    static func visibleViews(active: Set<String>, credentials: Set<String>) -> [IslandView] {
        IntegrationPages.visible(active: active, credentials: credentials).map(\.view)
    }

    static func main() {

        // ── the catalog ─────────────────────────────────────────────────────────
        print("\nCatalog of integration pages")
        do {
            check("exactly one page is made: GitHub", IntegrationPages.catalog.count == 1
                  && IntegrationPages.catalog[0].pillId == github
                  && IntegrationPages.catalog[0].view == .github)
            check("GitHub needs its token", IntegrationPages.catalog[0].credentialKey == token
                  && IntegrationPages.credentialKeys == [token])
            check("the page of a view is found, other views have none",
                  IntegrationPages.page(for: .github)?.pillId == github
                  && IslandView.allCases.filter { IntegrationPages.page(for: $0) != nil } == [.github])
            let names = IntegrationPages.catalog.map(\.view)
            check("every page is its own view", Set(names).count == names.count)
        }

        // ── when the tab is there ───────────────────────────────────────────────
        print("\nTab is there while the integration is connected")
        do {
            check("pill on and token saved → the GitHub tab",
                  visibleViews(active: [github], credentials: [token]) == [.github])
            check("pill on, no token → no tab (the default profile)",
                  visibleViews(active: defaultActive, credentials: []).isEmpty)
            check("token, but the pill is off → no tab",
                  visibleViews(active: ["integration_resend"], credentials: [token]).isEmpty)
            check("nothing at all → no tabs", visibleViews(active: [], credentials: []).isEmpty)
            check("another key saved is not the token",
                  visibleViews(active: [github], credentials: ["vercel-token", "n8n-api-key"]).isEmpty)
            check("the tab appears and goes away with the pill, live",
                  visibleViews(active: defaultActive, credentials: [token]) == [.github]
                  && visibleViews(active: defaultActive.subtracting([github]), credentials: [token]).isEmpty)
            check("the tab goes away with the token, live",
                  visibleViews(active: defaultActive, credentials: [token]) == [.github]
                  && visibleViews(active: defaultActive, credentials: []).isEmpty)
            check("the order of the tabs is stable",
                  (0..<20).allSatisfy { _ in visibleViews(active: defaultActive, credentials: [token]) == [.github] })
        }

        // ── the stored settings are read as they were ───────────────────────────
        print("\nStored settings")
        do {
            let json = #"["integration_resend","integration_n8n","integration_vercel","integration_github"]"#
            let stored = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))).map(Set.init) ?? []
            check("the stored array is the default set", stored == defaultActive)
            check("the stored set gives the same tabs as the one in memory",
                  visibleViews(active: stored, credentials: [token]) == visibleViews(active: defaultActive, credentials: [token]))
            let encoded = (try? JSONEncoder().encode(Array(defaultActive))).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            check("the set survives encoding as AppState writes it", encoded.map(Set.init) == defaultActive)
            let old = #"["integration_stripe","integration_notion"]"#
            let oldSet = (try? JSONDecoder().decode([String].self, from: Data(old.utf8))).map(Set.init) ?? []
            check("a profile without GitHub gets no tab and loses nothing",
                  visibleViews(active: oldSet, credentials: [token]).isEmpty && oldSet.count == 2)
        }

        // ── home ────────────────────────────────────────────────────────────────
        print("\nHome page")
        do {
            check("home is the Agents page", IslandHome.view(pendingApproval: false) == .agents)
            check("a waiting request comes first", IslandHome.view(pendingApproval: true) == .approval)
            check("home is not the pill overview", IslandHome.view(pendingApproval: false) != .overview)
            let pages = IntegrationPages.visible(active: [github], credentials: [token])
            check("a page whose tab is gone gives way to home",
                  IntegrationPages.resolved(.github, visible: [], pendingApproval: false) == .agents
                  && IntegrationPages.resolved(.github, visible: [], pendingApproval: true) == .approval)
            check("a page whose tab is there stays",
                  IntegrationPages.resolved(.github, visible: pages, pendingApproval: false) == .github)
            check("other views never move, the overview included",
                  IslandView.allCases.filter { $0 != .github }.allSatisfy {
                      IntegrationPages.resolved($0, visible: [], pendingApproval: false) == $0
                  })
            check("the pill overview, the agents and one agent stay reachable views",
                  IslandView.allCases.contains(.overview) && IslandView.allCases.contains(.agents)
                  && IslandView.allCases.contains(.agentPreview))
        }

        // ── layout ──────────────────────────────────────────────────────────────
        print("\nLayout of the pages")
        do {
            let missing = IslandView.allCases.filter { IslandConst.viewLayouts[$0] == nil }
            check("every view has a layout (viewLayouts[view]! never fails)", missing.isEmpty)
            let layout = IslandConst.viewLayouts[.github]
            check("GitHub: height 240, no agents column", layout?.height == 240 && layout?.agentMode == AgentLayoutMode.none)
            check("GitHub is as tall as the Agents page", layout?.height == IslandConst.viewLayouts[.agents]?.height)
            check("pages over the full width hide the big Luna: agents, one agent, GitHub",
                  IslandView.allCases.filter(\.hidesBigLuna) == [.agents, .agentPreview, .github])
        }

        print(failures == 0 ? "\nAll integration page checks passed" : "\n\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
