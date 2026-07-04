--- End-to-end user journey against the fake agent, driven through the REAL
--- user surface (the :Mya ex-command and buffer-local keymaps via feedkeys)
--- rather than module internals. Chains the product requirements together in
--- one Neovim instance:
---
---   :Mya dashboard (line counts, spinner indicator, o opens a split)
---   -> cc compose buffer -> :w submits -> ## user / ## agent headers
---   -> live-streaming log auto-update + working animation
---   -> review accept -> :Mya qf (+a −d entries)
---   -> :Mya config picker -> statusline reflects model/mode/variant
---   -> :checkhealth mya
---
--- Run with: nvim -l tests/e2e_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local api = vim.api

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

local function fake_args(scenario)
  return { '-l', fake_agent_path, scenario }
end

require('mya').setup {
  agents = {
    journey_ag = { command = 'nvim', args = fake_args 'session_basic' },
    stream_ag = { command = 'nvim', args = fake_args 'session_cancel' },
    config_ag = { command = 'nvim', args = fake_args 'config_opts' },
    review_ag = { command = 'nvim', args = fake_args 'review_flow' },
  },
  log = { level = 'debug' },
  notify = { turn_end = false, permission = false },
  review = { open = 'manual' },
}

vim.cmd('source ' .. repo_root .. '/plugin/mya.lua')

local session = require 'mya.session'
local dashboard = require 'mya.ui.dashboard'
local prompt = require 'mya.ui.prompt'
local log = require 'mya.ui.log'
local client = require 'mya.client'

---@param agent_name string
---@param opts table?
---@return mya.Session
local function new_session(agent_name, opts)
  local got
  session.new(agent_name, opts or {}, function(err, sess)
    got = { err = err, sess = sess }
  end)
  T.wait(3000, function()
    return got ~= nil
  end)
  T.ok(got.err == nil, 'session.new failed: ' .. vim.inspect(got.err))
  return got.sess
end

---@param bufnr integer
---@param pat string
---@param plain boolean?
---@return integer? lnum
local function find_line(bufnr, pat, plain)
  for i, l in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(pat, 1, plain ~= false) then
      return i
    end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- 1. :Mya opens the dashboard; a session row carries a line count; o
--    opens the log in a NEW window without replacing the dashboard
--    (<CR> would take over the current window, fugitive-style).
-- ---------------------------------------------------------------------
local journey_sess ---@type mya.Session
local log_win ---@type integer
local log_buf ---@type integer

T.test('journey: :Mya dashboard -> o opens the session log in a split', function()
  journey_sess = new_session 'journey_ag'

  vim.cmd 'Mya'
  local dash_buf = api.nvim_get_current_buf()
  local dash_win = api.nvim_get_current_win()
  T.eq(vim.bo[dash_buf].filetype, 'mya-dashboard')

  T.wait(4000, function()
    return find_line(dash_buf, journey_sess.id) ~= nil
  end)
  local lnum = find_line(dash_buf, journey_sess.id)
  local row = api.nvim_buf_get_lines(dash_buf, lnum - 1, lnum, false)[1]
  T.ok(row:find('lines', 1, true) ~= nil, 'dashboard row shows a line count: ' .. row)

  api.nvim_win_set_cursor(dash_win, { lnum, 0 })
  local wins_before = #api.nvim_list_wins()
  api.nvim_feedkeys('o', 'x', false)
  T.wait(2000, function()
    return #api.nvim_list_wins() > wins_before
  end)

  T.ok(vim.fn.bufwinid(dash_buf) ~= -1, 'dashboard buffer still visible after o')
  log_win = api.nvim_get_current_win()
  log_buf = api.nvim_get_current_buf()
  T.ok(log_win ~= dash_win, 'o opened a NEW window')
  T.ok(
    api.nvim_buf_get_name(log_buf):find('mya://journey_ag/' .. journey_sess.id .. '/log', 1, true) ~= nil,
    'new window shows the session log'
  )
end)

