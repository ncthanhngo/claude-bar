import SwiftUI

/// Color tokens for the Daily Briefing view. Source of truth:
/// daily-briefing-preview.html `:root` CSS variables. Phase 09 adds Dark + Rainbow.
struct BriefingPalette {
    let paper:   Color
    let paper2:  Color
    let ink:     Color
    let ink2:    Color
    let ink3:    Color
    let line:    Color
    let line2:   Color

    let coral:   Color   // urgent
    let rose:    Color   // important
    let blush:   Color   // chip bg
    let peach:   Color
    let cream:   Color
    let sage:    Color   // done
    let moss:    Color
    let gold:    Color
    let plum:    Color

    /// True when the base paper is dark. Drives card surface + shadow choices.
    let isDark: Bool

    /// Solid card surface for white-card components (calendar, mini cards).
    var raisedSurface: Color { isDark ? paper2 : .white }

    /// Soft shadow under raised cards. Disabled in dark to avoid haloing.
    var cardShadow: Color { isDark ? .clear : ink.opacity(0.04) }

    static let light = BriefingPalette(
        paper:   Color(hex: 0xFBF7F3),
        paper2:  Color(hex: 0xF5ECDF),
        ink:     Color(hex: 0x2A201D),
        ink2:    Color(hex: 0x5A4A44),
        ink3:    Color(hex: 0x9C8B82),
        line:    Color(hex: 0xEBE1D8),
        line2:   Color(hex: 0xE2D4C5),
        coral:   Color(hex: 0xC87267),
        rose:    Color(hex: 0xD99086),
        blush:   Color(hex: 0xF4D4CE),
        peach:   Color(hex: 0xF3D2B5),
        cream:   Color(hex: 0xFBF0E2),
        sage:    Color(hex: 0x8FA68E),
        moss:    Color(hex: 0x5E7A5C),
        gold:    Color(hex: 0xB48352),
        plum:    Color(hex: 0x8A5266),
        isDark:  false
    )

    /// Dark theme — warm dark paper (charcoal with brown undertones).
    /// Preserves editorial planner feel: muted accents on a deep base.
    static let dark = BriefingPalette(
        paper:   Color(hex: 0x141019),
        paper2:  Color(hex: 0x1C1620),
        ink:     Color(hex: 0xF2EAE3),
        ink2:    Color(hex: 0xC4B9B0),
        ink3:    Color(hex: 0x847569),
        line:    Color(hex: 0x2B2229),
        line2:   Color(hex: 0x3A2F37),
        coral:   Color(hex: 0xE78C80),
        rose:    Color(hex: 0xE8A59C),
        blush:   Color(hex: 0x3D2A2D),
        peach:   Color(hex: 0x4A3528),
        cream:   Color(hex: 0x2A221D),
        sage:    Color(hex: 0xA7C2A4),
        moss:    Color(hex: 0x7EA07B),
        gold:    Color(hex: 0xD7A76C),
        plum:    Color(hex: 0xB88299),
        isDark:  true
    )

    /// Rainbow — warm cream base + analogous chromatic accents
    /// (apricot · magenta · teal · iris). Same harmonious feel, more pop.
    static let rainbow = BriefingPalette(
        paper:   Color(hex: 0xFDF6F4),
        paper2:  Color(hex: 0xF8E8EB),
        ink:     Color(hex: 0x2A1F2C),
        ink2:    Color(hex: 0x5C4759),
        ink3:    Color(hex: 0x9A8499),
        line:    Color(hex: 0xEED5D9),
        line2:   Color(hex: 0xE3C3D2),
        coral:   Color(hex: 0xE85C79),
        rose:    Color(hex: 0xEA7FA3),
        blush:   Color(hex: 0xFBD7E0),
        peach:   Color(hex: 0xF8C8A8),
        cream:   Color(hex: 0xFEE9D8),
        sage:    Color(hex: 0x6ABAB2),
        moss:    Color(hex: 0x4BA091),
        gold:    Color(hex: 0xD99B3A),
        plum:    Color(hex: 0x8A5FAD),
        isDark:  false
    )
}

extension WidgetTheme {
    var briefingPalette: BriefingPalette {
        switch self {
        case .light:   return .light
        case .dark:    return .dark
        case .rainbow: return .rainbow
        case .apple:   return .light  // Apple theme briefing falls back to light palette
        }
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
