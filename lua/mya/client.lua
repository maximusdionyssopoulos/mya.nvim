--- Client-served ACP methods (Phase 6): fs/read_text_file,
--- fs/write_text_file, session/request_permission — and the review-unit
--- model that mediates them.
---
--- ## Review model
---
--- The review unit is ONE pending tool call (concepts-v3: review granularity
--- is the tool call; hunks are display-only children). A unit holds:
---   - the tool call ref (title/kind/status live on the session event)
---   - n file changes: `{ path, old_text?, new_text, origin='diff'|'fs_write' }`
---     (`old_text == nil` means "new file")
---   - zero or one held permission responder (the respond() closure from
---     session/request_permission — deferred respond is supported by rpc.lua)
---   - zero or more held fs/write responders (fs/write_text_file is NEVER
---     applied immediately; the respond() closures are held until decision)
---
--- accept(unit) applies all files atomically (buffer edits where loaded,
--- disk writes otherwise), answers every held responder, and lets the turn
--- continue. reject(unit) discards the files and answers reject/-32800.
--- A cancelled turn answers permission with outcome 'cancelled' and held
--- writes with -32800 (via the session cancel hook).
---
--- ## Held-responder registry
---
--- Per-session state lives in `states[session]` (keyed by the session
--- object; sessions live for the Neovim instance):
---   { units = {unit,...} (arrival order),   -- pending only; resolved units are removed
---     by_tool = { toolCallId -> unit },
---     accepted_writes = { path -> new_text },-- writes pre-approved by an accepted unit
---     synthetic_n = int }
--- Unit shape:
---   { id, session, tool_call = event?, title, tool_kind,
---     files = { file... }, permission = { respond, options }?,
---     held_writes = { { respond, path, content }... } }

local config = require 'mya.config'
local util = require 'mya.util'

local M = {}

-- Documented protocol judgment call: JSON-RPC has no "user rejected" code;
-- -32800 (request cancelled, the closest defined code) is used for rejected
-- and turn-cancelled fs/write_text_file requests.
M.WRITE_REJECTED_CODE = -32800

---@type table<mya.Session, table>
local states = {}

-- ---------------------------------------------------------------------
-- Text helpers (shared with ui/review.lua)
-- ---------------------------------------------------------------------

--- Split text into lines the way a buffer holds them: a trailing newline
--- does NOT produce a trailing empty line ('a\nb\n' -> {'a','b'}).
---@param text string?
---@return string[]
function M.text_to_lines(text)
  if text == nil or text == '' then
    return {}
  end
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

--- Canonical text form for vim.diff: newline-terminated unless empty.
---@param lines string[]
---@return string
function M.lines_to_text(lines)
  if #lines == 0 then
    return ''
  end
  return table.concat(lines, '\n') .. '\n'
end

--- Canonicalize arbitrary text (nil = new file) for vim.diff input.
---@param text string?
---@return string
local function canon(text)
  return M.lines_to_text(M.text_to_lines(text))
end

--- Find a loaded, listed buffer whose full name is `path`.
---@param path string
---@return integer? bufnr
function M.find_loaded_buf(path)
  local want = vim.fn.fnamemodify(path, ':p')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
      if vim.api.nvim_buf_get_name(buf) == want then
        return buf
      end
    end
  end
  return nil
end

--- Current content of a path: loaded-buffer text (unsaved state) if there is
--- one, else disk content, else nil (no such file).
---@param path string
---@return string? text
---@return integer? bufnr
local function read_current(path)
  local buf = M.find_loaded_buf(path)
  if buf then
    return M.lines_to_text(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), buf
  end
  local f = io.open(path, 'r')
  if not f then
    return nil, nil
  end
  local text = f:read '*a'
  f:close()
  return text, nil
end

--- vim.diff indices hunks between two (possibly nil) texts.
---@param old_text string?
---@param new_text string?
---@return integer[][] hunks {start_a, count_a, start_b, count_b}
function M.file_hunks(old_text, new_text)
  return vim.diff(canon(old_text), canon(new_text), { result_type = 'indices' }) --[[@as integer[][] ]]
end

