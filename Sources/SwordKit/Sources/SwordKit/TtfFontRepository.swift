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

    /// Exact forward-slash path beneath `ttf/`, including nested Android restore directories.
    public let relativePath: String

    /**
     Creates metadata for one manually installed Android-style TTF addon.

     - Parameters:
       - fontName: User-visible font name derived from the installed TTF filename without its extension.
       - moduleName: SWORD addon module initials written to `mods.d/<moduleName>.conf`.
       - fileName: TTF filename stored under the SWORD root's `ttf/` directory.
       - relativePath: Optional nested path beneath `ttf/`; defaults to `fileName` for manual imports.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        fontName: String,
        moduleName: String,
        fileName: String,
        relativePath: String? = nil
    ) {
        self.fontName = fontName
        self.moduleName = moduleName
        self.fileName = fileName
        self.relativePath = relativePath ?? fileName
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

        let installed = installedFontMetadata(relativePath: fileName)
        let stagingDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "ttf-addon-\(UUID().uuidString).staging",
            isDirectory: true
        )
        let stagedFontURL = stagingDirectory.appendingPathComponent(fileName)
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            try fileManager.copyItem(at: url, to: stagedFontURL)
            try mutationPublisher.publishTtfAddon(
                installed,
                stagedFontURL: stagedFontURL,
                configContent: addonConfig(for: installed)
            )
        } catch {
            if !sourceIsReadable(url) {
                throw TtfFontRepositoryError.cantRead(fileName)
            }
            throw TtfFontRepositoryError.cantWrite(fileName)
        }
        return installed
    }

    /**
     Ensures every manually copied TTF file has Android-style addon metadata.

     Android registers TTF files from `modulesDir/ttf` during app initialization. iOS persists the
     equivalent metadata to `mods.d` so discovery works through normal `SwordManager` scans.

     - Returns: Installed-font metadata for each readable `.ttf` file found under `ttf/`.
     - Side effects: transactionally rewrites addon config files and invalidates the SWORD module
       cache for each readable font. A missing font directory is not created.
     - Throws: Cancellation or `TtfFontRepositoryError.cantWrite` when transactional config
       publication fails. Directory listing failures are treated as no readable TTF files, matching
       Android startup registration.
     */
    @discardableResult
    public func registerInstalledFonts() throws -> [InstalledTtfFont] {
        guard fileManager.fileExists(atPath: fontsDirectory.path),
              let enumerator = fileManager.enumerator(
                at: fontsDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isReadableKey,
                    .isSymbolicLinkKey,
                ],
                options: []
              ) else {
            return []
        }

        let fontPackPathKeys = configuredFontPackPathKeys()
        var discoveredFontPaths: [String] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try? file.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isReadableKey,
                .isSymbolicLinkKey,
            ])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard file.pathExtension.lowercased() == "ttf",
                  values?.isRegularFile == true,
                  values?.isReadable != false,
                  let relativePath = relativeFontPath(for: file),
                  !fontPackPathKeys.contains(filesystemCollisionKey(relativePath)) else {
                continue
            }
            discoveredFontPaths.append(relativePath)
        }

        discoveredFontPaths.sort {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        var installedFonts: [InstalledTtfFont] = []
        var registeredIdentities = Set<String>()
        for relativePath in discoveredFontPaths {
            try Task.checkCancellation()
            let installed = installedFontMetadata(relativePath: relativePath)
            guard registeredIdentities.insert(
                filesystemCollisionKey(installed.moduleName)
            ).inserted else {
                continue
            }
            do {
                try mutationPublisher.publishTtfAddon(
                    installed,
                    stagedFontURL: nil,
                    configContent: addonConfig(for: installed)
                )
            } catch {
                throw TtfFontRepositoryError.cantWrite(installed.fileName)
            }
            installedFonts.append(installed)
        }
        return installedFonts
    }

    /// Shared transactional publisher for this SWORD root.
    private var mutationPublisher: ModuleStoreTransactionPublisher {
        ModuleStoreTransactionPublisher(
            moduleRootURL: URL(fileURLWithPath: swordPath, isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Directory where Android stores manually installed TTF files.
    private var fontsDirectory: URL {
        URL(fileURLWithPath: swordPath, isDirectory: true)
            .appendingPathComponent("ttf", isDirectory: true)
    }

    /**
     Resolves files already owned by installed FontPack configs beneath `ttf/`.

     Android registers configured font packs as their existing SWORD module and only synthesizes
     `TTF_` books for otherwise unowned manual files. iOS-generated manual registrations carry an
     explicit marker and remain eligible for deterministic refresh.

     - Returns: Filesystem collision keys for config-owned TTF paths.
     - Side effects: Reads installed SWORD configs through the shared parser.
     - Failure modes: Malformed, unsafe, and non-TTF provider rows are ignored; normal module
       inventory remains responsible for reporting an unusable FontPack.
     */
    private func configuredFontPackPathKeys() -> Set<String> {
        var keys = Set<String>()
        for config in SwordModuleConfig.readAll(modulePath: swordPath) {
            guard config.values["andbibleiosmanualttf"] == nil,
                  let providers = config.values["andbibleprovidesfont"],
                  config.dataPath.hasPrefix("ttf/") else {
                continue
            }
            let parent = String(config.dataPath.dropFirst("ttf/".count))
            for provider in providers {
                guard let separator = provider.firstIndex(of: ";") else { continue }
                let fileName = provider[provider.index(after: separator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let relativePath = parent + fileName
                let components = relativePath.split(
                    separator: "/",
                    omittingEmptySubsequences: false
                )
                guard !components.isEmpty,
                      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                      !relativePath.contains("\\"),
                      !relativePath.contains("\0"),
                      (relativePath as NSString).pathExtension.lowercased() == "ttf" else {
                    continue
                }
                keys.insert(filesystemCollisionKey(relativePath))
            }
        }
        return keys
    }

    /** Matches the case/canonical equivalence of the destination filesystem. */
    private func filesystemCollisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }

    /**
     Builds stable addon metadata for one TTF filename.

     - Parameter relativePath: Exact validated path beneath the `ttf` directory.
     - Returns: Font metadata with an Android-shaped `TTF_` module name.
     */
    private func installedFontMetadata(relativePath: String) -> InstalledTtfFont {
        let fileName = (relativePath as NSString).lastPathComponent
        let fontName = sanitizedConfigValue((fileName as NSString).deletingPathExtension)
        let moduleName = "TTF_" + fontName
        return InstalledTtfFont(
            fontName: fontName,
            moduleName: moduleName,
            fileName: fileName,
            relativePath: relativePath
        )
    }

    /** Returns generated SWORD config content that makes one TTF visible as an addon. */
    private func addonConfig(for font: InstalledTtfFont) -> String {
        let parent = (font.relativePath as NSString).deletingLastPathComponent
        let dataPath = parent.isEmpty || parent == "." ? "./ttf/" : "./ttf/\(parent)/"
        return """
        [\(font.moduleName)]
        Description=\(font.fontName)
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=\(dataPath)
        Encoding=UTF-8
        AndBibleProvidesFont=\(font.fontName);\(font.fileName)
        AndBibleIOSGeneratedRegistration=true
        AndBibleIOSManualTtf=true
        AndBibleMinimumVersion=892

        """
    }

    /**
     Resolves one enumerated font to a safe path relative to the Android `ttf` root.

     - Parameter fileURL: Real regular file produced by the repository enumerator.
     - Returns: Forward-slash relative path, or `nil` when the path escapes or contains traversal.
     - Side effects: none.
     - Failure modes: Unsafe or non-descendant paths are ignored during Android-style discovery.
     */
    private func relativeFontPath(for fileURL: URL) -> String? {
        let rootComponents = fontsDirectory.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        let components = fileComponents.dropFirst(rootComponents.count)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
        }) else {
            return nil
        }
        return components.joined(separator: "/")
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
     Normalizes an external filename to one basename before TTF validation.

     - Parameter rawName: Provider-supplied filename.
     - Returns: Non-empty basename with unsafe path and filename characters replaced. Blank provider
       names fall back to a UUID `.ttf` filename, matching Android's generated display-name path.
     - Important: `installFont(from:displayName:)` rejects sanitized names that do not end in `.ttf`
       before appending them under `ttf/`; this rejects special path components such as `.` and `..`.
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

}
