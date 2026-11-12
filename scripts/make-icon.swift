#!/usr/bin/env swift
// Draws the app icon: a three-feather wing (Hermes' winged sandals) on near-black.
//
//   swift scripts/make-icon.swift
//
// Writes the 1024 px light, dark and tinted variants into the asset catalog.
import AppKit
import CoreGraphics
import Foundation

let side = 1024
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Talaria/Resources/Assets.xcassets/AppIcon.appiconset")

enum Variant: String {
  case light = "icon-1024.png"
  case dark = "icon-1024-dark.png"
  case tinted = "icon-1024-tinted.png"
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// A feather: a leaf shape from `base` to a tip `length` away at `angle` degrees, bulging to the upper side.
func feather(base: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) -> CGPath {
  let radians = angle * .pi / 180
  let direction = CGPoint(x: cos(radians), y: sin(radians))
  let normal = CGPoint(x: -direction.y, y: direction.x)
  let tip = CGPoint(x: base.x + direction.x * length, y: base.y + direction.y * length)
  func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
    CGPoint(x: base.x + direction.x * length * along + normal.x * width * across,
            y: base.y + direction.y * length * along + normal.y * width * across)
  }
  let path = CGMutablePath()
  path.move(to: base)
  path.addCurve(to: tip, control1: point(0.18, 1.05), control2: point(0.72, 0.95))
  path.addCurve(to: base, control1: point(0.78, 0.02), control2: point(0.3, -0.42))
  path.closeSubpath()
  return path
}

func render(_ variant: Variant) -> Data {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let bounds = CGRect(x: 0, y: 0, width: side, height: side)

  switch variant {
  case .light:
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x1c1c1f), color(0x0a0a0a)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])
  case .dark:
    context.setFillColor(color(0x000000))
    context.fill(bounds)
  case .tinted:
    // The system supplies the tint; the artwork is grayscale on black.
    context.setFillColor(color(0x000000))
    context.fill(bounds)
  }

  // Three feathers fanned from a shared root, longest on top.
  let base = CGPoint(x: 258, y: 268)
  let feathers: [(angle: CGFloat, length: CGFloat, width: CGFloat, shade: CGFloat)] = [
    (62, 560, 150, 1.0),
    (40, 610, 150, 0.82),
    (18, 560, 140, 0.62),
  ]
  for (index, item) in feathers.enumerated().reversed() {
    let path = feather(base: base, angle: item.angle, length: item.length, width: item.width)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let top: CGColor
    let bottom: CGColor
    switch variant {
    case .tinted:
      top = color(0xffffff, alpha: item.shade)
      bottom = color(0xffffff, alpha: item.shade * 0.72)
    default:
      // White at the leading feather shading toward T3 Code's blue on the trailing ones.
      let blues: [UInt32] = [0xffffff, 0xbcd0ff, 0x6f97ff]
      let deep: [UInt32] = [0xdfe8ff, 0x7ea2ff, 0x346bf1]
      top = color(blues[index])
      bottom = color(deep[index])
    }
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    let box = path.boundingBox
    context.drawLinearGradient(
      gradient, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
    context.restoreGState()
  }

  let image = context.makeImage()!
  let bitmap = NSBitmapImageRep(cgImage: image)
  return bitmap.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for variant in [Variant.light, .dark, .tinted] {
  let url = iconset.appendingPathComponent(variant.rawValue)
  try render(variant).write(to: url)
  print("wrote \(url.path)")
}
