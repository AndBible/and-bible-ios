// AndroidBookmarkSnapshotMergeService.swift -- Timestamp-aware Android bookmark Import merge

import Foundation

/**
 Errors raised while applying Android row-level import metadata to bookmark snapshots.
 */
enum AndroidBookmarkSnapshotMergeError: Error, Equatable {
    /// An accepted Android `UPSERT` log row had no corresponding content row in the backup.
    case missingUpsertRow(table: String, entityID1: UUID, entityID2: UUID?)

    /// An Android bookmark log identifier was not a UUID-shaped BLOB or UUID string.
    case invalidLogIdentifier(table: String, field: String)

    /// A snapshot contained multiple rows for one Android fixed-label name.
    case duplicateFixedLabels([String])
}

/**
 Merges Android bookmark backup snapshots using Android's strict `LogEntry` timestamp rule.

 Imported log rows win only when the local key is absent or the imported timestamp is strictly
 greater. Equal timestamps keep local data. Full backups can legitimately contain rows without log
 metadata, so those rows retain Android Import's add-missing behavior; duplicate bookmark parent
 rows additionally use `lastUpdatedOn` as the only safe fallback. Notes, links, labels, and StudyPad
 rows without log evidence remain local-first.
 */
struct AndroidBookmarkSnapshotMergeService {
    private struct LogKey: Hashable {
        let tableName: String
        let entityID1: String
        let entityID2: String
    }