-- ---------------------------------------------------------------------
-- 2. cc -> compose buffer -> :w submits -> streamed turn:
--    ## user / ## agent headers, reasoning fold, winbar line count.
-- ---------------------------------------------------------------------
T.test('journey: cc compose -> :w submit -> user/agent headers + streamed turn', function()
  api.nvim_set_current_win(log_win)
  local wins_before = #api.nvim_list_wins()
  api.nvim_feedkeys('cc', 'x', false)
  T.wait(2000, function()
    return #api.nvim_list_wins() > wins_before
  end)
  local pst = prompt._state(journey_sess)
  T.ok(pst ~= nil and vim.bo[pst.buf].filetype == 'mya-compose', 'cc opened the compose buffer')
  T.eq(vim.bo[pst.buf].buftype, 'acwrite')

  api.nvim_set_current_win(vim.fn.win_findbuf(pst.buf)[1])
  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { 'please read @README.md' })
  vim.cmd.write()

  T.wait(4000, function()
    return journey_sess.status == 'idle' and journey_sess.stop_reason == 'end_turn'
  end)
  vim.wait(200)

  T.ok(find_line(log_buf, '^## user', false) ~= nil, 'log has the ## user header')
  T.ok(find_line(log_buf, '^## agent', false) ~= nil, 'log has the ## agent header')
  T.ok(find_line(log_buf, 'please read @README.md') ~= nil, 'prompt text in the log (sent verbatim)')
  T.ok(find_line(log_buf, 'Hello world') ~= nil, 'streamed agent reply coalesced into the log')
  T.ok(find_line(log_buf, 'reasoning', true) ~= nil, 'reasoning block rendered')

  -- No client-side @ parsing: the builder sends exactly one text block.
  local blocks = prompt.build_blocks(journey_sess, 'please read @README.md')
  T.ok(#blocks == 1 and blocks[1].type == 'text', 'prompt text is a single verbatim text block')

  -- Bar component: model display from config options + trailing line count.
  local comp = require('mya').statusline(log_buf)
  T.ok(comp:find('Fast', 1, true) ~= nil, 'bar shows the model display: ' .. comp)
  T.ok(comp:find('lines', 1, true) ~= nil, 'bar shows the log line count: ' .. comp)
end)

-- ---------------------------------------------------------------------
-- 3. Streaming session: the log buffer auto-updates (no manual refresh)
--    and shows the plain working animation; the dashboard row spins too.
-- ---------------------------------------------------------------------
T.test('journey: log auto-streams + working animation; dashboard shows prompting', function()
  local sess = new_session 'stream_ag'
  vim.cmd.split('mya://stream_ag/' .. sess.id .. '/log')
  local sbuf = api.nvim_get_current_buf()

  vim.cmd 'Mya send go'
  T.wait(2000, function()
    return sess.status == 'prompting'
  end)

  local count_a = api.nvim_buf_line_count(sbuf)
  T.wait(3000, function()
    return api.nvim_buf_line_count(sbuf) > count_a or #api.nvim_buf_get_lines(sbuf, -2, -1, false)[1] > 0
  end)
  local grew = api.nvim_buf_line_count(sbuf) > count_a
  T.ok(grew or find_line(sbuf, 'chunk') ~= nil, 'log buffer auto-updated while streaming')

  -- Working animation: a virt_lines extmark in the mya_log namespace.
  local ns = api.nvim_create_namespace 'mya_log'
  local has_virt = false
  for _, m in ipairs(api.nvim_buf_get_extmarks(sbuf, ns, 0, -1, { details = true })) do
    if m[4].virt_lines and #m[4].virt_lines > 0 then
      has_virt = true
    end
  end
  T.ok(has_virt, 'working-indicator virt_lines present while prompting')

  -- Dashboard row for the streaming session shows a spinner frame + status.
  local dash_buf = dashboard.open()
  T.wait(3000, function()
    return find_line(dash_buf, sess.id) ~= nil
  end)
  local lnum = find_line(dash_buf, sess.id)
  local row = api.nvim_buf_get_lines(dash_buf, lnum - 1, lnum, false)[1]
  T.ok(row:find('prompting', 1, true) ~= nil, 'dashboard row shows prompting status: ' .. row)
  local ind = row:match '^%s*(.)'
  T.ok(('-\\|/'):find(ind, 1, true) ~= nil, 'dashboard indicator is a plain spinner frame: ' .. row)

  -- Cancel from the session buffer via the real command.
  api.nvim_set_current_win(vim.fn.win_findbuf(sbuf)[1])
  vim.cmd 'Mya cancel'
  T.wait(4000, function()
    return sess.status == 'idle'
  end)
end)

