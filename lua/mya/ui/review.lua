--- Fugitive-status-style review buffer (Phase 6).
---
--- One scratch buffer per session (named `mya-review://<agent>/<session>`;
--- a plain scratch, deliberately NOT the mya:// BufReadCmd scheme). Lists
--- pending review units newest-first, then already-applied edits from
--- session history (read-only — see client.history_units):
---
---   ⏺ <tool title> (<n files>)
---     M path (+a −d)
---       @@ -a,b +c,d          <- '=' toggles this inline hunk expansion
---       +added line
---       -removed line
---
---   applied (read-only):
---   ✓ <tool title> (<n files>)
---     M path (+a −d)
---
--- Maps: '=' toggle hunks, 'dv' diffsplit proposed-vs-current, 'a' accept
--- unit, 'r' reject unit, 'cc' compose a prompt for the session (Phase 5,
--- ui/prompt.lua), 'g?' help, 'q' close. Cursor-line -> unit/file/hunk
--- resolution goes through a line-map table rebuilt on every render.
---
--- Line-map entry shapes (index = 1-based buffer line):
---   { unit = u }                          -- section header
---   { unit = u, file = f }                -- file line
---   { unit = u, file = f, hunk = k }      -- hunk header / hunk body line

local client = require 'mya.client'
local config = require 'mya.config'

local M = {}

local api = vim.api

local ns = api.nvim_create_namespace 'mya_review'

-- Per-session UI state: key -> { buf, line_map, expanded = {'<unitid>\0<path>'=true}, unsub }
---@type table<string, table>
local ui_state = {}

---@param sess mya.Session
---@return string
local function skey(sess)
  return sess.agent_name .. '/' .. sess.id
end

do
  -- default=true so user/colorscheme overrides win.
  api.nvim_set_hl(0, 'MyaReviewTitle', { link = 'Title', default = true })
  api.nvim_set_hl(0, 'MyaReviewFile', { link = 'Directory', default = true })
  api.nvim_set_hl(0, 'MyaReviewAdd', { link = 'DiffAdd', default = true })
  api.nvim_set_hl(0, 'MyaReviewDelete', { link = 'DiffDelete', default = true })
  api.nvim_set_hl(0, 'MyaReviewHunk', { link = 'DiffText', default = true })
  api.nvim_set_hl(0, 'MyaReviewApplied', { link = 'Comment', default = true })
end

---@param sess mya.Session
---@param path string
---@return string display path (cwd-relative when inside the session cwd)
local function display_path(sess, path)
  local cwd = sess.cwd
  if cwd and cwd ~= '' then
    local prefix = cwd:sub(-1) == '/' and cwd or (cwd .. '/')
    if path:sub(1, #prefix) == prefix then
      return path:sub(#prefix + 1)
    end
  end
  return path
end

--- Unified hunks for a file change: `{ { header = '@@ ... @@', a=..,b=..,c=..,d=..,
--- lines = {'+x','-y',' z',...} }, ... }`.
---@param file table
---@return table[]
local function unified_hunks(file)
  local cfg = config.get()
  local ctx = (cfg.review and cfg.review.context_lines) or 3
  local old = client.lines_to_text(client.text_to_lines(file.old_text))
  local new = client.lines_to_text(client.text_to_lines(file.new_text))
  local unified = vim.diff(old, new, { result_type = 'unified', ctxlen = ctx }) --[[@as string]]
  local hunks = {}
  local cur
  for _, line in ipairs(vim.split(unified or '', '\n', { plain = true })) do
    local a, b, c, d = line:match '^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@'
    if a then
      cur = {
        header = line,
        a = tonumber(a),
        b = b ~= '' and tonumber(b) or 1,
        c = tonumber(c),
        d = d ~= '' and tonumber(d) or 1,
        lines = {},
      }
      hunks[#hunks + 1] = cur
    elseif cur and line ~= '' then
      cur.lines[#cur.lines + 1] = line
    end
  end
  return hunks
end

---@param st table ui state
---@param sess mya.Session
local function render(st, sess)
  local units = client.units(sess)
  local lines, map, hls = {}, {}, {}

  local function push(text, entry, hl)
    lines[#lines + 1] = text
    map[#map + 1] = entry
    if hl then
      hls[#hls + 1] = { line = #lines - 1, group = hl }
    end
  end

  --- One unit block: title line, file lines, expanded hunks, trailing blank.
  local function push_unit(unit, marker)
    push(('%s %s (%d file%s)'):format(marker, unit.title or 'tool call', #unit.files, #unit.files == 1 and '' or 's'), { unit = unit }, 'MyaReviewTitle')
    for _, file in ipairs(unit.files) do
      local add, del = client.file_counts(file)
      push(('M %s (+%d −%d)'):format(display_path(sess, file.path), add, del), { unit = unit, file = file }, 'MyaReviewFile')
      if st.expanded[unit.id .. '\0' .. file.path] then
        for k, hunk in ipairs(unified_hunks(file)) do
          push('  ' .. hunk.header, { unit = unit, file = file, hunk = k }, 'MyaReviewHunk')
          for _, hline in ipairs(hunk.lines) do
            local hl = hline:sub(1, 1) == '+' and 'MyaReviewAdd' or (hline:sub(1, 1) == '-' and 'MyaReviewDelete' or nil)
            push('  ' .. hline, { unit = unit, file = file, hunk = k }, hl)
          end
        end
      end
    end
    push('', {})
  end

  if #units == 0 then
    push('no pending review units', {})
  else
    for i = #units, 1, -1 do -- newest-first
      push_unit(units[i], '⏺')
    end
  end

  -- Applied edits (read-only): completed tool calls that carried diffs but
  -- hold nothing to answer — accepted units, and agents that apply edits
  -- themselves without ever requesting permission (e.g. opencode with edit
  -- permissions allowed). '='/'dv' work; 'a'/'r' refuse.
  local history = client.history_units(sess)
  if #history > 0 then
    if #units == 0 then
      push('', {})
    end
    push('applied (read-only):', {}, 'MyaReviewApplied')
    for i = #history, 1, -1 do -- newest-first
      push_unit(history[i], '✓')
    end
  end

  st.line_map = map
  vim.bo[st.buf].modifiable = true
  api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    api.nvim_buf_set_extmark(st.buf, ns, h.line, 0, { end_row = h.line + 1, hl_group = h.group, hl_eol = true })
  end
end

---@param st table
---@return table? entry line-map entry under the cursor
local function entry_at_cursor(st)
  local lnum = api.nvim_win_get_cursor(0)[1]
  return st.line_map[lnum]
end

--- '=': toggle inline hunk expansion for the file under the cursor.
---@param st table
---@param sess mya.Session
local function toggle_expand(st, sess)
  local e = entry_at_cursor(st)
  if not (e and e.unit and e.file) then
    return
  end
  local key = e.unit.id .. '\0' .. e.file.path
  st.expanded[key] = not st.expanded[key] or nil
  render(st, sess)
end

--- 'dv': :diffsplit-style pair — current content in one window, proposed
--- new_text in a vsplit, both `:diffthis`; 'q' in either closes the pair.
---@param st table
---@param sess mya.Session
local function diffsplit(st, sess)
  local e = entry_at_cursor(st)
  if not (e and e.unit and e.file) then
    return
  end
  local file = e.file
  local ft = vim.filetype.match { filename = file.path } or ''

  local function scratch(text_lines, name)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, text_lines)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    if ft ~= '' then
      vim.bo[buf].filetype = ft
    end
    pcall(api.nvim_buf_set_name, buf, name)
    return buf
  end

  -- Old side: current buffer/disk content (what the change applies onto).
  local cur_buf = client.find_loaded_buf(file.path)
  local old_lines
  if cur_buf then
    old_lines = api.nvim_buf_get_lines(cur_buf, 0, -1, false)
  else
    old_lines = client.text_to_lines(file.old_text)
    local f = io.open(file.path, 'r')
    if f then
      old_lines = client.text_to_lines(f:read '*a')
      f:close()
    end
  end

  local old_scratch = scratch(old_lines, 'mya-diff-old://' .. file.path)
  local new_scratch = scratch(client.text_to_lines(file.new_text), 'mya-diff-new://' .. file.path)

  vim.cmd 'split'
  local w1 = api.nvim_get_current_win()
  api.nvim_win_set_buf(w1, old_scratch)
  vim.cmd 'diffthis'
  vim.cmd 'vsplit'
  local w2 = api.nvim_get_current_win()
  api.nvim_win_set_buf(w2, new_scratch)
  vim.cmd 'diffthis'

  local function close_pair()
    for _, w in ipairs { w1, w2 } do
      if api.nvim_win_is_valid(w) then
        pcall(api.nvim_win_close, w, true)
      end
    end
  end
  local close_key = require('mya.config').get({ soft = true }).keymaps.review.close
  if close_key then
    for _, buf in ipairs { old_scratch, new_scratch } do
      vim.keymap.set('n', close_key, close_pair, { buffer = buf, nowait = true, desc = '[mya] close diff pair' })
    end
  end
end

---@param st table
---@param sess mya.Session
local function setup_maps(st, sess)
  local keys = require('mya.config').get({ soft = true }).keymaps.review
  local function map(lhs, fn, desc)
    if not lhs then
      return
    end
    vim.keymap.set('n', lhs, fn, { buffer = st.buf, nowait = true, desc = '[mya] ' .. desc })
  end
  map(keys.toggle_hunks, function()
    toggle_expand(st, sess)
  end, 'toggle hunks')
  map(keys.diffsplit, function()
    diffsplit(st, sess)
  end, 'diffsplit')
  map(keys.accept, function()
    local e = entry_at_cursor(st)
    if e and e.unit and e.unit.applied then
      vim.notify('[mya] already applied (history) — nothing to accept', vim.log.levels.INFO)
      return
    end
    local ok, err = client.accept(e and e.unit or sess)
    if not ok and err then
      vim.notify(err, vim.log.levels.WARN)
    end
  end, 'accept unit')
  map(keys.reject, function()
    local e = entry_at_cursor(st)
    if e and e.unit and e.unit.applied then
      vim.notify('[mya] already applied (history) — nothing to reject', vim.log.levels.INFO)
      return
    end
    local ok, err = client.reject(e and e.unit or sess)
    if not ok and err then
      vim.notify(err, vim.log.levels.WARN)
    end
  end, 'reject unit')
  map(keys.compose, function()
    require('mya.ui.prompt').open_for_session(sess)
  end, 'compose a prompt for this session')
  map(keys.help, function()
    require('mya.ui.help').open 'mya-review-maps'
  end, 'open :help mya-review-maps')
  map(keys.close, function()
    M.close(sess)
  end, 'close review')
end

---@param sess mya.Session
---@return table st
local function ensure_ui(sess)
  local key = skey(sess)
  local st = ui_state[key]
  if st and api.nvim_buf_is_valid(st.buf) then
    return st
  end
  if st and st.unsub then
    pcall(st.unsub)
  end

  local buf = api.nvim_create_buf(false, true) -- unlisted scratch; NOT mya:// (no BufReadCmd coupling)
  api.nvim_buf_set_name(buf, ('mya-review://%s/%s'):format(sess.agent_name, sess.id))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'mya-review'

  st = { buf = buf, line_map = {}, expanded = {}, unsub = nil }
  ui_state[key] = st
  setup_maps(st, sess)

  -- Re-render on any session change (unit changes arrive as dirty flushes).
  st.unsub = sess:subscribe(function(_deltas, s)
    if not api.nvim_buf_is_valid(st.buf) then
      if st.unsub then
        pcall(st.unsub)
        st.unsub = nil
      end
      return
    end
    render(st, s)
  end)

  return st
end

--- Open (or focus) the review buffer for a session. Returns bufnr, winid.
---@param sess mya.Session
---@return integer buf
---@return integer win
function M.open(sess)
  local st = ensure_ui(sess)
  render(st, sess)

  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == st.buf then
      api.nvim_set_current_win(win)
      return st.buf, win
    end
  end
  vim.cmd 'botright split'
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, st.buf)
  local height = math.min(math.max(api.nvim_buf_line_count(st.buf) + 2, 5), 15)
  pcall(api.nvim_win_set_height, win, height)
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  return st.buf, win
end

--- Close any window showing the session's review buffer (buffer is kept).
---@param sess mya.Session
function M.close(sess)
  local st = ui_state[skey(sess)]
  if not st or not api.nvim_buf_is_valid(st.buf) then
    return
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == st.buf then
      -- Never close the last window.
      if #api.nvim_list_wins() > 1 then
        pcall(api.nvim_win_close, win, true)
      end
    end
  end
end

--- Test/introspection: the UI state (buf, line_map) for a session, if any.
---@param sess mya.Session
---@return table?
function M._state(sess)
  return ui_state[skey(sess)]
end

return M
