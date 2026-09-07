# mcp-compact

Naive first pass at session-history compaction for Ada's immortal Angela
session (adjacent to `mcp-home`, same stdio kit).

One tool: `compact_session_history` — resolves the session jsonl (explicit
id or `.angela/ada-session` pointer), backs it up, drops image-payload
events and `tool_call`/`tool_result` pairs, rewrites the file, and refreshes
the sidecar `.json` counts. No summarization (yet).

`dryRun` defaults true: reports counts without writing.

**Ordering matters:** stop `ada-back` before a real run, restart after.
Otherwise appended events can race the rewrite and the in-memory history
never shrinks.

## Run

```bash
bun ./server.coffee            # stdio MCP; env: ADA_ROOT, ADA_SESSION_DIR, ADA_SESSION_FILE
```
