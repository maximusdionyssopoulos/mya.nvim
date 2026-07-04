--- Configuration: defaults, validation, and the active-config singleton.

local M = {}

---@class mya.McpServerConfig
---@field name string
---@field command string
---@field args string[]?
---@field env (table<string,string>|{name:string,value:string}[])? map form is normalized to the protocol [{name,value}] shape by session.lua

---@class mya.AgentConfig
---@field command string
---@field args string[]?
---@field env table<string,string>?
---@field cwd string?
---@field keep_alive boolean?
---@field idle_timeout_ms integer?
---@field mcp_servers mya.McpServerConfig[]? MCP servers passed through on session/new
---@field session_delete_command (string[]|fun(session_id: string): string[])? out-of-band CLI fallback for agents that don't advertise sessionCapabilities.delete (see mya/extern.lua); '{sessionId}' args are replaced, or the id is appended

---@class mya.LogConfig
---@field level mya.LogLevel?
---@field file string?

---@class mya.NotifyConfig
---@field turn_end boolean? vim.notify when a prompt turn ends
---@field permission boolean? vim.notify when a permission is waiting (Phase 6)

---@class mya.ReviewConfig
---@field ui "buffer"|"select"? primary permission UX ('select' = always vim.ui.select)
---@field open "auto"|"manual"? auto-open the review buffer when a permission arrives
---@field context_lines integer? unified-diff context lines for '=' hunk expansion
---@field auto_qf boolean? populate quickfix on permission arrival
---@field default_accept_kind "allow_once"|"allow_always"? preferred option kind on accept

---@class mya.UiLogConfig
---@field context_lines integer? context lines in rendered tool-call diffs
---@field icons boolean? status/kind icons on tool-call title lines

---@class mya.UiConfig
---@field bar "statusline"|"winbar"|false? session info on mya:// windows: merged into the window's statusline (default), a separate winbar at the top, or false to disable
---@field log mya.UiLogConfig?

--- Buffer-local keymaps, action name -> lhs. Set a value to `false` to
--- disable that map (users can then bind their own via the buffer's
--- filetype).
---@alias mya.Keymap string|false

---@class mya.KeymapsDashboardConfig
---@field open mya.Keymap? open session log (current window)
---@field open_split mya.Keymap? open session log (split)
---@field open_vsplit mya.Keymap? open session log (vsplit)
---@field open_tab mya.Keymap? open session log (tab)
---@field toggle_preview mya.Keymap? toggle inline session preview
---@field compose mya.Keymap? compose a prompt for the session under cursor
---@field new_session mya.Keymap? new session
---@field delete_session mya.Keymap? delete session
---@field refresh mya.Keymap? refresh dashboard
---@field close mya.Keymap? close dashboard window
---@field help mya.Keymap? open the dashboard's help section

---@class mya.KeymapsLogConfig
---@field jump mya.Keymap? jump to tool-call location
---@field next_turn mya.Keymap? next turn header
---@field prev_turn mya.Keymap? previous turn header
---@field compose mya.Keymap? compose a prompt for this session
---@field config mya.Keymap? change model/mode/variant
---@field review mya.Keymap? open the review buffer for this session
---@field cancel mya.Keymap? cancel the in-flight turn
---@field help mya.Keymap? open the log buffer's help section
---@field close_output mya.Keymap? close a terminal output view

---@class mya.KeymapsReviewConfig
---@field toggle_hunks mya.Keymap? toggle hunk expansion
---@field diffsplit mya.Keymap? open the unit under cursor as a diffsplit pair
---@field accept mya.Keymap? accept unit
---@field reject mya.Keymap? reject unit
---@field compose mya.Keymap? compose a prompt for this session
---@field help mya.Keymap? open the review buffer's help section
---@field close mya.Keymap? close review (also closes a diffsplit pair)

---@class mya.KeymapsComposeConfig
---@field close mya.Keymap? close the compose window
---@field help mya.Keymap? open the compose buffer's help section

---@class mya.KeymapsConfig
---@field dashboard mya.KeymapsDashboardConfig?
---@field log mya.KeymapsLogConfig?
---@field review mya.KeymapsReviewConfig?
---@field compose mya.KeymapsComposeConfig?

---@class mya.Config
---@field agents table<string, mya.AgentConfig>
---@field log mya.LogConfig
---@field notify mya.NotifyConfig
---@field review mya.ReviewConfig
---@field ui mya.UiConfig
---@field keymaps mya.KeymapsConfig

