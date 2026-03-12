// GoogleDriveAuthService.swift — Google Sign-In session and Drive-scope management

import Foundation
import Observation
import GoogleSignIn
#if os(iOS)
import UIKit
#endif

/**
 One signed-in Google account snapshot suitable for sync settings UI and token access decisions.

 The Google Sign-In SDK exposes richer objects with profile-image helpers, fetcher authorizers, and
 token containers. The sync layer only needs stable account identity plus the granted-scope list,
 so this value type captures the subset that drives AndBible's Google Drive backend behavior.
 */
public struct GoogleDriveAccount: Sendable, Equatable {
    /// Primary email address returned by Google Sign-In when available.
    public let emailAddress: String?

    /// Human-readable full name returned by Google Sign-In when available.
    public let displayName: String?

    /// OAuth scopes currently granted to the app for this account.
    public let grantedScopes: [String]

    /**
     Creates one Google account snapshot.

     - Parameters:
       - emailAddress: Primary email address returned by Google Sign-In when available.
       - displayName: Human-readable full name returned by Google Sign-In when available.
       - grantedScopes: OAuth scopes currently granted to the app.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(emailAddress: String?, displayName: String?, grantedScopes: [String]) {
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.grantedScopes = grantedScopes
    }

    /**
     Returns the most helpful single-line label for settings UI.

     - Returns: Display name when present, otherwise email address, or `nil` when neither exists.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public var preferredDisplayLabel: String? {
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDisplayName, !trimmedDisplayName.isEmpty {
            return trimmedDisplayName
        }

        let trimmedEmailAddress = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEmailAddress, !trimmedEmailAddress.isEmpty {
            return trimmedEmailAddress
        }

        return nil
    }
}

/**
 High-level Google Drive session state exposed to SwiftUI.

 The sync settings screen needs to distinguish four materially different cases:
 - this iOS build is not configured for Google OAuth at all
 - the build is configured but no cached or interactive sign-in exists yet
 - a signed-in user exists but the Drive `appDataFolder` scope has not been granted
 - the account is fully ready for Google Drive sync
 */
public enum GoogleDriveAuthState: Sendable, Equatable {
    /// Google Drive sign-in is not configured in the app bundle.
    case notConfigured(String)

    /// No signed-in Google account is currently cached.
    case signedOut

    /// Sign-in or token-restoration work is in progress.
    case authenticating

    /// A Google account is available; `driveAccessGranted` indicates scope readiness for sync.
    case signedIn(GoogleDriveAccount, driveAccessGranted: Bool)

    /// A recoverable Google sign-in or token-refresh error occurred.
    case error(String)
}

/**
 Errors raised by `GoogleDriveAuthService`.

 The remote-sync pipeline needs concrete failure reasons when Google Drive cannot be used, while
 the settings UI needs human-readable localized text for status rows and alerts. These errors keep
 that surface narrow and Android-aligned: either the build is misconfigured, the user is not
 signed in, or the required Drive scope is still missing.
 */
public enum GoogleDriveAuthServiceError: Error, Equatable {
    /// The current iOS build does not declare a Google client ID.
    case notConfigured

    /// The required reversed-client-ID URL scheme is missing from `Info.plist`.
    case missingURLScheme(String)

    /// An interactive sign-in flow could not find a presenter.
    case missingPresentingViewController

    /// No signed-in Google account is currently available.
    case notSignedIn

    /// The signed-in account has not granted the Drive `appDataFolder` scope yet.
    case missingDriveScope

    /// The Google Sign-In SDK returned an error description that should be surfaced as-is.
    case sdk(String)
}

extension GoogleDriveAuthServiceError: LocalizedError {
    /**
     User-visible localized description for one auth failure.

     - Returns: Localized message suitable for settings status and alerts.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "google_drive_not_configured")
        case .missingURLScheme:
            return String(localized: "google_drive_missing_url_scheme")
        case .missingPresentingViewController:
            return String(localized: "google_drive_missing_presenter")
        case .notSignedIn:
            return String(localized: "google_drive_not_signed_in")
        case .missingDriveScope:
            return String(localized: "google_drive_permission_required")
        case .sdk(let message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedMessage.isEmpty {
                return String(localized: "sign_in_failed")
            }
            return trimmedMessage
        }
    }
}

/**
 Validated Google OAuth bundle configuration required by the iOS Google Sign-In SDK.

 iOS requires two bundle-time pieces of configuration before interactive sign-in can work:
 - `GIDClientID` in `Info.plist`
 - the reversed client ID declared under `CFBundleURLTypes` so the OAuth callback can return to
   the app
 */
public struct GoogleDriveOAuthConfiguration: Sendable, Equatable {
    /// Google OAuth client identifier used to configure `GIDSignIn`.
    public let clientID: String

