// Draws the DMG window background: a golf fairway with a tee box under the app, a putting green with a
// flag under the Applications link, a bunker, and one solid arrow pointing from the app to Applications.
//
// Usage: swift scripts/make-dmg-background.swift <output.png> <width> <height> <arrowStartX> <arrowEndX> <arrowY>
//
// Sizes are in points. The PNG is rendered at 2x and tagged at 144 DPI so Finder draws it sharp on Retina displays.

import AppKit

let args = CommandLine.arguments
guard args.count == 7,
      let width = Int(args[2]), let height = Int(args[3]),
      let startX = Double(args[4]), let endX = Double(args[5]), let arrowY = Double(args[6]) else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <output.png> <width> <height> <arrowStartX> <arrowEndX> <arrowY>\n".data(using: .utf8)!)
    exit(1)
}

let w = CGFloat(width)
let h = CGFloat(height)
let scale = 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: width * scale, pixelsHigh: height * scale,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    exit(1)
}
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.imageInterpolation = .high

// Finder places the image with its top-left at the window's top-left, so flip to a top-down coordinate system.
let flip = NSAffineTransform()
flip.translateX(by: 0, yBy: h)
flip.scaleX(by: 1, yBy: -1)
flip.concat()

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// Deterministic random numbers so every build produces the same image.
struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
var rng = LCG(state: 42)
func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
    CGFloat.random(in: range, using: &rng)
}

// Fairway: base green with a soft top-to-bottom gradient.
let fairway = NSGradient(colors: [rgb(106, 170, 52), rgb(92, 154, 44)])!
fairway.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)

// Mowing stripes: alternating diagonal bands.
let stripeWidth: CGFloat = 46
rgb(255, 255, 255, 0.07).setFill()
var x: CGFloat = -h
var band = 0
while x < w + h {
    if band % 2 == 0 {
        let stripe = NSBezierPath()
        stripe.move(to: NSPoint(x: x, y: 0))
        stripe.line(to: NSPoint(x: x + stripeWidth, y: 0))
        stripe.line(to: NSPoint(x: x + stripeWidth + h * 0.35, y: h))
        stripe.line(to: NSPoint(x: x + h * 0.35, y: h))
        stripe.close()
        stripe.fill()
    }
    x += stripeWidth
    band += 1
}

// Grass speckle.
for _ in 0..<9000 {
    let px = random(0...w)
    let py = random(0...h)
    let size = random(0.6...1.6)
    let light = Bool.random(using: &rng)
    (light ? rgb(190, 235, 120, 0.22) : rgb(30, 80, 20, 0.22)).setFill()
    NSBezierPath(ovalIn: NSRect(x: px, y: py, width: size, height: size)).fill()
}

// Soft-edged blob helper: fills the same path a few times, growing outward with decreasing alpha.
func drawSoftBlob(_ path: NSBezierPath, fill: NSColor, rim: NSColor, rimWidth: CGFloat) {
    rim.setStroke()
    path.lineWidth = rimWidth
    path.stroke()
    fill.setFill()
    path.fill()
}

func blob(center: NSPoint, radiusX: CGFloat, radiusY: CGFloat, wobble: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 24
    var points: [NSPoint] = []
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let r = 1 + wobble * sin(t * 3 + 0.7) * 0.5 + wobble * cos(t * 2 - 1.1) * 0.5
        points.append(NSPoint(x: center.x + cos(t) * radiusX * r, y: center.y + sin(t) * radiusY * r))
    }
    path.move(to: points[0])
    for i in 0..<steps {
        let p0 = points[i]
        let p1 = points[(i + 1) % steps]
        let pPrev = points[(i + steps - 1) % steps]
        let pNext = points[(i + 2) % steps]
        let c1 = NSPoint(x: p0.x + (p1.x - pPrev.x) / 6, y: p0.y + (p1.y - pPrev.y) / 6)
        let c2 = NSPoint(x: p1.x - (pNext.x - p0.x) / 6, y: p1.y - (pNext.y - p0.y) / 6)
        path.curve(to: p1, controlPoint1: c1, controlPoint2: c2)
    }
    path.close()
    return path
}

// Lighter cut grass under each icon, big enough to sit behind the label too.
let appCenter = NSPoint(x: startX - 80, y: arrowY + 10)
let appsCenter = NSPoint(x: endX + 80, y: arrowY + 10)
let lightGreen = rgb(142, 204, 82)
let fringe = rgb(122, 186, 66)

