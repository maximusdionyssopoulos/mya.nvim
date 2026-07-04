--- The session layer (concepts-v3 layer 1: NO UI imports).
---
--- A `Session` owns an append-only event log; UI phases render it as a pure
--- projection. Live `session/update` notifications and `session/load` replay
--- feed the SAME `apply_update` path, so auto-updating buffers and opening
--- old sessions are one code path.
---
--- ## Event log
---
--- `session.events` is an append-only array of event tables. Kinds:
---   - `message`  { role='user'|'agent'|'thought', content=<markdown>, message_id?, complete, block?, meta={config_snapshot?, timestamp} }
---   - `tool_call`{ id, title, tool_kind, status, content, locations, raw_input?, raw_output? } — tool_call_update MERGES in place
---   - `plan`     { entries, revision } — single mutable plan event per session, updated in place
---   - `turn`     { phase='start'|'end', stop_reason?, config_snapshot? }
---   - `info`     { text } — errors/notices worth showing in the log
---
--- Streamed message chunks of the same role + messageId coalesce into one
--- `message` event (marked incomplete until the turn ends). A non-text
--- content block ends coalescing and becomes its own event with a rendered
--- placeholder (`[image]`, ...) and the raw block stashed in `.block`.
---
--- ## Subscription / delta format
---
--- `session:subscribe(fn)` -> unsubscribe. `fn(deltas, session)` is called
--- AFTER `vim.schedule`, batched per tick (all updates applied in one tick
--- produce ONE callback carrying the list of deltas). Delta shape:
---   - `{ type='append', index, event }` — a new event appended at `index`
---   - `{ type='mutate', index, event }` — an existing event mutated in place
---   - `{ type='reset' }`               — redraw from scratch (after load replay)
--- A log renderer does incremental `set_lines` for append/mutate and a full
--- redraw for reset. A callback may fire with an EMPTY delta list purely to
--- signal that session header state (status/usage/title/commands) changed —
--- read `session.status`/`session.usage`/etc live. `session:on_status_change`
--- gives the coarse status-only signal for statusline/dashboard.

local agent_mod = require 'mya.agent'
local config = require 'mya.config'
local util = require 'mya.util'

local M = {}

---@alias mya.SessionStatus "idle"|"prompting"|"waiting_permission"|"error"|"unloaded"

---@class mya.Session
---@field id string
---@field agent_name string
---@field cwd string
---@field title string?
---@field status mya.SessionStatus
---@field created_here boolean
---@field config_options table[]? latest [SessionConfigOption]
---@field current_mode_id string?
---@field available_commands table[]?
---@field usage { used: integer, size: integer, cost: table? }?
---@field updated_at string?
---@field events table[] append-only
---@field pending_tool_calls table<string, { event: table, index: integer }> tool calls by toolCallId (Phase 6 correlates permission requests here)
---@field stop_reason string? last turn's stopReason
---@field cancelling boolean cancel requested, awaiting the cancelled prompt response
local Session = {}
Session.__index = Session

-- Registry: agent_name -> session_id -> Session.
---@type table<string, table<string, mya.Session>>
local registry = {}

-- Agents whose per-agent update-routing + crash hooks are installed.
---@type table<string, boolean>
local routed_agents = {}

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

local function now_ts()
  return os.time()
end

---@param sess mya.Session
local function register(sess)
  registry[sess.agent_name] = registry[sess.agent_name] or {}
  registry[sess.agent_name][sess.id] = sess
end

--- Snapshot of the config options' current values, keyed by option id —
--- captured on each prompt for per-message model/effort display.
---@param sess mya.Session
---@return table<string,string>?
local function config_snapshot(sess)
  local co = sess.config_options
  if type(co) ~= 'table' then
    return nil
  end
  local snap = {}
  for _, opt in ipairs(co) do
    if opt.id ~= nil then
      snap[opt.id] = opt.currentValue
    end
  end
  return snap
end

