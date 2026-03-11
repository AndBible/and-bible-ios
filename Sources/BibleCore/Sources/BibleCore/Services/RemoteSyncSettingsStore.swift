// RemoteSyncSettingsStore.swift — Backend selection and credential persistence

import Foundation
import Security

/**
 Supported sync backends that can be selected by the evolving cross-platform sync settings flow.

 Android stores remote adapter selection under the `sync_adapter` key with enum-like string
 values such as `NEXT_CLOUD` and `GOOGLE_DRIVE`. iOS extends that value set with `ICLOUD` so the
 new settings layer can coexist with the already-shipping CloudKit sync path without inventing a
 second backend-selection key.
 */
public enum RemoteSyncBackend: String, CaseIterable, Sendable {
    /// Native iCloud/CloudKit sync used by the current iOS implementation.
    case iCloud = "ICLOUD"

    /// WebDAV / NextCloud / ownCloud sync, matching Android's `CloudAdapters.NEXT_CLOUD`.
    case nextCloud = "NEXT_CLOUD"

    /// Google Drive sync, matching Android's `CloudAdapters.GOOGLE_DRIVE`.
    case googleDrive = "GOOGLE_DRIVE"
}

/**
 Non-secret WebDAV connection settings persisted in the local settings store.

 This payload mirrors the fields Android stores in preferences for its NextCloud adapter:
 `gdrive_server_url`, `gdrive_username`, and `gdrive_folder_path`.
 */
public struct WebDAVSyncConfiguration: Sendable, Equatable {
    /// Base WebDAV server URL.
    public let serverURL: String

    /// Username used for HTTP authentication.
    public let username: String

    /// Optional folder path under the server root.
    public let folderPath: String?

    /**
     Creates a WebDAV configuration payload.

     - Parameters:
       - serverURL: Base WebDAV server URL.
       - username: Username used for authentication.
       - folderPath: Optional folder path beneath the server root.
     - Note: This initializer performs no normalization. Trimming and empty-string coercion happen
       when the configuration is persisted through `RemoteSyncSettingsStore`.
     */
    public init(serverURL: String, username: String, folderPath: String?) {
        self.serverURL = serverURL
        self.username = username
        self.folderPath = folderPath
    }

    /**
     Resolves the persisted server URL into the DAV base endpoint used by `WebDAVClient`.

     Android stores the plain server root URL for its NextCloud adapter. This helper expands that
     root into the standard NextCloud DAV files endpoint, while still accepting already-expanded
     DAV URLs for advanced or generic WebDAV setups.

     - Returns: Normalized DAV base URL suitable for `WebDAVClient` requests.
     - Side Effects: none.
     - Failure modes:
       - throws `WebDAVClientError.invalidURL` when the server URL is malformed, uses a non-HTTP
         scheme, contains whitespace, or points at a login page instead of a DAV root
     */
    public func resolvedDAVBaseURL() throws -> URL {
        let trimmedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerURL.isEmpty, !trimmedUsername.isEmpty else {
            throw WebDAVClientError.invalidURL
        }
        guard trimmedServerURL.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw WebDAVClientError.invalidURL
        }
        guard var components = URLComponents(string: trimmedServerURL) else {
            throw WebDAVClientError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebDAVClientError.invalidURL
        }

        let normalizedPathComponents = components.path
            .split(separator: "/")
            .map(String.init)
        if normalizedPathComponents.last?.lowercased() == "login" {
            throw WebDAVClientError.invalidURL
        }

        if !Self.pathAlreadyPointsAtDAVRoot(normalizedPathComponents) {
            let encodedUsername = trimmedUsername.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? trimmedUsername
            let prefix = normalizedPathComponents.isEmpty
                ? ""
                : "/" + normalizedPathComponents.joined(separator: "/")
            components.path = "\(prefix)/remote.php/dav/files/\(encodedUsername)"
        } else {
            components.path = "/" + normalizedPathComponents.joined(separator: "/")
        }

