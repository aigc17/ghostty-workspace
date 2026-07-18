import AppKit

// Generates the Ghostty Workspace app icon: a Big Sur-style squircle,
// deep blue like the app theme, with a sidebar strip + terminal prompt.

let size: CGFloat = 1024
let image = NSImage(size: .init(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

// Squircle canvas (Big Sur margin ≈ 100px each side at 1024).
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = 185
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: .init(width: 0, height: -12), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x1B2130).setFill()
squircle.fill()
ctx.restoreGState()

// Background gradient: deep blue, brighter at top.
squircle.setClip()
let gradient = NSGradient(colors: [color(0x2A3346), color(0x171C29)])!
gradient.draw(in: rect, angle: -90)

// Sidebar strip on the left.
let sidebarWidth: CGFloat = 250
let sidebar = CGRect(x: rect.minX, y: rect.minY, width: sidebarWidth, height: rect.height)
color(0xFFFFFF, 0.055).setFill()
NSBezierPath(rect: sidebar).fill()

// Sidebar "rows": one folder row + sessions, one active (accent).
func row(_ i: Int, width: CGFloat, colorValue: NSColor, indent: CGFloat = 0) {
    let rowHeight: CGFloat = 34
    let top = rect.maxY - 150 - CGFloat(i) * 78
    let r = CGRect(x: rect.minX + 62 + indent, y: top, width: width - indent, height: rowHeight)
    colorValue.setFill()
    NSBezierPath(roundedRect: r, xRadius: rowHeight / 2, yRadius: rowHeight / 2).fill()
}
row(0, width: 120, colorValue: color(0xFFFFFF, 0.34))
row(1, width: 100, colorValue: color(0x5EA0EF, 0.95), indent: 28)
row(2, width: 76, colorValue: color(0xFFFFFF, 0.20), indent: 28)
row(3, width: 110, colorValue: color(0xFFFFFF, 0.34))
row(4, width: 86, colorValue: color(0xFFFFFF, 0.20), indent: 28)

// Divider between sidebar and terminal.
color(0xFFFFFF, 0.10).setFill()
NSBezierPath(rect: CGRect(x: sidebar.maxX, y: rect.minY, width: 3, height: rect.height)).fill()

// Terminal prompt "❯" + cursor block in the main area.
let promptFont = NSFont.monospacedSystemFont(ofSize: 300, weight: .bold)
let prompt = NSAttributedString(string: "❯", attributes: [
    .font: promptFont,
    .foregroundColor: color(0x7EE787),
])
prompt.draw(at: .init(x: sidebar.maxX + 90, y: rect.midY - 190))

// Cursor block.
color(0xE6EDF3, 0.92).setFill()
NSBezierPath(
    roundedRect: CGRect(x: sidebar.maxX + 330, y: rect.midY - 155, width: 120, height: 250),
    xRadius: 18, yRadius: 18).fill()

// Inner top highlight for depth.
let highlight = NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0.0)])!
highlight.draw(in: CGRect(x: rect.minX, y: rect.maxY - 220, width: rect.width, height: 220), angle: -90)

// Glossy rim light: a ring around the squircle edge, brighter on top,
// softer on the sides/bottom (Codex-style beveled edge).
ctx.saveGState()
let ringWidth: CGFloat = 10
let innerRect = rect.insetBy(dx: ringWidth, dy: ringWidth)
let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: radius - ringWidth, yRadius: radius - ringWidth)
let ring = NSBezierPath()
ring.append(squircle)
ring.append(innerPath)
ring.windingRule = .evenOdd
ring.setClip()
// Vertical gradient across the ring: strong top, faint mid, slight bottom.
let rim = NSGradient(colorsAndLocations:
    (color(0xFFFFFF, 0.45), 0.0),
    (color(0xFFFFFF, 0.10), 0.35),
    (color(0xFFFFFF, 0.06), 0.75),
    (color(0xFFFFFF, 0.22), 1.0))!
rim.draw(in: rect, angle: -90)
ctx.restoreGState()

// A crisp 1.5pt inner stroke to define the edge all the way around.
let strokePath = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
strokePath.lineWidth = 3
color(0xFFFFFF, 0.16).setStroke()
strokePath.stroke()

image.unlockFocus()

// Write 1024 PNG.
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
