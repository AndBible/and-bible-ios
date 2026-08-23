// ReadingPlanListView.swift -- Android Reading Plan activity coordinator

import BibleCore
import SwordKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/** Retains one preflighted Android Install ZIP overwrite decision. */
private struct ReadingPlanExternalImportOverwriteConfirmation {
    /// Security-scoped document request selected from the Reading Plan overflow.
    let request: ExternalDocumentImportRequest

    /// Validated archive metadata and exact conflicting destinations.
    let inspection: LocalSwordZipInspection
}

/**
 Owns Android's Reading Plan activity flow without native iOS list or navigation presentation.

 Android opens the selected plan's Daily Reading activity directly. When no plan is selected, or
 when the plan title is tapped, it presents the flat `ReadingPlanSelectorList` activity. This owner
 preserves that route contract while keeping all persistence and file-import mutations centralized.

 Data dependencies:
 - SwiftData plans and Android's single selected-plan setting
 - `ReadingPlanService` for definition recovery, selection, start, reset, and custom import
 - the active reader/window palette supplied by the parent reader route

 Side effects:
 - starts, selects, resets, and imports reading plans through durable BibleCore services
 - hands only explicit file selection to the platform
 - invokes `onDismiss` when Android Up leaves the Reading Plan activity

 Failure modes:
 - definition, persistence, and import failures remain visible in an app-owned Android dialog
 - a missing selected plan falls back to the selector instead of rendering an empty iOS screen
 */