--- Build the protocol `mcpServers` array from an agent's config. Env given
--- as a map is normalized to the protocol `[{name,value}]` shape.
---@param agent_name string
---@return table[]
local function mcp_servers_for(agent_name)
  local cfg = config.get_agent(agent_name)
  local servers = cfg.mcp_servers
  if type(servers) ~= 'table' or #servers == 0 then
    return {}
  end
  local out = {}
  for _, s in ipairs(servers) do
    local env = s.env
    if type(env) == 'table' and not vim.islist(env) then
      local list = {}
      for k, v in pairs(env) do
        list[#list + 1] = { name = k, value = tostring(v) }
      end
      env = list
    end
    out[#out + 1] = { name = s.name, command = s.command, args = s.args or {}, env = env or {} }
  end
  return out
end

-- ---------------------------------------------------------------------
-- Subscription plumbing + batched flush
-- ---------------------------------------------------------------------

--- Schedule a single per-tick flush. Deltas / dirty / status-change flags
--- accumulated between now and when the scheduled callback runs are all
--- delivered together.
function Session:_schedule_flush()
  if self._flush_scheduled then
    return
  end
  self._flush_scheduled = true
  vim.schedule(function()
    self._flush_scheduled = false
    local deltas = self._deltas
    self._deltas = {}
    local dirty = self._dirty
    self._dirty = false
    local status_changed = self._status_changed
    self._status_changed = false

    if #deltas > 0 or dirty then
      for _, fn in ipairs(self:_snapshot(self._subs)) do
        local ok, err = pcall(fn, deltas, self)
        if not ok then
          util.error(self.agent_name, 'session subscriber error: ' .. tostring(err))
        end
      end
    end
    if status_changed then
      for _, fn in ipairs(self:_snapshot(self._status_subs)) do
        local ok, err = pcall(fn, self.status, self)
        if not ok then
          util.error(self.agent_name, 'status subscriber error: ' .. tostring(err))
        end
      end
    end
  end)
end

--- Stable-order snapshot of a subscriber set (functions used as keys), so a
--- subscriber can safely (un)subscribe from within its own callback.
---@param set table<function, boolean>
---@return function[]
function Session:_snapshot(set)
  local list = {}
  for fn in pairs(set) do
    list[#list + 1] = fn
  end
  return list
end

--- Subscribe to event-log deltas. `fn(deltas, session)`; see module header.
---@param fn fun(deltas: table[], session: mya.Session)
---@return fun() unsubscribe
function Session:subscribe(fn)
  vim.validate { fn = { fn, 'function' } }
  self._subs[fn] = true
  return function()
    self._subs[fn] = nil
  end
end

--- Subscribe to status-only changes. `fn(status, session)`.
---@param fn fun(status: mya.SessionStatus, session: mya.Session)
---@return fun() unsubscribe
function Session:on_status_change(fn)
  vim.validate { fn = { fn, 'function' } }
  self._status_subs[fn] = true
  return function()
    self._status_subs[fn] = nil
  end
end

---@param delta table
function Session:_emit(delta)
  self._deltas[#self._deltas + 1] = delta
  self:_schedule_flush()
end

--- Mark session header state (usage/title/commands/config) changed so
--- subscribers refresh even without an event delta.
function Session:_mark_dirty()
  self._dirty = true
  self:_schedule_flush()
end

-- Phase 6 addition: generic cancel hooks. client.lua registers one to
-- auto-answer held permission/write responders when a turn is cancelled.
-- Fired synchronously on `Session:cancel()` AND when a prompt resolves with
-- stopReason 'cancelled' (hooks must be idempotent).
---@param fn fun(session: mya.Session)
---@return fun() unregister
function Session:on_cancel(fn)
  vim.validate { fn = { fn, 'function' } }
  self._cancel_hooks[fn] = true
  return function()
    self._cancel_hooks[fn] = nil
  end
end

--- Phase 6 addition: fire registered cancel hooks (see `Session:on_cancel`).
function Session:_fire_cancel_hooks()
  for _, fn in ipairs(self:_snapshot(self._cancel_hooks)) do
    local ok, err = pcall(fn, self)
    if not ok then
      util.error(self.agent_name, 'cancel hook error: ' .. tostring(err))
    end
  end
end

---@param status mya.SessionStatus
function Session:_set_status(status)
  if self.status ~= status then
    self.status = status
    self._status_changed = true
  end
  self._dirty = true
  self:_schedule_flush()
end

--- Append an event and emit an `append` delta. Returns its index.
---@param ev table
---@return integer
function Session:_append_event(ev)
  local idx = #self.events + 1
  self.events[idx] = ev
  self:_emit { type = 'append', index = idx, event = ev }
  return idx
end

-- ---------------------------------------------------------------------
-- apply_update: the ONE path every mutation flows through
-- ---------------------------------------------------------------------

---@param content table? a ContentBlock
---@return boolean is_text
local function is_text_block(content)
  return type(content) == 'table' and content.type == 'text'
end

--- Finalize the currently-open coalesced message (mark it complete) and stop
--- coalescing. Called whenever coalescing ends: a different chunk starts, a
--- non-chunk update interrupts, or the turn ends.
---@param sess mya.Session
local function close_coalesce(sess)
  local co = sess._coalesce
  if co then
    local ev = sess.events[co.index]
    if ev and not ev.complete then
      ev.complete = true
      sess:_emit { type = 'mutate', index = co.index, event = ev }
    end
    sess._coalesce = nil
  end
end

--- Live turns get their `## user` header from the turn event `prompt()`
--- appends; replayed user chunks (session/load) have no prompt() call, so a
--- turn-start is synthesized when a new user message begins. Skipped inside a
--- live turn, and when the chunk continues the user message just appended.
---@param sess mya.Session
---@param role "user"|"agent"|"thought"
---@param message_id string?
local function ensure_replay_turn_header(sess, role, message_id)
  if role ~= 'user' or sess.status == 'prompting' then
    return
  end
  local last = sess.events[#sess.events]
  if last and last.kind == 'message' and last.role == 'user' and last.message_id == message_id then
    return
  end
  sess:_append_event { kind = 'turn', phase = 'start' }
end

--- Handle a streamed message chunk (user/agent/thought), coalescing
--- consecutive same-role, same-messageId text chunks into one event.
---@param sess mya.Session
---@param role "user"|"agent"|"thought"
---@param content table? ContentBlock
---@param message_id string?
local function handle_chunk(sess, role, content, message_id)
  if is_text_block(content) then
    local co = sess._coalesce
    if co and co.role == role and co.message_id == message_id then
      local ev = sess.events[co.index]
      ev.content = ev.content .. (content.text or '')
      ev.complete = false
      sess:_emit { type = 'mutate', index = co.index, event = ev }
    else
      close_coalesce(sess)
      ensure_replay_turn_header(sess, role, message_id)
      local ev = {
        kind = 'message',
        role = role,
        content = content.text or '',
        message_id = message_id,
        complete = false,
        meta = { timestamp = now_ts() },
      }
      local idx = sess:_append_event(ev)
      sess._coalesce = { role = role, message_id = message_id, index = idx }
    end
  else
    -- Non-text block ends coalescing and becomes its own event with a
    -- rendered placeholder; the raw block is stashed for the renderer.
    close_coalesce(sess)
    ensure_replay_turn_header(sess, role, message_id)
    local kind = (type(content) == 'table' and content.type) or 'content'
    sess:_append_event {
      kind = 'message',
      role = role,
      content = ('[%s]'):format(kind),
      message_id = message_id,
      complete = true,
      block = content,
      meta = { timestamp = now_ts() },
    }
  end
end

--- Create a tool_call event from a ToolCall(Update) payload.
---@param update table
---@return table
local function new_tool_call(update)
  return {
    kind = 'tool_call',
    id = update.toolCallId,
    title = update.title,
    tool_kind = update.kind,
    status = update.status or 'pending',
    content = update.content,
    locations = update.locations,
    raw_input = update.rawInput,
    raw_output = update.rawOutput,
  }
end

--- Merge a ToolCall(Update) into the event log + `pending_tool_calls`: a
--- known `toolCallId` merges non-nil fields (arrays replace wholesale), an
--- unknown/new one appends a fresh tool_call event. Returns the
--- `{ event, index }` ref.
---
--- Phase 6 (`client.lua`) reuses this via `Session:merge_tool_call` to
--- correlate a `session/request_permission` toolCall (itself a ToolCallUpdate)
--- into the same log + pending map without duplicating merge logic.
---@param sess mya.Session
---@param update table ToolCall or ToolCallUpdate
---@return { event: table, index: integer }
local function merge_tool_call_update(sess, update)
  local ref = update.toolCallId ~= nil and sess.pending_tool_calls[update.toolCallId] or nil
  if not ref then
    -- Unknown toolCallId -> treat as a new tool call.
    local ev = new_tool_call(update)
    local idx = sess:_append_event(ev)
    if ev.id ~= nil then
      sess.pending_tool_calls[ev.id] = { event = ev, index = idx }
      return sess.pending_tool_calls[ev.id]
    end
    return { event = ev, index = idx }
  end
  local ev = ref.event
  if update.title ~= nil then
    ev.title = update.title
  end
  if update.kind ~= nil then
    ev.tool_kind = update.kind
  end
  if update.status ~= nil then
    ev.status = update.status
  end
  if update.content ~= nil then
    ev.content = update.content -- arrays replace wholesale
  end
  if update.locations ~= nil then
    ev.locations = update.locations
  end
  if update.rawInput ~= nil then
    ev.raw_input = update.rawInput
  end
  if update.rawOutput ~= nil then
    ev.raw_output = update.rawOutput
  end
  sess:_emit { type = 'mutate', index = ref.index, event = ev }
  return ref
end

--- Every mutation flows through here. Handles all 11 sessionUpdate variants;
--- unknown variants log a warning + append an info event (never crash).
---@param sess mya.Session
---@param update table the `params.update` object (has `sessionUpdate` tag)
local function apply_update(sess, update)
  if type(update) ~= 'table' then
    return
  end
  local kind = update.sessionUpdate

  if kind == 'user_message_chunk' then
    handle_chunk(sess, 'user', update.content, update.messageId)
  elseif kind == 'agent_message_chunk' then
    handle_chunk(sess, 'agent', update.content, update.messageId)
  elseif kind == 'agent_thought_chunk' then
    handle_chunk(sess, 'thought', update.content, update.messageId)
  elseif kind == 'tool_call' then
    close_coalesce(sess)
    -- A full ToolCall for an already-known id merges too (idempotent — some
    -- agents resend); an unknown id appends. Same path as tool_call_update.
    merge_tool_call_update(sess, update)
  elseif kind == 'tool_call_update' then
    close_coalesce(sess)
    merge_tool_call_update(sess, update)
  elseif kind == 'plan' then
    close_coalesce(sess)
    -- Single mutable plan event per session (mya://<agent>/<session>/plan
    -- renders "the" plan); a plan update REPLACES entries and bumps revision.
    if sess._plan_index then
      local ev = sess.events[sess._plan_index]
      ev.entries = update.entries
      ev.revision = (ev.revision or 0) + 1
      sess:_emit { type = 'mutate', index = sess._plan_index, event = ev }
    else
      sess._plan_index = sess:_append_event { kind = 'plan', entries = update.entries, revision = 1 }
    end
  elseif kind == 'available_commands_update' then
    sess.available_commands = update.availableCommands
    sess:_mark_dirty()
  elseif kind == 'current_mode_update' then
    sess.current_mode_id = update.currentModeId
    sess:_mark_dirty()
  elseif kind == 'config_option_update' then
    sess.config_options = update.configOptions
    sess:_mark_dirty()
  elseif kind == 'session_info_update' then
    if update.title ~= nil then
      sess.title = update.title
    end
    if update.updatedAt ~= nil then
      sess.updated_at = update.updatedAt
    end
    sess:_mark_dirty()
  elseif kind == 'usage_update' then
    sess.usage = { used = update.used, size = update.size, cost = update.cost }
    sess:_mark_dirty()
  else
    util.warn(sess.agent_name, 'unknown sessionUpdate variant: ' .. tostring(kind))
    sess:_append_event { kind = 'info', text = 'unknown update: ' .. tostring(kind) }
  end
end

M._apply_update = apply_update -- exposed for tests

--- Phase 6 addition: merge a ToolCall(Update) into this session's log —
--- client.lua uses it to correlate `session/request_permission`'s embedded
--- toolCall through the exact same merge path as session/update.
---@param update table ToolCall or ToolCallUpdate payload
---@return { event: table, index: integer }
function Session:merge_tool_call(update)
  return merge_tool_call_update(self, update)
end

-- ---------------------------------------------------------------------
-- Per-agent update routing + crash handling (installed lazily)
-- ---------------------------------------------------------------------

---@param agent_name string
local function on_agent_crash(agent_name)
  local sessions = registry[agent_name]
  if not sessions then
    return
  end
  for _, sess in pairs(sessions) do
    if sess.status ~= 'error' then
      -- If a prompt is still in flight and its request callback hasn't run
      -- (rpc rejects pending requests before on_crash fires, so usually it
      -- has), finalize it here.
      local pcb = sess._prompt_cb
      sess._prompt_cb = nil
      sess.cancelling = false
      sess:_append_event { kind = 'info', text = 'agent crashed' }
      sess:_set_status 'error'
      if pcb then
        pcall(pcb, { code = -32603, message = '[mya] agent crashed', data = { mya_transport = true } }, nil)
      end
    end
  end
end

--- Install (once per agent) the update-routing hook and the crash hook.
---@param agent_name string
---@return mya.Agent
local function ensure_routing(agent_name)
  local ag = agent_mod.get(agent_name)
  if routed_agents[agent_name] then
    return ag
  end
  routed_agents[agent_name] = true

  ag.session_update_hook = function(params)
    local sid = params and params.sessionId
    if not sid then
      util.debug(agent_name, 'session/update without sessionId, ignoring')
      return
    end
    local sess = registry[agent_name] and registry[agent_name][sid]
    if not sess then
      -- Could be another client's session on a shared agent.
      util.debug(agent_name, 'session/update for unknown sessionId ' .. tostring(sid) .. ', ignoring')
      return
    end
    apply_update(sess, params.update or {})
  end

  ag.on_crash = function(_a)
    on_agent_crash(agent_name)
  end

  return ag
end

-- ---------------------------------------------------------------------
-- Session object construction
-- ---------------------------------------------------------------------

---@param agent_name string
---@param id string
---@param cwd string
---@return mya.Session
local function new_session(agent_name, id, cwd)
  return setmetatable({
    id = id,
    agent_name = agent_name,
    cwd = cwd,
    title = nil,
    status = 'idle',
    created_here = false,
    config_options = nil,
    current_mode_id = nil,
    available_commands = nil,
    usage = nil,
    updated_at = nil,
    events = {},
    pending_tool_calls = {},
    stop_reason = nil,
    cancelling = false,
    -- private
    _agent = agent_mod.get(agent_name),
    _subs = {},
    _status_subs = {},
    _deltas = {},
    _dirty = false,
    _status_changed = false,
    _flush_scheduled = false,
    _coalesce = nil,
    _plan_index = nil,
    _prompt_cb = nil,
    _cancel_hooks = {}, -- Phase 6: see Session:on_cancel
  }, Session)
end

--- Store modes/configOptions from a session/new | session/load response.
---@param sess mya.Session
---@param result table?
local function absorb_session_result(sess, result)
  if type(result) ~= 'table' then
    return
  end
  if result.configOptions ~= nil then
    sess.config_options = result.configOptions
  end
  if type(result.modes) == 'table' then
    sess.current_mode_id = result.modes.currentModeId
    sess._modes = result.modes.availableModes
  end
end

-- ---------------------------------------------------------------------
-- Registry accessors
-- ---------------------------------------------------------------------

--- Look up an in-memory session.
---@param agent_name string
---@param session_id string
---@return mya.Session?
function M.get(agent_name, session_id)
  local sessions = registry[agent_name]
  return sessions and sessions[session_id] or nil
end

--- All in-memory sessions across all agents.
---@return mya.Session[]
function M.all()
  local out = {}
  for _, sessions in pairs(registry) do
    for _, sess in pairs(sessions) do
      out[#out + 1] = sess
    end
  end
  return out
end

-- ---------------------------------------------------------------------
-- Lifecycle: new / load / list_remote
-- ---------------------------------------------------------------------

--- Create a new session (`session/new`). opts: `{ cwd?, mcp_servers? }`.
--- cwd defaults to the current working directory; mcp_servers defaults to
--- the agent's configured `mcp_servers`.
---@param agent_name string
---@param opts { cwd: string?, mcp_servers: table[]? }?
---@param cb fun(err: table?, session: mya.Session?)
function M.new(agent_name, opts, cb)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  local ag = ensure_routing(agent_name)
  local mcp = opts.mcp_servers or mcp_servers_for(agent_name)

  ag:request('session/new', { cwd = cwd, mcpServers = mcp }, function(err, result)
    if err then
      if cb then
        cb(err, nil)
      end
      return
    end
    local sid = result and result.sessionId
    if not sid then
      if cb then
        cb({ code = -32603, message = '[mya] session/new returned no sessionId' }, nil)
      end
      return
    end
    local sess = new_session(agent_name, sid, cwd)
    sess.created_here = true
    sess.status = 'idle'
    absorb_session_result(sess, result)
    register(sess)
    if cb then
      cb(nil, sess)
    end
  end)
end

--- Resume a session (`session/load`). Requires `loadSession`. Replay updates
--- arrive as notifications BEFORE the response; routing is wired (via the
--- registry) before the request is sent so replay lands in the same log.
--- On success a `reset` delta fires so a renderer redraws from scratch.
---@param agent_name string
---@param session_id string
---@param cb fun(err: table?, session: mya.Session?)
function M.load(agent_name, session_id, cb)
  local ag = ensure_routing(agent_name)
  ag:ensure_ready(function(ready_err)
    if ready_err then
      if cb then
        cb(ready_err, nil)
      end
      return
    end
    if not ag:supports 'loadSession' then
      if cb then
        cb({ code = -32601, message = '[mya] agent does not support loadSession' }, nil)
      end
      return
    end

    -- Register BEFORE sending session/load so replay notifications route here.
    local sess = new_session(agent_name, session_id, vim.fn.getcwd())
    sess.status = 'unloaded'
    register(sess)

    ag:request('session/load', {
      sessionId = session_id,
      cwd = sess.cwd,
      mcpServers = mcp_servers_for(agent_name),
    }, function(err, result)
      if err then
        sess:_append_event { kind = 'info', text = 'session/load failed: ' .. (err.message or vim.inspect(err)) }
        sess:_set_status 'error'
        if cb then
          cb(err, sess)
        end
        return
      end
      absorb_session_result(sess, result)
      sess:_emit { type = 'reset' } -- replay complete: renderer redraws
      sess:_set_status 'idle'
      if cb then
        cb(nil, sess)
      end
    end)
  end)
end

--- Last successful `session/list` result per agent. In-memory only (no
--- client-side persistence, concepts-v3): this exists so synchronous
--- consumers — `:Mya open` completion — have candidates without blocking on
--- a round-trip. Refreshed by every list_remote() call (dashboard opens).
---@type table<string, table[]>
local list_cache = {}

--- List remote sessions (`session/list`), paginating through all cursors.
--- Returns raw [SessionInfo]; does NOT create session objects (dashboard use).
---@param agent_name string
---@param cb fun(err: table?, sessions: table[]?)
function M.list_remote(agent_name, cb)
  local ag = agent_mod.get(agent_name)
  local all = {}
  local function page(cursor)
    -- Empty params must be an OBJECT, not `[]`; use empty_dict when no cursor.
    local params = cursor and { cursor = cursor } or vim.empty_dict()
    ag:request('session/list', params, function(err, result)
      if err then
        cb(err, nil)
        return
      end
      for _, s in ipairs((result and result.sessions) or {}) do
        all[#all + 1] = s
      end
      if result and result.nextCursor ~= nil then
        page(result.nextCursor)
      else
        list_cache[agent_name] = all
        cb(nil, all)
      end
    end)
  end
  page(nil)
end

--- The most recent list_remote() result for an agent (possibly stale, maybe
--- never fetched — completion-quality data, not truth).
---@param agent_name string
---@return table[] [SessionInfo]
function M.list_cached(agent_name)
  return list_cache[agent_name] or {}
end

-- ---------------------------------------------------------------------
-- Prompting / cancel / config / delete
-- ---------------------------------------------------------------------

---@param sess mya.Session
---@param stop string?
local function maybe_notify_turn_end(sess, stop)
  local ok, cfg = pcall(config.get)
  if ok and cfg.notify and cfg.notify.turn_end then
    vim.schedule(function()
      pcall(
        vim.notify,
        ('[mya] %s: turn ended (%s)'):format(sess.agent_name, tostring(stop)),
        vim.log.levels.INFO
      )
    end)
  end
end

--- Send a prompt (`session/prompt`). One prompt in flight per session:
--- rejects (does NOT queue) if status ~= idle. Appends a turn-start event
--- (with a config snapshot), a user message event per content block, sets
--- status 'prompting'. `cb(err, stop_reason)` fires on the turn-end response.
---@param content_blocks table[] [ContentBlock]
---@param cb (fun(err: table?, stop_reason: string?))?
function Session:prompt(content_blocks, cb)
  if self.status ~= 'idle' then
    local err = {
      code = -32600,
      message = ('[mya] session busy (status=%s); one prompt in flight per session'):format(self.status),
    }
    if cb then
      vim.schedule(function()
        cb(err, nil)
      end)
    end
    return
  end

  content_blocks = content_blocks or {}
  local snapshot = config_snapshot(self)

  self:_append_event { kind = 'turn', phase = 'start', config_snapshot = snapshot }
  for _, block in ipairs(content_blocks) do
    if is_text_block(block) then
      self:_append_event {
        kind = 'message',
        role = 'user',
        content = block.text or '',
        complete = true,
        meta = { config_snapshot = snapshot, timestamp = now_ts() },
      }
    else
      self:_append_event {
        kind = 'message',
        role = 'user',
        content = ('[%s]'):format((type(block) == 'table' and block.type) or 'content'),
        block = block,
        complete = true,
        meta = { config_snapshot = snapshot, timestamp = now_ts() },
      }
    end
  end

  self.cancelling = false
  self.stop_reason = nil
  self._coalesce = nil
  self:_set_status 'prompting'
  self._prompt_cb = cb

  self._agent:request('session/prompt', { sessionId = self.id, prompt = content_blocks }, function(err, result)
    local pcb = self._prompt_cb
    self._prompt_cb = nil
    -- If the crash handler already finalized this turn, do nothing.
    if pcb == nil and self.status == 'error' then
      return
    end
    self.cancelling = false
    close_coalesce(self) -- close any still-open coalesced message at turn end

    if err then
      self:_append_event { kind = 'info', text = err.message or 'prompt failed' }
      self:_set_status 'error'
      if pcb then
        pcb(err, nil)
      end
      return
    end

    local stop = result and result.stopReason
    self.stop_reason = stop
    if stop == 'cancelled' then
      -- Phase 6: a turn may resolve cancelled without a client-side cancel()
      -- (agent-initiated); make sure held permission/write responders settle.
      self:_fire_cancel_hooks()
    end
    self:_append_event { kind = 'turn', phase = 'end', stop_reason = stop }
    self:_set_status 'idle'
    maybe_notify_turn_end(self, stop)
    if pcb then
      pcb(nil, stop)
    end
  end)
end

--- Request cancellation of the in-flight turn (`session/cancel`, a
--- notification). Status stays 'prompting' until the prompt response lands
--- with stopReason 'cancelled' (protocol semantics); `cancelling` is set for
--- the UI in the meantime.
function Session:cancel()
  -- Phase 6: 'waiting_permission' is also cancellable — the turn is still in
  -- flight, just blocked on our answer.
  if self.status ~= 'prompting' and self.status ~= 'waiting_permission' then
    return
  end
  self.cancelling = true
  self._agent:notify('session/cancel', { sessionId = self.id })
  -- Protocol: on session/cancel the client MUST answer pending permission
  -- requests with outcome 'cancelled' — the registered hooks do that.
  self:_fire_cancel_hooks()
  self:_mark_dirty()
end

--- Set a session config option (`session/set_config_option`); updates
--- `config_options` from the full set in the response.
---@param config_id string
---@param value string
---@param cb (fun(err: table?, config_options: table[]?))?
function Session:set_config_option(config_id, value, cb)
  self._agent:request('session/set_config_option', {
    sessionId = self.id,
    configId = config_id,
    value = value,
  }, function(err, result)
    if err then
      if cb then
        cb(err, nil)
      end
      return
    end
    if result and result.configOptions ~= nil then
      self.config_options = result.configOptions
      self:_mark_dirty()
    end
    if cb then
      cb(nil, self.config_options)
    end
  end)
end

--- Set the current mode (`session/set_mode`) — the deprecated-but-still-live
--- predecessor of Session Config Options. Phase 5 fallback: the `:Mya
--- config`/`co` picker uses this only when an agent has no `config_options`
--- but does advertise `_modes` (from `session/new`'s `modes.availableModes`).
---@param mode_id string
---@param cb (fun(err: table?))?
function Session:set_mode(mode_id, cb)
  self._agent:request('session/set_mode', { sessionId = self.id, modeId = mode_id }, function(err, _result)
    if err then
      if cb then
        cb(err)
      end
      return
    end
    self.current_mode_id = mode_id
    self:_mark_dirty()
    if cb then
      cb(nil)
    end
  end)
end

--- Session lifecycle requests other than load/new are optional for agents:
--- gated per-method by `sessionCapabilities.<capname>` (absent/null =
--- unsupported — a compliant client must not even send the request).
---@param sess mya.Session
---@param capname "delete"|"close"
---@param cb (fun(err: table?))?
---@return boolean supported
local function require_session_cap(sess, capname, cb)
  if sess._agent:supports(capname) then
    return true
  end
  if cb then
    vim.schedule(function()
      cb {
        code = -32601,
        message = ('[mya] %s does not advertise sessionCapabilities.%s'):format(sess.agent_name, capname),
      }
    end)
  end
  return false
end

--- Delete this session (`session/delete`) and drop it from the registry.
--- Errors without sending anything when the agent doesn't advertise
--- `sessionCapabilities.delete` — see `mya/extern.lua` for the out-of-band
--- CLI fallback such agents can be configured with.
---@param cb (fun(err: table?))?
function Session:delete(cb)
  if not require_session_cap(self, 'delete', cb) then
    return
  end
  self._agent:request('session/delete', { sessionId = self.id }, function(err, _result)
    if err then
      if cb then
        cb(err)
      end
      return
    end
    M.forget(self.agent_name, self.id)
    if cb then
      cb(nil)
    end
  end)
end

--- Close this session (`session/close`) and drop it from the registry. The
--- agent releases its live handle; unlike delete, the session still exists
--- agent-side and can be listed/loaded again later. Capability-gated the
--- same way as `Session:delete`.
---@param cb (fun(err: table?))?
function Session:close(cb)
  if not require_session_cap(self, 'close', cb) then
    return
  end
  self._agent:request('session/close', { sessionId = self.id }, function(err, _result)
    if err then
      if cb then
        cb(err)
      end
      return
    end
    M.forget(self.agent_name, self.id)
    if cb then
      cb(nil)
    end
  end)
end

--- Drop a session from the in-memory registry WITHOUT any protocol
--- interaction. Used after out-of-band deletion (`mya/extern.lua`) where the
--- agent was never told via ACP; harmless if the session isn't registered.
---@param agent_name string
---@param session_id string
function M.forget(agent_name, session_id)
  if registry[agent_name] then
    registry[agent_name][session_id] = nil
  end
end

-- ---------------------------------------------------------------------
-- Test support
-- ---------------------------------------------------------------------

--- Test-only: forget all sessions and routing state (does not stop agents).
function M._reset()
  registry = {}
  routed_agents = {}
  list_cache = {}
end

M.Session = Session

return M
