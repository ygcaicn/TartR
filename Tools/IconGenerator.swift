import AppKit

guard CommandLine.arguments.count == 3,
      let size = Int(CommandLine.arguments[1]) else { exit(2) }

let output = CommandLine.arguments[2]
let canvas = CGFloat(size)
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: canvas, height: canvas)
let inset = canvas * 0.08
let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                        xRadius: canvas * 0.22, yRadius: canvas * 0.22)
NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.29, alpha: 1),
    NSColor(calibratedRed: 0.24, green: 0.43, blue: 0.78, alpha: 1)
])!.draw(in: tile, angle: -55)

let screenRect = NSRect(x: canvas * 0.20, y: canvas * 0.28,
                        width: canvas * 0.60, height: canvas * 0.46)
let screen = NSBezierPath(roundedRect: screenRect,
                          xRadius: canvas * 0.055, yRadius: canvas * 0.055)
NSColor(calibratedWhite: 0.98, alpha: 0.96).setFill()
screen.fill()

NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.32, alpha: 1).setStroke()
let prompt = NSBezierPath()
prompt.lineWidth = canvas * 0.035
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
prompt.move(to: NSPoint(x: canvas * 0.31, y: canvas * 0.56))
prompt.line(to: NSPoint(x: canvas * 0.39, y: canvas * 0.50))
prompt.line(to: NSPoint(x: canvas * 0.31, y: canvas * 0.44))
prompt.stroke()

let line = NSBezierPath()
line.lineWidth = canvas * 0.035
line.lineCapStyle = .round
line.move(to: NSPoint(x: canvas * 0.45, y: canvas * 0.44))
line.line(to: NSPoint(x: canvas * 0.66, y: canvas * 0.44))
line.stroke()

NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: canvas * 0.68, y: canvas * 0.65,
                            width: canvas * 0.13, height: canvas * 0.13)).fill()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
try png.write(to: URL(fileURLWithPath: output))

