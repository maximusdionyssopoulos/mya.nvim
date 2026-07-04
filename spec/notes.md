# ACP v1 protocol notes (verified against schema/v1, 2026-07-04)

Source of truth: `spec/schema.v1.json` + `spec/meta.v1.json`, vendored from
`agentclientprotocol/agent-client-protocol` @ main, `schema/v1/` (stable, not
`.unstable`). Docs: https://agentclientprotocol.com.

## Framing (confirmed)

- JSON-RPC 2.0 over stdio. **Newline-delimited JSON** — one message per line,
  delimited by `\n`; messages MUST NOT contain embedded newlines. No
  `Content-Length` headers (explicitly not LSP-style).
- Both sides send requests, notifications, and responses on the same pipe in
  any order; correlation is by `id`.

## Method names (from meta.v1.json)

Agent-side (we call these):
`initialize`, `authenticate`, `session/new`, `session/load`,
`session/set_mode`, `session/set_config_option`, `session/prompt`,
`session/cancel` (notification), `session/list`, `session/delete`,
`session/resume`, `session/close`, `logout`.

Client-side (agent calls us):
`session/request_permission` (request), `session/update` (notification),
`fs/write_text_file`, `fs/read_text_file`, `terminal/create`,
`terminal/output`, `terminal/release`, `terminal/wait_for_exit`,
`terminal/kill`.

Protocol-level: `$/cancel_request` (notification, either direction).

## initialize (key shapes)

Request params:

```jsonc
{
  "protocolVersion": 1,              // integer, required (uint16)
  "clientCapabilities": {            // optional, defaults all-false
    "fs": { "readTextFile": true, "writeTextFile": true },
    "terminal": false
  },
  "clientInfo": { "name": "acp.nvim", "version": "0.1.0", "title": "acp.nvim" }
}
```

Response:

```jsonc
{
  "protocolVersion": 1,              // if != ours and unsupported → disconnect
  "agentCapabilities": {
    "loadSession": false,            // gates session/load
    "promptCapabilities": { "image": false, "audio": false, "embeddedContext": false },
    "mcpCapabilities": { "http": false, "sse": false },
    "sessionCapabilities": {
      // each key: absent/null = unsupported; {} = supported
      "list": {}, "delete": {}, "resume": {}, "close": {}, "additionalDirectories": {}
    },
    "auth": {}
  },
  "authMethods": [ { "id": "...", "name": "...", "description": null } ],
  "agentInfo": { "name": "...", "version": "..." }
}
```

Notes:
- `sessionCapabilities.list` etc. use the "absent/null vs `{}`" convention —
  treat as truthy table check, not boolean.
- `session/load` support is the top-level `loadSession` boolean (schema note:
  will be unified into sessionCapabilities later).
- `authMethods` non-empty + agent returning error code `-32000` on other calls
  → drive `authenticate` with `{ "methodId": ... }`, then retry.

## Error codes

JSON-RPC standard: `-32700` parse, `-32600` invalid request, `-32601` method
not found, `-32602` invalid params, `-32603` internal.
ACP-specific: `-32800` request cancelled, `-32000` auth required,
`-32002` resource not found.

Error object: `{ "code": int, "message": string, "data": any? }`.

## Misc conventions

- Every params/result object accepts an optional `_meta` object; never assume
  anything about its contents; preserve it where we round-trip data.
- All file paths in the protocol are absolute.
- `session/cancel` is a **notification** (no response); the cancelled
  `session/prompt` still resolves, with `stopReason: "cancelled"`.
- `$/cancel_request` (`{ "requestId": ... }`) asks the peer to cancel an
  in-flight request; the request must still receive a response
  (conventionally error `-32800`).
