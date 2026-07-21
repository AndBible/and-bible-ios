import Foundation
import XCTest
@testable import SwordKit

/**
 Transaction, replacement, uninstall, rollback, and concurrency coverage for module storage.

 Race tests use coordinator checkpoints and semaphores as explicit barriers. No assertion depends
 on sleeps or scheduler timing: the first writer owns the lease at `.willMutate`, and the second
 writer must emit `.waiting` before the test releases the first.
 */
final class ModuleStoreTransactionTests: XCTestCase {
    /**
     Verifies two remote writers targeting the same initials serialize and the FIFO successor wins.

     Failure means package publication can interleave payload/config writes or separate publisher
     instances do not share the canonical-root coordinator.
     */
    func testRemoteVersusRemoteSameInitialsSerializesDeterministically() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let first = try makeStagedInstall(
            context: context,
            name: "RACE",
            dataPath: "./modules/texts/rawtext/race/",
            payloadPath: "modules/texts/rawtext/race/ot",
            marker: "remote-first"
        )
        let second = try makeStagedInstall(
            context: context,
            name: "RACE",
            dataPath: "./modules/texts/rawtext/race/",
            payloadPath: "modules/texts/rawtext/race/ot",
            marker: "remote-second"
        )

        try await assertSerialized(
            root: context.root,
            firstKind: .remoteSword,
            secondKind: .remoteSword,
            first: { try context.firstPublisher.publishStagedInstall(
                first.plan,
                from: first.stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword
            ) },
            second: { try context.secondPublisher.publishStagedInstall(
                second.plan,
                from: second.stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword
            ) }
        )

        XCTAssertEqual(try payloadString(context.root, second.payloadPath), "remote-second")
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies remote and local SWORD writers share the same lease and publish in FIFO order.

     Failure means local file import can bypass an active package commit and leave a mixed module.
     */
    func testRemoteVersusLocalSerializesDeterministically() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let remote = try makeStagedInstall(
            context: context,
            name: "RACE",
            dataPath: "./modules/texts/rawtext/race/",
            payloadPath: "modules/texts/rawtext/race/ot",
            marker: "remote"
        )
        let local = try makeStagedInstall(
            context: context,
            name: "RACE",
            dataPath: "./modules/texts/rawtext/race/",
            payloadPath: "modules/texts/rawtext/race/ot",
            marker: "local"
        )

        try await assertSerialized(
            root: context.root,
            firstKind: .remoteSword,
            secondKind: .localSwordZip,
            first: { try context.firstPublisher.publishStagedInstall(
                remote.plan,
                from: remote.stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword
            ) },
            second: { try context.secondPublisher.publishStagedInstall(
                local.plan,
                from: local.stagingRoot,
                allowOverwrite: true,
                kind: .localSwordZip
            ) }
        )

        XCTAssertEqual(try payloadString(context.root, local.payloadPath), "local")
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies remote install and uninstall cannot mutate the same module concurrently.

     Failure means uninstall can delete a partially published package or install can resurrect a
     row after uninstall reports success.
     */
    func testRemoteVersusUninstallSerializesDeterministically() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let remote = try makeStagedInstall(
            context: context,
            name: "RACE",
            dataPath: "./modules/texts/rawtext/race/",
            payloadPath: "modules/texts/rawtext/race/ot",
            marker: "remote"
        )

