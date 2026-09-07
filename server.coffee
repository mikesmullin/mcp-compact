#!/usr/bin/env bun
# mcp-compact: naive session-history compaction for Ada's immortal Angela session.
# Two tools: context_analysis (read-only report for choosing what to jettison)
# and compact_session_history (backup + drop, blanket or sha-targeted).
#
# Naive by design (first pass): no summarization, no semantic merging.
# A real compact run takes effect in Ada's memory at the next turn boundary
# (ada-back reloads on the tool result); manual runs while the back is
# stopped apply on next startup.
import { existsSync, readFileSync, writeFileSync, copyFileSync } from 'fs'
import { join } from 'node:path'
import { createHash } from 'node:crypto'
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

# The five eligible kinds, and nothing else. Display names are the stable
# vocabulary for the report and removal: user_prompt, reasoning, tool_call,
# tool_response, assistant_response. Telemetry (provider_*, gen_info,
# harness), system prompts, catalogs, and session bookkeeping are invisible
# to the report and immortal to the trimmer.
displayType = (o) ->
  return null unless o
  switch o.event_type
    when 'tool_call' then 'tool_call'
    when 'tool_result' then 'tool_response'
    when 'reasoning' then 'reasoning'
    when 'context_window'
      role = o.payload?.role
      if role is 'user' then 'user_prompt'
      else if role is 'assistant' then 'assistant_response'
      else if role is 'reasoning' then 'reasoning'
      else null
    else null

# Pixel weight, not metadata: data-URLs, image_url parts, or base64 runs big
# enough to only be a picture (tool-result metadata like {mimeType, bytes}
# is a few dozen bytes and is kept). Only ever applied to the five kinds.
hasPixelBlob = (line) ->
  return true if /data:image\/[a-z0-9.+-]+;base64/i.test line
  return true if /"image_url"/.test line
  !!line.match /[A-Za-z0-9+\/]{4000,}={0,2}/

# `Sun, Sep 6 @ 5:21p` — same shape as Ada's user-prompt prefixes, local time.
fmtTs = (iso) ->
  try
    d = new Date iso
    return 'no-ts' if isNaN d.getTime()
    days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat']
    months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
    h24 = d.getHours()
    ampm = if h24 < 12 then 'a' else 'p'
    h12 = h24 % 12
    h12 = 12 if h12 is 0
    min = String(d.getMinutes()).padStart 2, '0'
    "#{days[d.getDay()]}, #{months[d.getMonth()]} #{d.getDate()} @ #{h12}:#{min}#{ampm}"
  catch e then String(iso or 'no-ts')

sha1hex = (s) -> createHash('sha1').update(s, 'utf8').digest('hex')

# One-line human gist per event for the analysis report: tool name plus a
# YAML-flow one-liner of parameters (truncated to 100 chars at render).
flowYaml = (v) ->
  if v is null or v is undefined then return 'null'
  if typeof v is 'string'
    return v if /^[A-Za-z0-9_][A-Za-z0-9_.\/-]*$/.test(v) and v.length < 60
    return JSON.stringify v
  if typeof v in ['number', 'boolean'] then return String v
  if Array.isArray v
    return '[' + (v.slice(0, 8).map(flowYaml).join ', ') + (if v.length > 8 then ', …]' else ']')
  if typeof v is 'object'
    ks = Object.keys v
    return '{' + ks.slice(0, 8).map((k) -> "#{k}: #{flowYaml v[k]}").join(', ') + (if ks.length > 8 then ', …}' else '}')
  String v

