// MyBibleRepositoryManifest.swift - Shared Android-compatible MyBible manifest schema

/**
 Android-compatible MyBible repository manifest decoded by validation and catalog refresh.

 This shared model keeps repository-source validation and Downloads catalog conversion on the
 same required-field and coding-key contract. The manifest is read from trusted HTTPS responses
 during custom repository registration and refresh; it performs no I/O itself and throws standard
 `DecodingError` values when required Android fields are absent or malformed.
 */
struct MyBibleRepositoryManifest: Decodable, Sendable {
    /// Canonical manifest URL reported inside the Android-compatible spec.
    let url: String

    /// User-visible repository name from the Android `file_name` field.
    let fileName: String

    /// Repository description shown by Android and preserved by iOS metadata.
    let description: String

    /// Downloadable module rows exposed by the manifest.
    let modules: [MyBibleModuleManifest]

    private enum CodingKeys: String, CodingKey {
        case url
        case fileName = "file_name"
        case description
        case modules
    }
}

/**
 Android-compatible MyBible module row converted into a Downloads catalog entry.

 The row mirrors the Android manifest field names so validation and refresh decode the same shape.
 Consumers normalize values such as download URLs and language codes after decoding, because those
 normalization rules depend on the caller's workflow. The type performs no I/O and fails only
 through standard `DecodingError` values from `JSONDecoder`.
 */
struct MyBibleModuleManifest: Decodable, Sendable {
    /// Package filename used for initials/category inference.
    let fileName: String

    /// User-visible module description.
    let description: String

    /// Package URL from `download_url`; iOS normalizes HTTP to HTTPS before use.
    let downloadURL: String

    /// Manifest language code for the row.
    let languageCode: String

    /// Manifest update date stored as the remote version marker.
    let updateDate: String

    /// Manifest update text retained for future metadata display.
    let updateInfo: String

    private enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case description
        case downloadURL = "download_url"
        case languageCode = "language_code"
        case updateDate = "update_date"
        case updateInfo = "update_info"
    }
}
