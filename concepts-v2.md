# nvim ACP agent plugin — concept v2

An AI agent plugin for Neovim built on the Agent Client Protocol (ACP), designed
the way vim-fugitive is designed: no app-inside-the-editor, just agent sessions
exposed as addressable buffers that compose with native vim machinery.

## Core model

- Every view is a real buffer served through an `mya://` URL scheme via
  `BufReadCmd` (the fugitive trick):
  - `mya://<agent>/<session>/log` — full history: prompts, tool calls, reasoning
  - `mya://<agent>/<session>/transcript` — clean view: prompts & outputs only
  - `mya://<agent>/<session>/plan` — formatted plan, if the session has one
  - `mya://<agent>/<session>/edit/<n>` — a single proposed edit
  So `:edit`, `:split`, `:tab sview`, `:e!` (refresh), session files, and
  bookmarking all work for free.
- Rendering is a pure projection of an append-only event log per session.
  Live `session/update` notifications and `session/load` replay feed the same
  log, so auto-updating buffers and resuming old sessions are one code path.
- Alternative to two history buffers: one log buffer with `foldexpr` folds over
  reasoning/tool-call blocks — the "clean" view is just `zM`. Worth prototyping
  before committing to separate URLs.

## Dashboard (the `:G`-alike)

- `:Mya` opens the session dashboard: all sessions across configured agents,
  with agent/provider, running state, title, and last activity.
- Sourced from `session/list` (v1) where the agent advertises
  `sessionCapabilities.list`. Caveats to design around:
  - `session/list` is served *per agent* — building the dashboard means
    spawning/querying each configured agent and merging results.
  - Returned metadata (`sessionId`, `cwd`, `title`, `updatedAt`) does **not**
    include the agent name; the plugin attributes sessions by which agent
    answered. A thin local registry is still needed for agents without the
    capability, and to cache titles for instant dashboard startup.
  - `session/load` is a separate optional capability: some listed sessions may
    be viewable (from our cached event log) but not resumable. Show that state.
- Buffer-local single-key maps, discoverable via `g?` (fugitive vocabulary):
  `<CR>` open session, `o`/`O` split/tab, `cc` new prompt, `dd`/`dv` diff the
  edit under cursor, `X` discard, `D` delete session (`session/delete` if
  supported).

## Prompting

- `:{range}Mya send {text}` — range-first, so `'<,'>` visual sends are just one
  case; any motion/mark range composes. Context (files, ranges) attaches as
  ACP content blocks.
- A `buftype=prompt` buffer attached to the session view for multi-line
  composition; the cmdline command remains for one-liners.
- Omni-completion in the prompt buffer for @-file/buffer mentions; agent slash
  commands (from `available_commands` updates) completed on the cmdline.

## Per-message metadata & statusline

- Each message records the session config options (model, thinking/effort)
  *client-side at prompt time* — the protocol does not attest which model
  served a message. Use Session Config Options, not the deprecated modes API
  (support both while agents transition).
- Statusline data comes from the now-stable `usage_update` notification:
  `used`/`size` tokens (context %) and optional `cost`. Both are
  agent-optional — degrade to "—".
- Expose an `MyaStatusline()` / winbar component function instead of drawing
  our own UI chrome; users wire it into their statusline. Winbar suits the
  per-session line (model · effort · ctx % · agent · cost).

## Edits & review  *(to re-review in detail later)*

- Advertise `fs.readTextFile`/`fs.writeTextFile` so agent edits route through
  the client (`fs/write_text_file`), and render tool-call diff content
  (old/new + absolute path) from `tool_call` / `tool_call_update`.
  Within the protocol, an agent with these capabilities advertised has no
  sanctioned path around the client — but nothing stops a badly behaved agent
  process from touching the disk directly, so keep a
  `FileChangedShell`/`checktime` safety net.
- Review is native diff mode: `dv`-style side-by-side via `:diffsplit`
  (`diffopt+=linematch:60`), or inline via extmarks/virtual lines
  (`vim.diff()` for hunks). Accept/reject with `diffget`/`diffput` semantics.
- No accept-all: edits are reviewed one by one. Note the protocol reality:
  one `session/request_permission` can cover a multi-file tool call, so
  "one at a time" may mean per tool call unless we split hunks ourselves; and
  the turn blocks while a permission is pending — the agent idles until the
  user catches up. Per-tool trust settings are a likely future concession
  (spec explicitly allows client-side auto-allow/reject policies).
- Apply accepted edits as buffer edits (`nvim_buf_set_text`) where the file is
  loaded, so they're undoable and preserve marks/extmarks; fs writes otherwise.
- Pending hunks populate the quickfix (`quickfixtextfunc` for rendering);
  `:cnext` drives the review. Per-session loclist as an alternative.

## Agent features to include

- `session/cancel` on an ergonomic map; queue a follow-up prompt mid-turn.
- `authenticate` flows (Claude Code, Gemini CLI need login).
- `terminal/*` capability implemented on `jobstart`/`:terminal` so agents can
  run builds/tests; live output as terminal content in tool calls.
- MCP server passthrough on `session/new`.
- Tool-call `locations` → follow mode (cursor tracks agent reads/edits) and
  jumplist/tagstack entries; `gf` works on paths in transcripts.
- `vim.notify` (and optional desktop notification) when a turn finishes or a
  permission is waiting — essential given review-gated edits.
- `vim.ui.select` for permission prompts so the user's picker is respected.
- Out of scope (no protocol support): conversation forking / edit-and-retry.

## Architecture

- **Pure Lua**, two layers:
  1. `mya.lua` protocol module — `vim.uv` spawn + stdio pipes, JSON-RPC framing,
     `vim.json`, typed session state. No UI imports; could stand alone as a
     library. All uv callbacks funnel through `vim.schedule`.
  2. UI plugin on top: URL scheme, dashboard, prompt buffers, diff review.
- No native/Rust core: message volumes are streamed text chunks (no perf case),
  and a build step breaks the "clone it and it works" property. If schema rigor
  is wanted, generate Lua validators from ACP's JSON schema. The clean layer
  split keeps a native swap possible later if ever needed.
- Zero-config startup, no mandatory `setup({})`: agents declared in a simple
  table or discovered from `.mya.json`; behavior tuned via native options and
  autocmds.

## Open questions

- Edit/diff review flow — revisit in depth (hunk splitting vs per-tool-call
  permissions, inline vs split default, quickfix ergonomics).
- One folded log buffer vs separate log/transcript URLs.
- Session registry format for agents without `session/list`.
