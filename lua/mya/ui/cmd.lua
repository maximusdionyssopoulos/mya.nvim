--- `:Mya` subcommand dispatch + completion. Kept separate from
--- `plugin/mya.lua` so the plugin file stays a thin `nvim_create_user_command`
--- wiring shim (module reload during development just works).
---
--- Subcommands: (none) -> dashboard, `new <agent>`, `open <agent>[/<id>]`,
--- `send [{text}]`, `cancel`, `include [path...]`, `qf`, `review`, `config`,
--- `model [value]`, `plan`, `log`.
---
--- ## Session targeting (fugitive-style ambient session)
---
--- Every session-scoped subcommand (`send`/`cancel`/`config`/`qf`/`review`/
--- `plan`/`include`) resolves its target through `ui/prompt.M.resolve()`: the
--- current buffer's session when it has one (mya:// view or compose buffer),
--- otherwise the most recently entered session buffer. So `:'<,'>Mya send
--- fix this` works from any file buffer, the way `:Ggrep` works from any
--- buffer of the repo.
---
--- ## Ranges compose
---
--- `:{range}Mya send [{text}]` stages the range as a resource block first
--- (shared with `:{range}Mya include`), then sends `{text}` — or opens the
--- compose buffer when there is no text. Bare `:Mya send` = compose buffer
--- (the `:Git commit` / `:Git commit -m` split).

local M = {}

local SUBCOMMANDS = { 'new', 'open', 'send', 'cancel', 'include', 'qf', 'review', 'config', 'model', 'plan', 'log' }

local NO_SESSION_MSG = '[mya] no current session (use :Mya, :Mya open, or :Mya new <agent>)'

---@return mya.Session
local function require_session()
  local sess = require('mya.ui.prompt').resolve()
  if not sess then
    error(NO_SESSION_MSG, 0)
  end
  return sess
end

--- `:Mya open <agent>[/<id>]`: open a session log in the current window.
--- With no `/<id>`, picks the agent's most recently updated known session
--- (in-memory or last-fetched session/list).
---@param arg string?
local function cmd_open(arg)
  if not arg or arg == '' then
    vim.notify('[mya] usage: :Mya open <agent>[/<session-id>]', vim.log.levels.ERROR)
    return
  end
  local agent, id = arg:match '^([^/]+)/(.+)$'
  if not agent then
    agent = arg
  end
  local ok, cfg = pcall(require('mya.config').get)
  if not ok or not cfg.agents[agent] then
    vim.notify(('[mya] no agent named %q configured'):format(agent), vim.log.levels.ERROR)
    return
  end
  if not id then
    -- Newest known session for the agent: in-memory first (they have live
    -- updated_at), then the cached session/list (already agent-ordered).
    local session = require 'mya.session'
    local best, best_t
    for _, s in ipairs(session.all()) do
      if s.agent_name == agent then
        local t = tonumber(s.updated_at) or 0
        if not best or t > best_t then
          best, best_t = s.id, t
        end
      end
    end
    if not best then
      local cached = session.list_cached(agent)
      best = cached[1] and cached[1].sessionId
    end
    if not best then
      vim.notify(('[mya] no known session for %q (open :Mya to fetch, or :Mya new %s)'):format(agent, agent), vim.log.levels.ERROR)
      return
    end
    id = best
  end
  require('mya.ui.buf').open(agent, id, 'log', { split = 'current' })
end

