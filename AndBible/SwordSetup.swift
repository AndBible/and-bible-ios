// SwordSetup.swift — SWORD module initialization at app launch

import Foundation
import SwordKit
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "SwordSetup")

/// Manages SWORD module directory setup and initialization.
enum SwordSetup {

    /**
     Ensure the SWORD modules directory exists and copy bundled modules if needed.
     Call this once at app startup before creating a SwordManager.
     */
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

        registerManuallyInstalledFonts(in: swordDir)

        logger.info("SWORD directory ready at: \(swordDir)")
    }

    /**
     Registers Android-style manually installed TTF font addons.

     Android scans `modulesDir/ttf` during app initialization and adds each TTF as an
     `AndBibleProvidesFont` addon module. iOS persists equivalent `.conf` files so the normal
     `SwordManager` scan can discover those fonts after launch.

     - Parameter swordDir: SWORD root containing `ttf` and `mods.d`.
     - Side effects: may write font addon config files and clear SWORD's module cache.
     - Failure modes: logs and continues when registration cannot complete.
     */
    private static func registerManuallyInstalledFonts(in swordDir: String) {
        do {
            let fonts = try TtfFontRepository(swordPath: swordDir).registerInstalledFonts()
            if !fonts.isEmpty {
                logger.info("Registered \(fonts.count) manually installed TTF font addon(s)")
            }
        } catch {
            logger.error("Failed to register manually installed TTF fonts: \(error.localizedDescription)")
        }
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