---@type mya.Config
local defaults = {
  agents = {},
  log = { level = 'info', file = nil },
  notify = { turn_end = true, permission = true },
  review = {
    ui = 'buffer',
    open = 'auto',
    context_lines = 3,
    auto_qf = false,
    default_accept_kind = 'allow_once',
  },
  ui = { bar = 'statusline', log = { context_lines = 3, icons = true } },
  keymaps = {
    dashboard = {
      open = '<CR>',
      open_split = 'o',
      open_vsplit = 'gO',
      open_tab = 'O',
      toggle_preview = '=',
      compose = 'cc',
      new_session = 'n',
      delete_session = 'D',
      refresh = 'R',
      close = 'q',
      help = 'g?',
    },
    log = {
      jump = '<CR>',
      next_turn = ']]',
      prev_turn = '[[',
      compose = 'cc',
      config = 'co',
      review = 'dr',
      cancel = '<C-c>',
      help = 'g?',
      close_output = 'q',
    },
    review = {
      toggle_hunks = '=',
      diffsplit = 'dv',
      accept = 'a',
      reject = 'r',
      compose = 'cc',
      help = 'g?',
      close = 'q',
    },
    compose = {
      close = 'q',
      help = 'g?',
    },
  },
}

---@type mya.Config?
local active = nil

local VALID_LEVELS = { trace = true, debug = true, info = true, warn = true, error = true }

--- vim.validate() error messages don't carry our '[mya] ' prefix; this
--- wraps it so every validation failure does.
---@param spec table
local function checked_validate(spec)
  local ok, err = pcall(vim.validate, spec)
  if not ok then
    error('[mya] ' .. tostring(err), 3)
  end
end

---@param name string
---@param agent_cfg mya.AgentConfig
local function validate_agent(name, agent_cfg)
  checked_validate {
    [('agents.%s'):format(name)] = { agent_cfg, 'table' },
  }
  checked_validate {
    [('agents.%s.command'):format(name)] = { agent_cfg.command, 'string' },
    [('agents.%s.args'):format(name)] = { agent_cfg.args, { 'table', 'nil' } },
    [('agents.%s.env'):format(name)] = { agent_cfg.env, { 'table', 'nil' } },
    [('agents.%s.cwd'):format(name)] = { agent_cfg.cwd, { 'string', 'nil' } },
    [('agents.%s.keep_alive'):format(name)] = { agent_cfg.keep_alive, { 'boolean', 'nil' } },
    [('agents.%s.idle_timeout_ms'):format(name)] = { agent_cfg.idle_timeout_ms, { 'number', 'nil' } },
    [('agents.%s.mcp_servers'):format(name)] = { agent_cfg.mcp_servers, { 'table', 'nil' } },
    [('agents.%s.session_delete_command'):format(name)] = {
      agent_cfg.session_delete_command,
      { 'table', 'function', 'nil' },
    },
  }
  if type(agent_cfg.session_delete_command) == 'table' then
    if #agent_cfg.session_delete_command == 0 then
      error(('[mya] agents.%s.session_delete_command must not be an empty list'):format(name), 2)
    end
    for i, a in ipairs(agent_cfg.session_delete_command) do
      if type(a) ~= 'string' then
        error(('[mya] agents.%s.session_delete_command[%d] must be a string'):format(name, i), 2)
      end
    end
  end
  if agent_cfg.mcp_servers then
    for i, srv in ipairs(agent_cfg.mcp_servers) do
      checked_validate {
        [('agents.%s.mcp_servers[%d]'):format(name, i)] = { srv, 'table' },
      }
      checked_validate {
        [('agents.%s.mcp_servers[%d].name'):format(name, i)] = { srv.name, 'string' },
        [('agents.%s.mcp_servers[%d].command'):format(name, i)] = { srv.command, 'string' },
        [('agents.%s.mcp_servers[%d].args'):format(name, i)] = { srv.args, { 'table', 'nil' } },
        [('agents.%s.mcp_servers[%d].env'):format(name, i)] = { srv.env, { 'table', 'nil' } },
      }
    end
  end
end