---@param opts table nvim_create_user_command callback opts
function M.run(opts)
  local args = opts.fargs or {}
  local sub = args[1]

  if not sub then
    require('mya.ui.dashboard').open()
    return
  end

  local rest = {}
  for i = 2, #args do
    rest[#rest + 1] = args[i]
  end

  if sub == 'new' then
    local agent = rest[1]
    if not agent then
      vim.notify('[mya] usage: :Mya new <agent>', vim.log.levels.ERROR)
      return
    end
    require('mya.session').new(agent, {}, function(err, sess)
      if err then
        vim.notify('[mya] session/new failed: ' .. tostring(err.message or vim.inspect(err)), vim.log.levels.ERROR)
        return
      end
      require('mya.ui.buf').open(agent, sess.id, 'log', { split = 'current' })
    end)
    return
  end

  if sub == 'open' then
    cmd_open(rest[1])
    return
  end

  if sub == 'log' then
    local path = require('mya.util').log_path()
    if vim.fn.filereadable(path) == 1 then
      vim.cmd('split ' .. vim.fn.fnameescape(path))
    else
      vim.notify('[mya] no log file yet: ' .. path, vim.log.levels.INFO)
    end
    return
  end

  -- Session-scoped subcommands: resolve the ambient current session.
  local ok, sess_or_err = pcall(require_session)
  if not ok then
    vim.notify(tostring(sess_or_err), vim.log.levels.ERROR)
    return
  end
  local sess = sess_or_err
  local prompt = require 'mya.ui.prompt'

  if sub == 'send' then
    if opts.range and opts.range > 0 then
      local okr, rerr = pcall(prompt.stage_range, sess, opts.line1, opts.line2)
      if not okr then
        vim.notify(tostring(rerr), vim.log.levels.ERROR)
        return
      end
    end
    local text = table.concat(rest, ' ')
    if text == '' then
      prompt.open_for_session(sess)
    else
      prompt.send_text(sess, text)
    end
  elseif sub == 'include' then
    local oki, ierr = pcall(prompt.cmd_include, opts, rest)
    if not oki then
      vim.notify(tostring(ierr), vim.log.levels.ERROR)
    end
  elseif sub == 'cancel' then
    sess:cancel()
  elseif sub == 'config' then
    prompt.config_picker(sess)
  elseif sub == 'model' then
    prompt.set_model(sess, rest[1])
  elseif sub == 'qf' then
    local n = require('mya.client').populate_session_qf(sess)
    vim.notify(('[mya] quickfix: %d entries'):format(n), vim.log.levels.INFO)
    if n > 0 then
      vim.cmd 'copen'
    end
  elseif sub == 'review' then
    require('mya.ui.review').open(sess)
  elseif sub == 'plan' then
    require('mya.ui.plan').open(sess)
  else
    vim.notify('[mya] unknown subcommand: ' .. tostring(sub), vim.log.levels.ERROR)
  end
end

--- Agent names from config, sorted (empty when setup() hasn't run).
---@return string[]
local function agent_names()
  local names = {}
  local ok, cfg = pcall(require('mya.config').get, { soft = true })
  if ok then
    for name in pairs(cfg.agents) do
      names[#names + 1] = name
    end
    table.sort(names)
  end
  return names
end

--- `:Mya open` candidates: `agent` and `agent/<session-id>` for every known
--- session (in-memory + cached session/list — see session.list_cached).
---@return string[]
local function open_candidates()
  local session = require 'mya.session'
  local out = {}
  for _, agent in ipairs(agent_names()) do
    out[#out + 1] = agent
    local seen = {}
    for _, s in ipairs(session.all()) do
      if s.agent_name == agent then
        seen[s.id] = true
        out[#out + 1] = agent .. '/' .. s.id
      end
    end
    for _, info in ipairs(session.list_cached(agent)) do
      if info.sessionId and not seen[info.sessionId] then
        out[#out + 1] = agent .. '/' .. info.sessionId
      end
    end
  end
  return out
end

--- `-complete=customlist` callback.
---@param arglead string
---@param cmdline string
---@param _cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, _cursorpos)
  -- cmdline is e.g. "Mya send /foo" or "Mya "; split on whitespace, keeping
  -- in mind the trailing arglead may itself be empty.
  local args = vim.split(vim.trim(cmdline), '%s+')
  -- args[1] == 'Mya'; args[2] (if any) is the subcommand (possibly partial).
  local n = #args
  local trailing_space = cmdline:sub(-1):match '%s' ~= nil

  local function filter(cands)
    local out = {}
    for _, c in ipairs(cands) do
      if vim.startswith(c, arglead) then
        out[#out + 1] = c
      end
    end
    return out
  end

  if n <= 1 or (n == 2 and not trailing_space) then
    return filter(SUBCOMMANDS)
  end

  local sub = args[2]
  if sub == 'new' then
    return filter(agent_names())
  end

  if sub == 'open' then
    return filter(open_candidates())
  end

  if sub == 'include' then
    return vim.fn.getcompletion(arglead, 'file')
  end

  if sub == 'model' then
    -- Model value ids for the current session (`:Mya model <Tab>`). With
    -- `set wildoptions+=fuzzy` these fuzzy-match; no picker plugin needed.
    local sess = require('mya.ui.prompt').resolve()
    return sess and filter(require('mya.ui.prompt').model_value_candidates(sess)) or {}
  end

  if sub == 'send' then
    -- Agent slash commands (advertised via available_commands_update) are
    -- ordinary prompt text; the cmdline is their completion surface.
    local sess = require('mya.ui.prompt').resolve()
    local out = {}
    if sess and type(sess.available_commands) == 'table' then
      for _, c in ipairs(sess.available_commands) do
        local word = '/' .. c.name
        if vim.startswith(word, arglead) then
          out[#out + 1] = word
        end
      end
    end
    return out
  end

  return {}
end

return M
