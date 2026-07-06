--- Session log renderer: a pure projection of the session event log into a
--- single folded buffer (concepts-v3 "one log buffer, two readings").
---
--- ## Design
---
--- `M.render_event(event)` is a pure function: one event -> content lines +
--- per-line fold levels + whole-line highlight groups + fold summary texts.
--- A per-buffer orchestrator keeps `blocks[]` (one entry per event index:
--- `{ start, n }`, 0-based start line, n includes the trailing blank
--- separator) so session deltas map to exact `nvim_buf_set_lines` ranges:
---   - append delta -> render, append at end, record block
---   - mutate delta -> re-render that event's block, replace its line range,
---     shift subsequent block offsets by the line-count delta
---   - reset        -> full redraw
---   - empty batch  -> header state changed; refresh the status bar only
--- Invariant (tests depend on it): blocks are contiguous and
--- sum(blocks[i].n) == nvim_buf_line_count() whenever the sum is > 0.
---
--- ## Folds
---
--- Fold levels are computed at render time and stored on the orchestrator
--- (and mirrored to `vim.b[buf].mya_fold_levels` / `mya_fold_text`);
--- 'foldexpr' is a cheap table lookup via `M.foldexpr`, `M.foldtext` shows a
--- stored per-fold summary. foldlevel=99 keeps everything open; zM is the
--- clean transcript.

local M = {}

local api = vim.api

local NS = api.nvim_create_namespace 'mya_log'

-- Highlight groups (default links; users can override).
local HL_LINKS = {
  MyaLogHeader = 'Title',
  MyaLogThought = 'Comment',
  MyaLogToolTitle = 'Function',
  MyaLogToolFailed = 'DiagnosticError',
  MyaLogMeta = 'NonText',
  MyaLogLocation = 'Directory',
}
for group, link in pairs(HL_LINKS) do
  api.nvim_set_hl(0, group, { link = link, default = true })
end

local STATUS_ICONS = { pending = '○', in_progress = '◐', completed = '●', failed = '✗' }
local KIND_ICONS = {
  read = '»',
  edit = '✎',
  delete = '✗',
  move = '⇢',
  search = '⌕',
  execute = '$',
  think = '∴',
  fetch = '↓',
  switch_mode = '⇄',
  other = '·',
}

--- Orchestrator state per buffer:
--- { buf, sess, blocks = { [event_index] = {start,n} }, total, fold_levels,
---   fold_text = { [lnum] = summary }, unsub }
local states = {}

-- ---------------------------------------------------------------------
-- Config access (soft: renderer works with defaults if setup() never ran)
-- ---------------------------------------------------------------------

local function ui_log_cfg()
  local ok, config = pcall(require, 'mya.config')
  local cfg = ok and config.get { soft = true } or {}
  local log_cfg = (cfg.ui and cfg.ui.log) or {}
  return {
    context_lines = log_cfg.context_lines or 3,
    icons = log_cfg.icons ~= false,
  }
end

-- ---------------------------------------------------------------------
-- Pure per-event rendering
-- ---------------------------------------------------------------------

--- Model/effort display from a turn-start config snapshot (option id ->
--- current value id). Same heuristics as mya.statusline.
---@param snap table?
---@return string?, string?
local function snapshot_parts(snap)
  if type(snap) ~= 'table' then
    return nil, nil
  end
  local model, effort
  for k, v in pairs(snap) do
    local key = tostring(k):lower()
    if key:find('model', 1, true) then
      model = model or tostring(v)
    elseif
      key:find('effort', 1, true)
      or key:find('thinking', 1, true)
      or key:find('reason', 1, true)
      or key == 'mode'
    then
      effort = effort or tostring(v)
    end
  end
  return model, effort
end

