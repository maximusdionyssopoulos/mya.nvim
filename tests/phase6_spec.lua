--- Phase 6 (client services & edit review) tests.
--- Run with: nvim -l tests/phase6_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local config = require 'mya.config'
local session = require 'mya.session'
local client = require 'mya.client'
local review = require 'mya.ui.review'

local api = vim.api

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

---@param scenario string
---@return string[]
local function fake_args(scenario)
  return { '-l', fake_agent_path, scenario }
end

config.setup {
  agents = {
    review_ag = { command = 'nvim', args = fake_args 'review_flow' },
    fs_ag = { command = 'nvim', args = fake_args 'fs_ops' },
    enoent_ag = { command = 'nvim', args = fake_args 'fs_enoent' },
    sel_ag = { command = 'nvim', args = fake_args 'permission_select' },
    cancel_ag = { command = 'nvim', args = fake_args 'permission_cancel' },
  },
  log = { level = 'debug' },
  notify = { turn_end = false, permission = false },
  -- Headless tests drive the review buffer explicitly.
  review = { open = 'manual' },
}

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

---@param path string
---@param text string
local function write_file(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

---@param agent_name string
---@param cwd string
---@return mya.Session
local function new_session(agent_name, cwd)
  local got
  session.new(agent_name, { cwd = cwd }, function(err, sess)
    got = { err = err, sess = sess }
  end)
  T.wait(3000, function()
    return got ~= nil
  end)
  T.ok(got.err == nil, 'session.new failed: ' .. vim.inspect(got.err))
  return got.sess
end

--- Start a prompt; returns a closure over the result table.
---@param sess mya.Session
---@return fun(): table? done
local function start_prompt(sess)
  local done
  sess:prompt({ { type = 'text', text = 'go' } }, function(err, stop)
    done = { err = err, stop = stop }
  end)
  return function()
    return done
  end
end

local function get_lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

--- Latest agent message content in a session's event log.
local function last_agent_msg(sess)
  local msg
  for _, e in ipairs(sess.events) do
    if e.kind == 'message' and e.role == 'agent' then
      msg = e.content
    end
  end
  return msg
end

-- ---------------------------------------------------------------------
-- 1. review_flow accept: unit shape, buffer apply, disk apply, turn end.
-- ---------------------------------------------------------------------
T.test('review: accept applies to loaded buffer + disk and completes the turn', function()
  local cwd = tmpdir()
  write_file(cwd .. '/rev_a.txt', 'line1\nline2\n')
  vim.cmd.edit(cwd .. '/rev_a.txt')
  local abuf = api.nvim_get_current_buf()
  -- Unsaved buffer state: asserts the buffer-apply path (not a disk write).
  api.nvim_buf_set_lines(abuf, 2, 2, false, { 'unsaved extra' })
  T.eq(vim.bo[abuf].modified, true)

  local sess = new_session('review_ag', cwd)
  local done = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)

  local units = client.units(sess)
  T.eq(#units, 1)
  local unit = units[1]
  T.eq(unit.title, 'edit files')
  T.eq(#unit.files, 2)
  T.ok(unit.permission ~= nil, 'permission responder held')
  T.eq(client._held_count(sess), 1)

  local by_path = {}
  for _, f in ipairs(unit.files) do
    by_path[f.path] = f
  end
  local fa = by_path[cwd .. '/rev_a.txt']
  T.ok(fa ~= nil, 'rev_a file change present')
  local add, del = client.file_counts(fa)
  T.eq(add, 1)
  T.eq(del, 0)
  local fb = by_path[cwd .. '/sub/rev_b.txt']
  T.ok(fb ~= nil, 'rev_b file change present')
  add, del = client.file_counts(fb)
  T.eq(add, 1)
  T.eq(del, 0)

  T.ok(client.accept(unit))
  -- Buffer applied and left modified (user saves); disk untouched for rev_a.
  T.eq(get_lines(abuf), { 'line1', 'CHANGED', 'line2' })
  T.eq(vim.bo[abuf].modified, true, 'buffer left modified, not :written')
  T.eq(vim.fn.readfile(cwd .. '/rev_a.txt'), { 'line1', 'line2' })
  -- rev_b written to disk, parent dir created.
  T.eq(vim.fn.readfile(cwd .. '/sub/rev_b.txt'), { 'new file' })

  -- end_turn also proves the agent's post-accept fs/write for rev_a got a
  -- success response (the fake agent exits 1 otherwise).
  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'end_turn')
  T.eq(sess.status, 'idle')
  T.eq(sess.pending_tool_calls['tc-edit-1'].event.status, 'completed')
  T.eq(#client.units(sess), 0)
  T.eq(client._held_count(sess), 0)

  vim.cmd('bwipeout! ' .. abuf)
end)

-- ---------------------------------------------------------------------
-- 2. review_flow reject: discarded, agent notified, follow-up prompt works.
-- ---------------------------------------------------------------------
T.test('review: reject discards the unit and leaves consistent state', function()
  local cwd = tmpdir()
  write_file(cwd .. '/rev_a.txt', 'line1\nline2\n')
  local sess = new_session('review_ag', cwd)
  local done = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)

  T.ok(client.reject(sess))
  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'end_turn')
  T.eq(sess.status, 'idle')

  -- Files untouched.
  T.eq(vim.fn.readfile(cwd .. '/rev_a.txt'), { 'line1', 'line2' })
  T.eq(vim.fn.filereadable(cwd .. '/sub/rev_b.txt'), 0)
  -- Agent reacted with tool_call_update failed.
  T.wait(2000, function()
    return sess.pending_tool_calls['tc-edit-1'].event.status == 'failed'
  end)
  T.eq(#client.units(sess), 0)
  T.eq(client._held_count(sess), 0)

  -- Follow-up prompt on the same session (plan deliverable: state consistent
  -- after reject + follow-up).
  local done2 = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)
  T.eq(#client.units(sess), 1)
  T.ok(client.accept(sess))
  T.wait(3000, function()
    return done2() ~= nil
  end)
  T.eq(done2().stop, 'end_turn')
  T.eq(sess.status, 'idle')
  T.eq(vim.fn.readfile(cwd .. '/rev_a.txt'), { 'line1', 'CHANGED', 'line2' })
end)

-- ---------------------------------------------------------------------
-- 3. fs_ops: read from modified buffer (line+limit), permissionless held write.
-- ---------------------------------------------------------------------
T.test('client: fs/read from modified buffer; fs/write held until accept', function()
  local cwd = tmpdir()
  write_file(cwd .. '/fs_read.txt', 'line1\nline2\nline3\nline4\n')
  vim.cmd.edit(cwd .. '/fs_read.txt')
  local rbuf = api.nvim_get_current_buf()
  -- Unsaved in-buffer edit: the read MUST see this, not the disk content.
  api.nvim_buf_set_lines(rbuf, 1, 2, false, { 'EDITED' })

  local sess = new_session('fs_ag', cwd)
  local done = start_prompt(sess)

  -- The write arrives with NO permission flow and must be held.
  T.wait(3000, function()
    return #client.units(sess) == 1
  end)
  T.eq(vim.fn.filereadable(cwd .. '/fs_new.txt'), 0, 'held write must not touch disk')
  local unit = client.units(sess)[1]
  T.eq(unit.title, 'file write', 'synthetic unit (no owning tool call)')
  T.eq(unit.files[1].origin, 'fs_write')
  T.eq(client._held_count(sess), 1)
  T.ok(done() == nil, 'turn still blocked on the held write')

  T.ok(client.accept(sess))
  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'end_turn')
  T.eq(vim.fn.readfile(cwd .. '/fs_new.txt'), { 'written' })

  -- Agent echoed the read content back: buffer version, line=2 limit=2.
  T.eq(last_agent_msg(sess), 'EDITED\nline3\n')
  T.eq(client._held_count(sess), 0)

  vim.cmd('bwipeout! ' .. rbuf)
end)