---@param opts mya.Config
local function validate(opts)
  checked_validate {
    agents = { opts.agents, 'table' },
    log = { opts.log, 'table' },
    notify = { opts.notify, 'table' },
  }
  checked_validate {
    ['notify.turn_end'] = { opts.notify.turn_end, { 'boolean', 'nil' } },
    ['notify.permission'] = { opts.notify.permission, { 'boolean', 'nil' } },
  }
  checked_validate {
    review = { opts.review, 'table' },
  }
  checked_validate {
    ['review.ui'] = { opts.review.ui, { 'string', 'nil' } },
    ['review.open'] = { opts.review.open, { 'string', 'nil' } },
    ['review.context_lines'] = { opts.review.context_lines, { 'number', 'nil' } },
    ['review.auto_qf'] = { opts.review.auto_qf, { 'boolean', 'nil' } },
    ['review.default_accept_kind'] = { opts.review.default_accept_kind, { 'string', 'nil' } },
  }
  if opts.review.ui and opts.review.ui ~= 'buffer' and opts.review.ui ~= 'select' then
    error(("[mya] invalid review.ui %q (expected 'buffer' or 'select')"):format(opts.review.ui), 2)
  end
  if opts.review.open and opts.review.open ~= 'auto' and opts.review.open ~= 'manual' then
    error(("[mya] invalid review.open %q (expected 'auto' or 'manual')"):format(opts.review.open), 2)
  end
  if
    opts.review.default_accept_kind
    and opts.review.default_accept_kind ~= 'allow_once'
    and opts.review.default_accept_kind ~= 'allow_always'
  then
    error(
      ("[mya] invalid review.default_accept_kind %q (expected 'allow_once' or 'allow_always')"):format(
        opts.review.default_accept_kind
      ),
      2
    )
  end
  checked_validate {
    ui = { opts.ui, 'table' },
  }
  checked_validate {
    ['ui.log'] = { opts.ui.log, { 'table', 'nil' } },
  }
  if opts.ui.bar ~= nil and opts.ui.bar ~= false and opts.ui.bar ~= 'statusline' and opts.ui.bar ~= 'winbar' then
    error(("[mya] invalid ui.bar %s (expected 'statusline', 'winbar', or false)"):format(vim.inspect(opts.ui.bar)), 2)
  end
  if opts.ui.log then
    checked_validate {
      ['ui.log.context_lines'] = { opts.ui.log.context_lines, { 'number', 'nil' } },
      ['ui.log.icons'] = { opts.ui.log.icons, { 'boolean', 'nil' } },
    }
  end
  checked_validate {
    keymaps = { opts.keymaps, 'table' },
  }
  for group, maps in pairs(opts.keymaps) do
    checked_validate {
      [('keymaps.%s'):format(group)] = { maps, 'table' },
    }
    for action, lhs in pairs(maps) do
      if type(lhs) ~= 'string' and lhs ~= false then
        error(
          ('[mya] invalid keymaps.%s.%s %s (expected a string lhs, or false to disable)'):format(
            group,
            action,
            vim.inspect(lhs)
          ),
          2
        )
      end
      if type(lhs) == 'string' and lhs == '' then
        error(('[mya] keymaps.%s.%s must not be an empty string (use false to disable)'):format(group, action), 2)
      end
    end
  end
  for name, agent_cfg in pairs(opts.agents) do
    if type(name) ~= 'string' or name == '' then
      error('[mya] agents table keys must be non-empty strings', 2)
    end
    validate_agent(name, agent_cfg)
  end
  checked_validate {
    ['log.level'] = { opts.log.level, { 'string', 'nil' } },
    ['log.file'] = { opts.log.file, { 'string', 'nil' } },
  }
  if opts.log.level and not VALID_LEVELS[opts.log.level] then
    error(
      ("[mya] invalid log.level %q (expected one of: trace, debug, info, warn, error)"):format(opts.log.level),
      2
    )
  end
end

--- Merge user options over defaults, validate, and install as the active
--- configuration. Also (re)configures the logger.
---@param user_opts mya.Config?
---@return mya.Config
function M.setup(user_opts)
  user_opts = user_opts or {}
  if type(user_opts) ~= 'table' then
    error('[mya] setup() expects a table, got ' .. type(user_opts), 2)
  end

  ---@type mya.Config
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_opts)
  validate(merged)

  active = merged

  local util = require 'mya.util'
  util.set_config { level = merged.log.level, file = merged.log.file }

  return active
end

--- Return the active configuration.
---
--- Reading config for defaults (e.g. plugin/mya.lua checking whether setup()
--- ran) should not hard-crash: pass `soft = true` to get the *defaults*
--- back (not installed as active) instead of erroring when setup() has not
--- run yet.
---@param opts { soft: boolean? }?
---@return mya.Config
function M.get(opts)
  if active then
    return active
  end
  if opts and opts.soft then
    return vim.deepcopy(defaults)
  end
  error('[mya] setup() has not been called; call require("mya").setup({...}) first', 2)
end

--- Whether setup() has been called yet.
---@return boolean
function M.is_configured()
  return active ~= nil
end

--- Look up one agent's config by name.
---@param name string
---@return mya.AgentConfig
function M.get_agent(name)
  local cfg = M.get()
  local agent_cfg = cfg.agents[name]
  if not agent_cfg then
    error(('[mya] no agent named %q configured'):format(name), 2)
  end
  return agent_cfg
end

--- Test-only: reset to unconfigured state.
function M._reset()
  active = nil
end

return M
