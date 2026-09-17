<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **and-bible-ios** (51527 symbols, 437685 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/and-bible-ios/context` | Codebase overview, check index freshness |
| `gitnexus://repo/and-bible-ios/clusters` | All functional areas |
| `gitnexus://repo/and-bible-ios/processes` | All execution flows |
| `gitnexus://repo/and-bible-ios/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->

## Repository Impact And Validation Policy

Choose the scope required to resolve the underlying mechanism and all affected
paths of the selected behavior. Understand the full impact and validate it. Do
not reduce the number of changed files, callers, or subsystems when doing so
preserves the defect or introduces another workaround.

GitNexus reports indexed dependencies. HIGH/CRITICAL describes graph reach;
“WILL BREAK” does not prove incompatibility. Inspect contracts, state
ownership, and callers. Broader reach requires appropriate validation and does
not itself require permission or deferral.

Supplement graph results with source and runtime tracing across observation,
callbacks, notifications, persistence, native interfaces, JavaScript strings,
and bridge events. Record traversal limits and unresolved dependencies.

Select tests from affected contracts and user workflows. A focused test set is
sufficient only when it covers that impact. A passing test that counts source
branches does not prove Android behavior.

Existing test expectations are evidence to review, not authority to preserve
current code. Derive parity expectations independently from Android behavior
and data contracts. Assert outcomes at the boundary the test actually
exercises. Source-shape checks belong only to explicit structural rules and
cannot substitute for runtime behavior. Test observation must not change the
interaction being claimed, and repeated actions must not turn a failed single
action into a pass.

Delivery may be staged. A selected behavior remains incomplete until its full
acceptance criteria pass. Known gaps belong in explicit implementation work;
“accepted gap” must not be used as an indefinite parity exemption.
