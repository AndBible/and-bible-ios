# 0002: Route Reader Document Modals Through The Shared Document Pipeline

Status: Accepted

Date: 2026-05-25

## Context

The reader parity audit in #122 compared Swift-native reader sheets against
Android and the shared Vue document/modal code.

The product goal for parity is an identical Android and iOS experience wherever
the platforms can honestly support it. Implementation internals can differ, but
observable behavior, presentation, and workflow structure should match Android
unless there is a real platform or product reason to diverge.

The audit found that some reader surfaces are not app-level native destinations
on Android. They are document-like reader content routed through Android's
document/window pipeline and rendered by the shared Vue client. Treating those
as standalone Swift sheets on iOS creates real parity drift even if the
immediate feature works.

At the same time, parity should not mean forcing brittle integrations. If a
shared pipeline route would require an iOS-only hack, the team should name that
constraint, compare alternatives, and decide explicitly rather than hiding the
problem behind native UI or awkward bridge code.

## Decision

Reader surfaces that Android treats as document/window content should route
through the shared Vue/document pipeline on iOS.

For the audited reader surfaces, the intended implementation is the shared
Vue/document pipeline, not the current native iOS modal/sheet:

- Strong's / dictionary content is no longer owned by a dedicated native iOS
  sheet; it is presented through the normal reader document/window pipeline.
- Compare should stop being presented by the native Swift `CompareView` sheet
  and should use the same compare document flow Android uses.
- Multi-reference and cross-reference content should stop being presented by
  the native Swift `CrossReferenceView` sheet and should use the Vue
  `MultiDocument` flow.

This includes:

- Strong's / dictionary content, while preserving the dedicated
  `contentType: "strongs"` Vue route
- Compare content, including hidden-translation and restore behavior
- multi-reference and cross-reference content that Android routes through the
  fake multi document and Vue `MultiDocument`

The iOS reader host should also honor Vue modal-open state reported by the
embedded client so native host navigation does not escape an open Vue modal.

Native iOS sheets are acceptable for these reader document surfaces only if a
future ADR records a real iOS-specific requirement, such as a platform
capability, platform restriction, system-owned presentation requirement, or an
explicitly different iOS product feature. Convenience, current implementation
shape, or "already works natively" is not enough.

Every reader parity decision should use an honest evaluation:

- identify the Android source behavior and whether Android uses native UI,
  shared Vue UI, or the document/window pipeline
- identify the shared Vue/document capability and whether iOS can use it without
  brittle bridge or lifecycle hacks
- identify any real iOS platform constraint or product-specific requirement
- choose the closest Android-equivalent user experience that can be implemented
  cleanly
- document any intentional divergence in an ADR with a validation boundary and
  re-evaluation trigger

## Consequences

- Native iOS sheets for Strong's, Compare, and multi-reference content are not
  accepted final parity endpoints.
- #8, #123, and #124 have replaced the Strong's, Compare, and
  multi-reference native sheet paths with shared document-pipeline routing.
- The legacy `CrossReferenceView` callback is not a final parity endpoint for
  multi-reference content and should not be expanded as a replacement for the
  shared Vue `MultiDocument` path.
- A native iOS sheet may still be the right answer for a future surface, but
  only after the evaluation above shows that it is the honest parity or platform
  answer.
- Existing tests for the shared document routes protect the current bridge path.
  #125 implemented the related modal-open host-gating behavior.
- Future reader modal audits should first classify whether Android treats a
  surface as document-pipeline content, app-level native UI, shared Vue modal
  UI, or platform-only behavior before creating implementation work.

## Related

- [ADR 0006: Modal Presentation Ownership For Android Parity](0006-modal-presentation-ownership-for-android-parity.md)
- [ADR 0008: Parity Documentation Ownership](0008-parity-documentation-ownership.md)
- #8
- #122
- #123
- #124
- #125
