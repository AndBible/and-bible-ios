// ModuleStoreMutationError.swift - Shared module mutation failures

import Foundation

/**
 Public failures raised by layout validation and module-store transactions.

 Errors keep unsafe input and rollback failures visible to callers; no mutation API treats a
 malformed installed config or failed filesystem operation as successful uninstall/install.
 */
public enum ModuleStoreMutationError: Error, LocalizedError, Equatable {
    case unsafeModuleName(String)
    case unsafeArchivePath(String)
    case unsafeDataPath(moduleName: String, dataPath: String)
    case canonicalPathEscape(String)
    case invalidConfiguration(String)
    case configNameMismatch(path: String, moduleName: String)
    case duplicatePath(String)
    case destinationFilesExist([String])
    /// Incoming file paths collide with live directories, symlinks, or other non-file nodes.
    case destinationTypeConflict([String])
    case duplicateModuleInitials(String)
    case missingConfiguration
    case missingPayload(String)
    case unownedPayload(String)
    case overlappingPayloadOwnership(String)
    case overlappingModuleTargets(String)
    case installedOwnershipConflict(moduleName: String, owner: String)
    case moduleNotFound(String)
    case stagedFileMissing(String)
    case rollbackFailed(original: String, failures: [String])

    /// Localized diagnostic suitable for import/download error presentation.
    public var errorDescription: String? {
        switch self {
        case .unsafeModuleName(let name):
            return "Unsafe module name: \(name)"
        case .unsafeArchivePath(let path):
            return "Unsafe module archive path: \(path)"
        case .unsafeDataPath(let moduleName, let dataPath):
            return "\(moduleName) has unsafe DataPath \(dataPath)."
        case .canonicalPathEscape(let path):
            return "Module path escapes the canonical module store: \(path)"
        case .invalidConfiguration(let path):
            return "Invalid SWORD module configuration: \(path)"
        case .configNameMismatch(let path, let moduleName):
            return "Configuration \(path) does not belong to module \(moduleName)."
        case .duplicatePath(let path):
            return "Duplicate module archive path: \(path)"
        case .destinationFilesExist(let paths):
            return "Module files already exist: \(paths.joined(separator: ", "))"
        case .destinationTypeConflict(let paths):
            return "Module file destinations are not replaceable regular files: \(paths.joined(separator: ", "))"
        case .duplicateModuleInitials(let name):
            return "Duplicate module initials: \(name)"
        case .missingConfiguration:
            return "No module configuration was found."
        case .missingPayload(let moduleName):
            return "No staged payload belongs to module \(moduleName)."
        case .unownedPayload(let path):
            return "Staged payload is not owned by a module configuration: \(path)"
        case .overlappingPayloadOwnership(let path):
            return "Staged payload is claimed by multiple modules: \(path)"
        case .overlappingModuleTargets(let moduleName):
            return "Module \(moduleName) shares a payload target with another staged module."
        case .installedOwnershipConflict(let moduleName, let owner):
            return "Cannot mutate \(moduleName) because its payload is also owned by \(owner)."
        case .moduleNotFound(let moduleName):
            return "Module '\(moduleName)' is not installed."
        case .stagedFileMissing(let path):
            return "Staged module file is missing or unsafe: \(path)"
        case .rollbackFailed(let original, let failures):
            return "Module transaction failed (\(original)); rollback also failed: \(failures.joined(separator: "; "))"
        }
    }
}
