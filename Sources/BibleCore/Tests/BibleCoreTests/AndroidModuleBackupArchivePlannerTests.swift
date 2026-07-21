import CLibSword
import Foundation
import SwordKit
import XCTest
@testable import BibleCore

/**
 Verifies read-only Android module-backup planning against the production Android contracts in
 `BackupControl`, `CommonUtils`, and `InstallZip`.

 Fixtures use explicit local-entry order and ZIP metadata. One URL-backed contract test writes and
 removes a private temporary archive. Failures
 indicate Android manifest/inference drift, loss of a supported module family, unsafe destination
 acceptance, missed integrity validation, or an ineffective resource bound. The suite performs no
 filesystem mutation and has no asynchronous or shared-state dependencies.
 */
final class AndroidModuleBackupArchivePlannerTests: XCTestCase {
    /**
     Protects literal first-entry manifest handling and Android path normalization.

     A manifested SWORD archive uses backslashes in ZIP names plus repeated separators and benign
     dot segments. Its SWORD `DataPath` remains POSIX syntax because Android does not reinterpret
     backslashes inside configuration values.
     Success requires typed manifest metadata, exact normalized output paths, config ownership, and
     case-insensitive conflict reporting without changing archive spelling.
     */
    func testManifestFirstPlansNormalizedSwordEntriesAndConflicts() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file(
                "AndBibleBackupManifest.json",
                manifestData(andBibleVersion: 777)
            ),
            .file(
                "mods.d\\.\\KJV.conf",
                swordConfigurationData(
                    moduleName: "KJV",
                    dataPath: "./modules/texts/rawtext/kjv/"
                )
            ),
            .file(
                "modules//texts/./rawtext/kjv/ot",
                Data("Genesis".utf8)
            ),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(
            from: fixture.data,
            existingDestinationPaths: ["MODS.D/kjv.conf"]
        )

