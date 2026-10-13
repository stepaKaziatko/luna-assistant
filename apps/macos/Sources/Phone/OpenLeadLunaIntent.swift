import AppIntents
import Foundation

/// Opens Luna on the Luna that needs you most (Control Center button).
/// Compiled into the app and the widgets extension.
struct OpenLeadLunaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the agent that needs you"

    func perform() async throws -> some IntentResult & OpensIntent {
        let url = SharedSessions.load().first.map { SharedSession.url(for: $0.id) } ?? URL(string: "luna://home")!
        return .result(opensIntent: OpenURLIntent(url))
    }
}