        guard let url = components.url else {
            throw WebDAVClientError.invalidURL
        }
        return url
    }

    /**
     Builds a transport client from the persisted WebDAV configuration.

     - Parameters:
       - password: Secret password or app password used for HTTP Basic authentication.
       - session: URL session used for transport. Tests can inject a custom configuration.
     - Returns: `WebDAVClient` bound to the resolved DAV endpoint and supplied credentials.
     - Side Effects: none.
     - Failure modes:
       - throws `WebDAVClientError.invalidURL` when `resolvedDAVBaseURL()` cannot normalize the
         stored server URL into a valid DAV endpoint
     */
    public func makeWebDAVClient(
        password: String,
        session: URLSession = .shared
    ) throws -> WebDAVClient {
        WebDAVClient(
            baseURL: try resolvedDAVBaseURL(),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.trimmingCharacters(in: .whitespacesAndNewlines),
            session: session
        )
    }

    /**
     Detects whether a normalized server path already points at a DAV resource root.

     - Parameter pathComponents: Slash-delimited path components from the server URL.
     - Returns: `true` when the path already contains a DAV-specific endpoint segment.
     - Side Effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func pathAlreadyPointsAtDAVRoot(_ pathComponents: [String]) -> Bool {
        guard !pathComponents.isEmpty else {
            return false
        }

        if pathComponents.count >= 3 {
            for index in 0...(pathComponents.count - 3) {
                if pathComponents[index] == "remote.php",
                   pathComponents[index + 1] == "dav",
                   pathComponents[index + 2] == "files" {
                    return true
                }
            }
        }

        if pathComponents.count >= 2 {
            for index in 0...(pathComponents.count - 2) {
                if pathComponents[index] == "remote.php",
                   pathComponents[index + 1] == "webdav" {
                    return true
                }
            }
        }

        return false
    }
}

/**
 Abstract secret store used for sync credentials.

 The production implementation is Keychain-backed, while tests can inject an in-memory store.
 */
public protocol SecretStoring: AnyObject {
    /**
     Reads a previously stored secret string, or `nil` when absent.

     - Parameter key: Logical secret identifier.
     - Returns: Stored secret text, or `nil` when the secret does not exist.
     - Side Effects: Reads from the concrete backing secret store, such as Keychain.
     - Failure modes: Concrete implementations may collapse lookup failures into `nil`.
     */
    func secret(forKey key: String) -> String?

    /**
     Inserts or updates a secret string.

     - Parameters:
       - value: Secret string to persist.
       - key: Logical secret identifier.
     - Side Effects: Writes to the concrete backing secret store.
     - Throws: Backend-specific write errors.
     */
    func setSecret(_ value: String, forKey key: String) throws

    /**
     Removes a previously stored secret.

     - Parameter key: Logical secret identifier.
     - Side Effects: Deletes the concrete backing secret-store entry when present.
     - Throws: Backend-specific delete errors.
     */
    func removeSecret(forKey key: String) throws
}

/**
 Errors emitted by the Keychain-backed secret store.
 */
public enum KeychainSecretStoreError: Error, Equatable {
    /// Keychain returned an unexpected status code.
    case unexpectedStatus(OSStatus)
}

/**
 Persists sync credentials in the system Keychain.

 This store is intentionally local-only. Secrets such as WebDAV passwords must never be synced
 through SwiftData or `UserDefaults`.
 */
public final class KeychainSecretStore: SecretStoring {
    /// Keychain service namespace shared by all secrets in this store instance.
    private let service: String