        XCTAssertEqual(
            plan.manifestDisposition,
            .validatedFirstEntry(AndroidModuleBackupArchiveManifest(
                backupType: .moduleBackup,
                manifestVersion: 1,
                andBibleVersion: 777
            ))
        )
        XCTAssertEqual(
            plan.entries.map(\.relativePath),
            ["mods.d/KJV.conf", "modules/texts/rawtext/kjv/ot"]
        )
        XCTAssertEqual(
            plan.entries.map(\.sourcePath),
            ["mods.d\\.\\KJV.conf", "modules//texts/./rawtext/kjv/ot"]
        )
        XCTAssertEqual(plan.entries.map(\.archivePosition), [1, 2])
        XCTAssertEqual(plan.entries.map(\.family), [.swordConfiguration, .swordPayload])
        XCTAssertEqual(plan.entries[1].owningConfigurationPaths, ["mods.d/KJV.conf"])
        XCTAssertEqual(plan.swordModuleNames, ["KJV"])
        XCTAssertEqual(plan.conflictPaths, ["mods.d/KJV.conf"])
        XCTAssertEqual(plan.families.map(\.family), [.swordConfiguration, .swordPayload])
    }

    /**
     Protects Android's rule that a non-first manifest is non-authoritative legacy metadata.

     The later manifest deliberately declares `DB_BACKUP`; planning must ignore its payload and
     infer MyBible content from paths, matching `AndBibleBackupManifest.fromUri` returning null.
     */
    func testManifestNotFirstUsesLegacyInferenceWithoutDecodingLaterManifest() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible/legacy.SQLite3", Data("SQLite".utf8)),
            .file(
                "AndBibleBackupManifest.json",
                Data(#"{"backupType":"DB_BACKUP","manifestVersion":99}"#.utf8)
            ),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.manifestDisposition, .legacyManifestNotFirst)
        XCTAssertEqual(plan.entries.map(\.relativePath), ["mybible/legacy.SQLite3"])
        XCTAssertEqual(plan.families.map(\.family), [.myBible])
    }

    /**
     Protects pre-manifest Android module archives.

     A no-manifest MySword archive must be recognized solely from its modules-root-relative path;
     failure would make backups produced before Android added manifests unrestorable.
     */
    func testNoManifestInfersLegacyFamily() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mysword/legacy.mybible", Data("SQLite".utf8)),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.manifestDisposition, .legacyWithoutManifest)
        XCTAssertEqual(plan.entries.map(\.family), [.mySword])
    }

    /**
     Protects complete Android family classification in one mixed archive.

     The fixture includes SWORD, MyBible, MySword, e-Sword, EPUB, font, background, and prompt
     content. Every path must remain ordered and receive a distinct typed family.
     */
    func testMixedArchiveExposesEveryAndroidModuleFamily() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("AndBibleBackupManifest.json", manifestData()),
            .file(
                "mods.d/mixed.conf",
                swordConfigurationData(
                    moduleName: "Mixed",
                    dataPath: "./modules/texts/rawtext/mixed/"
                )
            ),
            .file("modules/texts/rawtext/mixed/ot", Data("text".utf8)),
            .file("mybible/book.SQLite3", Data("mybible".utf8)),
            .file("mysword/book.mybible", Data("mysword".utf8)),
            .file("esword/book.bbli", Data("esword".utf8)),
            .file("epub/book/META-INF/container.xml", Data("epub".utf8)),
            .file("ttf/font.ttf", Data("font".utf8)),
            .file("background/image.webp", Data("image".utf8)),
            .file("prompts/questions.csv", Data("prompt".utf8)),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.families.map(\.family), [
            .swordConfiguration,
            .swordPayload,
            .myBible,
            .mySword,
            .eSword,
            .epub,
            .ttf,
            .background,
            .prompts,
        ])
        XCTAssertEqual(plan.entries.count, 9)
    }

    /**
     Protects Android backups whose SWORD `DataPath` lives outside the conventional `modules` root.

     A RawLD file-stem config owns its containing custom directory, so the custom payload must be
     typed as SWORD data and linked back to the exact configuration path.
     */
    func testUnusualSwordDataPathRootClassifiesConfigOwnedPayload() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mods.d/custom.conf", swordConfigurationData(
                moduleName: "Custom",
                dataPath: "./vendor/dictionaries/custom/stem",
                driver: "RawLD"
            )),
            .file("vendor/dictionaries/custom/stem.dat", Data("definitions".utf8)),
            .file("vendor/dictionaries/custom/stem.idx", Data([0, 0, 0, 0])),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.entries.map(\.family), [
            .swordConfiguration,
            .swordPayload,
            .swordPayload,
        ])
        XCTAssertEqual(
            plan.entries[1].owningConfigurationPaths,
            ["mods.d/custom.conf"]
        )
    }

    /**
     Protects destination containment after Android-compatible separator normalization.

     Absolute POSIX paths, Windows drive paths, NUL-containing names, and every `..` component must
     fail before decompression or family inference. Rejecting contained `..` is a deliberate iOS
     security extension over Android's unsafe lexical normalization.
     */
    func testRejectsAbsoluteNULAndEscapingTraversalPaths() throws {
        let unsafePaths = [
            "/mybible/book.SQLite3",
            "C:\\mybible\\book.SQLite3",
            "mybible/bad\0name.SQLite3",
            "mybible/nested/../book.SQLite3",
            "mybible/../../escape.SQLite3",
        ]

        for path in unsafePaths {
            let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
                .file(path, Data("payload".utf8)),
            ])
            XCTAssertThrowsError(
                try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data),
                "Expected unsafe path rejection for \(path.debugDescription)"
            ) { error in
                guard case .unsafeEntryPath = error as? AndroidModuleBackupArchivePlannerError else {
                    return XCTFail("Expected unsafeEntryPath, got \(error)")
                }
            }
        }
    }

    /**
     Protects unique destinations across exact, case-insensitive, and Unicode-normalized spellings.

     Each fixture contains distinct ZIP records that would target one Apple-filesystem path. A
     failure means publication could overwrite an earlier archive member nondeterministically.
     */
    func testRejectsDuplicateCaseAndUnicodeDestinationCollisions() throws {
        let fixtures: [(AndroidModuleBackupZIPFixture.Archive, Bool)] = [
            (try AndroidModuleBackupZIPFixture.make(entries: [
                .file("mybible/book.SQLite3", Data("one".utf8)),
                .file("mybible/book.SQLite3", Data("two".utf8)),
            ]), true),
            (try AndroidModuleBackupZIPFixture.make(entries: [
                .file("ttf/Font.ttf", Data("one".utf8)),
                .file("TTF/font.ttf", Data("two".utf8)),
            ]), false),
            (try AndroidModuleBackupZIPFixture.make(entries: [
                .file("background/caf\u{00e9}.jpg", Data("one".utf8)),
                .file("background/cafe\u{0301}.jpg", Data("two".utf8)),
            ]), false),
        ]

        for (fixture, expectsExactDuplicate) in fixtures {
            XCTAssertThrowsError(
                try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)
            ) { error in
                guard let plannerError = error as? AndroidModuleBackupArchivePlannerError else {
                    return XCTFail("Expected planner error, got \(error)")
                }
                if expectsExactDuplicate {
                    guard case .duplicateEntry = plannerError else {
                        return XCTFail("Expected duplicateEntry, got \(plannerError)")
                    }
                } else {
                    guard case .destinationCollision = plannerError else {
                        return XCTFail("Expected destinationCollision, got \(plannerError)")
                    }
                }
            }
        }
    }

    /**
     Protects destination-tree consistency when one file shadows another entry's parent directory.

     The archive must fail before classification because no transaction can create both `mybible`
     as a regular file and `mybible/book.SQLite3` as its descendant.
     */
    func testRejectsFileDirectoryDestinationCollision() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible", Data("file".utf8)),
            .file("mybible/book.SQLite3", Data("child".utf8)),
        ])

        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)
        ) { error in
            guard case .destinationCollision = error as? AndroidModuleBackupArchivePlannerError else {
                return XCTFail("Expected destinationCollision, got \(error)")
            }
        }
    }

    /**
     Protects read-only planning from ZIP entries representing links or special filesystem nodes.

     A Unix symlink can redirect later publication outside the modules root even when its textual
     path is safe, so external attributes must trigger rejection before payload expansion.
     */
    func testRejectsSymbolicLinkEntry() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .symbolicLink("mybible/link.SQLite3", target: "../../outside"),
        ])

        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)
        ) { error in
            XCTAssertEqual(
                error as? AndroidModuleBackupArchivePlannerError,
                .symbolicLink("mybible/link.SQLite3")
            )
        }
    }

    /**
     Protects Android's catch-and-generic-install first-manifest contract.

     Malformed JSON, unknown/DB types, future schemas, explicit nulls, unknown `contains` values,
     and overflowing integers all make Android's `fromUri` return null. Only a successfully decoded
     StudyPad export remains special and unsupported by module planning.
     */
    func testFirstManifestFailuresFallThroughGenericInstallExceptStudyPad() throws {
        let fallbackManifests = [
            Data("{".utf8),
            Data(#"{"backupType":"MODULE_BACKUP","manifestVersion":"1"}"#.utf8),
            Data(#"{"backupType":"DB_BACKUP","manifestVersion":1}"#.utf8),
            Data(#"{"backupType":"UNKNOWN_BACKUP","manifestVersion":1}"#.utf8),
            Data(#"{"backupType":"MODULE_BACKUP","manifestVersion":2}"#.utf8),
            Data(#"{"backupType":"MODULE_BACKUP","manifestVersion":null}"#.utf8),
            Data(#"{"backupType":"MODULE_BACKUP","andBibleVersion":null}"#.utf8),
            Data(#"{"backupType":"MODULE_BACKUP","andBibleVersion":9223372036854775808}"#.utf8),
            Data(#"{"backupType":"MODULE_BACKUP","contains":["FUTURE_DATA"]}"#.utf8),
        ]

        for manifest in fallbackManifests {
            let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
                .file("AndBibleBackupManifest.json", manifest),
                .file("mybible/book.SQLite3", Data("SQLite".utf8)),
            ])
            let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)
            XCTAssertEqual(plan.manifestDisposition, .legacyManifestNotFirst)
            XCTAssertEqual(plan.entries.map(\.family), [.myBible])
        }

        let studyPad = try AndroidModuleBackupZIPFixture.make(entries: [
            .file(
                "AndBibleBackupManifest.json",
                Data(#"{"backupType":"STUDYPAD_EXPORT"}"#.utf8)
            ),
            .file("mybible/book.SQLite3", Data("SQLite".utf8)),
        ])
        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner().planArchive(from: studyPad.data)
        ) { error in
            XCTAssertEqual(
                error as? AndroidModuleBackupArchivePlannerError,
                .unsupportedBackupType("STUDYPAD_EXPORT")
            )
        }
    }

    /**
     Protects metadata integrity validation before a plan is exposed.

     One fixture corrupts a bounded SWORD configuration after checksums are written and another
     truncates the ZIP trailer. Both must fail as invalid archives. Nonmetadata payload CRC validation
     is intentionally deferred to transactional extraction so preflight remains bounded and read-only.
     */
    func testRejectsCRCMismatchAndTruncatedArchive() throws {
        let valid = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mods.d/kjv.conf", swordConfigurationData(
                moduleName: "KJV",
                dataPath: "./modules/texts/rawtext/kjv/"
            )),
            .file("modules/texts/rawtext/kjv/ot", Data("payload".utf8)),
        ])
        let corrupt = valid.corruptingPayload(entryAt: 0)
        let truncated = Data(valid.data.dropLast(8))

        for archive in [corrupt, truncated] {
            XCTAssertThrowsError(
                try AndroidModuleBackupArchivePlanner().planArchive(from: archive)
            ) { error in
                guard case .invalidArchive = error as? AndroidModuleBackupArchivePlannerError else {
                    return XCTFail("Expected invalidArchive, got \(error)")
                }
            }
        }
    }

    /**
     Protects per-entry expansion, entry-count, aggregate expansion, and compression-ratio bounds.

     Each deterministic fixture exceeds exactly one reduced policy ceiling. Typed resource errors
     prove limits are enforced from metadata before eager decompression.
     */
    func testRejectsExpansionCountAndAggregateResourceViolations() throws {
        let oneEntry = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible/book.SQLite3", Data("1234".utf8)),
        ])
        try assertResourceViolation(
            .entryExpandedBytes,
            archive: oneEntry.data,
            limits: plannerLimits(maximumEntryExpandedByteCount: 3)
        )

        let twoEntries = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible/one.SQLite3", Data("123".utf8)),
            .file("mysword/two.mybible", Data("456".utf8)),
        ])
        try assertResourceViolation(
            .entryCount,
            archive: twoEntries.data,
            limits: plannerLimits(maximumEntryCount: 1)
        )
        try assertResourceViolation(
            .aggregateExpandedBytes,
            archive: twoEntries.data,
            limits: plannerLimits(maximumAggregateExpandedByteCount: 5)
        )

        let compressed = try AndroidModuleBackupZIPFixture.make(entries: [
            .file(
                "background/repeated.png",
                Data(repeating: 0x41, count: 4096),
                compression: .deflated
            ),
        ])
        try assertResourceViolation(
            .expansionRatio,
            archive: compressed.data,
            limits: plannerLimits(maximumExpansionRatio: 2)
        )
    }

    /**
     Protects Android generic extraction for files with no specialized registrar or config owner.

     Safe unowned files are published as generic `.swordPayload`, while only paths meeting Android's
     extension/depth discovery rules receive a specialized family.
     */
    func testPreservesSafeUnownedEntriesForGenericInstallation() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("modules/texts/rawtext/orphan/ot", Data("text".utf8)),
            .file("mybible/readme.txt", Data("notes".utf8)),
            .file("esword/nested/book.bbli", Data("nested".utf8)),
            .file("mybible/book.SQLite3", Data("SQLite".utf8)),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.entries.map(\.relativePath), [
            "modules/texts/rawtext/orphan/ot",
            "mybible/readme.txt",
            "esword/nested/book.bbli",
            "mybible/book.SQLite3",
        ])
        XCTAssertEqual(plan.entries.map(\.family), [
            .swordPayload, .swordPayload, .swordPayload, .myBible,
        ])
    }

    /**
     Protects the complete Android manifest DTO, including omitted non-null runtime defaults.

     Omitted versions decode to schema `1` and deterministic Android-version sentinel `0`, while
     the optional `contains` enum set is retained on the public plan.
     */
    func testManifestContainsAndOmittedRuntimeVersionAreRetained() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file(
                "AndBibleBackupManifest.json",
                Data(#"{"backupType":"MODULE_BACKUP","contains":["MODULES","EPUBS"]}"#.utf8)
            ),
            .file("mybible/book.SQLite3", Data("SQLite".utf8)),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(
            plan.manifestDisposition,
            .validatedFirstEntry(AndroidModuleBackupArchiveManifest(
                backupType: .moduleBackup,
                contains: [.modules, .epubs],
                manifestVersion: 1,
                andBibleVersion: 0
            ))
        )
    }

    /**
     Protects byte-exact local/central identity and terminal-dot destination safety.

     Canonically equivalent names compare equal as Swift strings but are distinct ZIP byte names;
     the parser must reject that mismatch. A terminal `/.` is rejected before dot normalization can
     silently alias it to another filesystem object.
     */
    func testRejectsCanonicalLocalNameMismatchAndTerminalDotPath() throws {
        let mismatchedName = try AndroidModuleBackupZIPFixture.make(entries: [
            .file(
                "background/caf\u{00e9}.jpg",
                Data("image".utf8),
                localName: "background/cafe\u{0301}.jpg"
            ),
        ])
        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner().planArchive(from: mismatchedName.data)
        ) { error in
            guard case .invalidArchive = error as? AndroidModuleBackupArchivePlannerError else {
                return XCTFail("Expected invalidArchive, got \(error)")
            }
        }

        let terminalDot = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible/.", Data("ambiguous".utf8)),
        ])
        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner().planArchive(from: terminalDot.data)
        ) { error in
            XCTAssertEqual(
                error as? AndroidModuleBackupArchivePlannerError,
                .unsafeEntryPath("mybible/.")
            )
        }
    }

    /**
     Protects implicit destination directories from case-folded and canonical aliases.

     No explicit directory records are needed for these trees to collide on Apple filesystems;
     every implied ancestor spelling must participate in collision validation.
     */
    func testRejectsImplicitAncestorAliases() throws {
        let aliasPairs = [
            ("background/Pack/one.jpg", "background/pack/two.jpg"),
            ("ttf/Caf\u{00e9}/one.ttf", "ttf/Cafe\u{0301}/two.ttf"),
        ]
        for (first, second) in aliasPairs {
            let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
                .file(first, Data("one".utf8)),
                .file(second, Data("two".utf8)),
            ])
            XCTAssertThrowsError(
                try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)
            ) { error in
                guard case .destinationCollision =
                    error as? AndroidModuleBackupArchivePlannerError else {
                    return XCTFail("Expected destinationCollision, got \(error)")
                }
            }
        }
    }

    /**
     Protects conflicts where either an existing or planned file blocks the other's descendant.

     Exact path matching alone misses both tree-shape failures; conflict reporting must flag the
     corresponding planned row in local order.
     */
    func testReportsExistingAncestorAndDescendantTreeConflicts() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible/book.SQLite3", Data("SQLite".utf8)),
            .file("background/theme.png", Data("image".utf8)),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(
            from: fixture.data,
            existingDestinationPaths: [
                "mybible",
                "background/theme.png/preview",
            ]
        )

        XCTAssertEqual(plan.conflictPaths, [
            "mybible/book.SQLite3",
            "background/theme.png",
        ])
    }

    /**
     Protects Android writer ownership for runtime categories and config-owned FontPacks.

     Dictionary file-stem backups include non-prefix siblings in the selected directory. A
     `Category=And Bible` font config owns its `ttf` tree and suppresses generic TTF registration.
     */
    func testSwordWriterOwnsWholeCategoryDirectoryAndConfigOwnedFontPack() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mods.d/Dictionary.conf", swordConfigurationData(
                moduleName: "Dictionary",
                dataPath: "./modules/lexdict/rawld/dictionary/stem",
                driver: "RawLD",
                category: "Lexicons / Dictionaries"
            )),
            .file(
                "modules/lexdict/rawld/dictionary/nonprefix.dat",
                Data("definitions".utf8)
            ),
            .file("mods.d/FontPack.conf", swordConfigurationData(
                moduleName: "FontPack",
                dataPath: "./ttf/",
                driver: "RawGenBook",
                category: "And Bible"
            )),
            .file("ttf/AndBible.ttf", Data("font".utf8)),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.entries.map(\.family), [
            .swordConfiguration, .swordPayload, .swordConfiguration, .swordPayload,
        ])
        XCTAssertEqual(
            plan.entries[1].owningConfigurationPaths,
            ["mods.d/Dictionary.conf"]
        )
        XCTAssertEqual(
            plan.entries[3].owningConfigurationPaths,
            ["mods.d/FontPack.conf"]
        )
    }

    /**
     Protects standards-valid forced ZIP64 local size fields when central sizes remain classic.

     Some writers force local ZIP64 headers below 4 GiB. Those sentinel fields must resolve from
     local extra metadata instead of being compared as literal `UInt32.max` values.
     */
    func testAcceptsForcedZIP64LocalHeader() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file(
                "mybible/book.SQLite3",
                Data("SQLite".utf8),
                forceLocalZIP64: true
            ),
        ])

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.entries.map(\.family), [.myBible])
    }

    /**
     Protects ZIP64 EOCD body-size arithmetic from conversion and addition traps.

     A crafted maximum body length cannot physically fit before the locator. Planning must return a
     typed invalid-archive error rather than trapping while calculating the record end.
     */
    func testRejectsOverflowingZIP64EndRecordBodyLengthWithoutTrap() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible/book.SQLite3", Data("SQLite".utf8)),
        ])
        let crafted = fixture.withZIP64EndRecord(bodyByteCount: .max)

        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner().planArchive(from: crafted)
        ) { error in
            guard case .invalidArchive = error as? AndroidModuleBackupArchivePlannerError else {
                return XCTFail("Expected invalidArchive, got \(error)")
            }
        }
    }

    /**
     Protects bounded URL-backed validation without extraction scratch.

     The URL path reads only metadata/config bytes directly from the archive. Its immutable plan must
     equal the Data path and leave the containing directory unchanged apart from the archive itself.
     */
    func testURLBackedStreamingPlanMatchesDataPlan() throws {
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: [
            .file("mybible/stored.SQLite3", Data(repeating: 0x41, count: 64 * 1024)),
            .file(
                "background/deflated.png",
                Data(repeating: 0x42, count: 128 * 1024),
                compression: .deflated
            ),
        ])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("modules.zip")
        try fixture.data.write(to: archiveURL, options: .atomic)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

        let planner = AndroidModuleBackupArchivePlanner()
        XCTAssertEqual(
            try planner.planArchive(at: archiveURL),
            try planner.planArchive(from: fixture.data)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    /**
     Protects ownership indexing with many disjoint SWORD configurations.

     The fixture is intentionally large enough to exercise prior pairwise ownership/classification
     loops while keeping each path shallow; every payload must retain exactly one owner.
     */
    func testManyDisjointSwordConfigurationsRemainIndependentlyOwned() throws {
        var entries: [AndroidModuleBackupZIPFixture.Entry] = []
        for index in 0..<512 {
            let moduleName = "Module\(index)"
            entries.append(.file(
                "mods.d/\(moduleName).conf",
                swordConfigurationData(
                    moduleName: moduleName,
                    dataPath: "./vendor/\(moduleName)/"
                )
            ))
            entries.append(.file(
                "vendor/\(moduleName)/payload.dat",
                Data("payload".utf8)
            ))
        }
        let fixture = try AndroidModuleBackupZIPFixture.make(entries: entries)

        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: fixture.data)

        XCTAssertEqual(plan.swordModuleNames.count, 512)
        XCTAssertEqual(plan.entries.count, 1_024)
        XCTAssertTrue(plan.entries.enumerated().allSatisfy { index, entry in
            index.isMultiple(of: 2) || entry.owningConfigurationPaths.count == 1
        })
    }

    /**
     Asserts that planning fails for one expected bounded resource.

     - Parameters:
       - expectedResource: Resource category expected to exceed policy.
       - archive: Complete deterministic fixture ZIP.
       - limits: Reduced planner limits.
     - Side effects: none.
     - Throws: Rethrows fixture-independent XCTest failures only through the enclosing test method.
     */
    private func assertResourceViolation(
        _ expectedResource: AndroidModuleBackupArchiveResource,
        archive: Data,
        limits: AndroidModuleBackupArchiveLimits
    ) throws {
        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner(limits: limits).planArchive(from: archive)
        ) { error in
            guard case .resourceLimitExceeded(let resource, _, _) =
                error as? AndroidModuleBackupArchivePlannerError else {
                return XCTFail("Expected resourceLimitExceeded, got \(error)")
            }
            XCTAssertEqual(resource, expectedResource)
        }
    }
}

