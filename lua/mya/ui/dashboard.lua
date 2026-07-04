--- Session dashboard: `:Mya` with no args opens (or focuses) a plain scratch
--- buffer named `mya-dashboard` (deliberately NOT the mya:// BufReadCmd
--- scheme, same pattern as `ui/review.lua`'s `mya-review://`).
---
--- ## Status, not index (fugitive `:G` model)
---
--- Rows are grouped by what needs the user, not by agent:
---
---   Needs review:      sessions blocked on a permission — their pending
---                      tool-call titles render as child lines
---   Running:           sessions with a prompt in flight (spinner)
---   Sessions:          everything else, most recently updated first
---   Agents:            one line per configured agent — ready / loading /
---                      error / "(no session listing)" — `n` starts a session
---
--- On open/refresh: for each configured agent, `ensure_ready`, then — if it
--- advertises `sessionCapabilities.list` — fetch `session/list` and merge
--- with in-memory sessions (`session.all()`), deduped by (agent, sessionId).
--- Agents without list contribute only in-memory sessions (concepts-v3: "no
--- client-side persistence" — that history is genuinely gone once the
--- process exits). `list`-but-no-`load` sessions (not in memory, agent can't
--- resume them) render dimmed with a "not resumable" annotation.
---
--- Maps follow fugitive: `<CR>` opens in the CURRENT window, `o`/`gO`/`O`
--- split/vsplit/tab, `=` toggles an inline preview (pending edits + last
--- message), `cc` composes a prompt, `n` new session, `D` delete, `R`
--- refresh.
---
--- Live refresh: subscribes to `on_status_change` of every in-memory session
--- currently shown, re-rendering (no re-fetch) on change; a shared
--- `ui/spinner.lua` ticker drives the `prompting` indicator, running only
--- while the dashboard buffer is visible AND >=1 row is prompting.

local agent_mod = require 'mya.agent'
local config = require 'mya.config'
local session = require 'mya.session'
local statusline = require 'mya.statusline'
local log = require 'mya.ui.log'
local spinner = require 'mya.ui.spinner'

local M = {}

local api = vim.api

local NS = api.nvim_create_namespace 'mya_dashboard'

api.nvim_set_hl(0, 'MyaDashHeader', { link = 'Title', default = true })
api.nvim_set_hl(0, 'MyaDashDim', { link = 'Comment', default = true })
api.nvim_set_hl(0, 'MyaDashWaiting', { link = 'DiagnosticWarn', default = true })
api.nvim_set_hl(0, 'MyaDashError', { link = 'DiagnosticError', default = true })

---@type integer?
local dash_buf = nil
---@type table?
local dash_state = nil

-- ---------------------------------------------------------------------
-- Data model
-- ---------------------------------------------------------------------

---@class mya.ui.DashRow
---@field agent string
---@field id string
---@field title string?
---@field updated_at any
---@field mem_sess mya.Session?
---@field resumable boolean whether the row can be opened (in-memory, or agent supports loadSession)

---@param row mya.ui.DashRow
---@return string stable per-row key for the `=` expanded set
local function row_key(row)
  return row.agent .. '\0' .. row.id
end

--- Merge a `session/list` result with in-memory sessions for one agent,
--- deduped by sessionId. Remote rows come first (list order), then any
--- purely in-memory session (created here, not yet reflected by the agent's
--- own list) not already covered.
---@param agent_name string
---@param remote table[]? [SessionInfo] ('nil' for a no-list agent)
---@param supports_load boolean
---@return mya.ui.DashRow[]
local function build_rows(agent_name, remote, supports_load)
  local mem_by_id = {}
  for _, s in ipairs(session.all()) do
    if s.agent_name == agent_name then
      mem_by_id[s.id] = s
    end
  end

  local rows, seen = {}, {}
  for _, info in ipairs(remote or {}) do
    local id = info.sessionId
    if id and not seen[id] then
      seen[id] = true
      local mem = mem_by_id[id]
      rows[#rows + 1] = {
        agent = agent_name,
        id = id,
        title = (mem and mem.title) or info.title,
        updated_at = (mem and mem.updated_at) or info.updatedAt,
        mem_sess = mem,
        resumable = mem ~= nil or supports_load,
      }
    end
  end
  -- ipairs(session.all()) has no defined order; sort remaining in-memory-only
  -- ids for deterministic rendering (helps tests too).
  local extra_ids = {}
  for id in pairs(mem_by_id) do
    if not seen[id] then
      extra_ids[#extra_ids + 1] = id
    end
  end
  table.sort(extra_ids)
  for _, id in ipairs(extra_ids) do
    local mem = mem_by_id[id]
    rows[#rows + 1] = {
      agent = agent_name,
      id = id,
      title = mem.title,
      updated_at = mem.updated_at,
      mem_sess = mem,
      resumable = true,
    }
  end
  return rows
end

-- ---------------------------------------------------------------------
-- Row / relative-time formatting
-- ---------------------------------------------------------------------

---@param s any
---@return integer? epoch_seconds
local function parse_time(s)
  if type(s) == 'number' then
    return s
  end
  if type(s) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, se = s:match '(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)'
  if not y then
    return nil
  end
  local ok, t = pcall(os.time, {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(se),
  })
  return ok and t or nil
end

---@param updated_at any
---@return string
local function relative_time(updated_at)
  local t = parse_time(updated_at)
  if not t then
    return '—'
  end
  local diff = math.max(os.time() - t, 0)
  if diff < 60 then
    return 'just now'
  elseif diff < 3600 then
    return ('%dm ago'):format(math.floor(diff / 60))
  elseif diff < 86400 then
    return ('%dh ago'):format(math.floor(diff / 3600))
  else
    return ('%dd ago'):format(math.floor(diff / 86400))
  end
end

---@param row mya.ui.DashRow
---@return string
local function indicator_for(row)
  if not row.mem_sess then
    return ' '
  end
  local status = row.mem_sess.status
  if status == 'prompting' then
    return spinner.current_frame()
  elseif status == 'waiting_permission' then
    return '!'
  elseif status == 'error' then
    return '✗'
  else
    return '·'
  end
end

---@param row mya.ui.DashRow
---@return string status_text
local function status_text(row)
  if row.mem_sess then
    return row.mem_sess.status
  end
  return row.resumable and 'remote' or 'not resumable'
end

--- Full row line text (WITHOUT the leading 2-space indent applied at
--- render() time) — kept a pure function of `row` (+ the shared spinner
--- frame) so the tick handler can recompute exactly this for one line.
---@param row mya.ui.DashRow
---@return string
local function row_text(row)
  local indicator = indicator_for(row)
  local title = row.title or row.id
  local lines_str = row.mem_sess and (('%d lines'):format(log.line_count(row.mem_sess))) or '— lines'

  local parts = { row.agent, lines_str }
  local cparts = statusline.config_parts(row.mem_sess)
  if #cparts > 0 then
    parts[#parts + 1] = table.concat(cparts, ', ')
  end
  parts[#parts + 1] = relative_time(row.updated_at)
  parts[#parts + 1] = status_text(row)

  return ('%s %s · %s'):format(indicator, title, table.concat(parts, ' · '))
end

---@param row mya.ui.DashRow
---@return string? hl_group
local function row_hl(row)
  if not row.mem_sess and not row.resumable then
    return 'MyaDashDim'
  end
  if row.mem_sess then
    if row.mem_sess.status == 'waiting_permission' then
      return 'MyaDashWaiting'
    elseif row.mem_sess.status == 'error' then
      return 'MyaDashError'
    end
  end
  return nil
end

--- Pending tool-call child lines for a needs-review row (always shown).
---@param row mya.ui.DashRow
---@return string[]
local function pending_lines(row)
  local out = {}
  if not row.mem_sess then
    return out
  end
  for _, u in ipairs(require('mya.client').units(row.mem_sess)) do
    out[#out + 1] = ('! %s (%d file%s)'):format(u.title or 'tool call', #u.files, #u.files == 1 and '' or 's')
  end
  return out
end

--- `=` inline preview: pending units + the tail of the conversation.
---@param row mya.ui.DashRow
---@return string[]
local function preview_lines(row)
  if not row.mem_sess then
    return {}
  end
  local out = pending_lines(row)
  for i = #row.mem_sess.events, 1, -1 do
    local e = row.mem_sess.events[i]
    if e.kind == 'message' and e.content and e.content ~= '' then
      local first = e.content:match '[^\n]*'
      out[#out + 1] = ('%s: %s'):format(e.role or '?', first)
      break
    end
  end
  return out
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------

--- Split every agent group's rows into the three status sections.
---@param state table
---@return mya.ui.DashRow[] needs, mya.ui.DashRow[] running, mya.ui.DashRow[] rest
local function categorize(state)
  local needs, running, rest = {}, {}, {}
  local names = {}
  for name in pairs(state.groups) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    for _, row in ipairs(state.groups[name].rows or {}) do
      local st = row.mem_sess and row.mem_sess.status
      if st == 'waiting_permission' then
        needs[#needs + 1] = row
      elseif st == 'prompting' then
        running[#running + 1] = row
      else
        rest[#rest + 1] = row
      end
    end
  end
  -- Most recently updated first; undated rows sink, ties keep agent order.
  table.sort(rest, function(a, b)
    local ta, tb = parse_time(a.updated_at) or 0, parse_time(b.updated_at) or 0
    if ta ~= tb then
      return ta > tb
    end
    return (a.agent .. a.id) < (b.agent .. b.id)
  end)
  return needs, running, rest
end

---@param state table
local function render(state)
  if not api.nvim_buf_is_valid(state.buf) then
    return
  end
  local lines, map, hls = {}, {}, {}
  local prompting_lines = {}

  local function push(text, entry, hl)
    lines[#lines + 1] = text
    map[#lines] = entry
    if hl then
      hls[#hls + 1] = { row = #lines - 1, group = hl }
    end
  end

  ---@param row mya.ui.DashRow
  ---@param children string[]?
  local function push_row(row, children)
    push('  ' .. row_text(row), { kind = 'row', row = row }, row_hl(row))
    if row.mem_sess and row.mem_sess.status == 'prompting' then
      prompting_lines[#lines] = row
    end
    for _, child in ipairs(children or {}) do
      push('      ' .. child, { kind = 'row', row = row }, 'MyaDashDim')
    end
    if state.expanded[row_key(row)] then
      for _, child in ipairs(preview_lines(row)) do
        push('      ' .. child, { kind = 'row', row = row }, 'MyaDashDim')
      end
    end
  end

  local needs, running, rest = categorize(state)

  if #needs > 0 then
    push('Needs review:', { kind = 'header' }, 'MyaDashHeader')
    for _, row in ipairs(needs) do
      push_row(row, pending_lines(row))
    end
    push('', {})
  end

  if #running > 0 then
    push('Running:', { kind = 'header' }, 'MyaDashHeader')
    for _, row in ipairs(running) do
      push_row(row)
    end
    push('', {})
  end

  push('Sessions:', { kind = 'header' }, 'MyaDashHeader')
  if #rest == 0 then
    push('  (no sessions)', { kind = 'info' }, 'MyaDashDim')
  else
    for _, row in ipairs(rest) do
      push_row(row)
    end
  end
  push('', {})

  push('Agents:', { kind = 'header' }, 'MyaDashHeader')
  local names = {}
  for name in pairs(state.groups) do
    names[#names + 1] = name
  end
  table.sort(names)
  if #names == 0 then
    push('  (no agents configured — see :help mya-setup)', { kind = 'info' })
  end
  for _, name in ipairs(names) do
    local grp = state.groups[name]
    local note
    if grp.loading then
      note = 'loading…'
    elseif grp.error then
      note = tostring(grp.error.message or grp.error)
    elseif grp.supports_list == false then
      note = 'ready (no session listing)'
    else
      note = 'ready'
    end
    local hl = grp.error and 'MyaDashError' or 'MyaDashDim'
    push(('  %s · %s'):format(name, note), { kind = 'agent', agent = name }, hl)
  end

  state.line_map = map
  state.prompting_lines = prompting_lines

  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified = false

  api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, state.buf, NS, h.row, 0, { end_row = h.row + 1, hl_group = h.group, hl_eol = true })
  end
end

-- ---------------------------------------------------------------------
-- Spinner ticking (indicator column only)
-- ---------------------------------------------------------------------

---@param state table
local function sync_spinner(state)
  local visible = #vim.fn.win_findbuf(state.buf) > 0
  local any_prompting = visible and next(state.prompting_lines) ~= nil
  if any_prompting then
    spinner.register(state.buf, function(_frame)
      if not api.nvim_buf_is_valid(state.buf) then
        spinner.unregister(state.buf)
        return
      end
      vim.bo[state.buf].modifiable = true
      for lnum, row in pairs(state.prompting_lines) do
        if row.mem_sess and row.mem_sess.status == 'prompting' then
          pcall(api.nvim_buf_set_lines, state.buf, lnum - 1, lnum, false, { '  ' .. row_text(row) })
        end
      end
      vim.bo[state.buf].modifiable = false
      vim.bo[state.buf].modified = false
    end)
  else
    spinner.unregister(state.buf)
  end
end

-- ---------------------------------------------------------------------
-- Live refresh: subscribe on_status_change for every in-memory session shown
-- ---------------------------------------------------------------------

---@param state table
local function sessions_in_view(state)
  local out = {}
  for _, entry in pairs(state.line_map) do
    if entry.kind == 'row' and entry.row.mem_sess then
      out[entry.row.mem_sess] = true
    end
  end
  return out
end

---@param state table
local function render_only(state)
  render(state)
  sync_spinner(state)
end

---@param state table
local function sync_status_subs(state)
  local keep = sessions_in_view(state)
  for sess in pairs(keep) do
    if not state.status_subs[sess] then
      state.status_subs[sess] = sess:on_status_change(function()
        render_only(state)
      end)
    end
  end
  for sess, unsub in pairs(state.status_subs) do
    if not keep[sess] then
      pcall(unsub)
      state.status_subs[sess] = nil
    end
  end
end

-- ---------------------------------------------------------------------
-- Fetch cycle
-- ---------------------------------------------------------------------

---@param state table
local function refresh(state)
  local cfg = config.get { soft = true }
  local names = {}
  for name in pairs(cfg.agents) do
    names[#names + 1] = name
  end
  table.sort(names)

  local groups = {}
  for _, name in ipairs(names) do
    groups[name] = { supports_list = nil, rows = {}, loading = true }
  end
  state.groups = groups
  render_only(state)

  -- Re-render (cheap, idempotent) whenever any single agent's fetch settles;
  -- callers don't need to wait for every agent before seeing partial results.
  local function finalize()
    if state.groups ~= groups then
      return -- superseded by a newer refresh() call
    end
    render_only(state)
    sync_status_subs(state)
  end

  for _, name in ipairs(names) do
    local ag = agent_mod.get(name)
    ag:ensure_ready(function(err)
      if state.groups ~= groups then
        return
      end
      if err then
        groups[name].loading = false
        groups[name].error = err
        finalize()
        return
      end
      local supports_list = ag:supports 'list'
      groups[name].supports_list = supports_list
      if not supports_list then
        groups[name].rows = build_rows(name, nil, false)
        groups[name].loading = false
        finalize()
        return
      end
      session.list_remote(name, function(lerr, remote)
        if state.groups ~= groups then
          return
        end
        groups[name].rows = build_rows(name, (not lerr) and remote or {}, ag:supports 'loadSession')
        groups[name].loading = false
        finalize()
      end)
    end)
  end
end

-- ---------------------------------------------------------------------
-- Maps
-- ---------------------------------------------------------------------

---@param state table
---@return table? entry
local function entry_at_cursor(state)
  return state.line_map[api.nvim_win_get_cursor(0)[1]]
end

---@param state table
---@param split "current"|"split"|"vsplit"|"tab"
local function open_at_cursor(state, split)
  local e = entry_at_cursor(state)
  if not (e and e.kind == 'row') then
    return
  end
  local row = e.row
  if not row.resumable then
    vim.notify(('[mya] session %s is not resumable (%s does not support session/load)'):format(row.id, row.agent), vim.log.levels.WARN)
    return
  end
  require('mya.ui.buf').open(row.agent, row.id, 'log', { split = split })
end

---@param state table
local function toggle_preview_at_cursor(state)
  local e = entry_at_cursor(state)
  if not (e and e.kind == 'row') then
    return
  end
  if not e.row.mem_sess then
    vim.notify('[mya] no preview for a session that is not in memory (open it first)', vim.log.levels.INFO)
    return
  end
  local key = row_key(e.row)
  state.expanded[key] = not state.expanded[key] or nil
  render_only(state)
end

---@param state table
local function compose_at_cursor(state)
  local e = entry_at_cursor(state)
  if not (e and e.kind == 'row') then
    return
  end
  if not e.row.mem_sess then
    vim.notify('[mya] open the session first (<CR>), then compose', vim.log.levels.INFO)
    return
  end
  require('mya.ui.prompt').open_for_session(e.row.mem_sess)
end

--- Delete dispatch: `session/delete` when the agent advertises
--- `sessionCapabilities.delete`; otherwise the agent's configured
--- out-of-band CLI (`session_delete_command`, see mya/extern.lua); otherwise
--- a notice — a compliant client never sends an unadvertised method (the
--- agent would just answer -32601, e.g. opencode).
---@param state table
local function delete_at_cursor(state)
  local e = entry_at_cursor(state)
  if not (e and e.kind == 'row') then
    return
  end
  local row = e.row
  local extern = require 'mya.extern'
  local via_mya = agent_mod.get(row.agent):supports 'delete'
  if not via_mya and not extern.can_delete(row.agent) then
    vim.notify(
      ('[mya] %s does not support session/delete (no sessionCapabilities.delete; configure agents.%s.session_delete_command for a CLI fallback)'):format(
        row.agent,
        row.agent
      ),
      vim.log.levels.WARN
    )
    return
  end
  local choice = vim.fn.confirm(('Delete session %s?'):format(row.title or row.id), '&Yes\n&No', 2)
  if choice ~= 1 then
    return
  end
  local function cb(err)
    if err then
      vim.notify('[mya] session delete failed: ' .. tostring(err.message or vim.inspect(err)), vim.log.levels.ERROR)
      return
    end
    refresh(state)
  end
  if not via_mya then
    extern.delete_session(row.agent, row.id, cb)
  elseif row.mem_sess then
    row.mem_sess:delete(cb)
  else
    agent_mod.get(row.agent):request('session/delete', { sessionId = row.id }, cb)
  end
end

---@param state table
local function new_at_cursor(state)
  local e = entry_at_cursor(state)
  local agent_name
  if e and e.kind == 'agent' then
    agent_name = e.agent
  elseif e and e.kind == 'row' then
    agent_name = e.row.agent
  end

  local function start(name)
    session.new(name, {}, function(err, sess)
      if err then
        vim.notify('[mya] session/new failed: ' .. tostring(err.message or vim.inspect(err)), vim.log.levels.ERROR)
        return
      end
      require('mya.ui.buf').open(name, sess.id, 'log', { split = 'current' })
    end)
  end

  if agent_name then
    start(agent_name)
    return
  end
  local names = {}
  local cfg = config.get { soft = true }
  for name in pairs(cfg.agents) do
    names[#names + 1] = name
  end
  table.sort(names)
  if #names == 0 then
    vim.notify('[mya] no agents configured — see :help mya-setup', vim.log.levels.ERROR)
    return
  end
  vim.ui.select(names, { prompt = '[mya] new session with agent:' }, function(name)
    if name then
      start(name)
    end
  end)
end

---@param state table
local function setup_maps(state)
  local bufnr = state.buf
  local keys = require('mya.config').get({ soft = true }).keymaps.dashboard
  local function map(lhs, fn, desc)
    if not lhs then
      return
    end
    vim.keymap.set('n', lhs, fn, { buffer = bufnr, silent = true, desc = desc })
  end
  map(keys.open, function()
    open_at_cursor(state, 'current')
  end, '[mya] open session log (current window)')
  map(keys.open_split, function()
    open_at_cursor(state, 'split')
  end, '[mya] open session log (split)')
  map(keys.open_vsplit, function()
    open_at_cursor(state, 'vsplit')
  end, '[mya] open session log (vsplit)')
  map(keys.open_tab, function()
    open_at_cursor(state, 'tab')
  end, '[mya] open session log (tab)')
  map(keys.toggle_preview, function()
    toggle_preview_at_cursor(state)
  end, '[mya] toggle inline session preview')
  map(keys.compose, function()
    compose_at_cursor(state)
  end, '[mya] compose a prompt for the session under cursor')
  map(keys.new_session, function()
    new_at_cursor(state)
  end, '[mya] new session')
  map(keys.delete_session, function()
    delete_at_cursor(state)
  end, '[mya] delete session')
  map(keys.refresh, function()
    refresh(state)
  end, '[mya] refresh dashboard')
  map(keys.close, function()
    if #api.nvim_list_wins() > 1 then
      pcall(api.nvim_win_close, 0, false)
    end
  end, '[mya] close dashboard window')
  map(keys.help, function()
    require('mya.ui.help').open 'mya-dashboard-maps'
  end, '[mya] open :help mya-dashboard-maps')
end

-- ---------------------------------------------------------------------
-- Buffer lifecycle
-- ---------------------------------------------------------------------

---@return integer bufnr
local function ensure_buffer()
  if dash_buf and api.nvim_buf_is_valid(dash_buf) then
    return dash_buf
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, 'mya-dashboard')
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'mya-dashboard'

  dash_buf = buf
  dash_state = { buf = buf, groups = {}, line_map = {}, prompting_lines = {}, status_subs = {}, expanded = {} }
  setup_maps(dash_state)

  api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      for _, unsub in pairs(dash_state.status_subs) do
        pcall(unsub)
      end
      spinner.unregister(buf)
      dash_buf = nil
      dash_state = nil
    end,
  })

  return buf
end

--- Open (or focus) the dashboard, and (re)fetch its data.
---@return integer bufnr
function M.open()
  local buf = ensure_buffer()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == buf then
      api.nvim_set_current_win(win)
      refresh(dash_state)
      return buf
    end
  end
  api.nvim_set_current_buf(buf)
  refresh(dash_state)
  return buf
end

--- Test/introspection access to the dashboard's render state, if open.
---@return table?
function M._state()
  return dash_state
end

return M
