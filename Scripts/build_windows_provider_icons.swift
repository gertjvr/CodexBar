// Run on macOS: swift Scripts/build_windows_provider_icons.swift
// Rasterize upstream provider branding for the Win32 resources and WinUI assets.
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Sources/CodexBar/Resources")
let destination = root.appendingPathComponent("Scripts/WindowsProviderIcons")
let winUIAssets = root.appendingPathComponent("Windows/CodexBar.Tray/Assets")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: winUIAssets, withIntermediateDirectories: true)

func captures(_ pattern: String, in text: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
    }
}

let providersRoot = root.appendingPathComponent("Sources/CodexBarCore/Providers")
let providersSource = try String(contentsOf: providersRoot.appendingPathComponent("Providers.swift"), encoding: .utf8)
let enumStart = providersSource.range(of: "public enum UsageProvider:")!.lowerBound
let enumEnd = providersSource.range(of: "\n}", range: enumStart..<providersSource.endIndex)!.lowerBound
let providers = try captures(#"^\s*case ([a-z0-9]+)$"#, in: String(providersSource[enumStart..<enumEnd]))
guard !providers.isEmpty else { fatalError("The upstream provider catalog is empty") }
let descriptorFiles = FileManager.default.enumerator(at: providersRoot, includingPropertiesForKeys: nil)!
var branding: [String: String] = [:]
for case let descriptor as URL in descriptorFiles
    where descriptor.lastPathComponent.hasSuffix("ProviderDescriptor.swift")
{
    let text = try String(contentsOf: descriptor, encoding: .utf8)
    guard let provider = try captures(#"\bid:\s*\.([a-z0-9]+),"#, in: text).first else { continue }
    guard branding[provider] == nil else { fatalError("Duplicate descriptor for \(provider)") }
    let explicit = try captures(#"iconResourceName:\s*"(ProviderIcon-[a-z0-9]+)""#, in: text).first
    branding[provider] = explicit ?? "ProviderIcon-\(provider)"
}

guard Set(branding.keys) == Set(providers) else { fatalError("Provider descriptors do not match the catalog") }

let expectedNames = Set(providers.flatMap { provider in ["\(provider)-normal", "\(provider)-selected"] })
for (directory, extensionName) in [(destination, "ico"), (winUIAssets, "png")] {
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == extensionName
        && (file.deletingPathExtension().lastPathComponent.hasSuffix("-normal")
            || file.deletingPathExtension().lastPathComponent.hasSuffix("-selected"))
        && !expectedNames.contains(file.deletingPathExtension().lastPathComponent)
    {
        try FileManager.default.removeItem(at: file)
    }
}

for provider in providers.sorted() {
    let resource = branding[provider]!
    let file = source.appendingPathComponent("\(resource).svg")
    guard let image = NSImage(contentsOf: file) else { fatalError("Cannot render \(file.lastPathComponent)") }
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
        try frames.last!.1.write(to: winUIAssets.appendingPathComponent("\(provider)-\(variant).png"))
    }
}

for (directory, extensionName) in [(destination, "ico"), (winUIAssets, "png")] {
    let generated = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == extensionName }
        .map { $0.deletingPathExtension().lastPathComponent }
        .filter { $0.hasSuffix("-normal") || $0.hasSuffix("-selected") }
    guard Set(generated) == expectedNames else { fatalError("Generated Windows icons do not match the catalog") }
}

print("Generated ICO and PNG variants for \(providers.count) providers from upstream branding")
