import Foundation

/// Centralized shared constants and helpers used across app and widgets.
///
/// The App Group identifier is read from the Info.plist key `AppGroupIdentifier` to avoid
/// hardcoding it in code and accidentally diverging between targets.
/// Make sure to add the key to both the App and Widget targets' Info.plist files
/// with the exact same value as configured in the App Group capability (e.g.,
/// "group.at.goinon.badvigaun.terminplan").
enum SharedConstants {
    /// Info.plist key that stores the App Group identifier.
    private static let appGroupInfoPlistKey = "AppGroupIdentifier"

    /// Returns the configured App Group identifier.
    /// Must be provided via Info.plist; no hardcoded fallback to avoid divergence.
    static var appGroupId: String {
        // Try reading from the main bundle first.
        if let id = Bundle.main.object(forInfoDictionaryKey: appGroupInfoPlistKey) as? String, !id.isEmpty {
            return id
        }
        // Some extensions/widgets may not use Bundle.main the same way; try the bundle for this type.
        if let id = Bundle(for: BundleMarker.self).object(forInfoDictionaryKey: appGroupInfoPlistKey) as? String, !id.isEmpty {
            return id
        }
        // No fallback to a hardcoded string to avoid configuration drift across targets.
        // Make the misconfiguration explicit to ensure it gets fixed.
        let message = "App Group identifier not found in Info.plist under key \(appGroupInfoPlistKey). Add this key with your App Group value (e.g., 'group.your.identifier') to both App and Widget targets."
        #if DEBUG
        assertionFailure(message)
        #endif
        // Crash in production to avoid silently writing to the wrong container.
        fatalError(message)
    }

    /// A convenience accessor for shared UserDefaults using the App Group identifier.
    /// This returns nil if the identifier is misconfigured at runtime.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    /// Key for storing the next appointment in shared defaults.
    static let nextAppointmentKey = "nextAppointment"
    
    /// Returns the App Group container URL if available.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }
}

/// Empty class used to obtain a stable bundle reference for Info.plist lookups in extensions.
private final class BundleMarker {}
