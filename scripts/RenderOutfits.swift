// RenderOutfits.swift — лист кадров персонажа (наряды, состояния, глаза), реальным BotEngine
// Compile + run via: bash scripts/render-outfits.sh
// Output: /tmp/luna-outfits.png

import Foundation
import SwiftUI
import AppKit

// MARK: - Cell view — one frame of the real BotEngine
//
// Лист рисует тем же кодом, что и приложение (`BotEngine.draw` и проходы нарядов), а не
// своей копией тела: если облик в приложении меняется, лист меняется вместе с ним.

struct LunaCell: View {
    var outfit: Outfit = .none
    var state: BotState = .idle
    var yaw: CGFloat = 0
    var pitch: CGFloat = 0
    var tilt: CGFloat = 0
    var phys: (dx: CGFloat, dy: CGFloat) = (0, 0)
    let cellSize: CGFloat
    var roll: CGFloat = 0
    var presence: CGFloat = 1
    var eye: EyeShape? = nil
    var hands: CGFloat = 0
    var blush: CGFloat = 0
    var mini = false
    var miniHex: String? = nil

    var body: some View {
        Canvas { context, sz in
            // Движок рисует по холсту W×H с R = 0.3·W; лист показывает его на 62 % ячейки.
            let k: CGFloat = 0.62
            let size = CGSize(width: sz.width * k, height: sz.height * k)
            var ctx = context
            ctx.translateBy(x: sz.width * (1 - k) / 2, y: sz.height * (1 - k) / 2)

            let e = BotEngine()
            e.isMini = mini
            if let hx = miniHex { e.bodyColor = Color(hex: hx).renderCGColor }
            e.nextBlink = .greatestFiniteMagnitude
            e.miniNextBehavior = .greatestFiniteMagnitude
            e.setState(state, force: true)
            e.col = e.cfg.color.renderTuple
            e.tint = e.cfg.tint
            e.badge = e.cfg.badge
            e.badgeS = e.cfg.badge == nil ? 0 : 1
            e.yaw = yaw; e.pitch = pitch; e.tilt = tilt != 0 ? tilt : e.cfg.tilt
            e.physDx = phys.dx; e.physDy = phys.dy
            e.roll = roll
            e.hands = hands; e.blush = blush
            if let eye { e.eyeOverride = eye; e.eyeOverrideUntil = .greatestFiniteMagnitude }
            if outfit != .none { e.outfit = outfit; e.outfitPresence = presence }

            // Как BotCanvasView: наряд вращается вместе с телом, поэтому поворачиваем контекст.
            if outfit != .none && presence > 0.05 && abs(roll) > 0.001 {
                let c = e.bodyCenter(size: size)
                var rigid = ctx
                rigid.translateBy(x: c.x, y: c.y)
                rigid.rotate(by: .radians(roll))
                rigid.translateBy(x: -c.x, y: -c.y)
                e.drawHandsBehind(context: rigid, size: size)
                e.drawOutfitBehind(context: rigid, size: size)
                e.draw(context: rigid, size: size)
                e.drawOutfitFront(context: rigid, size: size)
            } else {
                e.drawHandsBehind(context: ctx, size: size)
                e.drawOutfitBehind(context: ctx, size: size)
                e.draw(context: ctx, size: size)
                e.drawOutfitFront(context: ctx, size: size)
            }
            e.drawHandsAndExtras(context: ctx, size: size)
        }
        .frame(width: cellSize, height: cellSize)
    }
}

