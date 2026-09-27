// 앱 아이콘을 코드로 그린다: 밤하늘 위에 부릅뜬 눈 — "밤새 깨어 있다".
// 사용: swift tools/make-icon.swift  (personal/allnighter 에서) → Allnighter/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray, locations: [0, 1]) else {
        fatalError("Could not create gradient")
    }
    return gradient
}

// 1024 기준 좌표로 그린다(원점 왼쪽 아래). macOS 아이콘 격자: 본체 824×824, 여백 100.
func draw(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0A0C1C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient(0x2A3160, 0x0A0C1C), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (250, 800, 9, 0.85), (380, 845, 5, 0.6), (640, 812, 7, 0.75), (780, 770, 10, 0.9),
        (205, 690, 5, 0.5), (835, 660, 6, 0.55), (300, 250, 5, 0.35), (760, 215, 6, 0.4),
    ]
    for (x, y, r, a) in stars {
        ctx.setFillColor(color(0xFFFFFF, a))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // 눈: 양 끝이 뾰족한 아몬드. 위아래 곡선의 조절점이 벌어질수록 눈을 크게 뜬다.
    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: 232, y: 500))
    eye.addQuadCurve(to: CGPoint(x: 792, y: 500), control: CGPoint(x: 512, y: 790))
    eye.addQuadCurve(to: CGPoint(x: 232, y: 500), control: CGPoint(x: 512, y: 210))
    eye.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: color(0xFFB938, 0.45))
    ctx.addPath(eye)
    ctx.setFillColor(color(0xFFC94D))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(eye)
    ctx.clip()
    ctx.drawLinearGradient(gradient(0xFFE7A0, 0xF59E1B), start: CGPoint(x: 512, y: 650), end: CGPoint(x: 512, y: 350), options: [])
    // 동공
    ctx.setFillColor(color(0x0E1230))
    ctx.fillEllipse(in: CGRect(x: 512 - 122, y: 500 - 122, width: 244, height: 244))
    // 반사광
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillEllipse(in: CGRect(x: 548 - 34, y: 548 - 34, width: 68, height: 68))
    ctx.restoreGState()

    ctx.restoreGState()
}

func render(size: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create context") }
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(in: ctx)
    guard let image = ctx.makeImage() else { fatalError("Could not render") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(url.path)") }
}

let set = URL(fileURLWithPath: "Allnighter/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-\(points)@\(scale)x.png"
        writePNG(render(size: points * scale), to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
// 저장소 포매터(biome) 형식으로 쓴다: `"key": value`, 끝 줄바꿈.
func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else { fatalError("Could not encode \(url.path)") }
    try (text.replacingOccurrences(of: "\" : ", with: "\": ") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

try writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: set.appendingPathComponent("Contents.json"))
try writeJSON(["info": ["author": "xcode", "version": 1]], to: URL(fileURLWithPath: "Allnighter/Assets.xcassets/Contents.json"))
print("wrote \(images.count) icons")
