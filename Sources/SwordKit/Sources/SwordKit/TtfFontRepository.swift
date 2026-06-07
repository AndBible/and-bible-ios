// TtfFontRepository.swift -- Android-parity app-owned TTF font installation

import Foundation

/**
 Describes one TTF font installed as an Android-style And Bible addon module.

 Android stores manually imported fonts under `modulesDir/ttf` and registers an in-memory
 `Category=And Bible` module named `TTF_<fontName>`. iOS persists the same metadata as a SWORD
 `.conf` file so `SwordManager` can discover the font addon after startup or import.
 */
public struct InstalledTtfFont: Equatable, Sendable {
    /// User-visible font name derived from the installed TTF filename without its extension.
    public let fontName: String

    /// SWORD addon module initials written to `mods.d/<moduleName>.conf`.
    public let moduleName: String

    /// TTF filename stored under the SWORD root's `ttf/` directory.
    public let fileName: String

    /**
     Creates metadata for one manually installed Android-style TTF addon.

     - Parameters:
       - fontName: User-visible font name derived from the installed TTF filename without its extension.
       - moduleName: SWORD addon module initials written to `mods.d/<moduleName>.conf`.
       - fileName: TTF filename stored under the SWORD root's `ttf/` directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(fontName: String, moduleName: String, fileName: String) {
        self.fontName = fontName
        self.moduleName = moduleName
        self.fileName = fileName
    }
}

/**
 Errors produced while installing an app-owned TTF font.

 These mirror Android's install failure categories at the service boundary while carrying enough
 detail for localized import feedback and tests.
 */
public enum TtfFontRepositoryError: LocalizedError, Sendable {
    /// The selected file name does not identify a `.ttf` font.
    case invalidFont(String)

    /// The source file could not be read.
    case cantRead(String)

    /// The destination font or config file could not be written.
    case cantWrite(String)

    /// User-visible description used by import surfaces.
    public var errorDescription: String? {
        switch self {
        case .invalidFont(let fileName):
            return "Invalid TTF font: \(fileName)"
        case .cantRead(let fileName):
            return "Could not read TTF font: \(fileName)"
        case .cantWrite(let fileName):
            return "Could not write TTF font: \(fileName)"
        }
    }
}

/**
 Installs manually supplied TTF files into the app's SWORD module root.

 The repository intentionally models Android's `installTtf`/`addManuallyInstalledTtfBooks` behavior:
 imported fonts are copied under `<swordRoot>/ttf`, each font receives an `AndBibleProvidesFont`
 addon config, and the SWORD module cache is invalidated so a fresh `SwordManager` can discover the
 addon. The service does not register system fonts with iOS; it owns only AndBible reader resources.
 */
public struct TtfFontRepository: Sendable {
    /// SWORD module root containing `mods.d`, `modules`, and the Android-parity `ttf` directory.
    private let swordPath: String

    /// Filesystem service used for copy, config, and cache-invalidation work.
    private var fileManager: FileManager { .default }

    /**
     Creates a TTF font repository rooted at a SWORD module directory.

     - Parameter swordPath: SWORD root to mutate. Defaults to `SwordManager.defaultModulePath()`.
     - Side effects: none during initialization.
     - Failure modes: This initializer cannot fail.
     */
    public init(swordPath: String = SwordManager.defaultModulePath()) {
        self.swordPath = swordPath
    }

    /**
     Installs a single `.ttf` file as an And Bible addon module.

     - Parameters:
       - url: Readable source URL selected by the user or supplied by document open handling.
       - displayName: Optional filename from the external document provider; falls back to the URL's
         last path component.
     - Returns: Metadata for the installed font addon.
     - Side effects:
       - copies the TTF file into `<swordRoot>/ttf`
       - writes `<swordRoot>/mods.d/<module>.conf` with `AndBibleProvidesFont`
       - removes SWORD's `modules-conf.cache`
     - Throws: `TtfFontRepositoryError` or propagated filesystem errors when source or destination
       work fails.
     */
    public func installFont(from url: URL, displayName: String? = nil) throws -> InstalledTtfFont {
        let fileName = sanitizedFileName(displayName ?? url.lastPathComponent)
        guard fileName.lowercased().hasSuffix(".ttf") else {
            throw TtfFontRepositoryError.invalidFont(fileName)
        }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        if values?.isRegularFile == false || values?.isReadable == false {
            throw TtfFontRepositoryError.cantRead(fileName)
        }

        try createInstallDirectories()

        let destination = fontsDirectory.appendingPathComponent(fileName, isDirectory: false)
        if url.standardizedFileURL != destination.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                guard fileManager.isWritableFile(atPath: destination.path) else {
                    throw TtfFontRepositoryError.cantWrite(fileName)
                }
                try fileManager.removeItem(at: destination)
            }
            do {
                try fileManager.copyItem(at: url, to: destination)
            } catch {
                if !sourceIsReadable(url) {
                    throw TtfFontRepositoryError.cantRead(fileName)
                }
                throw TtfFontRepositoryError.cantWrite(fileName)
            }
        }

