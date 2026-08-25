// BibleReaderStrongsBackendLookupService.swift — exact installed-book dictionary reads

import BibleCore
import Foundation
import SwordKit
import os.log

private let strongsBackendLookupLogger = Logger(
    subsystem: "org.andbible",
    category: "BibleReaderStrongsBackendLookupService"
)

/**
 Performs Android/JSword-compatible dictionary lookup against an already authorized backend.

 The service owns cursor-sensitive SWORD reads, RawLD binary-key resolution, RawGenBook TreeKey
 resolution, and restored MyBible dictionary reads. Installed-book selection and Vue document
 assembly remain outside this boundary so lookup cannot silently substitute another owner.

 - Side effects: Reads SWORD cursor/index state or short-lived SQLite rows. SWORD fragment APIs
 restore their captured cursor state according to their own exact contracts.
 - Failure modes: Missing keys, unrelated nearest keys, malformed payloads, and backend failures
 return `nil`; an Android post-key commentary read failure is retained as a typed payload failure.
 */
enum BibleReaderStrongsBackendLookupService {
    /**
     Resolves the first Android key candidate through one readable SWORD book.

     - Parameters:
       - module: Globally authorized readable SWORD module.
       - keyOptions: Ordered typed Strong's keys or one raw Robinson code.
     - Returns: First JSword-owned record with exact key identity and processed payload inputs.
     - Side effects: Reads/caches dictionary or TreeKey indices and performs cursor-restoring OSIS
       fragment reads. Non-RawLD compatibility inspection uses the module's serialized cursor API.
     - Failure modes: Unsupported drivers, unreadable indices, nearest-key substitutions, and
       malformed payloads fail the affected candidate closed and may return `nil`.
     */
    static func lookupInModule(
        _ module: SwordModule,
        keyOptions: [String]
    ) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult? {
        strongsBackendLookupLogger.info(
            "lookupInModule: \(module.info.name), keyOptions=\(keyOptions)"
        )

        let driver = module.info.moduleDriver
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if driver == "rawgenbook" {
            return lookupInGenBook(module, keyOptions: keyOptions)
        }
        let usesRawLDKeyContract = ["rawld", "rawld4", "zld"].contains(driver)
        let rawLDConfiguration = AndroidJSwordRawLDKeyResolution.Configuration(
            moduleInitials: module.info.name,
            category: module.info.category,
            features: module.info.features,
            caseSensitiveKeys: AndroidJSwordRawLDKeyResolution.javaBoolean(
                module.configEntry("CaseSensitiveKeys")
            ),
            // SwordBookMetaData.DEFAULTS supplies true when this property is absent.
            strongsPadding: module.configEntry("StrongsPadding").map(
                AndroidJSwordRawLDKeyResolution.javaBoolean
            ) ?? true
        )

        let rawLDStoredSlots: [SwordRawDictionaryIndexSlot]?
        if usesRawLDKeyContract {
            rawLDStoredSlots = try? module.loadRawDictionaryIndexSlots()
        } else {
            rawLDStoredSlots = nil
        }

        for key in keyOptions {
            let selectedStoredKey: String?
            let selectedStoredIndex: Int?
            if usesRawLDKeyContract {
                guard let rawLDStoredSlots else { return nil }
                let resolution = AndroidJSwordRawLDKeyResolution.resolve(
                    requestedKey: key,
                    storedSlots: rawLDStoredSlots,
                    configuration: rawLDConfiguration
                )
                selectedStoredKey = resolution?.storedKey
                selectedStoredIndex = resolution?.index
            } else {
                selectedStoredKey = key
                selectedStoredIndex = nil
            }
            guard let selectedStoredKey else { continue }

            if usesRawLDKeyContract {
                guard let selectedStoredIndex else { continue }
                let fragment: SwordRawOSISFragment
                do {
                    fragment = try module.rawDictionaryOSISFragment(
                        forIndex: selectedStoredIndex,
                        storedKey: selectedStoredKey
                    )
                } catch SwordRawOSISFragmentError.missingCommentaryVerse(
                    let key,
                    let keyName,
                    let osisRef
                ) {
                    return .init(
                        actualKey: keyName,
                        osisID: key,
                        osisRef: osisRef,
                        rawEntry: "",
                        renderedText: "",
                        payloadFailure: .keyNotInDocument
                    )
                } catch {
                    continue
                }
                strongsBackendLookupLogger.info(
                    "lookupInModule: tried key='\(key)', actualKey='\(fragment.keyName)', accepted=true, xmlLen=\(fragment.xml.count)"
                )
                return .init(
                    actualKey: fragment.keyName,
                    osisID: fragment.key,
                    osisRef: fragment.osisRef,
                    rawEntry: fragment.originalXML,
                    renderedText: fragment.originalXML,
                    payloadReadyXML: fragment.xml
                )
            }

            let inspection = module.setKeyAndInspect(selectedStoredKey)
            let accepted = inspection.actualKey.utf16.elementsEqual(key.utf16)
            strongsBackendLookupLogger.info(
                "lookupInModule: tried key='\(key)', actualKey='\(inspection.actualKey)', accepted=\(accepted), renderLen=\(inspection.renderedText.count)"
            )
            guard accepted else { continue }
            return .init(
                actualKey: selectedStoredKey,
                rawEntry: inspection.rawEntry,
                renderedText: inspection.renderedText
            )
        }
        return nil
    }

