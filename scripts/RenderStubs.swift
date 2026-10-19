// RenderStubs.swift — заглушки типов приложения, нужных BotEngine вне приложения.
// Подключается к листу кадров (scripts/render-outfits.sh) и к кадровому тесту
// (scripts/test-character.sh).

import Foundation
import SwiftUI

// MARK: - Stubs (substitutes for app-only types)

@MainActor
final class SoundEngine {
    static let shared = SoundEngine()
    var enabled: Bool = false
    func play(_ name: String) {}
}

extension Notification.Name {
    static let botDizzy          = Notification.Name("luna.botDizzy")
    static let botGreet          = Notification.Name("luna.botGreet")
    static let botBlink          = Notification.Name("luna.botBlink")
    static let botSetTgEs        = Notification.Name("luna.botSetTgEs")
    static let botGulp           = Notification.Name("luna.botGulp")
    static let botMorphTo        = Notification.Name("luna.botMorphTo")
    static let triggerEmote      = Notification.Name("luna.triggerEmote")
    static let triggerSlap       = Notification.Name("luna.triggerSlap")
    static let greetComplete     = Notification.Name("luna.greetComplete")
    static let greetingHover     = Notification.Name("luna.greetingHover")
    static let greetingInterrupt = Notification.Name("luna.greetingInterrupt")
    static let islandAction      = Notification.Name("luna.islandAction")
    static let islandCollapse    = Notification.Name("luna.islandCollapse")
    static let hookReveal        = Notification.Name("luna.hookReveal")
    static let musicReveal       = Notification.Name("luna.musicReveal")
    static let openFullSettings  = Notification.Name("luna.openFullSettings")
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let val = UInt64(h, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
