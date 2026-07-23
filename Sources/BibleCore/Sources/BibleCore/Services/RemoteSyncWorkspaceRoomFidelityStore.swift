// RemoteSyncWorkspaceRoomFidelityStore.swift -- Local storage for Android-only workspace Room rows

import Foundation

/** Namespaced settings keys for Android workspace data with no native SwiftData owner. */
private enum RemoteSyncWorkspaceFidelityKeys {
    static let workspaceTextDisplayPrefix = "remote_sync.workspaces.fidelity.workspace_text_display"
    static let pageManagerTextDisplayPrefix = "remote_sync.workspaces.fidelity.page_manager_text_display"
    static let labelOverridePrefix = "remote_sync.workspaces.fidelity.label_override"
    static let globalTextDisplayKey = "remote_sync.workspaces.fidelity.global_text_display"
}

extension RemoteSyncWorkspaceFidelityStore {
    /** One owner-scoped Android-only text-display fidelity row. */
    struct TextDisplayFidelityEntry: Sendable, Equatable {
        let ownerID: UUID
        let fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity
    }

    /** Stored identity and Android-only fields for the global text-display singleton. */
    struct GlobalTextDisplayEntry: Codable, Sendable, Equatable {
        let id: UUID
        let fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity
    }

    /// Raw settings prefix used by strict snapshot validation.
    static let workspaceTextDisplayFidelityPrefix =
        RemoteSyncWorkspaceFidelityKeys.workspaceTextDisplayPrefix

    /// Raw settings prefix used by strict snapshot validation.
    static let pageManagerTextDisplayFidelityPrefix =
        RemoteSyncWorkspaceFidelityKeys.pageManagerTextDisplayPrefix

    /// Raw settings prefix used by strict snapshot validation.
    static let labelOverrideFidelityPrefix = RemoteSyncWorkspaceFidelityKeys.labelOverridePrefix

    /// Exact global singleton fidelity key used by strict snapshot validation.
    static let globalTextDisplayFidelityKey = RemoteSyncWorkspaceFidelityKeys.globalTextDisplayKey

    /** Stores Android-only text-display fields for one workspace row. */
    func setTextDisplayFidelity(
        _ fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity,
        forWorkspaceID workspaceID: UUID
    ) throws {
        try setCodable(
            fidelity,
            key: "\(Self.workspaceTextDisplayFidelityPrefix).\(workspaceID.uuidString.lowercased())"
        )
    }

    /** Reads Android-only text-display fields for one workspace row. */
    func textDisplayFidelity(
        forWorkspaceID workspaceID: UUID
    ) -> RemoteSyncWorkspaceTextDisplaySettingsFidelity? {
        decodeCodable(
            RemoteSyncWorkspaceTextDisplaySettingsFidelity.self,
            key: "\(Self.workspaceTextDisplayFidelityPrefix).\(workspaceID.uuidString.lowercased())"
        )
    }

    /** Reads every valid workspace text-display fidelity row in deterministic order. */
    func allWorkspaceTextDisplayFidelityEntries() -> [TextDisplayFidelityEntry] {
        allTextDisplayFidelityEntries(prefix: Self.workspaceTextDisplayFidelityPrefix)
    }

    /** Removes Android-only text-display fields for one workspace row. */
    func removeTextDisplayFidelity(forWorkspaceID workspaceID: UUID) {
        settingsStore.remove(
            "\(Self.workspaceTextDisplayFidelityPrefix).\(workspaceID.uuidString.lowercased())"
        )
    }

    /** Stores Android-only text-display fields for one page-manager row. */
    func setTextDisplayFidelity(
        _ fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity,
        forPageManagerWindowID windowID: UUID
    ) throws {
        try setCodable(
            fidelity,
            key: "\(Self.pageManagerTextDisplayFidelityPrefix).\(windowID.uuidString.lowercased())"
        )
    }

    /** Reads Android-only text-display fields for one page-manager row. */
    func textDisplayFidelity(
        forPageManagerWindowID windowID: UUID
    ) -> RemoteSyncWorkspaceTextDisplaySettingsFidelity? {
        decodeCodable(
            RemoteSyncWorkspaceTextDisplaySettingsFidelity.self,
            key: "\(Self.pageManagerTextDisplayFidelityPrefix).\(windowID.uuidString.lowercased())"
        )
    }

    /** Reads every valid page-manager text-display fidelity row in deterministic order. */
    func allPageManagerTextDisplayFidelityEntries() -> [TextDisplayFidelityEntry] {
        allTextDisplayFidelityEntries(prefix: Self.pageManagerTextDisplayFidelityPrefix)
    }

    /** Removes Android-only text-display fields for one page-manager row. */
    func removeTextDisplayFidelity(forPageManagerWindowID windowID: UUID) {
        settingsStore.remove(
            "\(Self.pageManagerTextDisplayFidelityPrefix).\(windowID.uuidString.lowercased())"
        )
    }

    /** Stores one complete Android workspace-label override row. */
    func setLabelOverride(_ row: RemoteSyncCurrentWorkspaceLabelOverrideRow) throws {
        try setCodable(row, key: labelOverrideKey(workspaceID: row.workspaceID, labelID: row.labelID))
    }

