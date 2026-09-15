// BibleReaderPreparedCommentaryNavigation.swift -- Immutable accepted commentary navigation

import Foundation
import SwordKit

/** Source-Bible coordinate for one adjacent commentary block selected during source capture. */
struct BibleReaderCommentaryNavigationTarget: Equatable, Sendable {
    let osisBookID: String
    let chapter: Int
    let verse: Int

    init(_ reference: SwordVersification.Reference) {
        osisBookID = reference.osisBookId
        chapter = reference.chapter
        verse = reference.verse
    }
}

/** Previous/next source-Bible targets captured with one accepted commentary document. */
struct BibleReaderCommentaryNavigationAvailability: Equatable, Sendable {
    static let empty = BibleReaderCommentaryNavigationAvailability(previous: nil, next: nil)

    let previous: BibleReaderCommentaryNavigationTarget?
    let next: BibleReaderCommentaryNavigationTarget?
}