extension Color { var renderCGColor: CGColor { NSColor(self).cgColor } }
extension CGColor {
    var renderTuple: (CGFloat, CGFloat, CGFloat) {
        let c = NSColor(cgColor: self)!.usingColorSpace(.sRGB)!
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
}

// MARK: - Grid view

// Outfit order matching sheet.html
private let targetOutfits: [Outfit] = [
    .none, .beanie, .santaHat, .partyHat, .crown, .witchHat,
    .sunglasses, .roundGlasses, .scarf, .pumpkin, .bow,
]

private struct PoseSpec {
    let label: String
    let yaw: CGFloat
    let pitch: CGFloat
    let tilt: CGFloat
    let phys: (dx: CGFloat, dy: CGFloat)
    let size: CGFloat
}

// Columns matching sheet.html cols array + small pill-preview column (W=190, scale=0.62; small=64)
private let poses: [PoseSpec] = [
    PoseSpec(label: "L",     yaw: -0.5,  pitch:  0,     tilt: 0,    phys: (0.6,  0),    size: 190),
    PoseSpec(label: "front", yaw:  0,    pitch:  0,     tilt: 0,    phys: (0,    0),    size: 190),
    PoseSpec(label: "R",     yaw:  0.5,  pitch:  0,     tilt: 0,    phys: (-0.6, 0),    size: 190),
    PoseSpec(label: "up",    yaw:  0.15, pitch:  0.4,   tilt: 0,    phys: (0,    0.4),  size: 190),
    PoseSpec(label: "down",  yaw: -0.2,  pitch: -0.5,   tilt: 0,    phys: (0,   -0.4),  size: 190),
    PoseSpec(label: "tilt",  yaw:  0.3,  pitch: -0.25,  tilt: 0.12, phys: (-0.3, 0),   size: 190),
    PoseSpec(label: "mini",  yaw:  0,    pitch:  0,     tilt: 0,    phys: (0,    0),    size: 64),
]

private let labelW: CGFloat = 90
private let gap:    CGFloat = 6

struct OutfitGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // Column headers
            HStack(spacing: gap) {
                Spacer().frame(width: labelW)
                ForEach(poses.indices, id: \.self) { i in
                    Text(poses[i].label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: poses[i].size, alignment: .center)
                }
            }
            // One row per outfit
            ForEach(targetOutfits.indices, id: \.self) { oi in
                let outfit = targetOutfits[oi]
                HStack(spacing: gap) {
                    Text(outfit.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(poses.indices, id: \.self) { pi in
                        let p = poses[pi]
                        LunaCell(outfit: outfit, yaw: p.yaw, pitch: p.pitch,
                                  tilt: p.tilt, phys: p.phys, cellSize: p.size)
                            .background(pi == poses.count - 1
                                        ? Color.black
                                        : Color(red: 0.083, green: 0.090, blue: 0.106))
                            .clipShape(RoundedRectangle(cornerRadius: pi == poses.count - 1 ? 0 : 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - Roll planche

private let rollOutfits: [Outfit] = [
    .none, .beanie, .santaHat, .witchHat, .crown,
    .sunglasses, .roundGlasses, .scarf, .bow, .pumpkin, .bunnyEars
]

private let rollValues: [CGFloat] = [0, CGFloat.pi/3, CGFloat.pi*2/3, CGFloat.pi, CGFloat.pi*4/3, CGFloat.pi*5/3]

struct RollGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // Column headers
            HStack(spacing: gap) {
                Spacer().frame(width: labelW)
                ForEach(rollValues.indices, id: \.self) { i in
                    Text(String(format: "%.2fπ", rollValues[i] / .pi))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 120, alignment: .center)
                }
            }
            ForEach(rollOutfits.indices, id: \.self) { oi in
                let outfit = rollOutfits[oi]
                HStack(spacing: gap) {
                    Text(outfit.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(rollValues.indices, id: \.self) { ri in
                        LunaCell(outfit: outfit, yaw: 0, pitch: 0, tilt: 0, phys: (0, 0),
                                  cellSize: 120, roll: rollValues[ri])
                            .background(Color(red: 0.083, green: 0.090, blue: 0.106))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - Transition planche

private let transitionOutfits: [Outfit] = [.witchHat, .santaHat, .bunnyEars, .scarf]
private let presenceValues: [CGFloat] = [0, 0.3, 0.6, 1]

struct TransitionGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // Column headers
            HStack(spacing: gap) {
                Spacer().frame(width: labelW)
                ForEach(presenceValues.indices, id: \.self) { i in
                    Text(String(format: "p=%.1f", presenceValues[i]))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 120, alignment: .center)
                }
            }
            ForEach(transitionOutfits.indices, id: \.self) { oi in
                let outfit = transitionOutfits[oi]
                HStack(spacing: gap) {
                    Text(outfit.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(presenceValues.indices, id: \.self) { pi in
                        LunaCell(outfit: outfit, yaw: 0, pitch: 0, tilt: 0, phys: (0, 0),
                                  cellSize: 120, presence: presenceValues[pi])
                            .background(Color(red: 0.083, green: 0.090, blue: 0.106))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - States planche
//
// Состояния, взгляды, эмоции и мини-Luna: то, что проверяют глазами при смене облика.

private let stateRows: [BotState] = [.idle, .working, .thinking, .searching, .approval, .question,
                                     .error, .finished, .ratelimit, .sleeping, .dizzy]
private let emoteEyes: [EyeShape] = [.pill, .wide, .dot, .line, .flat, .happy, .closed,
                                     .spiral, .heart, .star, .tired, .wink, .cup]
private let miniColors = ["#FFFFFF", "#E86A6A", "#3E86E0", "#EFAE5A", "#8C73F2", "#34D399"]

struct StateGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                ForEach(stateRows.indices, id: \.self) { i in
                    LunaCell(state: stateRows[i], cellSize: 120, hands: i == 0 ? 1 : 0,
                              blush: stateRows[i] == .finished ? 0.8 : 0)
                        .background(Color(red: 0.083, green: 0.090, blue: 0.106))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack(spacing: gap) {
                ForEach(stateRows.indices, id: \.self) { i in
                    LunaCell(state: stateRows[i], yaw: 0.55, pitch: -0.2, cellSize: 120)
                        .background(Color(red: 0.083, green: 0.090, blue: 0.106))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack(spacing: gap) {
                ForEach(emoteEyes.indices, id: \.self) { i in
                    LunaCell(cellSize: 100, eye: emoteEyes[i])
                        .background(Color(red: 0.083, green: 0.090, blue: 0.106))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack(spacing: gap) {
                ForEach(miniColors, id: \.self) { hx in
                    LunaCell(state: .working, cellSize: 64, mini: true, miniHex: hx)
                        .background(Color.black)
                }
                LunaCell(state: .idle, cellSize: 28, mini: true, miniHex: "#E86A6A").background(Color.black)
                LunaCell(state: .idle, cellSize: 20, mini: true, miniHex: "#3E86E0").background(Color.black)
                LunaCell(state: .idle, cellSize: 60).background(Color.black)
                LunaCell(state: .working, cellSize: 33).background(Color.black)
            }
        }
        .padding(12)
        .background(Color(red: 0.043, green: 0.047, blue: 0.055))
    }
}

// MARK: - Helper to render and save a view

@MainActor
private func renderAndSave<V: View>(_ view: V, path: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2.0
    guard let nsImage = renderer.nsImage else {
        print("Error: ImageRenderer returned nil for \(path)")
        return
    }
    guard let tiff = nsImage.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:])
    else {
        print("Error: PNG conversion failed for \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("✓ \(path) — \(Int(nsImage.size.width))×\(Int(nsImage.size.height)) @ 2×")
    } catch {
        print("Error writing \(path): \(error)")
    }
}

// MARK: - Entry point

@main
struct RenderOutfits {
    static func main() {
        MainActor.assumeIsolated {
            renderAndSave(OutfitGrid(),      path: "/tmp/luna-outfits.png")
            renderAndSave(RollGrid(),        path: "/tmp/luna-roll.png")
            renderAndSave(TransitionGrid(),  path: "/tmp/luna-transition.png")
            renderAndSave(StateGrid(),       path: "/tmp/luna-states.png")
        }
    }
}
