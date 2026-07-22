// ReadingProgressAndroidContracts.swift -- Android chapter-progress identity and presentation data

import Foundation

/**
 Pure Android reading-progress heatmap scale and ARGB color contract.

 Values mirror `ReadingProgressColors.kt`: chapter counts use pale yellow through orange to deep
 red, book repeat-read percentages use light blue through dark blue to red, and legends retain
 Android's fixed anchors. Keeping the arithmetic outside SwiftUI makes fixture verification exact.
 */
public enum AndroidReadingProgressHeatmap {
    /// Android empty-cell color `#E8E8E8`.
    public static let emptyARGB: UInt32 = 0xFFE8E8E8
    /// Android chapter count color at one read, `#FFF9C4`.
    public static let chapterMinimumARGB: UInt32 = 0xFFFFF9C4
    /// Android chapter count color at five reads, `#FF6D00`.
    public static let chapterMidpointARGB: UInt32 = 0xFFFF6D00
    /// Android chapter count color at the effective maximum, `#B71C1C`.
    public static let chapterMaximumARGB: UInt32 = 0xFFB71C1C
    /// Android book count color above zero, `#E3F2FD`.
    public static let bookMinimumARGB: UInt32 = 0xFFE3F2FD
    /// Android book count color at 100 percent, `#1565C0`.
    public static let bookHundredPercentARGB: UInt32 = 0xFF1565C0
    /// Android book count color at the current scale maximum, `#B71C1C`.
    public static let bookMaximumARGB: UInt32 = 0xFFB71C1C
    /// Android's fixed chapter heatmap midpoint.
    public static let chapterMidpointCount = 5

    /**
     Resolves Android's dynamic book percentage scale maximum.

     - Parameter maximumReadPercent: Largest `totalReads / totalChapters` value, where `1` is 100%.
     - Returns: At least `1`, rounded upward to the next 25-percent boundary above 100%.
     - Side effects: none.
     - Failure modes: Negative and missing values produce the default `1` scale.
     */
    public static func effectiveBookScaleMaximum(_ maximumReadPercent: Double?) -> Double {
        let actualMaximum = max(maximumReadPercent ?? 0, 0)
        guard actualMaximum > 1 else { return 1 }
        return ceil(actualMaximum * 4) / 4
    }

    /**
     Builds Android's 25-percent book legend labels.

     - Parameter maximumReadPercent: Effective maximum returned by `effectiveBookScaleMaximum`.
     - Returns: Integer percentage labels from 25 through at least 100.
     - Side effects: none.
     - Failure modes: Non-positive values still return Android's default 25...100 labels.
     */
    public static func bookScalePercentages(maximumReadPercent: Double) -> [Int] {
        let maximumPercent = max(Int((maximumReadPercent * 100).rounded()), 100)
        return Array(stride(from: 25, through: maximumPercent, by: 25))
    }

    /**
     Builds Android's chapter-count legend values.

     - Parameter maximumCount: Largest persisted repeat-read count in the selected book.
     - Returns: Every count `1...10`, or Android's sampled ten-value scale above ten.
     - Side effects: none.
     - Failure modes: Non-positive values use the minimum effective maximum of ten.
     */
    public static func chapterScaleCounts(maximumCount: Int) -> [Int] {
        let effectiveMaximum = max(maximumCount, 10)
        guard effectiveMaximum > 10 else { return Array(1...effectiveMaximum) }

        let evenlySpaced = Set((0..<10).map { index in
            1 + index * (effectiveMaximum - 1) / 9
        })
        return Array(
            evenlySpaced
                .union([1, chapterMidpointCount, effectiveMaximum])
                .sorted()
                .prefix(10)
        )
    }