/**
 Creates Android manifest JSON used by valid planner fixtures.

 - Parameter andBibleVersion: Optional Android application version.
 - Returns: UTF-8 module-backup manifest bytes with schema version `1`.
 - Side effects: none.
 - Failure modes: This deterministic fixture helper cannot fail.
 */
private func manifestData(andBibleVersion: Int? = nil) -> Data {
    let versionField = andBibleVersion.map { ",\"andBibleVersion\":\($0)" } ?? ""
    return Data(
        "{\"backupType\":\"MODULE_BACKUP\",\"manifestVersion\":1\(versionField)}".utf8
    )
}

/**
 Creates one minimal UTF-8 SWORD configuration fixture.

 - Parameters:
   - moduleName: SWORD section initials.
   - dataPath: Raw Android/SWORD `DataPath` spelling.
   - driver: SWORD module driver.
   - category: Optional Android/SWORD display category.
 - Returns: UTF-8 config bytes containing the ownership fields used by the planner.
 - Side effects: none.
 - Failure modes: This deterministic fixture helper cannot fail.
 */
private func swordConfigurationData(
    moduleName: String,
    dataPath: String,
    driver: String = "RawText",
    category: String? = nil
) -> Data {
    var lines = [
        "[\(moduleName)]",
        "DataPath=\(dataPath)",
        "ModDrv=\(driver)",
    ]
    if let category {
        lines.append("Category=\(category)")
    }
    lines.append("Encoding=UTF-8")
    return Data(lines.joined(separator: "\n").utf8)
}

