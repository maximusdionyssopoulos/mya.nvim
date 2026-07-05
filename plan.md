# Implementation plan — nvim ACP agent plugin

Companion to `concepts-v3.md`. Phases are ordered so every phase ends with
something runnable and testable. Pure Lua, Neovim ≥ 0.10 (`vim.uv`,
`vim.system`, `vim.json`, `splitkeep`, `vim.ui.select`).

## Module layout

```
lua/acp/
  init.lua          -- setup(), public API, AcpStatusline()
  config.lua        -- defaults, validation, agent definitions
  rpc.lua           -- JSON-RPC over stdio: framing, correlation, dispatch
  agent.lua         -- agent process lifecycle: spawn, initialize, auth, shutdown
  session.lua       -- session objects, event log, subscriptions
  client.lua        -- client-served methods: fs/*, permissions, terminal/*
  ui/
    url.lua         -- acp:// scheme, BufReadCmd routing, buffer registry
    dashboard.lua   -- :Acp session list
    log.lua         -- session log rendering, folds, streaming updates
    plan.lua        -- plan buffer rendering
    prompt.lua      -- prompt buffer, :Acp send, completion
    review.lua      -- edit review: '=' hunks, diffsplit, quickfix
  util.lua          -- vim.schedule wrappers, async helpers, logging
plugin/acp.lua      -- :Acp command stub, lazy require
doc/acp.txt         -- vimdoc
tests/
  fake_agent.lua    -- scriptable ACP agent for integration tests (run via `nvim -l`)
  ...
```

## Phase 1 — protocol core (`rpc.lua`, `agent.lua`)

The foundation everything sits on; matches how Neovim's own LSP client works.

- **Transport**: `vim.uv.spawn` with stdin/stdout pipes; stderr to a log file.
  ACP frames messages as newline-delimited JSON (not LSP `Content-Length`
  headers) — verify against the spec/schema before locking the framing code.
  Buffer partial lines; `vim.json.decode` per line.
- **RPC layer**: outgoing requests with id → callback correlation table;
  incoming messages split three ways: responses (resolve callback),
  notifications (dispatch to handler table), *incoming requests* (agent
  calling us — must send a response, including error responses for unknown
  methods). Every handler entry point wraps in `vim.schedule`; nothing touches
  nvim API from a uv callback.
- **Lifecycle** (`agent.lua`): lazy spawn on first use per agent; `initialize`
  handshake advertising client capabilities (`fs.readTextFile`,
  `fs.writeTextFile`, later `terminal`); record agent capabilities
  (`loadSession`, `sessionCapabilities.list`, config options). Keep-alive
  policy from config (keep warm vs kill after idle). Crash detection: on
  unexpected exit, mark all its sessions errored, notify, allow respawn.
- **Auth**: if `initialize` says auth required, drive `authenticate` and
  surface method choices via `vim.ui.select`.
- **Errors**: JSON-RPC error objects mapped to `vim.notify` + session state;
  malformed JSON from agent logged, connection kept alive if possible.

Deliverable: `:lua require('acp.agent').get('gemini'):request('initialize', ...)`
round-trips against a real agent and the fake agent.

## Phase 2 — sessions & event log (`session.lua`)

- Session object: `{ id, agent, cwd, title, status, config_options, usage,
  events = {}, pending_tool_calls = {}, subscribers = {} }`.
  `status ∈ idle | prompting | waiting_permission | error`.
- `session/new` (with cwd + MCP servers from config), `session/prompt`
  (one in flight per session — queue or reject a second prompt),
  `session/cancel`, `session/load` (replay feeds the same event-append path
  as live updates).
- `session/update` handler: normalize every update kind
  (`agent_message_chunk`, `agent_thought_chunk`, `user_message_chunk`,
  `tool_call`, `tool_call_update`, `plan`, `available_commands_update`,
  config/mode changes, `usage_update`) into event-log appends; coalesce
  streamed chunks into the current message event.
