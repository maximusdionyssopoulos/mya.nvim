--- Phase 3 (URL scheme & log buffer UI) tests.
--- Run with: nvim -l tests/phase3_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local api = vim.api
local config = require 'mya.config'
local session = require 'mya.session'
local log = require 'mya.ui.log'
local ui_buf = require 'mya.ui.buf'

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

---@param scenario string
---@return string[]
local function fake_args(scenario)
  return { '-l', fake_agent_path, scenario }
end

config.setup {
  agents = {
    basic_sess = { command = 'nvim', args = fake_args 'session_basic' },
    cancel_sess = { command = 'nvim', args = fake_args 'session_cancel' },
    load_sess = { command = 'nvim', args = fake_args 'session_load' },
    multi_sess = { command = 'nvim', args = fake_args 'session_multi' },
  },
  log = { level = 'debug' },
  notify = { turn_end = false, permission = false },
}

-- Install the BufReadCmd routing exactly the way users get it.
vim.cmd('source ' .. repo_root .. '/plugin/mya.lua')

-- ---------------------------------------------------------------------
-- Helpers (setup patterns copied from phase2_spec)
-- ---------------------------------------------------------------------

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

---@param sess mya.Session
---@param text string
---@return table
local function prompt_and_wait(sess, text)
  local done
  sess:prompt({ { type = 'text', text = text } }, function(err, stop)
    done = { err = err, stop = stop }
  end)
  T.wait(3000, function()
    return done ~= nil
  end)
  return done
end

---@param bufnr integer
---@return string[]
local function buf_lines(bufnr)
  return api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param bufnr integer
---@return string
local function buf_text(bufnr)
  return table.concat(buf_lines(bufnr), '\n')
end

--- 1-based line number of the first line matching `pat`.
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

--- The core offset invariant: blocks are contiguous from line 0 and their
--- line counts sum to the buffer line count (or 0 <-> the single empty line).
---@param bufnr integer
local function check_blocks(bufnr)
  local st = log._state(bufnr)
  T.ok(st ~= nil, 'log orchestrator state present for buffer ' .. bufnr)
  local sum, expected_start = 0, 0
  for i, b in ipairs(st.blocks) do
    T.eq(b.start, expected_start, ('block %d start offset'):format(i))
    sum = sum + b.n
    expected_start = expected_start + b.n
  end
  T.eq(sum, st.total, 'sum of block line counts == total')
  local count = api.nvim_buf_line_count(bufnr)
  if sum == 0 then
    T.eq(count, 1, 'empty log buffer has the single implicit line')
  else
    T.eq(count, sum, 'sum of block line counts == buffer line count')
  end
end

-- Shared across tests (the session_basic fake always uses id sess-1).
local sess1 ---@type mya.Session
local log_buf1 ---@type integer

-- ---------------------------------------------------------------------
-- 0. config: ui section defaults + validation
-- ---------------------------------------------------------------------
T.test('config: ui defaults present and validated', function()
  local cfg = config.get()
  T.eq(cfg.ui.bar, 'statusline')
  T.eq(cfg.ui.log.context_lines, 3)
  T.eq(cfg.ui.log.icons, true)

  T.ok(not pcall(config.setup, { ui = { bar = 'yes' } }), 'ui.bar must be statusline/winbar/false')
  T.ok(not pcall(config.setup, { ui = { bar = true } }), 'ui.bar = true is rejected')
  T.ok(not pcall(config.setup, { ui = { log = { context_lines = 'x' } } }), 'ui.log.context_lines must be number')
  T.ok(not pcall(config.setup, { ui = { log = { icons = 3 } } }), 'ui.log.icons must be boolean')
  -- Failed setups must not have clobbered the active config.
  T.eq(config.get().agents.basic_sess ~= nil, true)
end)