    /**
     Resolves Android's chapter repeat-count color.

     - Parameters:
       - count: Persisted read count for one chapter.
       - maximumCount: Largest count in the selected book.
     - Returns: Android ARGB color at the same fixed one/five/effective-maximum anchors.
     - Side effects: none.
     - Failure modes: Zero and negative counts return the empty color.
     */
    public static func chapterARGB(count: Int, maximumCount: Int) -> UInt32 {
        guard count > 0 else { return emptyARGB }
        let effectiveMaximum = max(maximumCount, 10)
        if count <= chapterMidpointCount {
            let denominator = max(chapterMidpointCount - 1, 1)
            let ratio = Double(count - 1) / Double(denominator)
            return blendARGB(chapterMinimumARGB, chapterMidpointARGB, ratio: ratio)
        }
        let denominator = max(effectiveMaximum - chapterMidpointCount, 1)
        let ratio = Double(count - chapterMidpointCount) / Double(denominator)
        return blendARGB(chapterMidpointARGB, chapterMaximumARGB, ratio: ratio)
    }

    /**
     Resolves Android's book repeat-percentage color.

     - Parameters:
       - readPercent: `totalReads / totalChapters`, where one is 100 percent.
       - effectiveMaximum: Dynamic 25-percent-rounded scale maximum.
     - Returns: Android ARGB book heatmap color.
     - Side effects: none.
     - Failure modes: Zero and negative percentages return the empty color.
     */
    public static func bookARGB(readPercent: Double, effectiveMaximum: Double) -> UInt32 {
        guard readPercent > 0 else { return emptyARGB }
        if readPercent <= 1 {
            return blendARGB(bookMinimumARGB, bookHundredPercentARGB, ratio: readPercent)
        }
        let denominator = max(effectiveMaximum - 1, Double.leastNonzeroMagnitude)
        return blendARGB(
            bookHundredPercentARGB,
            bookMaximumARGB,
            ratio: (readPercent - 1) / denominator
        )
    }

    /**
     Applies Android's luminance threshold for heatmap foreground text.

     - Parameter argb: Opaque or translucent ARGB color.
     - Returns: `true` when Android would use white rather than dark-gray text.
     - Side effects: none.
     - Failure modes: none.
     */
    public static func usesLightForeground(argb: UInt32) -> Bool {
        relativeLuminance(argb: argb) < 0.45
    }

    private static func blendARGB(_ from: UInt32, _ to: UInt32, ratio: Double) -> UInt32 {
        let clampedRatio = min(max(ratio, 0), 1)
        let inverse = 1 - clampedRatio
        var result: UInt32 = 0
        for shift in stride(from: 24, through: 0, by: -8) {
            let fromChannel = Double((from >> UInt32(shift)) & 0xFF)
            let toChannel = Double((to >> UInt32(shift)) & 0xFF)
            let channel = UInt32(fromChannel * inverse + toChannel * clampedRatio)
            result |= channel << UInt32(shift)
        }
        return result
    }

    private static func relativeLuminance(argb: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let component = Double(channel) / 255
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let red = linear((argb >> 16) & 0xFF)
        let green = linear((argb >> 8) & 0xFF)
        let blue = linear(argb & 0xFF)
        return red * 0.2126 + green * 0.7152 + blue * 0.0722
    }
}

/**
 Validated Android `ChapterReadHistory` chapter identity in JSword's KJVA domain.

 Android persists `BibleBook.ordinal`, not a verse ordinal, beside a one-based chapter. This type
 validates both fields against the pinned JSword KJVA canon before any native write reaches local
 persistence. Native source-versification callers must construct it from a verified mapping;
 Android-imported rows use the explicit Android boundary.
 */
public struct ReadingProgressKJVAIdentity: Codable, Equatable, Hashable, Sendable {
    /// Android JSword `BibleBook.ordinal` value.
    public let kjvBookOrdinal: Int

    /// One-based chapter number stored by Android.
    public let chapter: Int

    /// Canonical KJVA OSIS identifier proven by the pinned book table.
    public let osisBookId: String

