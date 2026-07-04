--- Dashboard tests: status sections, fugitive open vocabulary, previews,
--- delete dispatch.
--- Run with: nvim -l tests/phase4_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local api = vim.api
local config = require 'mya.config'
local session = require 'mya.session'
local dashboard = require 'mya.ui.dashboard'

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

---@param scenario string
---@return string[]
local function fake_args(scenario)
  return { '-l', fake_agent_path, scenario }
end

-- Marker file the extern (CLI-fallback) delete command writes the session id
-- to; proves the configured command really ran with the substituted id.
local extern_marker = vim.fn.tempname()

config.setup {
  agents = {
    -- session_basic advertises sessionCapabilities.list=true and its
    -- session/new always returns id 'sess-1'; session/list (the generic
    -- fake_agent handler) returns two remote-only 'loaded-N' rows regardless
    -- of scenario, which is exactly the "merge in-memory + remote, dedupe"
    -- case we want to exercise.
    list_ag = { command = 'nvim', args = fake_args 'session_basic' },
    -- no_list advertises NO sessionCapabilities at all (no list, and no
    -- delete either: D must gate with a notice instead of sending).
    nolist_ag = { command = 'nvim', args = fake_args 'no_list' },
    -- default caps: list + delete — the ACP session/delete path for D.
    del_ag = { command = 'nvim', args = fake_args 'basic' },
    -- Opencode-shaped: list + close but NO delete, with the out-of-band CLI
    -- fallback configured ('{sessionId}' lands in $0 of the sh script).
    oc_ag = {
      command = 'nvim',
      args = fake_args 'close_only',
      session_delete_command = { 'sh', '-c', 'printf %s "$0" > ' .. extern_marker, '{sessionId}' },
    },
  },
  log = { level = 'debug' },
  notify = { turn_end = false, permission = false },
}

vim.cmd('source ' .. repo_root .. '/plugin/mya.lua')

---@param agent_name string
---@return mya.Session
local function new_session(agent_name)
  local got
  session.new(agent_name, {}, function(err, sess)
    got = { err = err, sess = sess }
  end)
  T.wait(3000, function()
    return got ~= nil
  end)
  T.ok(got.err == nil, 'session.new failed: ' .. vim.inspect(got.err))
  return got.sess
end

---@param bufnr integer
---@return string[]
local function buf_lines(bufnr)
  return api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param lines string[]
---@param pat string
---@param plain boolean?
---@return integer?
local function find_line(lines, pat, plain)
  for i, l in ipairs(lines) do
    if l:find(pat, 1, plain and true or false) then
      return i
    end
  end
  return nil
end

--- Wait until every configured agent's fetch settled.
local function wait_settled()
  T.wait(4000, function()
    local st = dashboard._state()
    if not st then
      return false
    end
    for _, grp in pairs(st.groups) do
      if grp.loading then
        return false
      end
    end
    return next(st.groups) ~= nil
  end)
end

--- Line number of a specific (agent, session) row via the dashboard's own
--- line map — session ids repeat across agent groups (every fake process
--- numbers from 1), so a plain text search can land in the wrong group.
--- Child (preview) lines map to the same row; return the smallest lnum.
---@param agent_name string
---@param id string
---@return integer?
local function row_lnum(agent_name, id)
  local st = dashboard._state()
  if not (st and st.line_map) then
    return nil
  end
  local best
  for lnum, e in pairs(st.line_map) do
    if e.kind == 'row' and e.row.agent == agent_name and e.row.id == id then
      best = best and math.min(best, lnum) or lnum
    end
  end
  return best
end

local sess1 ---@type mya.Session