        try await assertSerialized(
            root: context.root,
            firstKind: .remoteSword,
            secondKind: .uninstall,
            first: { try context.firstPublisher.publishStagedInstall(
                remote.plan,
                from: remote.stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword
            ) },
            second: { try context.secondPublisher.uninstall(moduleName: "RACE") }
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/race.conf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("modules/texts/rawtext/race").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies local ZIP install and uninstall use the same process-wide transaction boundary.

     Failure means Files import can race a Downloads uninstall despite using distinct service
     instances.
     */
    func testLocalVersusUninstallSerializesDeterministically() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let local = try makeStagedInstall(
            context: context,
            name: "RACE",
            dataPath: "./modules/texts/rawtext/race/",
            payloadPath: "modules/texts/rawtext/race/ot",
            marker: "local"
        )

        try await assertSerialized(
            root: context.root,
            firstKind: .localSwordZip,
            secondKind: .uninstall,
            first: { try context.firstPublisher.publishStagedInstall(
                local.plan,
                from: local.stagingRoot,
                allowOverwrite: true,
                kind: .localSwordZip
            ) },
            second: { try context.secondPublisher.uninstall(moduleName: "RACE") }
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/race.conf").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies MyBible publication and uninstall are serialized with the SWORD writer family.

     Failure means the custom-driver sidecar path remains a process-wide mutation bypass.
     */
    func testMyBibleVersusUninstallSerializesDeterministically() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let staging = context.parent.appendingPathComponent("mybible-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staging.appendingPathComponent("module.json"))
        try Data("sqlite".utf8).write(to: staging.appendingPathComponent("race.SQLite3"))

        try await assertSerialized(
            root: context.root,
            firstKind: .remoteMyBible,
            secondKind: .uninstall,
            first: { try context.firstPublisher.publishStagedMyBibleInstall(
                from: staging,
                moduleName: "RACE"
            ) },
            second: { try context.secondPublisher.uninstall(moduleName: "RACE") }
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mybible/RACE").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /** Verifies TTF addon publication shares the SWORD writer's canonical-root lease. */
    func testRemoteVersusTtfAddonSerializesDeterministically() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let remote = try makeStagedInstall(
            context: context,
            name: "RACE",
            dataPath: "./modules/texts/rawtext/race/",
            payloadPath: "modules/texts/rawtext/race/ot",
            marker: "remote"
        )
        let fontSource = context.parent.appendingPathComponent("Source.ttf")
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: fontSource)
        let fontRepository = TtfFontRepository(swordPath: context.root.path)

        try await assertSerialized(
            root: context.root,
            firstKind: .remoteSword,
            secondKind: .ttfAddon,
            first: { try context.firstPublisher.publishStagedInstall(
                remote.plan,
                from: remote.stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword
            ) },
            second: {
                _ = try fontRepository.installFont(from: fontSource, displayName: "Shared.ttf")
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("ttf/Shared.ttf").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/ttf_shared.conf").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies independent `ModuleRepository` instances share the root coordinator for uninstalls.

     - Setup: Installs two Bibles, holds the first repository at the deterministic mutation boundary,
       then queues removal of the second through an independently constructed repository.
     - Expected result: The first removal commits; the queued call reloads inventory under the same
       lease, rejects removal of the survivor, and never reaches `.willMutate`.
     - Side effects: Creates and removes a temporary SWORD root and installs a scoped coordinator
       observer; the gate controls ordering without sleeps.
     - Failure meaning: Repository-scoped locks or an out-of-lease inventory check can let two
       concurrent callers both approve removal of the final Bible.
     */
    func testIndependentModuleRepositoryInstancesShareMutationCoordinator() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        try writeInstalledModule(
            root: context.root,
            name: "ONE",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/one/",
            payloadPath: "modules/texts/rawtext/one/ot",
            marker: "one"
        )
        try writeInstalledModule(
            root: context.root,
            name: "TWO",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/two/",
            payloadPath: "modules/texts/rawtext/two/ot",
            marker: "two"
        )
        let firstRepository = ModuleRepository(
            basePath: context.parent.appendingPathComponent("repo-one").path,
            swordPath: context.root.path
        )
        let secondRepository = ModuleRepository(
            basePath: context.parent.appendingPathComponent("repo-two").path,
            swordPath: context.root.path
        )

        let gate = ModuleStoreTransactionGate()
        let observation = ModuleStoreMutationCoordinator.observeTransactions(
            forModuleRoot: context.root,
            observer: { event in gate.observe(event) }
        )
        defer { observation.cancel() }
        let firstTask = Task.detached {
            try firstRepository.uninstallModule(named: "ONE")
        }
        try gate.waitForFirstMutationBoundary()
        let secondTask = Task.detached { () -> Bool in
            do {
                try secondRepository.uninstallModule(named: "TWO")
                return false
            } catch ModuleRepositoryError.lastInstalledBible {
                return true
            } catch {
                return false
            }
        }
        try gate.waitForSecondWriterToQueue()
        gate.releaseFirstWriter()
        try await firstTask.value
        let didRejectSecondRemoval = await secondTask.value
        XCTAssertTrue(didRejectSecondRemoval)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/one.conf").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/two.conf").path
        ))
        let secondID = try XCTUnwrap(gate.secondTransactionID)
        XCTAssertFalse(gate.events.contains {
            $0.transactionID == secondID && $0.stage == .willMutate
        })
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies the repository service rejects direct removal of the only installed Bible.

     - Setup: Writes one manager-readable RawText Bible and calls the repository API directly,
       bypassing all UI action planning.
     - Expected result: The service returns `lastInstalledBible` before mutation and preserves the
       config, payload, and clean transaction root.
     - Side effects: Creates one installed RawText fixture and attempts transactional removal.
     - Failure meaning: Non-UI callers can bypass Android's last-Bible invariant or a rejected
       removal can still delete config/payload files.
     */
    func testRepositoryDirectCallCannotRemoveOnlyInstalledBible() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        try writeInstalledModule(
            root: context.root,
            name: "ONLY",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/only/",
            payloadPath: "modules/texts/rawtext/only/ot",
            marker: "only"
        )
        let repository = ModuleRepository(
            basePath: context.parent.appendingPathComponent("repo").path,
            swordPath: context.root.path
        )

        XCTAssertThrowsError(try repository.uninstallModule(named: "ONLY")) { error in
            guard case ModuleRepositoryError.lastInstalledBible("ONLY") = error else {
                return XCTFail("Expected lastInstalledBible, received \(error).")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/only.conf").path
        ))
        XCTAssertEqual(
            try payloadString(context.root, "modules/texts/rawtext/only/ot"),
            "only"
        )
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies one of two installed Bibles can be removed and the remaining Bible becomes protected.

     - Setup: Writes two manager-readable RawText Bibles and removes them sequentially through one
       repository instance.
     - Expected result: The first removal succeeds; the second fails before deleting the survivor.
     - Side effects: Creates two RawText fixtures and invokes the repository service twice.
     - Failure meaning: The invariant is either too strict for ordinary deletion or is not rechecked
       from current inventory after a successful mutation.
     */
    func testRepositoryAllowsOneOfTwoBiblesThenProtectsRemainingBible() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        for (name, marker) in [("ONE", "one"), ("TWO", "two")] {
            try writeInstalledModule(
                root: context.root,
                name: name,
                driver: "RawText",
                dataPath: "./modules/texts/rawtext/\(name.lowercased())/",
                payloadPath: "modules/texts/rawtext/\(name.lowercased())/ot",
                marker: marker
            )
        }
        let repository = ModuleRepository(
            basePath: context.parent.appendingPathComponent("repo").path,
            swordPath: context.root.path
        )

        try repository.uninstallModule(named: "ONE")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/one.conf").path
        ))
        XCTAssertThrowsError(try repository.uninstallModule(named: "TWO")) { error in
            guard case ModuleRepositoryError.lastInstalledBible("TWO") = error else {
                return XCTFail("Expected lastInstalledBible, received \(error).")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/two.conf").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies cancellation while queued for the lease aborts without staging publication.

     Failure means a cancelled Downloads row can later publish after another writer releases the
     root, or can clear UI state without a typed terminal cancellation event.
     */
    func testCancellationWhileWaitingAbortsBeforeMutation() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let first = try makeStagedInstall(
            context: context,
            name: "FIRST",
            dataPath: "./modules/texts/rawtext/first/",
            payloadPath: "modules/texts/rawtext/first/ot",
            marker: "first"
        )
        let waiting = try makeStagedInstall(
            context: context,
            name: "WAITING",
            dataPath: "./modules/texts/rawtext/waiting/",
            payloadPath: "modules/texts/rawtext/waiting/ot",
            marker: "waiting"
        )
        let gate = ModuleStoreTransactionGate()
        let observation = ModuleStoreMutationCoordinator.observeTransactions(
            forModuleRoot: context.root,
            observer: { event in gate.observe(event) }
        )
        defer { observation.cancel() }

        let firstTask = Task.detached {
            try context.firstPublisher.publishStagedInstall(
                first.plan,
                from: first.stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword
            )
        }
        try gate.waitForFirstMutationBoundary()
        let waitingTask = Task.detached {
            try context.secondPublisher.publishStagedInstall(
                waiting.plan,
                from: waiting.stagingRoot,
                allowOverwrite: true,
                kind: .localSwordZip
            )
        }
        try gate.waitForSecondWriterToQueue()
        waitingTask.cancel()
        try gate.waitForSecondWriterCancellation()
        gate.releaseFirstWriter()

        try await firstTask.value
        do {
            try await waitingTask.value
            XCTFail("Expected queued transaction cancellation.")
        } catch is CancellationError {
            // Expected typed cancellation before mutation.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/waiting.conf").path
        ))
    }

