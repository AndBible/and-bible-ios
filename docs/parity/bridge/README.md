# Bridge Parity

This directory holds parity documentation for the shared WebView bridge between
the Vue.js client and native iOS code.

## Reading Order

1. [contract.md](contract.md): bridge contract and message/event expectations
2. [dispositions.md](dispositions.md): explicit iOS adaptations and no-op dispositions
3. [memorization-progress-model.md](memorization-progress-model.md): accepted
   local iOS memorization progress model and Android references
4. [reading-progress-model.md](reading-progress-model.md): accepted local iOS
   reading-progress model, storage, settings, and Android references
5. [my-documents-model.md](my-documents-model.md): accepted local iOS My
   Documents model, storage, rendering, and raw-content contract
6. [verification-matrix.md](verification-matrix.md): current status by bridge contract area
7. [regression-report.md](regression-report.md): focused bridge-adjacent validation evidence
8. [guardrails.md](guardrails.md): maintenance rules for high-risk bridge changes

Machine-readable tracking:

- [baselines/android-bridge-gap-inventory.json](baselines/android-bridge-gap-inventory.json):
  Android bridge methods plus resolved iOS bridge dispositions

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