-- ---------------------------------------------------------------------
-- 1. Status sections render: Sessions (merged remote + in-memory rows with
--    agent field, newest first) and Agents (per-agent state notes).
-- ---------------------------------------------------------------------
T.test('dashboard: renders Sessions/Agents sections with per-agent notes', function()
  sess1 = new_session 'list_ag'

  local buf = dashboard.open()
  T.eq(vim.bo[buf].buftype, 'nofile')
  T.eq(vim.bo[buf].filetype, 'mya-dashboard')
  -- nvim_buf_set_name resolves a bare (no "://") name against cwd, same as
  -- any other buffer name; assert the meaningful part.
  T.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ':t'), 'mya-dashboard')

  wait_settled()

  local lines = buf_lines(buf)
  io.stderr:write('----- dashboard -----\n' .. table.concat(lines, '\n') .. '\n----------------------\n')

  T.ok(find_line(lines, '^Sessions:$') ~= nil, 'Sessions section header')
  T.ok(find_line(lines, '^Agents:$') ~= nil, 'Agents section header')
  T.ok(find_line(lines, 'list_ag · ready', true) ~= nil, 'list_ag agent line')
  T.ok(find_line(lines, 'nolist_ag · ready (no session listing)', true) ~= nil, 'nolist_ag agent line annotated')

  local sess1_lnum = row_lnum('list_ag', sess1.id)
  T.ok(sess1_lnum ~= nil, 'in-memory session row present')
  local row = lines[sess1_lnum]
  T.ok(row:find('list_ag', 1, true) ~= nil, 'row carries the agent field: ' .. row)
  T.ok(row:find('lines', 1, true) ~= nil, 'line-count column present: ' .. row)
  T.ok(row:find('idle', 1, true) ~= nil, 'status column present: ' .. row)

  -- The fake agent's session/list gives these SessionInfo rows a title
  -- ("First"/"Second"), which the row renders in preference to the raw id.
  T.ok(find_line(lines, 'First', true) ~= nil, 'remote-only session row (page 1) present')
  T.ok(find_line(lines, 'Second', true) ~= nil, 'remote-only session row (page 2) present')
end)