/**
 Creates a planner limit set while retaining production defaults for unspecified boundaries.

 - Parameters:
   - maximumEntryCount: Optional local-entry ceiling.
   - maximumEntryExpandedByteCount: Optional per-entry expanded-size ceiling.
   - maximumAggregateExpandedByteCount: Optional aggregate expanded-size ceiling.
   - maximumExpansionRatio: Optional rounded-up expansion-ratio ceiling.
 - Returns: Complete immutable resource policy.
 - Side effects: none.
 - Failure modes: This deterministic fixture helper cannot fail.
 */
private func plannerLimits(
    maximumEntryCount: Int? = nil,
    maximumEntryExpandedByteCount: UInt64? = nil,
    maximumAggregateExpandedByteCount: UInt64? = nil,
    maximumExpansionRatio: UInt64? = nil
) -> AndroidModuleBackupArchiveLimits {
    let defaults = AndroidModuleBackupArchiveLimits()
    return AndroidModuleBackupArchiveLimits(
        maximumArchiveByteCount: defaults.maximumArchiveByteCount,
        maximumEntryCount: maximumEntryCount ?? defaults.maximumEntryCount,
        maximumEntryCompressedByteCount: defaults.maximumEntryCompressedByteCount,
        maximumEntryExpandedByteCount: maximumEntryExpandedByteCount
            ?? defaults.maximumEntryExpandedByteCount,
        maximumAggregateCompressedByteCount: defaults.maximumAggregateCompressedByteCount,
        maximumAggregateExpandedByteCount: maximumAggregateExpandedByteCount
            ?? defaults.maximumAggregateExpandedByteCount,
        maximumExpansionRatio: maximumExpansionRatio ?? defaults.maximumExpansionRatio,
        maximumMetadataEntryByteCount: defaults.maximumMetadataEntryByteCount,
        maximumPathByteCount: defaults.maximumPathByteCount
    )
}