    /// Optional backend server client ID used when the app also exchanges ID tokens server-side.
    public let serverClientID: String?

    /// Reversed client-ID URL scheme expected in `CFBundleURLTypes`.
    public let reversedClientIDScheme: String

    /**
     Creates one validated OAuth configuration payload.

     - Parameters:
       - clientID: Google OAuth client identifier.
       - serverClientID: Optional backend server client identifier.
       - reversedClientIDScheme: Reversed client-ID URL scheme expected in the app bundle.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(clientID: String, serverClientID: String?, reversedClientIDScheme: String) {
        self.clientID = clientID
        self.serverClientID = serverClientID
        self.reversedClientIDScheme = reversedClientIDScheme
    }

    /**
     Validates OAuth configuration from an app-bundle info dictionary.

     - Parameter infoDictionary: `Info.plist` dictionary to inspect.
     - Returns: Validated OAuth configuration payload.
     - Side effects: none.
     - Failure modes:
       - throws `GoogleDriveAuthServiceError.notConfigured` when `GIDClientID` is absent or blank
       - throws `GoogleDriveAuthServiceError.missingURLScheme(_:)` when the reversed client ID is
         not declared under `CFBundleURLTypes`
     */
    public static func from(infoDictionary: [String: Any]?) throws -> GoogleDriveOAuthConfiguration {
        guard let infoDictionary else {
            throw GoogleDriveAuthServiceError.notConfigured
        }

        let clientID = (infoDictionary["GIDClientID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clientID.isEmpty else {
            throw GoogleDriveAuthServiceError.notConfigured
        }

        let serverClientID = (infoDictionary["GIDServerClientID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServerClientID = serverClientID?.isEmpty == true ? nil : serverClientID
        let reversedClientIDScheme = Self.reversedClientIDScheme(from: clientID)

        guard declaredURLSchemes(in: infoDictionary).contains(reversedClientIDScheme) else {
            throw GoogleDriveAuthServiceError.missingURLScheme(reversedClientIDScheme)
        }

        return GoogleDriveOAuthConfiguration(
            clientID: clientID,
            serverClientID: normalizedServerClientID,
            reversedClientIDScheme: reversedClientIDScheme
        )
    }

    /**
     Computes the reversed-client-ID callback scheme expected by Google Sign-In.

     - Parameter clientID: Forward client ID from Google Cloud Console.
     - Returns: Dot-component-reversed client ID used as the callback URL scheme.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public static func reversedClientIDScheme(from clientID: String) -> String {
        clientID
            .split(separator: ".")
            .reversed()
            .joined(separator: ".")
    }

    /**
     Returns every URL scheme declared in `CFBundleURLTypes`.

     - Parameter infoDictionary: `Info.plist` dictionary to inspect.
     - Returns: Lower-level callback URL schemes declared by the bundle.
     - Side effects: none.
     - Failure modes: Malformed `CFBundleURLTypes` structures are ignored.
     */
    private static func declaredURLSchemes(in infoDictionary: [String: Any]) -> Set<String> {
        let urlTypes = infoDictionary["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return Set(
            urlTypes
                .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

/**
 Minimal user shape required by `GoogleDriveAuthService`.

 The live implementation wraps `GIDGoogleUser`, while tests inject lightweight fakes so auth-state
 transitions and token refresh behavior can be exercised without invoking the real SDK.
 */
@MainActor
protocol GoogleDriveAuthenticatedUser: AnyObject {
    /// Signed-in user's primary email address when available.
    var emailAddress: String? { get }

    /// Signed-in user's full display name when available.
    var displayName: String? { get }

    /// OAuth scopes currently granted to the app.
    var grantedScopes: [String] { get }

    /// Current Google OAuth access token string.
    var accessTokenString: String { get }

    /**
     Refreshes tokens when Google considers them stale.

     - Returns: Updated user snapshot after refresh completed.
     - Side effects: May perform network I/O through the Google Sign-In SDK.
     - Failure modes: Re-throws SDK token-refresh failures.
     */
    func refreshTokensIfNeeded() async throws -> any GoogleDriveAuthenticatedUser
}

/**
 Minimal Google Sign-In client surface required by `GoogleDriveAuthService`.

 This protocol keeps the service testable without mocking static `GIDSignIn.sharedInstance`
 globals inside the test bundle.
 */
@MainActor
protocol GoogleDriveSignInClient: AnyObject {
    /// Currently signed-in user, if any.
    var currentUser: (any GoogleDriveAuthenticatedUser)? { get }

    /// Whether the SDK has a previous sign-in saved in Keychain.
    var hasPreviousSignIn: Bool { get }

    /**
     Configures the SDK with the validated client identifiers from the app bundle.

     - Parameters:
       - clientID: Google OAuth client identifier.
       - serverClientID: Optional backend server client identifier.
     - Side effects: Updates the underlying SDK configuration.
     - Failure modes: This helper cannot fail.
     */
    func configure(clientID: String, serverClientID: String?)

    /**
     Attempts to restore the previous sign-in silently.

     - Returns: Restored user when the SDK found one, otherwise `nil`.
     - Side effects: May perform Keychain access and token refresh work through the SDK.
     - Failure modes: Re-throws SDK restoration failures.
     */
    func restorePreviousSignIn() async throws -> (any GoogleDriveAuthenticatedUser)?

    #if os(iOS)
    /**
     Starts a fresh interactive Google sign-in flow.

     - Parameters:
       - presentingViewController: Presenter used for the web-authentication flow.
       - additionalScopes: OAuth scopes to request in addition to the basic profile scopes.
     - Returns: Signed-in user that completed the interactive flow.
     - Side effects: Presents Google Sign-In UI.
     - Failure modes: Re-throws SDK sign-in failures and user-cancellation errors.
     */
    func signIn(
        presentingViewController: UIViewController,
        additionalScopes: [String]
    ) async throws -> any GoogleDriveAuthenticatedUser

    /**
     Requests additional scopes for the currently signed-in user.

     - Parameters:
       - scopes: Additional OAuth scopes to request.
       - presentingViewController: Presenter used for the consent flow.
     - Returns: Updated signed-in user after scope consent completed.
     - Side effects: Presents Google scope-consent UI.
     - Failure modes:
       - throws `GoogleDriveAuthServiceError.notSignedIn` when no user is cached
       - re-throws SDK scope-consent failures and user-cancellation errors
     */
    func addScopes(
        _ scopes: [String],
        presentingViewController: UIViewController
    ) async throws -> any GoogleDriveAuthenticatedUser
    #endif

    /**
     Hands OAuth callback URLs back to the Google Sign-In SDK.

     - Parameter url: Incoming URL routed to the app.
     - Returns: `true` when the SDK consumed the URL.
     - Side effects: May advance an in-flight sign-in session inside the SDK.
     - Failure modes: This helper cannot fail.
     */
    func handle(url: URL) -> Bool

    /**
     Signs the current user out and clears cached credentials.

     - Side effects: Removes Google Sign-In session state from the SDK Keychain cache.
     - Failure modes: This helper cannot fail.
     */
    func signOut()
}

/**
 Live wrapper around `GIDGoogleUser`.

 The wrapper converts Objective-C SDK callbacks into async Swift methods while preserving the
 fields the remote-sync layer actually consumes.
 */
@MainActor
final class LiveGoogleDriveAuthenticatedUser: GoogleDriveAuthenticatedUser {
    private let user: GIDGoogleUser

    /**
     Wraps one SDK user object.

     - Parameter user: Live SDK user object.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(user: GIDGoogleUser) {
        self.user = user
    }

    /// Signed-in user's primary email address when available.
    var emailAddress: String? {
        user.profile?.email
    }

    /// Signed-in user's full display name when available.
    var displayName: String? {
        user.profile?.name
    }

    /// OAuth scopes currently granted to the app.
    var grantedScopes: [String] {
        user.grantedScopes ?? []
    }

    /// Current Google OAuth access token string.
    var accessTokenString: String {
        user.accessToken.tokenString
    }

    /**
     Refreshes tokens if Google marks them stale.

     - Returns: Updated wrapped user snapshot.
     - Side effects: May perform network I/O through the Google Sign-In SDK.
     - Failure modes: Re-throws SDK token-refresh failures.
     */
    func refreshTokensIfNeeded() async throws -> any GoogleDriveAuthenticatedUser {
        try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let refreshedUser {
                    continuation.resume(returning: LiveGoogleDriveAuthenticatedUser(user: refreshedUser))
                } else {
                    continuation.resume(
                        throwing: GoogleDriveAuthServiceError.sdk(
                            String(localized: "sign_in_failed")
                        )
                    )
                }
            }
        }
    }
}

/**
 Live wrapper around `GIDSignIn.sharedInstance`.

 The sync layer depends on a narrow async surface rather than directly on the SDK singleton so
 tests can inject deterministic fakes.
 */
@MainActor
final class LiveGoogleDriveSignInClient: GoogleDriveSignInClient {
    private let signIn = GIDSignIn.sharedInstance

    /// Currently signed-in user, if any.
    var currentUser: (any GoogleDriveAuthenticatedUser)? {
        signIn.currentUser.map { LiveGoogleDriveAuthenticatedUser(user: $0) }
    }

    /// Whether the SDK has a previous sign-in saved in Keychain.
    var hasPreviousSignIn: Bool {
        signIn.hasPreviousSignIn()
    }

    /**
     Configures the live SDK client.

     - Parameters:
       - clientID: Google OAuth client identifier.
       - serverClientID: Optional backend server client identifier.
     - Side effects: Replaces `GIDSignIn.sharedInstance.configuration`.
     - Failure modes: This helper cannot fail.
     */
    func configure(clientID: String, serverClientID: String?) {
        signIn.configuration = GIDConfiguration(clientID: clientID, serverClientID: serverClientID)
    }

    /**
     Attempts to restore the previous Google sign-in.

     - Returns: Restored user when one exists, otherwise `nil`.
     - Side effects: May perform Keychain access and token refresh work through the SDK.
     - Failure modes: Re-throws SDK restoration failures.
     */
    func restorePreviousSignIn() async throws -> (any GoogleDriveAuthenticatedUser)? {
        try await withCheckedThrowingContinuation { continuation in
            signIn.restorePreviousSignIn { user, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: user.map { LiveGoogleDriveAuthenticatedUser(user: $0) }
                    )
                }
            }
        }
    }

    #if os(iOS)
    /**
     Starts a fresh interactive Google sign-in flow.

     - Parameters:
       - presentingViewController: Presenter used for the web-authentication flow.
       - additionalScopes: OAuth scopes to request in addition to the basic profile scopes.
     - Returns: Signed-in user that completed the interactive flow.
     - Side effects: Presents Google Sign-In UI.
     - Failure modes: Re-throws SDK sign-in failures and user-cancellation errors.
     */
    func signIn(
        presentingViewController: UIViewController,
        additionalScopes: [String]
    ) async throws -> any GoogleDriveAuthenticatedUser {
        try await withCheckedThrowingContinuation { continuation in
            signIn.signIn(
                withPresenting: presentingViewController,
                hint: nil,
                additionalScopes: additionalScopes
            ) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let user = result?.user {
                    continuation.resume(returning: LiveGoogleDriveAuthenticatedUser(user: user))
                } else {
                    continuation.resume(
                        throwing: GoogleDriveAuthServiceError.sdk(
                            String(localized: "sign_in_failed")
                        )
                    )
                }
            }
        }
    }

    /**
     Requests additional scopes for the currently signed-in user.

     - Parameters:
       - scopes: Additional OAuth scopes to request.
       - presentingViewController: Presenter used for the consent flow.
     - Returns: Updated signed-in user after scope consent completed.
     - Side effects: Presents Google scope-consent UI.
     - Failure modes:
       - throws `GoogleDriveAuthServiceError.notSignedIn` when no user is cached
       - re-throws SDK scope-consent failures and user-cancellation errors
     */
    func addScopes(
        _ scopes: [String],
        presentingViewController: UIViewController
    ) async throws -> any GoogleDriveAuthenticatedUser {
        guard let currentUser = signIn.currentUser else {
            throw GoogleDriveAuthServiceError.notSignedIn
        }

        return try await withCheckedThrowingContinuation { continuation in
            currentUser.addScopes(scopes, presenting: presentingViewController) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let user = result?.user {
                    continuation.resume(returning: LiveGoogleDriveAuthenticatedUser(user: user))
                } else {
                    continuation.resume(
                        throwing: GoogleDriveAuthServiceError.sdk(
                            String(localized: "sign_in_failed")
                        )
                    )
                }
            }
        }
    }
    #endif

