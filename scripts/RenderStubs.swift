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
    static let botDizzy          = Notification.Name("notchBuddy.botDizzy")
    static let botGreet          = Notification.Name("notchBuddy.botGreet")
    static let botBlink          = Notification.Name("notchBuddy.botBlink")
    static let botSetTgEs        = Notification.Name("notchBuddy.botSetTgEs")
    static let botGulp           = Notification.Name("notchBuddy.botGulp")
    static let botMorphTo        = Notification.Name("notchBuddy.botMorphTo")
    static let triggerEmote      = Notification.Name("notchBuddy.triggerEmote")
    static let triggerSlap       = Notification.Name("notchBuddy.triggerSlap")
    static let greetComplete     = Notification.Name("notchBuddy.greetComplete")
    static let greetingHover     = Notification.Name("notchBuddy.greetingHover")
    static let greetingInterrupt = Notification.Name("notchBuddy.greetingInterrupt")
    static let islandAction      = Notification.Name("notchBuddy.islandAction")
    static let islandCollapse    = Notification.Name("notchBuddy.islandCollapse")
    static let hookReveal        = Notification.Name("notchBuddy.hookReveal")
    static let musicReveal       = Notification.Name("notchBuddy.musicReveal")
    static let openFullSettings  = Notification.Name("notchBuddy.openFullSettings")
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