/**
 Deterministic classic-ZIP fixture factory for Android archive planner tests.

 The builder writes local headers and central records in the supplied order, uses no data
 descriptors, and exposes payload offsets for targeted corruption. It models only stored and raw
 deflated entries because those are the production reader's accepted methods.
 */
private enum AndroidModuleBackupZIPFixture {
    /**
     Compression method used by one fixture entry.
     */
    enum Compression {
        /// ZIP method 0 with payload bytes unchanged.
        case stored

        /// ZIP method 8 using a raw-deflate payload.
        case deflated
    }

    /**
     One ordered fixture entry before ZIP headers are serialized.
     */
    struct Entry {
        /// Exact central-directory path spelling.
        let name: String

        /// Optional distinct local-header path spelling for mismatch tests.
        let localName: String?

        /// Expanded payload bytes.
        let data: Data

        /// ZIP compression method.
        let compression: Compression

        /// Central-directory external attributes.
        let externalAttributes: UInt32

        /// Whether local sizes use ZIP64 sentinels and an extended-information field.
        let forceLocalZIP64: Bool

        /**
         Creates a regular file entry.

         - Parameters:
           - name: Exact ZIP path.
           - data: Expanded file bytes.
           - compression: Stored or raw-deflated payload encoding.
           - localName: Optional local-header name distinct from the central name.
           - forceLocalZIP64: Whether to encode valid ZIP64 local size fields below 4 GiB.
         - Returns: Regular-file fixture descriptor.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        static func file(
            _ name: String,
            _ data: Data,
            compression: Compression = .stored,
            localName: String? = nil,
            forceLocalZIP64: Bool = false
        ) -> Entry {
            Entry(
                name: name,
                localName: localName,
                data: data,
                compression: compression,
                externalAttributes: UInt32(0o100644) << 16,
                forceLocalZIP64: forceLocalZIP64
            )
        }

        /**
         Creates a Unix symbolic-link entry whose payload is the textual target.

         - Parameters:
           - name: Exact ZIP link path.
           - target: Link target encoded as UTF-8 payload bytes.
         - Returns: Symlink fixture descriptor with Unix external mode bits.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        static func symbolicLink(_ name: String, target: String) -> Entry {
            Entry(
                name: name,
                localName: nil,
                data: Data(target.utf8),
                compression: .stored,
                externalAttributes: UInt32(0o120777) << 16,
                forceLocalZIP64: false
            )
        }
    }

    /**
     Serialized archive plus local payload offsets used by corruption tests.
     */
    struct Archive {
        /// Complete classic ZIP bytes.
        let data: Data