    /**
     Hands OAuth callback URLs back to the SDK.

     - Parameter url: Incoming URL routed to the app.
     - Returns: `true` when the SDK consumed the URL.
     - Side effects: May advance an in-flight sign-in session inside the SDK.
     - Failure modes: This helper cannot fail.
     */
    func handle(url: URL) -> Bool {
        signIn.handle(url)
    }

    /**
     Signs the current user out and clears cached credentials.

     - Side effects: Removes Google Sign-In session state from the SDK Keychain cache.
     - Failure modes: This helper cannot fail.
     */
    func signOut() {
        signIn.signOut()
    }
}

/**
 Main-actor Google Drive auth/session service shared by the iOS app shell and sync settings UI.

 Data dependencies:
 - `GoogleDriveSignInClient` provides the concrete Google Sign-In SDK bridge
 - `GoogleDriveOAuthConfiguration` validates `Info.plist` client-ID and callback-scheme state
 - on iOS, a presenting-view-controller provider supplies the UI presenter for interactive sign-in

 Side effects:
 - configures the Google Sign-In SDK with bundle client identifiers when available
 - restores previous Google sessions from SDK-managed Keychain state
 - may present interactive Google sign-in or additional-scope consent UI on iOS
 - refreshes Google access tokens on demand for the Google Drive sync adapter

 Failure modes:
 - bundle misconfiguration transitions the service into `.notConfigured` instead of crashing
 - token-refresh or sign-in failures transition the service into `.error`
 - access-token requests throw concrete auth errors when the build is not configured, no account is
   signed in, or the Drive scope has not been granted yet

 Concurrency:
 - this type is main-actor isolated because the Google Sign-In SDK is UIKit-oriented and because
   SwiftUI observes its mutable state directly
 - `@unchecked Sendable` is used only so the async access-token provider can capture this service
   and hop to the main actor before reading or mutating state
 */
@MainActor
@Observable
public final class GoogleDriveAuthService: @unchecked Sendable {
    /// Drive scope Android uses for app-private sync storage in `appDataFolder`.
    public static let driveAppDataScope = "https://www.googleapis.com/auth/drive.appdata"

