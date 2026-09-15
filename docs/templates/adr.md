---
adr: ADR-NNNN
title: "[Short decision title]"
description: "[One sentence describing the choice and why it matters]"
date: YYYY-MM-DD
status: proposed # proposed | accepted | rejected | superseded
review-status: pending_review # pending_review | reviewed
extends: []
extended-by: []
amends: []
amended-by: []
supersedes: []
superseded-by: null
decision-owner: "[Name or team]"
deciders: []
consulted: []
informed: []
tags: []
related-adrs: []
related-work-items: []
---

# ADR-NNNN: [Short decision title]

Use an ADR when a human decides one is needed or when, after investigation
and discussion, the team needs to record a direction to prevent architectural
drift. Explain choices future readers could not safely infer from code.
Keep delivery status, task lists, and test evidence in issues and pull requests.
Draft the record as a proposal; only a human can accept it.

Delete this introductory paragraph when writing the record.

## Decision

[State the proposed choice in plain language. Include the boundary of the
decision and any defaults readers might otherwise mistake for rules. Leave
unresolved mechanisms and nearby questions explicitly open. For an amendment,
identify exactly which earlier provision is replaced and what remains in
force. Do not present the proposal as already accepted.]

## Why this came up

[Explain the problem, the relevant constraints, and what prompted the
decision. Connect the proposed direction to the intent established with the
human. Link to earlier ADRs or work items instead of retelling their full
history.]

## Alternatives considered

### [Alternative]

[Explain why it was plausible and why the proposal does not select it.]

### [Alternative]

[Explain why it was plausible and why the proposal does not select it.]

## Consequences

- [What becomes easier or clearer.]
- [What tradeoff the proposal entails.]
- [Any migration or compatibility effect.]

## When to revisit this

[Name an observable change that would justify reopening the decision. Avoid
dates or speculative consumers unless they genuinely change the tradeoff.]

## References

- [Related work item, documentation, or prior ADR]

## Maintaining the record

This section is authoring guidance. Omit it from completed ADRs.

Use these statuses:

- `proposed`: open for human review; not accepted.
- `accepted`: a human has manually reviewed the ADR and manually committed
  this status through the pull-request process.
- `rejected`: considered but not selected.
- `superseded`: replaced in full by a later accepted ADR.

Start with `status: proposed` and `review-status: pending_review`. Never have
an agent or automation set or commit acceptance on a human's behalf. Pull-request
approval, merge, successful checks, agent review, and conversational agreement
do not substitute for human review and the human's manual acceptance commit.
Use `review-status: reviewed` only to reflect actual human review; it does not
by itself mean acceptance. Record actual participants without prescribing a
particular decision authority or approval hierarchy.

Acceptance records the human's adoption of the stated choice. Preserve that
choice and its reasons after acceptance; do not rewrite them to match later
implementation. Keep factual repairs rare and clearly marked as corrections.

Use `extends` when both decisions remain current, `amends` when a newer record
replaces named parts of this one, and `supersedes` when it replaces the whole
decision. Keep proposed relationships in the proposal. Only after human
acceptance, update the corresponding `*-by` field and a brief successor
pointer in the older record. An amendment or extension leaves the older ADR
accepted; only full replacement makes it superseded. Preserve its prose.

Keep investigation open regardless of ADR status. Pause implementation for
human alignment when a significant architectural choice remains unresolved.
Once a compatible direction is agreed, implementation may proceed while its
ADR is proposed. Implementation that contradicts an accepted ADR must wait
for a human to accept the amendment or supersession.

The front matter is used by the ADR index. Keep the identifier stable, use
links rather than copied delivery status in `related-work-items`, and update
the index when adding a record or reflecting a human decision. Keep each ADR
decision in its own branch and pull request, separate from dependent implementation.
