// ModuleRepository.swift — Swift-native SWORD module catalog and installer
//
// Replaces libsword's InstallMgr network operations (which require curl,
// not compiled into our iOS build) with pure Swift URLSession downloads.
// Used for: catalog browsing, module downloading, module installation.

import Foundation
import CLibSword
import os.log

private let logger = Logger(subsystem: "org.andbible.ios", category: "ModuleRepository")

/// Configuration for a remote SWORD module source.
public struct SourceConfig: Sendable, Identifiable {
    public let name: String
    public let type: String  // "HTTP" or "FTP"
    public let host: String
    public let catalogPath: String

    public var id: String { name }

    /// Base URL for this source (HTTPS preferred).
    public var baseURL: URL? {
        URL(string: "https://\(host)\(catalogPath)")
    }
}

/// Parsed module entry from a SWORD catalog .conf file.
public struct CatalogModule: Sendable, Identifiable {
    public let name: String
    public let description: String
    public let category: ModuleCategory
    public let language: String
    public let modDrv: String
    public let dataPath: String
    public let confContent: String
    public let sourceName: String
    public let version: String
    public let size: String

    public var id: String { "\(sourceName):\(name)" }

    /// Convert to the public RemoteModuleInfo type.
    public var remoteModuleInfo: RemoteModuleInfo {
        RemoteModuleInfo(
            name: name,
            description: description,
            category: category,
            language: language,
            sourceName: sourceName
        )
    }
}

/// Pure Swift implementation of SWORD catalog browsing and module installation.
///
/// Bypasses libsword's InstallMgr (which requires curl, not compiled for iOS)
/// and uses URLSession for all HTTP operations.
///
/// Usage:
/// ```swift
/// let repo = ModuleRepository()
/// let sources = repo.loadSources()
/// for source in sources {
///     let modules = try await repo.refreshCatalog(for: source)
///     // display modules...
/// }
/// try await repo.installModule(named: "KJV", from: sources[0])
/// ```
public final class ModuleRepository: @unchecked Sendable {
    private let basePath: String
    private let swordPath: String
    private let session: URLSession

    /// Catalog entries cached per source name.
    private var catalogCache: [String: [CatalogModule]] = [:]

    /// Directory for persisting catalog caches.
    private var cacheDir: String {
        let dir = (basePath as NSString).appendingPathComponent("catalog-cache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(basePath: String? = nil, swordPath: String? = nil) {
        self.basePath = basePath ?? InstallManager.defaultBasePath()
        self.swordPath = swordPath ?? SwordManager.defaultModulePath()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)

        // Ensure sword directories exist
        let fm = FileManager.default
        try? fm.createDirectory(atPath: self.swordPath, withIntermediateDirectories: true)
        let modsD = (self.swordPath as NSString).appendingPathComponent("mods.d")
        try? fm.createDirectory(atPath: modsD, withIntermediateDirectories: true)
    }

    // MARK: - Source Configuration

    /// Parse sources from InstallMgr.conf.
    public func loadSources() -> [SourceConfig] {
        // Ensure config exists
        InstallManager.ensureDefaultConfigPublic(at: basePath)

        let configPath = (basePath as NSString).appendingPathComponent("InstallMgr.conf")
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }

        var sources: [SourceConfig] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("HTTPSource=") {
                let value = String(trimmed.dropFirst("HTTPSource=".count))
                let parts = value.components(separatedBy: "|")
                if parts.count >= 3 {
                    sources.append(SourceConfig(
                        name: parts[0],
                        type: "HTTP",
                        host: parts[1],
                        catalogPath: parts[2]
                    ))
                }
            }
            // Skip FTP sources — URLSession doesn't support FTP
        }
        return sources
    }

    // MARK: - Catalog Cache (Disk)

    /// Codable wrapper for persisting catalog entries to disk.
    private struct CachedCatalog: Codable {
        var timestamp: Date
        var modules: [CachedModule]
    }

    private struct CachedModule: Codable {
        var name: String
        var description: String
        var category: String
        var language: String
        var sourceName: String
        var modDrv: String
        var dataPath: String
        var confContent: String
        var version: String
        var size: String
    }

    /// Load all cached catalogs from disk. Returns combined RemoteModuleInfo list.
    public func loadCachedCatalogs() -> [RemoteModuleInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cacheDir) else { return [] }

        var allModules: [RemoteModuleInfo] = []
        for file in files where file.hasSuffix(".json") {
            let path = (cacheDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data) else {
                continue
            }

            // Also restore in-memory catalogCache for install operations
            var entries: [CatalogModule] = []
            for m in cached.modules {
                let cat = ModuleCategory(typeString: m.category)
                let entry = CatalogModule(
                    name: m.name,
                    description: m.description,
                    category: cat,
                    language: m.language,
                    modDrv: m.modDrv,
                    dataPath: m.dataPath,
                    confContent: m.confContent,
                    sourceName: m.sourceName,
                    version: m.version,
                    size: m.size
                )
                entries.append(entry)
                allModules.append(entry.remoteModuleInfo)
            }

            let sourceName = String(file.dropLast(5)) // remove .json
            catalogCache[sourceName] = entries
        }

        return allModules
    }

    /// Save a source's catalog entries to disk.
    private func saveCatalogToDisk(sourceName: String, entries: [CatalogModule]) {
        let cached = CachedCatalog(
            timestamp: Date(),
            modules: entries.map { e in
                CachedModule(
                    name: e.name,
                    description: e.description,
                    category: e.category.rawValue,
                    language: e.language,
                    sourceName: e.sourceName,
                    modDrv: e.modDrv,
                    dataPath: e.dataPath,
                    confContent: e.confContent,
                    version: e.version,
                    size: e.size
                )
            }
        )

        guard let data = try? JSONEncoder().encode(cached) else { return }
        let path = (cacheDir as NSString).appendingPathComponent("\(sourceName).json")
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Age of the cached catalog for a source, or nil if not cached.
    public func catalogCacheAge(for sourceName: String) -> TimeInterval? {
        let path = (cacheDir as NSString).appendingPathComponent("\(sourceName).json")
        guard let data = FileManager.default.contents(atPath: path),
              let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data) else {
            return nil
        }
        return Date().timeIntervalSince(cached.timestamp)
    }

    // MARK: - Catalog Refresh

    /// Download and parse the module catalog for a source.
    /// - Returns: List of available modules from this source.
    public func refreshCatalog(for source: SourceConfig) async throws -> [RemoteModuleInfo] {
        guard source.type == "HTTP" else { return [] }

        guard let baseURL = source.baseURL else {
            throw ModuleRepositoryError.invalidURL(source.name)
        }

        // Download mods.d.tar.gz
        let catalogURL = baseURL.appendingPathComponent("mods.d.tar.gz")
        let (data, response) = try await session.data(from: catalogURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModuleRepositoryError.downloadFailed(
                "Catalog download from \(source.name) failed (HTTP \(code))")
        }

        // Decompress gzip
        let tarData = try decompressGzip(data)

        // Parse tar archive to extract .conf files
        let tarEntries = parseTar(tarData)

        // Parse each .conf file into a catalog entry
        var catalogEntries: [CatalogModule] = []
        for entry in tarEntries {
            // Only process .conf files
            guard entry.name.hasSuffix(".conf") else { continue }

            guard let content = String(data: entry.data, encoding: .utf8) ??
                                String(data: entry.data, encoding: .isoLatin1) else {
                continue
            }

            if let module = parseModuleConf(content, sourceName: source.name) {
                catalogEntries.append(module)
            }
        }

        // Cache in memory and persist to disk
        catalogCache[source.name] = catalogEntries
        saveCatalogToDisk(sourceName: source.name, entries: catalogEntries)

        return catalogEntries.map(\.remoteModuleInfo)
    }

    // MARK: - Module Installation

    /// Install a module by downloading its data files.
    /// - Parameters:
    ///   - moduleName: Module abbreviation (e.g., "KJV").
    ///   - source: The remote source to download from.
    ///   - progress: Optional progress callback (0.0 to 1.0).
    public func installModule(named moduleName: String, from source: SourceConfig,
                              progress: ((Double) -> Void)? = nil) async throws {
        guard let entries = catalogCache[source.name],
              let entry = entries.first(where: { $0.name == moduleName }) else {
            throw ModuleRepositoryError.moduleNotFound(moduleName)
        }

        guard let baseURL = source.baseURL else {
            throw ModuleRepositoryError.invalidURL(source.name)
        }

        let fm = FileManager.default

        // 1. Determine local directory and remote base path.
        //    For verse-keyed modules (ztext, rawtext, zcom, rawcom), DataPath is a directory
        //    (e.g. "modules/texts/ztext/kjv/") and files go directly inside.
        //    For lexicon/genbook modules (rawld, zld, rawgenbook), DataPath ends with a
        //    filename prefix (e.g. "modules/lexdict/rawld/strongshebrew/strongshebrew")
        //    — the parent is the directory, and files like "strongshebrew.dat" go there.
        let driver = entry.modDrv.lowercased()
        let usesFilePrefix = ["rawld", "rawld4", "zld", "rawgenbook"].contains(driver)
        let localDir: String
        let remoteBase: String
        if usesFilePrefix {
            // DataPath's parent is the actual directory
            localDir = ((swordPath as NSString).appendingPathComponent(entry.dataPath) as NSString).deletingLastPathComponent
            remoteBase = (entry.dataPath as NSString).deletingLastPathComponent
        } else {
            localDir = (swordPath as NSString).appendingPathComponent(entry.dataPath)
            remoteBase = entry.dataPath
        }
        try fm.createDirectory(atPath: localDir, withIntermediateDirectories: true)

        // 2. Determine files to download based on ModDrv
        let fileNames = moduleFiles(for: entry.modDrv, dataPath: entry.dataPath)

        // 3. Download each file
        let total = Double(max(fileNames.count, 1))
        var downloaded = 0

        for fileName in fileNames {
            let remoteURL = baseURL
                .appendingPathComponent(remoteBase)
                .appendingPathComponent(fileName)

            do {
                logger.info("Downloading \(remoteURL.absoluteString)")
                let (fileData, fileResponse) = try await session.data(from: remoteURL)
                guard let httpResp = fileResponse as? HTTPURLResponse,
                      httpResp.statusCode == 200 else {
                    let code = (fileResponse as? HTTPURLResponse)?.statusCode ?? -1
                    logger.warning("HTTP \(code) for \(fileName) — skipping")
                    downloaded += 1
                    progress?(Double(downloaded) / total)
                    continue
                }

                let localFilePath = (localDir as NSString).appendingPathComponent(fileName)
                try fileData.write(to: URL(fileURLWithPath: localFilePath))
                logger.info("Saved \(fileName) (\(fileData.count) bytes) to \(localFilePath)")
            } catch {
                logger.warning("Download failed for \(fileName): \(error.localizedDescription)")
            }

            downloaded += 1
            progress?(Double(downloaded) / total)
        }

        // 4. Write .conf file to mods.d/
        let modsDir = (swordPath as NSString).appendingPathComponent("mods.d")
        try fm.createDirectory(atPath: modsDir, withIntermediateDirectories: true)
        let confPath = (modsDir as NSString)
            .appendingPathComponent(moduleName.lowercased() + ".conf")
        try entry.confContent.write(toFile: confPath, atomically: true, encoding: .utf8)

        // 5. Invalidate SWORD's module cache so new SWMgr instances rescan
        invalidateModuleCache()

        progress?(1.0)
    }

    /// Uninstall a module by removing its data and conf files.
    public func uninstallModule(named moduleName: String) throws {
        let fm = FileManager.default

        // Find and read .conf file
        let modsDir = (swordPath as NSString).appendingPathComponent("mods.d")
        let confPath = (modsDir as NSString)
            .appendingPathComponent(moduleName.lowercased() + ".conf")

        // Read DataPath before deleting
        var dataPath: String?
        if let content = try? String(contentsOfFile: confPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("datapath=") {
                    let idx = trimmed.index(trimmed.startIndex, offsetBy: 9)
                    dataPath = String(trimmed[idx...])
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "./", with: "")
                    break
                }
            }
        }

        // Remove .conf file
        try? fm.removeItem(atPath: confPath)

        // Remove data directory
        if let dataPath, !dataPath.isEmpty {
            let fullDataPath = (swordPath as NSString).appendingPathComponent(dataPath)
            try? fm.removeItem(atPath: fullDataPath)
        }

        // Invalidate SWORD's module cache
        invalidateModuleCache()
    }

    /// Delete SWORD's modules-conf.cache so the next SWMgr instance rescans mods.d/.
    private func invalidateModuleCache() {
        let cachePath = (swordPath as NSString)
            .appendingPathComponent("mods.d")
            .appending("/modules-conf.cache")
        try? FileManager.default.removeItem(atPath: cachePath)
    }

    // MARK: - Install from ZIP

    /// Install a SWORD module from a local .zip file.
    /// The ZIP must contain `mods.d/*.conf` and a data directory (e.g., `modules/`).
    /// Returns the name of the installed module.
    public func installFromZip(at url: URL) throws -> String {
        let fm = FileManager.default

        // Read ZIP data
        guard let zipData = try? Data(contentsOf: url) else {
            throw ModuleRepositoryError.invalidZip("Could not read ZIP file")
        }

        // Parse ZIP entries
        let entries = try parseZip(zipData)
        guard !entries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("ZIP file is empty")
        }

        // Find .conf files in mods.d/
        let confEntries = entries.filter { entry in
            let name = entry.name.lowercased()
            return (name.hasPrefix("mods.d/") || name.contains("/mods.d/"))
                && name.hasSuffix(".conf")
        }

        guard !confEntries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("No module .conf files found in mods.d/")
        }

        var installedModuleName = ""

        for entry in entries {
            // Normalize path — remove leading "./" or module folder prefix
            var relativePath = entry.name
            if relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            // Some zips nest everything under a folder like "KJV/"
            // Detect if all paths share a common prefix that's not mods.d/ or modules/
            if relativePath.isEmpty || relativePath.hasSuffix("/") { continue }

            let destPath = (swordPath as NSString).appendingPathComponent(relativePath)
            let destDir = (destPath as NSString).deletingLastPathComponent

            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            try entry.data.write(to: URL(fileURLWithPath: destPath))

            // Track the module name from .conf filename
            if relativePath.lowercased().hasPrefix("mods.d/") && relativePath.lowercased().hasSuffix(".conf") {
                let confName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                installedModuleName = confName.uppercased()
            }
        }

        // Invalidate SWORD's module cache
        invalidateModuleCache()

        guard !installedModuleName.isEmpty else {
            throw ModuleRepositoryError.invalidZip("No module name found in .conf files")
        }

        return installedModuleName
    }

    // MARK: - ZIP Parsing

    private struct ZipEntry {
        let name: String
        let data: Data
    }

    /// Parse ZIP file data and extract all entries.
    /// Supports stored (method 0) and deflated (method 8) entries.
    private func parseZip(_ data: Data) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            // Local file header signature: 0x04034b50
            let sig = data.subdata(in: offset..<offset+4)
            guard sig == Data([0x50, 0x4b, 0x03, 0x04]) else { break }

            let method = readUInt16(data, at: offset + 8)
            let compressedSize = Int(readUInt32(data, at: offset + 18))
            let uncompressedSize = Int(readUInt32(data, at: offset + 22))
            let nameLen = Int(readUInt16(data, at: offset + 26))
            let extraLen = Int(readUInt16(data, at: offset + 28))

            let nameStart = offset + 30
            guard nameStart + nameLen <= data.count else { break }
            let name = String(data: data[nameStart..<nameStart+nameLen], encoding: .utf8) ?? ""

            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + compressedSize <= data.count else { break }
            let compressedData = data[dataStart..<dataStart+compressedSize]

            if !name.isEmpty && !name.hasSuffix("/") {
                let fileData: Data
                switch method {
                case 0: // Stored
                    fileData = Data(compressedData)
                case 8: // Deflated
                    fileData = try inflateData(Data(compressedData), uncompressedSize: uncompressedSize)
                default:
                    // Skip unsupported compression methods
                    offset = dataStart + compressedSize
                    continue
                }
                entries.append(ZipEntry(name: name, data: fileData))
            }

            offset = dataStart + compressedSize
        }

        return entries
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    /// Inflate deflated data using the C adapter's inflate_raw_data().
    private func inflateData(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        return try compressed.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw ModuleRepositoryError.decompressionFailed
            }

            var outputLen: UInt = 0
            guard let output = inflate_raw_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(compressed.count),
                UInt(uncompressedSize),
                &outputLen
            ) else {
                throw ModuleRepositoryError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLen))
        }
    }

    /// Find the source for a given module name from the catalog cache.
    public func source(for moduleName: String) -> SourceConfig? {
        for (sourceName, entries) in catalogCache {
            if entries.contains(where: { $0.name == moduleName }) {
                return loadSources().first(where: { $0.name == sourceName })
            }
        }
        return nil
    }

    // MARK: - Gzip Decompression

    private func decompressGzip(_ data: Data) throws -> Data {
        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw ModuleRepositoryError.decompressionFailed
            }

            var outputLen: UInt = 0
            guard let output = gunzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLen
            ) else {
                throw ModuleRepositoryError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLen))
        }
    }

    // MARK: - Tar Parsing

    private struct TarEntry {
        let name: String
        let data: Data
    }

    private func parseTar(_ data: Data) -> [TarEntry] {
        var entries: [TarEntry] = []
        var offset = 0

        while offset + 512 <= data.count {
            // Read 512-byte header
            let headerStart = offset
            offset += 512

            // Check for end-of-archive (zero block)
            let isZeroBlock = data[headerStart..<headerStart + 512]
                .allSatisfy { $0 == 0 }
            if isZeroBlock { break }

            // File name: bytes 0-99 (null-terminated)
            let nameBytes = data[headerStart..<headerStart + 100]
            var nameEnd = nameBytes.startIndex
            while nameEnd < nameBytes.endIndex && data[nameEnd] != 0 {
                nameEnd = data.index(after: nameEnd)
            }
            let name = String(
                bytes: data[nameBytes.startIndex..<nameEnd],
                encoding: .utf8
            ) ?? ""

            // File size: bytes 124-135 (octal ASCII, null/space terminated)
            let sizeStart = headerStart + 124
            let sizeBytes = data[sizeStart..<sizeStart + 12]
            var sizeStr = ""
            for byte in sizeBytes {
                if byte == 0 || byte == 0x20 { break }
                sizeStr.append(Character(UnicodeScalar(byte)))
            }
            let size = Int(sizeStr, radix: 8) ?? 0

            // Type flag: byte 156 ('0' or NUL = regular file)
            let typeFlag = data[headerStart + 156]
            let isFile = typeFlag == 0 || typeFlag == 0x30 // '0'

            // Extract file data
            if size > 0 && isFile && offset + size <= data.count {
                let fileData = Data(data[offset..<offset + size])
                if !name.isEmpty {
                    entries.append(TarEntry(name: name, data: fileData))
                }
            }

            // Advance past data to next 512-byte boundary
            if size > 0 {
                let dataBlocks = (size + 511) / 512
                offset += dataBlocks * 512
            }
        }

        return entries
    }

    // MARK: - .conf File Parsing

    private func parseModuleConf(_ content: String, sourceName: String) -> CatalogModule? {
        var name = ""
        var description = ""
        var categoryStr = ""
        var language = "en"
        var modDrv = ""
        var dataPath = ""
        var version = ""
        var installSize = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Section header [ModuleName]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if name.isEmpty {
                    name = String(trimmed.dropFirst().dropLast())
                }
                continue
            }

            // Skip continuation lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Key=Value
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIdx)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "Description": description = value
            case "Category": categoryStr = value
            case "Lang": language = value
            case "ModDrv": modDrv = value
            case "DataPath":
                dataPath = value
                // Strip leading ./ prefix
                if dataPath.hasPrefix("./") {
                    dataPath = String(dataPath.dropFirst(2))
                }
                // Ensure trailing slash
                if !dataPath.hasSuffix("/") {
                    dataPath += "/"
                }
            case "Version": version = value
            case "InstallSize": installSize = value
            default: break
            }
        }

        guard !name.isEmpty, !modDrv.isEmpty else { return nil }

        // Determine category
        let category: ModuleCategory
        if !categoryStr.isEmpty {
            category = ModuleCategory(typeString: categoryStr)
        } else {
            // Infer from ModDrv
            let driver = modDrv.lowercased()
            if driver.contains("text") {
                category = .bible
            } else if driver.contains("com") {
                category = .commentary
            } else if driver.contains("ld") {
                category = .dictionary
            } else if driver.contains("genbook") {
                category = .generalBook
            } else {
                category = .unknown
            }
        }

        return CatalogModule(
            name: name,
            description: description,
            category: category,
            language: language,
            modDrv: modDrv,
            dataPath: dataPath,
            confContent: content,
            sourceName: sourceName,
            version: version,
            size: installSize
        )
    }

    // MARK: - Module File Patterns

    /// Determine which files to download based on module driver type.
    private func moduleFiles(for modDrv: String, dataPath: String) -> [String] {
        let driver = modDrv.lowercased()

        switch driver {
        case "ztext", "ztext4":
            return ["ot.bzs", "ot.bzz", "ot.bzv", "nt.bzs", "nt.bzz", "nt.bzv"]
        case "rawtext", "rawtext4":
            return ["ot", "ot.vss", "nt", "nt.vss"]
        case "zcom", "zcom2", "zcom4":
            return ["ot.bzs", "ot.bzz", "ot.bzv", "nt.bzs", "nt.bzz", "nt.bzv"]
        case "rawcom", "rawcom4":
            return ["ot", "ot.vss", "nt", "nt.vss"]
        case "zld":
            let name = lastComponent(of: dataPath)
            return ["\(name).dat", "\(name).idx", "\(name).zdx", "\(name).zdt"]
        case "rawld", "rawld4":
            let name = lastComponent(of: dataPath)
            return ["\(name).dat", "\(name).idx"]
        case "rawgenbook":
            let name = lastComponent(of: dataPath)
            return ["\(name).bdt", "\(name).bks", "\(name).bky"]
        default:
            // Best effort for unknown types
            return ["ot.bzs", "ot.bzz", "ot.bzv", "nt.bzs", "nt.bzz", "nt.bzv"]
        }
    }

    /// Get the last path component, stripping trailing slashes.
    private func lastComponent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }
}

/// Errors from ModuleRepository operations.
public enum ModuleRepositoryError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case decompressionFailed
    case moduleNotFound(String)
    case installFailed(String)
    case invalidZip(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let source): return "Invalid URL for source: \(source)"
        case .downloadFailed(let msg): return msg
        case .decompressionFailed: return "Failed to decompress catalog data"
        case .moduleNotFound(let name): return "Module '\(name)' not found in catalog"
        case .installFailed(let msg): return "Installation failed: \(msg)"
        case .invalidZip(let msg): return "Invalid ZIP module: \(msg)"
        }
    }
}