    /// Current high-level auth state observed by SwiftUI.
    public private(set) var state: GoogleDriveAuthState

    private let signInClient: any GoogleDriveSignInClient
    private let oauthConfiguration: GoogleDriveOAuthConfiguration?
    private let initialConfigurationError: GoogleDriveAuthServiceError?
    private let infoDictionary: [String: Any]?
    private let hasRestoredPreviousSignInKey = UUID().uuidString
    private var hasRestoredPreviousSignIn = false

    #if os(iOS)
    private let presentingViewControllerProvider: () -> UIViewController?
    #endif

    #if os(iOS)
    /**
     Creates a Google Drive auth/session service.

     - Parameters:
       - infoDictionary: App-bundle info dictionary used for OAuth configuration validation.
       - presentingViewControllerProvider: iOS presenter provider for interactive sign-in and
         scope-consent flows. Tests can inject a deterministic view controller.
     - Side effects:
       - configures the underlying sign-in client immediately when bundle OAuth configuration is valid
       - snapshots the current SDK user, if any, into the initial observable state
     - Failure modes:
       - bundle misconfiguration is captured in `state` instead of throwing from the initializer
     */
    public convenience init(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        presentingViewControllerProvider: (() -> UIViewController?)? = nil
    ) {
        self.init(
            signInClient: LiveGoogleDriveSignInClient(),
            infoDictionary: infoDictionary,
            presentingViewControllerProvider: presentingViewControllerProvider
        )
    }