-- ---------------------------------------------------------------------
-- 4. permission_select: vim.ui.select fallback for a no-diff permission.
-- ---------------------------------------------------------------------
T.test('client: permission with no file changes falls back to vim.ui.select', function()
  local orig_select = vim.ui.select
  local select_calls = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, _opts, on_choice)
    select_calls = select_calls + 1
    for _, it in ipairs(items) do
      if it.kind == 'allow_once' then
        on_choice(it)
        return
      end
    end
    on_choice(nil)
  end

  local ok, err = pcall(function()
    local cwd = tmpdir()
    local sess = new_session('sel_ag', cwd)
    local done = start_prompt(sess)
    T.wait(3000, function()
      return done() ~= nil
    end)
    T.eq(done().stop, 'end_turn')
    T.eq(select_calls, 1)
    T.eq(sess.status, 'idle')
    T.eq(last_agent_msg(sess), 'allowed')
    T.eq(#client.units(sess), 0)
    T.eq(client._held_count(sess), 0)
    -- No review buffer was created for this session.
    for _, b in ipairs(api.nvim_list_bufs()) do
      local name = api.nvim_buf_get_name(b)
      T.ok(name:find('mya%-review://sel_ag/') == nil, 'unexpected review buffer: ' .. name)
    end
  end)

  vim.ui.select = orig_select
  if not ok then
    error(err, 0)
  end
end)