    /**
     Verifies cancellation after `.willMutate` cannot turn a successful commit into cancellation.

     Failure means Downloads can clear a row as cancelled while payload/config publication is still
     active, recreating the false terminal state this contract prevents.
     */
    func testCancellationAfterCommitBoundaryReportsActualSuccess() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let fixture = try makeStagedInstall(
            context: context,
            name: "COMMIT",
            dataPath: "./modules/texts/rawtext/commit/",
            payloadPath: "modules/texts/rawtext/commit/ot",
            marker: "committed"
        )
        let gate = ModuleStoreTransactionGate()
        let observation = ModuleStoreMutationCoordinator.observeTransactions(
            forModuleRoot: context.root,
            observer: { event in gate.observe(event) }
        )
        defer { observation.cancel() }
        let commitStarted = ModuleStoreLockedFlag()
        let task = Task.detached {
            try context.firstPublisher.publishStagedInstall(
                fixture.plan,
                from: fixture.stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword,
                onCommitStarted: { commitStarted.set() }
            )
        }

        try gate.waitForFirstMutationBoundary()
        task.cancel()
        gate.releaseFirstWriter()
        try await task.value

        XCTAssertTrue(commitStarted.value)
        XCTAssertEqual(try payloadString(context.root, fixture.payloadPath), "committed")
        XCTAssertFalse(ModuleInstallProgress(phase: .committing).isCancellable)
        XCTAssertTrue(ModuleInstallProgress(phase: .extracting, fraction: 1).isCancellable)
    }

    /**
     Verifies same-initials replacement removes obsolete old payload and displaced new target data.

     Failure means changing `DataPath` can orphan the prior module or merge unrelated destination
     files into the replacement.
     */
    func testChangedPathReplacementCleansOldAndDisplacedTargets() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        try writeInstalledModule(
            root: context.root,
            name: "MOVE",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/oldmove/",
            payloadPath: "modules/texts/rawtext/oldmove/ot",
            marker: "old"
        )
        let displacedURL = context.root.appendingPathComponent("modules/texts/rawtext/newmove/extra")
        try FileManager.default.createDirectory(
            at: displacedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("displaced".utf8).write(to: displacedURL)
        let replacement = try makeStagedInstall(
            context: context,
            name: "MOVE",
            dataPath: "./modules/texts/rawtext/newmove/",
            payloadPath: "modules/texts/rawtext/newmove/ot",
            marker: "new"
        )

        try context.firstPublisher.publishStagedInstall(
            replacement.plan,
            from: replacement.stagingRoot,
            allowOverwrite: true,
            kind: .localSwordZip
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("modules/texts/rawtext/oldmove").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: displacedURL.path))
        XCTAssertEqual(try payloadString(context.root, replacement.payloadPath), "new")
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies replacement handles a driver change from directory ownership to filename-prefix.

     Failure means changing `ModDrv` can preserve stale directory data or delete prefix siblings.
     */
    func testChangedDriverReplacementUsesNewOwnershipShape() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        try writeInstalledModule(
            root: context.root,
            name: "CHANGE",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/change/",
            payloadPath: "modules/texts/rawtext/change/ot",
            marker: "old"
        )
        let replacement = try makeStagedInstall(
            context: context,
            name: "CHANGE",
            driver: "RawLD4",
            dataPath: "./modules/lexdict/rawld4/change/change",
            payloadPath: "modules/lexdict/rawld4/change/change.dat",
            marker: "new-prefix"
        )

        try context.firstPublisher.publishStagedInstall(
            replacement.plan,
            from: replacement.stagingRoot,
            allowOverwrite: true,
            kind: .remoteSword
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("modules/texts/rawtext/change").path
        ))
        XCTAssertEqual(try payloadString(context.root, replacement.payloadPath), "new-prefix")
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies a config-copy failure restores old config/payload and leaves no transaction residue.

     Failure means payload-first/config-last publication is not fully reversible.
     */
    func testPublishFailureRollsBackOldFilesAndRemovesBackupResidue() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        try writeInstalledModule(
            root: context.root,
            name: "ROLL",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/roll/",
            payloadPath: "modules/texts/rawtext/roll/ot",
            marker: "old"
        )
        let faultManager = ModuleStoreConfigCopyFaultFileManager(failingConfigName: "roll.conf")
        let publisher = ModuleStoreTransactionPublisher(
            moduleRootURL: context.root,
            fileManager: faultManager
        )
        let replacement = try makeStagedInstall(
            context: context,
            publisher: publisher,
            name: "ROLL",
            dataPath: "./modules/texts/rawtext/roll/",
            payloadPath: "modules/texts/rawtext/roll/ot",
            marker: "new"
        )

        XCTAssertThrowsError(try publisher.publishStagedInstall(
            replacement.plan,
            from: replacement.stagingRoot,
            allowOverwrite: true,
            kind: .localSwordZip
        ))
        XCTAssertEqual(try payloadString(context.root, replacement.payloadPath), "old")
        XCTAssertTrue(try String(
            contentsOf: context.root.appendingPathComponent("mods.d/roll.conf"),
            encoding: .utf8
        ).contains("DataPath=./modules/texts/rawtext/roll/"))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies prefix-driver uninstall deletes only matching files and preserves sibling ownership.

     Failure means RawLD/RawLD4 uninstall can remove a shared containing directory.
     */
    func testPrefixDriverUninstallPreservesSiblingModuleFiles() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        try writeInstalledModule(
            root: context.root,
            name: "STRONGS",
            driver: "RawLD4",
            dataPath: "./modules/lexdict/rawld4/shared/strongs",
            payloadPath: "modules/lexdict/rawld4/shared/strongs.dat",
            marker: "strongs"
        )
        try writeInstalledModule(
            root: context.root,
            name: "OTHER",
            driver: "RawLD4",
            dataPath: "./modules/lexdict/rawld4/shared/other",
            payloadPath: "modules/lexdict/rawld4/shared/other.dat",
            marker: "other"
        )
        try Data("index".utf8).write(
            to: context.root.appendingPathComponent("modules/lexdict/rawld4/shared/strongs.idx")
        )
        let matchingDirectory = context.root
            .appendingPathComponent("modules/lexdict/rawld4/shared/strongs-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: matchingDirectory, withIntermediateDirectories: true)
        let matchingSymlink = context.root
            .appendingPathComponent("modules/lexdict/rawld4/shared/strongs-alias")
        try FileManager.default.createSymbolicLink(
            at: matchingSymlink,
            withDestinationURL: context.root
                .appendingPathComponent("modules/lexdict/rawld4/shared/other.dat")
        )

        try context.firstPublisher.uninstall(moduleName: "STRONGS")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("modules/lexdict/rawld4/shared/strongs.dat").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("modules/lexdict/rawld4/shared/strongs.idx").path
        ))
        XCTAssertEqual(
            try payloadString(context.root, "modules/lexdict/rawld4/shared/other.dat"),
            "other"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/other.conf").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: matchingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: matchingSymlink.path))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies uninstall fails closed for unsafe legacy configs and shared installed targets.

     Failure means malformed `DataPath` can escape the root or one module can delete data still
     claimed by another installed config.
     */
    func testUninstallRejectsUnsafeLegacyAndSharedOwnership() throws {
        let unsafeContext = try makeContext()
        defer { try? FileManager.default.removeItem(at: unsafeContext.parent) }
        try configData(
            name: "BAD",
            driver: "RawText",
            dataPath: "../outside"
        ).write(to: unsafeContext.root.appendingPathComponent("mods.d/bad.conf"))
        XCTAssertThrowsError(try unsafeContext.firstPublisher.uninstall(moduleName: "BAD")) { error in
            guard case ModuleStoreMutationError.unsafeDataPath = error else {
                return XCTFail("Expected unsafe legacy config failure, received \(error)")
            }
        }

        let sharedContext = try makeContext()
        defer { try? FileManager.default.removeItem(at: sharedContext.parent) }
        try writeInstalledModule(
            root: sharedContext.root,
            name: "ONE",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/shared/",
            payloadPath: "modules/texts/rawtext/shared/ot",
            marker: "shared"
        )
        try configData(
            name: "TWO",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/shared/"
        ).write(to: sharedContext.root.appendingPathComponent("mods.d/two.conf"))

        XCTAssertThrowsError(try sharedContext.firstPublisher.uninstall(moduleName: "ONE")) { error in
            guard case ModuleStoreMutationError.installedOwnershipConflict = error else {
                return XCTFail("Expected shared ownership failure, received \(error)")
            }
        }
        XCTAssertEqual(
            try payloadString(sharedContext.root, "modules/texts/rawtext/shared/ot"),
            "shared"
        )
    }

    /** Verifies missing and malformed installed modules fail visibly without deleting live files. */
    func testUninstallReportsMissingAndMalformedModules() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }

        XCTAssertThrowsError(try context.firstPublisher.uninstall(moduleName: "MISSING")) { error in
            XCTAssertEqual(error as? ModuleStoreMutationError, .moduleNotFound("MISSING"))
        }

        let malformedModuleURL = context.root.appendingPathComponent(
            "mybible/BROKEN",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: malformedModuleURL, withIntermediateDirectories: true)
        let payloadURL = malformedModuleURL.appendingPathComponent("broken.SQLite3")
        try Data("payload".utf8).write(to: payloadURL)

        XCTAssertThrowsError(try context.firstPublisher.uninstall(moduleName: "BROKEN")) { error in
            guard case ModuleStoreMutationError.invalidConfiguration = error else {
                return XCTFail("Expected malformed MyBible failure, received \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: payloadURL, encoding: .utf8), "payload")
        try assertNoTransactionBackups(in: context.root)
    }

    /** Verifies a public uninstall filesystem error restores config and payload before escaping. */
    func testUninstallFilesystemFailureRollsBackWithoutBackupResidue() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        try writeInstalledModule(
            root: context.root,
            name: "ROLLBACK",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/rollback/",
            payloadPath: "modules/texts/rawtext/rollback/ot",
            marker: "installed"
        )
        let publisher = ModuleStoreTransactionPublisher(
            moduleRootURL: context.root,
            fileManager: ModuleStoreBackupCleanupFaultFileManager()
        )

        XCTAssertThrowsError(try publisher.uninstall(moduleName: "ROLLBACK")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, CocoaError.fileWriteNoPermission.rawValue)
        }
        XCTAssertEqual(
            try payloadString(context.root, "modules/texts/rawtext/rollback/ot"),
            "installed"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/rollback.conf").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Exact overlay authorization never permits replacing a directory with an incoming file.

     The fixture authorizes the exact live payload path to prove the lease-held type check is
     independent of overwrite consent. The publisher must throw `destinationTypeConflict` before
     its commit callback, preserve the directory's child, leave the config absent, and create no
     transaction backup. Failure means a destination can change type after UI preflight and still
     be recursively displaced during commit.

     The test mutates only its isolated module root and removes that root on exit.
     */
    func testOverlayRejectsAuthorizedDirectoryDestinationBeforeCommit() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let fixture = try makeStagedInstall(
            context: context,
            name: "TYPECONFLICT",
            dataPath: "./modules/texts/rawtext/typeconflict/",
            payloadPath: "modules/texts/rawtext/typeconflict/ot",
            marker: "incoming"
        )
        let destinationURL = context.root.appendingPathComponent(fixture.payloadPath)
        let sentinelURL = destinationURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try Data("existing-child".utf8).write(to: sentinelURL)
        let commitStarted = ModuleStoreLockedFlag()

        XCTAssertThrowsError(try context.firstPublisher.publishStagedOverlay(
            fixture.plan,
            from: fixture.stagingRoot,
            authorizedExistingPaths: [fixture.payloadPath],
            kind: .localSwordZip,
            onCommitStarted: { commitStarted.set() }
        )) { error in
            guard case let ModuleStoreMutationError.destinationTypeConflict(paths) = error else {
                return XCTFail("Expected destinationTypeConflict, received \(error)")
            }
            XCTAssertEqual(paths, [fixture.payloadPath])
        }
        XCTAssertFalse(commitStarted.value)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("existing-child".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/typeconflict.conf").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies mixed Android backup roots publish content before their activation pointer.

     The file-manager probe rejects the activation move unless the replacement database is already
     visible, so a passing test proves ordering rather than merely asserting the final snapshot. The
     transaction must replace only authorized exact files, preserve an unrelated sibling, invalidate
     the SWORD cache, and remove both backup and recovery-journal residue.

     The test creates only isolated temporary files and removes the parent directory on exit.
     Failure means a non-SWORD backup family can become discoverable before its data is complete or
     the generic overlay does not retain the established transaction cleanup guarantees.
     */
    func testExactOverlayPublishesMixedRootsBeforeActivation() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let contentPath = "mybible/KJV.sqlite3"
        let activationPath = "document-catalog/KJV.json"
        let contentURL = context.root.appendingPathComponent(contentPath)
        let activationURL = context.root.appendingPathComponent(activationPath)
        let siblingURL = context.root.appendingPathComponent("mybible/Keep.sqlite3")
        for url in [contentURL, activationURL, siblingURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("old-database".utf8).write(to: contentURL)
        try Data("old-catalog".utf8).write(to: activationURL)
        try Data("preserved".utf8).write(to: siblingURL)
        let cacheURL = context.root.appendingPathComponent("mods.d/modules-conf.cache")
        try Data("stale-cache".utf8).write(to: cacheURL)

        let stagingRoot = context.parent.appendingPathComponent("mixed-staging", isDirectory: true)
        for relativePath in [contentPath, activationPath] {
            let url = stagingRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("new-database".utf8).write(to: stagingRoot.appendingPathComponent(contentPath))
        try Data("new-catalog".utf8).write(to: stagingRoot.appendingPathComponent(activationPath))
        let fileManager = ModuleStoreActivationOrderFileManager(
            requiredContentURL: contentURL,
            expectedContent: Data("new-database".utf8),
            activationURL: activationURL
        )
        let publisher = ModuleStoreTransactionPublisher(
            moduleRootURL: context.root,
            fileManager: fileManager
        )

        try publisher.publishExactOverlay(
            ModuleStoreExactOverlayManifest(
                contentRelativePaths: [contentPath],
                activationRelativePaths: [activationPath]
            ),
            from: stagingRoot,
            authorizedExistingPaths: [contentPath, activationPath],
            kind: .androidModuleBackup
        )

        XCTAssertEqual(try Data(contentsOf: contentURL), Data("new-database".utf8))
        XCTAssertEqual(try Data(contentsOf: activationURL), Data("new-catalog".utf8))
        XCTAssertEqual(try Data(contentsOf: siblingURL), Data("preserved".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent(".module-recovery").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies failed post-publish registration is part of the exact-overlay transaction.

     Existing content and activation files are replaced before the validator throws. The publisher
     must call the external registration inverse exactly once, restore both old files, remove the
     stale module cache, skip completion, and discard all durable transaction residue. Failure means
     restore can report an error while leaving unavailable or mixed-family bytes live.
     */
    func testExactOverlayRegistrationFailureRestoresFilesAndExternalState() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let contentPath = "mybible/Book.SQLite3"
        let activationPath = "mods.d/generated.conf"
        let contentURL = context.root.appendingPathComponent(contentPath)
        let activationURL = context.root.appendingPathComponent(activationPath)
        for url in [contentURL, activationURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("old-content".utf8).write(to: contentURL)
        try Data("old-activation".utf8).write(to: activationURL)
        let cacheURL = context.root.appendingPathComponent("mods.d/modules-conf.cache")
        try Data("stale".utf8).write(to: cacheURL)

        let stagingRoot = context.parent.appendingPathComponent(
            "registration-failure-staging",
            isDirectory: true
        )
        for (path, value) in [
            (contentPath, "new-content"),
            (activationPath, "new-activation"),
        ] {
            let url = stagingRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: url)
        }
        var callbackEvents: [String] = []

        XCTAssertThrowsError(try context.firstPublisher.publishExactOverlay(
            ModuleStoreExactOverlayManifest(
                contentRelativePaths: [contentPath],
                activationRelativePaths: [activationPath]
            ),
            from: stagingRoot,
            authorizedExistingPaths: [contentPath, activationPath],
            kind: .androidModuleBackup,
            validatePublishedState: {
                callbackEvents.append("validate")
                XCTAssertEqual(try Data(contentsOf: contentURL), Data("new-content".utf8))
                XCTAssertEqual(try Data(contentsOf: activationURL), Data("new-activation".utf8))
                throw ModuleStoreTransactionTestError.registrationRejected
            },
            rollbackPublishedState: {
                callbackEvents.append("rollback")
            },
            completePublishedState: {
                callbackEvents.append("complete")
            }
        )) { error in
            guard case ModuleStoreTransactionTestError.registrationRejected = error else {
                return XCTFail("Expected registration rejection, received \(error)")
            }
        }

        XCTAssertEqual(callbackEvents, ["validate", "rollback"])
        XCTAssertEqual(try Data(contentsOf: contentURL), Data("old-content".utf8))
        XCTAssertEqual(try Data(contentsOf: activationURL), Data("old-activation".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent(".module-recovery").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies generic overlay validation rejects transaction metadata and unapproved replacement.

     Both calls must fail before the commit callback: a staged journal path cannot overwrite crash
     recovery state, and an ordinary existing file cannot be displaced without exact authorization.
     The live file remains byte-identical and no transaction storage is created.
     */
    func testExactOverlayRejectsReservedAndUnapprovedDestinationsBeforeCommit() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let stagingRoot = context.parent.appendingPathComponent("validation-staging", isDirectory: true)
        let reservedPath = ".module-recovery/forged.json"
        let ordinaryPath = "epub/book/content.xhtml"
        for relativePath in [reservedPath, ordinaryPath] {
            let url = stagingRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("incoming".utf8).write(to: url)
        }
        let existingURL = context.root.appendingPathComponent(ordinaryPath)
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(to: existingURL)
        let commitStarted = ModuleStoreLockedFlag()

        XCTAssertThrowsError(try context.firstPublisher.publishExactOverlay(
            ModuleStoreExactOverlayManifest(
                contentRelativePaths: [reservedPath],
                activationRelativePaths: []
            ),
            from: stagingRoot,
            authorizedExistingPaths: [],
            kind: .androidModuleBackup,
            onCommitStarted: { commitStarted.set() }
        )) { error in
            XCTAssertEqual(error as? ModuleStoreMutationError, .unsafeArchivePath(reservedPath))
        }
        XCTAssertThrowsError(try context.firstPublisher.publishExactOverlay(
            ModuleStoreExactOverlayManifest(
                contentRelativePaths: [ordinaryPath],
                activationRelativePaths: []
            ),
            from: stagingRoot,
            authorizedExistingPaths: [],
            kind: .androidModuleBackup,
            onCommitStarted: { commitStarted.set() }
        )) { error in
            guard case let ModuleStoreMutationError.destinationFilesExist(paths) = error else {
                return XCTFail("Expected destinationFilesExist, received \(error)")
            }
            XCTAssertEqual(paths, [ordinaryPath])
        }
        XCTAssertFalse(commitStarted.value)
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("existing".utf8))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies no-overwrite publication rejects every existing path owned by the incoming layout.

     Exact staged filenames are insufficient: directory drivers own the complete target subtree,
     while prefix drivers own matching sibling files even when those names are absent from the ZIP.
     */
    func testNoOverwriteRejectsExistingDirectoryAndPrefixOwnedPayload() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.parent) }
        let directoryFixture = try makeStagedInstall(
            context: context,
            name: "DIRCONFLICT",
            dataPath: "./modules/texts/rawtext/dirconflict/",
            payloadPath: "modules/texts/rawtext/dirconflict/ot",
            marker: "incoming-directory"
        )
        let existingDirectoryFile = context.root.appendingPathComponent(
            "modules/texts/rawtext/dirconflict/legacy"
        )
        try FileManager.default.createDirectory(
            at: existingDirectoryFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing-directory".utf8).write(to: existingDirectoryFile)

        XCTAssertThrowsError(try context.firstPublisher.publishStagedInstall(
            directoryFixture.plan,
            from: directoryFixture.stagingRoot,
            allowOverwrite: false,
            kind: .localSwordZip
        )) { error in
            guard case let ModuleStoreMutationError.destinationFilesExist(paths) = error else {
                return XCTFail("Expected directory conflict, received \(error)")
            }
            XCTAssertTrue(paths.contains("modules/texts/rawtext/dirconflict"))
        }
        XCTAssertEqual(try String(contentsOf: existingDirectoryFile, encoding: .utf8), "existing-directory")

        let prefixFixture = try makeStagedInstall(
            context: context,
            name: "PREFIXCONFLICT",
            driver: "RawLD4",
            dataPath: "./modules/lexdict/rawld/prefixconflict/dict",
            payloadPath: "modules/lexdict/rawld/prefixconflict/dict.dat",
            marker: "incoming-prefix"
        )
        let existingPrefixFile = context.root.appendingPathComponent(
            "modules/lexdict/rawld/prefixconflict/dict.idx"
        )
        try FileManager.default.createDirectory(
            at: existingPrefixFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing-prefix".utf8).write(to: existingPrefixFile)

        XCTAssertThrowsError(try context.firstPublisher.publishStagedInstall(
            prefixFixture.plan,
            from: prefixFixture.stagingRoot,
            allowOverwrite: false,
            kind: .localSwordZip
        )) { error in
            guard case let ModuleStoreMutationError.destinationFilesExist(paths) = error else {
                return XCTFail("Expected prefix conflict, received \(error)")
            }
            XCTAssertTrue(paths.contains("modules/lexdict/rawld/prefixconflict/dict.idx"))
        }
        XCTAssertEqual(try String(contentsOf: existingPrefixFile, encoding: .utf8), "existing-prefix")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/dirconflict.conf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent("mods.d/prefixconflict.conf").path
        ))
        try assertNoTransactionBackups(in: context.root)
    }

    /**
     Verifies the former `InstallManager` and `DownloadService` public mutation APIs stay absent.

     This source-level guard is intentional: compilation cannot assert that an API does not exist.
     Failure means a future wrapper reintroduces a live-tree path outside the transaction publisher.
     */
    func testLegacyMutationBypassAPIsRemainAbsent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let installManagerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SwordKit/Sources/SwordKit/InstallManager.swift"
            ),
            encoding: .utf8
        )
        let downloadServiceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/BibleCore/Sources/BibleCore/Services/DownloadService.swift"
            ),
            encoding: .utf8
        )
        let flatAPISource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SwordKit/CLibSword/include/flatapi.h"
            ),
            encoding: .utf8
        )
        let swordAdapterSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SwordKit/CLibSword/sword_adapter.c"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(installManagerSource.contains("public func install(moduleName:"))
        XCTAssertFalse(installManagerSource.contains("public func uninstall(moduleName:"))
        XCTAssertFalse(downloadServiceSource.contains("public func install(moduleName:"))
        XCTAssertFalse(downloadServiceSource.contains("public func uninstall(moduleName:"))
        XCTAssertFalse(downloadServiceSource.contains("installManager.install("))
        XCTAssertFalse(downloadServiceSource.contains("installManager.uninstall("))
        XCTAssertFalse(flatAPISource.contains("InstallMgr_installModule"))
        XCTAssertFalse(flatAPISource.contains("InstallMgr_uninstallModule"))
        XCTAssertFalse(swordAdapterSource.contains("InstallMgr_installModule"))
        XCTAssertFalse(swordAdapterSource.contains("InstallMgr_uninstallModule"))
    }

    /** Runs two throwing operations behind an explicit coordinator barrier and checks ordering. */
    private func assertSerialized(
        root: URL,
        firstKind: ModuleStoreMutationKind,
        secondKind: ModuleStoreMutationKind,
        first: @escaping @Sendable () throws -> Void,
        second: @escaping @Sendable () throws -> Void
    ) async throws {
        let gate = ModuleStoreTransactionGate()
        let observation = ModuleStoreMutationCoordinator.observeTransactions(
            forModuleRoot: root,
            observer: { event in gate.observe(event) }
        )
        defer { observation.cancel() }
        let firstTask = Task.detached(operation: first)
        try gate.waitForFirstMutationBoundary()
        let secondTask = Task.detached(operation: second)
        try gate.waitForSecondWriterToQueue()
        gate.releaseFirstWriter()
        try await firstTask.value
        try await secondTask.value

        let events = gate.events
        let firstID = try XCTUnwrap(gate.firstTransactionID)
        let secondID = try XCTUnwrap(gate.secondTransactionID)
        let firstCommit = try XCTUnwrap(events.firstIndex {
            $0.transactionID == firstID && $0.stage == .committed && $0.kind == firstKind
        })
        let secondMutation = try XCTUnwrap(events.firstIndex {
            $0.transactionID == secondID && $0.stage == .willMutate && $0.kind == secondKind
        })
        XCTAssertLessThan(firstCommit, secondMutation)
    }

    /** Creates one isolated root, two publisher instances, and a separate staging parent. */
    private func makeContext() throws -> ModuleStoreTestContext {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mods.d", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("modules", isDirectory: true),
            withIntermediateDirectories: true
        )
        return ModuleStoreTestContext(
            parent: parent,
            root: root,
            firstPublisher: ModuleStoreTransactionPublisher(moduleRootURL: root),
            secondPublisher: ModuleStoreTransactionPublisher(moduleRootURL: root)
        )
    }

    /** Builds and validates an isolated staged install fixture. */
    private func makeStagedInstall(
        context: ModuleStoreTestContext,
        publisher: ModuleStoreTransactionPublisher? = nil,
        name: String,
        driver: String = "RawText",
        dataPath: String,
        payloadPath: String,
        marker: String
    ) throws -> ModuleStoreStagedFixture {
        let stagingRoot = context.parent.appendingPathComponent(
            "staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let configPath = "mods.d/\(name.lowercased()).conf"
        let config = configData(name: name, driver: driver, dataPath: dataPath)
        let configURL = stagingRoot.appendingPathComponent(configPath)
        let payloadURL = stagingRoot.appendingPathComponent(payloadPath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: payloadURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try config.write(to: configURL)
        try Data(marker.utf8).write(to: payloadURL)
        let configuration = ModuleStoreStagedConfiguration(
            relativePath: configPath,
            content: try String(contentsOf: configURL, encoding: .utf8)
        )
        let plan = try (publisher ?? context.firstPublisher).validateStagedInstall(
            configurations: [configuration],
            payloadRelativePaths: [payloadPath]
        )
        return ModuleStoreStagedFixture(
            stagingRoot: stagingRoot,
            payloadPath: payloadPath,
            plan: plan
        )
    }

    /** Writes one valid installed config and payload directly for uninstall/replacement setup. */
    private func writeInstalledModule(
        root: URL,
        name: String,
        driver: String,
        dataPath: String,
        payloadPath: String,
        marker: String
    ) throws {
        let configURL = root.appendingPathComponent("mods.d/\(name.lowercased()).conf")
        let payloadURL = root.appendingPathComponent(payloadPath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: payloadURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try configData(name: name, driver: driver, dataPath: dataPath).write(to: configURL)
        try Data(marker.utf8).write(to: payloadURL)
    }

    /**
     Builds minimal UTF-8 SWORD config data without normalizing the supplied path.

     Bible drivers include explicit Android-compatible category and KJV versification metadata so
     fresh manager inventory can classify them during under-lease uninstall policy checks.

     - Parameters:
       - name: Exact module initials and config section.
       - driver: SWORD driver used to infer category and payload ownership.
       - dataPath: Unmodified path under the fixture's module root.
     - Returns: UTF-8 config bytes accepted by libsword and the transaction layout resolver.
     - Side effects: None; callers decide where to write the bytes.
     - Failure modes: None for supplied strings; intentionally unsafe paths remain unnormalized so
       path-validation tests can reject them.
     */
    private func configData(name: String, driver: String, dataPath: String) -> Data {
        let category = ModuleCategory(typeString: "", modDrv: driver)
        let versification = category == .bible ? "Versification=KJV\n" : ""
        return Data(
            """
            [\(name)]
            ModDrv=\(driver)
            DataPath=\(dataPath)
            Description=\(name)
            Category=\(category.rawValue)
            SourceType=OSIS
            Encoding=UTF-8
            \(versification)

            """.utf8
        )
    }

    /** Reads one installed payload marker. */
    private func payloadString(_ root: URL, _ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /** Proves no hidden transaction backup remains under the live root. */
    private func assertNoTransactionBackups(in root: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".module-transaction-") })
    }
}

