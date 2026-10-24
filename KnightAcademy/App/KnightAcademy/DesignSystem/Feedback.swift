import UIKit
import AudioToolbox

/// Haptic and sound feedback, respecting the user's settings.
@MainActor
enum Feedback {
    static var hapticsEnabled = true
    static var soundEnabled = true

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    static func move(capture: Bool = false) {
        if hapticsEnabled { (capture ? medium : light).impactOccurred() }
        // 1104 = keyboard tock, 1105 = a slightly heavier click.
        if soundEnabled { AudioServicesPlaySystemSound(capture ? 1105 : 1104) }
    }

    static func success() {
        if hapticsEnabled { notification.notificationOccurred(.success) }
    }

    static func error() {
        if hapticsEnabled { notification.notificationOccurred(.error) }
    }

    static func selection() {
        if hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
    }
}
