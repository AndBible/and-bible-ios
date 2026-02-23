// StudyPad.swift — StudyPad (journal) entry models

import Foundation
import SwiftData

/// A text entry in a StudyPad (associated with a Label).
/// StudyPads combine user-written notes with bookmark references.
@Model
public final class StudyPadTextEntry {
    /// UUID primary key.
    @Attribute(.unique) public var id: UUID

    /// The label (StudyPad) this entry belongs to.
    public var label: Label?

    /// Display order within the StudyPad.
    public var orderNumber: Int

    /// Nesting indent level.
    public var indentLevel: Int

    /// The text content (stored separately for performance).
    @Relationship(deleteRule: .cascade, inverse: \StudyPadTextEntryText.entry)
    public var textEntry: StudyPadTextEntryText?

    public init(
        id: UUID = UUID(),
        orderNumber: Int = 0,
        indentLevel: Int = 0
    ) {
        self.id = id
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
    }
}

/// The actual text content of a StudyPad entry (separated for performance).
@Model
public final class StudyPadTextEntryText {
    /// References the parent StudyPadTextEntry.
    @Attribute(.unique) public var studyPadTextEntryId: UUID

    /// Parent entry.
    public var entry: StudyPadTextEntry?

    /// The rich text content.
    public var text: String

    public init(studyPadTextEntryId: UUID, text: String = "") {
        self.studyPadTextEntryId = studyPadTextEntryId
        self.text = text
    }
}
