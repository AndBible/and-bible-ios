import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
import SwordKit

/**
 Verifies Android's startup locked-Bible queue and its final real-source reconciliation.

 These tests protect the behavior that was missing in issue #389: installed locked Bibles are
 snapshotted in registration order, every initial row is processed even after an earlier success,
 cancel/rejection owns an explicit same-row retry decision, and only queue completion returns
 control to the reader's fresh access reconciliation.
 */
@MainActor
final class StartupLockedBibleUnlockQueueTests: BibleUISwordFixtureTestCase {
    /**
     Filters only locked Bibles while preserving exact installed registration order.

     - Setup: Interleaves locked Bibles with commentary, plain, and already-unlocked rows.
     - Expected result: The two locked Bible initials remain in their original relative order.
     - Failure meaning: Startup may prompt for non-Bibles, re-prompt readable content, or diverge
       from Android's `SwordDocumentFacade.bibles.filter { it.isLocked }` snapshot ordering.
     - Side effects: None; immutable metadata is used.
     */
    func testSnapshotFiltersLockedBiblesWithoutSorting() {
        let installedModules = [
            ModuleInfo(
                name: "LOCKED-Z",
                description: "First registered locked Bible",
                category: .bible,
                language: "en",
                isEncrypted: true,
                isUnlocked: false
            ),
            ModuleInfo(
                name: "COMMENTARY",
                description: "Locked commentary",
                category: .commentary,
                language: "en",
                isEncrypted: true,
                isUnlocked: false
            ),
            ModuleInfo(
                name: "PLAIN",
                description: "Readable Bible",
                category: .bible,
                language: "en"
            ),
            ModuleInfo(
                name: "UNLOCKED",
                description: "Previously unlocked Bible",
                category: .bible,
                language: "en",
                isEncrypted: true,
                isUnlocked: true
            ),
            ModuleInfo(
                name: "LOCKED-A",
                description: "Second registered locked Bible",
                category: .bible,
                language: "en",
                isEncrypted: true,
                isUnlocked: false
            ),
        ]

        let queue = StartupLockedBibleUnlockQueue(installedModules: installedModules)

        XCTAssertEqual(queue.lockedBibleModules.map(\.name), ["LOCKED-Z", "LOCKED-A"])
        XCTAssertEqual(queue.currentModule?.name, "LOCKED-Z")
        XCTAssertFalse(queue.isCompleted)
    }

    /**
     Continues the immutable queue after an accepted credential instead of entering the reader.

     - Setup: Creates two initially locked Bibles and accepts each in turn.
     - Expected result: The first acceptance advances to the second prompt; only the second marks
       the queue complete.
     - Failure meaning: iOS can stop at the first success and skip a later installed locked Bible,
       diverging from Android's full `for` loop.
     - Side effects: None; credential validation belongs to the presenter integration.
     */
    func testAcceptedCredentialStillProcessesEveryInitialLockedBible() {
        var queue = StartupLockedBibleUnlockQueue(
            installedModules: [
                ModuleInfo(
                    name: "FIRST",
                    description: "First",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
                ModuleInfo(
                    name: "SECOND",
                    description: "Second",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
            ]
        )

        queue.acceptCurrentModule()

        XCTAssertEqual(queue.currentModule?.name, "SECOND")
        XCTAssertFalse(queue.isCompleted)

        queue.acceptCurrentModule()

        XCTAssertNil(queue.currentModule)
        XCTAssertTrue(queue.isCompleted)
    }

    /** A terminal decline advances exactly once; credential/retry phases belong to the session. */
    func testTerminalDeclineAdvancesTheImmutableQueueExactlyOnce() {
        var queue = StartupLockedBibleUnlockQueue(
            installedModules: [
                ModuleInfo(
                    name: "FIRST",
                    description: "First",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
                ModuleInfo(
                    name: "SECOND",
                    description: "Second",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
            ]
        )

        queue.declineCurrentModule()

        XCTAssertEqual(queue.currentModule?.name, "SECOND")
        XCTAssertFalse(queue.isCompleted)

        queue.declineCurrentModule()
        XCTAssertNil(queue.currentModule)
        XCTAssertTrue(queue.isCompleted)

        queue.declineCurrentModule()
        XCTAssertEqual(queue.currentIndex, 2)
    }

    /**
     Reconciles a genuine locked-only A/B startup inventory after A accepts its real cipher key.

     - Setup: Copies the licensed-safe encrypted RawText fixture twice, removes the readable KJV
       descriptor, starts the reader with only locked A/B, then persists A's verified key.
     - Expected result: One fresh lifecycle reconciliation selects A and publishes its decrypted
       body while B remains locked; no second picker selection or cached placeholder is involved.
     - Failure meaning: Queue completion only refreshes picker rows, retains placeholder bytes, or
       requires an extra selection after a successful startup unlock.
     - Side effects: Mutates only the base test case's copied SWORD fixture.
     */
    func testLockedOnlyABStartupUnlocksAIntoFreshVisibleBody() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEncryptedBible(named: "LOCKEDA", in: modulePath)
        try seedEncryptedBible(named: "LOCKEDB", in: modulePath)
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        try FileManager.default.removeItem(
            at: moduleRoot.appendingPathComponent("mods.d/kjv.conf")
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertEqual(
            manager.installedModules().filter { $0.category == .bible }.map(\.name),
            ["LOCKEDA", "LOCKEDB"]
        )
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKEDA"), .locked)
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKEDB"), .locked)

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        let boundary = scripts().count

        XCTAssertTrue(
            manager.unlockModule(named: "LOCKEDA", withCipherKey: "rawtextcipherkey")
        )
        controller.reconcileInstalledSources()
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )

        XCTAssertEqual(controller.activeModuleName, "LOCKEDA")
        XCTAssertTrue(emissions.joined().contains("Synthetic encrypted first verse"))
        XCTAssertEqual(
            controller.installedModules(for: .bible).first { $0.name == "LOCKEDB" }?.isUnlocked,
            false
        )
    }

    /** Copies one genuine encrypted RawText fixture behind a distinct installed identity. */
    private func seedEncryptedBible(named name: String, in modulePath: String) throws {
        let fileManager = FileManager.default
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let source = moduleRoot.appendingPathComponent(
            "ui-test-encrypted-rawtext",
            isDirectory: true
        )
        let moduleKey = name.lowercased()
        let destination = moduleRoot.appendingPathComponent(
            "modules/texts/rawtext/\(moduleKey)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: destination)
        try """
        [\(name)]
        Description=Encrypted startup fixture \(name)
        Abbreviation=\(name)
        DataPath=./modules/texts/rawtext/\(moduleKey)/
        ModDrv=RawText
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        CipherKey=
        """.write(
            to: moduleRoot.appendingPathComponent("mods.d/\(moduleKey).conf"),
            atomically: true,
            encoding: .utf8
        )
    }
}
