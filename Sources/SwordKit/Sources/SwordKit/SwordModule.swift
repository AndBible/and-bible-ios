// SwordModule.swift — SWModule wrapper for SwordKit

import Foundation
import CLibSword

/// Swift wrapper around a SWORD SWModule instance.
///
/// Provides verse key navigation, text retrieval, and search capabilities.
/// All operations are serialized on an internal queue since libsword is not thread-safe.
///
/// Do not create instances directly — obtain them from `SwordManager.module(named:)`.
public final class SwordModule: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    private let queue: DispatchQueue

    /// Module metadata.
    public let info: ModuleInfo

    init(handle: UnsafeMutableRawPointer, queue: DispatchQueue, modulePath: String? = nil) {
        self.handle = handle
        self.queue = queue

        // Extract metadata once at init
        let name = String(cString: SWModule_getName(handle))
        let description = String(cString: SWModule_getDescription(handle))
        let typeStr = String(cString: SWModule_getType(handle))
        let language = String(cString: SWModule_getLanguage(handle))

        // Detect features by parsing the .conf file directly from disk.
        // SWORD's flat API getConfigEntry() only returns the FIRST value for
        // multi-value keys (Feature, GlobalOptionFilter), so modules like KJV
        // where StrongsNumbers isn't the first entry are missed. Reading the
        // .conf file catches ALL entries.
        let features = SwordModule.detectFeatures(
            name: name, handle: handle, modulePath: modulePath
        )

        let cipherKey = SWModule_getConfigEntry(handle, "CipherKey")
        let isEncrypted = cipherKey != nil
        let directionPtr = SWModule_getConfigEntry(handle, "Direction")
        let direction = directionPtr != nil ? String(cString: directionPtr!) : "LtoR"
        let versionPtr = SWModule_getConfigEntry(handle, "Version")
        let versionStr = versionPtr != nil ? String(cString: versionPtr!) : ""

        self.info = ModuleInfo(
            name: name,
            description: description,
            category: ModuleCategory(typeString: typeStr),
            language: language,
            version: versionStr,
            isEncrypted: isEncrypted,
            isUnlocked: !isEncrypted || (cipherKey.map { String(cString: $0) } ?? "").isEmpty == false,
            features: features,
            isRightToLeft: direction == "RtoL"
        )
    }

    // MARK: - Key Navigation

    /// Set the current verse/key position.
    /// - Parameter keyText: A verse reference like "Gen 1:1" or a dictionary key.
    public func setKey(_ keyText: String) {
        queue.sync {
            SWModule_setKeyText(handle, keyText)
        }
    }

    /// Get the current key text.
    public func currentKey() -> String {
        queue.sync {
            String(cString: SWModule_getKeyText(handle))
        }
    }

    /// Navigate to the next entry/verse.
    /// - Returns: `true` if navigation succeeded (not at end).
    @discardableResult
    public func next() -> Bool {
        queue.sync {
            SWModule_next(handle) == 0
        }
    }

    /// Navigate to the previous entry/verse.
    /// - Returns: `true` if navigation succeeded (not at beginning).
    @discardableResult
    public func previous() -> Bool {
        queue.sync {
            SWModule_previous(handle) == 0
        }
    }

    /// Navigate to the beginning of the module.
    public func begin() {
        queue.sync {
            SWModule_begin(handle)
        }
    }

    /// Check if the current position is at the end.
    public var isAtEnd: Bool {
        queue.sync {
            SWModule_isEnd(handle) != 0
        }
    }

    // MARK: - Text Retrieval

    /// Get rendered text (with markup/HTML) at the current position.
    public func renderText() -> String {
        queue.sync {
            String(cString: SWModule_getRenderText(handle))
        }
    }

    /// Get raw entry text at the current position (no markup processing).
    public func rawEntry() -> String {
        queue.sync {
            String(cString: SWModule_getRawEntry(handle))
        }
    }

    /// Get plain/strip text at the current position (no markup at all).
    public func stripText() -> String {
        queue.sync {
            String(cString: SWModule_getStripText(handle))
        }
    }

    /// Get rendered header text (chapter/book introductions).
    public func renderHeader() -> String {
        queue.sync {
            String(cString: SWModule_getRenderHeader(handle))
        }
    }

    // MARK: - Configuration

    /// Get a module configuration entry value.
    /// - Parameter key: The config key (e.g., "About", "LCSH", "DistributionLicense").
    /// - Returns: The value, or nil if not found.
    public func configEntry(_ key: String) -> String? {
        queue.sync {
            guard let cStr = SWModule_getConfigEntry(handle, key) else { return nil }
            return String(cString: cStr)
        }
    }

    /// Set the cipher key for encrypted modules.
    /// - Parameter key: The decryption key.
    public func setCipherKey(_ key: String) {
        queue.sync {
            SWModule_setCipherKey(handle, key)
        }
    }

    // MARK: - Key Browsing

    /// Collect all entry keys in the module (for dictionary/genbook key browsing).
    /// Uses begin()/next() iteration, returns array of key strings.
    /// Faster than `iterateAllEntries` since it skips text retrieval.
    public func allKeys() -> [String] {
        queue.sync {
            let savedKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, savedKey) }

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else { return [] }

            var keys: [String] = []
            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                keys.append(key)
                if SWModule_next(handle) != 0 { break }
            }
            return keys
        }
    }

    /// Get child keys at the current position (for tree-key modules like general books).
    /// Returns the NULL-terminated string array from SWORD's getKeyChildren.
    public func keyChildren() -> [String] {
        queue.sync {
            guard let children = SWModule_getKeyChildren(handle) else { return [] }
            var result: [String] = []
            var i = 0
            while let ptr = children[i] {
                result.append(String(cString: ptr))
                i += 1
            }
            return result
        }
    }

    // MARK: - Bulk Iteration

    /// Iterate through all entries in the module, calling the callback for each.
    ///
    /// The callback receives `(key, plainText, index)` and should return `true` to continue.
    /// All SWORD operations run in a single queue.sync block for efficiency.
    /// The module's current key position is saved and restored after iteration.
    ///
    /// - Parameter callback: Called for each entry. Return `false` to stop early.
    public func iterateAllEntries(_ callback: (String, String, Int) -> Bool) {
        queue.sync {
            // Save current position
            let savedKey = String(cString: SWModule_getKeyText(handle))

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else {
                SWModule_setKeyText(handle, savedKey)
                return
            }

            var index = 0
            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                let text = String(cString: SWModule_getStripText(handle))
                if !callback(key, text, index) { break }
                index += 1
                if SWModule_next(handle) != 0 { break }
            }

            // Restore position
            SWModule_setKeyText(handle, savedKey)
        }
    }

    // MARK: - Search

    /// Search the module for the given query.
    /// - Parameter options: Search configuration.
    /// - Returns: Search results.
    public func search(_ options: SearchOptions) -> SearchResults {
        queue.sync {
            let flags: Int32 = options.caseInsensitive ? 2 : 0 // REG_ICASE = 2

            _ = SWModule_search(
                handle,
                options.query,
                Int32(options.searchType.rawValue),
                flags,
                options.scope,
                nil
            )

            let count = SWModule_searchResultCount(handle)
            var results: [SearchResult] = []
            results.reserveCapacity(Int(count))

            for i in 0..<count {
                let key = String(cString: SWModule_getSearchResultKeyText(handle, i))
                // Get preview text by navigating to the result key
                SWModule_setKeyText(handle, key)
                let preview = String(cString: SWModule_getStripText(handle))
                results.append(SearchResult(
                    key: key,
                    moduleName: info.name,
                    previewText: String(preview.prefix(200))
                ))
            }

            return SearchResults(
                options: options,
                moduleName: info.name,
                results: results
            )
        }
    }

    // MARK: - Feature Detection

    /// Detect module features by parsing the .conf file directly from disk.
    ///
    /// SWORD's flat API `getConfigEntry()` only returns the first value for
    /// multi-value keys like `Feature` and `GlobalOptionFilter`. This causes
    /// modules where `StrongsNumbers` isn't the first entry (e.g., KJV) to
    /// be missed. Parsing the .conf file catches all entries.
    ///
    /// Falls back to the C API if the conf file can't be read.
    private static func detectFeatures(
        name: String,
        handle: UnsafeMutableRawPointer,
        modulePath: String?
    ) -> ModuleFeatures {
        var features: ModuleFeatures = []

        // Try reading .conf file directly (reliable for multi-value keys)
        if let modulePath,
           let confLines = readConfFile(name: name, modulePath: modulePath) {
            for line in confLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Feature=") || trimmed.hasPrefix("GlobalOptionFilter=") {
                    let value = String(trimmed[trimmed.index(after: trimmed.firstIndex(of: "=")!)...])
                        .trimmingCharacters(in: .whitespaces)
                    if value.contains("Strongs") || value.contains("OSISStrongs") {
                        features.insert(.strongsNumbers)
                    }
                    if value.contains("Morphology") || value.contains("OSISMorph") {
                        features.insert(.morphology)
                    }
                    if value.contains("Footnotes") || value.contains("OSISFootnotes") {
                        features.insert(.footnotes)
                    }
                    if value.contains("Headings") || value.contains("OSISHeadings") {
                        features.insert(.headings)
                    }
                    if value.contains("RedLetterWords") || value.contains("OSISRedLetterWords") {
                        features.insert(.redLetterWords)
                    }
                    if value.contains("GreekDef") { features.insert(.greekDef) }
                    if value.contains("HebrewDef") { features.insert(.hebrewDef) }
                    if value.contains("GreekParse") { features.insert(.greekParse) }
                    if value.contains("HebrewParse") { features.insert(.hebrewParse) }
                    if value.contains("DailyDevotion") { features.insert(.dailyDevotion) }
                }
            }
        } else {
            // Fallback: use C API (only gets first value for multi-value keys)
            if SWModule_hasFeature(handle, "StrongsNumbers") != 0 { features.insert(.strongsNumbers) }
            if SWModule_hasFeature(handle, "GreekDef") != 0 { features.insert(.greekDef) }
            if SWModule_hasFeature(handle, "HebrewDef") != 0 { features.insert(.hebrewDef) }
            if SWModule_hasFeature(handle, "GreekParse") != 0 { features.insert(.greekParse) }
            if SWModule_hasFeature(handle, "HebrewParse") != 0 { features.insert(.hebrewParse) }
            if SWModule_hasFeature(handle, "DailyDevotion") != 0 { features.insert(.dailyDevotion) }
        }

        return features
    }

    /// Read all lines from a module's .conf file.
    private static func readConfFile(name: String, modulePath: String) -> [String]? {
        let confPath = (modulePath as NSString)
            .appendingPathComponent("mods.d")
            .appending("/\(name.lowercased()).conf")
        guard let contents = try? String(contentsOfFile: confPath, encoding: .utf8) else {
            return nil
        }
        return contents.components(separatedBy: .newlines)
    }
}
