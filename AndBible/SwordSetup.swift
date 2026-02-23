// SwordSetup.swift — SWORD module initialization at app launch

import Foundation
import SwordKit
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "SwordSetup")

/// Manages SWORD module directory setup and initialization.
enum SwordSetup {

    /// Ensure the SWORD modules directory exists and copy bundled modules if needed.
    /// Call this once at app startup before creating a SwordManager.
    static func ensureModulesReady() {
        let swordDir = SwordManager.defaultModulePath()
        let fm = FileManager.default

        // Create required subdirectories
        let modsD = (swordDir as NSString).appendingPathComponent("mods.d")
        let modulesDir = (swordDir as NSString).appendingPathComponent("modules")
        try? fm.createDirectory(atPath: modsD, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: modulesDir, withIntermediateDirectories: true)

        // Copy bundled modules on first launch
        copyBundledModulesIfNeeded(to: swordDir)

        logger.info("SWORD directory ready at: \(swordDir)")
    }

    private static func copyBundledModulesIfNeeded(to swordDir: String) {
        let fm = FileManager.default

        // Look for bundled sword resources
        guard let bundledSwordDir = Bundle.main.path(forResource: "sword", ofType: nil) else {
            logger.info("No bundled SWORD modules found in app bundle")
            return
        }

        // Copy mods.d config files
        let bundledModsD = (bundledSwordDir as NSString).appendingPathComponent("mods.d")
        let destModsD = (swordDir as NSString).appendingPathComponent("mods.d")

        if let confFiles = try? fm.contentsOfDirectory(atPath: bundledModsD) {
            for confFile in confFiles where confFile.hasSuffix(".conf") {
                let src = (bundledModsD as NSString).appendingPathComponent(confFile)
                let dst = (destModsD as NSString).appendingPathComponent(confFile)
                if !fm.fileExists(atPath: dst) {
                    do {
                        try fm.copyItem(atPath: src, toPath: dst)
                        logger.info("Copied module config: \(confFile)")
                    } catch {
                        logger.error("Failed to copy \(confFile): \(error)")
                    }
                }
            }
        }

        // Copy module data files
        let bundledModules = (bundledSwordDir as NSString).appendingPathComponent("modules")
        let destModules = (swordDir as NSString).appendingPathComponent("modules")

        if fm.fileExists(atPath: bundledModules) {
            copyDirectoryContents(from: bundledModules, to: destModules)
        }
    }

    private static func copyDirectoryContents(from src: String, to dst: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)

        guard let items = try? fm.contentsOfDirectory(atPath: src) else { return }
        for item in items {
            let srcPath = (src as NSString).appendingPathComponent(item)
            let dstPath = (dst as NSString).appendingPathComponent(item)

            var isDir: ObjCBool = false
            fm.fileExists(atPath: srcPath, isDirectory: &isDir)

            if isDir.boolValue {
                copyDirectoryContents(from: srcPath, to: dstPath)
            } else if !fm.fileExists(atPath: dstPath) {
                try? fm.copyItem(atPath: srcPath, toPath: dstPath)
            }
        }
    }
}