    /**
     Validates an Android-origin chapter identity.

     - Parameters:
       - kjvBookOrdinal: Raw Android `BibleBook.ordinal` value.
       - chapter: Raw Android one-based chapter.
     - Returns: `nil` when either field is outside Android's KJVA canon domain.
     - Side effects: none.
     - Failure modes: Unknown books and non-positive chapters are rejected. Deuterocanonical
       KJVA rows remain valid in persistence; Android applies `Scripture.isScripture` only when
       building the 66-book progress presentation.
     */
    public init?(androidKJVBookOrdinal kjvBookOrdinal: Int, chapter: Int) {
        guard let book = JSwordKJVAVersification.books.first(where: {
            $0.bibleBookOrdinal == kjvBookOrdinal
        }),
              chapter > 0 else {
            return nil
        }
        self.kjvBookOrdinal = kjvBookOrdinal
        self.chapter = chapter
        osisBookId = book.osisId
    }

    /**
     Builds a native chapter identity from verified source-to-KJVA mapping proof.

     Android maps source book `1:1` into KJVA to choose the stored book ordinal, while retaining
     the source chapter number. The verified range must therefore represent that exact source
     book anchor; this initializer consumes only its trusted KJVA endpoint and then validates the
     chapter against the mapped KJVA canon book.

     - Parameters:
       - verifiedBookAnchor: Verified mapping proof for the source book's `1:1` anchor.
       - sourceChapter: One-based chapter supplied by the active reader.
     - Returns: Validated Android chapter identity, or `nil` when the strict mapping lands outside
       the pinned KJVA canon or the source chapter is non-positive.
     - Side effects: Reads the pinned JSword KJVA ordinal table.
     - Failure modes: Unmappable anchors and invalid chapters fail closed.
     */
    public init?(verifiedBookAnchor: VerifiedKJVAOrdinalRange, sourceChapter: Int) {
        guard let reference = JSwordKJVAVersification.referenceIncludingIntroductions(
            ordinal: verifiedBookAnchor.kjvaOrdinalStart
        ),
        let bookOrdinal = JSwordKJVAVersification.bibleBookOrdinal(forOsisId: reference.osisId) else {
            return nil
        }
        self.init(androidKJVBookOrdinal: bookOrdinal, chapter: sourceChapter)
    }

    /// JSword KJVA rows that Android's KJV `Scripture.isScripture` predicate accepts.
    public static let scriptureBooks: [JSwordKJVABookSummary] = {
        let osisIDs: Set<String> = [
            "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
            "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
            "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer",
            "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah",
            "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt",
            "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal",
            "Eph", "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim",
            "Titus", "Phlm", "Heb", "Jas", "1Pet", "2Pet", "1John",
            "2John", "3John", "Jude", "Rev",
        ]
        return JSwordKJVAVersification.books.filter { osisIDs.contains($0.osisId) }
    }()

    /// Pinned KJVA book metadata for this identity.
    public var book: JSwordKJVABookSummary {
        JSwordKJVAVersification.books.first { $0.bibleBookOrdinal == kjvBookOrdinal }!
    }
}

/** One Android reading-progress calendar bucket at local midnight. */
public struct ReadingProgressDayCount: Equatable, Identifiable, Sendable {
    /// Local start-of-day represented in Unix milliseconds.
    public let dayStartMilliseconds: Int64

    /// Number of chapter-history rows recorded that local day.
    public let count: Int

    /// Stable SwiftUI identity.
    public var id: Int64 { dayStartMilliseconds }

    /** Creates one immutable day bucket without side effects or failure modes. */
    public init(dayStartMilliseconds: Int64, count: Int) {
        self.dayStartMilliseconds = dayStartMilliseconds
        self.count = count
    }
}

/** Android-equivalent progress summary for one KJV scripture book and cycle. */
public struct ReadingProgressBookSummary: Equatable, Identifiable, Sendable {
    /// Pinned KJVA book metadata.
    public let book: JSwordKJVABookSummary

    /// Read-history count by one-based chapter.
    public let chapterReadCounts: [Int: Int]

    /// Total chapter-history rows across this book and cycle.
    public let totalReadCount: Int

    /// Stable SwiftUI identity.
    public var id: String { book.osisId }