public struct ReadingPlanListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReadingPlan.startDate, order: .reverse) private var plans: [ReadingPlan]

    private let surfacePalette: ReaderThemeSurfacePalette
    private let onDismiss: (() -> Void)?
    private let planVersificationResolver: ReadingPlanVersificationResolver?
    private let onPerformDailyReadingAction: DailyReadingActionHandler?
    private let onReadCompleted: (@MainActor () -> Void)?
    private let dailyReadingToolbarState: AndroidDailyReadingToolbarState
    private let onOpenDailyReadingBible: (() -> Void)?
    private let onOpenDailyReadingCommentary: (() -> Void)?
    private let onOpenDailyReadingDictionary: (() -> Void)?
    private let onToggleDailyReadingSpeechPause: (() -> Void)?
    private let onStopDailyReadingSpeech: (() -> Void)?

    @State private var activePlanID: UUID?
    @State private var selectorReturnPlanID: UUID?
    @State private var showsSelector = true
    @State private var showsImportPicker = false
    @State private var catalog = ReadingPlanService.catalog()
    @State private var definitionRecoveryError: String?
    @State private var showsDuplicateUserPlanWarning = false
    @State private var pendingExternalImportRequest: ExternalDocumentImportRequest?
    @State private var pendingExternalImportOverwrite: ReadingPlanExternalImportOverwriteConfirmation?
    @State private var externalImportProgress: ModuleInstallProgress?
    @State private var transientImportMessage: String?

    /**
     Creates the public compatibility route with the standard application palette.

     - Parameters:
       - planVersificationResolver: Loads one plan definition's optional versification.
       - onPerformDailyReadingAction: Executes exact Read or Speak requests in the active reader.
       - onReadCompleted: Closes the reader route after a successful Read action.
     - Side effects: None until the view appears or the user invokes a command.
     - Failure modes: Missing action dependencies are reported by `DailyReadingView`.
     */
    public init(
        planVersificationResolver: ReadingPlanVersificationResolver? = nil,
        onPerformDailyReadingAction: DailyReadingActionHandler? = nil,
        onReadCompleted: (@MainActor () -> Void)? = nil
    ) {
        surfacePalette = .standard
        onDismiss = nil
        self.planVersificationResolver = planVersificationResolver
        self.onPerformDailyReadingAction = onPerformDailyReadingAction
        self.onReadCompleted = onReadCompleted
        dailyReadingToolbarState = .unavailable
        onOpenDailyReadingBible = nil
        onOpenDailyReadingCommentary = nil
        onOpenDailyReadingDictionary = nil
        onToggleDailyReadingSpeechPause = nil
        onStopDailyReadingSpeech = nil
    }

    /**
     Creates the reader-owned route with the exact active workspace/window palette and Up action.

     - Parameters:
       - surfacePalette: Resolved reader palette shared with all app-owned activity surfaces.
       - onDismiss: Clears the parent reader destination.
       - dailyReadingToolbarState: Active document labels and speech state for Daily Reading.
       - onOpenDailyReadingBible: Opens the active Bible and leaves Reading Plans.
       - onOpenDailyReadingCommentary: Opens the active commentary and leaves Reading Plans.
       - onOpenDailyReadingDictionary: Opens the active dictionary and leaves Reading Plans.
       - onToggleDailyReadingSpeechPause: Pauses or resumes the shared speech session.
       - onStopDailyReadingSpeech: Stops the shared speech session.
       - planVersificationResolver: Loads one plan definition's optional versification.
       - onPerformDailyReadingAction: Executes exact Read or Speak requests in the active reader.
       - onReadCompleted: Closes the reader route after a successful Read action.
     - Side effects: None during initialization.
     - Failure modes: None during initialization.
     */
    init(
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: @escaping () -> Void,
        dailyReadingToolbarState: AndroidDailyReadingToolbarState,
        onOpenDailyReadingBible: @escaping () -> Void,
        onOpenDailyReadingCommentary: @escaping () -> Void,
        onOpenDailyReadingDictionary: @escaping () -> Void,
        onToggleDailyReadingSpeechPause: @escaping () -> Void,
        onStopDailyReadingSpeech: @escaping () -> Void,
        planVersificationResolver: ReadingPlanVersificationResolver? = nil,
        onPerformDailyReadingAction: DailyReadingActionHandler? = nil,
        onReadCompleted: (@MainActor () -> Void)? = nil
    ) {
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
        self.dailyReadingToolbarState = dailyReadingToolbarState
        self.onOpenDailyReadingBible = onOpenDailyReadingBible
        self.onOpenDailyReadingCommentary = onOpenDailyReadingCommentary
        self.onOpenDailyReadingDictionary = onOpenDailyReadingDictionary
        self.onToggleDailyReadingSpeechPause = onToggleDailyReadingSpeechPause
        self.onStopDailyReadingSpeech = onStopDailyReadingSpeech
        self.planVersificationResolver = planVersificationResolver
        self.onPerformDailyReadingAction = onPerformDailyReadingAction
        self.onReadCompleted = onReadCompleted
    }

    /** Builds Android's selector-or-current-plan activity without a native navigation stack. */
    public var body: some View {
        ZStack {
            surfacePalette.backgroundColor.ignoresSafeArea()

            if showsSelector || activePlanID == nil {
                AndroidReadingPlanSelectorView(
                    templates: catalog.templates,
                    startedPlanCodes: Set(plans.map(\.planCode)),
                    surfacePalette: surfacePalette,
                    onBack: closeSelector,
                    onSelect: startSelectedTemplate,
                    onReset: resetPlan(code:)
                )
            } else if let activePlanID {
                DailyReadingView(
                    planId: activePlanID,
                    surfacePalette: surfacePalette,
                    onDismiss: closeActivity,
                    onChoosePlan: presentSelector,
                    onPlanEnded: closeActivity,
                    onImportPlan: { showsImportPicker = true },
                    toolbarState: dailyReadingToolbarState,
                    onOpenBible: { onOpenDailyReadingBible?() },
                    onOpenCommentary: { onOpenDailyReadingCommentary?() },
                    onOpenDictionary: { onOpenDailyReadingDictionary?() },
                    onToggleSpeechPause: { onToggleDailyReadingSpeechPause?() },
                    onStopSpeech: { onStopDailyReadingSpeech?() },
                    planVersificationResolver: planVersificationResolver,
                    onPerformAction: onPerformDailyReadingAction,
                    onReadCompleted: onReadCompleted
                )
            }
        }
        .foregroundStyle(surfacePalette.foregroundColor)
        .overlay(alignment: .topLeading) {
            AndroidActivityAccessibilityMarker(
                label: String(localized: "rdg_plan_title", defaultValue: "Reading Plan"),
                accessibilityIdentifier: "readingPlanListScreen",
                accessibilityValue: readingPlanListAccessibilityValue,
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .overlay(alignment: .topLeading) { readingPlanListStateExport }
        .fileImporter(
            isPresented: $showsImportPicker,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false,
            onCompletion: handleCustomPlanImport
        )
        .overlay { errorDialogs }
        .androidToastFeedback(transientImportMessage, bottomPadding: 48)
        .onAppear(perform: recoverDefinitionsAndActivateRoute)
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// Android's single-selected-plan setting store bound to the active model context.
    private var selectionStore: ReadingPlanSelectionStore {
        ReadingPlanSelectionStore(settingsStore: SettingsStore(modelContext: modelContext))
    }

    /// Stable semantic route state exported for UI automation without inspecting row layout.
    private var readingPlanListAccessibilityValue: String {
        let selectedCode = plans.first(where: { $0.id == activePlanID })?.planCode ?? ""
        let base = "total=\(plans.count);selected=\(readingPlanAccessibilitySegment(selectedCode));templates=\(catalog.templates.count);showAvailablePlans=\(showsSelector);importPickerPresented=\(showsImportPicker)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else { return base }
        let tokens = catalog.templates
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(readingPlanAccessibilitySegment($0.code))|" }
            .joined(separator: ",")
        return "\(base);templateRows=\(tokens)"
    }

    /// Hidden semantic-state probe retained for deterministic UI tests.
    @ViewBuilder
    private var readingPlanListStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(readingPlanListAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("readingPlanListStateExport")
                .accessibilityValue(readingPlanListAccessibilityValue)
        }
    }

    /// App-owned duplicate-definition or operation-failure dialogs in Android precedence order.
    @ViewBuilder
    private var errorDialogs: some View {
        if let request = pendingExternalImportRequest {
            AndroidDecisionDialog(
                title: String(localized: "install_zip", defaultValue: "Load Documents From Files"),
                message: String(
                    format: String(
                        localized: "install_do_you_want",
                        defaultValue: "Do you want to install module (%@)?"
                    ),
                    request.displayFileName ?? "?"
                ),
                actions: [
                    .init(
                        id: "cancel",
                        title: String(localized: "cancel"),
                        style: .normal
                    ) { pendingExternalImportRequest = nil },
                    .init(
                        id: "okay",
                        title: String(localized: "okay", defaultValue: "OK"),
                        style: .normal
                    ) {
                        pendingExternalImportRequest = nil
                        preflightExternalDocumentImport(request)
                    }
                ],
                accessibilityIdentifier: "readingPlanImportConfirmationDialog"
            )
        } else if let confirmation = pendingExternalImportOverwrite {
            AndroidDecisionDialog(
                title: String(
                    localized: "android_module_backup_overwrite_title",
                    defaultValue: "Overwrite existing module files?"
                ),
                message: ModuleBrowserView.localModuleOverwriteMessage(confirmation.inspection),
                actions: [
                    .init(
                        id: "cancel",
                        title: String(localized: "cancel"),
                        style: .normal
                    ) { pendingExternalImportOverwrite = nil },
                    .init(
                        id: "overwrite",
                        title: String(localized: "overwrite", defaultValue: "Overwrite"),
                        style: .destructive
                    ) {
                        pendingExternalImportOverwrite = nil
                        importExternalDocument(
                            confirmation.request,
                            overwritePolicy: .replaceExisting(
                                confirmation.inspection.overwriteAuthorization
                            )
                        )
                    }
                ],
                accessibilityIdentifier: "readingPlanImportOverwriteDialog"
            )
        } else if let progress = externalImportProgress {
            AndroidDecisionDialog(
                title: String(localized: "install_zip", defaultValue: "Load Documents From Files"),
                message: ModuleBrowserView.installPhaseText(
                    progress.phase,
                    progressPercent: progress.percent
                ),
                actions: [],
                accessibilityIdentifier: "readingPlanImportProgressDialog"
            )
        } else if showsDuplicateUserPlanWarning {
            AndroidDecisionDialog(
                title: String(localized: "error", defaultValue: "Error"),
                message: duplicateUserPlanWarningMessage,
                actions: [
                    .init(
                        id: "okay",
                        title: String(localized: "okay", defaultValue: "OK"),
                        style: .normal
                    ) { showsDuplicateUserPlanWarning = false }
                ]
            )
        } else if let definitionRecoveryError {
            AndroidDecisionDialog(
                title: String(localized: "error_occurred", defaultValue: "Error"),
                message: definitionRecoveryError,
                actions: [
                    .init(
                        id: "okay",
                        title: String(localized: "okay", defaultValue: "OK"),
                        style: .normal
                    ) { self.definitionRecoveryError = nil }
                ]
            )
        }
    }

    /// Android duplicate user-plan warning copied from the source resource contract.
    private var duplicateUserPlanWarningMessage: String {
        String(
            localized: "plan_duplicate_user_plan",
            defaultValue: "There is a user reading plan in sdcard jsword/readingplan with the same name as an internal plan. It can not be listed here. Please rename the file to something else, leaving it's file extension as .properties"
        )
    }

    /**
     Recovers definition publication and chooses Android's current-plan or selector entry route.

     Side effects: may recover interrupted definition publication and reconcile legacy selection.
     Failure modes: failures show an app-owned error and leave the selector accessible.
     */
    private func recoverDefinitionsAndActivateRoute() {
        do {
            try ReadingPlanService.recoverCustomPlanDefinitionPublication(
                settingsStore: SettingsStore(modelContext: modelContext)
            )
            let selectedPlan = try selectionStore.reconcile(plans, modelContext: modelContext)
            reloadCatalog()
            activePlanID = selectedPlan?.id
            selectorReturnPlanID = selectedPlan?.id
            showsSelector = selectedPlan == nil
            definitionRecoveryError = nil
        } catch {
            reloadCatalog()
            activePlanID = nil
            selectorReturnPlanID = nil
            showsSelector = true
            definitionRecoveryError = error.localizedDescription
        }
    }

    /// Refreshes Android's bundled/user catalog and duplicate-code warning state.
    private func reloadCatalog() {
        catalog = ReadingPlanService.catalog()
        showsDuplicateUserPlanWarning = catalog.hasDuplicateUserPlans
    }

    /// Opens Android's plan-title selector while retaining the current plan as the Up destination.
    private func presentSelector() {
        reloadCatalog()
        selectorReturnPlanID = activePlanID
        showsSelector = true
    }

    /// Android Up from the selector returns to Daily Reading or leaves the activity when none exists.
    private func closeSelector() {
        if let selectorReturnPlanID,
           plans.contains(where: { $0.id == selectorReturnPlanID }) {
            activePlanID = selectorReturnPlanID
            showsSelector = false
        } else {
            closeActivity()
        }
    }

    /// Clears the reader-owned route without relying on SwiftUI environment dismissal.
    private func closeActivity() {
        onDismiss?()
    }

    /** Starts or selects one Android catalog entry and returns directly to its Daily Reading. */
    private func startSelectedTemplate(_ template: ReadingPlanTemplate) {
        do {
            let plan = try ReadingPlanService.startPlan(
                template: template,
                modelContext: modelContext,
                selectionStore: selectionStore
            )
            activePlanID = plan.id
            selectorReturnPlanID = plan.id
            showsSelector = false
            definitionRecoveryError = nil
        } catch {
            definitionRecoveryError = error.localizedDescription
        }
    }

    /**
     Applies Android's selector context-menu Reset command for the matching started plan.

     Unstarted catalog entries are a no-op, matching a reset of absent Android progress.
     */
    private func resetPlan(code: String) {
        guard let plan = plans.first(where: { $0.planCode == code }) else { return }
        do {
            try ReadingPlanService.resetPlan(
                plan,
                modelContext: modelContext,
                progressStore: ReadingPlanProgressStore(
                    modelContext: modelContext,
                    settingsStore: SettingsStore(modelContext: modelContext)
                ),
                selectionStore: selectionStore
            )
            if activePlanID == plan.id { activePlanID = nil }
            if selectorReturnPlanID == plan.id { selectorReturnPlanID = nil }
            definitionRecoveryError = nil
        } catch {
            definitionRecoveryError = error.localizedDescription
        }
    }

    /**
     Converts Android's ZIP-only Reading Plan picker result into its shared Install ZIP request.

     Android's `DailyReading.importPlanLauncher` accepts `application/zip`, then opens the same
     `InstallZip` activity used by the rest of the application. Keeping that boundary here avoids
     misreading ZIP bytes as a raw `.properties` plan definition.

     - Parameter result: The platform file-selection result.
     - Side effects: Retains a normalized request for Android's install confirmation dialog.
     - Failure modes: Picker failures become app-owned error feedback; cancellation is ignored.
     */
    private func handleCustomPlanImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            pendingExternalImportRequest = ExternalDocumentImportRequest(
                url: url,
                contentTypeIdentifier: try? url.resourceValues(forKeys: [.contentTypeKey])
                    .contentType?.identifier,
                suggestedFileName: url.lastPathComponent
            )
        case .failure(let error):
            if Self.isFileImporterCancellation(error) { return }
            definitionRecoveryError = error.localizedDescription
        }
    }

    /**
     Runs the shared read-only ZIP validation before any installer writes begin.

     - Parameter request: Confirmed external document request.
     - Side effects: Publishes app-owned progress or overwrite-decision state on the main actor.
     - Failure modes: Validation failures become the existing Reading Plan error dialog.
     */
    private func preflightExternalDocumentImport(_ request: ExternalDocumentImportRequest) {
        externalImportProgress = ModuleInstallProgress(phase: .queued)
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: modelContext
        )
        Task { @MainActor in
            let preflight = await Task.detached(priority: .userInitiated) {
                service.preflightDocument(request)
            }.value
            switch preflight {
            case .ready:
                importExternalDocument(request, overwritePolicy: .reject)
            case .moduleOverwriteRequired(let inspection):
                externalImportProgress = nil
                pendingExternalImportOverwrite = .init(
                    request: request,
                    inspection: inspection
                )
            case .failed(let message):
                externalImportProgress = nil
                definitionRecoveryError = ExternalDocumentImportResult.failed(
                    message: message
                ).feedbackMessage
            }
        }
    }

    /**
     Installs a preflighted ZIP through the same durable service as Downloads and Backup & Restore.

     - Parameters:
       - request: Validated ZIP request.
       - overwritePolicy: Reject-by-default policy or exact replacement authorization granted by
         the user after preflight.
     - Side effects: Performs installer I/O off the main actor, streams phase progress, and reports
       Android's success toast or persistent failure feedback.
     - Failure modes: Installer failures are represented by `ExternalDocumentImportResult` and do
       not alter Reading Plan selection state.
     */
    private func importExternalDocument(
        _ request: ExternalDocumentImportRequest,
        overwritePolicy: LocalSwordZipOverwritePolicy
    ) {
        externalImportProgress = ModuleInstallProgress(phase: .queued)
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: modelContext
        )
        Task { @MainActor in
            let importResult = await Task.detached(priority: .userInitiated) {
                service.importDocument(
                    request,
                    moduleOverwritePolicy: overwritePolicy,
                    progressState: { progress in
                        Task { @MainActor in externalImportProgress = progress }
                    }
                )
            }.value
            externalImportProgress = nil
            if importResult.usesAndroidInstallToastFeedback {
                showTransientImportMessage(importResult.feedbackMessage)
            } else {
                definitionRecoveryError = importResult.feedbackMessage
            }
        }
    }

    /**
     Shows Android's short install-result toast and clears only the matching message later.

     - Parameter message: Localized success text.
     - Side effects: Mutates transient overlay state and schedules its dismissal.
     - Failure modes: A newer message is not cleared by an older dismissal task.
     */
    private func showTransientImportMessage(_ message: String) {
        withAnimation { transientImportMessage = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(AndroidToastFeedback.shortDuration))
            guard transientImportMessage == message else { return }
            withAnimation { transientImportMessage = nil }
        }
    }

    /** Returns whether a platform picker error represents user cancellation. */
    private static func isFileImporterCancellation(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.userCancelled.rawValue
    }
}

/// Sanitizes one reading-plan code for stable accessibility identifiers and semantic state tokens.
func readingPlanAccessibilitySegment(_ value: String) -> String {
    let mapped = value.unicodeScalars.map { scalar -> String in
        CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
    }
    let collapsed = mapped.joined().replacingOccurrences(
        of: "_+",
        with: "_",
        options: .regularExpression
    )
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}