---@param old string?
---@param new string?
---@param ctx integer
---@return string[]
local function unified_diff(old, new, ctx)
  old = old or ''
  new = new or ''
  if old ~= '' and old:sub(-1) ~= '\n' then
    old = old .. '\n'
  end
  if new ~= '' and new:sub(-1) ~= '\n' then
    new = new .. '\n'
  end
  local ok, out = pcall(vim.diff, old, new, { result_type = 'unified', ctxlen = ctx })
  if not ok or type(out) ~= 'string' then
    return { '(diff unavailable)' }
  end
  local lines = vim.split(out, '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

---@class mya.ui.Rendered
---@field lines string[]
---@field folds integer[] per-line fold level (parallel to lines)
---@field hl { offset: integer, group: string }[] whole-line highlights (1-based offset)
---@field foldtext table<integer, string> fold summary keyed by 1-based line offset (the fold-START line)

--- Render one event into lines/folds/highlights. Pure; no buffer access.
---@param event table
---@return mya.ui.Rendered
function M.render_event(event)
  local cfg = ui_log_cfg()
  local lines, folds, hl, foldtext = {}, {}, {}, {}
  -- Newline-safe: several event fields (tool_call titles, info text, stop
  -- reasons, ...) come straight from the agent and can carry embedded "\n"
  -- (opencode sends multi-line tool titles, e.g. full bash commands).
  -- nvim_buf_set_lines rejects any replacement line containing "\n", so a
  -- string with embedded newlines is split into one line per piece here,
  -- each keeping the caller's fold level/highlight group. A trailing "\r"
  -- on a piece (CRLF input) is stripped too. Behavior for strings without
  -- "\n" is unchanged. Returns the number of lines the call added, so
  -- callers that need to know how many buffer lines a value consumed (e.g.
  -- the tool_call foldtext key) can find out.
  ---@return integer
  local function add(line, level, group)
    local pieces
    if type(line) == 'string' and line:find('\n', 1, true) then
      pieces = vim.split(line, '\n', { plain = true })
    else
      pieces = { line }
    end
    for _, piece in ipairs(pieces) do
      if type(piece) == 'string' and piece:sub(-1) == '\r' then
        piece = piece:sub(1, -2)
      end
      lines[#lines + 1] = piece
      folds[#folds + 1] = level or 0
      if group then
        hl[#hl + 1] = { offset = #lines, group = group }
      end
    end
    return #pieces
  end

  local kind = event.kind
  if kind == 'turn' then
    if event.phase == 'start' then
      local parts = { '## user' }
      local model, effort = snapshot_parts(event.config_snapshot)
      if model then
        parts[#parts + 1] = model
      end
      if effort then
        parts[#parts + 1] = effort
      end
      -- NOTE: session.lua does not timestamp turn events (only message
      -- events carry meta.timestamp), so the time part is omitted unless a
      -- timestamp ever appears here.
      local ts = event.timestamp or (event.meta and event.meta.timestamp)
      if ts then
        parts[#parts + 1] = os.date('%H:%M', ts)
      end
      add(table.concat(parts, ' · '), 0, 'MyaLogHeader')
    elseif event.phase == 'end' and event.stop_reason and event.stop_reason ~= 'end_turn' then
      add('· stopped: ' .. tostring(event.stop_reason), 0, 'MyaLogMeta')
    end
    -- turn end with end_turn renders nothing.
  elseif kind == 'message' then
    local text_lines = vim.split(event.content or '', '\n', { plain = true })
    if event.role == 'agent' then
      add('## agent', 0, 'MyaLogHeader')
      for _, l in ipairs(text_lines) do
        add(l, 0)
      end
    elseif event.role == 'thought' then
      add('### reasoning', 1, 'MyaLogThought')
      for _, l in ipairs(text_lines) do
        add(l, 1, 'MyaLogThought')
      end
      foldtext[1] = ('⏵ reasoning (%d lines)'):format(#text_lines)
    else -- user: plain text under the turn header
      for _, l in ipairs(text_lines) do
        add(l, 0)
      end
    end
  elseif kind == 'tool_call' then
    local status = event.status or 'pending'
    local title_text = event.title or event.id or 'tool'

    -- Sum added/deleted lines across the event's diff content items (a small
    -- local `vim.diff` count — deliberately NOT a require of client.lua, per
    -- the layer rule; client.file_counts does the same computation for the
    -- review buffer/quickfix).
    local diff_add, diff_del, has_diff = 0, 0, false
    for _, item in ipairs(type(event.content) == 'table' and event.content or {}) do
      if item.type == 'diff' then
        has_diff = true
        local old = item.oldText or ''
        local new = item.newText or ''
        if old ~= '' and old:sub(-1) ~= '\n' then
          old = old .. '\n'
        end
        if new ~= '' and new:sub(-1) ~= '\n' then
          new = new .. '\n'
        end
        local ok, hunks = pcall(vim.diff, old, new, { result_type = 'indices' })
        if ok and type(hunks) == 'table' then
          for _, h in ipairs(hunks) do
            diff_del = diff_del + h[2]
            diff_add = diff_add + h[4]
          end
        end
      end
    end
    local diff_suffix = has_diff and (' (+%d −%d)'):format(diff_add, diff_del) or ''

    local title
    if cfg.icons then
      title = ('%s %s %s (%s)%s'):format(
        STATUS_ICONS[status] or STATUS_ICONS.pending,
        KIND_ICONS[event.tool_kind] or KIND_ICONS.other,
        title_text,
        status,
        diff_suffix
      )
    else
      title = ('%s (%s)%s'):format(title_text, status, diff_suffix)
    end
    local title_line_count = add(title, 0, status == 'failed' and 'MyaLogToolFailed' or 'MyaLogToolTitle')

    for _, loc in ipairs(type(event.locations) == 'table' and event.locations or {}) do
      local l = '  ↳ ' .. (loc.path or '')
      if loc.line then
        l = l .. ':' .. tostring(loc.line)
      end
      add(l, 1, 'MyaLogLocation')
    end

    for _, item in ipairs(type(event.content) == 'table' and event.content or {}) do
      if item.type == 'content' and type(item.content) == 'table' and item.content.type == 'text' then
        for _, l in ipairs(vim.split(item.content.text or '', '\n', { plain = true })) do
          add('  ' .. l, 1)
        end
      elseif item.type == 'content' and type(item.content) == 'table' then
        add(('  [%s]'):format(tostring(item.content.type or 'content')), 1)
      elseif item.type == 'diff' then
        if item.path then
          add('  ↳ ' .. item.path, 1, 'MyaLogLocation')
        end
        add('```diff', 1)
        for _, l in ipairs(unified_diff(item.oldText, item.newText, cfg.context_lines)) do
          add(l, 1)
        end
        add('```', 1)
      elseif item.type == 'terminal' then
        add(('  [terminal %s]'):format(tostring(item.terminalId)), 1)
      else
        add(('  [%s]'):format(tostring(item.type)), 1)
      end
    end

    -- The fold starts on the first body line (the title stays visible in
    -- the zM transcript), so the summary is keyed there. A multi-line title
    -- (e.g. a multi-line bash command) pushes that key past line 2 by
    -- however many extra lines the title itself consumed. foldtext is
    -- displayed as a single buffer line, so newlines in the title are
    -- collapsed to spaces for the summary text.
    if #lines > title_line_count then
      foldtext[title_line_count + 1] =
        ('⏵ tool: %s (%s)%s'):format((title_text:gsub('[\r\n]+', ' ')), status, diff_suffix)
    end
  elseif kind == 'plan' then
    local total, done = 0, 0
    for _, e in ipairs(type(event.entries) == 'table' and event.entries or {}) do
      total = total + 1
      if e.status == 'completed' then
        done = done + 1
      end
    end
    add(('⚑ plan updated (%d/%d done)'):format(done, total), 0, 'MyaLogMeta')
  elseif kind == 'info' then
    add(('— %s —'):format(tostring(event.text or '')), 0, 'MyaLogMeta')
  else
    add(('— unknown event kind: %s —'):format(tostring(kind)), 0, 'MyaLogMeta')
  end

  return { lines = lines, folds = folds, hl = hl, foldtext = foldtext }
end

--- render_event + the blank separator line every non-empty block ends with.
---@param event table
---@return mya.ui.Rendered
local function rendered_with_sep(event)
  local r = M.render_event(event)
  if #r.lines > 0 then
    r.lines[#r.lines + 1] = ''
    r.folds[#r.folds + 1] = 0
  end
  return r
end

--- Total rendered line count for a session's log view (dashboard row
--- "N lines" column): the attached orchestrator's running total if a log
--- buffer for this session is attached (cheap field read), else a pure sum
--- over `render_event` (+1 separator per non-empty block — the same
--- accounting `rendered_with_sep` gives a live buffer).
---@param sess mya.Session
---@return integer
function M.line_count(sess)
  for _, st in pairs(states) do
    if st.sess == sess then
      return st.total
    end
  end
  local total = 0
  for _, ev in ipairs(sess.events) do
    total = total + #rendered_with_sep(ev).lines
  end
  return total
end

-- ---------------------------------------------------------------------
-- Working indicator: a virt_lines "spinner" at the bottom of the buffer
-- while the session is prompting/waiting_permission (concepts-v3: "vim.notify
-- when a turn finishes or a permission is waiting" — this is the live,
-- in-buffer counterpart). Shares the frame ticker with the dashboard via
-- ui/spinner.lua.
-- ---------------------------------------------------------------------

local spinner = require 'mya.ui.spinner'

---@param st table
---@param text string?
local function set_working_indicator(st, text)
  if not api.nvim_buf_is_valid(st.buf) then
    return
  end
  if not text then
    if st.spinner_mark_id then
      pcall(api.nvim_buf_del_extmark, st.buf, NS, st.spinner_mark_id)
      st.spinner_mark_id = nil
    end
    return
  end
  local last_row = math.max(api.nvim_buf_line_count(st.buf) - 1, 0)
  local ok, id = pcall(api.nvim_buf_set_extmark, st.buf, NS, last_row, 0, {
    id = st.spinner_mark_id,
    virt_lines = { { { text, 'MyaLogMeta' } } },
  })
  if ok then
    st.spinner_mark_id = id
  end
end

--- Sync the working-indicator extmark + spinner-ticker registration with the
--- session's current status. Called on attach, on every status change, and
--- after every delta batch (content growth moves the "last line").
---@param st table
local function refresh_working_indicator(st)
  if not api.nvim_buf_is_valid(st.buf) then
    return
  end
  local status = st.sess.status
  if status == 'prompting' then
    spinner.register(st.buf, function(frame)
      set_working_indicator(st, frame .. ' working…')
    end)
    set_working_indicator(st, spinner.current_frame() .. ' working…')
  elseif status == 'waiting_permission' then
    spinner.unregister(st.buf)
    set_working_indicator(st, '! waiting for permission…')
  else
    spinner.unregister(st.buf)
    set_working_indicator(st, nil)
  end
end

-- ---------------------------------------------------------------------
-- Buffer orchestration
-- ---------------------------------------------------------------------

local function set_lines(st, start, end_, lines)
  vim.bo[st.buf].modifiable = true
  api.nvim_buf_set_lines(st.buf, start, end_, false, lines)
  vim.bo[st.buf].modifiable = false
  vim.bo[st.buf].modified = false
end

---@param st table
---@param start integer 0-based start line of the block
---@param r mya.ui.Rendered
local function apply_extmarks(st, start, r)
  for _, h in ipairs(r.hl) do
    local row = start + h.offset - 1
    pcall(api.nvim_buf_set_extmark, st.buf, NS, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = h.group,
    })
  end
end

local function append_block(st, index, event)
  local r = rendered_with_sep(event)
  local block = { start = st.total, n = #r.lines }
  st.blocks[index] = block
  if #r.lines == 0 then
    return
  end
  if st.total == 0 then
    set_lines(st, 0, -1, r.lines) -- replace the single implicit empty line
  else
    set_lines(st, st.total, st.total, r.lines)
  end
  for i, lv in ipairs(r.folds) do
    st.fold_levels[block.start + i] = lv
  end
  for off, txt in pairs(r.foldtext) do
    st.fold_text[block.start + off] = txt
  end
  apply_extmarks(st, block.start, r)
  st.total = st.total + block.n
end

local function full_render(st)
  st.blocks = {}
  local all, levels, ftext = {}, {}, {}
  local hls = {}
  local total = 0
  for idx, ev in ipairs(st.sess.events) do
    local r = rendered_with_sep(ev)
    st.blocks[idx] = { start = total, n = #r.lines }
    for i, l in ipairs(r.lines) do
      all[total + i] = l
      levels[total + i] = r.folds[i]
    end
    for off, txt in pairs(r.foldtext) do
      ftext[total + off] = txt
    end
    for _, h in ipairs(r.hl) do
      hls[#hls + 1] = { row = total + h.offset - 1, group = h.group }
    end
    total = total + #r.lines
  end
  st.total = total
  st.fold_levels = levels
  st.fold_text = ftext
  api.nvim_buf_clear_namespace(st.buf, NS, 0, -1)
  set_lines(st, 0, -1, total > 0 and all or { '' })
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, st.buf, NS, h.row, 0, {
      end_row = h.row + 1,
      end_col = 0,
      hl_group = h.group,
    })
  end
end

local function mutate_block(st, index, event)
  local block = st.blocks[index]
  if not block then
    -- Mutate for an event we never rendered (shouldn't happen: attach does a
    -- full render first). Fall back to a full redraw.
    full_render(st)
    return
  end
  local r = rendered_with_sep(event)
  local old_n, new_n = block.n, #r.lines
  local delta = new_n - old_n

  if st.total == 0 and new_n > 0 then
    set_lines(st, 0, -1, r.lines)
  else
    set_lines(st, block.start, block.start + old_n, r.lines)
  end

  -- Splice fold levels (array of length total).
  local nl = {}
  for i = 1, block.start do
    nl[i] = st.fold_levels[i]
  end
  for i = 1, new_n do
    nl[block.start + i] = r.folds[i]
  end
  for i = block.start + old_n + 1, st.total do
    nl[i + delta] = st.fold_levels[i]
  end
  st.fold_levels = nl

  -- Splice fold summary texts (sparse lnum-keyed map).
  local nt = {}
  for lnum, txt in pairs(st.fold_text) do
    if lnum <= block.start then
      nt[lnum] = txt
    elseif lnum > block.start + old_n then
      nt[lnum + delta] = txt
    end
  end
  for off, txt in pairs(r.foldtext) do
    nt[block.start + off] = txt
  end
  st.fold_text = nt

  -- Re-apply highlights for the re-rendered range.
  api.nvim_buf_clear_namespace(st.buf, NS, block.start, block.start + new_n)
  apply_extmarks(st, block.start, r)

  -- Shift subsequent blocks by the line-count delta.
  if delta ~= 0 then
    for _, b in pairs(st.blocks) do
      if b ~= block and b.start >= block.start + old_n then
        b.start = b.start + delta
      end
    end
  end
  block.n = new_n
  st.total = st.total + delta
end

--- Mirror fold state into buffer variables (introspection + foldexpr
--- survival across module reloads is NOT a goal; the module table is the
--- authoritative cheap lookup).
local function sync_buf_vars(st)
  vim.b[st.buf].mya_fold_levels = st.fold_levels
  local ft = {}
  for lnum, txt in pairs(st.fold_text) do
    ft[tostring(lnum)] = txt
  end
  vim.b[st.buf].mya_fold_text = ft
end

local function on_deltas(st, deltas)
  if not api.nvim_buf_is_valid(st.buf) then
    M.detach(st.buf)
    return
  end

  -- Autoscroll (fugitive-log behavior): windows whose cursor sat on the last
  -- line before this batch follow appends to the new last line.
  local old_count = api.nvim_buf_line_count(st.buf)
  local bottom_wins = {}
  for _, win in ipairs(vim.fn.win_findbuf(st.buf)) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_cursor(win)[1] == old_count then
      bottom_wins[#bottom_wins + 1] = win
    end
  end

  for _, d in ipairs(deltas) do
    if d.type == 'append' then
      append_block(st, d.index, d.event)
    elseif d.type == 'mutate' then
      mutate_block(st, d.index, d.event)
    elseif d.type == 'reset' then
      full_render(st)
    end
  end

  if #deltas > 0 then
    sync_buf_vars(st)
    local new_count = api.nvim_buf_line_count(st.buf)
    if new_count ~= old_count then
      for _, win in ipairs(bottom_wins) do
        if api.nvim_win_is_valid(win) then
          pcall(api.nvim_win_set_cursor, win, { new_count, 0 })
        end
      end
    end
  end

  -- Empty batch = header-state change; either way the bar component may be
  -- stale, so redraw statusline/winbar lines.
  pcall(vim.cmd, 'redrawstatus')
  refresh_working_indicator(st)
end

-- ---------------------------------------------------------------------
-- foldexpr / foldtext (cheap lookups into orchestrator state)
-- ---------------------------------------------------------------------

--- 'foldexpr' callback: v:lua.require'mya.ui.log'.foldexpr(v:lnum)
---@param lnum integer
---@return integer
function M.foldexpr(lnum)
  local st = states[api.nvim_get_current_buf()]
  if not st then
    return 0
  end
  return st.fold_levels[lnum] or 0
end

--- 'foldtext' callback showing the stored per-fold summary.
---@return string
function M.foldtext()
  local st = states[api.nvim_get_current_buf()]
  local fs, fe = vim.v.foldstart, vim.v.foldend
  local txt = st and st.fold_text[fs]
  return txt or ('⏵ %d lines'):format(fe - fs + 1)
end

local FOLD_WIN_OPTS = {
  foldmethod = 'expr',
  foldexpr = "v:lua.require'mya.ui.log'.foldexpr(v:lnum)",
  foldtext = "v:lua.require'mya.ui.log'.foldtext()",
  foldlevel = 99,
}

local function apply_win_opts(win)
  for opt, val in pairs(FOLD_WIN_OPTS) do
    pcall(api.nvim_set_option_value, opt, val, { win = win })
  end
end

local function setup_windows(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    apply_win_opts(win)
  end
  api.nvim_create_autocmd('BufWinEnter', {
    group = api.nvim_create_augroup('mya_log_win_' .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function()
      apply_win_opts(api.nvim_get_current_win())
    end,
    desc = '[mya] window-local fold options for the session log',
  })
end

-- ---------------------------------------------------------------------
-- Terminal content viewer (Phase 8): `<CR>` on a rendered `[terminal <id>]`
-- line opens a small read-only scratch buffer showing that terminal's
-- current output, auto-refreshing via `mya.terminal`'s push-based
-- `on_output` subscription (no polling/ticker needed — the protocol layer
-- already schedules a callback on every output chunk and on exit).
-- ---------------------------------------------------------------------

---@type table<integer, table> viewer bufnr -> { agent, session_id, terminal_id, unsub }
local term_view_states = {}

---@param buf integer
---@param agent_name string
---@param session_id string
---@param terminal_id string
local function render_terminal_view(buf, agent_name, session_id, terminal_id)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local term = require('mya.terminal').get(agent_name, session_id, terminal_id)
  local lines
  if not term then
    lines = { ('(terminal %s: no longer known — released or never seen by this instance)'):format(terminal_id) }
  else
    lines = vim.split(term.output, '\n', { plain = true })
    if term.truncated then
      table.insert(lines, 1, ('— output truncated —'))
    end
    if term.exit_status then
      lines[#lines + 1] = ''
      lines[#lines + 1] = ('[exited: code=%s signal=%s]'):format(tostring(term.exit_status.exitCode), tostring(term.exit_status.signal))
    else
      lines[#lines + 1] = ''
      lines[#lines + 1] = '[running…]'
    end
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---@param sess mya.Session
---@param terminal_id string
local function open_terminal_view(sess, terminal_id)
  local name = ('mya-terminal://%s'):format(terminal_id)
  local buf
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(b) == name then
      buf = b
      break
    end
  end
  local fresh = not (buf and api.nvim_buf_is_valid(buf))
  if fresh then
    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'mya-terminal'
  end

  render_terminal_view(buf, sess.agent_name, sess.id, terminal_id)

  local win
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == buf then
      win = w
      break
    end
  end
  if win then
    api.nvim_set_current_win(win)
  else
    vim.cmd 'belowright split'
    win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, buf)
    pcall(api.nvim_win_set_height, win, 10)
  end

  if fresh then
    local st = { agent = sess.agent_name, session_id = sess.id, terminal_id = terminal_id }
    term_view_states[buf] = st
    st.unsub = require('mya.terminal').on_output(sess.agent_name, sess.id, terminal_id, function()
      render_terminal_view(buf, sess.agent_name, sess.id, terminal_id)
    end)
    local close_output = require('mya.config').get({ soft = true }).keymaps.log.close_output
    if close_output then
      vim.keymap.set('n', close_output, function()
        if #api.nvim_list_wins() > 1 then
          pcall(api.nvim_win_close, 0, true)
        end
      end, { buffer = buf, nowait = true, desc = '[mya] close terminal output view' })
    end
    api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function()
        if st.unsub then
          pcall(st.unsub)
        end
        term_view_states[buf] = nil
      end,
    })
  end
end

-- ---------------------------------------------------------------------
-- Maps
-- ---------------------------------------------------------------------

---@param path string
---@param line integer?
local function jump_to_location(path, line)
  local cur = api.nvim_get_current_win()
  local prevnr = vim.fn.winnr '#'
  local prev = prevnr > 0 and vim.fn.win_getid(prevnr) or 0
  if prev ~= 0 and prev ~= cur and api.nvim_win_is_valid(prev) then
    api.nvim_set_current_win(prev)
  else
    vim.cmd 'aboveleft split'
  end
  vim.cmd "normal! m'" -- jumplist entry at the previous position
  vim.cmd.edit(vim.fn.fnameescape(path))
  if line then
    pcall(api.nvim_win_set_cursor, 0, { line, 0 })
  end
end

local function on_cr(bufnr, sess)
  local st = states[bufnr]
  if not st then
    return
  end
  local lnum = api.nvim_win_get_cursor(0)[1]
  local idx
  for i, b in ipairs(st.blocks) do
    if b.n > 0 and lnum > b.start and lnum <= b.start + b.n then
      idx = i
      break
    end
  end
  local ev = idx and sess.events[idx]
  if not ev or ev.kind ~= 'tool_call' then
    return
  end

  local cur_line = api.nvim_get_current_line()
  local term_id = cur_line:match '%[terminal%s+(%S-)%]%s*$'
  if term_id then
    open_terminal_view(sess, term_id)
    return
  end

  local path, line
  local target = cur_line:match '↳%s+(.-)%s*$'
  if target and target ~= '' then
    local p, l = target:match '^(.-):(%d+)$'
    if p then
      path, line = p, tonumber(l)
    else
      path = target
    end
  elseif type(ev.locations) == 'table' and ev.locations[1] then
    path = ev.locations[1].path
    line = ev.locations[1].line
  end
  if not path or path == '' then
    return
  end
  if not path:match '^/' then
    path = (sess.cwd or '.') .. '/' .. path
  end
  jump_to_location(path, line)
end

local function setup_maps(bufnr, sess)
  local keys = require('mya.config').get({ soft = true }).keymaps.log
  local function map(lhs, fn, desc)
    if not lhs then
      return
    end
    vim.keymap.set('n', lhs, fn, { buffer = bufnr, silent = true, desc = desc })
  end
  map(keys.jump, function()
    on_cr(bufnr, sess)
  end, '[mya] jump to tool-call location')
  map(keys.next_turn, function()
    vim.fn.search([[\v^## (user|agent)]], 'W')
  end, '[mya] next turn header')
  map(keys.prev_turn, function()
    vim.fn.search([[\v^## (user|agent)]], 'bW')
  end, '[mya] previous turn header')
  map(keys.compose, function()
    require('mya.ui.prompt').open_for(bufnr)
  end, '[mya] compose a prompt for this session')
  map(keys.config, function()
    require('mya.ui.prompt').config_picker(sess)
  end, '[mya] change model/mode/variant')
  map(keys.review, function()
    require('mya.ui.review').open(sess)
  end, '[mya] open the review buffer for this session')
  map(keys.open_plan, function()
    require('mya.ui.plan').open(sess)
  end, '[mya] open the plan buffer for this session')
  map(keys.cancel, function()
    sess:cancel()
  end, '[mya] cancel the in-flight turn')
  map(keys.help, function()
    require('mya.ui.help').open 'mya-log-maps'
  end, '[mya] open :help mya-log-maps')
  -- Bare-enough paths + session cwd on 'path' make default gf work.
  if sess.cwd and sess.cwd ~= '' then
    pcall(function()
      vim.opt_local.path:append(sess.cwd)
    end)
  end
end

-- ---------------------------------------------------------------------
-- Attach / detach
-- ---------------------------------------------------------------------

--- Attach the log renderer to a buffer for a session. Idempotent: calling
--- again for the same buffer+session re-renders without adding a second
--- subscription (BufReadCmd re-fires on :edit).
---@param bufnr integer
---@param sess mya.Session
function M.attach(bufnr, sess)
  local st = states[bufnr]
  if st and st.sess == sess then
    full_render(st)
    sync_buf_vars(st)
    setup_windows(bufnr)
    refresh_working_indicator(st)
    return
  end
  if st then
    M.detach(bufnr)
  end

  st = {
    buf = bufnr,
    sess = sess,
    blocks = {},
    total = 0,
    fold_levels = {},
    fold_text = {},
    spinner_mark_id = nil,
  }
  states[bufnr] = st

  full_render(st)
  sync_buf_vars(st)
  st.unsub = sess:subscribe(function(deltas)
    on_deltas(st, deltas)
  end)
  st.status_unsub = sess:on_status_change(function()
    refresh_working_indicator(st)
  end)
  setup_windows(bufnr)
  setup_maps(bufnr, sess)
  refresh_working_indicator(st)

  -- Markdown treesitter highlighting on top of the myalog filetype; degrade
  -- silently when the parser is unavailable.
  pcall(vim.treesitter.start, bufnr, 'markdown')
end

---@param bufnr integer
function M.detach(bufnr)
  local st = states[bufnr]
  if not st then
    return
  end
  states[bufnr] = nil
  if st.unsub then
    pcall(st.unsub)
  end
  if st.status_unsub then
    pcall(st.status_unsub)
  end
  spinner.unregister(bufnr)
  pcall(api.nvim_del_augroup_by_name, 'mya_log_win_' .. bufnr)
end

--- Test/introspection access to the orchestrator state of a buffer.
---@param bufnr integer
---@return table?
function M._state(bufnr)
  return states[bufnr]
end

return M
