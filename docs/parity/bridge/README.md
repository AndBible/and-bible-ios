# Bridge Parity

This directory holds parity documentation for the shared WebView bridge between
the Vue.js client and native iOS code.

## Reading Order

1. [contract.md](contract.md): bridge contract and message/event expectations
2. [dispositions.md](dispositions.md): explicit iOS adaptations and no-op branches
3. [verification-matrix.md](verification-matrix.md): current status by bridge contract area
4. [regression-report.md](regression-report.md): focused bridge-adjacent validation evidence
5. [guardrails.md](guardrails.md): maintenance rules for high-risk bridge changes

Companion reference:

- [../../bridge-guide.md](../../bridge-guide.md): detailed message/event catalog and
  implementation-oriented bridge walkthrough

Primary references:

- `Sources/BibleView/Sources/BibleView/BibleWebView.swift`
- `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- `Sources/BibleView/Sources/BibleView/BridgeTypes.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/StrongsSheetView.swift`