/** Isolated test root and independent publisher instances. */
private struct ModuleStoreTestContext: @unchecked Sendable {
    let parent: URL
    let root: URL
    let firstPublisher: ModuleStoreTransactionPublisher
    let secondPublisher: ModuleStoreTransactionPublisher
}

/** Validated staged publication fixture. */
private struct ModuleStoreStagedFixture: @unchecked Sendable {
    let stagingRoot: URL
    let payloadPath: String
    let plan: ModuleStoreStagedInstallPlan
}

/**
 Deterministic barrier driven by coordinator events.

 The first `.willMutate` callback blocks on `releaseSemaphore`, keeping the lease held. A distinct
 transaction's `.waiting` and `.cancelledBeforeMutation` events provide typed proof of queue and
 cancellation state.
 */
private final class ModuleStoreTransactionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstBoundarySemaphore = DispatchSemaphore(value: 0)
    private let secondWaitingSemaphore = DispatchSemaphore(value: 0)
    private let secondCancelledSemaphore = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var storedEvents: [ModuleStoreMutationEvent] = []
    private var storedFirstTransactionID: UUID?
    private var storedSecondTransactionID: UUID?

    /// Stable snapshot of all observed coordinator events.
    var events: [ModuleStoreMutationEvent] {
        lock.withLock { storedEvents }
    }

    /// Transaction held at the first mutation boundary.
    var firstTransactionID: UUID? {
        lock.withLock { storedFirstTransactionID }
    }

    /// Distinct transaction observed waiting behind the first.
    var secondTransactionID: UUID? {
        lock.withLock { storedSecondTransactionID }
    }

    /** Records one event and blocks exactly the first writer at `.willMutate`. */
    func observe(_ event: ModuleStoreMutationEvent) {
        var shouldBlock = false
        lock.lock()
        storedEvents.append(event)
        if event.stage == .willMutate, storedFirstTransactionID == nil {
            storedFirstTransactionID = event.transactionID
            shouldBlock = true
            firstBoundarySemaphore.signal()
        } else if event.stage == .waiting,
                  let firstID = storedFirstTransactionID,
                  event.transactionID != firstID,
                  storedSecondTransactionID == nil {
            storedSecondTransactionID = event.transactionID
            secondWaitingSemaphore.signal()
        } else if event.stage == .cancelledBeforeMutation,
                  event.transactionID == storedSecondTransactionID {
            secondCancelledSemaphore.signal()
        }
        lock.unlock()
        if shouldBlock {
            releaseSemaphore.wait()
        }
    }

    /** Waits for the first writer to own the non-cancellable mutation boundary. */
    func waitForFirstMutationBoundary() throws {
        try wait(firstBoundarySemaphore, checkpoint: "first mutation boundary")
    }

    /** Waits for a distinct second writer to enter the coordinator queue. */
    func waitForSecondWriterToQueue() throws {
        try wait(secondWaitingSemaphore, checkpoint: "second writer queue")
    }

    /** Waits for typed pre-mutation cancellation of the queued writer. */
    func waitForSecondWriterCancellation() throws {
        try wait(secondCancelledSemaphore, checkpoint: "second writer cancellation")
    }

    /** Releases the first writer's synchronous observer callback. */
    func releaseFirstWriter() {
        releaseSemaphore.signal()
    }

    /** Applies a timeout only as deadlock protection around an event-driven barrier. */
    private func wait(_ semaphore: DispatchSemaphore, checkpoint: String) throws {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw ModuleStoreTransactionTestError.missingCheckpoint(checkpoint)
        }
    }
}

