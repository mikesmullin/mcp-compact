#!/usr/bin/env bun
# mcp-compact: naive session-history compaction for Ada's immortal Angela session.
# One tool: compact_session_history — backs up the session jsonl, then drops
# image-payload events and tool_call/tool_result pairs so the next restart
# replays a smaller history into the model context.
#
# Naive by design (first pass): no summarization, no semantic merging.
# Ada-back must be STOPPED before a real (non-dryRun) compaction and
# restarted after, or appended events can race the rewrite and history
# already loaded in memory will not shrink.
import { existsSync, readFileSync, writeFileSync, copyFileSync } from 'fs'
import { join } from 'node:path'
import { runMcpStdioServer, textResult } from './shared/mcp-stdio.mjs'

ADA_ROOT = process.env.ADA_ROOT or '/workspace/ada'
SESSION_DIR = process.env.ADA_SESSION_DIR or join(ADA_ROOT, '.angela/sessions')
POINTER = process.env.ADA_SESSION_FILE or join(ADA_ROOT, '.angela/ada-session')

resolveSessionFile = (sessionId) ->
  id = String(sessionId or '').trim()
  unless id
    return { ok: false, error: "no session id given and pointer missing: #{POINTER}" } unless existsSync POINTER
    id = readFileSync(POINTER, 'utf8').trim()
  return { ok: false, error: 'empty session id' } unless id
  return { ok: false, error: "bad session id: #{id}" } unless /^[A-Za-z0-9._-]+$/.test id
  fp = join SESSION_DIR, "#{id}.jsonl"
  return { ok: false, error: "session file missing: #{fp}" } unless existsSync fp
  { ok: true, id, fp }

# Pixel weight, not metadata: data-URLs, image_url parts, or base64 runs big
# enough to only be a picture (tool-result metadata like {mimeType, bytes}
# is a few dozen bytes and is kept).
hasPixelBlob = (line) ->
  return true if /data:image\/[a-z0-9.+-]+;base64/i.test line
  return true if /"image_url"/.test line
  !!line.match /[A-Za-z0-9+\/]{4000,}={0,2}/

compactLines = (lines) ->
  parsed = lines.map (l) ->
    try JSON.parse l catch then null
  callIds = new Set()
  for o in parsed when o?.event_type is 'tool_call'
    cid = o.payload?.id
    callIds.add cid if cid
  kept = []
  removedImages = 0
  removedCalls = 0
  removedResults = 0
  for l, i in lines
    o = parsed[i]
    unless o
      kept.push l # corrupt line: keep rather than destroy
      continue
    if hasPixelBlob l
      removedImages += 1
      continue
    switch o.event_type
      when 'tool_call'
        removedCalls += 1
      when 'tool_result'
        cid = o.payload?.tool_call_id
        if not cid or callIds.has cid
          removedResults += 1
        else
          kept.push l
      else
        kept.push l
  { kept, removedImages, removedCalls, removedResults }

tools =
  compact_session_history:
    description: 'Slim Ada\'s session history file so the next restart fits context. ' +
      'Backs up the jsonl, then drops image-payload events and tool_call/tool_result pairs ' +
      '(naive first pass: no summarization). ' +
      'STOP ada-back before a real run and RESTART it after, or the trim has no effect ' +
      'and appended events can race the rewrite. Use dryRun first to preview counts.'
    inputSchema:
      type: 'object'
      properties:
        sessionId:
          type: 'string'
          description: 'session id (basename without .jsonl). Omit to use the pointer file.'
        dryRun:
          type: 'boolean'
          description: 'report what would be removed without writing. Default true.'
      required: []
    handler: ({ sessionId, dryRun }) ->
      dry = dryRun isnt false
      r = resolveSessionFile sessionId
      return textResult r.error, true unless r.ok
      raw = readFileSync r.fp, 'utf8'
      lines = raw.split('\n').filter (l) -> l.length > 0
      { kept, removedImages, removedCalls, removedResults } = compactLines lines
      summary =
        session: r.id
        file: r.fp
        dryRun: dry
        eventsBefore: lines.length
        eventsAfter: kept.length
        removedImages: removedImages
        removedToolCalls: removedCalls
        removedToolResults: removedResults
        bytesBefore: raw.length
        bytesAfter: null
        backupPath: null
      unless dry
        stamp = new Date().toISOString().replace(/[:.]/g, '-')
        backup = "#{r.fp}.pre-compact-#{stamp}"
        copyFileSync r.fp, backup
        out = if kept.length then kept.join('\n') + '\n' else ''
        writeFileSync r.fp, out
        summary.bytesAfter = out.length
        summary.backupPath = backup
        # keep the sidecar honest (informational only)
        sidecar = join SESSION_DIR, "#{r.id}.json"
        if existsSync sidecar
          try
            meta = JSON.parse readFileSync sidecar, 'utf8'
            meta.eventCount = kept.length
            meta.updatedAt = new Date().toISOString()
            writeFileSync sidecar, JSON.stringify(meta, null, 2)
          catch e then null
      textResult JSON.stringify summary, null, 2

await runMcpStdioServer
  name: 'compact'
  version: '0.1.0'
  tools: tools
