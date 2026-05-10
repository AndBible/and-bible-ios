# Reader Parity

This directory is meant to help the next person understand how close the iOS `reader` currently is to Android, where the remaining gaps are, and which parts are easy to break by accident.

It covers the main reading experience, including the reader shell, toolbar chrome, drawer/overflow navigation, history handoff, workspace switching, compare presentation, and the Strong's / dictionary modal path.

If you are new to this area, start here and read top to bottom once. The matrix
is useful, but the surrounding notes are where the intent and the remaining rough edges are easier to understand.

## Reading Order

1. [contract.md](contract.md): reader behaviors that intentionally mirror Android
2. [dispositions.md](dispositions.md): explicit iOS adaptations for those behaviors
3. [verification-matrix.md](verification-matrix.md): current status by contract area
4. [regression-report.md](regression-report.md): focused validation evidence
5. [guardrails.md](guardrails.md): maintenance rules for high-risk reader changes

Helpful companion docs:

- [../settings/contract.md](../settings/contract.md): Android application-preference
  baseline that feeds many reader behaviors
- [../bridge/contract.md](../bridge/contract.md): shared bridge contract used by the
  embedded document client

Primary code references:

- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/CompareView.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/StrongsSheetView.swift`
- `Sources/BibleView/Sources/BibleView/WebViewCoordinator.swift`
- `Sources/BibleUI/Sources/BibleUI/Shared/HistoryView.swift`
- `Sources/BibleUI/Sources/BibleUI/Workspace/WorkspaceSelectorView.swift`
- `bibleview-js/src/components/documents/DocumentBroker.vue`
- `bibleview-js/src/components/documents/StrongsDocument.vue`
