import SwiftUI

/// User-adjustable text size for the sidebar (⌘+ / ⌘− / ⌘0, Settings → General).
enum UIScale {
    static let key = "uiScale"
    static let range: ClosedRange<Double> = 0.8...1.6
    static let step = 0.1

    static var current: Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v == 0 ? 1 : min(max(v, range.lowerBound), range.upperBound)
    }

    static func set(_ v: Double) {
        let r = (min(max(v, range.lowerBound), range.upperBound) * 10).rounded() / 10
        UserDefaults.standard.set(r, forKey: key)
    }

    static func bigger() { set(current + step) }
    static func smaller() { set(current - step) }
    static func reset() { set(1) }

    /// macOS point sizes for the semantic text styles.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption: return 10
        case .caption2: return 10
        @unknown default: return 13
        }
    }
}

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    var size: CGFloat
    var weight: Font.Weight?
    var design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight ?? .regular, design: design))
    }
}

extension View {
    /// A text style that follows the sidebar's text size setting.
    func sfont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: UIScale.baseSize(style),
                            weight: weight ?? (style == .headline ? .semibold : nil),
                            design: design))
    }

    func sfont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}