--- Added/deleted line counts for one file change.
---@param file table
---@return integer added
---@return integer deleted
function M.file_counts(file)
  local add, del = 0, 0
  for _, h in ipairs(M.file_hunks(file.old_text, file.new_text)) do
    del = del + h[2]
    add = add + h[4]
  end
  return add, del
end

-- ---------------------------------------------------------------------
-- Per-session state / unit registry
-- ---------------------------------------------------------------------

---@param sess mya.Session
local function ensure_state(sess)
  local st = states[sess]
  if st then
    return st
  end
  st = { units = {}, by_tool = {}, accepted_writes = {}, synthetic_n = 0 }
  states[sess] = st
  -- Cancel hook: a cancelled turn must settle every held responder
  -- (protocol: pending permissions answered with outcome 'cancelled').
  sess:on_cancel(function()
    M._cancel_all(sess)
  end)
  return st
end

--- Signal "units changed" to subscribers (the review buffer re-renders on
--- session dirty flushes).
---@param sess mya.Session
local function units_changed(sess)
  sess:_mark_dirty()
end

---@param sess mya.Session
---@param tool_ref { event: table, index: integer }? nil -> synthetic unit
---@return table unit
local function get_or_create_unit(sess, tool_ref)
  local st = ensure_state(sess)
  local tc = tool_ref and tool_ref.event or nil
  if tc and tc.id ~= nil and st.by_tool[tc.id] then
    return st.by_tool[tc.id]
  end
  local unit = {
    id = tc and tc.id or nil,
    session = sess,
    tool_call = tc,
    title = tc and tc.title or 'file write',
    tool_kind = tc and tc.tool_kind or nil,
    files = {},
    permission = nil,
    held_writes = {},
  }
  if unit.id == nil then
    st.synthetic_n = st.synthetic_n + 1
    unit.id = ('synthetic-%d'):format(st.synthetic_n)
  end
  st.units[#st.units + 1] = unit
  if tc and tc.id ~= nil then
    st.by_tool[tc.id] = unit
  end
  return unit
end

--- Upsert a file change into a unit (dedupe by path; a later change to the
--- same path replaces new_text/origin but keeps the first old_text capture).
---@param unit table
---@param file { path: string, old_text: string?, new_text: string, origin: string }
local function upsert_file(unit, file)
  for _, f in ipairs(unit.files) do
    if f.path == file.path then
      f.new_text = file.new_text
      f.origin = file.origin
      return
    end
  end
  unit.files[#unit.files + 1] = file
end

--- Pull diff-type ToolCallContent off a tool-call event into unit files.
---@param unit table
---@param tc_event table
local function absorb_diff_content(unit, tc_event)
  for _, c in ipairs(tc_event.content or {}) do
    if type(c) == 'table' and c.type == 'diff' and type(c.path) == 'string' then
      local old_text = c.oldText
      if old_text == nil then
        -- Agent did not state the old content: capture the current
        -- buffer-or-disk state (nil if the file does not exist = new file).
        -- NOTE: schema says oldText null/absent means "new file", but
        -- capturing current content makes the apply/diff safe either way.
        old_text = (read_current(c.path))
      end
      upsert_file(unit, { path = c.path, old_text = old_text, new_text = c.newText or '', origin = 'diff' })
    end
  end
end

---@param sess mya.Session
---@param unit table
local function remove_unit(sess, unit)
  local st = states[sess]
  if not st then
    return
  end
  for i, u in ipairs(st.units) do
    if u == unit then
      table.remove(st.units, i)
      break
    end
  end
  if unit.tool_call and unit.tool_call.id ~= nil then
    st.by_tool[unit.tool_call.id] = nil
  end
end

--- Pending review units for a session, arrival order (renderers reverse for
--- newest-first display).
---@param sess mya.Session
---@return table[] units
function M.units(sess)
  local st = states[sess]
  if not st then
    return {}
  end
  return st.units -- callers treat this as read-only
end

--- Read-only "applied" units derived from session history: one per COMPLETED
--- tool-call event carrying diff content that has no pending unit (either the
--- unit was already answered, or the agent applied the edit itself and never
--- asked — e.g. opencode with edit permissions allowed). Same shape as
--- pending units plus `applied = true`; accept/reject must not act on these.
--- Rebuilt from `sess.events` on every call (no state held).
---@param sess mya.Session
---@return table[] units
function M.history_units(sess)
  local st = states[sess]
  local out = {}
  for _, ev in ipairs(sess.events) do
    local pending = st and ev.id ~= nil and st.by_tool[ev.id] ~= nil
    if ev.kind == 'tool_call' and ev.status == 'completed' and not pending then
      local unit
      for _, c in ipairs(type(ev.content) == 'table' and ev.content or {}) do
        if type(c) == 'table' and c.type == 'diff' and type(c.path) == 'string' then
          unit = unit or {
            id = 'history-' .. tostring(ev.id),
            session = sess,
            tool_call = ev,
            title = ev.title or 'tool call',
            tool_kind = ev.tool_kind,
            files = {},
            held_writes = {},
            applied = true,
          }
          upsert_file(unit, { path = c.path, old_text = c.oldText, new_text = c.newText or '', origin = 'history' })
        end
      end
      if unit then
        out[#out + 1] = unit
      end
    end
  end
  return out
end

--- Test/debug: number of held responders (permission + writes) for a session.
---@param sess mya.Session
---@return integer
function M._held_count(sess)
  local st = states[sess]
  if not st then
    return 0
  end
  local n = 0
  for _, u in ipairs(st.units) do
    if u.permission then
      n = n + 1
    end
    n = n + #u.held_writes
  end
  return n
end

-- ---------------------------------------------------------------------
-- fs/read_text_file — served immediately, never held
-- ---------------------------------------------------------------------

--- Serve fs/read_text_file: loaded+listed buffer content (unsaved state —
--- that's the point) if the file has one, else disk. Honors `line` (1-based
--- start) + `limit` (line count): a windowed read returns the selected lines
--- newline-joined with a trailing newline; a full read returns disk text
--- as-is (buffer reads are always newline-normalized).
---@param agent mya.Agent
---@param params { sessionId: string, path: string, line: integer?, limit: integer? }?
---@param respond fun(result: table?, err: table?)
function M.handle_read_text_file(agent, params, respond)
  params = params or {}
  local path = params.path
  if type(path) ~= 'string' then
    respond(nil, { code = -32602, message = '[mya] fs/read_text_file: missing path' })
    return
  end

  local text
  local buf = M.find_loaded_buf(path)
  if buf then
    text = M.lines_to_text(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  else
    local f = io.open(path, 'r')
    if not f then
      respond(nil, { code = -32002, message = 'Resource not found', data = { path = path } })
      return
    end
    text = f:read '*a'
    f:close()
  end

  if params.line == nil and params.limit == nil then
    respond { content = text }
    return
  end

  local lines = M.text_to_lines(text)
  local first = params.line or 1
  local last = params.limit and (first + params.limit - 1) or #lines
  local window = {}
  for i = math.max(first, 1), math.min(last, #lines) do
    window[#window + 1] = lines[i]
  end
  util.debug(agent.name, ('fs/read_text_file %s line=%s limit=%s -> %d lines'):format(path, tostring(params.line), tostring(params.limit), #window))
  respond { content = M.lines_to_text(window) }
end

-- ---------------------------------------------------------------------
-- fs/write_text_file — NEVER written immediately; held on a review unit
-- ---------------------------------------------------------------------

--- Most plausible owning tool call for an intercepted write: the session's
--- most recent pending/in_progress tool call whose locations or existing
--- diff content mention `path`; else the most recent pending/in_progress
--- tool call; else nil (synthetic unit).
---@param sess mya.Session
---@param path string
---@return { event: table, index: integer }?
local function owning_tool_call(sess, path)
  local best_match, best_any
  for _, ref in pairs(sess.pending_tool_calls) do
    local ev = ref.event
    if ev.status == 'pending' or ev.status == 'in_progress' then
      if not best_any or ref.index > best_any.index then
        best_any = ref
      end
      local mentions = false
      for _, loc in ipairs(ev.locations or {}) do
        if loc.path == path then
          mentions = true
        end
      end
      for _, c in ipairs(ev.content or {}) do
        if type(c) == 'table' and c.type == 'diff' and c.path == path then
          mentions = true
        end
      end
      if mentions and (not best_match or ref.index > best_match.index) then
        best_match = ref
      end
    end
  end
  return best_match or best_any
end

---@param agent mya.Agent
---@param params { sessionId: string, path: string, content: string }?
---@param respond fun(result: table?, err: table?)
function M.handle_write_text_file(agent, params, respond)
  params = params or {}
  local sess = require('mya.session').get(agent.name, params.sessionId)
  if not sess then
    respond(nil, { code = -32602, message = '[mya] fs/write_text_file: unknown session ' .. tostring(params.sessionId) })
    return
  end
  local path, content = params.path, params.content
  if type(path) ~= 'string' or type(content) ~= 'string' then
    respond(nil, { code = -32602, message = '[mya] fs/write_text_file: missing path/content' })
    return
  end

  -- A write matching a file of an already-accepted unit was pre-approved by
  -- the user's accept (the content is already applied): answer immediately.
  local st = ensure_state(sess)
  if st.accepted_writes[path] ~= nil and canon(st.accepted_writes[path]) == canon(content) then
    util.debug(agent.name, 'fs/write_text_file pre-approved by accepted unit: ' .. path)
    respond(vim.empty_dict())
    return
  end

  local unit = get_or_create_unit(sess, owning_tool_call(sess, path))
  local old_text = (read_current(path))
  upsert_file(unit, { path = path, old_text = old_text, new_text = content, origin = 'fs_write' })
  unit.held_writes[#unit.held_writes + 1] = { respond = respond, path = path, content = content }
  util.info(agent.name, ('fs/write_text_file held for review: %s (unit %s)'):format(path, unit.id))
  units_changed(sess)
end

-- ---------------------------------------------------------------------
-- session/request_permission
-- ---------------------------------------------------------------------

---@param options table[]
---@param kinds string[] preference order
---@return table? option
local function pick_option(options, kinds)
  for _, kind in ipairs(kinds) do
    for _, o in ipairs(options or {}) do
      if o.kind == kind then
        return o
      end
    end
  end
  return nil
end

--- vim.ui.select fallback: permission requests with no file changes (e.g.
--- execute tools), or review.ui = 'select'. Answers directly; intercepted
--- writes (if any later) still go through units.
---@param sess mya.Session
---@param params table
---@param respond fun(result: table?, err: table?)
local function select_permission(sess, params, respond)
  local options = params.options or {}
  sess:_set_status 'waiting_permission'
  local answered = false
  local unregister
  local function answer(outcome)
    if answered then
      return
    end
    answered = true
    if unregister then
      unregister()
    end
    if sess.status == 'waiting_permission' then
      sess:_set_status 'prompting'
    end
    respond { outcome = outcome }
  end
  -- A cancelled turn must settle this responder too.
  unregister = sess:on_cancel(function()
    answer { outcome = 'cancelled' }
  end)
  vim.schedule(function()
    if answered then
      return
    end
    vim.ui.select(options, {
      prompt = ('[mya] %s requests permission: %s'):format(sess.agent_name, tostring(params.toolCall and params.toolCall.title)),
      format_item = function(o)
        return ('%s (%s)'):format(o.name or o.optionId, o.kind or '?')
      end,
    }, function(choice)
      if not choice then
        answer { outcome = 'cancelled' }
      else
        answer { outcome = 'selected', optionId = choice.optionId }
      end
    end)
  end)
end

---@param agent mya.Agent
---@param params { sessionId: string, toolCall: table, options: table[] }?
---@param respond fun(result: table?, err: table?)
function M.handle_request_permission(agent, params, respond)
  params = params or {}
  local sess = require('mya.session').get(agent.name, params.sessionId)
  if not sess then
    util.warn(agent.name, 'session/request_permission for unknown session; answering cancelled')
    respond { outcome = { outcome = 'cancelled' } }
    return
  end

  -- Correlate/merge the embedded ToolCallUpdate through the session's own
  -- merge path (creates the event for an unknown toolCallId).
  local tool_ref = nil
  if type(params.toolCall) == 'table' then
    tool_ref = sess:merge_tool_call(params.toolCall)
  end

  local unit = get_or_create_unit(sess, tool_ref)
  if tool_ref then
    absorb_diff_content(unit, tool_ref.event)
  end

  local cfg = config.get()
  local review_cfg = cfg.review or {}

  -- Fallback UX: config'd select mode, or nothing reviewable in the unit
  -- (permission for a non-edit tool, e.g. execute).
  if review_cfg.ui == 'select' or #unit.files == 0 then
    if #unit.files == 0 and unit.permission == nil and #unit.held_writes == 0 then
      remove_unit(sess, unit) -- nothing to review; don't leave an empty unit
    end
    select_permission(sess, params, respond)
    return
  end

  -- Primary UX: hold the responder on the unit; the review buffer answers.
  unit.permission = { respond = respond, options = params.options or {} }
  sess:_set_status 'waiting_permission'

  if cfg.notify and cfg.notify.permission then
    vim.schedule(function()
      pcall(vim.notify, ('[mya] %s: permission requested — %s'):format(sess.agent_name, unit.title or ''), vim.log.levels.WARN)
    end)
  end
  if review_cfg.auto_qf then
    M.populate_qf(sess)
  end
  if review_cfg.open ~= 'manual' then
    vim.schedule(function()
      pcall(function()
        require('mya.ui.review').open(sess)
      end)
    end)
  end
  units_changed(sess)
end

-- ---------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------

--- Write `text` to disk creating parent directories. Uses binary-mode
--- writefile when the text has no trailing newline so content round-trips
--- exactly.
---@param path string
---@param text string
local function write_disk(path, text)
  local dir = vim.fn.fnamemodify(path, ':h')
  if dir ~= '' and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines) -- trailing newline: default writefile mode adds it back
    vim.fn.writefile(lines, path)
  else
    vim.fn.writefile(lines, path, 'b') -- no trailing newline
  end
end

--- Apply one file change. Loaded buffer: hunk-wise nvim_buf_set_lines
--- (bottom-up, single undo step via :undojoin between edits) computed with
--- vim.diff over the CURRENT buffer text as `old`; if the buffer changed
--- since capture (text ~= old_text) fall back to a full-buffer replace
--- (still one undo entry) with a warning. The buffer is left modified —
--- the user saves. No buffer: disk write + checktime.
---@param sess mya.Session
---@param file table
local function apply_file(sess, file)
  local buf = M.find_loaded_buf(file.path)
  local new_lines = M.text_to_lines(file.new_text)

  if not buf then
    write_disk(file.path, file.new_text or '')
    -- Safety net for anything else viewing the file; we do not auto-reload
    -- edits under review (FileChangedShell default behavior is kept).
    pcall(vim.cmd.checktime)
    return
  end

  local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur_text = M.lines_to_text(cur_lines)

  if cur_text ~= canon(file.old_text) then
    -- Buffer changed since capture: hunk positions are unreliable relative
    -- to what was reviewed — replace wholesale (one undo entry).
    util.warn(sess.agent_name, ('buffer for %s changed since review capture; applying full replace'):format(file.path))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    return
  end

  local hunks = vim.diff(cur_text, canon(file.new_text), { result_type = 'indices' }) --[[@as integer[][] ]]
  vim.api.nvim_buf_call(buf, function()
    -- Bottom-up so earlier hunk positions stay valid; undojoin chains all
    -- set_lines calls into ONE undo step (first edit without undojoin).
    for i = #hunks, 1, -1 do
      local sa, ca, sb, cb = hunks[i][1], hunks[i][2], hunks[i][3], hunks[i][4]
      if i < #hunks then
        pcall(vim.cmd, 'undojoin')
      end
      local start_line, end_line
      if ca == 0 then
        start_line, end_line = sa, sa -- pure insertion after old line sa
      else
        start_line, end_line = sa - 1, sa - 1 + ca
      end
      local repl = {}
      for k = sb, sb + cb - 1 do
        repl[#repl + 1] = new_lines[k]
      end
      vim.api.nvim_buf_set_lines(buf, start_line, end_line, false, repl)
    end
  end)
end

-- ---------------------------------------------------------------------
-- accept / reject / cancel
-- ---------------------------------------------------------------------

---@param target table mya.Session or unit
---@return mya.Session? sess
---@return table? unit
local function resolve_target(target)
  if type(target) ~= 'table' then
    return nil, nil
  end
  if target.files ~= nil and target.session ~= nil then
    return target.session, target
  end
  -- Session: first pending unit (review order is one-by-one).
  local st = states[target]
  if st and st.units[1] then
    return target, st.units[1]
  end
  return target, nil
end

---@param unit table
---@param sess mya.Session
local function restore_status(unit, sess)
  if unit.permission and sess.status == 'waiting_permission' then
    sess:_set_status 'prompting'
  end
end

--- Accept a review unit: apply all its files atomically, answer every held
--- write with success, answer the permission (preferring the configured
--- accept kind), and drop the unit.
---@param target table unit or mya.Session
---@return boolean ok
---@return string? err
function M.accept(target)
  local sess, unit = resolve_target(target)
  if not sess or not unit then
    return false, '[mya] no pending review unit'
  end
  local st = ensure_state(sess)

  for _, file in ipairs(unit.files) do
    local ok, apply_err = pcall(apply_file, sess, file)
    if not ok then
      util.error(sess.agent_name, ('apply failed for %s: %s'):format(file.path, tostring(apply_err)))
      return false, tostring(apply_err)
    end
    -- Pre-approve the agent's own follow-up fs/write for this exact content.
    st.accepted_writes[file.path] = file.new_text
  end

  for _, hw in ipairs(unit.held_writes) do
    hw.respond(vim.empty_dict())
  end
  unit.held_writes = {}

  if unit.permission then
    local cfg = config.get()
    local prefer = (cfg.review and cfg.review.default_accept_kind) or 'allow_once'
    local opt = pick_option(unit.permission.options, { prefer, 'allow_once', 'allow_always' })
      or unit.permission.options[1]
    if opt then
      unit.permission.respond { outcome = { outcome = 'selected', optionId = opt.optionId } }
    else
      unit.permission.respond { outcome = { outcome = 'cancelled' } }
    end
  end
  restore_status(unit, sess)
  unit.permission = nil

  remove_unit(sess, unit)
  units_changed(sess)
  return true
end

--- Reject a review unit: discard its files (nothing applied), answer held
--- writes with -32800, answer the permission with a reject-kind option.
---@param target table unit or mya.Session
---@return boolean ok
---@return string? err
function M.reject(target)
  local sess, unit = resolve_target(target)
  if not sess or not unit then
    return false, '[mya] no pending review unit'
  end

  for _, hw in ipairs(unit.held_writes) do
    hw.respond(nil, { code = M.WRITE_REJECTED_CODE, message = '[mya] write rejected by user' })
  end
  unit.held_writes = {}

  if unit.permission then
    local opt = pick_option(unit.permission.options, { 'reject_once', 'reject_always' })
    if opt then
      unit.permission.respond { outcome = { outcome = 'selected', optionId = opt.optionId } }
    else
      unit.permission.respond { outcome = { outcome = 'cancelled' } }
    end
  end
  restore_status(unit, sess)
  unit.permission = nil

  remove_unit(sess, unit)
  units_changed(sess)
  return true
end

--- Cancelled turn: settle every held responder for the session (permission
--- -> outcome 'cancelled', writes -> -32800) and discard all units.
--- Idempotent — the session cancel hook may fire more than once.
---@param sess mya.Session
function M._cancel_all(sess)
  local st = states[sess]
  if not st or #st.units == 0 then
    return
  end
  local units = st.units
  st.units = {}
  st.by_tool = {}
  for _, unit in ipairs(units) do
    for _, hw in ipairs(unit.held_writes) do
      pcall(hw.respond, nil, { code = M.WRITE_REJECTED_CODE, message = '[mya] write rejected: turn cancelled' })
    end
    unit.held_writes = {}
    if unit.permission then
      pcall(unit.permission.respond, { outcome = { outcome = 'cancelled' } })
      unit.permission = nil
    end
  end
  if sess.status == 'waiting_permission' then
    sess:_set_status 'prompting' -- prompt response (stopReason cancelled) takes it to idle
  end
  units_changed(sess)
end

-- ---------------------------------------------------------------------
-- Quickfix
-- ---------------------------------------------------------------------

---@param info table quickfixtextfunc info dict
---@return string[]
local function qf_textfunc(info)
  local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
  local out = {}
  for i = info.start_idx, info.end_idx do
    local it = items[i]
    local name = (it.bufnr and it.bufnr > 0) and vim.fn.fnamemodify(vim.fn.bufname(it.bufnr), ':.') or ''
    out[#out + 1] = ('%s:%d %s'):format(name, it.lnum or 0, it.text or '')
  end
  return out
end

--- Fill the quickfix list with one entry per file-HUNK across the session's
--- pending units: `{ filename, lnum = hunk new-side start, text = '<tool
--- title>: @@ -a,b +c,d' }`, title 'ACP review'. `:cnext` drives the review.
---@param sess mya.Session
---@return integer n_entries
function M.populate_qf(sess)
  local items = {}
  local units = M.units(sess)
  for i = #units, 1, -1 do -- newest-first, matching the review buffer
    local unit = units[i]
    for _, file in ipairs(unit.files) do
      for _, h in ipairs(M.file_hunks(file.old_text, file.new_text)) do
        items[#items + 1] = {
          filename = file.path,
          lnum = math.max(h[3], 1),
          text = ('%s: @@ -%d,%d +%d,%d'):format(unit.title or 'tool call', h[1], h[2], h[3], h[4]),
        }
      end
    end
  end
  vim.fn.setqflist({}, ' ', { title = 'ACP review', items = items, quickfixtextfunc = qf_textfunc })
  return #items
end

--- Fill the quickfix list with one entry per FILE touched by any edit/delete/
--- move tool call made so far in the session (historical — everything in
--- `sess.events`, not just currently-pending review units; shares the
--- hunk-counting helpers with `populate_qf` above). Entry text is
--- `"<tool title> — <path> (+a −d)"`; filename+lnum point at the first
--- changed line of the last diff seen for that path (new-side).
---@param sess mya.Session
---@return integer n_entries
function M.populate_session_qf(sess)
  local items = {}
  for _, ev in ipairs(sess.events) do
    if ev.kind == 'tool_call' then
      local edit_kind = ev.tool_kind == 'edit' or ev.tool_kind == 'delete' or ev.tool_kind == 'move'
      local diff_items = {}
      for _, c in ipairs(type(ev.content) == 'table' and ev.content or {}) do
        if type(c) == 'table' and c.type == 'diff' and type(c.path) == 'string' then
          diff_items[#diff_items + 1] = c
        end
      end
      if #diff_items > 0 then
        for _, c in ipairs(diff_items) do
          local add, del = M.file_counts { old_text = c.oldText, new_text = c.newText }
          local hunks = M.file_hunks(c.oldText, c.newText)
          local lnum = (hunks[1] and math.max(hunks[1][3], 1)) or 1
          items[#items + 1] = {
            filename = c.path,
            lnum = lnum,
            text = ('%s — %s (+%d −%d)'):format(ev.title or 'tool call', c.path, add, del),
          }
        end
      elseif edit_kind then
        -- Edit/delete/move kind with no diff content on the event (e.g. a
        -- rename reported only via locations): still surface the file.
        for _, loc in ipairs(type(ev.locations) == 'table' and ev.locations or {}) do
          items[#items + 1] = {
            filename = loc.path,
            lnum = loc.line or 1,
            text = ('%s — %s'):format(ev.title or 'tool call', loc.path),
          }
        end
      end
    end
  end
  vim.fn.setqflist({}, ' ', { title = 'ACP session history', items = items, quickfixtextfunc = qf_textfunc })
  return #items
end

--- Test-only: forget all per-session review state (does not answer held
--- responders).
function M._reset()
  states = {}
end

return M
