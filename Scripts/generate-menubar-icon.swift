import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-menubar-icon.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSize = 72.0
let center = NSPoint(x: canvasSize / 2, y: canvasSize / 2)
let radius = 28.0
let canvas = NSImage(size: NSSize(width: canvasSize, height: canvasSize))

func arrowhead(at tip: NSPoint, pointing direction: NSPoint) {
    let length = 9.0
    let halfWidth = 5.5
    let base = NSPoint(x: tip.x - direction.x * length, y: tip.y - direction.y * length)
    let normal = NSPoint(x: -direction.y, y: direction.x)
    let head = NSBezierPath()
    head.move(to: tip)
    head.line(to: NSPoint(x: base.x + normal.x * halfWidth, y: base.y + normal.y * halfWidth))
    head.line(to: NSPoint(x: base.x - normal.x * halfWidth, y: base.y - normal.y * halfWidth))
    head.close()
    head.fill()
}

func pointOnCircle(_ angle: Double) -> NSPoint {
    NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
}

canvas.lockFocus()
NSColor.white.setStroke()
NSColor.white.setFill()

// The menu-bar mark reduces Morph's M and two-way conversion loop to a crisp
// monochrome glyph that stays legible on both light and dark menu bars.
let upperLoop = NSBezierPath()
upperLoop.lineWidth = 4.5
upperLoop.lineCapStyle = .round
upperLoop.appendArc(
    withCenter: center,
    radius: radius,
    startAngle: 155,
    endAngle: 25,
    clockwise: true
)
upperLoop.stroke()
arrowhead(at: pointOnCircle(25 * .pi / 180), pointing: NSPoint(x: sin(25 * .pi / 180), y: -cos(25 * .pi / 180)))

let lowerLoop = NSBezierPath()
lowerLoop.lineWidth = 4.5
lowerLoop.lineCapStyle = .round
lowerLoop.appendArc(
    withCenter: center,
    radius: radius,
    startAngle: -25,
    endAngle: -155,
    clockwise: true
)
lowerLoop.stroke()
arrowhead(at: pointOnCircle(-155 * .pi / 180), pointing: NSPoint(x: sin(-155 * .pi / 180), y: -cos(-155 * .pi / 180)))

let morphLetter = NSBezierPath()
morphLetter.lineWidth = 7
morphLetter.lineCapStyle = .round
morphLetter.lineJoinStyle = .round
morphLetter.move(to: NSPoint(x: 22, y: 24))
morphLetter.line(to: NSPoint(x: 27, y: 49))
morphLetter.line(to: NSPoint(x: 36, y: 35))
morphLetter.line(to: NSPoint(x: 45, y: 49))
morphLetter.line(to: NSPoint(x: 50, y: 24))
morphLetter.stroke()
canvas.unlockFocus()

guard let tiffData = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Couldn't encode the menu-bar icon as PNG.\n", stderr)
    exit(1)
}

try pngData.write(to: outputURL, options: .atomic)
