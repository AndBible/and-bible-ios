// ProductFeedbackContract.swift -- Android-aligned product feedback endpoints and report types

/**
 Defines the stable identifiers for a user-initiated manual diagnostic report.

 Keeping these two Android-aligned values in one contract avoids duplicating the addressed
recipient or subject source across evidence collection and system-Mail handoff. Review, rating,
and App Store routing are deliberately outside this contract.
 */
public enum ProductFeedbackContract {
    /// Android's manual report source label included in the addressed email subject.
    public static let manualReportSource = "manual"
    /// Destination for addressed diagnostic reports.
    public static let diagnosticRecipient = "errors.andbible@gmail.com"
}
