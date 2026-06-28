import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Package-level presentation tests for Android database backup UI copy.

 The database backup service and archive semantics belong in `BibleCoreTests`; this suite protects
 the BibleUI-only localized strings that the Backup & Restore screen presents around those services.
 */
final class AndroidDatabaseBackupPresentationTests: XCTestCase {
    /**
     Verifies Backup & Restore reset success copy names the category that was reset.

     Setup:
     - reads the BibleUI presentation labels for Android reset categories

     Expected result:
     - repository reset feedback includes repository wording
     - repository reset feedback does not claim that only "Database" was reset

     Failure meaning:
     - the user-visible reset result would be misleading for non-database categories such as
       Repositories, Application Preferences, My Documents, or Progress.
     */
    func testAndroidBackupResetSuccessMessageNamesSelectedCategory() {
        let message = AndroidBackupResetCategory.repositories.localizedBackupResetSuccessMessage

        XCTAssertTrue(message.localizedCaseInsensitiveContains("repositories"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("database has been reset"))
    }
}
