<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **and-bible-ios** (46393 symbols, 332818 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Interpreting Impact Risk

GitNexus impact levels describe dependency reach and potential blast radius. They are inputs to engineering judgment, not permission levels. HIGH or CRITICAL does not mean "do not edit," does not by itself require user approval, and must not be used to justify a parallel implementation. A central shared symbol may be the correct and safest place for a root-cause fix.

When impact is HIGH or CRITICAL:

- Inspect the direct callers, affected execution flows, contracts, and relevant tests before editing.
- Briefly report the blast radius, why the selected symbol is or is not the correct owner, what behavior must remain unchanged, and how the change will be validated. Continue without waiting for approval unless a genuine escalation condition below applies.
- Make the smallest coherent change that fixes the root cause at the existing source of truth. "Smallest" means the narrowest architecturally complete solution, not the fewest lines, files, callers, or lowest GitNexus risk score.
- If the high-impact symbol owns the behavior, edit it carefully rather than bypassing it. Prefer one shared implementation over duplicated logic, shadow state, feature-specific forks, adapters, or parallel implementations that can drift.
- Preserve unrelated behavior and validate affected contracts proportionally to the blast radius.
- Cross-check GitNexus output against the actual source and tests. Treat stale, incomplete, or ambiguous graph results as supporting evidence, not authority.

Ask the user before proceeding only when analysis reveals that the change would:

- materially expand product scope beyond the request;
- require a breaking shared, bridge, sync, persistence, or public API change;
- require a data migration, irreversible operation, or external/platform coordination;
- depend on ambiguous intended behavior that cannot be resolved from the code, tests, documentation, or established parity baseline; or
- affect critical behavior that cannot be validated safely.

A HIGH or CRITICAL score alone is never an escalation condition.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER avoid the correct shared implementation solely because its impact score is HIGH or CRITICAL.
- NEVER create duplicated logic, parallel features, shadow state, or a drift-prone workaround merely to reduce the reported blast radius.
- NEVER modify every reported dependent automatically. Impact results identify what must be inspected and validated, not necessarily what must be edited.
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
