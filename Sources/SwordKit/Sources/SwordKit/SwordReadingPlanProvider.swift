// SwordReadingPlanProvider.swift -- Android add-on reading plan projection

import Foundation

/**
 Android-compatible reading plan file provided by an installed SWORD add-on module.

 Android exposes add-on plans through repeated `AndBibleProvidesReadingPlan` config values. This
 DTO keeps the iOS catalog layer independent from raw `.conf` parsing while preserving the module
 metadata Android uses for display and date-based plan handling.
 */
public struct SwordReadingPlanProvider: Equatable, Sendable {
    /// Stable plan code derived from the provided plan file name without its extension.
    public let planCode: String

    /// User-visible module name Android shows for add-on-provided plans.
    public let name: String

    /// User-visible short promotional text from the module config, when present.
    public let description: String

    /// Validated local URL for the `.properties` plan file.
    public let fileURL: URL

    /// Optional versification advertised by the add-on module.
    public let versification: String?

    /// Whether the add-on declares Android's date-based reading-plan format.
    public let isDateBased: Bool

    /**
     Creates one add-on reading plan provider row.

     - Parameters:
       - planCode: Stable code used by reading-plan persistence and catalog de-duplication.
       - name: User-visible module name.
       - description: Short module description.
       - fileURL: Validated local plan file URL.
       - versification: Optional module versification.
       - isDateBased: Whether readings use Android's date-prefixed plan syntax.
     */
    public init(
        planCode: String,
        name: String,
        description: String,
        fileURL: URL,
        versification: String?,
        isDateBased: Bool
    ) {
        self.planCode = planCode
        self.name = name
        self.description = description
        self.fileURL = fileURL
        self.versification = versification
        self.isDateBased = isDateBased
    }
}