eventText = (o) ->
  p = o.payload or {}
  str = (v) ->
    if typeof v is 'string' then v else JSON.stringify(v ? '')
  switch o.event_type
    when 'context_window'
      role = p.role or '?'
      c = str p.content
      if role is 'assistant' and not c.trim() and Array.isArray(p.tool_calls) and p.tool_calls.length
        "assistant → calls: #{p.tool_calls.map((t) -> t?.function?.name or t?.name or '?').join ', '}"
      else
        "#{role}: #{c}"
    when 'reasoning'
      str p.text
    when 'tool_call'
      "#{p.name or 'call'} #{flowYaml p.args}"
    when 'tool_result'
      "#{p.name or p.tool or 'result'} => #{str p.text}"
    when 'provider_request'
      "llm request #{p.model or ''} msgs=#{p.messages_count ? '?'}"
    when 'provider_response'
      if p.error then "llm error #{str p.message}"
      else
        m = p.choices?[0]?.message or {}
        c = str m.content
        if c.trim() then c
        else
          tcs = m.tool_calls or []
          if tcs.length then "tool calls: #{tcs.map((t) -> t?.function?.name or '?').join ', '}" else '(empty reply)'
    when 'gen_info'
      "usage prompt=#{p.prompt_tokens} completion=#{p.completion_tokens}"
    when 'harness' then "harness #{p.kind or ''}"
    when 'session' then "session #{p.kind or ''}"
    when 'system' then 'system prompt'
    when 'tools' then "catalog (#{(p.tools or []).length}): #{(p.tools or []).map((t) -> t?.function?.name or t?.name or '?').join ', '}"
    when 'error' then "error #{str p.message}"
    else str p

clip100 = (text) ->
  s = String(text or '').replace(/\s+/g, ' ').trim()
  if s.length > 60 then s.slice(0, 60) + '…' else s