    /**
     Creates a Google Drive auth/session service with an injected sign-in client.

     - Parameters:
       - signInClient: Concrete Google Sign-In bridge. Tests inject fakes.
       - infoDictionary: App-bundle info dictionary used for OAuth configuration validation.
       - presentingViewControllerProvider: iOS presenter provider for interactive sign-in and
         scope-consent flows. Tests can inject a deterministic view controller.
     - Side effects:
       - configures the underlying sign-in client immediately when bundle OAuth configuration is valid
       - snapshots the current SDK user, if any, into the initial observable state
     - Failure modes:
       - bundle misconfiguration is captured in `state` instead of throwing from the initializer
     */
    init(
        signInClient: any GoogleDriveSignInClient,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        presentingViewControllerProvider: (() -> UIViewController?)? = nil
    ) {
        self.signInClient = signInClient
        self.infoDictionary = infoDictionary
        self.presentingViewControllerProvider = presentingViewControllerProvider ?? {
            GoogleDriveAuthService.defaultPresentingViewController()
        }

        let oauthConfiguration: GoogleDriveOAuthConfiguration?
        let initialConfigurationError: GoogleDriveAuthServiceError?
        do {
            let parsedConfiguration = try GoogleDriveOAuthConfiguration.from(infoDictionary: infoDictionary)
            signInClient.configure(
                clientID: parsedConfiguration.clientID,
                serverClientID: parsedConfiguration.serverClientID
            )
            oauthConfiguration = parsedConfiguration
            initialConfigurationError = nil
        } catch let error as GoogleDriveAuthServiceError {
            oauthConfiguration = nil
            initialConfigurationError = error
        } catch {
            oauthConfiguration = nil
            initialConfigurationError = .sdk(error.localizedDescription)
        }

        self.oauthConfiguration = oauthConfiguration
        self.initialConfigurationError = initialConfigurationError

        if let initialConfigurationError {
            self.state = .notConfigured(
                initialConfigurationError.localizedDescription
            )
        } else if let currentUser = signInClient.currentUser {
            self.state = Self.state(from: currentUser)
        } else {
            self.state = .signedOut
        }
    }
    #else
    /**
     Creates a Google Drive auth/session service.

     - Parameters:
       - infoDictionary: App-bundle info dictionary used for OAuth configuration validation.
     - Side effects:
       - configures the underlying sign-in client immediately when bundle OAuth configuration is valid
       - snapshots the current SDK user, if any, into the initial observable state
     - Failure modes:
       - bundle misconfiguration is captured in `state` instead of throwing from the initializer
     */
    public convenience init(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        self.init(
            signInClient: LiveGoogleDriveSignInClient(),
            infoDictionary: infoDictionary
        )
    }

