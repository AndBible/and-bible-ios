// BibleWindowPaneMenuActionHandler.swift -- Shared Android window-popup command routing

import BibleCore
import Foundation

/**
 Executes one shared Android window-popup action against an immutable target window.

 Both the pane hamburger and the bottom restore-strip button open Android's same
 `SplitBibleArea.showPopupMenu` contract. This handler keeps layout mutations and reader-owned
 presentation callbacks on one route so the two entry points cannot silently diverge again.

 Inputs: target window, window manager, and feature-owner callbacks for presentation side effects

 Output: none; each terminal action either mutates the target or invokes one callback

 Side effects: may activate/add/move/pin/synchronize/close windows, open reader-owned settings or AI
 UI, copy a reference, or persist display-setting changes through callbacks

 Failure modes: absent optional callbacks are safe no-ops; `WindowManager` enforces non-removable,
 pending-registration, and invalid-position guards
 */
@MainActor
struct BibleWindowPaneMenuActionHandler {
    let windowManager: WindowManager
    let window: BibleCore.Window
    var onEditTextSetting: ((AndroidTextDisplaySettingType) -> Void)?
    var onShowWindowTextOptions: (() -> Void)?
    var onCopyWindowSettingsToWindow: ((UUID) -> Void)?
    var onCopyWindowSettingsToWorkspace: (() -> Void)?
    var onCopyWindowSettingsToGlobal: (() -> Void)?
    var onAddWholePageBookmark: (() -> Void)?
    var onExportHTML: (() -> Void)?
    var onExportStudyPad: (() -> Void)?
    var onExportStudyPadCSV: (() -> Void)?
    var onOpenAIActions: (() -> Void)?
    var onCopyLink: (() -> Void)?
    var onOpenCopiedReference: (() -> Void)?
    var onOpenSpeakReference: (() -> Void)?

    /**
     Executes one terminal menu action without re-resolving the active window.

     - Parameter action: Command emitted by `BibleWindowPaneMenuModel`.
     - Side effects: Performs the corresponding manager mutation or owner callback.
     - Failure modes: Optional presentation callbacks may be absent; manager guards reject invalid
       operations without retargeting a different window.
     */
    func perform(_ action: BibleWindowPaneMenuAction) {
        if window.layoutState != "minimized" {
            windowManager.activateWindow(window)
        }
        switch action {
        case .newWindow:
            windowManager.addWindow(from: window)
        case .maximize:
            windowManager.maximizeWindow(window)
        case .minimize:
            windowManager.minimizeWindow(window)
        case .changeToNormalWindow:
            windowManager.changeLinksWindowToNormal(window)
        case .moveToPosition(let position):
            windowManager.moveWindow(window, toPosition: position)
        case .togglePin:
            windowManager.setPinMode(window, value: !window.isPinMode)
        case .disableSync:
            windowManager.setSynchronized(window, value: false)
        case .selectSyncGroup(let group):
            windowManager.changeSyncGroup(window, groupNumber: group)
        case .addWholePageBookmark:
            onAddWholePageBookmark?()
        case .exportHTML:
            onExportHTML?()
        case .exportStudyPad:
            onExportStudyPad?()
        case .exportStudyPadCSV:
            onExportStudyPadCSV?()
        case .editTextSetting(let type):
            onEditTextSetting?(type)
        case .openAllTextOptions:
            onShowWindowTextOptions?()
        case .copySettingsToWindow(let targetWindowID):
            onCopyWindowSettingsToWindow?(targetWindowID)
        case .copySettingsToWorkspace:
            onCopyWindowSettingsToWorkspace?()
        case .copySettingsToGlobal:
            onCopyWindowSettingsToGlobal?()
        case .openAIActions:
            onOpenAIActions?()
        case .copyLink:
            onCopyLink?()
        case .openCopiedReference:
            onOpenCopiedReference?()
        case .openSpeakReference:
            onOpenSpeakReference?()
        case .close:
            windowManager.removeWindow(window)
        }
    }
}
