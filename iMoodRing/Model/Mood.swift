import SwiftUI

enum Mood: String, CaseIterable, Codable {
    case calm, happy, excited, tense, sad, angry, neutral

    // Matches web app color palette exactly
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .calm:    return (74,  144, 217)
        case .happy:   return (245, 166, 35)
        case .excited: return (255, 107, 53)
        case .tense:   return (208, 2,   27)
        case .sad:     return (123, 104, 238)
        case .angry:   return (139, 0,   0)
        case .neutral: return (155, 155, 155)
        }
    }

    var color: Color {
        let (r, g, b) = rgb
        return Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    static func from(_ string: String) -> Mood {
        Mood(rawValue: string.lowercased()) ?? .neutral
    }
}

func lerpRGB(_ a: (r: Double, g: Double, b: Double),
             _ b: (r: Double, g: Double, b: Double),
             t: Double) -> (r: Double, g: Double, b: Double) {
    (r: a.r + (b.r - a.r) * t,
     g: a.g + (b.g - a.g) * t,
     b: a.b + (b.b - a.b) * t)
}
