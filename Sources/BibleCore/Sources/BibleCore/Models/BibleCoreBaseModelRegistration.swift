import SwiftData

/**
 Declares the stable non-AI SwiftData model partitions shared by the app and host fixtures.

 The application appends the separately owned `AIModelRegistration` groups. Callers retain
 ownership of configuration names, store URLs, CloudKit policy, and in-memory versus disk storage.
 Keeping only the model membership here prevents the app, fixture writer, and production-shaped
 tests from silently changing relationship-complete base schemas independently.
 */
public enum BibleCoreBaseModelRegistration {
    /// Models stored in the CloudKit-capable user-data partition before separately registered model families.
    public static var cloudModels: [any PersistentModel.Type] {
        [
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
            ReadingPlan.self,
            ReadingPlanDay.self,
            ReadingPlanDefinitionPublicationState.self,
        ]
    }

    /// Models stored in the device-local partition before separately registered model families.
    public static var localModels: [any PersistentModel.Type] {
        [
            Repository.self,
            Setting.self,
        ]
    }
}