    /** Reads one validated workspace-label override by its composite Android identity. */
    func labelOverride(
        workspaceID: UUID,
        labelID: UUID
    ) -> RemoteSyncCurrentWorkspaceLabelOverrideRow? {
        let key = labelOverrideKey(workspaceID: workspaceID, labelID: labelID)
        guard let value = settingsStore.getString(key),
              let data = value.data(using: .utf8),
              let row = try? JSONDecoder().decode(RemoteSyncCurrentWorkspaceLabelOverrideRow.self, from: data),
              row.workspaceID == workspaceID,
              row.labelID == labelID else {
            return nil
        }
        return row
    }

    /** Reads every valid workspace-label override in deterministic key order. */
    func allLabelOverrides() -> [RemoteSyncCurrentWorkspaceLabelOverrideRow] {
        settingsStore.entries(withPrefix: Self.labelOverrideFidelityPrefix)
            .sorted { $0.key < $1.key }
            .compactMap { setting in
                guard let data = setting.value.data(using: .utf8),
                      let row = try? JSONDecoder().decode(
                        RemoteSyncCurrentWorkspaceLabelOverrideRow.self,
                        from: data
                      ),
                      setting.key == labelOverrideKey(
                        workspaceID: row.workspaceID,
                        labelID: row.labelID
                      ) else {
                    return nil
                }
                return row
            }
    }

    /** Removes one workspace-label override row. */
    func removeLabelOverride(workspaceID: UUID, labelID: UUID) {
        settingsStore.remove(labelOverrideKey(workspaceID: workspaceID, labelID: labelID))
    }

    /** Removes every label override owned by one workspace. */
    func removeLabelOverrides(forWorkspaceID workspaceID: UUID) {
        let prefix = "\(Self.labelOverrideFidelityPrefix).\(workspaceID.uuidString.lowercased())."
        for setting in settingsStore.entries(withPrefix: prefix) {
            settingsStore.remove(setting.key)
        }
    }

    /** Removes every Android workspace override that references one globally deleted label. */
    func removeLabelOverrides(forLabelID labelID: UUID) {
        let suffix = ".\(labelID.uuidString.lowercased())"
        for setting in settingsStore.entries(withPrefix: "\(Self.labelOverrideFidelityPrefix).")
            where setting.key.hasSuffix(suffix) {
            settingsStore.remove(setting.key)
        }
    }

    /** Stores the Android global singleton identity and its non-native fields. */
    func setGlobalTextDisplayEntry(
        id: UUID,
        fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity
    ) throws {
        try setCodable(
            GlobalTextDisplayEntry(id: id, fidelity: fidelity),
            key: Self.globalTextDisplayFidelityKey
        )
    }

    /** Reads the validated Android global singleton fidelity row. */
    func globalTextDisplayEntry() -> GlobalTextDisplayEntry? {
        decodeCodable(GlobalTextDisplayEntry.self, key: Self.globalTextDisplayFidelityKey)
    }

    /** Removes the Android global singleton fidelity row. */
    func removeGlobalTextDisplayEntry() {
        settingsStore.remove(Self.globalTextDisplayFidelityKey)
    }

    /** Removes every Android Room workspace fidelity row owned by this extension. */
    func clearWorkspaceRoomFidelity() {
        for prefix in [
            Self.workspaceTextDisplayFidelityPrefix,
            Self.pageManagerTextDisplayFidelityPrefix,
            Self.labelOverrideFidelityPrefix,
            Self.globalTextDisplayFidelityKey,
        ] {
            for setting in settingsStore.entries(withPrefix: prefix) {
                settingsStore.remove(setting.key)
            }
        }
    }

    /** Encodes one fidelity value with sorted keys into the local settings table. */
    private func setCodable<Value: Encodable>(_ value: Value, key: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        settingsStore.setString(key, value: String(decoding: data, as: UTF8.self))
    }

    /** Decodes one exact-key fidelity value, returning nil for absent or malformed storage. */
    private func decodeCodable<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let setting = settingsStore.entries(withPrefix: key).first(where: { $0.key == key }),
              let data = setting.value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    /** Decodes owner-scoped text-display fidelity rows while validating key identity. */
    private func allTextDisplayFidelityEntries(prefix: String) -> [TextDisplayFidelityEntry] {
        let qualifiedPrefix = "\(prefix)."
        return settingsStore.entries(withPrefix: qualifiedPrefix)
            .sorted { $0.key < $1.key }
            .compactMap { setting in
                guard let ownerID = UUID(uuidString: String(setting.key.dropFirst(qualifiedPrefix.count))),
                      let data = setting.value.data(using: .utf8),
                      let fidelity = try? JSONDecoder().decode(
                        RemoteSyncWorkspaceTextDisplaySettingsFidelity.self,
                        from: data
                      ) else {
                    return nil
                }
                return TextDisplayFidelityEntry(ownerID: ownerID, fidelity: fidelity)
            }
    }

    /** Builds the canonical composite storage key for one label override. */
    private func labelOverrideKey(workspaceID: UUID, labelID: UUID) -> String {
        "\(Self.labelOverrideFidelityPrefix).\(workspaceID.uuidString.lowercased()).\(labelID.uuidString.lowercased())"
    }
}
