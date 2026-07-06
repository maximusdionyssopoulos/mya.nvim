--- Prompting tests: compose buffer (:w submits), ambient session targeting,
--- range staging, :Mya completion.
--- Run with: nvim -l tests/phase5_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local api = vim.api
local config = require 'mya.config'
local session = require 'mya.session'
local client = require 'mya.client'
local log = require 'mya.ui.log'
local prompt = require 'mya.ui.prompt'
local cmd = require 'mya.ui.cmd'
local statusline = require 'mya.statusline'

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

---@param scenario string
---@return string[]
local function fake_args(scenario)
  return { '-l', fake_agent_path, scenario }
end

config.setup {
  agents = {
    basic_ag = { command = 'nvim', args = fake_args 'session_basic' },
    cancel_ag = { command = 'nvim', args = fake_args 'session_cancel' },
    config_ag = { command = 'nvim', args = fake_args 'config_opts' },
    review_ag = { command = 'nvim', args = fake_args 'review_flow' },
  },
  log = { level = 'debug' },
  notify = { turn_end = false, permission = false },
  review = { open = 'manual' },
}

vim.cmd('source ' .. repo_root .. '/plugin/mya.lua')

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

---@return string[] captured vim.notify messages from running fn
local function capture_notify(fn)
  local messages = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, _level)
    messages[#messages + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = orig_notify
  T.ok(ok, 'must not raise: ' .. tostring(err))
  return messages
end

-- ---------------------------------------------------------------------
-- 0. No session anywhere yet: session-scoped subcommands error clearly.
--    MUST run before any mya:// buffer is entered (ambient tracking).
-- ---------------------------------------------------------------------
T.test(':Mya send errors when no current session exists at all', function()
  local scratch = api.nvim_create_buf(false, true)
  api.nvim_set_current_buf(scratch)
  local messages = capture_notify(function()
    cmd.run { fargs = { 'send', 'hello' }, range = 0 }
  end)
  T.ok(#messages > 0, 'expected a vim.notify call')
  T.ok(messages[1]:find('no current session', 1, true) ~= nil, messages[1])
end)

-- ---------------------------------------------------------------------
-- 1. cc opens the compose buffer: a plain acwrite scratch, no insert-mode
--    maps, stable filetype.
-- ---------------------------------------------------------------------
local sess1 ---@type mya.Session
local log_buf1 ---@type integer

T.test('compose: cc opens an acwrite compose buffer for the log buffer', function()
  sess1 = new_session 'basic_ag'
  vim.cmd.edit('mya://basic_ag/' .. sess1.id .. '/log')
  log_buf1 = api.nvim_get_current_buf()

  local wins_before = #api.nvim_list_wins()
  api.nvim_feedkeys('cc', 'x', false)
  T.wait(2000, function()
    return #api.nvim_list_wins() > wins_before
  end)

  local pst = prompt._state(sess1)
  T.ok(pst ~= nil, 'compose buffer state created')
  T.eq(vim.bo[pst.buf].buftype, 'acwrite')
  T.eq(vim.bo[pst.buf].filetype, 'mya-compose')
  T.ok(api.nvim_buf_get_name(pst.buf):find('mya%-compose://basic_ag/') ~= nil, 'compose buffer named mya-compose://<agent>/<id>')
  -- No chat-widget maps: <CR> and <Tab> stay untouched in insert mode.
  for _, m in ipairs(api.nvim_buf_get_keymap(pst.buf, 'i')) do
    T.ok(m.lhs ~= '<CR>' and m.lhs ~= '<Tab>' and m.lhs ~= '<S-CR>', 'no insert-mode map hijacks: ' .. m.lhs)
  end
end)

-- ---------------------------------------------------------------------
-- 2. :w submits the whole buffer as one message and clears the draft.
-- ---------------------------------------------------------------------
T.test('compose: :w submits the message and clears the draft', function()
  local pst = prompt._state(sess1)
  T.ok(pst ~= nil)
  api.nvim_set_current_win(vim.fn.win_findbuf(pst.buf)[1])

  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { 'hello from compose buffer' })
  vim.cmd.write()

  T.wait(3000, function()
    for _, e in ipairs(sess1.events) do
      if e.kind == 'message' and e.role == 'user' and e.content == 'hello from compose buffer' then
        return true
      end
    end
    return false
  end)

  vim.wait(200) -- let the log buffer render the new turn
  local lines = api.nvim_buf_get_lines(log_buf1, 0, -1, false)
  local found_header = false
  for _, l in ipairs(lines) do
    if l:find('^## user', 1, false) then
      found_header = true
    end
  end
  T.ok(found_header, 'turn rendered with the ## user header')
  T.eq(api.nvim_buf_get_lines(pst.buf, 0, -1, false), { '' }, 'compose buffer cleared after submit')
  T.eq(vim.bo[pst.buf].modified, false, 'compose buffer unmodified after :w')
end)

-- ---------------------------------------------------------------------
-- 2b. Multi-line drafts are plain buffer editing; :w sends one block.
-- ---------------------------------------------------------------------
T.test('compose: multi-line draft submits as one message', function()
  local pst = prompt._state(sess1)
  T.ok(pst ~= nil)
  api.nvim_set_current_win(vim.fn.win_findbuf(pst.buf)[1])

  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { 'line one', 'line two' })
  vim.cmd.write()

  T.wait(3000, function()
    for _, e in ipairs(sess1.events) do
      if e.kind == 'message' and e.role == 'user' and e.content == 'line one\nline two' then
        return true
      end
    end
    return false
  end)
end)

