import AppKit

enum AppIdentity {
    static let mainWindowID = "main"
    private static let fallbackName = "OpenWhisper"

    static let displayName: String = {
        if let displayName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String, !displayName.isEmpty {
            return displayName
        }

        if let bundleName = Bundle.main.object(
            forInfoDictionaryKey: kCFBundleNameKey as String
        ) as? String, !bundleName.isEmpty {
            return bundleName
        }

        return fallbackName
    }()

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == mainWindowID
    }
}