// Tee box: a rounded rectangle under the app.
let teeRect = NSRect(x: appCenter.x - 78, y: appCenter.y - 92, width: 156, height: 196)
let tee = NSBezierPath(roundedRect: teeRect, xRadius: 28, yRadius: 28)
drawSoftBlob(tee, fill: lightGreen, rim: fringe, rimWidth: 10)

// Putting green: a wobbly blob under Applications.
let green = blob(center: appsCenter, radiusX: 84, radiusY: 100, wobble: 0.08)
drawSoftBlob(green, fill: lightGreen, rim: fringe, rimWidth: 10)

// Bunker in the lower-left corner.
let bunker = blob(center: NSPoint(x: 64, y: h - 86), radiusX: 64, radiusY: 38, wobble: 0.25)
drawSoftBlob(bunker, fill: rgb(236, 218, 170), rim: rgb(208, 188, 136), rimWidth: 8)
for _ in 0..<500 {
    let px = random((bunker.bounds.minX)...(bunker.bounds.maxX))
    let py = random((bunker.bounds.minY)...(bunker.bounds.maxY))
    guard bunker.contains(NSPoint(x: px, y: py)) else { continue }
    rgb(200, 176, 120, 0.35).setFill()
    NSBezierPath(ovalIn: NSRect(x: px, y: py, width: 1.2, height: 1.2)).fill()
}

// Hole and flag at the upper-right of the putting green.
let hole = NSPoint(x: appsCenter.x + 72, y: appsCenter.y - 78)
rgb(20, 40, 15, 0.25).setFill()
NSBezierPath(ovalIn: NSRect(x: hole.x - 7, y: hole.y - 2, width: 14, height: 6)).fill()
rgb(30, 50, 20).setFill()
NSBezierPath(ovalIn: NSRect(x: hole.x - 5, y: hole.y - 2.5, width: 10, height: 5)).fill()

let poleTop = NSPoint(x: hole.x, y: hole.y - 70)
let pole = NSBezierPath()
pole.lineWidth = 2.5
pole.lineCapStyle = .round
pole.move(to: hole)
pole.line(to: poleTop)
rgb(0, 0, 0, 0.25).setStroke()
pole.transform(using: AffineTransform(translationByX: 1.5, byY: 1.5))
pole.stroke()
pole.transform(using: AffineTransform(translationByX: -1.5, byY: -1.5))
NSColor.white.setStroke()
pole.stroke()

let flag = NSBezierPath()
flag.move(to: NSPoint(x: poleTop.x, y: poleTop.y))
flag.line(to: NSPoint(x: poleTop.x + 32, y: poleTop.y + 10))
flag.line(to: NSPoint(x: poleTop.x, y: poleTop.y + 22))
flag.close()
rgb(0, 0, 0, 0.25).setFill()
flag.transform(using: AffineTransform(translationByX: 1.5, byY: 1.5))
flag.fill()
flag.transform(using: AffineTransform(translationByX: -1.5, byY: -1.5))
rgb(226, 48, 48).setFill()
flag.fill()

// One solid arrow from the app to Applications.
let shaftHalf: CGFloat = 6
let headLength: CGFloat = 30
let headHalf: CGFloat = 19
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: startX, y: arrowY - shaftHalf))
arrow.line(to: NSPoint(x: endX - headLength, y: arrowY - shaftHalf))
arrow.line(to: NSPoint(x: endX - headLength, y: arrowY - headHalf))
arrow.line(to: NSPoint(x: endX, y: arrowY))
arrow.line(to: NSPoint(x: endX - headLength, y: arrowY + headHalf))
arrow.line(to: NSPoint(x: endX - headLength, y: arrowY + shaftHalf))
arrow.line(to: NSPoint(x: startX, y: arrowY + shaftHalf))
arrow.close()
arrow.lineJoinStyle = .round
arrow.lineWidth = 4

rgb(0, 0, 0, 0.22).setFill()
arrow.transform(using: AffineTransform(translationByX: 0, byY: 3))
arrow.fill()
arrow.transform(using: AffineTransform(translationByX: 0, byY: -3))
NSColor.white.setFill()
NSColor.white.setStroke()
arrow.stroke()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: args[1]))
} catch {
    FileHandle.standardError.write("failed to write \(args[1]): \(error)\n".data(using: .utf8)!)
    exit(1)
}
