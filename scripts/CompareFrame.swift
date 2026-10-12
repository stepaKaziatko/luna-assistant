// CompareFrame.swift — один кадр BotEngine в PNG с прозрачным фоном.
// Собирается дважды (upstream Mochi и рабочая копия) скриптом compare-with-mochi.sh.
// Запуск: compare-frame <out.png> <state>

import Foundation
import SwiftUI
import AppKit

struct CompareCanvas: View {
    let state: BotState
    var body: some View {
        Canvas { ctx, size in
            let e = BotEngine()
            e.nextBlink = .greatestFiniteMagnitude
            e.miniNextBehavior = .greatestFiniteMagnitude
            e.setState(state, force: true)
            let c = NSColor(cgColor: e.cfg.color)!.usingColorSpace(.sRGB)!
            e.col = (c.redComponent, c.greenComponent, c.blueComponent)
            e.tint = e.cfg.tint
            e.badge = e.cfg.badge
            e.badgeS = e.cfg.badge == nil ? 0 : 1
            e.tilt = e.cfg.tilt
            e.drawHandsBehind(context: ctx, size: size)
            e.drawOutfitBehind(context: ctx, size: size)
            e.draw(context: ctx, size: size)
            e.drawOutfitFront(context: ctx, size: size)
            e.drawHandsAndExtras(context: ctx, size: size)
        }
        .frame(width: 200, height: 200)
    }
}

@main
struct CompareFrame {
    static func main() {
        MainActor.assumeIsolated {
            let args = CommandLine.arguments
            guard args.count >= 3, let state = BotState(rawValue: args[2]) else {
                print("usage: compare-frame <out.png> <state>"); exit(2)
            }
            let r = ImageRenderer(content: CompareCanvas(state: state))
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("render failed"); exit(1)
            }
            try! png.write(to: URL(fileURLWithPath: args[1]))
        }
    }
}
