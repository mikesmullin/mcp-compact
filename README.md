<p align="center">
  <a href="#install">Install</a>
  ·
  <a href="#look-then-cut">Look, then cut</a>
  ·
  <a href="#the-two-tools">The two tools</a>
  ·
  <a href="#safety">Safety</a>
  ·
  <a href="#configuration">Configuration</a>
</p>

# 🗜️ mcp-compact

**Surgery for an immortal agent session — look at what's eating context, then cut exactly that.**

Ada never restarts. Her Angela session (`*.jsonl`, one event per line) accretes
forever: every user prompt, every reasoning trace, every tool call and result —
plus screenshots and image payloads that each weigh as much as a novella. The
usual options all disappoint: restart the session and she forgets who you are;
summarize aggressively and hard-won facts get paraphrased into mush; truncate
from the front and you amputate the conversation while keeping the bulkiest
junk. You end up with either **no memory or no room to think**.

`mcp-compact` is the opposite. It treats the session file as a patient, not a
log pile: first a read-only report that weighs every event in bytes and tokens
so you can *choose* what goes, then a trimmer that removes exactly what you
named — or, when you don't want to choose, a blanket pass that takes only the
provably dead weight. Telemetry, system prompts, and tool catalogs are immortal
and never listed or touched. Everything else keeps working: Ada notices a real
run and reloads the trimmed history into memory at the next turn boundary, no
restart dance.

**Why use it**

- **Look before you cut.** `context_analysis` weighs the whole window (bytes,
  ~tokens, share of budget) and lists one line per event —
  `sha6 kind NNNtok: gist…` — heaviest first, pageable to the full session.
- **Surgical or blanket.** Pass `removeShas` from the report to delete exactly
  those events, or run empty-handed for the blanket pass: image payloads plus
  `tool_call`/`tool_result` pairs. Nothing in between.
- **Pairs never split.** Naming a call takes its result; naming a result takes
  its call. The transcript stays coherent.
- **The denominator is honest.** The budget is `min(AGL per-model table, server
  floor)`, so the `% full` number matches the pie ring Ada shows, not a guess.
- **Safe by construction.** `dryRun` defaults true, real runs back up the file
  (`*.pre-compact-<stamp>`), refresh the sidecar counts, keep corrupt lines
  rather than destroy them, and refuse anything outside the five kinds.
