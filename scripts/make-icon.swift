#!/usr/bin/env swift
// Generates a 1024×1024 PNG of the EGO Mac app icon.
// Style modeled on the EGO Cep'te logo: heavy red "EGO" with a stylized
// Ankara-tower / Atakule wireframe sphere replacing the "O", and "MAC"
// below in matching red. Subtle diagonal light-gray gradient background.
//
// Usage: swift scripts/make-icon.swift assets/icon-1024.png

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    print("usage: \(CommandLine.arguments[0]) <output.png>")
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let canvas: CGFloat = 1024
let img = NSImage(size: NSSize(width: canvas, height: canvas))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// MARK: - 1. Background gradient (mirrors EGO Cep'te's subtle diagonal wash)

let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(white: 0.985, alpha: 1.0).cgColor,
        NSColor(white: 0.93,  alpha: 1.0).cgColor,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: canvas),
    end: CGPoint(x: canvas, y: 0),
    options: []
)

// Soft diagonal sheen (Cep'te has a faint white curve crossing the image).
ctx.saveGState()
let sheen = NSBezierPath()
sheen.move(to: NSPoint(x: 0, y: canvas * 0.42))
sheen.curve(
    to: NSPoint(x: canvas, y: canvas * 0.58),
    controlPoint1: NSPoint(x: canvas * 0.35, y: canvas * 0.55),
    controlPoint2: NSPoint(x: canvas * 0.65, y: canvas * 0.45)
)
sheen.line(to: NSPoint(x: canvas, y: canvas))
sheen.line(to: NSPoint(x: 0, y: canvas))
sheen.close()
NSColor(white: 1.0, alpha: 0.55).setFill()
sheen.fill()
ctx.restoreGState()

// MARK: - 2. Brand color

let brandRed = NSColor(red: 0.83, green: 0.16, blue: 0.16, alpha: 1.0)

// MARK: - 3. EGO text (with placeholder space for the dome glyph as "O")

// We render "EG" then the dome icon, then leave "O" out — so we need to
// measure the typography by hand.
// We use the system bold heavy font at a large size.
let egoFontSize: CGFloat = 360
let egoFont = NSFont.systemFont(ofSize: egoFontSize, weight: .heavy)

// Letterform color + slight shadow for depth.
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0.0, alpha: 0.10)
shadow.shadowBlurRadius = 8
shadow.shadowOffset = NSSize(width: 0, height: -3)

let egTextAttrs: [NSAttributedString.Key: Any] = [
    .font: egoFont,
    .foregroundColor: brandRed,
    .kern: -8,
    .shadow: shadow,
]

let egText = NSAttributedString(string: "EG", attributes: egTextAttrs)
let oText = NSAttributedString(string: "O", attributes: egTextAttrs)
let egSize = egText.size()
let oSize = oText.size()

// Total horizontal width for the EG + dome row (dome uses the same width as the O).
let domeWidth = oSize.width * 0.95
let totalWidth = egSize.width + domeWidth + 16  // 16pt of optical gap between G and dome

// Center horizontally
let startX = (canvas - totalWidth) / 2

// Vertical position — upper half of the canvas.
let egoBaselineY = canvas * 0.40

egText.draw(at: NSPoint(x: startX, y: egoBaselineY))

// MARK: - 4. Dome glyph in place of "O"

let domeRect = NSRect(
    x: startX + egSize.width + 16,
    y: egoBaselineY + (egoFont.capHeight * 0.04),
    width: domeWidth,
    height: egoFont.capHeight + 8
)

ctx.saveGState()
brandRed.setStroke()
brandRed.setFill()

let domeLineWidth: CGFloat = 18

// 4a. Antenna spires on top — drawn first so they sit behind the dome's outer ring.
let antennaCount = 5
for i in 0..<antennaCount {
    let t = CGFloat(i) / CGFloat(antennaCount - 1)
    let xPos = domeRect.minX + 8 + (domeRect.width - 16) * t
    let baseY = domeRect.maxY - domeRect.height * 0.20
    let tipY = domeRect.maxY + domeRect.height * 0.18
    let path = NSBezierPath()
    path.move(to: NSPoint(x: xPos, y: baseY))
    path.line(to: NSPoint(x: xPos, y: tipY))
    path.lineWidth = domeLineWidth * 0.55
    path.lineCapStyle = .round
    path.stroke()
}

// 4b. Outer ring (the "O" outline)
let ringInset: CGFloat = domeLineWidth / 2
let ringRect = domeRect.insetBy(dx: ringInset, dy: ringInset)
let ring = NSBezierPath(ovalIn: ringRect)
ring.lineWidth = domeLineWidth
ring.stroke()

// 4c. Latitude wireframe (horizontal ellipses inside the ring)
ctx.saveGState()
let clip = NSBezierPath(ovalIn: ringRect.insetBy(dx: domeLineWidth * 0.4, dy: domeLineWidth * 0.4))
clip.addClip()
let latitudes: [CGFloat] = [0.18, 0.36, 0.55, 0.74]
for ratio in latitudes {
    let h = ringRect.height * ratio
    let er = NSRect(
        x: ringRect.minX, y: ringRect.midY - h / 2,
        width: ringRect.width, height: h
    )
    let e = NSBezierPath(ovalIn: er)
    e.lineWidth = domeLineWidth * 0.50
    e.stroke()
}

// 4d. Vertical longitudes
let longitudes: [CGFloat] = [0.20, 0.40, 0.60, 0.80]
for ratio in longitudes {
    let w = ringRect.width * (1 - 2 * abs(ratio - 0.5))
    let er = NSRect(
        x: ringRect.midX - w / 2, y: ringRect.minY,
        width: w, height: ringRect.height
    )
    let e = NSBezierPath(ovalIn: er)
    e.lineWidth = domeLineWidth * 0.50
    e.stroke()
}
ctx.restoreGState()

// 4e. Base bar under the dome (mirrors Atakule's pedestal)
let baseRect = NSRect(
    x: ringRect.minX - 4, y: ringRect.minY - 12,
    width: ringRect.width + 8, height: 22
)
NSBezierPath(roundedRect: baseRect, xRadius: 4, yRadius: 4).fill()

ctx.restoreGState()

// MARK: - 5. "MAC" caption below

let macFontSize: CGFloat = 240
let macFont = NSFont.systemFont(ofSize: macFontSize, weight: .heavy)
let macAttrs: [NSAttributedString.Key: Any] = [
    .font: macFont,
    .foregroundColor: brandRed,
    .kern: -4,
    .shadow: shadow,
]
let mac = NSAttributedString(string: "MAC", attributes: macAttrs)
let macSize = mac.size()
mac.draw(at: NSPoint(x: (canvas - macSize.width) / 2, y: canvas * 0.10))

// MARK: - Save PNG

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep  = NSBitmapImageRep(data: tiff),
      let png  = rep.representation(using: .png, properties: [:])
else {
    print("failed to encode PNG")
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("✓ wrote \(outputPath)")
} catch {
    print("write failed: \(error)")
    exit(1)
}
