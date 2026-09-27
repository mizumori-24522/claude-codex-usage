import AppKit
import SwiftUI

/// One step of the Claude character's colour scale: used at or below `upTo` percent → `hex`.
struct CharacterStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var upTo: Int
    var hex: UInt32
}

/// Claude's own colour scale, used by its character and its 5-hour / weekly gauges. It can be
/// edited in the panel, so changing taste later needs no code change. Codex keeps the shared scale.
enum CharacterScale {
    /// The steps in use, readable from any drawing code; kept in sync by `Settings`.
    nonisolated(unsafe) static var current: [CharacterStep] = defaults

    /// Light blue → green → Claude orange (the widest band) → purple → yellow → white.
    static let defaults: [CharacterStep] = [
        CharacterStep(upTo: 19, hex: 0x3DB9F2),
        CharacterStep(upTo: 39, hex: 0x34C77B),
        CharacterStep(upTo: 69, hex: 0xD97757),
        CharacterStep(upTo: 79, hex: 0xA873F5),
        CharacterStep(upTo: 89, hex: 0xF6C744),
        CharacterStep(upTo: 100, hex: 0xF2F2F2),
    ]

    static func hex(forUsed used: Int, in steps: [CharacterStep]) -> UInt32 {
        let sorted = steps.sorted { $0.upTo < $1.upTo }
        return (sorted.first { used <= $0.upTo } ?? sorted.last)?.hex ?? 0xD97757
    }

    /// `[light, body, shade]` derived from a single colour.
    static func ramp(_ hex: UInt32) -> [Color] {
        let base = nsColor(hex)
        return [Color(nsColor: base.blended(withFraction: 0.45, of: .white) ?? base),
                Color(nsColor: base),
                Color(nsColor: base.blended(withFraction: 0.25, of: .black) ?? base)]
    }

    /// A near-white body vanishes on a light background; give it just enough grey to read.
    static func legible(_ color: NSColor, onDark dark: Bool) -> NSColor {
        guard !dark, let c = color.usingColorSpace(.sRGB) else { return color }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.82 ? (c.blended(withFraction: 0.32, of: .black) ?? c) : c
    }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func hex(of color: Color) -> UInt32 {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 0xD97757 }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}