        let installed = installedFontMetadata(forFileName: fileName)
        try writeAddonConfig(for: installed)
        invalidateModuleCache()
        return installed
    }

    /**
     Ensures every manually copied TTF file has Android-style addon metadata.

     Android registers TTF files from `modulesDir/ttf` during app initialization. iOS persists the
     equivalent metadata to `mods.d` so discovery works through normal `SwordManager` scans.

     - Returns: Installed-font metadata for each readable `.ttf` file found under `ttf/`.
     - Side effects: creates missing directories, rewrites addon config files, and invalidates the
       SWORD module cache when at least one font is registered.
     - Throws: filesystem errors while creating directories or writing config files.
     */
    @discardableResult
    public func registerInstalledFonts() throws -> [InstalledTtfFont] {
        try createInstallDirectories()
        guard let files = try? fileManager.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var installedFonts: [InstalledTtfFont] = []
        for file in files where file.pathExtension.lowercased() == "ttf" {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values?.isRegularFile != false, values?.isReadable != false else {
                continue
            }
            let installed = installedFontMetadata(forFileName: file.lastPathComponent)
            try writeAddonConfig(for: installed)
            installedFonts.append(installed)
        }

        if !installedFonts.isEmpty {
            invalidateModuleCache()
        }
        return installedFonts
    }

    /// Directory where Android stores manually installed TTF files.
    private var fontsDirectory: URL {
        URL(fileURLWithPath: swordPath, isDirectory: true)
            .appendingPathComponent("ttf", isDirectory: true)
    }

    /// Directory containing SWORD module config files.
    private var modsDirectory: URL {
        URL(fileURLWithPath: swordPath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
    }

    /**
     Creates the SWORD subdirectories touched by the TTF installer.

     - Side effects: creates `ttf` and `mods.d` directories when absent.
     - Throws: filesystem errors from `FileManager`.
     */
    private func createInstallDirectories() throws {
        try fileManager.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
    }

    /**
     Builds stable addon metadata for one TTF filename.

     - Parameter fileName: Sanitized filename stored in the `ttf` directory.
     - Returns: Font metadata with an Android-shaped `TTF_` module name.
     */
    private func installedFontMetadata(forFileName fileName: String) -> InstalledTtfFont {
        let fontName = sanitizedConfigValue((fileName as NSString).deletingPathExtension)
        let moduleName = "TTF_" + sanitizedModuleSuffix(fontName)
        return InstalledTtfFont(fontName: fontName, moduleName: moduleName, fileName: fileName)
    }

    /**
     Writes the SWORD config file that makes a TTF visible as an And Bible addon.

     - Parameter font: Installed-font metadata to serialize.
     - Side effects: writes or replaces one `.conf` file under `mods.d`.
     - Throws: `TtfFontRepositoryError.cantWrite` with the selected TTF filename when config
       serialization fails.
     */
    private func writeAddonConfig(for font: InstalledTtfFont) throws {
        let config = """
        [\(font.moduleName)]
        Description=\(font.fontName)
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./ttf/
        Encoding=UTF-8
        AndBibleProvidesFont=\(font.fontName);\(font.fileName)
        AndBibleMinimumVersion=892

        """
        let configURL = modsDirectory
            .appendingPathComponent(font.moduleName.lowercased(), isDirectory: false)
            .appendingPathExtension("conf")
        do {
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            throw TtfFontRepositoryError.cantWrite(font.fileName)
        }
    }

    /**
     Removes SWORD's module cache so the next manager sees newly registered font addons.

     - Side effects: deletes `mods.d/modules-conf.cache` when present.
     - Failure modes: deletion failures are ignored, matching the existing module installer.
     */
    private func invalidateModuleCache() {
        let cacheURL = modsDirectory.appendingPathComponent("modules-conf.cache", isDirectory: false)
        try? fileManager.removeItem(at: cacheURL)
    }

    /**
     Checks whether a source font URL is readable after copy failure.

     The preflight resource-value check can be inconclusive for security-scoped or provider-backed
     URLs. Rechecking with `FileManager` after `copyItem` fails lets import feedback distinguish
     unreadable sources from destination write errors without changing the installer contract.

     - Parameter url: Source URL passed to `installFont(from:displayName:)`.
     - Returns: `true` when the current process can still read the source path.
     - Side effects: none.
     - Failure modes: Inconclusive resource values fall back to `FileManager.isReadableFile`.
     */
    private func sourceIsReadable(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]) {
            if values.isRegularFile == false || values.isReadable == false {
                return false
            }
        }
        return fileManager.isReadableFile(atPath: url.path)
    }

    /**
     Normalizes an external filename so it cannot escape the `ttf` directory.

     - Parameter rawName: Provider-supplied filename.
     - Returns: Non-empty basename ending in `.ttf` when the source name did.
     */
    private func sanitizedFileName(_ rawName: String) -> String {
        let lastComponent = (rawName as NSString).lastPathComponent
        let trimmed = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? UUID().uuidString + ".ttf" : trimmed
        let scalars = base.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "-"
                || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        return String(scalars)
    }

    /**
     Removes line breaks from config values before writing SWORD metadata.

     - Parameter value: Filename-derived value.
     - Returns: Config-safe one-line value.
     */
    private func sanitizedConfigValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /**
     Creates a SWORD-safe module-name suffix from an arbitrary font name.

     - Parameter value: User-visible font name.
     - Returns: Non-empty alphanumeric/underscore suffix.
     */
    private func sanitizedModuleSuffix(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                return Character(scalar)
            }
            return "_"
        }
        let suffix = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return suffix.isEmpty ? "Font" : suffix
    }
}
