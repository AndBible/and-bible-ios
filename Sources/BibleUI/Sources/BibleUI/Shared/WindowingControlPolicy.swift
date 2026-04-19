#if os(iOS)
import UIKit

public enum AndBibleWindowingControlStyleChoice {
    case automatic
    case minimal
}

/// Shared policy for whether iPadOS 26 window controls should use the minimal style.
public struct AndBibleWindowingControlPolicy {
    public static func shouldUseMinimalStyle(userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool {
        userInterfaceIdiom == .pad
    }

    public static func preferredWindowingControlStyleChoice(
        userInterfaceIdiom: UIUserInterfaceIdiom
    ) -> AndBibleWindowingControlStyleChoice {
        shouldUseMinimalStyle(userInterfaceIdiom: userInterfaceIdiom) ? .minimal : .automatic
    }
}

/// Shared app delegate used to attach the window-scene delegate for iPadOS 26 window-control customization.
public final class AndBibleApplicationDelegate: NSObject, UIApplicationDelegate {
    public override init() {
        super.init()
    }

    public static func sceneConfiguration(sessionRole: UISceneSession.Role) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: sessionRole)
        configuration.delegateClass = AndBibleWindowSceneDelegate.self
        return configuration
    }

    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        Self.sceneConfiguration(sessionRole: connectingSceneSession.role)
    }
}

/// Scene delegate that opts iPadOS 26 windows into the minimal system window-control style.
public final class AndBibleWindowSceneDelegate: NSObject, UIWindowSceneDelegate {
    private static let automaticStyleSelectorName = "automaticStyle"
    private static let minimalStyleSelectorName = "minimalStyle"
    private static let windowingControlStyleClassName = "UISceneWindowingControlStyle"

    public override init() {
        super.init()
    }

    public static func preferredWindowingControlStyleSelectorName(
        userInterfaceIdiom: UIUserInterfaceIdiom
    ) -> String {
        switch AndBibleWindowingControlPolicy.preferredWindowingControlStyleChoice(
            userInterfaceIdiom: userInterfaceIdiom
        ) {
        case .automatic:
            return automaticStyleSelectorName
        case .minimal:
            return minimalStyleSelectorName
        }
    }

    private static func resolvedWindowingControlStyle(
        userInterfaceIdiom: UIUserInterfaceIdiom
    ) -> AnyObject? {
        let selectorName = preferredWindowingControlStyleSelectorName(
            userInterfaceIdiom: userInterfaceIdiom
        )
        let selector = NSSelectorFromString(selectorName)

        guard let styleClass = NSClassFromString(windowingControlStyleClassName) as? NSObject.Type,
              styleClass.responds(to: selector),
              let unmanagedStyle = styleClass.perform(selector) else {
            return nil
        }

        return unmanagedStyle.takeUnretainedValue()
    }

    @objc(preferredWindowingControlStyleForScene:)
    public func preferredWindowingControlStyleForScene(_ windowScene: UIWindowScene) -> AnyObject? {
        Self.resolvedWindowingControlStyle(
            userInterfaceIdiom: windowScene.traitCollection.userInterfaceIdiom
        )
    }
}
#endif