        /// Local payload offset for each input entry.
        let payloadOffsets: [Int]

        /// Classic central-directory offset retained for ZIP64 trailer fixtures.
        let centralDirectoryOffset: Int

        /// Classic central-directory byte count retained for ZIP64 trailer fixtures.
        let centralDirectoryByteCount: Int

        /// Number of serialized central entries.
        let entryCount: Int

        /**
         Corrupts the first payload byte of one non-empty entry without updating its CRC.

         - Parameter entryAt: Input entry index.
         - Returns: Complete archive bytes containing a deterministic CRC mismatch.
         - Side effects: none; mutates only a local copy.
         - Failure modes: Returns the original bytes when the index or payload offset is unavailable.
         */
        func corruptingPayload(entryAt index: Int) -> Data {
            guard payloadOffsets.indices.contains(index),
                  payloadOffsets[index] < data.count else {
                return data
            }
            var corrupted = data
            corrupted[payloadOffsets[index]] ^= 0xff
            return corrupted
        }

        /**
         Replaces the classic trailer with a ZIP64 EOCD, locator, and sentinel classic EOCD.

         - Parameter bodyByteCount: Declared ZIP64 EOCD body size; callers may deliberately make it
           inconsistent with the physically emitted fixed record.
         - Returns: Complete ZIP bytes with the replacement trailer.
         - Side effects: none; appends to a local byte copy.
         - Failure modes: This deterministic fixture transformation cannot fail.
         */
        func withZIP64EndRecord(bodyByteCount: UInt64) -> Data {
            var result = Data(data.dropLast(22))
            let zip64RecordOffset = result.count
            AndroidModuleBackupZIPFixture.appendUInt32(0x0606_4b50, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt64(bodyByteCount, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt16(45, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt16(45, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt32(0, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt32(0, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt64(UInt64(entryCount), to: &result)
            AndroidModuleBackupZIPFixture.appendUInt64(UInt64(entryCount), to: &result)
            AndroidModuleBackupZIPFixture.appendUInt64(
                UInt64(centralDirectoryByteCount),
                to: &result
            )
            AndroidModuleBackupZIPFixture.appendUInt64(
                UInt64(centralDirectoryOffset),
                to: &result
            )

            AndroidModuleBackupZIPFixture.appendUInt32(0x0706_4b50, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt32(0, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt64(UInt64(zip64RecordOffset), to: &result)
            AndroidModuleBackupZIPFixture.appendUInt32(1, to: &result)

            AndroidModuleBackupZIPFixture.appendUInt32(0x0605_4b50, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt16(.max, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt16(.max, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt16(.max, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt16(.max, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt32(.max, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt32(.max, to: &result)
            AndroidModuleBackupZIPFixture.appendUInt16(0, to: &result)
            return result
        }
    }

    /**
     Intermediate serialized entry metadata reused by central-directory emission.
     */
    private struct SerializedEntry {
        /// UTF-8 central path bytes.
        let centralName: Data

        /// Raw stored or deflated bytes.
        let compressedData: Data

        /// Expanded byte count.
        let expandedByteCount: Int

        /// ZIP compression method.
        let method: UInt16

        /// Expanded payload checksum.
        let checksum: UInt32

        /// Local-header offset.
        let localHeaderOffset: Int

        /// Central external attributes.
        let externalAttributes: UInt32

        /// Minimum extraction version written to local and central records.
        let versionNeeded: UInt16
    }

    /**
     Serializes ordered entries as a single-disk classic ZIP fixture.

     - Parameter entries: Local and central entries in desired Android stream order.
     - Returns: Complete archive and payload offsets.
     - Side effects: Allocates and frees compression buffers for deflated entries.
     - Throws: Fixture construction errors for non-UTF-8/oversized names or compression failure.
     */
    static func make(entries: [Entry]) throws -> Archive {
        guard entries.count <= Int(UInt16.max) else {
            throw ZipArchiveReaderError.invalidArchive("Fixture has too many entries")
        }
        var archive = Data()
        var payloadOffsets: [Int] = []
        var serializedEntries: [SerializedEntry] = []

        for entry in entries {
            let centralName = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            guard !centralName.isEmpty,
                  centralName.count <= Int(UInt16.max),
                  !localName.isEmpty,
                  localName.count <= Int(UInt16.max) else {
                throw ZipArchiveReaderError.invalidArchive("Fixture entry name is invalid")
            }
            let compressedData: Data
            let method: UInt16
            switch entry.compression {
            case .stored:
                compressedData = entry.data
                method = 0
            case .deflated:
                compressedData = try rawDeflate(entry.data)
                method = 8
            }
            guard compressedData.count <= Int(UInt32.max),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw ZipArchiveReaderError.invalidArchive("Fixture entry exceeds classic ZIP limits")
            }

            let localHeaderOffset = archive.count
            let checksum = fixtureCRC32(entry.data)
            var localExtra = Data()
            let versionNeeded: UInt16
            let localCompressedSize: UInt32
            let localExpandedSize: UInt32
            if entry.forceLocalZIP64 {
                versionNeeded = 45
                localCompressedSize = .max
                localExpandedSize = .max
                appendUInt16(0x0001, to: &localExtra)
                appendUInt16(16, to: &localExtra)
                appendUInt64(UInt64(entry.data.count), to: &localExtra)
                appendUInt64(UInt64(compressedData.count), to: &localExtra)
            } else {
                versionNeeded = 20
                localCompressedSize = UInt32(compressedData.count)
                localExpandedSize = UInt32(entry.data.count)
            }
            appendUInt32(0x0403_4b50, to: &archive)
            appendUInt16(versionNeeded, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(method, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(checksum, to: &archive)
            appendUInt32(localCompressedSize, to: &archive)
            appendUInt32(localExpandedSize, to: &archive)
            appendUInt16(UInt16(localName.count), to: &archive)
            appendUInt16(UInt16(localExtra.count), to: &archive)
            archive.append(localName)
            archive.append(localExtra)
            payloadOffsets.append(archive.count)
            archive.append(compressedData)

            serializedEntries.append(SerializedEntry(
                centralName: centralName,
                compressedData: compressedData,
                expandedByteCount: entry.data.count,
                method: method,
                checksum: checksum,
                localHeaderOffset: localHeaderOffset,
                externalAttributes: entry.externalAttributes,
                versionNeeded: versionNeeded
            ))
        }

        let centralDirectoryOffset = archive.count
        for entry in serializedEntries {
            appendUInt32(0x0201_4b50, to: &archive)
            appendUInt16(0x0314, to: &archive)
            appendUInt16(entry.versionNeeded, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(entry.method, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(entry.checksum, to: &archive)
            appendUInt32(UInt32(entry.compressedData.count), to: &archive)
            appendUInt32(UInt32(entry.expandedByteCount), to: &archive)
            appendUInt16(UInt16(entry.centralName.count), to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(entry.externalAttributes, to: &archive)
            appendUInt32(UInt32(entry.localHeaderOffset), to: &archive)
            archive.append(entry.centralName)
        }

        let centralDirectorySize = archive.count - centralDirectoryOffset
        appendUInt32(0x0605_4b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt32(UInt32(centralDirectorySize), to: &archive)
        appendUInt32(UInt32(centralDirectoryOffset), to: &archive)
        appendUInt16(0, to: &archive)
        return Archive(
            data: archive,
            payloadOffsets: payloadOffsets,
            centralDirectoryOffset: centralDirectoryOffset,
            centralDirectoryByteCount: centralDirectorySize,
            entryCount: entries.count
        )
    }

    /**
     Compresses fixture bytes and strips gzip framing to obtain ZIP method-8 raw deflate.

     - Parameter data: Expanded fixture payload.
     - Returns: Raw-deflate bytes.
     - Side effects: Allocates and releases a C compression buffer.
     - Throws: `ZipArchiveReaderError` when compression fails or framing is malformed.
     */
    private static func rawDeflate(_ data: Data) throws -> Data {
        let gzipData = try data.withUnsafeBytes { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else {
                throw ZipArchiveReaderError.invalidArchive("Fixture compression failed")
            }
            var outputLength: UInt = 0
            guard let output = gzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw ZipArchiveReaderError.invalidArchive("Fixture compression failed")
            }
            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
        guard gzipData.count > 18 else {
            throw ZipArchiveReaderError.invalidArchive("Fixture gzip framing is malformed")
        }
        return Data(gzipData.dropFirst(10).dropLast(8))
    }

    /**
     Computes ZIP's reflected CRC32 independently of production implementation.

     - Parameter data: Expanded fixture payload.
     - Returns: Finalized CRC32.
     - Side effects: none.
     - Failure modes: This deterministic operation cannot fail.
     */
    private static func fixtureCRC32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xffff_ffff
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = checksum & 1 == 1
                    ? (checksum >> 1) ^ 0xedb8_8320
                    : checksum >> 1
            }
        }
        return checksum ^ 0xffff_ffff
    }

    /**
     Appends one little-endian 16-bit integer to fixture bytes.

     - Parameters:
       - value: Integer to encode.
       - data: Destination bytes mutated in place.
     - Side effects: Appends two bytes to `data`.
     - Failure modes: This operation cannot fail.
     */
    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    /**
     Appends one little-endian 32-bit integer to fixture bytes.

     - Parameters:
       - value: Integer to encode.
       - data: Destination bytes mutated in place.
     - Side effects: Appends four bytes to `data`.
     - Failure modes: This operation cannot fail.
     */
    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    /**
     Appends one little-endian 64-bit integer to fixture bytes.

     - Parameters:
       - value: Integer to encode.
       - data: Destination bytes mutated in place.
     - Side effects: Appends eight bytes to `data`.
     - Failure modes: This operation cannot fail.
     */
    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}
