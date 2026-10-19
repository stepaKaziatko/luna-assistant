import Foundation

// MARK: - Pages of the island that are not the home page
//
// Two small rules live here, without a window or a view, so they can be tested alone:
//
// 1. Which page the island opens on: the Agents page; a request that waits for an answer
//    comes first. ("Home" used to be the pill overview, now the "Active pills" page.)
// 2. Which integrations have a page of their own, ready in the app. A page exists only while
//    the integration is connected: its pill is switched on in Settings → Active pills AND its
//    key is saved. Switch it off or erase the key — the tab goes away at once.
//
// The page itself (what it draws) is a view; this file only decides whether it is there.

// MARK: Home

enum IslandHome {
    /// The page the island opens on and returns to ("home").
    static func view(pendingApproval: Bool) -> IslandView {
        pendingApproval ? .approval : .agents
    }

    /// Что делает остров, когда запрос агента ушёл (ответ, апрув, ответ в терминале, таймаут).
    ///
    /// - Parameters:
    ///   - view: страница на экране.
    ///   - nextWaits: ждёт ли ещё запрос — его показывает очередь, как и раньше.
    ///   - note: есть ли заметка «запрос снят без ответа».
    ///   - canCollapse: можно ли свернуть шторку (её не удерживает черновик письма голосом).
    static func afterRequest(on view: IslandView, nextWaits: Bool, note: Bool,
                             canCollapse: Bool) -> AfterRequest {
        // Страница агента сама показывает, что запрос ушёл.
        if view == .agentPreview { return .stay }
        // На других страницах пользователь остаётся где был: на главную его больше не уводит.
        guard view == .approval || view == .question else { return .stay }
        if nextWaits { return .showNext }
        if note { return .noteThenCollapse }
        return canCollapse ? .collapse : .home
    }
}

/// Итог `IslandHome.afterRequest`.
enum AfterRequest: Equatable {
    /// Ждёт следующий запрос: его показывает очередь (порядок не меняется).
    case showNext
    /// Пользователь остаётся на своей странице.
    case stay
    /// Заметка на 3 с, потом шторка сворачивается.
    case noteThenCollapse
    /// Шторка сворачивается в остров.
    case collapse
    /// Свернуть нельзя — главная страница, а не пустая карточка.
    case home
}

// MARK: Integration pages

struct IntegrationPage: Equatable {
    /// The pill of the integration in `PillCatalog`; the tab is on while this pill is on.
    let pillId: String
    /// The page of the island this integration opens.
    let view: IslandView
    /// Name on the tab (tooltip); a brand name, not translated.
    let title: String
    /// SF Symbol on the tab in the header.
    let icon: String
    /// Key in the Keychain; the page needs it saved, otherwise there is nothing to show.
    let credentialKey: String
}

enum IntegrationPages {
    /// Pages made ahead of time in the app, in the order of the tabs. Only GitHub for now: a
    /// new integration gets its page by one more line here (and a view for it).
    static let catalog: [IntegrationPage] = [
        IntegrationPage(pillId: "integration_github", view: .github, title: "GitHub",
                        icon: "arrow.triangle.branch", credentialKey: "github-token"),
    ]

    /// Keys in the Keychain the catalog cares about: `AppState` reads exactly these.
    static var credentialKeys: [String] { catalog.map(\.credentialKey) }

    /// Tabs to show: the integration is on in "Active pills" and its key is saved.
    static func visible(active: Set<String>, credentials: Set<String>) -> [IntegrationPage] {
        catalog.filter { active.contains($0.pillId) && credentials.contains($0.credentialKey) }
    }

    /// The page of a view, if the view is the page of an integration.
    static func page(for view: IslandView) -> IntegrationPage? {
        catalog.first { $0.view == view }
    }

    /// What the island shows when `view` is on screen and the visible tabs are `pages`: the same
    /// view, or home when it is a page of an integration whose tab has gone away.
    static func resolved(_ view: IslandView, visible pages: [IntegrationPage],
                         pendingApproval: Bool) -> IslandView {
        guard let own = page(for: view), !pages.contains(own) else { return view }
        return IslandHome.view(pendingApproval: pendingApproval)
    }
}
