// Run on macOS: swift Scripts/build_windows_provider_icons.swift
// Rasterize the existing provider SVGs for Windows resource compilation.
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Sources/CodexBar/Resources")
let destination = root.appendingPathComponent("Scripts/WindowsProviderIcons")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where file.lastPathComponent.hasPrefix("ProviderIcon-") && file.pathExtension == "svg"
{
    guard let image = NSImage(contentsOf: file) else { fatalError("Cannot render \(file.lastPathComponent)") }
    let provider = String(file.deletingPathExtension().lastPathComponent.dropFirst("ProviderIcon-".count))
    for (variant, ink) in [("normal", NSColor(calibratedWhite: 0.37, alpha: 1)), ("selected", NSColor.white)] {
        var frames: [(Int, Data)] = []
        for size in [32, 64, 128] {
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let rect = NSRect(x: 0, y: 0, width: size, height: size)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            ink.setFill()
            rect.fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()
            frames.append((size, bitmap.representation(using: .png, properties: [:])!))
        }
        var data = Data()
        func append16(_ value: UInt16) {
            data.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)])
        }
        func append32(_ value: UInt32) {
            data.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) })
        }
        append16(0); append16(1); append16(UInt16(frames.count))
        var offset = UInt32(6 + frames.count * 16)
        for (size, bytes) in frames {
            data.append(contentsOf: [UInt8(size), UInt8(size), 0, 0])
            append16(1); append16(32); append32(UInt32(bytes.count)); append32(offset)
            offset += UInt32(bytes.count)
        }
        for (_, bytes) in frames {
            data.append(bytes)
        }
        try data.write(to: destination.appendingPathComponent("\(provider)-\(variant).ico"))
    }
}