-- ---------------------------------------------------------------------
-- 2. <CR> opens the session log in the CURRENT window (fugitive vocabulary);
--    the dashboard buffer survives hidden.
-- ---------------------------------------------------------------------
T.test('dashboard: <CR> opens session log in the current window', function()
  local dash_buf = dashboard.open()
  local dash_win = api.nvim_get_current_win()
  wait_settled()
  local lnum = row_lnum('list_ag', sess1.id)
  T.ok(lnum ~= nil)
  api.nvim_win_set_cursor(dash_win, { lnum, 0 })

  local wins_before = #api.nvim_list_wins()
  api.nvim_feedkeys('\r', 'x', false)
  T.wait(2000, function()
    return api.nvim_get_current_buf() ~= dash_buf
  end)

  T.eq(#api.nvim_list_wins(), wins_before, '<CR> did not open a new window')
  T.eq(api.nvim_get_current_win(), dash_win, 'same window is current')
  T.ok(api.nvim_buf_is_valid(dash_buf), 'dashboard buffer still valid (hidden)')
  local new_buf = api.nvim_get_current_buf()
  T.ok(
    api.nvim_buf_get_name(new_buf):find('mya://list_ag/' .. sess1.id .. '/log', 1, true) ~= nil,
    'current window shows the session log: ' .. api.nvim_buf_get_name(new_buf)
  )
end)

-- ---------------------------------------------------------------------
-- 2b. o opens in a split; the dashboard stays visible.
-- ---------------------------------------------------------------------
T.test('dashboard: o opens session log in a split, dashboard stays visible', function()
  local dash_buf = dashboard.open()
  local dash_win = api.nvim_get_current_win()
  wait_settled()
  local lnum = row_lnum('list_ag', sess1.id)
  T.ok(lnum ~= nil)
  api.nvim_win_set_cursor(dash_win, { lnum, 0 })

  local wins_before = #api.nvim_list_wins()
  api.nvim_feedkeys('o', 'x', false)
  T.wait(2000, function()
    return #api.nvim_list_wins() > wins_before
  end)

  T.ok(vim.fn.bufwinid(dash_buf) ~= -1, 'dashboard still shown in some window')
  local new_win = api.nvim_get_current_win()
  T.ok(new_win ~= dash_win, 'a NEW window is now current')
  T.ok(
    api.nvim_buf_get_name(api.nvim_get_current_buf()):find('mya://list_ag/' .. sess1.id .. '/log', 1, true) ~= nil,
    'new window shows the session log'
  )
  api.nvim_win_close(new_win, true)
end)

-- ---------------------------------------------------------------------
-- 2c. = on a not-in-memory row explains there is no preview.
-- ---------------------------------------------------------------------
T.test('dashboard: = on a remote-only row notifies (no preview)', function()
  dashboard.open()
  wait_settled()
  local st = dashboard._state()
  local lnum
  for l, e in pairs(st.line_map) do
    if e.kind == 'row' and not e.row.mem_sess then
      lnum = lnum and math.min(lnum, l) or l
    end
  end
  T.ok(lnum ~= nil, 'a remote-only row exists')
  api.nvim_win_set_cursor(0, { lnum, 0 })

  local notices = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    notices[#notices + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(function()
    api.nvim_feedkeys('=', 'x', false)
  end)
  vim.notify = orig_notify
  if not ok then
    error(err, 0)
  end
  T.ok(#notices == 1 and notices[1].msg:find('no preview', 1, true) ~= nil, 'no-preview notice: ' .. vim.inspect(notices))
end)

---@param agent_name string
---@param id string
---@param confirm_answer integer
local function press_D_on(agent_name, id, confirm_answer)
  local lnum = row_lnum(agent_name, id)
  T.ok(lnum ~= nil, ('row (%s, %s) present in the dashboard'):format(agent_name, id))
  api.nvim_win_set_cursor(0, { lnum, 0 })

  local orig_confirm = vim.fn.confirm
  local confirm_calls = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.confirm = function(...)
    confirm_calls = confirm_calls + 1
    return confirm_answer
  end
  local ok, err = pcall(function()
    api.nvim_feedkeys('D', 'x', false)
  end)
  vim.fn.confirm = orig_confirm
  if not ok then
    error(err, 0)
  end
  return confirm_calls
end

-- ---------------------------------------------------------------------
-- 3. D deletes a session over ACP when the agent advertises
--    sessionCapabilities.delete (with confirm); R refreshes.
-- ---------------------------------------------------------------------
T.test('dashboard: D deletes the session under cursor via session/delete; R refreshes', function()
  local s2 = new_session 'del_ag'

  dashboard.open()
  wait_settled()

  press_D_on('del_ag', s2.id, 1)

  T.wait(3000, function()
    return session.get('del_ag', s2.id) == nil
  end)
  T.ok(session.get('del_ag', s2.id) == nil, 'session removed from the registry after delete')

  -- R: refresh runs without error and settles again.
  local ok2 = pcall(function()
    api.nvim_feedkeys('R', 'x', false)
  end)
  T.ok(ok2, 'R refresh ran without error')
  wait_settled()
end)

-- ---------------------------------------------------------------------
-- 4. D gates: no sessionCapabilities.delete and no CLI fallback -> a
--    warning notice, no confirm dialog, session untouched.
-- ---------------------------------------------------------------------
T.test('dashboard: D warns (and sends nothing) when delete is unsupported and no CLI fallback', function()
  local s3 = new_session 'nolist_ag'

  dashboard.open()
  wait_settled()

  local notices = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    notices[#notices + 1] = { msg = msg, level = level }
  end
  local confirm_calls
  local ok, err = pcall(function()
    confirm_calls = press_D_on('nolist_ag', s3.id, 1)
  end)
  vim.notify = orig_notify
  if not ok then
    error(err, 0)
  end

  T.eq(confirm_calls, 0, 'no confirm dialog for a gated delete')
  T.ok(#notices == 1 and notices[1].msg:find('does not support session/delete', 1, true) ~= nil, 'gating notice shown: ' .. vim.inspect(notices))
  T.eq(notices[1].level, vim.log.levels.WARN)
  T.ok(session.get('nolist_ag', s3.id) ~= nil, 'session still registered after gated delete')
end)

-- ---------------------------------------------------------------------
-- 5. D falls back to the configured session_delete_command CLI when the
--    agent has no delete capability, closing the live session first
--    (close_only = opencode-shaped: list + close, no delete).
-- ---------------------------------------------------------------------
T.test('dashboard: D deletes via session_delete_command CLI, session/close first', function()
  local s4 = new_session 'oc_ag'

  dashboard.open()
  wait_settled()

  press_D_on('oc_ag', s4.id, 1)

  T.wait(3000, function()
    return session.get('oc_ag', s4.id) == nil
  end)
  T.wait(3000, function()
    return vim.fn.filereadable(extern_marker) == 1
  end)
  T.eq(vim.fn.readfile(extern_marker), { s4.id }, 'CLI ran with the substituted session id')

  -- The live session must have been closed agent-side before the CLI ran.
  local stats
  require('mya.agent').get('oc_ag'):request('test/get_stats', vim.empty_dict(), function(err, result)
    stats = { err = err, result = result }
  end)
  T.wait(3000, function()
    return stats ~= nil
  end)
  T.ok(stats.err == nil, 'test/get_stats failed: ' .. vim.inspect(stats.err))
  T.eq(stats.result.close_count, 1, 'session/close sent exactly once before the CLI delete')
end)

T.finish()