    /**
     Resolves one candidate through pinned `SwordGenBook.getKey` and reads its exact TreeKey.

     - Parameters:
       - module: Readable RawGenBook whose complete key list backs the JSword key map.
       - keyOptions: Ordered Strong's typed families or one raw Robinson code.
     - Returns: First resolved entry with leaf name and distinct full-path OSIS identity.
     - Side effects: Enumerates/caches keys and performs one cursor-restoring raw OSIS read.
     - Failure modes: Enumeration, key-resolution, and OSIS failures fail closed without selecting a
       nearest tree node; Android's missing-commentary-verse outcome is returned as typed failure.
     */
    private static func lookupInGenBook(
        _ module: SwordModule,
        keyOptions: [String]
    ) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult? {
        guard let sourceKeys = try? module.loadAllKeys() else { return nil }
        for key in keyOptions {
            guard let resolution = AndroidJSwordGenBookKeyResolution.resolve(
                candidate: key,
                sourceKeys: sourceKeys
            ) else {
                continue
            }
            let fragment: SwordRawOSISFragment
            do {
                fragment = try module.rawGenBookOSISFragment(
                    forKey: resolution.sourceKey,
                    treeKeyCardinality: resolution.subtreeCardinality
                )
            } catch SwordRawOSISFragmentError.missingCommentaryVerse(
                let sourceKey,
                let keyName,
                let osisRef
            ) {
                return .init(
                    actualKey: keyName,
                    osisID: resolution.osisRef.isEmpty ? sourceKey : resolution.osisRef,
                    osisRef: resolution.osisRef.isEmpty ? osisRef : resolution.osisRef,
                    rawEntry: "",
                    renderedText: "",
                    payloadFailure: .keyNotInDocument
                )
            } catch {
                continue
            }
            return .init(
                actualKey: fragment.keyName,
                osisID: resolution.osisRef,
                osisRef: resolution.osisRef,
                rawEntry: fragment.originalXML,
                renderedText: fragment.originalXML,
                payloadReadyXML: fragment.xml
            )
        }
        return nil
    }

    /**
     Resolves the first exact Android key candidate through a restored MyBible dictionary.

     - Parameters:
       - reader: Validated read-only MyBible dictionary backend.
       - keyOptions: Ordered Android Strong's or Robinson candidates.
       - moduleInitials: Installed initials used by source-specific OSIS compatibility rules.
     - Returns: Exact topic identity plus payload-ready OSIS, or `nil` when no row is processable.
     - Side effects: Opens short-lived SQLite reads and runs one OSIS/anchor pass per exact row.
     - Failure modes: Missing topics and malformed OSIS continue to the next candidate; an exact
       empty definition remains a successful hidden-title-only fragment.
     */
    static func lookupInMyBibleDictionary(
        _ reader: MyBibleReader,
        keyOptions: [String],
        moduleInitials: String? = nil
    ) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult? {
        for key in keyOptions {
            guard let entry = reader.getDictionaryEntry(key: key),
                  let processed = try? SwordOSISFragmentProcessor.processDictionarySource(
                    sourceXML: entry,
                    keyName: key,
                    moduleInitials: moduleInitials
                  ) else {
                continue
            }
            return .init(
                actualKey: key,
                rawEntry: processed.originalXML,
                renderedText: processed.originalXML,
                payloadReadyXML: processed.xml
            )
        }
        return nil
    }
}
