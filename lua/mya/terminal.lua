--- Client-served terminal/* methods (Phase 8): `terminal/create`,
--- `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`,
--- `terminal/release`. Protocol layer — NO ui imports.
---
--- ## Spawn choice
---
--- `vim.uv.spawn` (not `vim.fn.jobstart`): `rpc.lua` already spawns agent
--- processes this way (uv pipes + `read_start`, every callback funneled
--- through `vim.schedule`); reusing the same idiom here avoids introducing a
--- second process-spawning convention (`jobstart` has a different callback
--- shape and its own scheduling story) into a codebase that otherwise has
--- exactly one.
---
--- ## Registry
---
--- `registry[agent_name][session_id][terminal_id] = Terminal`, held in this
--- module only (agent_name/session_id are plain strings — no `mya.Session`
--- object is required at this layer; the one place we need the session's
--- cwd, `resolve_cwd` lazily `require`s `mya.session` the same way
--- `client.lua` lazily requires it, to avoid a module cycle).
---
--- ## Output ring buffer
---
--- stdout+stderr are appended into one string per terminal, capped at
--- `outputByteLimit` bytes: once exceeded, bytes are dropped from the FRONT
--- and `truncated` is set (sticky — never clears). The schema asks that
--- truncation land on a character boundary; we deliberately don't do
--- UTF-8-aware boundary scanning for a client-side scrollback buffer — a
--- multi-byte character split at the truncation point is a display glitch
--- (this is not what the agent sees or diffs against), not a whole-buffer
--- accuracy risk.
---
--- ## Lifecycle
---
--- `session/cancel` / a cancelled turn deliberately do NOT touch terminals
--- (the protocol keeps them alive across a cancelled turn — no code here
--- hooks `Session:on_cancel`, so this is true by omission). An agent CRASH
--- kills every terminal it owns (`kill_all_for_agent`, wired once per agent
--- via `Agent:on_crash_hook` — the process would otherwise leak with no way
--- to ever reach it again).

local util = require 'mya.util'

local M = {}

---@class mya.TerminalExitStatus
---@field exitCode integer?
---@field signal string?

---@class mya.Terminal
---@field id string
---@field agent_name string
---@field session_id string
---@field handle uv_process_t?
---@field pid integer?
---@field stdout uv_pipe_t?
---@field stderr uv_pipe_t?
---@field output string accumulated ring-buffer content (stdout+stderr interleaved in arrival order)
---@field truncated boolean
---@field byte_limit integer?
---@field exited boolean
---@field exit_status mya.TerminalExitStatus?
---@field released boolean
---@field _on_output table<function, boolean> subscribers notified (already on the main loop) on output growth / exit
---@field _wait_waiters (fun(result: table))[] held `terminal/wait_for_exit` responders

-- agent_name -> session_id -> terminal_id -> mya.Terminal
---@type table<string, table<string, table<string, mya.Terminal>>>
local registry = {}

-- Agents for which the crash-cleanup hook has been installed (once each).
---@type table<string, boolean>
local crash_hooked = {}

local SIGNAL_NAMES = {
  [1] = 'SIGHUP',
  [2] = 'SIGINT',
  [3] = 'SIGQUIT',
  [4] = 'SIGILL',
  [6] = 'SIGABRT',
  [8] = 'SIGFPE',
  [9] = 'SIGKILL',
  [11] = 'SIGSEGV',
  [13] = 'SIGPIPE',
  [15] = 'SIGTERM',
}

---@param signal integer?
---@return string?
local function signal_name(signal)
  if not signal or signal == 0 then
    return nil
  end
  return SIGNAL_NAMES[signal] or ('SIG%d'):format(signal)
end

---@param code integer
---@param signal integer
---@return mya.TerminalExitStatus
local function exit_status_from(code, signal)
  local sig = signal_name(signal)
  return { exitCode = sig and nil or code, signal = sig }
end

-- ---------------------------------------------------------------------
-- Registry helpers
-- ---------------------------------------------------------------------

local next_id = 0

---@return string
local function gen_id()
  next_id = next_id + 1
  return ('term-%d'):format(next_id)
end

---@param agent_name string
---@param session_id string
---@param byte_limit integer?
---@return mya.Terminal
local function new_terminal(agent_name, session_id, byte_limit)
  return {
    id = gen_id(),
    agent_name = agent_name,
    session_id = session_id,
    output = '',
    truncated = false,
    byte_limit = byte_limit,
    exited = false,
    exit_status = nil,
    released = false,
    _on_output = {},
    _wait_waiters = {},
  }
end

---@param term mya.Terminal
local function register_terminal(term)
  registry[term.agent_name] = registry[term.agent_name] or {}
  registry[term.agent_name][term.session_id] = registry[term.agent_name][term.session_id] or {}
  registry[term.agent_name][term.session_id][term.id] = term
end

---@param agent_name string
---@param session_id string
---@param terminal_id string
---@return mya.Terminal?
local function find_terminal(agent_name, session_id, terminal_id)
  local by_sess = registry[agent_name]
  local by_term = by_sess and by_sess[session_id]
  return by_term and by_term[terminal_id]
end

---@param term mya.Terminal
local function remove_terminal(term)
  local by_sess = registry[term.agent_name]
  local by_term = by_sess and by_sess[term.session_id]
  if by_term then
    by_term[term.id] = nil
  end
end

---@param term mya.Terminal
local function fire_on_output(term)
  for fn in pairs(term._on_output) do
    local ok, err = pcall(fn)
    if not ok then
      util.error(term.agent_name, 'terminal on_output subscriber error: ' .. tostring(err))
    end
  end
end

-- ---------------------------------------------------------------------
-- Process control
-- ---------------------------------------------------------------------

---@param term mya.Terminal
---@param chunk string
local function append_output(term, chunk)
  term.output = term.output .. chunk
  local limit = term.byte_limit
  if limit and #term.output > limit then
    term.output = term.output:sub(#term.output - limit + 1)
    term.truncated = true
  end
  fire_on_output(term)
end

---@param term mya.Terminal
---@param code integer
---@param signal integer
local function finish_terminal(term, code, signal)
  if term.exited then
    return -- already finalized (e.g. kill_terminal raced the natural exit)
  end
  term.exited = true
  term.exit_status = exit_status_from(code, signal)
  for _, h in ipairs { term.stdout, term.stderr } do
    if h and not h:is_closing() then
      pcall(function()
        h:close()
      end)
    end
  end
  local waiters = term._wait_waiters
  term._wait_waiters = {}
  for _, respond in ipairs(waiters) do
    pcall(respond, { exitCode = term.exit_status.exitCode, signal = term.exit_status.signal })
  end
  fire_on_output(term)
end

---@param term mya.Terminal
local function kill_terminal(term)
  if term.exited then
    return
  end
  if term.handle and not term.handle:is_closing() then
    pcall(function()
      term.handle:kill 'sigkill'
    end)
  end
end

---@param env_list table[]? [EnvVariable]
---@return string[]? nil means "inherit parent env unchanged"
local function build_env(env_list)
  if type(env_list) ~= 'table' or #env_list == 0 then
    return nil
  end
  local merged = vim.fn.environ()
  for _, kv in ipairs(env_list) do
    if type(kv) == 'table' and kv.name ~= nil then
      merged[kv.name] = kv.value
    end
  end
  local list = {}
  for k, v in pairs(merged) do
    list[#list + 1] = k .. '=' .. tostring(v)
  end
  return list
end

---@param agent_name string
---@param session_id string
---@param cwd string?
---@return string?
local function resolve_cwd(agent_name, session_id, cwd)
  if type(cwd) == 'string' and cwd ~= '' then
    return cwd
  end
  local ok, session = pcall(require, 'mya.session')
  local sess = ok and session.get(agent_name, session_id)
  return sess and sess.cwd or nil
end

--- Kill every live terminal belonging to `agent_name` (process crash — the
--- protocol gives us no other way to ever reach these child processes
--- again). Entries stay in the registry (matches `terminal/kill` semantics:
--- output remains readable) until explicitly released.
---@param agent_name string
function M.kill_all_for_agent(agent_name)
  local sessions = registry[agent_name]
  if not sessions then
    return
  end
  for _, terms in pairs(sessions) do
    for _, term in pairs(terms) do
      kill_terminal(term)
    end
  end
end

---@param agent mya.Agent
local function ensure_crash_hook(agent)
  if crash_hooked[agent.name] then
    return
  end
  crash_hooked[agent.name] = true
  agent:on_crash_hook(function(ag)
    M.kill_all_for_agent(ag.name)
  end)
end

-- ---------------------------------------------------------------------
-- Request handlers
-- ---------------------------------------------------------------------

---@param agent mya.Agent
---@param params { sessionId: string, command: string, args: string[]?, env: table[]?, cwd: string?, outputByteLimit: integer? }?
---@param respond fun(result: table?, err: table?)
function M.handle_create(agent, params, respond)
  params = params or {}
  local sid, command = params.sessionId, params.command
  if type(sid) ~= 'string' or type(command) ~= 'string' then
    respond(nil, { code = -32602, message = '[mya] terminal/create: missing sessionId/command' })
    return
  end
  ensure_crash_hook(agent)

  local term = new_terminal(agent.name, sid, params.outputByteLimit)
  local cwd = resolve_cwd(agent.name, sid, params.cwd)
  local env = build_env(params.env)

  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)

  local handle, pid_or_err = vim.uv.spawn(command, {
    args = params.args or {},
    stdio = { nil, stdout, stderr }, -- stdin: nil = closed (no interactive input)
    env = env,
    cwd = cwd,
  }, function(code, signal)
    vim.schedule(function()
      finish_terminal(term, code, signal)
    end)
  end)

  if not handle then
    pcall(function()
      stdout:close()
      stderr:close()
    end)
    respond(nil, {
      code = -32603,
      message = ('[mya] terminal/create: failed to spawn %q: %s'):format(command, tostring(pid_or_err)),
    })
    return
  end

  term.handle = handle
  term.pid = pid_or_err
  term.stdout = stdout
  term.stderr = stderr
  register_terminal(term)

  local function on_data(_err, chunk)
    if not chunk then
      return -- EOF; process exit (finish_terminal) closes the pipe
    end
    vim.schedule(function()
      append_output(term, chunk)
    end)
  end
  stdout:read_start(on_data)
  stderr:read_start(on_data)

  util.info(agent.name, ('terminal/create %s: pid=%s cwd=%s: %s %s'):format(term.id, tostring(term.pid), tostring(cwd), command, table.concat(params.args or {}, ' ')))
  respond { terminalId = term.id }
end

---@param agent mya.Agent
---@param params { sessionId: string, terminalId: string }?
---@param respond fun(result: table?, err: table?)
function M.handle_output(agent, params, respond)
  params = params or {}
  local term = find_terminal(agent.name, params.sessionId, params.terminalId)
  if not term then
    respond(nil, { code = -32602, message = '[mya] terminal/output: unknown terminalId ' .. tostring(params.terminalId) })
    return
  end
  local result = { output = term.output, truncated = term.truncated }
  if term.exit_status then
    result.exitStatus = { exitCode = term.exit_status.exitCode, signal = term.exit_status.signal }
  end
  respond(result)
end

---@param agent mya.Agent
---@param params { sessionId: string, terminalId: string }?
---@param respond fun(result: table?, err: table?)
function M.handle_wait_for_exit(agent, params, respond)
  params = params or {}
  local term = find_terminal(agent.name, params.sessionId, params.terminalId)
  if not term then
    respond(nil, { code = -32602, message = '[mya] terminal/wait_for_exit: unknown terminalId ' .. tostring(params.terminalId) })
    return
  end
  if term.exited then
    respond { exitCode = term.exit_status.exitCode, signal = term.exit_status.signal }
    return
  end
  table.insert(term._wait_waiters, respond)
end

---@param agent mya.Agent
---@param params { sessionId: string, terminalId: string }?
---@param respond fun(result: table?, err: table?)
function M.handle_kill(agent, params, respond)
  params = params or {}
  local term = find_terminal(agent.name, params.sessionId, params.terminalId)
  if not term then
    respond(nil, { code = -32602, message = '[mya] terminal/kill: unknown terminalId ' .. tostring(params.terminalId) })
    return
  end
  kill_terminal(term)
  respond(vim.empty_dict())
end

---@param agent mya.Agent
---@param params { sessionId: string, terminalId: string }?
---@param respond fun(result: table?, err: table?)
function M.handle_release(agent, params, respond)
  params = params or {}
  local term = find_terminal(agent.name, params.sessionId, params.terminalId)
  if not term then
    respond(nil, { code = -32602, message = '[mya] terminal/release: unknown terminalId ' .. tostring(params.terminalId) })
    return
  end
  kill_terminal(term)
  term.released = true
  remove_terminal(term)
  respond(vim.empty_dict())
end

-- ---------------------------------------------------------------------
-- UI-facing read API (ui/log.lua's `<CR>`-on-terminal-content viewer)
-- ---------------------------------------------------------------------

--- Snapshot of a terminal's current state for display, or nil if unknown
--- (never created this Neovim instance, or already released).
---@param agent_name string
---@param session_id string
---@param terminal_id string
---@return { output: string, truncated: boolean, exited: boolean, exit_status: mya.TerminalExitStatus? }?
function M.get(agent_name, session_id, terminal_id)
  local term = find_terminal(agent_name, session_id, terminal_id)
  if not term then
    return nil
  end
  return { output = term.output, truncated = term.truncated, exited = term.exited, exit_status = term.exit_status }
end

--- Subscribe to output/exit-status changes for one terminal: `fn()` (no
--- payload — callers re-`M.get()`) is invoked on the main loop on every
--- output chunk and once more on exit. Returns a no-op unsubscribe if the
--- terminal is unknown.
---@param agent_name string
---@param session_id string
---@param terminal_id string
---@param fn fun()
---@return fun() unsubscribe
function M.on_output(agent_name, session_id, terminal_id, fn)
  local term = find_terminal(agent_name, session_id, terminal_id)
  if not term then
    return function() end
  end
  term._on_output[fn] = true
  return function()
    term._on_output[fn] = nil
  end
end

-- ---------------------------------------------------------------------
-- Test support
-- ---------------------------------------------------------------------

--- Test-only: snapshot of every live (unreleased) terminal for one session,
--- keyed by terminalId.
---@param agent_name string
---@param session_id string
---@return table<string, table>
function M._for_session(agent_name, session_id)
  local by_sess = registry[agent_name]
  local terms = by_sess and by_sess[session_id]
  local out = {}
  if terms then
    for id, term in pairs(terms) do
      out[id] = { output = term.output, truncated = term.truncated, exited = term.exited, exit_status = term.exit_status }
    end
  end
  return out
end

--- Test-only: forget all registry/crash-hook state (does not kill live
--- processes — call `kill_all_for_agent` first if that matters).
function M._reset()
  registry = {}
  crash_hooked = {}
end

return M