-- ---------------------------------------------------------------------
-- 5. permission_cancel: session:cancel answers the held permission.
-- ---------------------------------------------------------------------
T.test('client: cancelling the turn answers pending permission with cancelled', function()
  local cwd = tmpdir()
  write_file(cwd .. '/cancel_me.txt', 'a\n')
  local sess = new_session('cancel_ag', cwd)
  local done = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)
  T.eq(client._held_count(sess), 1)

  sess:cancel()
  -- done resolving with 'cancelled' proves the agent received outcome
  -- cancelled (fake agent exits 1 on any other outcome).
  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'cancelled')
  T.eq(sess.status, 'idle')
  T.eq(client._held_count(sess), 0, 'no dangling held responders')
  T.eq(#client.units(sess), 0)
  T.eq(vim.fn.readfile(cwd .. '/cancel_me.txt'), { 'a' })
end)

-- ---------------------------------------------------------------------
-- 6. review buffer: rendering, '=' hunks, line map, dv diffsplit, quickfix.
-- ---------------------------------------------------------------------
T.test('review buffer: render, = expansion, line map, dv, populate_qf', function()
  local cwd = tmpdir()
  write_file(cwd .. '/rev_a.txt', 'line1\nline2\n')
  local sess = new_session('review_ag', cwd)
  local done = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)

  local buf, win = review.open(sess)
  T.ok(api.nvim_buf_is_valid(buf))
  T.eq(api.nvim_win_get_buf(win), buf)
  T.eq(vim.bo[buf].modifiable, false)

  local lines = get_lines(buf)
  T.eq(lines[1], '⏺ edit files (2 files)')
  T.eq(lines[2], 'M rev_a.txt (+1 −0)')
  T.eq(lines[3], 'M sub/rev_b.txt (+1 −0)')

  local st = review._state(sess)
  T.ok(st.line_map[1].unit ~= nil and st.line_map[1].file == nil, 'header maps to unit')
  T.eq(st.line_map[2].file.path, cwd .. '/rev_a.txt')

  -- '=' expands inline hunks under the file line.
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { 2, 0 })
  feed '='
  lines = get_lines(buf)
  T.eq(lines[3], '  @@ -1,2 +1,3 @@')
  T.eq(lines[5], '  +CHANGED')
  T.eq(st.line_map[3].hunk, 1, 'hunk header maps to hunk 1')
  T.eq(st.line_map[3].file.path, cwd .. '/rev_a.txt')

  -- '=' again collapses.
  api.nvim_win_set_cursor(win, { 2, 0 })
  feed '='
  T.eq(get_lines(buf)[3], 'M sub/rev_b.txt (+1 −0)')

  -- dv opens a proposed-vs-current diff pair.
  api.nvim_win_set_cursor(win, { 2, 0 })
  feed 'dv'
  local diff_wins = {}
  for _, w in ipairs(api.nvim_list_wins()) do
    if vim.wo[w].diff then
      diff_wins[#diff_wins + 1] = w
    end
  end
  T.eq(#diff_wins, 2, 'dv opens exactly 2 diff windows')
  feed 'q' -- current window is one of the pair; q closes both
  local still_diff = 0
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(w) and vim.wo[w].diff then
      still_diff = still_diff + 1
    end
  end
  T.eq(still_diff, 0, 'q closes the diff pair')

  -- Quickfix: one entry per file-hunk with path + new-side lnum.
  local n = client.populate_qf(sess)
  T.eq(n, 2)
  T.eq(vim.fn.getqflist({ title = 1 }).title, 'ACP review')
  local qf = vim.fn.getqflist()
  T.eq(#qf, 2)
  local lnum_by_name = {}
  for _, it in ipairs(qf) do
    lnum_by_name[vim.fn.fnamemodify(vim.fn.bufname(it.bufnr), ':p')] = it.lnum
    T.ok(it.text:find('edit files: @@ ', 1, true) ~= nil, 'qf text carries tool title + hunk: ' .. it.text)
  end
  T.eq(lnum_by_name[cwd .. '/rev_a.txt'], 2)
  T.eq(lnum_by_name[cwd .. '/sub/rev_b.txt'], 1)

  review.close(sess)
  T.ok(client.reject(sess))
  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'end_turn')
end)

-- ---------------------------------------------------------------------
-- 6b. review buffer: applied-history section (read-only) after the unit
--     is answered; '=' works, 'a'/'r' refuse.
-- ---------------------------------------------------------------------
T.test('review buffer: applied history section is rendered read-only', function()
  local cwd = tmpdir()
  write_file(cwd .. '/rev_a.txt', 'line1\nline2\n')
  local sess = new_session('review_ag', cwd)
  local done = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)

  T.ok(client.accept(sess))
  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'end_turn')
  T.eq(#client.units(sess), 0)

  local history = client.history_units(sess)
  T.eq(#history, 1)
  T.eq(history[1].title, 'edit files')
  T.eq(#history[1].files, 2)
  T.ok(history[1].applied, 'history unit flagged applied')

  local buf, win = review.open(sess)
  local lines = get_lines(buf)
  T.eq(lines[1], 'no pending review units')
  T.eq(lines[3], 'applied (read-only):')
  T.eq(lines[4], '✓ edit files (2 files)')
  T.eq(lines[5], 'M rev_a.txt (+1 −0)')
  T.eq(lines[6], 'M sub/rev_b.txt (+1 −0)')

  -- '=' hunk expansion works on applied entries too.
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { 5, 0 })
  feed '='
  T.eq(get_lines(buf)[6], '  @@ -1,2 +1,3 @@')
  api.nvim_win_set_cursor(win, { 5, 0 })
  feed '='

  -- 'a'/'r' on an applied entry refuse instead of resolving anything.
  local messages = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, _level)
    messages[#messages + 1] = msg
  end
  api.nvim_win_set_cursor(win, { 4, 0 })
  feed 'a'
  feed 'r'
  vim.notify = orig_notify
  T.eq(#messages, 2)
  T.ok(messages[1]:find('already applied', 1, true) ~= nil, messages[1])
  T.eq(#client.history_units(sess), 1, 'history untouched by a/r')

  review.close(sess)
end)

-- ---------------------------------------------------------------------
-- 7. ENOENT read -> -32002 (asserted agent-side; end_turn proves it).
-- ---------------------------------------------------------------------
T.test('client: fs/read of a missing file returns -32002 Resource not found', function()
  local sess = new_session('enoent_ag', tmpdir())
  local done = start_prompt(sess)
  T.wait(3000, function()
    return done() ~= nil
  end)
  T.ok(done().err == nil, vim.inspect(done().err))
  T.eq(done().stop, 'end_turn')
  T.eq(last_agent_msg(sess), 'enoent ok')
end)

-- ---------------------------------------------------------------------
-- 8. buffer changed after capture -> full-replace fallback, exact new_text.
-- ---------------------------------------------------------------------
T.test('review: buffer changed since capture falls back to full replace', function()
  local cwd = tmpdir()
  write_file(cwd .. '/rev_a.txt', 'line1\nline2\n')
  vim.cmd.edit(cwd .. '/rev_a.txt')
  local abuf = api.nvim_get_current_buf()

  local sess = new_session('review_ag', cwd)
  local done = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)

  -- Change the buffer AFTER the permission (and its old_text capture).
  api.nvim_buf_set_lines(abuf, 0, 1, false, { 'line1 tweaked' })

  T.ok(client.accept(sess))
  T.eq(get_lines(abuf), { 'line1', 'CHANGED', 'line2' }, 'full replace: content == new_text exactly')
  T.eq(vim.bo[abuf].modified, true)

  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'end_turn')
  vim.cmd('bwipeout! ' .. abuf)
end)

-- ---------------------------------------------------------------------
-- 9. clean buffer -> hunk-wise apply; one undo step returns to original.
-- ---------------------------------------------------------------------
T.test('review: clean buffer applies hunk-wise and undoes in one step', function()
  local cwd = tmpdir()
  write_file(cwd .. '/rev_a.txt', 'line1\nline2\n')
  vim.cmd.edit(cwd .. '/rev_a.txt')
  local abuf = api.nvim_get_current_buf()
  T.eq(vim.bo[abuf].modified, false)

  local sess = new_session('review_ag', cwd)
  local done = start_prompt(sess)
  T.wait(3000, function()
    return sess.status == 'waiting_permission'
  end)

  T.ok(client.accept(sess))
  T.eq(get_lines(abuf), { 'line1', 'CHANGED', 'line2' })
  T.eq(vim.bo[abuf].modified, true)

  -- Single undo step restores the pre-apply content.
  api.nvim_buf_call(abuf, function()
    vim.cmd 'silent undo'
  end)
  T.eq(get_lines(abuf), { 'line1', 'line2' })

  T.wait(3000, function()
    return done() ~= nil
  end)
  T.eq(done().stop, 'end_turn')
  vim.cmd('bwipeout! ' .. abuf)
end)

T.finish()
