// Рисует иконки Luna: значок приложения для macOS, значок строки меню и иконки iPhone-таргета.
// Иконки coucou под лицензией автора и в репозиторий не берутся; эти — свои: луна на тёмном небе.
//
//   swift apps/macos/scripts/render-icons.swift        # пишет PNG в Assets.xcassets и PhoneAssets.xcassets
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let mac = root.appendingPathComponent("Assets.xcassets")
let phone = root.appendingPathComponent("PhoneAssets.xcassets")

struct Tint { let top: NSColor; let bottom: NSColor }
let tints: [String: Tint] = [
    "Orange":   Tint(top: NSColor(red: 0.16, green: 0.18, blue: 0.36, alpha: 1), bottom: NSColor(red: 0.05, green: 0.06, blue: 0.16, alpha: 1)),
    "Blue":     Tint(top: NSColor(red: 0.12, green: 0.36, blue: 0.75, alpha: 1), bottom: NSColor(red: 0.04, green: 0.14, blue: 0.38, alpha: 1)),
    "Green":    Tint(top: NSColor(red: 0.12, green: 0.50, blue: 0.38, alpha: 1), bottom: NSColor(red: 0.03, green: 0.22, blue: 0.17, alpha: 1)),
    "Purple":   Tint(top: NSColor(red: 0.42, green: 0.26, blue: 0.70, alpha: 1), bottom: NSColor(red: 0.18, green: 0.08, blue: 0.36, alpha: 1)),
    "Pink":     Tint(top: NSColor(red: 0.78, green: 0.30, blue: 0.52, alpha: 1), bottom: NSColor(red: 0.40, green: 0.10, blue: 0.26, alpha: 1)),
    "Graphite": Tint(top: NSColor(red: 0.34, green: 0.35, blue: 0.38, alpha: 1), bottom: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)),
]

/// Луна: полумесяц со звездой. `inset` — доля поля вокруг фигуры (у macOS иконки есть свои поля).
func drawMoon(in rect: CGRect, moon: NSColor, star: NSColor?) {
    let s = rect.width
    let r = s * 0.30
    let center = CGPoint(x: rect.midX - s * 0.03, y: rect.midY)
    let disc = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    // Тень, вырезающая серп: смещённый круг того же радиуса
    let bite = NSBezierPath(ovalIn: CGRect(x: center.x - r + s * 0.17, y: center.y - r + s * 0.07, width: 2 * r, height: 2 * r))
    let crescent = disc.copy() as! NSBezierPath
    crescent.append(bite.reversed)
    crescent.windingRule = .evenOdd
    moon.setFill()
    crescent.fill()
    if let star {
        let sr = s * 0.045
        let sc = CGPoint(x: rect.midX + s * 0.22, y: rect.midY + s * 0.20)
        let p = NSBezierPath()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let rad = i % 2 == 0 ? sr : sr * 0.38
            let pt = CGPoint(x: sc.x + cos(a) * rad, y: sc.y + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        star.setFill()
        p.fill()
    }
}

func render(size: Int, draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Значок приложения: скруглённый квадрат с градиентом неба и луной. `margin` — поле вокруг
/// фигуры (macOS рисует иконки с полями, iOS — на всю площадь и скругляет сам).
func appIcon(size: Int, tint: Tint, margin: CGFloat, corner: CGFloat, dark: Bool = false, tinted: Bool = false) -> Data {
    render(size: size) { full in
        let inset = full.width * margin
        let rect = full.insetBy(dx: inset, dy: inset)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * corner, yRadius: rect.width * corner)
        if tinted {
            NSColor.black.setFill(); shape.fill()
            drawMoon(in: rect, moon: .white, star: NSColor(white: 0.8, alpha: 1))
            return
        }
        let top = dark ? tint.top.blended(withFraction: 0.5, of: .black)! : tint.top
        let bottom = dark ? tint.bottom.blended(withFraction: 0.5, of: .black)! : tint.bottom
        NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)
        drawMoon(in: rect, moon: NSColor(red: 0.98, green: 0.95, blue: 0.82, alpha: 1),
                 star: NSColor(red: 1, green: 0.96, blue: 0.80, alpha: 0.9))
    }
}

func write(_ data: Data, to dir: URL, _ name: String) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try data.write(to: dir.appendingPathComponent(name))
}

func json(_ dir: URL, _ text: String) throws {
    try write(text.data(using: .utf8)!, to: dir, "Contents.json")
}

// macOS: AppIcon.appiconset
let macIcon = mac.appendingPathComponent("AppIcon.appiconset")
var macImages: [String] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try write(appIcon(size: pt * scale, tint: tints["Orange"]!, margin: 0.09, corner: 0.225), to: macIcon, name)
    macImages.append("""
        { "idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": "\(name)" }
    """)
}
try json(macIcon, "{\n  \"images\": [\n\(macImages.joined(separator: ",\n"))\n  ],\n  \"info\": { \"author\": \"xcode\", \"version\": 1 }\n}\n")

// macOS: значок строки меню — шаблон (чёрный с прозрачностью), система красит его сама
let menu = mac.appendingPathComponent("MenuBarIcon.imageset")
for (scale, name) in [(1, "menubar.png"), (2, "menubar@2x.png"), (3, "menubar@3x.png")] {
    try write(render(size: 18 * scale) { r in drawMoon(in: r.insetBy(dx: -r.width * 0.12, dy: -r.width * 0.12), moon: .black, star: nil) }, to: menu, name)
}
try json(menu, """
{
  "images": [
    { "idiom": "universal", "scale": "1x", "filename": "menubar.png" },
    { "idiom": "universal", "scale": "2x", "filename": "menubar@2x.png" },
    { "idiom": "universal", "scale": "3x", "filename": "menubar@3x.png" }
  ],
  "info": { "author": "xcode", "version": 1 },
  "properties": { "template-rendering-intent": "template" }
}

""")

// iPhone: основная иконка (светлая, тёмная, tinted), альтернативные цвета и их превью в настройках
let phoneIcon = phone.appendingPathComponent("AppIcon.appiconset")
let orange = tints["Orange"]!
try write(appIcon(size: 1024, tint: orange, margin: 0, corner: 0), to: phoneIcon, "icon-1024.png")
try write(appIcon(size: 1024, tint: orange, margin: 0, corner: 0, dark: true), to: phoneIcon, "icon-1024-dark.png")
try write(appIcon(size: 1024, tint: orange, margin: 0, corner: 0, tinted: true), to: phoneIcon, "icon-1024-tinted.png")
try json(phoneIcon, """
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "icon-1024-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "icon-1024-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

""")
for (name, tint) in tints {
    if name != "Orange" {
        let dir = phone.appendingPathComponent("AppIcon-\(name).appiconset")
        try write(appIcon(size: 1024, tint: tint, margin: 0, corner: 0), to: dir, "icon-1024.png")
        try json(dir, """
        {
          "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
          "info" : { "author" : "xcode", "version" : 1 }
        }

        """)
    }
    let preview = phone.appendingPathComponent("IconPreview-\(name).imageset")
    try write(appIcon(size: 180, tint: tint, margin: 0, corner: 0.225), to: preview, "preview.png")
    try json(preview, """
    {
      "images" : [ { "filename" : "preview.png", "idiom" : "universal" } ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """)
}
print("иконки записаны в \(mac.lastPathComponent) и \(phone.lastPathComponent)")