# Context budget in tokens, same denominator as Ada's pie ring:
# min(AGL per-model table, server floor). AGL yaml parsed directly (their
# own lookup misfires here); server -c has no API so ADA_SERVER_CTX env
# overrides an observed-verified default.
ctxBudget = ->
  try
    cfgPath = process.env.AGL_CONFIG_PATH or "#{process.env.HOME}/.config/agl/config.yaml"
    txt = readFileSync cfgPath, 'utf8'
    m = /^default_model:\s*(.+?)\s*$/m.exec txt
    spec = if m then m[1] else ''
    prov = null
    model = spec
    if (i = model.indexOf ':') > 0
      prov = model[0...i]
      model = model[i + 1..]
    num = (s) ->
      n = Number String(s or '').trim()
      if Number.isFinite(n) and n > 0 then n else 0
    agl = 0
    inWindows = false
    inProvider = false
    for line in txt.split '\n'
      if /^context_windows:\s*$/.test line
        inWindows = true
        inProvider = false
        continue
      if inWindows
        if /^[^ \t#]/.test line
          break
        pm = /^  ([^ :#]+):\s*$/.exec line
        if pm
          inProvider = pm[1] is prov
          continue
        if inProvider
          vm = /^    ([^ :#]+):\s*(\S+)/.exec line
          if vm
            if vm[1] is model and num(vm[2]) then agl = num vm[2]
            else if vm[1] is 'default' and agl <= 0 then agl = num vm[2]
    floor = Number(process.env.ADA_SERVER_CTX or 0)
    floor = 262144 unless floor > 0
    budget = if agl > 0 then Math.min agl, floor else floor
    { budget, agl, srv: floor, spec }
  catch e
    floor = Number(process.env.ADA_SERVER_CTX or 0) or 262144
    { budget: floor, agl: 0, spec: '' }

analyzeLines = (lines) ->
  rows = []
  excluded = 0
  for l in lines
    o = try JSON.parse l catch then null
    dt = displayType o
    unless dt
      excluded += 1
      continue
    rows.push {
      bytes: Buffer.byteLength l, 'utf8'
      sha: sha1hex l
      type: dt
      ts: fmtTs o.ts
      text: eventText o
    }
  total = rows.reduce ((s, r) -> s + r.bytes), 0
  { rows, total, excluded }

# Targeted removal: drop exactly the named events (sha prefix, min 4 chars)
# plus their tool_call/tool_result pair-mates so pairs never split.
# Only the five kinds are eligible; anything else is refused per sha.
removeByShas = (lines, parsed, requested) ->
  full = lines.map (l) -> sha1hex l
  drop = new Set()
  detail = {}
  for orig in requested
    norm = String(orig or '').trim().toLowerCase()
    if norm.length < 4
      detail[String orig] = 'too short (min 4 hex chars)'
      continue
    hits = []
    for h, i in full when h.startsWith norm
      hits.push i
    unless hits.length
      detail[String orig] = 'no match'
      continue
    eligible = hits.filter (i) -> displayType parsed[i]
    refused = hits.length - eligible.length
    for i in eligible
      drop.add i
    eids = eligible.map (i) -> parsed[i]?.event_id or "line#{i}"
    label = if eids.length is 1 then eids[0] else eids
    if refused > 0
      label = { removed: label, refused: "#{refused} matched but outside the five kinds" }
    detail[String orig] = label
  # pair expansion: a dropped call takes its result and vice versa
  callIds = new Set()
  resCids = {}
  parsed.forEach (o, i) ->
    return unless o
    if o.event_type is 'tool_call' and o.payload?.id
      callIds.add o.payload.id
    if o.event_type is 'tool_result' and o.payload?.tool_call_id
      (resCids[o.payload.tool_call_id] ?= []).push i
  callIdx = {}
  parsed.forEach (o, i) ->
    if o?.event_type is 'tool_call' and o.payload?.id
      callIdx[o.payload.id] = i
  for i in Array.from drop
    o = parsed[i]
    continue unless o
    if o.event_type is 'tool_call' and o.payload?.id
      for j in resCids[o.payload.id] or []
        drop.add j
    if o.event_type is 'tool_result' and o.payload?.tool_call_id
      j = callIdx[o.payload.tool_call_id]
      drop.add j if j?
  kept = lines.filter (_, i) -> not drop.has i
  { kept, drop, detail }

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
    unless displayType o
      kept.push l # immortal: outside the five kinds, never touched
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
  context_analysis:
    description: 'Read-only report on what is in Ada\'s session history, scoped to five kinds: ' +
      'user_prompt, reasoning, tool_call, tool_response, assistant_response (telemetry, system, catalogs excluded). ' +
      'Byte subtotals by kind, then one line per event `sha6 kind NNNtok: tool name + YAML-flow params…` ' +
      '(truncated at 100 chars). ' +
      'Top 25 heaviest first by default; raise limit + offset to enumerate everything. ' +
      'Name sha prefixes in compact_session_history removeShas to delete exactly those events.'
    inputSchema:
      type: 'object'
      properties:
        sessionId:
          type: 'string'
          description: 'session id (basename without .jsonl). Omit to use the pointer file.'
        sort:
          type: 'string'
          enum: ['largest', 'chrono']
          description: 'largest-heavy first (default) or file order.'
        limit:
          type: 'integer'
          default: 100
          minimum: 1
          maximum: 1000
          description: 'top-N heaviest lines (totals always cover the whole window; raise + offset to enumerate all).'
        offset:
          type: 'integer'
          default: 0
          minimum: 0
          description: 'skip this many listed lines (paging).'
      required: []
    handler: ({ sessionId, sort, limit, offset }) ->
      r = resolveSessionFile sessionId
      return textResult r.error, true unless r.ok
      raw = readFileSync r.fp, 'utf8'
      lines = raw.split('\n').filter (l) -> l.length > 0
      { rows, total, excluded } = analyzeLines lines
      s = String(sort or 'largest')
      s = 'largest' unless s in ['largest', 'chrono']
      rows = rows.slice().sort((a, b) -> b.bytes - a.bytes) if s is 'largest'
      lim = parseInt limit, 10
      lim = 100 unless lim >= 1
      lim = Math.min 1000, lim
      off0 = parseInt offset, 10
      off0 = 0 unless off0 >= 0
      page = rows.slice off0, off0 + lim
      byType = {}
      for row in rows
        e = byType[row.type] ?= { bytes: 0, count: 0 }
        e.bytes += row.bytes
        e.count += 1
      typeLines = Object.keys(byType).map (t) -> { type: t, bytes: byType[t].bytes, count: byType[t].count }
      typeLines.sort (a, b) -> b.bytes - a.bytes
      estTok = (b) -> Math.ceil b / 4  # bytes -> tokens; row.bytes below is always raw bytes
      for tl in typeLines
        tl.tok = estTok tl.bytes
      { budget, agl, srv, spec } = ctxBudget()
      used = null
      try
        meta = JSON.parse readFileSync (join SESSION_DIR, "#{r.id}.json"), 'utf8'
        n = Number meta?.lastPromptTokens
        used = n if Number.isFinite(n) and n > 0
      catch e then null
      usedEst = estTok total
      usedLabel = if used? then "#{used}tok" else "~#{usedEst}tok est"
      usedPct = if budget > 0 then ((if used? then used else usedEst) / budget * 100).toFixed 1 else '0.0'
      out = [
        "Context window: #{r.id}"
        "Window: #{usedLabel} / #{budget}tok (#{usedPct}%) in #{rows.length} events"
        "Budget #{budget}tok (#{spec or '?'}: AGL #{agl or 'miss'}, server floor #{srv})"
        "Excluded: #{excluded} telemetry/system events (never listed or removed)"
        "Tokens by type (est ~bytes/4):"
      ]
      for tl in typeLines
        tpct = if budget > 0 then (tl.tok / budget * 100).toFixed 1 else '0.0'
        out.push "  #{tl.type}: #{tl.tok}tok (~#{tpct}%) in #{tl.count} events"
      out.push "Showing top #{page.length} of #{rows.length} largest (offset=#{off0} limit=#{lim})"
      out.push ''
      for row in page
        out.push "#{row.sha.slice 0, 6} #{row.type} #{estTok row.bytes}tok: #{clip100 row.text}"
      textResult out.join '\n'

  compact_session_history:
    description: 'Slim Ada\'s session history file so context fits again. ' +
      'Backs up the jsonl, then drops image-payload events and tool_call/tool_result pairs ' +
      '(naive first pass: no summarization). Only user_prompt, reasoning, tool_call, tool_response, ' +
      'assistant_response are ever eligible — telemetry, system, and catalogs are immortal. ' +
      'Pass removeShas (sha prefixes from context_analysis) to delete exactly those events ' +
      'plus their tool_call/tool_result pair-mates instead of the blanket pass. ' +
      'Ada-back notices a real run and reloads the trimmed history into memory at the next ' + +
      'turn boundary — no restart needed. Use dryRun first to preview counts.'
    inputSchema:
      type: 'object'
      properties:
        sessionId:
          type: 'string'
          description: 'session id (basename without .jsonl). Omit to use the pointer file.'
        dryRun:
          type: 'boolean'
          description: 'report what would be removed without writing. Default true.'
        removeShas:
          type: 'array'
          items: { type: 'string' }
          description: 'optional sha prefixes (from context_analysis) to delete exactly, with pair-mates. Replaces the blanket pass when given.'
      required: []
    handler: ({ sessionId, dryRun, removeShas }) ->
      dry = dryRun isnt false
      r = resolveSessionFile sessionId
      return textResult r.error, true unless r.ok
      raw = readFileSync r.fp, 'utf8'
      lines = raw.split('\n').filter (l) -> l.length > 0
      parsed = lines.map (l) ->
        try JSON.parse l catch then null
      targeted = Array.isArray(removeShas) and removeShas.length > 0
      if targeted
        { kept, drop, detail } = removeByShas lines, parsed, removeShas
        removedImages = 0
        removedCalls = 0
        removedResults = 0
        drop.forEach (i) ->
          et = parsed[i]?.event_type
          if et is 'tool_call' then removedCalls += 1
          else if et is 'tool_result' then removedResults += 1
      else
        detail = null
        { kept, removedImages, removedCalls, removedResults } = compactLines lines
      summary =
        session: r.id
        file: r.fp
        dryRun: dry
        targeted: targeted
        shaDetail: detail
        eventsBefore: lines.length
        eventsAfter: kept.length
        removedTargeted: if targeted then drop.size else 0
        removedImages: removedImages
        removedToolCalls: removedCalls
        removedToolResults: removedResults
        bytesBefore: raw.length
        bytesAfter: null
        backupPath: null
      droppedAny = kept.length < lines.length
      if not dry and droppedAny
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
