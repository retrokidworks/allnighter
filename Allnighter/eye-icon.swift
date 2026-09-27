import AppKit

// 메뉴바 아이콘. 앱 아이콘(부릅뜬 눈)을 흑백 템플릿으로 줄인 것 — 꺼짐은 감은 눈, 켜짐은 뜬 눈.
// 템플릿 이미지라 메뉴바 색(다크·라이트·강조)에 맞춰 macOS 가 칠한다.
enum EyeIcon {
    private static let size = NSSize(width: 18, height: 18)
    private static let lineWidth: CGFloat = 1.6

    static func make(open: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            open ? drawOpen() : drawClosed()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = open ? "Allnighter: awake" : "Allnighter: off"
        return image
    }

    // 양 끝이 뾰족한 아몬드와 동공.
    private static func drawOpen() {
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: 1.8, y: 9))
        eye.curve(to: NSPoint(x: 16.2, y: 9), controlPoint1: NSPoint(x: 5.5, y: 15.2), controlPoint2: NSPoint(x: 12.5, y: 15.2))
        eye.curve(to: NSPoint(x: 1.8, y: 9), controlPoint1: NSPoint(x: 12.5, y: 2.8), controlPoint2: NSPoint(x: 5.5, y: 2.8))
        eye.close()
        eye.lineWidth = lineWidth
        eye.lineJoinStyle = .round
        eye.stroke()
        NSBezierPath(ovalIn: NSRect(x: 9 - 2.7, y: 9 - 2.7, width: 5.4, height: 5.4)).fill()
    }

    // 아래로 볼록한 눈꺼풀 선과 속눈썹 셋.
    private static func drawClosed() {
        let lid = NSBezierPath()
        lid.move(to: NSPoint(x: 2, y: 10.5))
        lid.curve(to: NSPoint(x: 16, y: 10.5), controlPoint1: NSPoint(x: 5.5, y: 5.6), controlPoint2: NSPoint(x: 12.5, y: 5.6))
        for (from, to) in [((5.2, 8.1), (4.1, 5.9)), ((9, 6.9), (9, 4.4)), ((12.8, 8.1), (13.9, 5.9))] {
            lid.move(to: NSPoint(x: from.0, y: from.1))
            lid.line(to: NSPoint(x: to.0, y: to.1))
        }
        lid.lineWidth = lineWidth
        lid.lineCapStyle = .round
        lid.stroke()
    }
}