    /// Number of distinct chapters read at least once.
    public var distinctReadChapterCount: Int { chapterReadCounts.values.filter { $0 > 0 }.count }

    /// Android count-mode heat value: total reads divided by total chapters.
    public var readPercent: Double {
        guard book.chapterCount > 0 else { return 0 }
        return Double(totalReadCount) / Double(book.chapterCount)
    }

    /// Whether every chapter has at least one history row.
    public var isComplete: Bool { distinctReadChapterCount >= book.chapterCount }

    /** Creates one immutable book summary without side effects or failure modes. */
    public init(
        book: JSwordKJVABookSummary,
        chapterReadCounts: [Int: Int],
        totalReadCount: Int
    ) {
        self.book = book
        self.chapterReadCounts = chapterReadCounts
        self.totalReadCount = totalReadCount
    }
}

/** Complete Android-equivalent reading-progress presentation for one active cycle. */
public struct ReadingProgressPresentationSnapshot: Equatable, Sendable {
    /// Cycle being displayed.
    public let cycle: Int

    /// Highest persisted cycle, defaulting to one.
    public let latestCycle: Int

    /// Distinct KJV chapters read in the displayed cycle.
    public let distinctChapterCount: Int

    /// Distinct local calendar days containing a read event.
    public let activeDayCount: Int

    /// Total chapters in Android's KJV scripture scope.
    public let totalBibleChapterCount: Int

    /// One summary for each of Android's 66 scripture books.
    public let books: [ReadingProgressBookSummary]

    /// Last 52 weeks of local-day activity.
    public let calendar: [ReadingProgressDayCount]

    /// Most recent history rows in the cycle.
    public let recentRows: [ReadingProgressHistoryRow]

    /// Distinct-chapter completion fraction clamped for Android's bounded progress bar.
    public var overallProgress: Double {
        guard totalBibleChapterCount > 0 else { return 0 }
        return min(max(Double(distinctChapterCount) / Double(totalBibleChapterCount), 0), 1)
    }

    /// Android's unbounded one-decimal label percentage, which can exceed 100 for non-scripture rows.
    public var overallPercent: Double {
        guard totalBibleChapterCount > 0 else { return 0 }
        return max(Double(distinctChapterCount) * 100 / Double(totalBibleChapterCount), 0)
    }

    /** Creates one immutable presentation snapshot without side effects or failure modes. */
    public init(
        cycle: Int,
        latestCycle: Int,
        distinctChapterCount: Int,
        activeDayCount: Int,
        totalBibleChapterCount: Int,
        books: [ReadingProgressBookSummary],
        calendar: [ReadingProgressDayCount],
        recentRows: [ReadingProgressHistoryRow]
    ) {
        self.cycle = cycle
        self.latestCycle = latestCycle
        self.distinctChapterCount = distinctChapterCount
        self.activeDayCount = activeDayCount
        self.totalBibleChapterCount = totalBibleChapterCount
        self.books = books
        self.calendar = calendar
        self.recentRows = recentRows
    }
}

public extension ReadingProgressHistoryRow {
    /**
     Resolves the user-visible Android read-history reference.

     Android permits an empty `bookInitials` value on imported and older rows. In that case the
     persisted KJVA `BibleBook.ordinal` remains authoritative and supplies the book name instead of
     rendering an empty prefix.

     - Returns: KJVA short book name plus chapter; invalid quarantined rows use Android's `?` marker.
     - Side effects: Reads the pinned JSword KJVA book table.
     - Failure modes: Unknown book ordinals return Android's `? <chapter>` marker.
     */
    var androidDisplayReference: String {
        let name = ReadingProgressKJVAIdentity(
            androidKJVBookOrdinal: kjvBookOrdinal,
            chapter: chapter
        )?.book.shortName ?? "?"
        return "\(name) \(chapter)"
    }

    /** Android module/version line, or `nil` for its localized unknown-version fallback. */
    var androidDisplayVersion: String? {
        bookInitials.isEmpty ? nil : bookInitials
    }
}