    /**
     Creates a Google Drive auth/session service with an injected sign-in client.

     - Parameters:
       - signInClient: Concrete Google Sign-In bridge. Tests inject fakes.
       - infoDictionary: App-bundle info dictionary used for OAuth configuration validation.
     - Side effects:
       - configures the underlying sign-in client immediately when bundle OAuth configuration is valid
       - snapshots the current SDK user, if any, into the initial observable state
     - Failure modes:
       - bundle misconfiguration is captured in `state` instead of throwing from the initializer
     */
    init(
        signInClient: any GoogleDriveSignInClient,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        self.signInClient = signInClient
        self.infoDictionary = infoDictionary

        let oauthConfiguration: GoogleDriveOAuthConfiguration?
        let initialConfigurationError: GoogleDriveAuthServiceError?
        do {
            let parsedConfiguration = try GoogleDriveOAuthConfiguration.from(infoDictionary: infoDictionary)
            signInClient.configure(
                clientID: parsedConfiguration.clientID,
                serverClientID: parsedConfiguration.serverClientID
            )
            oauthConfiguration = parsedConfiguration
            initialConfigurationError = nil
        } catch let error as GoogleDriveAuthServiceError {
            oauthConfiguration = nil
            initialConfigurationError = error
        } catch {
            oauthConfiguration = nil
            initialConfigurationError = .sdk(error.localizedDescription)
        }

        self.oauthConfiguration = oauthConfiguration
        self.initialConfigurationError = initialConfigurationError

        if let initialConfigurationError {
            self.state = .notConfigured(
                initialConfigurationError.localizedDescription
            )
        } else if let currentUser = signInClient.currentUser {
            self.state = Self.state(from: currentUser)
        } else {
            self.state = .signedOut
        }
    }
    #endif