-- ---------------------------------------------------------------------
-- 4. Review accept -> :Mya qf lists the edit tool call with (+a −d).
-- ---------------------------------------------------------------------
T.test('journey: accepted edit -> :Mya qf entries with +/- counts', function()
  local cwd = vim.fn.tempname()
  vim.fn.mkdir(cwd, 'p')
  vim.fn.writefile({ 'line1', 'line2' }, cwd .. '/rev_a.txt')

  local sess = new_session('review_ag', { cwd = cwd })
  local done
  sess:prompt({ { type = 'text', text = 'go' } }, function(err, stop)
    done = { err = err, stop = stop }
  end)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)
  T.ok(client.accept(sess))
  T.wait(3000, function()
    return done ~= nil and done.stop == 'end_turn'
  end)

  vim.cmd.edit('mya://review_ag/' .. sess.id .. '/log')
  vim.cmd 'Mya qf'
  local qf = vim.fn.getqflist()
  T.ok(#qf > 0, 'quickfix populated by :Mya qf')
  local found = false
  for _, it in ipairs(qf) do
    if it.text:find('+', 1, true) ~= nil and it.bufnr ~= 0 then
      found = true
    end
  end
  T.ok(found, 'quickfix entry carries added/changed counts: ' .. vim.inspect(qf))
end)

-- ---------------------------------------------------------------------
-- 5. :Mya config -> pick mode=Chat -> statusline shows model+mode+variant.
-- ---------------------------------------------------------------------
T.test('journey: :Mya config changes mode; statusline shows model/mode/variant', function()
  local sess = new_session 'config_ag'
  vim.cmd.edit('mya://config_ag/' .. sess.id .. '/log')
  local buf = api.nvim_get_current_buf()

  local orig_select = vim.ui.select
  local calls = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, _opts, on_choice)
    calls = calls + 1
    for _, it in ipairs(items) do
      if (calls == 1 and it.id == 'mode') or (calls == 2 and it.value == 'chat') then
        on_choice(it)
        return
      end
    end
    on_choice(nil)
  end
  local ok, err = pcall(vim.cmd, 'Mya config')
  vim.ui.select = orig_select
  T.ok(ok, ':Mya config raised: ' .. tostring(err))

  T.wait(3000, function()
    local comp = require('mya').statusline(buf)
    return comp:find('Chat', 1, true) ~= nil
  end)
  local comp = require('mya').statusline(buf)
  T.ok(comp:find('claude%-sonnet') ~= nil, 'statusline shows model: ' .. comp)
  T.ok(comp:find('Chat', 1, true) ~= nil, 'statusline shows changed mode: ' .. comp)
  T.ok(comp:find('Default', 1, true) ~= nil, 'statusline shows variant: ' .. comp)
end)

-- ---------------------------------------------------------------------
-- 6. :checkhealth mya runs and reports the configured agents.
-- ---------------------------------------------------------------------
T.test('journey: :checkhealth mya reports configured agents', function()
  local ok, err = pcall(vim.cmd, 'checkhealth mya')
  T.ok(ok, ':checkhealth mya raised: ' .. tostring(err))
  local health_buf = api.nvim_get_current_buf()
  T.ok(find_line(health_buf, 'journey_ag') ~= nil, 'health output mentions a configured agent')
end)

T.finish()