-- ---------------------------------------------------------------------
-- 1. mya:// log buffer renders a streamed turn end-to-end
-- ---------------------------------------------------------------------
T.test('log: mya:// buffer streams a full turn (session_basic)', function()
  sess1 = new_session 'basic_sess'
  vim.cmd.edit('mya://basic_sess/' .. sess1.id .. '/log')
  log_buf1 = api.nvim_get_current_buf()

  T.eq(vim.bo[log_buf1].buftype, 'nofile')
  T.eq(vim.bo[log_buf1].modifiable, false)
  T.eq(vim.bo[log_buf1].bufhidden, 'hide')
  T.eq(vim.bo[log_buf1].swapfile, false)
  T.eq(vim.bo[log_buf1].filetype, 'myalog')
  T.ok(ui_buf.entry(log_buf1) ~= nil, 'buffer registered')
  T.eq(ui_buf.entry(log_buf1).view, 'log')

  -- Attach happened BEFORE the prompt: everything below streams in live.
  local done = prompt_and_wait(sess1, 'hi')
  T.eq(done.stop, 'end_turn')
  vim.wait(150) -- drain trailing scheduled flushes

  local lines = buf_lines(log_buf1)
  local text = buf_text(log_buf1)
  T.ok(find_line(lines, '^## user · fast') ~= nil, 'turn header with config-snapshot model: ' .. lines[1])
  T.ok(text:find('\nhi\n', 1, true) ~= nil, 'user prompt text under the turn header')
  T.ok(find_line(lines, '^### reasoning') ~= nil, 'reasoning section header')
  T.ok(text:find('thinking hard', 1, true) ~= nil, 'coalesced thought text')
  T.ok(find_line(lines, '^## agent') ~= nil, 'agent header')
  T.ok(text:find('Hello world', 1, true) ~= nil, 'coalesced agent text')

  local tool_lnum = find_line(lines, 'read file %(completed%)')
  T.ok(tool_lnum ~= nil, 'tool title line present')
  T.ok(lines[tool_lnum]:find('●', 1, true) ~= nil, 'completed status icon on tool title')
  T.ok(find_line(lines, '↳ /tmp/x%.lua:3') ~= nil, 'location line rendered')
  T.ok(find_line(lines, '⚑ plan updated %(0/2 done%)') ~= nil, 'plan summary line')

  check_blocks(log_buf1)
  -- turn-end with end_turn renders nothing: zero-line block, exact accounting
  T.eq(log._state(log_buf1).blocks[#sess1.events].n, 0)

  -- manual smoke: dump the rendered log
  io.stderr:write('----- rendered log -----\n' .. text .. '\n------------------------\n')
end)

-- ---------------------------------------------------------------------
-- 2. fold levels, foldexpr, foldtext
-- ---------------------------------------------------------------------
T.test('log: fold levels + foldexpr/foldtext tables', function()
  local st = log._state(log_buf1)
  local lines = buf_lines(log_buf1)

  local header = find_line(lines, '^## user')
  local user = find_line(lines, '^hi$')
  local reason = find_line(lines, '^### reasoning')
  local agent_h = find_line(lines, '^## agent')
  local tool = find_line(lines, 'read file %(completed%)')

  T.eq(st.fold_levels[header] or 0, 0, 'turn header stays visible')
  T.eq(st.fold_levels[user] or 0, 0, 'user text stays visible')
  T.eq(st.fold_levels[agent_h] or 0, 0, 'agent header stays visible')
  T.eq(st.fold_levels[agent_h + 1] or 0, 0, 'agent text stays visible')
  T.eq(st.fold_levels[reason], 1, 'reasoning header folds')
  T.eq(st.fold_levels[reason + 1], 1, 'reasoning text folds')
  T.eq(st.fold_levels[tool] or 0, 0, 'tool title stays visible')
  T.eq(st.fold_levels[tool + 1], 1, 'tool location line folds')
  T.eq(st.fold_levels[tool + 2], 1, 'tool content line folds')

  -- foldexpr function returns the same values for the current buffer
  api.nvim_set_current_buf(log_buf1)
  T.eq(log.foldexpr(reason), 1)
  T.eq(log.foldexpr(reason + 1), 1)
  T.eq(log.foldexpr(header), 0)
  T.eq(log.foldexpr(tool), 0)
  T.eq(log.foldexpr(tool + 1), 1)

  -- fold summary text at the fold-start lines
  T.ok(st.fold_text[reason] ~= nil and st.fold_text[reason]:find('reasoning', 1, true) ~= nil, 'reasoning fold summary')
  T.ok(st.fold_text[tool + 1] ~= nil and st.fold_text[tool + 1]:find('read file', 1, true) ~= nil, 'tool fold summary')

  -- window-local fold options were applied
  local win = vim.fn.win_findbuf(log_buf1)[1]
  T.eq(api.nvim_get_option_value('foldmethod', { win = win }), 'expr')
  T.ok(api.nvim_get_option_value('foldexpr', { win = win }):find('mya%.ui%.log') ~= nil, 'foldexpr wired')
  T.eq(api.nvim_get_option_value('foldlevel', { win = win }), 99)

  -- vim.b mirrors
  T.eq(vim.b[log_buf1].mya_fold_levels[reason], 1)
  T.ok(vim.b[log_buf1].mya_fold_text[tostring(tool + 1)] ~= nil, 'fold text mirrored to vim.b')
end)

-- ---------------------------------------------------------------------
-- 3. streaming/mutate accounting + cancel line (session_cancel)
-- ---------------------------------------------------------------------
T.test('log: streaming offsets stay consistent; cancel renders stopped line', function()
  local sess = new_session 'cancel_sess'
  vim.cmd.edit('mya://cancel_sess/' .. sess.id .. '/log')
  local bufnr = api.nvim_get_current_buf()

  local done
  sess:prompt({ { type = 'text', text = 'go' } }, function(err, stop)
    done = { err = err, stop = stop }
  end)

  -- While chunks stream (every 50ms), repeatedly assert the offset invariant.
  for _ = 1, 6 do
    vim.wait(60)
    check_blocks(bufnr)
  end
  T.ok(buf_text(bufnr):find('chunk', 1, true) ~= nil, 'streamed chunks visible mid-turn')

  sess:cancel()
  T.wait(3000, function()
    return done ~= nil
  end)
  T.eq(done.stop, 'cancelled')
  vim.wait(150)

  check_blocks(bufnr)
  T.ok(find_line(buf_lines(bufnr), '· stopped: cancelled', true) ~= nil, 'stopped line rendered for cancelled turn')
end)

-- ---------------------------------------------------------------------
-- 4. autoscroll: bottom-parked cursors follow, others stay; statusline set
-- ---------------------------------------------------------------------
T.test('log: autoscroll follows only bottom-parked cursors', function()
  api.nvim_set_current_buf(log_buf1)
  local bottom_win = api.nvim_get_current_win()
  local count = api.nvim_buf_line_count(log_buf1)
  api.nvim_win_set_cursor(bottom_win, { count, 0 })

  vim.cmd 'split' -- new (current) window shows the same buffer
  local parked_win = api.nvim_get_current_win()
  api.nvim_win_set_cursor(parked_win, { 1, 0 })

  -- statusline (config ui.bar default 'statusline') wired to the component,
  -- embedded in the stock layout so it inherits the theme's StatusLine hl
  local sl = api.nvim_get_option_value('statusline', { win = bottom_win })
  T.ok(sl:find("require'mya'.statusline", 1, true) ~= nil, 'statusline uses require("mya").statusline: ' .. sl)
  T.ok(sl:find('%f', 1, true) ~= nil, 'statusline keeps the stock filename part: ' .. sl)
  local wb = api.nvim_get_option_value('winbar', { win = bottom_win })
  T.eq(wb, '', 'no winbar in the default statusline mode')

  local done = prompt_and_wait(sess1, 'more')
  T.eq(done.stop, 'end_turn')
  vim.wait(150)

  local new_count = api.nvim_buf_line_count(log_buf1)
  T.ok(new_count > count, 'second turn appended lines')
  T.eq(api.nvim_win_get_cursor(bottom_win)[1], new_count, 'bottom-parked window followed the append')
  T.eq(api.nvim_win_get_cursor(parked_win)[1], 1, 'parked window did not move')
  check_blocks(log_buf1)

  api.nvim_win_close(parked_win, true)
end)

-- ---------------------------------------------------------------------
-- 5. plan view + unknown view + not-resumable + load-replay paths
-- ---------------------------------------------------------------------
T.test('plan: renders checkbox lines from the scripted plan', function()
  vim.cmd.edit('mya://basic_sess/' .. sess1.id .. '/plan')
  local bufnr = api.nvim_get_current_buf()
  T.eq(vim.bo[bufnr].filetype, 'myaplan')
  T.eq(vim.bo[bufnr].modifiable, false)

  local lines = buf_lines(bufnr)
  T.ok(lines[1]:find('# Plan', 1, true) ~= nil, 'plan header')
  T.ok(lines[1]:find('Test session', 1, true) ~= nil, 'session title in plan header')
  T.ok(find_line(lines, '[ ] (!) step one', true) ~= nil, 'high-priority pending entry')
  T.ok(find_line(lines, '[ ] step two', true) ~= nil, 'low-priority pending entry')
end)

T.test('buf: unknown view renders an in-buffer error', function()
  vim.cmd.edit('mya://basic_sess/' .. sess1.id .. '/bogus')
  local bufnr = api.nvim_get_current_buf()
  T.ok(buf_text(bufnr):find('unknown mya view', 1, true) ~= nil, 'error line for unknown view')
  T.eq(vim.bo[bufnr].modifiable, false)
end)

T.test('buf: not-in-memory session without loadSession -> not resumable', function()
  -- Every fake-agent scenario advertises loadSession=true, so flip the
  -- in-memory capability after the handshake to simulate a list-but-no-load
  -- agent (concepts-v3 consequence).
  local ag = require('mya.agent').get 'load_sess'
  local ready
  ag:ensure_ready(function(err)
    ready = { err = err }
  end)
  T.wait(3000, function()
    return ready ~= nil
  end)
  T.ok(ready.err == nil, 'load_sess agent ready: ' .. vim.inspect(ready.err))

  local saved = ag.capabilities.loadSession
  ag.capabilities.loadSession = false
  vim.cmd.edit 'mya://load_sess/ghost-1/log'
  local bufnr = api.nvim_get_current_buf()
  T.wait(2000, function()
    return buf_text(bufnr):find('not resumable', 1, true) ~= nil
  end)
  T.ok(buf_text(bufnr):find('does not support session/load', 1, true) ~= nil, 'explanation rendered')
  ag.capabilities.loadSession = saved
end)

T.test('buf: session/load replays into the log buffer', function()
  vim.cmd.edit 'mya://load_sess/loaded-1/log'
  local bufnr = api.nvim_get_current_buf()
  -- session.load is async, so the loading placeholder shows synchronously.
  T.ok(buf_text(bufnr):find('loading session', 1, true) ~= nil, 'loading placeholder rendered first')
  T.wait(3000, function()
    return buf_text(bufnr):find('replayed answer', 1, true) ~= nil
  end)
  local text = buf_text(bufnr)
  T.ok(text:find('hi there', 1, true) ~= nil, 'replayed user message rendered')
  local header_at = text:find('## user', 1, true)
  T.ok(header_at ~= nil and header_at < text:find('hi there', 1, true), 'synthesized ## user header precedes the replayed user message')
  T.ok(text:find('ran cmd', 1, true) ~= nil, 'replayed tool call rendered')
  check_blocks(bufnr)
end)

-- ---------------------------------------------------------------------
-- 6. registry: :edit re-fires BufReadCmd without duplicating subscriptions
-- ---------------------------------------------------------------------
T.test('buf: re-:edit does not duplicate subscriptions', function()
  local sess = new_session 'multi_sess'
  vim.cmd.edit('mya://multi_sess/' .. sess.id .. '/log')
  local bufnr = api.nvim_get_current_buf()

  vim.cmd 'edit' -- re-read same buffer
  vim.cmd.edit('mya://multi_sess/' .. sess.id .. '/log') -- and again by name
  T.eq(api.nvim_get_current_buf(), bufnr, 'same buffer reused for the same URL')

  local done = prompt_and_wait(sess, 'x')
  T.eq(done.stop, 'end_turn')
  vim.wait(150)

  -- A duplicated subscription would double-apply deltas and corrupt offsets
  -- and/or duplicate the rendered chunk text.
  check_blocks(bufnr)
  local _, n = buf_text(bufnr):gsub(vim.pesc(sess.id .. '-1'), '')
  T.eq(n, 1, 'agent chunk rendered exactly once')
end)

-- ---------------------------------------------------------------------
-- 7. render_event unit checks (pure projection, incl. diff content)
-- ---------------------------------------------------------------------
T.test('log: render_event pure projections (diff, failed tool, info, plan)', function()
  local r = log.render_event {
    kind = 'tool_call',
    id = 'tc-d',
    title = 'edit file',
    tool_kind = 'edit',
    status = 'failed',
    content = { { type = 'diff', path = '/tmp/a.lua', oldText = 'a\nb\nc\n', newText = 'a\nB\nc\n' } },
  }
  local text = table.concat(r.lines, '\n')
  T.ok(r.lines[1]:find('✗', 1, true) ~= nil, 'failed status icon')
  T.ok(text:find('```diff', 1, true) ~= nil, 'diff fenced')
  T.ok(text:find('-b', 1, true) ~= nil and text:find('+B', 1, true) ~= nil, 'unified diff body')
  T.eq(r.folds[1], 0)
  for i = 2, #r.lines do
    T.eq(r.folds[i], 1, 'tool body line ' .. i .. ' folds')
  end
  T.eq(r.hl[1].group, 'MyaLogToolFailed')
  T.ok(r.foldtext[2]:find('edit file', 1, true) ~= nil)

  local turn_end = log.render_event { kind = 'turn', phase = 'end', stop_reason = 'end_turn' }
  T.eq(#turn_end.lines, 0, 'end_turn renders nothing')

  local info = log.render_event { kind = 'info', text = 'agent crashed' }
  T.eq(info.lines, { '— agent crashed —' })

  local plan = log.render_event {
    kind = 'plan',
    entries = {
      { content = 'a', status = 'completed' },
      { content = 'b', status = 'in_progress' },
      { content = 'c', status = 'pending' },
    },
  }
  T.eq(plan.lines, { '⚑ plan updated (1/3 done)' })
end)

-- ---------------------------------------------------------------------
-- 8. render_event newline safety (opencode session replay can carry
--    embedded "\n" in tool_call titles / info text; nvim_buf_set_lines
--    rejects any replacement line containing "\n").
-- ---------------------------------------------------------------------
T.test('log: render_event splits embedded newlines into separate lines', function()
  local tc = log.render_event {
    kind = 'tool_call',
    id = 'tc-nl',
    title = 'run:\nls -la',
    tool_kind = 'execute',
    status = 'completed',
  }
  for _, l in ipairs(tc.lines) do
    T.ok(not l:find('\n', 1, true), 'no rendered line contains a newline: ' .. vim.inspect(l))
  end
  T.eq(tc.lines[1], '● $ run:', 'title split before the embedded newline')
  T.eq(tc.lines[2], 'ls -la (completed)', 'title split after the embedded newline, rest of the format intact')
  -- Both title lines share the same fold level/highlight group.
  T.eq(tc.folds[1], 0)
  T.eq(tc.folds[2], 0)
  T.eq(#tc.hl, 2, 'both split title lines get their own highlight entry')
  T.eq(tc.hl[1], { offset = 1, group = 'MyaLogToolTitle' })
  T.eq(tc.hl[2], { offset = 2, group = 'MyaLogToolTitle' })
  -- The fold body (none here) would start after the title's 2 lines; the
  -- foldtext summary itself must stay single-line regardless.
  T.ok(tc.foldtext[3] == nil, 'no body lines follow the 2-line title, so no foldtext key here')

  local tc_with_body = log.render_event {
    kind = 'tool_call',
    id = 'tc-nl-2',
    title = 'run:\nls -la',
    tool_kind = 'execute',
    status = 'completed',
    locations = { { path = '/tmp/x' } },
  }
  T.ok(not tc_with_body.foldtext[3]:find('\n', 1, true), 'foldtext summary has no embedded newline')
  T.ok(tc_with_body.foldtext[3]:find('run: ls %-la', 1, false) ~= nil, 'foldtext collapses the title newline to a space')

  local info = log.render_event { kind = 'info', text = 'first line\nsecond line' }
  T.eq(info.lines, { '— first line', 'second line —' }, 'info text newline is split, not embedded')
  for _, l in ipairs(info.lines) do
    T.ok(not l:find('\n', 1, true), 'info line has no embedded newline')
  end
end)

T.finish()