    /**
     Whether this iOS build has the bundle-time Google OAuth configuration required for sign-in.

     - Returns: `true` when `GIDClientID` and the reversed-client-ID URL scheme were validated.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public var isConfigured: Bool {
        oauthConfiguration != nil
    }

    /**
     Whether a signed-in account currently has the Drive scope required for sync.

     - Returns: `true` when the observable state is a signed-in account with Drive access granted.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public var isReadyForSync: Bool {
        guard case .signedIn(_, driveAccessGranted: true) = state else {
            return false
        }
        return true
    }

    /**
     Human-readable signed-in account label for settings UI.

     - Returns: Preferred display label for the current account, or `nil` when signed out.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public var currentAccountLabel: String? {
        guard case .signedIn(let account, _) = state else {
            return nil
        }
        return account.preferredDisplayLabel
    }

    /**
     Restores the previous Google sign-in at most once per service lifetime.

     The app shell calls this during startup so sync settings and lifecycle-driven remote sync can
     see an already-restored session without forcing the user back through interactive sign-in.
     Repeated calls are ignored unless `force` is set.
     *
     - Parameter force: Whether a prior restore attempt should be ignored and re-run.
     - Side effects:
       - may read Google session state from Keychain
       - may refresh Google tokens silently
       - mutates the observable `state`
     - Failure modes:
       - bundle misconfiguration leaves `state` in `.notConfigured`
       - restore failures move the service into `.error`
     */
    public func restorePreviousSignInIfNeeded(force: Bool = false) async {
        guard force || !hasRestoredPreviousSignIn else {
            return
        }
        hasRestoredPreviousSignIn = true

        guard oauthConfiguration != nil else {
            if let initialConfigurationError {
                state = .notConfigured(initialConfigurationError.localizedDescription)
            }
            return
        }

        guard signInClient.hasPreviousSignIn else {
            reconcileState(with: signInClient.currentUser)
            return
        }

        state = .authenticating

        do {
            let restoredUser = try await signInClient.restorePreviousSignIn()
            reconcileState(with: restoredUser)
        } catch {
            state = .error(Self.localizedMessage(for: error))
        }
    }

    #if os(iOS)
    /**
     Starts interactive sign-in or scope-consent UI as needed for Google Drive sync.

     - Side effects:
       - may present Google Sign-In or scope-consent UI
       - mutates the observable `state`
     - Failure modes:
       - throws `GoogleDriveAuthServiceError.notConfigured` when the app bundle is missing OAuth config
       - throws `GoogleDriveAuthServiceError.missingPresentingViewController` when no presenter exists
       - re-throws SDK sign-in failures and user-cancellation errors
     */
    public func signInInteractively() async throws {
        guard oauthConfiguration != nil else {
            let error = initialConfigurationError ?? GoogleDriveAuthServiceError.notConfigured
            state = .notConfigured(error.localizedDescription)
            throw error
        }

        guard let presentingViewController = presentingViewControllerProvider() else {
            let error = GoogleDriveAuthServiceError.missingPresentingViewController
            state = .error(error.localizedDescription)
            throw error
        }

        state = .authenticating

        do {
            let user: any GoogleDriveAuthenticatedUser
            if let currentUser = signInClient.currentUser,
               !Self.hasDriveScope(currentUser) {
                user = try await signInClient.addScopes(
                    [Self.driveAppDataScope],
                    presentingViewController: presentingViewController
                )
            } else if signInClient.currentUser != nil {
                user = signInClient.currentUser!
            } else {
                user = try await signInClient.signIn(
                    presentingViewController: presentingViewController,
                    additionalScopes: [Self.driveAppDataScope]
                )
            }

            reconcileState(with: user)
        } catch {
            let message = Self.localizedMessage(for: error)
            state = .error(message)
            throw (error as? GoogleDriveAuthServiceError) ?? .sdk(message)
        }
    }
    #endif

    /**
     Signs the current Google account out and clears the observable session state.

     - Side effects:
       - instructs the underlying Google Sign-In SDK to forget the current session
       - mutates the observable `state`
     - Failure modes: This helper cannot fail.
     */
    public func signOut() {
        signInClient.signOut()
        state = oauthConfiguration == nil
            ? .notConfigured(
                (initialConfigurationError ?? .notConfigured).localizedDescription
            )
            : .signedOut
    }

    /**
     Hands OAuth callback URLs back to Google Sign-In.

     - Parameter url: Incoming URL routed to the app.
     - Returns: `true` when Google Sign-In consumed the URL.
     - Side effects: May advance an in-flight sign-in session inside the SDK.
     - Failure modes: This helper cannot fail.
     */
    public func handle(url: URL) -> Bool {
        signInClient.handle(url: url)
    }

