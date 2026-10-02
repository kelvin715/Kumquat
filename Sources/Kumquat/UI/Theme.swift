import SwiftUI

/// The warm "citrus glass" palette shared by the wheel and the tool windows.
enum Theme {
    static func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
        let red: Double = Double((value >> 16) & 0xff) / 255
        let green: Double = Double((value >> 8) & 0xff) / 255
        let blue: Double = Double(value & 0xff) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    // Accent
    static let tangerine = hex(0xF2541B)
    static let tangerineLight = hex(0xFF7A3D)
    static let tangerineDeep = hex(0xDD420C)

    /// Dark brown used for text on peach surfaces.
    static let ink = hex(0x3A2316)
    static let inkSecondary = hex(0x7A5340)

    // Wheel
    static let discFill = LinearGradient(colors: [hex(0xFFD7A8, 0.78), hex(0xF5A766, 0.74), hex(0xEE8E52, 0.76)],
                                         startPoint: .top, endPoint: .bottom)
    static let rim = LinearGradient(colors: [hex(0xFFFFFF, 0.85), hex(0xFFE2B8, 0.45), hex(0xC9782E, 0.55)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let segmentFill = LinearGradient(colors: [hex(0xFFE5D2, 0.96), hex(0xFFCFAF, 0.94)],
                                            startPoint: .top, endPoint: .bottom)
    static let segmentHover = LinearGradient(colors: [hex(0xFF7B3A), hex(0xE5450D)],
                                             startPoint: .top, endPoint: .bottom)
    static let well = RadialGradient(colors: [hex(0xF29B4E, 0.92), hex(0xDE7630, 0.92)],
                                     center: .center, startRadius: 0, endRadius: 60)
    static let pill = LinearGradient(colors: [hex(0xFFD0A3), hex(0xFFB476)], startPoint: .top, endPoint: .bottom)

    // Windows
    static let windowGradient = LinearGradient(colors: [hex(0xFAB847, 0.93), hex(0xF8A464, 0.93), hex(0xF59C8E, 0.93)],
                                               startPoint: .top, endPoint: .bottom)
    static let fieldFill = Color.white.opacity(0.85)
    static let trackFill = Color.white.opacity(0.32)
    static let separator = Color.white.opacity(0.35)
}
