# Bridge Parity

This directory holds parity documentation for the shared WebView bridge between
the Vue.js client and native iOS code.

## Reading Order

1. [contract.md](contract.md): bridge contract and message/event expectations
2. [dispositions.md](dispositions.md): explicit iOS adaptations and no-op dispositions
3. [verification-matrix.md](verification-matrix.md): current status by bridge contract area
4. [regression-report.md](regression-report.md): focused bridge-adjacent validation evidence
5. [guardrails.md](guardrails.md): maintenance rules for high-risk bridge changes

Machine-readable tracking:

- [baselines/android-bridge-gap-inventory.json](baselines/android-bridge-gap-inventory.json):
  Android bridge methods plus iOS no-op and former no-op dispositions

Recurring alignment check:

```bash
python3 scripts/check_bridge_parity_inventory.py --android-root ../and-bible
```

Use `--android-root` for a non-sibling Android checkout, or set
`ANDBIBLE_ANDROID_ROOT` for repeated local runs. Paste the command summary into
bridge parity issues and PR validation notes when Android-backed drift was
checked.

Companion reference:

- [../../bridge-guide.md](../../bridge-guide.md): detailed message/event catalog and
  implementation-oriented bridge walkthrough

Primary references:

- `Sources/BibleView/Sources/BibleView/BibleWebView.swift`
- `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- `Sources/BibleView/Sources/BibleView/BridgeTypes.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/StrongsSheetView.swift`
