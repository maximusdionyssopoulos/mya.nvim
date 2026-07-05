# nvim ACP agent plugin — concept v3

An AI agent plugin for Neovim built on the Agent Client Protocol (ACP),
fugitive-inspired: agent sessions exposed as addressable buffers that compose
with native vim machinery. The plugin is a *thin UI over the protocol* — no
client-side persistence, registries, or state beyond what a live Neovim
instance holds in memory.

## Core model

- Every view is a real buffer served through an `acp://` URL scheme via
  `BufReadCmd`:
  - `acp://<agent>/<session>/log` — the session history
  - `acp://<agent>/<session>/plan` — formatted plan, if the session has one
- One log buffer, two readings: the full view (prompts, tool calls, reasoning)
  and the clean view are the same buffer with `foldexpr` folds over
  reasoning/tool-call blocks. `zM` is the transcript; no second URL.
- Rendering is a pure projection of an in-memory, append-only event log per
  session. Live `session/update` notifications and `session/load` replay feed
  the same log, so auto-updating buffers and opening old sessions are one
  code path. The log lives only for the lifetime of the Neovim instance.

## Dashboard

- `:Acp` opens the session dashboard. Sessions are fetched live from each
  configured agent's `session/list` on every open — no local cache. All
  sessions are local, so the fetch is cheap enough.
- Agents that don't advertise `sessionCapabilities.list` simply contribute no
  history to the dashboard. You can still start new sessions with them.
- Buffer-local single-key maps, discoverable via `g?`: `<CR>` open session,
  `o`/`O` split/tab, `cc` new prompt, `X` discard, `D` delete session
  (`session/delete` where supported).

## Prompting

- `:{range}Acp send {text}` — range-first, so `'<,'>` visual sends are one
  case; any motion/mark range composes. Files and ranges attach as ACP
  content blocks.
- A `buftype=prompt` buffer attached to the session view for multi-line
  composition; the cmdline command remains for one-liners.
- Omni-completion in the prompt buffer for file/buffer mentions; agent slash
  commands (from `available_commands` updates) completed there too.

## Per-message metadata & statusline

- Messages display the session config options (model, thinking/effort) in
  effect when the prompt was sent — held in the in-memory session state, using
  Session Config Options (not the deprecated modes API).
- Statusline/winbar line per session: model · effort · context % · agent ·
  cost, fed by the `usage_update` notification (`used`/`size` tokens, optional
  `cost`). Both agent-optional — degrade to "—".
- Exposed as an `AcpStatusline()`-style component function users wire into
  their own statusline/winbar.

## Edits & review

- Advertise `fs.readTextFile`/`fs.writeTextFile` so agent edits route through
  the client; render diff content (old/new + absolute path) from
  `tool_call` / `tool_call_update`.
- Review granularity is the **tool call** (matching `session/request_permission`).
  A multi-file tool call is reviewed as one unit: a fugitive-style `=` expands
  it into browsable hunks across files, `dv` opens any hunk side-by-side via
  native diff mode, but accept/reject applies to the whole tool call.
  Per-hunk accept/reject is explicitly deferred.
- No accept-all: tool calls are reviewed one by one; the turn blocks while a
  permission is pending (protocol behavior, and the intended workflow).
- Pending edits populate the quickfix; `:cnext` drives the review.
- Apply accepted edits as buffer edits (`nvim_buf_set_text`) where the file is
  loaded (undoable, preserves marks); plain fs writes otherwise. Keep a
  `checktime`/`FileChangedShell` safety net for agents that touch disk
  directly.

## Agent features included

- `session/cancel` on an ergonomic map; permission prompts answered through
  `vim.ui.select` (cancelled turn → outcome `"cancelled"`).
- `authenticate` flows for agents that need login.
- `terminal/*` capability on `jobstart`/`:terminal` so agents can run
  builds/tests; live output rendered from terminal content in tool calls.
- MCP server passthrough on `session/new`.
- Tool-call `locations` → follow mode and jumplist entries; `gf` on paths in
  the log buffer.
- `vim.notify` when a turn finishes or a permission is waiting.
- Out of scope (no protocol support): conversation forking / edit-and-retry.

## Configuration

- Standard Lua plugin convention: `require('acp').setup({...})` — agents
  (command, args, env), keymaps, diff/fold preferences, notification behavior.
  A deliberate departure from fugitive's zero-config purism.

## Architecture

- **Pure Lua**, two layers:
  1. Protocol module — `vim.uv` spawn + stdio pipes, JSON-RPC framing,
     `vim.json`, session state. No UI imports. All uv callbacks funnel
     through `vim.schedule`.
  2. UI plugin — URL scheme, dashboard, prompt buffers, review flow.
- No native/Rust core, no build step.

---

## Consequences of these decisions (recorded for later)

**No client-side persistence:**
- Agents without `session/list` have *no* visible history: their sessions
  appear nowhere after the Neovim instance that created them exits, and their
  session IDs are lost, so they can never be resumed even if the agent
  supports `session/load`. History for those agents is effectively
  single-instance and ephemeral.
- An agent that supports `list` but not `load` produces dashboard rows that
  can't be opened at all — we hold no cached transcript to fall back on.
  The dashboard must show this state rather than fail on `<CR>`.
- Per-message model/effort attribution only exists for prompts sent from the
  current Neovim instance. After `session/load`, replayed messages carry no
  config metadata (the protocol doesn't attest it), so old messages render
  without model/mode. Same for cost: `usage_update` is live-push, so a
  resumed session's price display starts unknown.
- Cross-instance coordination is out: two Neovim instances talking to the same
  agent see each other's sessions only through `session/list`, and may race on
  edits to the same files.

**Live-fetch dashboard:**
- Opening `:Acp` requires spawning + initializing every configured agent (or
  keeping them warm). Fine locally, but agent startup time directly becomes
  dashboard latency; a keep-alive policy is a config knob, not a cache.
- Dashboard content is only as complete and as well-titled as each agent's
  `session/list` implementation.

**Single folded log buffer:**
- `foldexpr` + `foldtext` must stay cheap on long sessions (they run per
  line on redraw); may need `vim.b` caching of fold levels computed at
  render time rather than a parsing foldexpr.
- The "clean" view can't reorder or reformat content (it's the same lines,
  folded) — e.g. no merging of a prompt + response into a compact exchange.

**Tool-call-granularity review:**
- Rejecting one bad hunk in a 10-file tool call rejects all 10 files; the
  practical recourse is a follow-up prompt telling the agent what to redo.
- If per-hunk accept lands later, it means constructing modified
  `fs/write_text_file` results or post-hoc reverts — revisit then.

**Required `setup()`:**
- The plugin does nothing until configured with at least one agent; docs and
  `:checkhealth acp` need to make the empty state obvious.
