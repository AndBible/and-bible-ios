// SwordSetup.swift — SWORD module initialization at app launch

import Foundation
import SwordKit
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "SwordSetup")

/// Manages SWORD module directory setup and initialization.
enum SwordSetup {

    /**
     Ensure the writable SWORD module directories exist before creating a SwordManager.

     Android does not bundle a default Bible module; iOS follows that contract and only prepares the
     module root for user-installed or restored content.
     */
    static func ensureModulesReady() {
        let swordDir = SwordManager.defaultModulePath()
        let fm = FileManager.default

        do {
            try ModuleStoreTransactionPublisher(
                moduleRootURL: URL(fileURLWithPath: swordDir, isDirectory: true),
                fileManager: fm
            ).recoverInterruptedTransactions()
        } catch {
            preconditionFailure(
                "Unable to recover an interrupted module-store transaction: \(error.localizedDescription)"
            )
        }

        // Create required subdirectories
        let modsD = (swordDir as NSString).appendingPathComponent("mods.d")
        let modulesDir = (swordDir as NSString).appendingPathComponent("modules")
        try? fm.createDirectory(atPath: modsD, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: modulesDir, withIntermediateDirectories: true)

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
}
