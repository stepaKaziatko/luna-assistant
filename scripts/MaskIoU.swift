// MaskIoU.swift — пересечение силуэтов двух кадров и расстояние между средними цветами тела.
// Запуск: mask-iou <a.png> <b.png>
import AppKit

func load(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("cannot read \(path)"); exit(2)
    }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

let a = load(CommandLine.arguments[1]), b = load(CommandLine.arguments[2])
precondition(a.w == b.w && a.h == b.h, "размеры кадров различаются")
var inter = 0, union = 0
func mean(_ f: (w: Int, h: Int, px: [UInt8])) -> (Double, Double, Double) {
    var r = 0.0, g = 0.0, bl = 0.0, n = 0.0
    for i in stride(from: 0, to: f.px.count, by: 4) where f.px[i + 3] > 200 {
        r += Double(f.px[i]); g += Double(f.px[i + 1]); bl += Double(f.px[i + 2]); n += 1
    }
    return n == 0 ? (0, 0, 0) : (r / n / 255, g / n / 255, bl / n / 255)
}
for i in stride(from: 0, to: a.px.count, by: 4) {
    let ma = a.px[i + 3] > 24, mb = b.px[i + 3] > 24
    if ma && mb { inter += 1 }
    if ma || mb { union += 1 }
}
let ca = mean(a), cb = mean(b)
let dist = sqrt(pow(ca.0 - cb.0, 2) + pow(ca.1 - cb.1, 2) + pow(ca.2 - cb.2, 2))
print(String(format: "IoU=%.3f colorDistance=%.3f", Double(inter) / Double(max(union, 1)), dist))