/** Thread-safe boolean used to observe the publisher's commit-start callback. */
private final class ModuleStoreLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool { lock.withLock { storedValue } }

    /** Marks the flag without exposing mutable state across task boundaries. */
    func set() {
        lock.withLock { storedValue = true }
    }
}

/** Injects a deterministic failure only when the publisher moves the final config marker. */
private final class ModuleStoreConfigCopyFaultFileManager: FileManager, @unchecked Sendable {
    private let failingConfigName: String

    /** Creates a file manager that rejects one destination config filename. */
    init(failingConfigName: String) {
        self.failingConfigName = failingConfigName
        super.init()
    }

    /** Fails the chosen staged-config move after payload publication has begun. */
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == failingConfigName,
           dstURL.deletingLastPathComponent().lastPathComponent == "mods.d",
           srcURL.lastPathComponent.hasPrefix(".module-config-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/** Injects one backup-cleanup failure after uninstall moved all live targets. */
private final class ModuleStoreBackupCleanupFaultFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailBackupCleanup = true

    /** Fails the first transaction-backup removal; rollback cleanup is allowed to complete. */
    override func removeItem(at URL: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard shouldFailBackupCleanup,
                  URL.lastPathComponent.hasPrefix(".module-transaction-") else {
                return false
            }
            shouldFailBackupCleanup = false
            return true
        }
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

/** Rejects activation publication unless its required replacement content is already live. */
private final class ModuleStoreActivationOrderFileManager: FileManager, @unchecked Sendable {
    private let requiredContentURL: URL
    private let expectedContent: Data
    private let activationURL: URL

    /** Creates a deterministic content-before-activation publication assertion. */
    init(requiredContentURL: URL, expectedContent: Data, activationURL: URL) {
        self.requiredContentURL = requiredContentURL
        self.expectedContent = expectedContent
        self.activationURL = activationURL
        super.init()
    }

    /** Fails the activation move if exact replacement content is not yet visible. */
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.standardizedFileURL == activationURL.standardizedFileURL,
           (try? Data(contentsOf: requiredContentURL)) != expectedContent {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/** Barrier setup failures indicate the transaction did not emit its typed checkpoint. */
private enum ModuleStoreTransactionTestError: Error {
    case missingCheckpoint(String)
    case registrationRejected
}

private extension NSLock {
    /** Executes a test-state operation while holding this lock. */
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
