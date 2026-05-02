//
//  SubtitleAppearanceSettings.swift
//  Rivulet
//
//  Shared subtitle appearance and sync preferences.
//

import Combine
import SwiftUI

enum SubtitleTextSize: String, CaseIterable, Identifiable, Sendable, CustomStringConvertible {
    case compact = "50"
    case small = "75"
    case normal = "100"
    case large = "125"
    case extraLarge = "150"
    case cinema = "200"

    var id: String { rawValue }

    var description: String {
        "\(rawValue)%"
    }

    var fontSize: CGFloat {
        48 * scale
    }

    private var scale: CGFloat {
        (Double(rawValue) ?? 100) / 100
    }
}

enum SubtitleTextColor: String, CaseIterable, Identifiable, Sendable, CustomStringConvertible {
    case white
    case yellow
    case orange
    case cyan
    case green
    case red

    var id: String { rawValue }

    var description: String {
        switch self {
        case .white: return "White"
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .red: return "Red"
        }
    }

    var color: Color {
        switch self {
        case .white: return .white
        case .yellow: return .yellow
        case .orange: return .orange
        case .cyan: return .cyan
        case .green: return .green
        case .red: return .red
        }
    }
}

enum SubtitleVerticalPosition: Int, CaseIterable, Identifiable, Sendable, CustomStringConvertible {
    case top = -15
    case upper = -10
    case standard = 0
    case lower = 5
    case bottom = 10

    var id: Int { rawValue }

    var description: String {
        switch self {
        case .top: return "Top"
        case .upper: return "Upper"
        case .standard: return "Standard"
        case .lower: return "Lower"
        case .bottom: return "Bottom"
        }
    }

    func bottomPadding(in viewHeight: CGFloat, controlsOffset: CGFloat) -> CGFloat {
        switch self {
        case .top:
            return max(controlsOffset, viewHeight - 180)
        case .upper:
            return max(controlsOffset, viewHeight * 0.62)
        case .standard:
            return max(controlsOffset, 150)
        case .lower:
            return max(controlsOffset, 100)
        case .bottom:
            return max(controlsOffset, 50)
        }
    }
}

@MainActor
final class SubtitleAppearanceSettings: ObservableObject {
    static let shared = SubtitleAppearanceSettings()

    static let delayRange: ClosedRange<TimeInterval> = -30...30

    @Published private(set) var textSize: SubtitleTextSize
    @Published private(set) var textColor: SubtitleTextColor
    @Published private(set) var verticalPosition: SubtitleVerticalPosition
    @Published private(set) var delay: TimeInterval

    private enum Keys {
        static let textSize = "subtitleTextSize"
        static let textColor = "subtitleTextColor"
        static let verticalPosition = "subtitleVerticalPosition"
        static let delay = "subtitleDelay"
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.textSize = SubtitleTextSize(rawValue: defaults.string(forKey: Keys.textSize) ?? "") ?? .normal
        self.textColor = SubtitleTextColor(rawValue: defaults.string(forKey: Keys.textColor) ?? "") ?? .white
        self.verticalPosition = SubtitleVerticalPosition(rawValue: defaults.object(forKey: Keys.verticalPosition) as? Int ?? 0) ?? .standard
        self.delay = Self.clampedDelay(defaults.object(forKey: Keys.delay) as? TimeInterval ?? 0)
    }

    func setTextSize(_ value: SubtitleTextSize) {
        textSize = value
        defaults.set(value.rawValue, forKey: Keys.textSize)
    }

    func setTextColor(_ value: SubtitleTextColor) {
        textColor = value
        defaults.set(value.rawValue, forKey: Keys.textColor)
    }

    func setVerticalPosition(_ value: SubtitleVerticalPosition) {
        verticalPosition = value
        defaults.set(value.rawValue, forKey: Keys.verticalPosition)
    }

    func setDelay(_ value: TimeInterval) {
        delay = Self.clampedDelay(value)
        defaults.set(delay, forKey: Keys.delay)
    }

    func cycleTextSize() {
        setTextSize(nextValue(after: textSize, in: SubtitleTextSize.allCases))
    }

    func cycleTextColor() {
        setTextColor(nextValue(after: textColor, in: SubtitleTextColor.allCases))
    }

    func cycleVerticalPosition() {
        setVerticalPosition(nextValue(after: verticalPosition, in: SubtitleVerticalPosition.allCases))
    }

    func adjustDelay(by delta: TimeInterval) {
        setDelay(delay + delta)
    }

    func resetDelay() {
        setDelay(0)
    }

    var formattedDelay: String {
        if abs(delay) < 0.005 {
            return "0.0s"
        }
        return String(format: "%+.1fs", delay)
    }

    private static func clampedDelay(_ value: TimeInterval) -> TimeInterval {
        min(max(value, delayRange.lowerBound), delayRange.upperBound)
    }

    private func nextValue<Value: Equatable>(after value: Value, in values: [Value]) -> Value {
        guard let index = values.firstIndex(of: value), !values.isEmpty else {
            return value
        }
        return values[values.index(after: index) % values.count]
    }
}