-- ---------------------------------------------------------------------
-- 3. Ambient session: :Mya send works from an unrelated buffer, targeting
--    the most recently entered session buffer.
-- ---------------------------------------------------------------------
T.test(':Mya send from a non-session buffer targets the ambient session', function()
  T.wait(4000, function()
    return sess1.status == 'idle'
  end)
  local scratch = api.nvim_create_buf(false, true)
  api.nvim_set_current_buf(scratch)

  cmd.run { fargs = { 'send', 'ambient', 'hello' }, range = 0 }

  T.wait(3000, function()
    for _, e in ipairs(sess1.events) do
      if e.kind == 'message' and e.role == 'user' and e.content == 'ambient hello' then
        return true
      end
    end
    return false
  end)
end)

-- ---------------------------------------------------------------------
-- 4. :{range}Mya send stages the range as a resource block, then sends.
-- ---------------------------------------------------------------------
T.test(':{range}Mya send from a file buffer stages the range and sends', function()
  local tmpfile = vim.fn.tempname() .. '.txt'
  vim.fn.writefile({ 'alpha line', 'beta line', 'gamma line' }, tmpfile)
  vim.cmd.edit(tmpfile)

  -- Capture the outgoing content blocks instead of round-tripping.
  local captured
  rawset(sess1, 'prompt', function(_self, blocks, cb)
    captured = blocks
    if cb then
      cb(nil, 'end_turn')
    end
  end)
  local ok, err = pcall(cmd.run, { fargs = { 'send', 'fix', 'this' }, range = 2, line1 = 1, line2 = 2 })
  rawset(sess1, 'prompt', nil) -- restore the metatable method
  T.ok(ok, 'cmd.run raised: ' .. tostring(err))

  T.ok(captured ~= nil, 'prompt sent')
  T.eq(captured[1].type, 'text')
  T.eq(captured[1].text, 'fix this')
  local res
  for _, b in ipairs(captured) do
    if b.type == 'resource' then
      res = b
    end
  end
  T.ok(res ~= nil, 'range staged as a resource block: ' .. vim.inspect(captured))
  T.ok(res.resource.uri:find('#L1%-L2$') ~= nil, 'resource uri carries the span: ' .. res.resource.uri)
  T.ok(res.resource.text:find('alpha line', 1, true) ~= nil, 'resource text carries the range content')
  T.ok(res.resource.text:find('gamma', 1, true) == nil, 'resource text excludes lines outside the range')
  T.eq(#prompt.staged(sess1), 0, 'staged blocks consumed by the send')
end)

-- ---------------------------------------------------------------------
-- 5. Prompt text is sent verbatim: no client-side @-token parsing.
-- ---------------------------------------------------------------------
T.test('build_blocks sends text verbatim (no @mention resource_link scanning)', function()
  local blocks = prompt.build_blocks(sess1, 'please check @lua/mya/init.lua and @reviewer')
  T.eq(#blocks, 1, 'exactly one block (no staged context): ' .. vim.inspect(blocks))
  T.eq(blocks[1].type, 'text')
  T.eq(blocks[1].text, 'please check @lua/mya/init.lua and @reviewer')
end)

-- ---------------------------------------------------------------------
-- 6. :Mya include stages a resource block that attaches on next submit.
-- ---------------------------------------------------------------------
T.test(':Mya include stages a resource block attached on the next build_blocks', function()
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile({ 'staged content line 1', 'line2' }, tmpfile)

  cmd.run { fargs = { 'include', tmpfile }, range = 0 }

  local blocks = prompt.build_blocks(sess1, 'see attached')
  local found
  for _, b in ipairs(blocks) do
    if b.type == 'resource' and b.resource.uri == 'file://' .. tmpfile then
      found = b
    end
  end
  T.ok(found ~= nil, 'expected a staged resource block for the included file')
  T.ok(found.resource.text:find('staged content line 1', 1, true) ~= nil, 'resource text carries file content')

  T.eq(#prompt.staged(sess1), 0, 'staged blocks cleared after build_blocks')
end)

-- ---------------------------------------------------------------------
-- 6a. A note travels WITH the include: `:{range}Mya include <note>` embeds
--     it in the range's resource header, and `:Mya include path -- note`
--     embeds it in the file's resource text + label.
-- ---------------------------------------------------------------------
T.test(':{range}Mya include <note> attaches the note to the range resource', function()
  prompt.clear_staged(sess1)
  local tmpfile = vim.fn.tempname() .. '.txt'
  vim.fn.writefile({ 'alpha line', 'beta line', 'gamma line' }, tmpfile)
  vim.cmd.edit(tmpfile)

  cmd.run { fargs = { 'include', 'check', 'this', 'off-by-one' }, range = 2, line1 = 1, line2 = 2 }

  local staged = prompt.staged(sess1)
  T.eq(#staged, 1, 'one staged entry')
  local res = staged[1].block.resource
  T.ok(res.text:find('check this off-by-one', 1, true) ~= nil, 'note embedded in resource text: ' .. res.text)
  T.ok(res.text:find('alpha line', 1, true) ~= nil, 'range content still present')
  T.ok(res.text:find('gamma', 1, true) == nil, 'lines outside the range excluded')
  T.ok(staged[1].label:find('check this off-by-one', 1, true) ~= nil, 'note shown in staged label: ' .. staged[1].label)
end)

T.test(':Mya include path -- note attaches the note to the file resource', function()
  prompt.clear_staged(sess1)
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile({ 'file body line' }, tmpfile)

  cmd.run { fargs = { 'include', tmpfile, '--', 'review', 'error', 'handling' }, range = 0 }

  local staged = prompt.staged(sess1)
  T.eq(#staged, 1, 'one staged entry')
  local res = staged[1].block.resource
  T.eq(res.uri, 'file://' .. tmpfile, 'uri is the pure file path (no note)')
  T.ok(res.text:find('review error handling', 1, true) ~= nil, 'note prepended to file content: ' .. res.text)
  T.ok(res.text:find('file body line', 1, true) ~= nil, 'file content still present')
  T.ok(staged[1].label:find('review error handling', 1, true) ~= nil, 'note shown in staged label')
  prompt.clear_staged(sess1)
end)

-- ---------------------------------------------------------------------
-- 6b. Staging renders REAL `# staged:` lines at the bottom of the compose
--     buffer (gitcommit-style), each carrying a Comment extmark.
-- ---------------------------------------------------------------------
T.test('compose: staging renders real `# staged:` lines below the draft', function()
  prompt.clear_staged(sess1)
  prompt.open_for_session(sess1)
  local pst = prompt._state(sess1)
  T.ok(pst ~= nil)
  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { 'my draft line' })

  prompt.stage(sess1, { type = 'text', text = 'A' }, 'file_a')
  prompt.stage(sess1, { type = 'text', text = 'B' }, 'file_b')

  T.eq(api.nvim_buf_get_lines(pst.buf, 0, -1, false), { 'my draft line', '# staged: file_a', '# staged: file_b' })
  -- Real lines, so highlighted via a Comment extmark per line (not virt_lines).
  local ns = api.nvim_create_namespace 'mya_prompt_staged'
  T.eq(#api.nvim_buf_get_extmarks(pst.buf, ns, 0, -1, {}), 2, 'one Comment extmark per staged line')
end)

-- ---------------------------------------------------------------------
-- 6c. Deleting one of two `# staged:` lines then firing TextChanged prunes
--     exactly that entry (and never rewrites the buffer).
-- ---------------------------------------------------------------------
T.test('compose: deleting a `# staged:` line prunes exactly that entry', function()
  prompt.clear_staged(sess1)
  local pst = prompt._state(sess1)
  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { 'my draft line' })
  prompt.stage(sess1, { type = 'text', text = 'A' }, 'file_a')
  prompt.stage(sess1, { type = 'text', text = 'B' }, 'file_b')
  T.eq(#prompt.staged(sess1), 2)

  -- User deletes the file_a line; TextChanged prunes state only.
  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { 'my draft line', '# staged: file_b' })
  local msgs = capture_notify(function()
    api.nvim_exec_autocmds('TextChanged', { buffer = pst.buf })
  end)

  local staged = prompt.staged(sess1)
  T.eq(#staged, 1, 'exactly one entry survives')
  T.eq(staged[1].label, 'file_b')
  T.eq(api.nvim_buf_get_lines(pst.buf, 0, -1, false), { 'my draft line', '# staged: file_b' }, 'prune must not touch the buffer')
  local unstaged = false
  for _, m in ipairs(msgs) do
    if m:find('unstaged: file_a', 1, true) then
      unstaged = true
    end
  end
  T.ok(unstaged, 'notified about the dropped entry: ' .. vim.inspect(msgs))
end)

-- ---------------------------------------------------------------------
-- 6d. Submit (BufWriteCmd) strips the `# staged:` lines from the message and
--     attaches only the surviving staged blocks.
-- ---------------------------------------------------------------------
T.test('compose: submit strips `# staged:` lines and attaches surviving blocks', function()
  prompt.clear_staged(sess1)
  prompt.open_for_session(sess1)
  local pst = prompt._state(sess1)
  api.nvim_set_current_win(vim.fn.win_findbuf(pst.buf)[1])
  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { 'do the thing' })
  prompt.stage(sess1, { type = 'resource', resource = { uri = 'x', text = 'AAA' } }, 'keep_me')

  local captured
  rawset(sess1, 'prompt', function(_self, blocks, cb)
    captured = blocks
    if cb then
      cb(nil, 'end_turn')
    end
  end)
  api.nvim_exec_autocmds('BufWriteCmd', { buffer = pst.buf })
  rawset(sess1, 'prompt', nil)

  T.ok(captured ~= nil, 'prompt sent')
  T.eq(captured[1].type, 'text')
  T.eq(captured[1].text, 'do the thing', 'message excludes the `# staged:` line')
  T.eq(#captured, 2, 'text block + one surviving resource block')
  T.eq(captured[2].resource.text, 'AAA')
  T.eq(#prompt.staged(sess1), 0, 'staging cleared after submit')
end)

-- ---------------------------------------------------------------------
-- 6e. A markdown `# heading` in the draft is ordinary prompt text: only the
--     exact `# staged: ` prefix is magic, so the heading survives into the
--     sent message.
-- ---------------------------------------------------------------------
T.test('compose: a markdown `# heading` in the draft survives into the message', function()
  prompt.clear_staged(sess1)
  prompt.open_for_session(sess1)
  local pst = prompt._state(sess1)
  api.nvim_set_current_win(vim.fn.win_findbuf(pst.buf)[1])
  api.nvim_buf_set_lines(pst.buf, 0, -1, false, { '# My heading', 'body text' })
  prompt.stage(sess1, { type = 'text', text = 'S' }, 'ctx')

  local captured
  rawset(sess1, 'prompt', function(_self, blocks, cb)
    captured = blocks
    if cb then
      cb(nil, 'end_turn')
    end
  end)
  api.nvim_exec_autocmds('BufWriteCmd', { buffer = pst.buf })
  rawset(sess1, 'prompt', nil)

  T.ok(captured ~= nil, 'prompt sent')
  T.eq(captured[1].text, '# My heading\nbody text', 'markdown heading is not stripped')
end)

-- ---------------------------------------------------------------------
-- 7. Bare :Mya send opens the compose buffer (the :Git commit split).
-- ---------------------------------------------------------------------
T.test('bare :Mya send opens the compose window', function()
  prompt.close(sess1)
  vim.cmd.edit('mya://basic_ag/' .. sess1.id .. '/log')

  cmd.run { fargs = { 'send' }, range = 0 }

  local pst = prompt._state(sess1)
  T.ok(pst ~= nil)
  T.ok(#vim.fn.win_findbuf(pst.buf) > 0, 'a window shows the compose buffer')
end)

-- ---------------------------------------------------------------------
-- 8. :Mya completion: subcommands, open targets, agent slash commands.
-- ---------------------------------------------------------------------
T.test(':Mya completion covers subcommands, open targets, slash commands', function()
  local subs = cmd.complete('', 'Mya ', 4)
  local has_open, has_send, has_plan = false, false, false
  for _, s in ipairs(subs) do
    has_open = has_open or s == 'open'
    has_send = has_send or s == 'send'
    has_plan = has_plan or s == 'plan'
  end
  T.ok(has_open and has_send and has_plan, 'subcommand completion: ' .. vim.inspect(subs))

  local targets = cmd.complete('', 'Mya open ', 9)
  local has_agent, has_session = false, false
  for _, t in ipairs(targets) do
    has_agent = has_agent or t == 'basic_ag'
    has_session = has_session or t == ('basic_ag/' .. sess1.id)
  end
  T.ok(has_agent, 'agent completed for :Mya open: ' .. vim.inspect(targets))
  T.ok(has_session, 'in-memory session completed for :Mya open: ' .. vim.inspect(targets))

  -- Agent slash commands complete on the :Mya send cmdline (they are plain
  -- prompt text on the wire; the cmdline is their one completion surface).
  vim.cmd.edit('mya://basic_ag/' .. sess1.id .. '/log')
  T.wait(3000, function()
    return sess1.available_commands ~= nil
  end)
  local cmds = cmd.complete('/', 'Mya send /', 10)
  T.eq(cmds, { '/web' }, 'slash command completion: ' .. vim.inspect(cmds))
  T.eq(cmd.complete('/zz', 'Mya send /zz', 12), {}, 'non-matching slash prefix yields nothing')
end)

-- ---------------------------------------------------------------------
-- 9. :Mya qf fills quickfix with (+a -d) entries after an edit tool call.
-- ---------------------------------------------------------------------
T.test(':Mya qf fills quickfix with (+a -d) entries after an accepted edit', function()
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
    return done ~= nil
  end)
  T.eq(done.stop, 'end_turn')

  vim.cmd.edit('mya://review_ag/' .. sess.id .. '/log')
  cmd.run { fargs = { 'qf' }, range = 0 }

  local qf = vim.fn.getqflist()
  T.ok(#qf > 0, 'expected quickfix entries')
  local found = false
  for _, it in ipairs(qf) do
    if it.text:find('edit files', 1, true) and it.text:find('+1', 1, true) then
      found = true
    end
  end
  T.ok(found, '(+a -d) entry present: ' .. vim.inspect(qf))
end)

-- ---------------------------------------------------------------------
-- 9b. :Mya review opens the session's review buffer in a window.
-- ---------------------------------------------------------------------
T.test(':Mya review opens the review buffer from a session buffer', function()
  local sess = new_session 'review_ag'
  vim.cmd.edit('mya://review_ag/' .. sess.id .. '/log')

  cmd.run { fargs = { 'review' }, range = 0 }

  local found_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:find('mya-review://', 1, true) then
      found_win = win
    end
  end
  T.ok(found_win ~= nil, 'a window shows the mya-review:// buffer')
  T.eq(vim.api.nvim_get_current_win(), found_win)
end)

-- ---------------------------------------------------------------------
-- 9c. :Mya plan opens the session's plan buffer in a split; the log
--     buffer's `cp` map is wired to the same opener, and reopening
--     focuses the existing window instead of duplicating it.
-- ---------------------------------------------------------------------
T.test(':Mya plan opens the plan buffer and is idempotent; log `cp` is bound', function()
  local sess = new_session 'basic_ag'
  vim.cmd.edit('mya://basic_ag/' .. sess.id .. '/log')

  -- The log buffer binds `cp` (open_plan) buffer-locally.
  local m = vim.fn.maparg('cp', 'n', false, true)
  T.ok(m and m.buffer == 1, 'cp is a buffer-local map in the log buffer: ' .. vim.inspect(m))

  cmd.run { fargs = { 'plan' }, range = 0 }

  local plan_name = 'mya://basic_ag/' .. sess.id .. '/plan'
  local function plan_wins()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == plan_name then
        wins[#wins + 1] = win
      end
    end
    return wins
  end

  local wins = plan_wins()
  T.eq(#wins, 1, 'exactly one window shows the plan buffer')
  T.eq(vim.api.nvim_get_current_win(), wins[1])
  T.eq(vim.bo[vim.api.nvim_win_get_buf(wins[1])].filetype, 'myaplan')

  -- Reopening from the plan window itself (its session resolves ambiently)
  -- focuses the existing window rather than opening a duplicate.
  cmd.run { fargs = { 'plan' }, range = 0 }
  local again = plan_wins()
  T.eq(#again, 1, 'no duplicate plan window on reopen')
  T.eq(vim.api.nvim_get_current_win(), again[1])
end)

-- ---------------------------------------------------------------------
-- 10. :Mya config changes a config option via vim.ui.select; statusline
--     reflects it.
-- ---------------------------------------------------------------------
T.test(':Mya config picks an option via vim.ui.select and updates the statusline', function()
  local sess = new_session 'config_ag'
  vim.cmd.edit('mya://config_ag/' .. sess.id .. '/log')

  local orig_select = vim.ui.select
  local call_n = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, _opts, on_choice)
    call_n = call_n + 1
    if call_n == 1 then
      for _, it in ipairs(items) do
        if it.id == 'variant' then
          on_choice(it)
          return
        end
      end
      on_choice(nil)
    else
      for _, it in ipairs(items) do
        if it.value == 'fast' then
          on_choice(it)
          return
        end
      end
      on_choice(nil)
    end
  end

  local ok, err = pcall(cmd.run, { fargs = { 'config' }, range = 0 })
  vim.ui.select = orig_select
  T.ok(ok, 'cmd.run must not raise: ' .. tostring(err))

  T.wait(3000, function()
    for _, o in ipairs(sess.config_options or {}) do
      if o.id == 'variant' then
        return o.currentValue == 'fast'
      end
    end
    return false
  end)

  local comp = statusline.component(sess)
  T.ok(comp:find('Fast', 1, true) ~= nil, 'statusline reflects the new variant value: ' .. comp)
end)

-- ---------------------------------------------------------------------
-- 10b. :Mya model [value]: native-completion fast path over :Mya config.
-- ---------------------------------------------------------------------
T.test(':Mya model completes value ids and sets the model directly', function()
  local sess = new_session 'config_ag'
  vim.cmd.edit('mya://config_ag/' .. sess.id .. '/log')

  -- Completion covers the model option's value ids (not `mode`/`variant`).
  local cands = cmd.complete('', 'Mya model ', 10)
  local has_sonnet, has_opus, has_mode = false, false, false
  for _, c in ipairs(cands) do
    has_sonnet = has_sonnet or c == 'sonnet'
    has_opus = has_opus or c == 'opus'
    has_mode = has_mode or c == 'code' or c == 'chat'
  end
  T.ok(has_sonnet and has_opus, 'model value ids completed: ' .. vim.inspect(cands))
  T.ok(not has_mode, 'model completion must not leak mode/variant values: ' .. vim.inspect(cands))
  T.eq(cmd.complete('op', 'Mya model op', 12), { 'opus' }, 'arglead filters model candidates')

  -- `:Mya model opus` sets it directly — no vim.ui.select involved.
  local ok, err = pcall(cmd.run, { fargs = { 'model', 'opus' }, range = 0 })
  T.ok(ok, 'cmd.run must not raise: ' .. tostring(err))
  T.wait(3000, function()
    for _, o in ipairs(sess.config_options or {}) do
      if o.id == 'model' then
        return o.currentValue == 'opus'
      end
    end
    return false
  end)

  local comp = statusline.component(sess)
  T.ok(comp:find('claude%-opus') ~= nil, 'statusline reflects the new model: ' .. comp)
end)

-- ---------------------------------------------------------------------
-- 11. Spinner: while prompting, the log buffer has the working virt_lines
--     extmark (existence only — not asserting animation frames).
-- ---------------------------------------------------------------------
T.test('log: working indicator extmark present while prompting', function()
  local sess = new_session 'cancel_ag'
  vim.cmd.edit('mya://cancel_ag/' .. sess.id .. '/log')
  local bufnr = api.nvim_get_current_buf()

  sess:prompt({ { type = 'text', text = 'go' } }, function(_err, _stop) end)
  T.wait(2000, function()
    return sess.status == 'prompting'
  end)
  vim.wait(150) -- let attach/refresh + at least one spinner tick happen

  local st = log._state(bufnr)
  T.ok(st ~= nil)
  T.ok(st.spinner_mark_id ~= nil, 'expected a spinner extmark id recorded on the orchestrator state')

  local ns = api.nvim_create_namespace 'mya_log'
  local marks = api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local found = false
  for _, m in ipairs(marks) do
    local details = m[4]
    if details.virt_lines and #details.virt_lines > 0 then
      found = true
    end
  end
  T.ok(found, 'expected a virt_lines extmark for the working indicator')

  sess:cancel()
  T.wait(3000, function()
    return sess.status == 'idle'
  end)
end)

T.finish()
