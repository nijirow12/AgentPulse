// Turns Resources/AppIcon-source.png (a rounded-square picture on a black background)
// into Resources/AppIcon.png: the picture cut out with the macOS icon corner radius,
// centered on a transparent 1024px canvas with the standard icon margin.
//
//   swift scripts/make_icon.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let input = root.appending(path: "Resources/AppIcon-source.png")
let output = root.appending(path: "Resources/AppIcon.png")

guard
    let source = CGImageSourceCreateWithURL(input as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("cannot read \(input.path)") }

// Find the picture's bounds: everything brighter than the black backdrop.
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let rgb = CGColorSpaceCreateDeviceRGB()
let scan = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
scan.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 120 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// Trim well inside the picture: its rounded edge fades into the black backdrop over a
// few dozen pixels, and any of that left under the mask shows as a dark rim.
let inset = 32
let crop = CGRect(
    x: minX + inset, y: minY + inset,
    width: maxX - minX - 2 * inset, height: maxY - minY - 2 * inset
)
// Bitmap rows run top-down while CGImage.cropping expects the same, so no flip is needed.
guard let picture = image.cropping(to: crop) else { fatalError("crop failed") }

// macOS icon grid: 1024 canvas, 824 body, corner radius ≈ 22.37% of the body.
let canvas = 1024, body: CGFloat = 824
let origin = (CGFloat(canvas) - body) / 2
let rect = CGRect(x: origin, y: origin, width: body, height: body)
let out = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
out.interpolationQuality = .high
out.addPath(CGPath(roundedRect: rect, cornerWidth: body * 0.2237, cornerHeight: body * 0.2237, transform: nil))
out.clip()
out.draw(picture, in: rect)

guard
    let result = out.makeImage(),
    let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("cannot write \(output.path)") }
CGImageDestinationAddImage(destination, result, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output.path) from crop \(crop)")