- **Naive on purpose.** No summarization, no semantic merging — what survives is
  verbatim. (That's the v1 contract; summarization is the obvious next pass.)

## Install

Built for [Bun](https://bun.sh) + CoffeeScript. Not on npm — run it from local
disk as a stdio MCP server:

```sh
cd /workspace/mcp-compact
bun install
bun ./server.coffee            # stdio MCP; see Configuration below
```

Wired into Ada as the `compact` MCP (`prefix: false`), so the model sees
`context_analysis` and `compact_session_history` directly. `compact_session_history`
stays Tom-gated; `context_analysis` runs free.

## Look, then cut

This is the part worth reading. The loop is always the same: weigh the window,
pick the weight, remove it, keep talking.

**1. Weigh the window.** Ask what the session is made of. Totals always cover
the whole window; `limit` + `offset` just page the listing:

```
context_analysis({ sort: "largest", limit: 25 })
```

```
Context window: 2026-09-06
Window: 183420tok / 262144tok (70.0%) in 412 events
Budget 262144tok (gemma-4-26b: AGL 262144, server floor 262144)
Excluded: 96 telemetry/system events (never listed or removed)
Tokens by type (est ~bytes/4):
  tool_response: 94000tok (~35.9%) in 120 events
  reasoning: 41000tok (~15.6%) in 88 events
  ...
Showing top 25 of 412 largest (offset=0 limit=25)

a3f9c1 tool_response 18230tok: agent_browser_snapshot => {tabs: [...], …}
77bd20 tool_response 15411tok: read_file => {"content": "iVBORw0KGgo…}
...
```

Kinds are the stable vocabulary everywhere (report *and* removal):
`user_prompt`, `reasoning`, `tool_call`, `tool_response`, `assistant_response`.
Everything else — `provider_*` telemetry, `gen_info` usage, harness events,
system prompts, tool catalogs, session bookkeeping — is excluded from the report
and immortal to the trimmer.

**2. Preview the cut.** Everything is `dryRun: true` unless you say otherwise.
The blanket pass reports what it *would* drop; the targeted pass reports
per-sha resolution (`removed` vs. `no match` / `too short` / `refused`):

```
compact_session_history({ dryRun: true })
compact_session_history({ dryRun: true, removeShas: ["a3f9c1", "77bd20"] })
```

```json
{
  "session": "2026-09-06",
  "dryRun": true,
  "targeted": true,
  "eventsBefore": 412,
  "eventsAfter": 408,
  "removedToolCalls": 2,
  "removedToolResults": 2,
  "shaDetail": { "a3f9c1": "…", "77bd20": "…" }
}
```

Sha prefixes need 4+ hex chars; anything shorter is refused, anything matching
only immortal events is refused per sha, and pair-mates ride along automatically.

**3. Make the cut and keep talking.** Drop `dryRun` (or set it false). The
server backs up the jsonl, rewrites it, refreshes the sidecar `.json`
(`eventCount`, `updatedAt`) — and Ada-back notices the real run and reloads the
trimmed history into memory at the next turn boundary. Manual runs while the
back is stopped still apply on next startup. No restart needed either way.

## The two tools

| tool | what it does | writes? |
|---|---|---|
| `context_analysis` | Read-only report: budget line, `Tokens by type`, then one `sha6 kind NNNtok: gist` line per event (`largest` or `chrono`, `limit` ≤ 1000, `offset` pages). | never |
| `compact_session_history` | Slim the session file. Blanket: drop image-payload events + `tool_call`/`tool_result` pairs. Targeted (`removeShas`): drop exactly those events + pair-mates. | only when `dryRun: false` |

Resolution order for the session file: explicit `sessionId` (basename without
`.jsonl`), else the pointer file (default
`/workspace/ada/.angela/ada-session`). Bad ids and missing files are errors,
not guesses.

What counts as an image: `data:image/…;base64` URLs, `image_url` parts, or any
base64 run long enough to only be a picture (tool-result metadata like
`{mimeType, bytes}` is a few dozen bytes and is kept).

## Safety

The invariants, for when you want the full contract:

- **Five kinds, nothing else.** Only `user_prompt`, `reasoning`, `tool_call`,
  `tool_response`, `assistant_response` are ever eligible. Telemetry, system,
  catalogs, and bookkeeping are invisible to the report and immortal to the
  trimmer.
- **Pairs never split.** A dropped call takes its result(s); a dropped result
  takes its call — by `tool_call_id`, in both directions.
- **Pixels, not metadata.** The image detector keys on payload shape, so small
  metadata survives while screenshots and pasted pictures go.
- **Corrupt lines survive.** A line that won't parse is kept rather than
  destroyed.
- **Every real run is reversible.** Pre-rewrite backup beside the session file;
  sidecar counts refreshed so nothing downstream lies about the new size.
- **Dry first.** `dryRun` defaults true on the write tool. Preview counts, then
  commit.

## Configuration

Env vars (all optional; shown with defaults):

| var | default | what it does |
|---|---|---|
| `ADA_ROOT` | `/workspace/ada` | anchor for the session-dir and pointer defaults |
| `ADA_SESSION_DIR` | `$ADA_ROOT/.angela/sessions` | where `<id>.jsonl` + sidecar `<id>.json` live |
| `ADA_SESSION_FILE` | `$ADA_ROOT/.angela/ada-session` | pointer file holding the live session id |
| `AGL_CONFIG_PATH` | `~/.config/agl/config.yaml` | parsed directly for the per-model `context_windows` table |
| `ADA_SERVER_CTX` | `262144` | server floor; budget is `min(AGL table, floor)` |

## Contributing

Naive by design is a starting point, not a destination. The next pass is
summarization / semantic merging on top of the sha-targeted machinery — the
report already speaks the vocabulary (`removeShas`) the summarizer will need.
Until then: no new eligible kinds without updating `displayType`,
`compactLines`, and the pair-expansion together, and keep the report's one-line
gist (`sha6 kind NNNtok: …`) parseable — Ada reads it, not just humans.
