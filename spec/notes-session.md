# ACP v1 session-layer notes (verified against spec/schema.v1.json)

Addendum to `spec/notes.md`. Field names below are exact schema names.
Everything decoded with `luanil`: JSON `null` == absent key.

## session/new

Params: `{ cwd: string (absolute), mcpServers: [], additionalDirectories?: [string] }`
— `mcpServers` is REQUIRED. Empty Lua tables encode as JSON `[]` in Neovim
(verified: `vim.json.encode({}) == "[]"`), so a plain `{}` is correct for
empty required arrays; use `vim.empty_dict()` only where an empty OBJECT is
needed.

McpServerStdio: `{ name, command, args, env }` (env = [{name,value}]).

Response: `{ sessionId, modes?: SessionModeState, configOptions?: [SessionConfigOption] }`

## session/prompt

Params: `{ sessionId, prompt: [ContentBlock] }`.
Response (arrives at TURN END): `{ stopReason: "end_turn"|"max_tokens"|"max_turn_requests"|"refusal"|"cancelled" }`.
One prompt in flight per session (protocol allows queueing client-side).

## session/cancel — NOTIFICATION

Params `{ sessionId }`. The in-flight session/prompt still resolves, with
stopReason "cancelled". Client MUST answer any pending
session/request_permission for that session with outcome "cancelled".

## session/load

Params: `{ sessionId, cwd, mcpServers (required, same as new) }`.
Agent replays the whole conversation as ordinary `session/update`
notifications BEFORE responding to session/load; response
`{ modes?, configOptions? }` arrives after replay completes.
Gated by top-level `agentCapabilities.loadSession` boolean.

## session/list

Params: `{ cwd?: string, cursor?: string }` (both optional; omit cwd to list
all). Response: `{ sessions: [SessionInfo], nextCursor?: string }` — paginate
until nextCursor absent. SessionInfo:
`{ sessionId, cwd, title?, updatedAt? (ISO 8601 string), additionalDirectories? }`.

## session/delete

Params `{ sessionId }`. Empty-object response.
Gated by `sessionCapabilities.delete` (absent/null = unsupported, `{}` =
supported) — do NOT send when unadvertised (agents answer -32601). opencode
(verified against its main, 2026-07) advertises `{ close, fork, list,
resume }` and has no session/delete handler at all, though its own CLI
(`opencode session delete <id>`) deletes from the same storage its
session/list reads — hence the `session_delete_command` out-of-band fallback
in `acp/extern.lua`.

## session/close

Params `{ sessionId }`. Empty-object response. Gated by
`sessionCapabilities.close`. The agent releases its LIVE handle only; the
session still exists agent-side (opencode: still listed by session/list from
storage) and can be loaded/resumed later. Relevant to out-of-band deletion:
close first, or the agent's live registry resurrects the row.

## session/set_config_option

Params `{ sessionId, configId, value }` → response `{ configOptions: [SessionConfigOption] }`
(the full updated set). SessionConfigOption:
`{ id, name, description?, category?, type: "select", currentValue: string(value id), options }`
where options is `SessionConfigSelectOptions` — for `type=select`:
`options: [ { value, name, description? } ]` (value = SessionConfigValueId string)
possibly grouped (SessionConfigSelectGroup has `name` + `options` list — check
`options[1].options` presence to detect grouped form).
Also arrives unsolicited via `session/update` kind `config_option_update`
`{ configOptions: [...] }` (full replacement set).

## session/update — NOTIFICATION (agent → client)

Params: `{ sessionId, update }` where `update.sessionUpdate` is the
discriminator. Variants (exact tags) and their payload fields (flattened
beside `sessionUpdate`):

- `user_message_chunk` | `agent_message_chunk` | `agent_thought_chunk`:
  `{ content: ContentBlock, messageId? }` — a chunk of the CURRENT message;
  coalesce consecutive chunks of the same tag into one message event; a new
  message starts when the tag changes or a tool_call/plan/etc interrupts, or
  messageId changes.
