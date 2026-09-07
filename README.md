# mcp-compact

Naive first pass at session-history compaction for Ada's immortal Angela
session (adjacent to `mcp-home`, same stdio kit).

One tool: `compact_session_history` — resolves the session jsonl (explicit
id or `.angela/ada-session` pointer), backs it up, drops image-payload
events and `tool_call`/`tool_result` pairs, rewrites the file, and refreshes
the sidecar `.json` counts. No summarization (yet).

`dryRun` defaults true: reports counts without writing.

No restart dance: ada-back watches for real (non-dry) runs of this tool
and reloads the trimmed history into memory at the next turn boundary.
(Manual runs while the back is stopped still apply on next startup.)

## Run

```bash
bun ./server.coffee            # stdio MCP; env: ADA_ROOT, ADA_SESSION_DIR, ADA_SESSION_FILE
```