    /**
     Creates a Keychain-backed secret store for one logical service namespace.

     - Parameter service: Keychain service name used to namespace stored secrets.
     - Side Effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(service: String) {
        self.service = service
    }

    /**
     Reads a secret string from Keychain.

     - Parameter key: Logical secret identifier stored as the Keychain account.
     - Returns: UTF-8 secret text, or `nil` when the item does not exist or the payload cannot be
       decoded as UTF-8 text.
     - Side Effects: Performs a Keychain lookup through `SecItemCopyMatching`.
     - Failure modes:
       - returns `nil` when the item does not exist
       - returns `nil` when Keychain lookup fails or the payload is not UTF-8 text
     */
    public func secret(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /**
     Inserts or updates a secret string in Keychain.

     - Parameters:
       - value: Secret string to persist.
       - key: Logical secret identifier stored as the Keychain account.
     - Side Effects:
       - updates an existing Keychain item when one already exists
       - inserts a new Keychain item when the account has not been stored yet
     - Failure modes:
       - throws `KeychainSecretStoreError.unexpectedStatus` when Keychain insert or update fails
     */
    public func setSecret(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0] = $1 }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainSecretStoreError.unexpectedStatus(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    /**
     Removes a secret string from Keychain.

     - Parameter key: Logical secret identifier stored as the Keychain account.
     - Side Effects: Deletes the matching Keychain item when present.
     - Failure modes:
       - throws `KeychainSecretStoreError.unexpectedStatus` when Keychain deletion fails
     */
    public func removeSecret(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
    }

    /**
     Builds the base Keychain query shared by lookup, insert, update, and delete operations.

     - Parameter key: Logical secret identifier stored as the Keychain account.
     - Returns: Dictionary configured for the service namespace and account key.
     - Side Effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/**
 Persists remote-sync backend selection and backend-specific local settings.

 This store layers on top of `SettingsStore` for non-secret fields and `SecretStoring` for
 passwords and tokens. It intentionally mirrors Android's durable preference keys for the legacy
 cloud-sync settings:
 - `sync_adapter`
 - `gdrive_server_url`
 - `gdrive_username`
 - `gdrive_folder_path`
 - `gdrive_password`

 The password is intentionally split out to Keychain because iOS should not persist secrets in the
 raw `Setting` table. The store is otherwise isolated from the current CloudKit runtime so future
 sync backends can be configured without destabilizing the existing `SyncService`.
 */
public final class RemoteSyncSettingsStore {
    /**
     Android-compatible keys reused for NextCloud/WebDAV sync settings persistence.

     Android's NextCloud adapter still uses the historical `gdrive_*` preference keys, so iOS uses
     the same names to keep parity with the existing configuration contract.
     */
    private enum Keys {
        static let backend = "sync_adapter"
        static let webDAVServerURL = "gdrive_server_url"
        static let webDAVUsername = "gdrive_username"
        static let webDAVFolderPath = "gdrive_folder_path"
        static let webDAVPassword = "gdrive_password"
    }

    /// Local-only SwiftData-backed settings store for backend selection and non-secret fields.
    private let settingsStore: SettingsStore

    /// Secret store used for credentials that must not be written into SwiftData or `UserDefaults`.
    private let secretStore: any SecretStoring

    /**
     Creates a sync-settings store bound to local settings and secret storage.

     - Parameters:
       - settingsStore: Local-only settings store for backend selection and non-secret fields.
       - secretStore: Secret store used for passwords and tokens. Defaults to Keychain.
     - Side Effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        settingsStore: SettingsStore,
        secretStore: any SecretStoring = KeychainSecretStore(service: "org.andbible.remote-sync")
    ) {
        self.settingsStore = settingsStore
        self.secretStore = secretStore
    }

    /**
     Currently selected sync backend.

     iOS defaults to `.iCloud` when no backend has been persisted yet because the current shipping
     sync implementation is CloudKit-based. When the user selects a remote backend that Android
     also supports, the raw stored value matches Android's `CloudAdapters` enum name.

     - Side Effects: Setting this property writes to the `sync_adapter` key in `SettingsStore`.
     - Failure modes:
       - invalid stored backend strings fall back to `.iCloud`
     */
    public var selectedBackend: RemoteSyncBackend {
        get {
            let stored = settingsStore.getString(Keys.backend) ?? RemoteSyncBackend.iCloud.rawValue
            return RemoteSyncBackend(rawValue: stored) ?? .iCloud
        }
        set {
            settingsStore.setString(Keys.backend, value: newValue.rawValue)
        }
    }

    /**
     Reads the currently stored WebDAV configuration.

     - Returns: Persisted non-secret WebDAV configuration, or `nil` when required fields are absent.
     - Side Effects: Reads local settings from `SettingsStore`.
     - Failure modes: Missing or whitespace-only server URL or username fields return `nil`.
     */
    public func loadWebDAVConfiguration() -> WebDAVSyncConfiguration? {
        let serverURL = settingsStore.getString(Keys.webDAVServerURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = settingsStore.getString(Keys.webDAVUsername)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !serverURL.isEmpty, !username.isEmpty else {
            return nil
        }

        let folderPath = settingsStore.getString(Keys.webDAVFolderPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WebDAVSyncConfiguration(
            serverURL: serverURL,
            username: username,
            folderPath: folderPath?.isEmpty == true ? nil : folderPath
        )
    }

    /**
     Reads the WebDAV password from the secret store.

     - Returns: Stored password text, or `nil` when no password has been saved.
     - Side Effects: Reads from the configured `SecretStoring` backend, typically Keychain.
     - Failure modes: Secret-store lookup failures collapse to `nil`.
     */
    public func webDAVPassword() -> String? {
        secretStore.secret(forKey: Keys.webDAVPassword)
    }

    /**
     Builds a configured `WebDAVClient` from persisted settings and Keychain-backed credentials.

     - Parameter session: URL session used for transport. Tests can inject a custom configuration.
     - Returns: Configured client when the required WebDAV settings and password are present, or
       `nil` when configuration is incomplete.
     - Side Effects: Reads from `SettingsStore` and the configured `SecretStoring` backend.
     - Failure modes:
       - returns `nil` when the configuration or password has not been fully provided yet
       - rethrows `WebDAVClientError.invalidURL` when the stored server URL cannot be normalized
         into a valid DAV endpoint
     */
    public func makeWebDAVClient(session: URLSession = .shared) throws -> WebDAVClient? {
        guard let configuration = loadWebDAVConfiguration() else {
            return nil
        }
        let trimmedPassword = webDAVPassword()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPassword.isEmpty else {
            return nil
        }
        return try configuration.makeWebDAVClient(password: trimmedPassword, session: session)
    }

    /**
     Persists WebDAV non-secret fields and optionally updates the stored password.

     - Parameters:
       - configuration: Non-secret WebDAV settings to persist.
       - password: Optional password to write to the secret store. Empty strings clear the secret.
     - Side Effects:
       - writes server URL, username, and folder path to `SettingsStore` using Android-compatible
         keys
       - writes or deletes the password in the configured secret store
     - Failure modes:
       - rethrows secret-store failures when password persistence fails
     */
    public func saveWebDAVConfiguration(
        _ configuration: WebDAVSyncConfiguration,
        password: String?
    ) throws {
        settingsStore.setString(
            Keys.webDAVServerURL,
            value: configuration.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        settingsStore.setString(
            Keys.webDAVUsername,
            value: configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        settingsStore.setString(
            Keys.webDAVFolderPath,
            value: configuration.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )

        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedPassword.isEmpty {
            try secretStore.removeSecret(forKey: Keys.webDAVPassword)
        } else {
            try secretStore.setSecret(trimmedPassword, forKey: Keys.webDAVPassword)
        }
    }

    /**
     Clears all persisted WebDAV settings and secrets.

     - Side Effects:
       - clears the Android-compatible WebDAV fields from `SettingsStore`
       - deletes the stored password from the configured secret store
     - Failure modes:
       - rethrows secret-store failures when password deletion fails
     */
    public func clearWebDAVConfiguration() throws {
        settingsStore.setString(Keys.webDAVServerURL, value: "")
        settingsStore.setString(Keys.webDAVUsername, value: "")
        settingsStore.setString(Keys.webDAVFolderPath, value: "")
        try secretStore.removeSecret(forKey: Keys.webDAVPassword)
    }
}