    /**
     Returns a fresh Google Drive access token suitable for REST requests.

     - Returns: OAuth access token string with Drive `appDataFolder` scope.
     - Side effects:
       - may refresh Google tokens through the SDK
       - mutates the observable `state` with the refreshed user snapshot
     - Failure modes:
       - throws `GoogleDriveAuthServiceError.notConfigured` when OAuth bundle config is missing
       - throws `GoogleDriveAuthServiceError.notSignedIn` when no account is cached
       - throws `GoogleDriveAuthServiceError.missingDriveScope` when the Drive scope has not been granted
       - re-throws SDK token-refresh failures
     */
    public func accessToken() async throws -> String {
        guard oauthConfiguration != nil else {
            let error = initialConfigurationError ?? GoogleDriveAuthServiceError.notConfigured
            state = .notConfigured(error.localizedDescription)
            throw error
        }

        guard let currentUser = signInClient.currentUser else {
            state = .signedOut
            throw GoogleDriveAuthServiceError.notSignedIn
        }

        guard Self.hasDriveScope(currentUser) else {
            reconcileState(with: currentUser)
            throw GoogleDriveAuthServiceError.missingDriveScope
        }

        do {
            let refreshedUser = try await currentUser.refreshTokensIfNeeded()
            reconcileState(with: refreshedUser)
            return refreshedUser.accessTokenString
        } catch {
            let message = Self.localizedMessage(for: error)
            state = .error(message)
            throw (error as? GoogleDriveAuthServiceError) ?? .sdk(message)
        }
    }

    /**
     Reconciles the observable auth state from an optional SDK user snapshot.

     - Parameter user: Current or restored signed-in user.
     - Side effects: Mutates the observable `state`.
     - Failure modes: This helper cannot fail.
     */
    private func reconcileState(with user: (any GoogleDriveAuthenticatedUser)?) {
        guard oauthConfiguration != nil else {
            state = .notConfigured(
                (initialConfigurationError ?? .notConfigured).localizedDescription
            )
            return
        }

        if let user {
            state = Self.state(from: user)
        } else {
            state = .signedOut
        }
    }

    /**
     Converts one SDK user snapshot into the observable auth state.

     - Parameter user: Signed-in SDK user snapshot.
     - Returns: Observable state representing the account and Drive-scope readiness.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func state(from user: any GoogleDriveAuthenticatedUser) -> GoogleDriveAuthState {
        let account = GoogleDriveAccount(
            emailAddress: user.emailAddress,
            displayName: user.displayName,
            grantedScopes: user.grantedScopes
        )
        return .signedIn(account, driveAccessGranted: hasDriveScope(user))
    }

    /**
     Returns whether the Google user currently has Drive `appDataFolder` access.

     - Parameter user: Signed-in SDK user snapshot.
     - Returns: `true` when `drive.appdata` is present in the granted-scope list.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func hasDriveScope(_ user: any GoogleDriveAuthenticatedUser) -> Bool {
        user.grantedScopes.contains(Self.driveAppDataScope)
    }

    /**
     Normalizes thrown errors into the user-visible string surface.

     - Parameter error: Error emitted by the sign-in client or token refresh path.
     - Returns: Localized human-readable message suitable for settings UI.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func localizedMessage(for error: Error) -> String {
        if let authError = error as? GoogleDriveAuthServiceError {
            return authError.localizedDescription
        }

        let localizedDescription = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if localizedDescription.isEmpty {
            return String(localized: "sign_in_failed")
        }
        return localizedDescription
    }

    #if os(iOS)
    /**
     Locates the top-most active view controller for interactive sign-in presentation.

     - Returns: Presenter rooted in the active foreground window scene, or `nil` when no scene is active.
     - Side effects: Reads UIKit scene and window state.
     - Failure modes: This helper cannot fail.
     */
    private static func defaultPresentingViewController() -> UIViewController? {
        let rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?
            .rootViewController

        return topMostViewController(from: rootViewController)
    }

    /**
     Walks the presentation stack to the currently visible view controller.

     - Parameter rootViewController: Root view controller for one active window.
     - Returns: Top-most presented view controller, or `nil` when the root is missing.
     - Side effects: Reads UIKit presentation state.
     - Failure modes: This helper cannot fail.
     */
    private static func topMostViewController(from rootViewController: UIViewController?) -> UIViewController? {
        var currentViewController = rootViewController
        while let presentedViewController = currentViewController?.presentedViewController {
            currentViewController = presentedViewController
        }
        return currentViewController
    }
    #endif
}
