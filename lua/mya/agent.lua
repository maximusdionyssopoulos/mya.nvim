--- Agent process lifecycle: lazy spawn, `initialize` handshake, auth,
--- keep-alive/idle policy, crash detection, graceful shutdown.

local config = require 'mya.config'
local rpc = require 'mya.rpc'
local util = require 'mya.util'

local M = {}

---@alias mya.Agent.State "idle"|"initializing"|"ready"|"crashed"|"stopped"

---@class mya.Agent
---@field name string
---@field state mya.Agent.State
---@field generation integer
---@field conn mya.rpc.Connection?
---@field capabilities table agentCapabilities from the initialize response
---@field info table? agentInfo from the initialize response
---@field auth_methods table[] authMethods from the initialize response
---@field protocol_version integer?
---@field session_update_hook fun(params: table?) session.lua installs a per-agent routing hook here (replaces the Phase 1 no-op)
---@field on_crash (fun(agent: mya.Agent))? called (on the main loop) when the process exits *unexpectedly*; session.lua uses it to error all the agent's sessions
---@field _crash_hooks (fun(agent: mya.Agent))[]? additional crash observers (Phase 8: `terminal.lua` registers here via `on_crash_hook` to kill live terminals without clobbering session.lua's single `on_crash` field)
local Agent = {}
Agent.__index = Agent

---@type table<string, mya.Agent>
local agents_by_name = {}

local CLIENT_INFO = { name = 'mya.nvim', version = '0.1.0' }

--- Get (creating if necessary) the Agent object for a configured agent name.
--- Does not spawn a process — spawning is lazy, on first `ensure_ready`/
--- `request`/`notify`.
---@param name string
---@return mya.Agent
function M.get(name)
  config.get_agent(name) -- validates the name exists; errors otherwise
  local existing = agents_by_name[name]
  if existing then
    return existing
  end
  local agent = setmetatable({
    name = name,
    state = 'idle',
    generation = 0,
    capabilities = {},
    auth_methods = {},
    session_update_hook = function(_params)
      util.debug(name, 'session/update received (phase1 no-op hook)')
    end,
    _ready_waiters = {},
    _outstanding = 0,
  }, Agent)
  agents_by_name[name] = agent
  return agent
end

--- Whether the agent advertises a capability. Handles both conventions in
--- the schema:
---  - top-level `loadSession` boolean (pass capname == "loadSession")
---  - `sessionCapabilities.*` absent/null (unsupported) vs `{}` (supported)
---    (pass capname == "list" | "delete" | "resume" | "close" |
---    "additionalDirectories")
---@param capname string
---@return boolean
function Agent:supports(capname)
  if capname == 'loadSession' then
    return self.capabilities.loadSession == true
  end
  local session_caps = self.capabilities.sessionCapabilities
  if type(session_caps) ~= 'table' then
    return false
  end
  return type(session_caps[capname]) == 'table'
end

---@param handler_id string
local function build_handlers(self)
  return {
    -- Client-served requests (Phase 6 fs/permission, Phase 8 terminal/*).
    -- The require is lazy (inside the closures) to avoid module cycles.
    requests = {
      ['fs/read_text_file'] = function(params, respond)
        require('mya.client').handle_read_text_file(self, params, respond)
      end,
      ['fs/write_text_file'] = function(params, respond)
        require('mya.client').handle_write_text_file(self, params, respond)
      end,
      ['session/request_permission'] = function(params, respond)
        require('mya.client').handle_request_permission(self, params, respond)
      end,
      ['terminal/create'] = function(params, respond)
        require('mya.terminal').handle_create(self, params, respond)
      end,
      ['terminal/output'] = function(params, respond)
        require('mya.terminal').handle_output(self, params, respond)
      end,
      ['terminal/wait_for_exit'] = function(params, respond)
        require('mya.terminal').handle_wait_for_exit(self, params, respond)
      end,
      ['terminal/kill'] = function(params, respond)
        require('mya.terminal').handle_kill(self, params, respond)
      end,
      ['terminal/release'] = function(params, respond)
        require('mya.terminal').handle_release(self, params, respond)
      end,
    },
    notifications = {
      ['session/update'] = function(params)
        local ok, err = pcall(self.session_update_hook, params)
        if not ok then
          util.error(self.name, 'session_update_hook error: ' .. tostring(err))
        end
      end,
    },
    on_cancel_request = function(request_id)
      util.debug(self.name, ('peer sent $/cancel_request for id=%s'):format(vim.inspect(request_id)))
    end,
  }
end

function Agent:_cancel_idle_timer()
  if self._idle_timer then
    pcall(function()
      self._idle_timer:stop()
      self._idle_timer:close()
    end)
    self._idle_timer = nil
  end
end

function Agent:_maybe_start_idle_timer()
  local cfg = config.get_agent(self.name)
  if cfg.keep_alive == false and cfg.idle_timeout_ms and self.conn and self.conn:is_alive() then
    self:_cancel_idle_timer()
    local timer = vim.uv.new_timer()
    self._idle_timer = timer
    timer:start(cfg.idle_timeout_ms, 0, function()
      vim.schedule(function()
        if self._idle_timer ~= timer then
          return -- superseded by a newer request/timer already
        end
        self._idle_timer = nil
        util.info(self.name, 'idle timeout reached; stopping agent')
        self:shutdown()
      end)
    end)
  end
end

function Agent:_touch_idle()
  self._outstanding = self._outstanding + 1
  self:_cancel_idle_timer()
end

function Agent:_release_idle()
  self._outstanding = math.max(0, self._outstanding - 1)
  if self._outstanding == 0 then
    self:_maybe_start_idle_timer()
  end
end

---@param err table?
function Agent:_finish_ready(err)
  self._initializing = false
  local waiters = self._ready_waiters
  self._ready_waiters = {}
  for _, cb in ipairs(waiters) do
    local ok, cb_err = pcall(cb, err, err and nil or self)
    if not ok then
      util.error(self.name, 'ensure_ready callback error: ' .. tostring(cb_err))
    end
  end
end

function Agent:_spawn_and_initialize()
  local cfg = config.get_agent(self.name)
  self.generation = self.generation + 1
  local my_generation = self.generation
  self.state = 'initializing'
  self._shutting_down = false

  local ok, conn_or_err = pcall(rpc.spawn, {
    command = cfg.command,
    args = cfg.args,
    env = cfg.env,
    cwd = cfg.cwd,
    log_id = self.name,
    handlers = build_handlers(self),
    on_exit = function(code, signal)
      self:_on_process_exit(my_generation, code, signal)
    end,
  })

  if not ok then
    self.state = 'crashed'
    self.conn = nil
    self:_finish_ready { code = rpc.TRANSPORT_ERROR_CODE, message = tostring(conn_or_err), data = { mya_transport = true } }
    return
  end

  self.conn = conn_or_err
  self.conn:request('initialize', {
    protocolVersion = 1,
    clientCapabilities = { fs = { readTextFile = true, writeTextFile = true }, terminal = true },
    clientInfo = CLIENT_INFO,
  }, function(err, result)
    if my_generation ~= self.generation then
      return -- stale: superseded by a respawn already
    end
    if err then
      util.error(self.name, 'initialize failed: ' .. vim.inspect(err))
      self:_finish_ready(err)
      return
    end
    result = result or {}
    self.capabilities = result.agentCapabilities or {}
    self.info = result.agentInfo
    self.auth_methods = result.authMethods or {}
    self.protocol_version = result.protocolVersion
    self.state = 'ready'
    util.info(self.name, 'initialize complete: ' .. vim.inspect { capabilities = self.capabilities, info = self.info })
    self:_finish_ready(nil)
  end)
end

---@param my_generation integer
---@param code integer
---@param signal integer
function Agent:_on_process_exit(my_generation, code, signal)
  if my_generation ~= self.generation then
    return -- already superseded (e.g. we already respawned)
  end
  self.conn = nil
  self:_cancel_idle_timer()
  self._outstanding = 0

  if self._shutting_down then
    self.state = 'stopped'
    util.info(self.name, ('agent stopped: code=%s signal=%s'):format(tostring(code), tostring(signal)))
  else
    self.state = 'crashed'
    util.error(self.name, ('agent crashed: code=%s signal=%s'):format(tostring(code), tostring(signal)))
    pcall(vim.notify, ('[mya] agent %q exited unexpectedly (code=%s)'):format(self.name, tostring(code)), vim.log.levels.ERROR)
    -- Let the session layer (if wired) mark this agent's sessions errored.
    -- Runs after the pending-request rejections in rpc's exit handler, so a
    -- session with an in-flight prompt has already seen its transport error
    -- by the time on_crash fires (it is idempotent about status).
    if self.on_crash then
      local ok, hook_err = pcall(self.on_crash, self)
      if not ok then
        util.error(self.name, 'on_crash hook error: ' .. tostring(hook_err))
      end
    end
    for _, fn in ipairs(self._crash_hooks or {}) do
      local ok, hook_err = pcall(fn, self)
      if not ok then
        util.error(self.name, 'crash hook error: ' .. tostring(hook_err))
      end
    end
  end

  -- No-op if a handshake already finished/failed via its own request
  -- callback; harmless if there are no queued waiters.
  self:_finish_ready { code = rpc.TRANSPORT_ERROR_CODE, message = 'agent process exited', data = { mya_transport = true, exit_code = code, exit_signal = signal } }
end

--- Ensure the agent is spawned and has completed the `initialize` handshake.
--- Concurrent callers during an in-flight handshake are queued and all
--- notified once it settles (spawns/initializes at most once concurrently).
---@param cb fun(err: table?, agent: mya.Agent?)
function Agent:ensure_ready(cb)
  if self.state == 'ready' and self.conn and self.conn:is_alive() then
    vim.schedule(function()
      cb(nil, self)
    end)
    return
  end

  table.insert(self._ready_waiters, cb)
  if self._initializing then
    return -- handshake already in flight; will be notified when it settles
  end
  self._initializing = true
  self:_spawn_and_initialize()
end

--- Drive the `authenticate` flow: exactly one method -> use it directly;
--- multiple -> vim.ui.select. Concurrent callers share one in-flight
--- authenticate call.
---@param cb fun(err: table?)
function Agent:_authenticate(cb)
  if self._auth_inflight then
    table.insert(self._auth_waiters, cb)
    return
  end
  self._auth_inflight = true
  self._auth_waiters = { cb }

  local function finish(err)
    self._auth_inflight = false
    local waiters = self._auth_waiters
    self._auth_waiters = {}
    for _, w in ipairs(waiters) do
      w(err)
    end
  end

  local function do_authenticate(method_id)
    self.conn:request('authenticate', { methodId = method_id }, function(err, _result)
      finish(err)
    end)
  end

  local methods = self.auth_methods or {}
  if #methods == 0 then
    finish { code = -32000, message = '[mya] agent requires auth but advertised no auth methods' }
  elseif #methods == 1 then
    do_authenticate(methods[1].id)
  else
    vim.schedule(function()
      vim.ui.select(methods, {
        prompt = ('[mya] %s requires authentication:'):format(self.name),
        format_item = function(m)
          return m.name or m.id
        end,
      }, function(choice)
        if not choice then
          finish { code = -32000, message = '[mya] authentication cancelled' }
          return
        end
        do_authenticate(choice.id)
      end)
    end)
  end
end

---@param method string
---@param params table?
---@param cb fun(err: table?, result: table?)
---@param _retried boolean? internal: prevents infinite auth-retry loops
function Agent:_do_request(method, params, cb, _retried)
  -- The process can exit between ensure_ready resolving (scheduled) and this
  -- running; _on_process_exit clears self.conn, so re-check here.
  if not self.conn then
    cb({
      code = rpc.TRANSPORT_ERROR_CODE,
      message = '[mya] agent process exited',
      data = { mya_transport = true },
    }, nil)
    return
  end
  self:_touch_idle()
  self.conn:request(method, params, function(err, result)
    self:_release_idle()
    if err and err.code == -32000 and not _retried and self.auth_methods and #self.auth_methods > 0 then
      self:_authenticate(function(auth_err)
        if auth_err then
          cb(err, nil) -- surface the original auth-required error
          return
        end
        self:_do_request(method, params, cb, true)
      end)
      return
    end
    cb(err, result)
  end)
end

--- Send a request, ensuring the agent is spawned/initialized first, and
--- transparently driving `authenticate` on a `-32000` response.
---@param method string
---@param params table?
---@param cb fun(err: table?, result: table?)
function Agent:request(method, params, cb)
  self:ensure_ready(function(err, _agent)
    if err then
      cb(err, nil)
      return
    end
    self:_do_request(method, params, cb)
  end)
end

--- Send a notification, ensuring the agent is spawned/initialized first.
---@param method string
---@param params table?
---@param cb (fun(err: table?))?
function Agent:notify(method, params, cb)
  self:ensure_ready(function(err, _agent)
    if err then
      if cb then
        cb(err)
      end
      return
    end
    self.conn:notify(method, params)
    if cb then
      cb(nil)
    end
  end)
end

--- Register an additional on-crash observer (Phase 8): unlike the single
--- `on_crash` field (owned by session.lua), any number of modules can add a
--- hook here without clobbering each other. Called on the main loop, same
--- timing as `on_crash`.
---@param fn fun(agent: mya.Agent)
function Agent:on_crash_hook(fn)
  self._crash_hooks = self._crash_hooks or {}
  table.insert(self._crash_hooks, fn)
end

--- Graceful shutdown. Marks the exit as intentional (state becomes
--- "stopped", not "crashed") and cancels any idle timer.
function Agent:shutdown()
  self._shutting_down = true
  self:_cancel_idle_timer()
  if self.conn then
    self.conn:close()
  else
    self.state = 'stopped'
  end
end

--- Stop every agent that has ever been spawned. Intended for VimLeavePre.
function M.stop_all()
  for _, agent in pairs(agents_by_name) do
    agent:shutdown()
  end
end

--- Test-only: forget all memoized agents (does not stop running processes —
--- call stop_all() first if that matters).
function M._reset()
  agents_by_name = {}
end

M.Agent = Agent

return M