- Subscription API: `session:on_event(fn)` → UI buffers attach/detach; events
  are delivered post-`vim.schedule`, batched per tick to keep redraws sane.
- Record config options in effect on each prompt event (for per-message
  model/effort display; in-memory only, per concepts-v3).

Deliverable: scripted conversation against fake agent produces the expected
event log; cancellation mid-turn leaves consistent state.

## Phase 3 — URL scheme & log buffer (`ui/url.lua`, `ui/log.lua`)

- `BufReadCmd acp://*`: parse `acp://<agent>/<session>/<view>`, create scratch
  buffer (`buftype=nofile`, `bufhidden=hide`, `noswapfile`, `nomodifiable`),
  register in bufnr↔(session, view) map, trigger load (`session/load` if not
  in memory and agent supports it; error message in-buffer if it doesn't).
- Log rendering: event log → lines. Sections per exchange: prompt header
  (model · effort · timestamp), response text, reasoning blocks, tool calls
  (kind icon, title, status, locations). Markdown highlighting via treesitter
  on the buffer; extmark highlights for headers/status.
- Streaming: subscriber appends via `nvim_buf_set_lines` with
  modifiable-toggle; batch per scheduler tick; autoscroll only if cursor was
  at bottom (fugitive-log behavior).
- Folds: fold levels computed at render time and stored (extmark or line map);
  `foldexpr` is a table lookup, `foldtext` shows e.g.
  `⏵ tool: edit src/main.rs (completed)` or `⏵ reasoning (1.2k tokens)`.
  `zM` = clean transcript view.
- `gf`/`gF` work on paths (`includeexpr`/`isfname` tuning); tool-call
  `locations` get `<CR>` jump maps + jumplist entries.
- Plan buffer (`ui/plan.lua`): render plan entries + status checkboxes from
  plan events; same subscription mechanism.

Deliverable: open `acp://fake/<id>/log`, watch a live turn stream in, fold to
transcript view, jump to a location.

## Phase 4 — dashboard (`ui/dashboard.lua`)

- `:Acp` → scratch buffer listing sessions grouped by agent. On open: ensure
  each configured agent is initialized, call `session/list` (paginate through
  cursors) where supported; agents without the capability get a
  "(no session listing)" group header with only in-memory sessions.
- Row: running-indicator · title · agent · relative updatedAt · status
  (resumable / view-only / live). `list`-but-no-`load` sessions render
  dimmed with a "not resumable" annotation (per concepts-v3 consequences).
- Maps (all buffer-local, `g?` help float): `<CR>` open log, `o`/`O`
  split/tab, `cc` prompt in new/selected session, `D` `session/delete` with
  confirm, `R` refresh, `q` close.
- Live refresh of running-state rows via session subscriptions.

Deliverable: dashboard against two fake agents (one with list, one without).

## Phase 5 — prompting (`ui/prompt.lua`)

- `:{range}Acp send {text}`: builds content blocks — text + optional resource
  block for the range (path, line span, text) or whole files via
  `:Acp send @file ...` args. `:Acp` subcommand completion (`send`, `cancel`,
  `new`, plus agent slash commands from `available_commands`).
- Prompt buffer: `buftype=prompt` window below the log view; `<CR>` in insert
  submits, multi-line via `<S-CR>`/`o`; prompt callback assembles content
  blocks. Omni-completion: file paths, open buffers, slash commands.
- Turn state in winbar: spinner while `prompting`, key hint while
  `waiting_permission`; `<C-c>`/`:Acp cancel` → `session/cancel`.
- `vim.notify` on turn end / permission wait (config-gated).

Deliverable: full conversation loop from prompt buffer and from a visual
range, against a real agent.

## Phase 6 — client services & edit review (`client.lua`, `ui/review.lua`)

The heart of the plugin; largest phase.

- `fs/read_text_file`: serve from loaded buffer contents when the file has a
  buffer (unsaved changes included — that's the point), else read disk;
  honor line/limit params.
- `fs/write_text_file`: never write immediately. Store as pending content on
  the owning tool call; actual application happens on accept.
- `session/request_permission`: correlate to tool call; set session status
  `waiting_permission`; open/focus the review flow. Answer options via
  `vim.ui.select` fallback, but primary UX is review-buffer keys. Turn
  cancelled while pending → respond `outcome: "cancelled"`.
- Review model: a pending tool call = one review unit holding n file diffs
  (from tool-call diff content and/or intercepted `fs/write_text_file`).
- Review buffer (fugitive-status style): one section per pending tool call,
  `=` expands into per-file hunks (computed with `vim.diff`), `dv` on a
  file/hunk → `:diffsplit` proposed-vs-current (scratch buffer for proposed),
  inline preview via virtual lines as alternate view (config default).
  `a` accept tool call, `r` reject, both reply to the pending permission and
  apply/discard all its files atomically.
- Apply: `nvim_buf_set_text` diff-application for loaded buffers (undoable),
  `fs` write otherwise; fire `checktime` after; `FileChangedShell` autocmd
  guards direct-disk agents.
- Quickfix: `:Acp qf` (and auto on permission, config-gated) fills quickfix
  with one entry per file-hunk (`quickfixtextfunc` renders tool-call title +
  hunk summary); `:cnext` navigates, review keys work from target windows.

Deliverable: multi-file edit from a real agent reviewed hunk-by-hunk and
accepted/rejected as a unit; state consistent after reject + follow-up prompt.

## Phase 7 — usage & statusline

- `usage_update` → session.usage; `require('acp').statusline(buf?)` returns
  `model · effort · 42% ctx · gemini · $0.13` with graceful "—" for missing
  fields; winbar auto-set on acp:// buffers (config-gated).

## Phase 8 — terminal capability

- Advertise `terminal` capability; implement `terminal/create` (`jobstart` with
  output ring buffer), `terminal/output`, `terminal/wait_for_exit`,
  `terminal/kill`, `terminal/release`. Tool calls with terminal content get an
  "open terminal" map that shows the live `:terminal`-style buffer.
- Ship after Phase 6 — agents degrade fine without it, and permission review
  must exist first since command execution rides the same permission flow.

## Phase 9 — polish & release

- `:checkhealth acp`: nvim version, agents configured, binaries found,
  handshake + capability dump per agent (makes the "setup required" emptiness
  obvious).
- `doc/acp.txt` vimdoc; README with agent recipes (Claude Code, Gemini CLI,
  opencode…).
<!-- - Follow mode (config off by default): tool-call `locations` move cursor in a -->
<!--   designated window. -->
- Log level config + `:Acp log` opening the rpc trace for debugging.

## Testing strategy

- **fake_agent.lua**: standalone script (`nvim -l` or luajit) speaking ACP on
  stdio, driven by a scenario table (respond to initialize/new/prompt with
  scripted update sequences, request permissions, call fs methods, misbehave
  on demand: garbage JSON, crash mid-turn, never-answering). This is the
  workhorse — protocol, session, and UI phases all integration-test against
  it headlessly.
- Unit tests (mini.test or plenary.busted, run headless in CI): rpc framing
  (partial lines, batched lines), event-log projection, fold-level
  computation, diff/hunk model, statusline formatting.
- Manual test matrix against 2–3 real agents before release; capability
  differences (list/load/usage present vs absent) covered by fake-agent
  scenarios.

## Risks / open items

- Confirm ndjson framing + exact v1 method/field names against the ACP JSON
  schema before Phase 1 hardens (generate a `types.lua` reference from the
  schema; keep it as documentation, not runtime validation).
- Session Config Options are newly stabilized — check per-agent support and
  keep the deprecated modes fallback behind a shim in `agent.lua`.
- Fold/redraw performance on very long sessions (target: 10k-line log with no
  visible lag; fall back to windowed rendering if needed).
- Per-hunk accept/reject: deferred (concepts-v3); the review model
  intentionally keeps hunks as display-only children of a tool call so this
  can be added without remodeling.