    /**
     Merges one imported Android snapshot into the current local snapshot.

     - Parameters:
       - local: Current iOS rows projected into Android form, including preserved row logs.
       - imported: Android backup rows and row logs.
     - Returns: Deterministic merged snapshot in Android's fixed-label identifier space.
     - Side effects: none.
     - Failure modes:
       - throws `missingUpsertRow` when accepted log metadata references absent patch content
       - throws `invalidLogIdentifier` when a bookmark log key cannot be decoded as an Android ID
     */
    func merge(
        local: RemoteSyncAndroidBookmarkSnapshot,
        imported: RemoteSyncAndroidBookmarkSnapshot
    ) throws -> RemoteSyncAndroidBookmarkSnapshot {
        let local = try canonicalized(local)
        let imported = try canonicalized(imported)
        let localLogs = logsByKey(local.logEntries)
        let importedLogs = logsByKey(imported.logEntries)

        var labelsByID = Dictionary(uniqueKeysWithValues: local.labels.map { ($0.id, $0) })
        for row in imported.labels where labelsByID[row.id] == nil && shouldSeedImportedRow(
            table: "Label",
            id1: row.id,
            localLogs: localLogs,
            importedLogs: importedLogs
        ) {
            labelsByID[row.id] = row
        }

        var bibleByID = Dictionary(uniqueKeysWithValues: local.bibleBookmarks.map { ($0.id, $0) })
        for row in imported.bibleBookmarks {
            guard let current = bibleByID[row.id] else {
                if shouldSeedImportedRow(
                    table: "BibleBookmark",
                    id1: row.id,
                    localLogs: localLogs,
                    importedLogs: importedLogs
                ) {
                    bibleByID[row.id] = row
                }
                continue
            }
            var merged = current
            if importedLogs[logKey(table: "BibleBookmark", id1: row.id)] == nil,
               row.lastUpdatedOn > current.lastUpdatedOn {
                merged = replacingBibleParent(with: row, preservingChildrenFrom: current)
            }
            if merged.notes == nil,
               row.notes != nil,
               shouldSeedImportedRow(
                   table: "BibleBookmarkNotes",
                   id1: row.id,
                   localLogs: localLogs,
                   importedLogs: importedLogs
               ) {
                merged = replacingBibleNote(in: merged, from: row)
            }
            let acceptedImportedLinks = row.labelLinks.filter { link in
                shouldSeedImportedRow(
                    table: "BibleBookmarkToLabel",
                    id1: row.id,
                    id2: link.labelID,
                    localLogs: localLogs,
                    importedLogs: importedLogs
                )
            }
            merged = replacingBibleLinks(
                in: merged,
                with: unionLinks(local: merged.labelLinks, imported: acceptedImportedLinks)
            )
            bibleByID[row.id] = merged
        }

        var genericByID = Dictionary(uniqueKeysWithValues: local.genericBookmarks.map { ($0.id, $0) })
        for row in imported.genericBookmarks {
            guard let current = genericByID[row.id] else {
                if shouldSeedImportedRow(
                    table: "GenericBookmark",
                    id1: row.id,
                    localLogs: localLogs,
                    importedLogs: importedLogs
                ) {
                    genericByID[row.id] = row
                }
                continue
            }
            var merged = current
            if importedLogs[logKey(table: "GenericBookmark", id1: row.id)] == nil,
               row.lastUpdatedOn > current.lastUpdatedOn {
                merged = replacingGenericParent(with: row, preservingChildrenFrom: current)
            }
            if merged.notes == nil,
               row.notes != nil,
               shouldSeedImportedRow(
                   table: "GenericBookmarkNotes",
                   id1: row.id,
                   localLogs: localLogs,
                   importedLogs: importedLogs
               ) {
                merged = replacingGenericNote(in: merged, from: row)
            }
            let acceptedImportedLinks = row.labelLinks.filter { link in
                shouldSeedImportedRow(
                    table: "GenericBookmarkToLabel",
                    id1: row.id,
                    id2: link.labelID,
                    localLogs: localLogs,
                    importedLogs: importedLogs
                )
            }
            merged = replacingGenericLinks(
                in: merged,
                with: unionLinks(local: merged.labelLinks, imported: acceptedImportedLinks)
            )
            genericByID[row.id] = merged
        }

        var studyPadByID = Dictionary(uniqueKeysWithValues: local.studyPadEntries.map { ($0.id, $0) })
        for row in imported.studyPadEntries {
            guard let current = studyPadByID[row.id] else {
                guard shouldSeedImportedRow(
                    table: "StudyPadTextEntry",
                    id1: row.id,
                    localLogs: localLogs,
                    importedLogs: importedLogs
                ) else {
                    continue
                }
                let acceptedText = shouldSeedImportedRow(
                    table: "StudyPadTextEntryText",
                    id1: row.id,
                    localLogs: localLogs,
                    importedLogs: importedLogs
                ) ? row.text : nil
                studyPadByID[row.id] = replacingStudyPadText(in: row, with: acceptedText)
                continue
            }
            if current.text == nil,
               row.text != nil,
               shouldSeedImportedRow(
                   table: "StudyPadTextEntryText",
                   id1: row.id,
                   localLogs: localLogs,
                   importedLogs: importedLogs
               ) {
                studyPadByID[row.id] = replacingStudyPadText(in: current, with: row.text)
            }
        }

        let importedLabels = Dictionary(uniqueKeysWithValues: imported.labels.map { ($0.id, $0) })
        let importedBible = Dictionary(uniqueKeysWithValues: imported.bibleBookmarks.map { ($0.id, $0) })
        let importedGeneric = Dictionary(uniqueKeysWithValues: imported.genericBookmarks.map { ($0.id, $0) })
        let importedStudyPad = Dictionary(uniqueKeysWithValues: imported.studyPadEntries.map { ($0.id, $0) })

        let acceptedLogs = importedLogs.values.filter { entry in
            let key = logKey(entry)
            guard let localEntry = localLogs[key] else { return true }
            return entry.lastUpdated > localEntry.lastUpdated
        }.sorted(by: logSort)

        for entry in acceptedLogs {
            let id1 = try uuid(from: entry.entityID1, table: entry.tableName, field: "entityId1")
            switch entry.tableName {
            case "Label":
                if entry.type == .delete {
                    labelsByID.removeValue(forKey: id1)
                } else {
                    guard let row = importedLabels[id1] else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: nil
                        )
                    }
                    labelsByID[id1] = row
                }
            case "BibleBookmark":
                if entry.type == .delete {
                    bibleByID.removeValue(forKey: id1)
                } else {
                    guard let row = importedBible[id1] else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: nil
                        )
                    }
                    bibleByID[id1] = replacingBibleParent(
                        with: row,
                        preservingChildrenFrom: bibleByID[id1] ?? row
                    )
                }
            case "BibleBookmarkNotes":
                guard var current = bibleByID[id1] else { continue }
                if entry.type == .delete {
                    current = clearingBibleNote(in: current)
                } else {
                    guard let row = importedBible[id1], row.notes != nil else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: nil
                        )
                    }
                    current = replacingBibleNote(in: current, from: row)
                }
                bibleByID[id1] = current
            case "BibleBookmarkToLabel":
                let id2 = try uuid(from: entry.entityID2, table: entry.tableName, field: "entityId2")
                guard var current = bibleByID[id1] else { continue }
                var links = Dictionary(uniqueKeysWithValues: current.labelLinks.map { ($0.labelID, $0) })
                if entry.type == .delete {
                    links.removeValue(forKey: id2)
                } else {
                    guard let link = importedBible[id1]?.labelLinks.first(where: { $0.labelID == id2 }) else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: id2
                        )
                    }
                    links[id2] = link
                }
                current = replacingBibleLinks(in: current, with: sortedLinks(links.values))
                bibleByID[id1] = current
            case "GenericBookmark":
                if entry.type == .delete {
                    genericByID.removeValue(forKey: id1)
                } else {
                    guard let row = importedGeneric[id1] else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: nil
                        )
                    }
                    genericByID[id1] = replacingGenericParent(
                        with: row,
                        preservingChildrenFrom: genericByID[id1] ?? row
                    )
                }
            case "GenericBookmarkNotes":
                guard var current = genericByID[id1] else { continue }
                if entry.type == .delete {
                    current = clearingGenericNote(in: current)
                } else {
                    guard let row = importedGeneric[id1], row.notes != nil else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: nil
                        )
                    }
                    current = replacingGenericNote(in: current, from: row)
                }
                genericByID[id1] = current
            case "GenericBookmarkToLabel":
                let id2 = try uuid(from: entry.entityID2, table: entry.tableName, field: "entityId2")
                guard var current = genericByID[id1] else { continue }
                var links = Dictionary(uniqueKeysWithValues: current.labelLinks.map { ($0.labelID, $0) })
                if entry.type == .delete {
                    links.removeValue(forKey: id2)
                } else {
                    guard let link = importedGeneric[id1]?.labelLinks.first(where: { $0.labelID == id2 }) else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: id2
                        )
                    }
                    links[id2] = link
                }
                current = replacingGenericLinks(in: current, with: sortedLinks(links.values))
                genericByID[id1] = current
            case "StudyPadTextEntry":
                if entry.type == .delete {
                    studyPadByID.removeValue(forKey: id1)
                } else {
                    guard let row = importedStudyPad[id1] else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: nil
                        )
                    }
                    let preservedText: String?
                    if let current = studyPadByID[id1] {
                        preservedText = current.text
                    } else {
                        preservedText = row.text
                    }
                    studyPadByID[id1] = replacingStudyPadParent(
                        with: row,
                        preservingText: preservedText
                    )
                }
            case "StudyPadTextEntryText":
                guard let current = studyPadByID[id1] else { continue }
                if entry.type == .delete {
                    studyPadByID[id1] = replacingStudyPadText(in: current, with: nil)
                } else {
                    guard let text = importedStudyPad[id1]?.text else {
                        throw AndroidBookmarkSnapshotMergeError.missingUpsertRow(
                            table: entry.tableName,
                            entityID1: id1,
                            entityID2: nil
                        )
                    }
                    studyPadByID[id1] = replacingStudyPadText(in: current, with: text)
                }
            default:
                continue
            }
        }

        let validLabelIDs = Set(labelsByID.keys)
        bibleByID = bibleByID.mapValues { row in
            let primaryLabelID = row.primaryLabelID.flatMap { validLabelIDs.contains($0) ? $0 : nil }
            let links = row.labelLinks.filter { validLabelIDs.contains($0.labelID) }
            return replacingBibleReferences(in: row, primaryLabelID: primaryLabelID, links: links)
        }
        genericByID = genericByID.mapValues { row in
            let primaryLabelID = row.primaryLabelID.flatMap { validLabelIDs.contains($0) ? $0 : nil }
            let links = row.labelLinks.filter { validLabelIDs.contains($0.labelID) }
            return replacingGenericReferences(in: row, primaryLabelID: primaryLabelID, links: links)
        }
        studyPadByID = studyPadByID.filter { validLabelIDs.contains($0.value.labelID) }

        var mergedLogs = localLogs
        for entry in acceptedLogs {
            mergedLogs[logKey(entry)] = entry
        }
        return RemoteSyncAndroidBookmarkSnapshot(
            labels: labelsByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            bibleBookmarks: bibleByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            genericBookmarks: genericByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            studyPadEntries: studyPadByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            logEntries: mergedLogs.values.sorted(by: logSort)
        )
    }

    /**
     Moves fixed labels and all of their references into Android's canonical identifier space.

     - Parameter snapshot: Local or imported Android-shaped bookmark rows.
     - Returns: Snapshot whose fixed-label rows, links, and log keys use Android v12 identifiers.
     - Side effects: none.
     - Failure modes: Throws `duplicateFixedLabels` instead of collapsing two reserved rows and
       silently discarding one row's style or relationship data.
     */
    private func canonicalized(
        _ snapshot: RemoteSyncAndroidBookmarkSnapshot
    ) throws -> RemoteSyncAndroidBookmarkSnapshot {
        let duplicateFixedNames = Dictionary(grouping: snapshot.labels, by: \.name)
            .filter { AndroidBookmarkDatabaseContract.fixedLabelID(forName: $0.key) != nil && $0.value.count > 1 }
            .map(\.key)
            .sorted()
        guard duplicateFixedNames.isEmpty else {
            throw AndroidBookmarkSnapshotMergeError.duplicateFixedLabels(duplicateFixedNames)
        }
        let labelIDMap = Dictionary(uniqueKeysWithValues: snapshot.labels.map { row in
            (row.id, AndroidBookmarkDatabaseContract.fixedLabelID(forName: row.name) ?? row.id)
        })
        let labels = snapshot.labels.map { row in
            RemoteSyncAndroidLabel(
                id: labelIDMap[row.id] ?? row.id,
                name: row.name,
                color: row.color,
                markerStyle: row.markerStyle,
                markerStyleWholeVerse: row.markerStyleWholeVerse,
                underlineStyle: row.underlineStyle,
                underlineStyleWholeVerse: row.underlineStyleWholeVerse,
                hideStyle: row.hideStyle,
                hideStyleWholeVerse: row.hideStyleWholeVerse,
                favourite: row.favourite,
                type: row.type,
                customIcon: row.customIcon
            )
        }
        let uniqueLabels = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) }).values
        return RemoteSyncAndroidBookmarkSnapshot(
            labels: uniqueLabels.sorted { $0.id.uuidString < $1.id.uuidString },
            bibleBookmarks: snapshot.bibleBookmarks.map { remappingLabels(in: $0, using: labelIDMap) },
            genericBookmarks: snapshot.genericBookmarks.map { remappingLabels(in: $0, using: labelIDMap) },
            studyPadEntries: snapshot.studyPadEntries.map { row in
                RemoteSyncAndroidStudyPadEntry(
                    id: row.id,
                    labelID: labelIDMap[row.labelID] ?? row.labelID,
                    orderNumber: row.orderNumber,
                    indentLevel: row.indentLevel,
                    contentType: row.contentType,
                    sourcePromptId: row.sourcePromptId,
                    text: row.text
                )
            },
            logEntries: snapshot.logEntries.map { remappingLabels(in: $0, using: labelIDMap) }
        )
    }

    private func remappingLabels(
        in row: RemoteSyncAndroidBibleBookmark,
        using labelIDMap: [UUID: UUID]
    ) -> RemoteSyncAndroidBibleBookmark {
        replacingBibleReferences(
            in: row,
            primaryLabelID: row.primaryLabelID.map { labelIDMap[$0] ?? $0 },
            links: row.labelLinks.map {
                RemoteSyncAndroidBookmarkLabelLink(
                    labelID: labelIDMap[$0.labelID] ?? $0.labelID,
                    orderNumber: $0.orderNumber,
                    indentLevel: $0.indentLevel,
                    expandContent: $0.expandContent
                )
            }
        )
    }

    private func remappingLabels(
        in row: RemoteSyncAndroidGenericBookmark,
        using labelIDMap: [UUID: UUID]
    ) -> RemoteSyncAndroidGenericBookmark {
        replacingGenericReferences(
            in: row,
            primaryLabelID: row.primaryLabelID.map { labelIDMap[$0] ?? $0 },
            links: row.labelLinks.map {
                RemoteSyncAndroidBookmarkLabelLink(
                    labelID: labelIDMap[$0.labelID] ?? $0.labelID,
                    orderNumber: $0.orderNumber,
                    indentLevel: $0.indentLevel,
                    expandContent: $0.expandContent
                )
            }
        )
    }

    private func remappingLabels(
        in entry: RemoteSyncLogEntry,
        using labelIDMap: [UUID: UUID]
    ) -> RemoteSyncLogEntry {
        let entry = AndroidBookmarkDatabaseContract.normalizedLogEntry(entry)
        var entityID1 = entry.entityID1
        var entityID2 = entry.entityID2
        if entry.tableName == "Label", let id = try? uuid(from: entityID1, table: entry.tableName, field: "entityId1") {
            entityID1 = idValue(labelIDMap[id] ?? id)
        }
        if ["BibleBookmarkToLabel", "GenericBookmarkToLabel"].contains(entry.tableName),
           let id = try? uuid(from: entityID2, table: entry.tableName, field: "entityId2") {
            entityID2 = idValue(labelIDMap[id] ?? id)
        }
        return RemoteSyncLogEntry(
            tableName: entry.tableName,
            entityID1: entityID1,
            entityID2: entityID2,
            type: entry.type,
            lastUpdated: entry.lastUpdated,
            sourceDevice: entry.sourceDevice
        )
    }

    private func shouldSeedImportedRow(
        table: String,
        id1: UUID,
        id2: UUID? = nil,
        localLogs: [LogKey: RemoteSyncLogEntry],
        importedLogs: [LogKey: RemoteSyncLogEntry]
    ) -> Bool {
        let key = logKey(table: table, id1: id1, id2: id2)
        guard let importedEntry = importedLogs[key] else {
            return true
        }
        guard importedEntry.type == .upsert else {
            return false
        }
        guard let localEntry = localLogs[key] else {
            return true
        }
        return importedEntry.lastUpdated > localEntry.lastUpdated
    }

    private func logsByKey(_ entries: [RemoteSyncLogEntry]) -> [LogKey: RemoteSyncLogEntry] {
        var result: [LogKey: RemoteSyncLogEntry] = [:]
        for rawEntry in entries {
            let entry = AndroidBookmarkDatabaseContract.normalizedLogEntry(rawEntry)
            let key = logKey(entry)
            if (result[key]?.lastUpdated ?? .min) <= entry.lastUpdated {
                result[key] = entry
            }
        }
        return result
    }

    private func logKey(table: String, id1: UUID, id2: UUID? = nil) -> LogKey {
        logKey(
            RemoteSyncLogEntry(
                tableName: table,
                entityID1: idValue(id1),
                entityID2: id2.map(idValue) ?? AndroidBookmarkDatabaseContract.emptySecondaryEntityID,
                type: .upsert,
                lastUpdated: 0,
                sourceDevice: ""
            )
        )
    }

    private func logKey(_ rawEntry: RemoteSyncLogEntry) -> LogKey {
        let entry = AndroidBookmarkDatabaseContract.normalizedLogEntry(rawEntry)
        return LogKey(
            tableName: entry.tableName,
            entityID1: scalarKey(entry.entityID1),
            entityID2: scalarKey(entry.entityID2)
        )
    }

    private func scalarKey(_ value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            "null:"
        case .integer:
            "integer:\(value.integerValue ?? 0)"
        case .real:
            "real:\(value.realValue?.bitPattern ?? 0)"
        case .text:
            "text:\(Data((value.textValue ?? "").utf8).base64EncodedString())"
        case .blob:
            "blob:\(value.blobBase64Value ?? "")"
        }
    }

    private func idValue(_ id: UUID) -> RemoteSyncSQLiteValue {
        .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(id))
    }

    private func uuid(
        from value: RemoteSyncSQLiteValue,
        table: String,
        field: String
    ) throws -> UUID {
        if value.kind == .text, let text = value.textValue, let id = UUID(uuidString: text) {
            return id
        }
        guard value.kind == .blob, let data = value.blobData, data.count == 16 else {
            throw AndroidBookmarkSnapshotMergeError.invalidLogIdentifier(table: table, field: field)
        }
        let bytes = Array(data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func replacingBibleParent(
        with row: RemoteSyncAndroidBibleBookmark,
        preservingChildrenFrom existing: RemoteSyncAndroidBibleBookmark
    ) -> RemoteSyncAndroidBibleBookmark {
        RemoteSyncAndroidBibleBookmark(
            id: row.id,
            kjvOrdinalStart: row.kjvOrdinalStart,
            kjvOrdinalEnd: row.kjvOrdinalEnd,
            ordinalStart: row.ordinalStart,
            ordinalEnd: row.ordinalEnd,
            v11n: row.v11n,
            playbackSettingsJSON: row.playbackSettingsJSON,
            createdAt: row.createdAt,
            book: row.book,
            startOffset: row.startOffset,
            endOffset: row.endOffset,
            primaryLabelID: row.primaryLabelID,
            notes: existing.notes,
            notesContentType: existing.notesContentType,
            lastUpdatedOn: row.lastUpdatedOn,
            wholeVerse: row.wholeVerse,
            type: row.type,
            customIcon: row.customIcon,
            sourcePromptId: row.sourcePromptId,
            notesSourcePromptId: existing.notesSourcePromptId,
            editAction: row.editAction,
            labelLinks: existing.labelLinks,
            ordinalTrustMetadata: row.ordinalTrustMetadata
        )
    }

    private func replacingGenericParent(
        with row: RemoteSyncAndroidGenericBookmark,
        preservingChildrenFrom existing: RemoteSyncAndroidGenericBookmark
    ) -> RemoteSyncAndroidGenericBookmark {
        RemoteSyncAndroidGenericBookmark(
            id: row.id,
            key: row.key,
            createdAt: row.createdAt,
            bookInitials: row.bookInitials,
            ordinalStart: row.ordinalStart,
            ordinalEnd: row.ordinalEnd,
            startOffset: row.startOffset,
            endOffset: row.endOffset,
            primaryLabelID: row.primaryLabelID,
            notes: existing.notes,
            notesContentType: existing.notesContentType,
            lastUpdatedOn: row.lastUpdatedOn,
            wholeVerse: row.wholeVerse,
            playbackSettingsJSON: row.playbackSettingsJSON,
            customIcon: row.customIcon,
            sourcePromptId: row.sourcePromptId,
            notesSourcePromptId: existing.notesSourcePromptId,
            editAction: row.editAction,
            labelLinks: existing.labelLinks
        )
    }

    private func replacingBibleNote(
        in row: RemoteSyncAndroidBibleBookmark,
        from noteRow: RemoteSyncAndroidBibleBookmark
    ) -> RemoteSyncAndroidBibleBookmark {
        replacingBibleChildren(
            in: row,
            notes: noteRow.notes,
            notesContentType: noteRow.notesContentType,
            notesSourcePromptId: noteRow.notesSourcePromptId,
            links: row.labelLinks
        )
    }

    private func clearingBibleNote(in row: RemoteSyncAndroidBibleBookmark) -> RemoteSyncAndroidBibleBookmark {
        replacingBibleChildren(in: row, notes: nil, notesContentType: nil, notesSourcePromptId: nil, links: row.labelLinks)
    }

    private func replacingBibleLinks(
        in row: RemoteSyncAndroidBibleBookmark,
        with links: [RemoteSyncAndroidBookmarkLabelLink]
    ) -> RemoteSyncAndroidBibleBookmark {
        replacingBibleChildren(
            in: row,
            notes: row.notes,
            notesContentType: row.notesContentType,
            notesSourcePromptId: row.notesSourcePromptId,
            links: links
        )
    }

    private func replacingBibleChildren(
        in row: RemoteSyncAndroidBibleBookmark,
        notes: String?,
        notesContentType: String?,
        notesSourcePromptId: UUID?,
        links: [RemoteSyncAndroidBookmarkLabelLink]
    ) -> RemoteSyncAndroidBibleBookmark {
        RemoteSyncAndroidBibleBookmark(
            id: row.id,
            kjvOrdinalStart: row.kjvOrdinalStart,
            kjvOrdinalEnd: row.kjvOrdinalEnd,
            ordinalStart: row.ordinalStart,
            ordinalEnd: row.ordinalEnd,
            v11n: row.v11n,
            playbackSettingsJSON: row.playbackSettingsJSON,
            createdAt: row.createdAt,
            book: row.book,
            startOffset: row.startOffset,
            endOffset: row.endOffset,
            primaryLabelID: row.primaryLabelID,
            notes: notes,
            notesContentType: notesContentType,
            lastUpdatedOn: row.lastUpdatedOn,
            wholeVerse: row.wholeVerse,
            type: row.type,
            customIcon: row.customIcon,
            sourcePromptId: row.sourcePromptId,
            notesSourcePromptId: notesSourcePromptId,
            editAction: row.editAction,
            labelLinks: sortedLinks(links),
            ordinalTrustMetadata: row.ordinalTrustMetadata
        )
    }

    private func replacingBibleReferences(
        in row: RemoteSyncAndroidBibleBookmark,
        primaryLabelID: UUID?,
        links: [RemoteSyncAndroidBookmarkLabelLink]
    ) -> RemoteSyncAndroidBibleBookmark {
        let base = RemoteSyncAndroidBibleBookmark(
            id: row.id,
            kjvOrdinalStart: row.kjvOrdinalStart,
            kjvOrdinalEnd: row.kjvOrdinalEnd,
            ordinalStart: row.ordinalStart,
            ordinalEnd: row.ordinalEnd,
            v11n: row.v11n,
            playbackSettingsJSON: row.playbackSettingsJSON,
            createdAt: row.createdAt,
            book: row.book,
            startOffset: row.startOffset,
            endOffset: row.endOffset,
            primaryLabelID: primaryLabelID,
            notes: row.notes,
            notesContentType: row.notesContentType,
            lastUpdatedOn: row.lastUpdatedOn,
            wholeVerse: row.wholeVerse,
            type: row.type,
            customIcon: row.customIcon,
            sourcePromptId: row.sourcePromptId,
            notesSourcePromptId: row.notesSourcePromptId,
            editAction: row.editAction,
            labelLinks: sortedLinks(links),
            ordinalTrustMetadata: row.ordinalTrustMetadata
        )
        return base
    }

    private func replacingGenericNote(
        in row: RemoteSyncAndroidGenericBookmark,
        from noteRow: RemoteSyncAndroidGenericBookmark
    ) -> RemoteSyncAndroidGenericBookmark {
        replacingGenericChildren(
            in: row,
            notes: noteRow.notes,
            notesContentType: noteRow.notesContentType,
            notesSourcePromptId: noteRow.notesSourcePromptId,
            links: row.labelLinks
        )
    }

    private func clearingGenericNote(in row: RemoteSyncAndroidGenericBookmark) -> RemoteSyncAndroidGenericBookmark {
        replacingGenericChildren(in: row, notes: nil, notesContentType: nil, notesSourcePromptId: nil, links: row.labelLinks)
    }

    private func replacingGenericLinks(
        in row: RemoteSyncAndroidGenericBookmark,
        with links: [RemoteSyncAndroidBookmarkLabelLink]
    ) -> RemoteSyncAndroidGenericBookmark {
        replacingGenericChildren(
            in: row,
            notes: row.notes,
            notesContentType: row.notesContentType,
            notesSourcePromptId: row.notesSourcePromptId,
            links: links
        )
    }

    private func replacingGenericChildren(
        in row: RemoteSyncAndroidGenericBookmark,
        notes: String?,
        notesContentType: String?,
        notesSourcePromptId: UUID?,
        links: [RemoteSyncAndroidBookmarkLabelLink]
    ) -> RemoteSyncAndroidGenericBookmark {
        RemoteSyncAndroidGenericBookmark(
            id: row.id,
            key: row.key,
            createdAt: row.createdAt,
            bookInitials: row.bookInitials,
            ordinalStart: row.ordinalStart,
            ordinalEnd: row.ordinalEnd,
            startOffset: row.startOffset,
            endOffset: row.endOffset,
            primaryLabelID: row.primaryLabelID,
            notes: notes,
            notesContentType: notesContentType,
            lastUpdatedOn: row.lastUpdatedOn,
            wholeVerse: row.wholeVerse,
            playbackSettingsJSON: row.playbackSettingsJSON,
            customIcon: row.customIcon,
            sourcePromptId: row.sourcePromptId,
            notesSourcePromptId: notesSourcePromptId,
            editAction: row.editAction,
            labelLinks: sortedLinks(links)
        )
    }

    private func replacingGenericReferences(
        in row: RemoteSyncAndroidGenericBookmark,
        primaryLabelID: UUID?,
        links: [RemoteSyncAndroidBookmarkLabelLink]
    ) -> RemoteSyncAndroidGenericBookmark {
        RemoteSyncAndroidGenericBookmark(
            id: row.id,
            key: row.key,
            createdAt: row.createdAt,
            bookInitials: row.bookInitials,
            ordinalStart: row.ordinalStart,
            ordinalEnd: row.ordinalEnd,
            startOffset: row.startOffset,
            endOffset: row.endOffset,
            primaryLabelID: primaryLabelID,
            notes: row.notes,
            notesContentType: row.notesContentType,
            lastUpdatedOn: row.lastUpdatedOn,
            wholeVerse: row.wholeVerse,
            playbackSettingsJSON: row.playbackSettingsJSON,
            customIcon: row.customIcon,
            sourcePromptId: row.sourcePromptId,
            notesSourcePromptId: row.notesSourcePromptId,
            editAction: row.editAction,
            labelLinks: sortedLinks(links)
        )
    }

    private func replacingStudyPadParent(
        with row: RemoteSyncAndroidStudyPadEntry,
        preservingText text: String?
    ) -> RemoteSyncAndroidStudyPadEntry {
        RemoteSyncAndroidStudyPadEntry(
            id: row.id,
            labelID: row.labelID,
            orderNumber: row.orderNumber,
            indentLevel: row.indentLevel,
            contentType: row.contentType,
            sourcePromptId: row.sourcePromptId,
            text: text
        )
    }

    private func replacingStudyPadText(
        in row: RemoteSyncAndroidStudyPadEntry,
        with text: String?
    ) -> RemoteSyncAndroidStudyPadEntry {
        RemoteSyncAndroidStudyPadEntry(
            id: row.id,
            labelID: row.labelID,
            orderNumber: row.orderNumber,
            indentLevel: row.indentLevel,
            contentType: row.contentType,
            sourcePromptId: row.sourcePromptId,
            text: text
        )
    }

    private func unionLinks(
        local: [RemoteSyncAndroidBookmarkLabelLink],
        imported: [RemoteSyncAndroidBookmarkLabelLink]
    ) -> [RemoteSyncAndroidBookmarkLabelLink] {
        var rows = Dictionary(uniqueKeysWithValues: local.map { ($0.labelID, $0) })
        for row in imported where rows[row.labelID] == nil {
            rows[row.labelID] = row
        }
        return sortedLinks(rows.values)
    }

    private func sortedLinks<S: Sequence>(_ links: S) -> [RemoteSyncAndroidBookmarkLabelLink]
    where S.Element == RemoteSyncAndroidBookmarkLabelLink {
        links.sorted {
            if $0.orderNumber == $1.orderNumber {
                return $0.labelID.uuidString < $1.labelID.uuidString
            }
            return $0.orderNumber < $1.orderNumber
        }
    }

    private func logSort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated < rhs.lastUpdated }
        let left = logKey(lhs)
        let right = logKey(rhs)
        if left.tableName != right.tableName { return left.tableName < right.tableName }
        if left.entityID1 != right.entityID1 { return left.entityID1 < right.entityID1 }
        return left.entityID2 < right.entityID2
    }
}
