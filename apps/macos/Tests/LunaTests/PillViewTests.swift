import AppKit
import SwiftUI
import XCTest
@testable import Luna

/// Нарисованная шторка: то, что раскладка учла в замере крыла, действительно попадает на картинку.
@MainActor
final class PillViewTests: XCTestCase {
    private func session(_ id: String, _ state: AgentState) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", cwd: "/work/shop",
            host: AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil), id: id, model: nil, openUrl: nil,
            pid: 1, project: "shop", startedAt: 0, state: state, title: "сессия \(id)", trail: nil, updatedAt: 0, waitingFor: nil
        )
    }

    private func makeState() -> AppState {
        let suite = "dev.luna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settings: LunaSettings(defaults: defaults))
        state.islandPlacement = IslandPlacement(notch: NotchGeometry(notchWidth: 186, barHeight: 32, centerX: 400), correction: 0)
        return state
    }

    /// Рисует `PillView` вне экрана, пока крылья не замерены, и отдаёт картинку и раскладку.
    private func render(_ state: AppState) throws -> (NSBitmapImageRep, IslandLayout) {
        let root = PillView()
            .environmentObject(state)
            .environmentObject(state.settings)
        let host = NSHostingView(rootView: root)
        // Вид шириной с окно pill, как в панели: окно не подгоняется под содержимое.
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 32), styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 32)
        // Замер крыльев приходит через `onGeometryChange` и меняет раскладку: ждём, пока она устоится.
        var previous = state.pillLayout
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let current = state.pillLayout
            if current == previous, current.rightWing > IslandLayout.restMargin { break }
            previous = current
        }
        // Анимации появления (пружина и прозрачность) успевают доиграть.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.close()
        return (bitmap, state.pillLayout)
    }

    /// Самый правый столбец с непрозрачными пикселями — в точках от левого края вида.
    private func rightmostPainted(_ bitmap: NSBitmapImageRep, width: CGFloat) -> CGFloat? {
        let scale = CGFloat(bitmap.pixelsWide) / width
        for x in stride(from: bitmap.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                return CGFloat(x + 1) / scale
            }
        }
        return nil
    }

    /// Сессий больше четырёх — справа от аватаров «+N». Замер крыла его учитывает, значит, и на картинке
    /// содержимое доходит до края крыла за вычетом отступа; без надписи оно кончается на аватаре.
    func testOverflowCountIsDrawnWhereWingReservesIt() throws {
        let state = makeState()
        state.applyAgents([
            session("s1", .waiting), session("s2", .waiting),
            session("s3", .working), session("s4", .working), session("s5", .working), session("s6", .idle),
        ])
        let presentation = try XCTUnwrap(state.pillPresentation)
        XCTAssertGreaterThan(presentation.sessions.count, PillPresentation.avatarLimit)

        let (bitmap, layout) = try render(state)
        // Тело — по середине вида: справа от него — только прозрачное.
        let bodyMaxX = (800 + layout.body.width) / 2
        let contentMaxX = bodyMaxX - 11  // правый отступ крыла
        let painted = try XCTUnwrap(rightmostPainted(bitmap, width: 800), "шторка пустая")
        XCTAssertLessThanOrEqual(painted, bodyMaxX, "содержимое вылезло за тело")
        XCTAssertEqual(
            painted, contentMaxX, accuracy: 3,
            "«+N» не нарисован: содержимое кончается на \(painted), а крыло замерено до \(contentMaxX)"
        )
    }

    /// Четыре сессии — «+N» нет, и крыло под него места не оставляет.
    func testNoOverflowCountWithFourSessions() throws {
        let state = makeState()
        state.applyAgents([
            session("s1", .waiting), session("s2", .working), session("s3", .working), session("s4", .working),
        ])
        let (bitmap, layout) = try render(state)
        let contentMaxX = (800 + layout.body.width) / 2 - 11
        let painted = try XCTUnwrap(rightmostPainted(bitmap, width: 800), "шторка пустая")
        // У аватара по краям есть прозрачное поле в пару точек.
        XCTAssertEqual(painted, contentMaxX, accuracy: 4)
    }
}
