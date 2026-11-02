import SwiftUI

/// Apple TV's text styles, from Apple's Human Interface Guidelines for tvOS: SF Pro, Medium for
/// nearly everything, Bold when emphasized, nothing under 23 pt. Mac TV draws on a 1920×1080
/// canvas like tvOS, so the sizes carry over point for point.
enum TVText {
    case title1, title2, title3, headline, subtitle, callout, body, caption1, caption2

    var size: CGFloat {
        switch self {
        case .title1: 76
        case .title2: 57
        case .title3: 48
        case .headline, .subtitle: 38
        case .callout: 31
        case .body: 29
        case .caption1: 25
        case .caption2: 23
        }
    }

    var weight: Font.Weight { self == .subtitle ? .regular : .medium }
    var emphasizedWeight: Font.Weight { self == .subtitle ? .medium : .bold }
}

extension Font {
    /// One of Apple TV's text styles; `emphasized` is its bold form.
    static func tv(_ style: TVText, emphasized: Bool = false) -> Font {
        .system(size: style.size, weight: emphasized ? style.emphasizedWeight : style.weight)
    }
}