- `tool_call`: full ToolCall:
  `{ toolCallId, title (req), kind?: "read"|"edit"|"delete"|"move"|"search"|"execute"|"think"|"fetch"|"switch_mode"|"other",
     status?: "pending"|"in_progress"|"completed"|"failed" (default pending),
     content?: [ToolCallContent], locations?: [{path, line?}], rawInput?, rawOutput? }`
- `tool_call_update`: same fields, all optional except toolCallId — MERGE
  non-nil fields into the existing tool call (arrays replace wholesale).
  May arrive for unknown toolCallId (treat as new).
- `plan`: `{ entries: [{ content: string, priority: "high"|"medium"|"low", status: "pending"|"in_progress"|"completed" }] }`
  — each update is the COMPLETE plan (replace, don't merge).
- `available_commands_update`: `{ availableCommands: [{ name, description, input? }] }`
- `current_mode_update`: `{ currentModeId }` (legacy modes API)
- `config_option_update`: `{ configOptions: [SessionConfigOption] }`
- `session_info_update`: `{ title?, updatedAt? }`
- `usage_update`: `{ used: int (req), size: int (req), cost?: { amount: number, currency: string } }`
  — cumulative snapshot, replace not add.

## ContentBlock (discriminator: `type`)

- `text`: `{ type, text, annotations? }` — render as markdown
- `image`: `{ type, data (b64), mimeType, uri? }`
- `audio`: `{ type, data, mimeType }`
- `resource_link`: `{ type, uri, name, title?, description?, mimeType?, size? }`
- `resource` (embedded): `{ type, resource: { uri, text, mimeType? } | { uri, blob } }`
  — this is the block type for attaching file/range context to prompts:
  `{ type = "resource", resource = { uri = "file:///abs/path", text = "<contents>" } }`
  Requires agent promptCapabilities.embeddedContext for prompts.

## ToolCallContent (discriminator: `type`)

- `content`: `{ type, content: ContentBlock }`
- `diff`: `{ type, path (abs), oldText?: string|null, newText: string }`
  (oldText null/absent = new file)
- `terminal`: `{ type, terminalId }` — live-render terminal output

## session/request_permission (agent → client REQUEST)

Params: `{ sessionId, toolCall: ToolCallUpdate, options: [PermissionOption] }`
PermissionOption: `{ optionId, name, kind: "allow_once"|"allow_always"|"reject_once"|"reject_always" }`
Response: `{ outcome: { outcome: "selected", optionId } | { outcome: "cancelled" } }`
(NOTE the nesting: result.outcome.outcome.)

## fs/* (agent → client REQUESTS)

- `fs/read_text_file` params `{ sessionId, path (abs), line?: 1-based int, limit?: int }`
  → `{ content: string }`. Serve from loaded buffer if file has one (include
  unsaved changes), else disk. line+limit = window of lines.
- `fs/write_text_file` params `{ sessionId, path (abs), content }` → `{}` (empty result ok).

## terminal/* (agent → client REQUESTS)

- `terminal/create` `{ sessionId, command, args?, env?: [{name,value}], cwd?, outputByteLimit? }` → `{ terminalId }`
- `terminal/output` `{ sessionId, terminalId }` → `{ output, truncated: bool, exitStatus?: { exitCode?, signal? } }`
- `terminal/wait_for_exit` `{ sessionId, terminalId }` → `{ exitCode?, signal? }` (respond when process exits)
- `terminal/kill` `{ sessionId, terminalId }` → `{}` (kill but keep output readable)
- `terminal/release` `{ sessionId, terminalId }` → `{}` (free everything)
Advertise via clientCapabilities.terminal = true.

## Empty-array encoding gotcha (Lua)

`vim.json.encode({})` produces `[]` in Neovim ≥0.10 — empty Lua tables encode
as arrays. For REQUIRED array params (`mcpServers`, `prompt`) plain `{}` is
correct. For empty OBJECT values use `vim.empty_dict()`. Write a test.
