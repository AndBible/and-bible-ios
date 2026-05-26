# 0002: Route Reader Document Modals Through The Shared Document Pipeline

Status: Accepted

Date: 2026-05-25

## Context

The reader parity audit in #122 compared Swift-native reader sheets against
Android and the shared Vue document/modal code.

The audit found that not every native iOS sheet is parity drift. Android also
uses native flows for some app-level surfaces, and iOS can use platform-native
presentation when the user-visible choices and outcomes remain equivalent.

However, some reader surfaces are not app-level native destinations on Android.
They are document-like reader content routed through Android's document/window
pipeline and rendered by the shared Vue client. Treating those as standalone
Swift sheets on iOS creates real parity drift even if the immediate feature
works.

## Decision

Reader surfaces that Android treats as document/window content should route
through the shared document pipeline on iOS.

This includes:

- Strong's / dictionary content, while preserving the dedicated
  `contentType: "strongs"` Vue route
- Compare content, including hidden-translation and restore behavior
- multi-reference and cross-reference content that Android routes through the
  fake multi document and Vue `MultiDocument`

The iOS reader host should also honor Vue modal-open state reported by the
embedded client so native host navigation does not escape an open Vue modal.

Reader-adjacent native app surfaces may remain native adaptations when Android
also uses native/app-level flows or when no shared Vue document/modal equivalent
exists. Those classifications belong in the reader parity dispositions and
verification matrix.

## Consequences

- Native iOS sheets for Strong's, Compare, and multi-reference content are not
  accepted final parity endpoints.
- Existing tests that prove native presentation payloads still have value
  protect the current bridge path rather than closing the parity gap.
- Focused implementation work is tracked by #8, #123, #124, and #125.
- Future reader modal audits should first classify whether a surface is
  document-pipeline content, app-level native UI, or a platform-only
  adaptation before creating implementation work.

## Related

- [Reader parity contract](../parity/reader/contract.md)
- [Reader parity dispositions](../parity/reader/dispositions.md)
- [Reader verification matrix](../parity/reader/verification-matrix.md)
- [Bridge parity dispositions](../parity/bridge/dispositions.md)
- #8
- #122
- #123
- #124
- #125
