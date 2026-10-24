import SwiftUI
import UIKit
import Learning

/// Design tokens for Knight Academy: deep charcoal surfaces, a calm green accent.
enum KA {
    enum Palette {
        static let background = Color(light: 0xF4F4F6, dark: 0x0D0D10)
        static let surface = Color(light: 0xFFFFFF, dark: 0x1A1B1F)
        static let surfaceElevated = Color(light: 0xEAEBEF, dark: 0x25262B)
        static let stroke = Color(light: 0xDCDDE2, dark: 0x2E2F35)
        static let accent = Color(light: 0x23845A, dark: 0x5BC98F)
        static let accentSoft = Color(light: 0xDCEFE5, dark: 0x1F3A2D)
        static let textSecondary = Color(light: 0x5F6168, dark: 0x9C9DA6)
        static let danger = Color(light: 0xC0392B, dark: 0xFF6B5E)
        static let warning = Color(light: 0xB9770E, dark: 0xF5B041)
        static let info = Color(light: 0x2E6DA4, dark: 0x7FB2E5)
        static let gold = Color(light: 0xB8860B, dark: 0xE8C547)
        /// Progress bars on course cards (as in the course list design).
        static let progress = Color(light: 0x6D4AE0, dark: 0x8B6CF6)
        /// Score/coverage numbers.
        static let score = Color(light: 0x4E9A2E, dark: 0x9BD36A)
        /// The white instruction card above the board.
        static let instructionCard = Color(light: 0xFFFFFF, dark: 0xFFFFFF)
        static let instructionText = Color(light: 0x111114, dark: 0x111114)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 18
        static let chip: CGFloat = 10
    }
}

extension Color {
    /// A colour that adapts to light and dark mode, given as 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension AppearanceSetting {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayName: String { rawValue.capitalized }
}

/// Board square colours per theme.
struct BoardColors {
    let light: Color
    let dark: Color
    let lastMove: Color
    let selection: Color
    let hint: Color

    static func forTheme(_ theme: BoardTheme) -> BoardColors {
        switch theme {
        case .wood:
            return BoardColors(light: Color(red: 0.933, green: 0.843, blue: 0.706), dark: Color(red: 0.784, green: 0.627, blue: 0.478),
                               lastMove: Color(red: 0.80, green: 0.82, blue: 0.32).opacity(0.55),
                               selection: Color(red: 0.42, green: 0.66, blue: 0.36).opacity(0.55),
                               hint: Color(red: 0.36, green: 0.55, blue: 0.95).opacity(0.5))
        case .forest:
            return BoardColors(light: Color(red: 0.91, green: 0.92, blue: 0.84), dark: Color(red: 0.42, green: 0.58, blue: 0.43),
                               lastMove: Color(red: 0.86, green: 0.83, blue: 0.35).opacity(0.55),
                               selection: Color(red: 0.30, green: 0.76, blue: 0.54).opacity(0.55),
                               hint: Color(red: 0.35, green: 0.62, blue: 0.95).opacity(0.55))
        case .walnut:
            return BoardColors(light: Color(red: 0.94, green: 0.85, blue: 0.71), dark: Color(red: 0.71, green: 0.53, blue: 0.39),
                               lastMove: Color(red: 0.80, green: 0.82, blue: 0.30).opacity(0.5),
                               selection: Color(red: 0.42, green: 0.70, blue: 0.40).opacity(0.55),
                               hint: Color(red: 0.35, green: 0.55, blue: 0.95).opacity(0.5))
        case .slate:
            return BoardColors(light: Color(red: 0.87, green: 0.89, blue: 0.91), dark: Color(red: 0.47, green: 0.55, blue: 0.62),
                               lastMove: Color(red: 0.62, green: 0.80, blue: 0.55).opacity(0.55),
                               selection: Color(red: 0.30, green: 0.76, blue: 0.54).opacity(0.55),
                               hint: Color(red: 0.95, green: 0.70, blue: 0.30).opacity(0.55))
        case .classic:
            return BoardColors(light: Color(red: 0.93, green: 0.93, blue: 0.82), dark: Color(red: 0.46, green: 0.59, blue: 0.34),
                               lastMove: Color(red: 0.97, green: 0.97, blue: 0.41).opacity(0.5),
                               selection: Color(red: 0.08, green: 0.47, blue: 0.95).opacity(0.4),
                               hint: Color(red: 0.95, green: 0.55, blue: 0.20).opacity(0.5))
        }
    }
}
