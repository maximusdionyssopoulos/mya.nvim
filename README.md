# mya.nvim

A fugitive-style [Agent Client Protocol](https://agentclientprotocol.com)
client for Neovim: AI coding-agent sessions are addressable `mya://` buffers
that compose with native Vim machinery (folds, quickfix, diffsplit, jumplist)
instead of a dashboard-and-dialogs UI bolted on top.

Pure Lua, no external dependencies, no build step.

## Requirements

- Neovim >= 0.10 (`vim.uv`, `vim.json`, `vim.diff`, `vim.ui.select`)
- One or more ACP-speaking agent binaries on your `$PATH` (or an absolute
  `command` path in `setup()`)

## Setup

```lua
require('mya').setup {
  agents = {
    -- Claude Code, via its ACP adapter:
    --   npm install -g @zed-industries/claude-code-acp
    claude = {
      command = 'claude-code-acp',
    },

    -- Gemini CLI's built-in (experimental) ACP mode:
    gemini = {
      command = 'gemini',
      args = { '--experimental-acp' },
    },

    -- opencode's built-in ACP mode. opencode doesn't implement
    -- session/delete over ACP; session_delete_command makes the dashboard's
    -- D map fall back to its CLI (see :help mya-session_delete_command).
    opencode = {
      command = 'opencode',
      args = { 'acp' },
      session_delete_command = { 'opencode', 'session', 'delete', '{sessionId}' },
    },
  },
}
```

See `:help mya-setup` for every option (env vars, MCP server passthrough,
keep-alive/idle policy, review UI, notifications, statusline/winbar).

Every buffer-local keybind is configurable (or removable) through the
`keymaps` option — action name to lhs, `false` to disable:

```lua
require('mya').setup {
  agents = { ... },
  keymaps = {
    dashboard = { refresh = '<F5>' },
    log = { cancel = false },      -- unbind <C-c> in the transcript
    review = { accept = 'ga', reject = 'gr' },
  },
}
```

See `:help mya-keymaps` for every action and its default.

## Quickstart

1. `:Mya` opens the session dashboard — organized like fugitive's `:G`
   around what needs you: **Needs review** (pending permissions), **Running**,
   **Sessions**, **Agents**. `=` previews a session inline.
2. `<CR>` on a session opens its transcript in the current window (`o`
   split, `gO` vsplit, `O` tab; `n` starts a new session). Or skip the
   dashboard: `:Mya open <agent>/<Tab>`.
3. `cc` opens a compose buffer under the transcript — a plain `acwrite`
   buffer, the `gitcommit` model: edit like any buffer, **`:w` sends**
   (`:wq` sends and closes). No insert-mode maps, no widget: your completion
   plugin attaches via the `mya-compose` filetype, and native `<C-x><C-f>`
   completes paths. One-liners go through `:Mya send fix the tests`
   (cmdline history = prompt history), and `:'<,'>Mya send explain this`
   attaches the selected range from any file buffer.

Context is explicit, never parsed out of your prompt: `:{range}Mya include`
/ `:Mya include <path>` stage files or ranges for the next send. Staged
blocks show as real `# staged:` comment lines below the draft; delete one to
unstage it, and they are stripped from the sent message. Agent slash
commands complete on the cmdline (`:Mya send /<Tab>`).

Tool-call edits route through a fugitive-status-style review buffer
(`a`/`r` to accept/reject, `=` to expand hunks, `dv` to diffsplit); permission
prompts, plans, reasoning, and terminal output all render inline in the
transcript. `g?` in any mya.nvim buffer shows that buffer's maps.

## Docs

- `:help mya` — full vimdoc: setup reference, every `:Mya` subcommand, and
  every buffer's maps.
- `:checkhealth mya` — Neovim version, whether `setup()` has run, and
  per-agent executable/capability status.
