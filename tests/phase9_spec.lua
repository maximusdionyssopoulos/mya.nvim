--- Phase 9 (polish & release) tests: health check, `:Mya log`, helptags.
--- Run with: nvim -l tests/phase9_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local config = require 'mya.config'
local health = require 'mya.health'

-- `:Mya` itself is wired by plugin/mya.lua, which normal plugin-loading
-- sources automatically; `nvim -l` scripts skip that, so source it by hand
-- (same pattern phase5_spec.lua uses).
vim.cmd('source ' .. repo_root .. '/plugin/mya.lua')

-- ---------------------------------------------------------------------
-- 1. Health check: unconfigured state.
-- ---------------------------------------------------------------------
T.test('health: check() runs without error before setup() is called', function()
  config._reset()
  local ok, err = pcall(health.check)
  T.ok(ok, 'health.check() errored: ' .. tostring(err))
  T.eq(config.is_configured(), false)
end)

-- ---------------------------------------------------------------------
-- 2. Health check: configured state, one executable-but-unstarted agent,
--    one agent with a bogus command (executable check must fail cleanly,
--    not error), all without ever spawning anything itself.
-- ---------------------------------------------------------------------
T.test('health: check() runs without error once configured (agent running + agent not found)', function()
  local fake_agent_path = repo_root .. '/tests/fake_agent.lua'
  config.setup {
    agents = {
      fake = { command = 'nvim', args = { '-l', fake_agent_path, 'basic' } },
      missing = { command = 'no_such_binary_mya_test_xyz' },
    },
    log = { level = 'info' },
  }

  -- Bring "fake" fully up so the health check exercises the
  -- already-running/capabilities-dump branch too.
  local agent = require 'mya.agent'
  local ag = agent.get 'fake'
  local ready = false
  ag:ensure_ready(function()
    ready = true
  end)
  T.wait(3000, function()
    return ready
  end)

  local ok, err = pcall(health.check)
  T.ok(ok, 'health.check() errored: ' .. tostring(err))

  ag:shutdown()
  T.wait(2000, function()
    return not (ag.conn and ag.conn:is_alive())
  end)
end)

-- ---------------------------------------------------------------------
-- 3. `:Mya log` must not error, whether or not a log file exists yet.
-- ---------------------------------------------------------------------
T.test(':Mya log opens (or notifies about) the trace log without erroring', function()
  -- Point the logger at a file that does not exist yet: must notify, not error.
  local util = require 'mya.util'
  local missing_path = vim.fn.tempname() .. '-mya-nolog.log'
  util.set_config { file = missing_path }

  local notified = nil
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    notified = { msg = msg, level = level }
  end
  local ok, err = pcall(vim.cmd, 'Mya log')
  vim.notify = orig_notify
  T.ok(ok, ':Mya log errored: ' .. tostring(err))
  T.ok(notified ~= nil and notified.msg:find('no log file yet', 1, true) ~= nil, 'expected a "no log file yet" notification')

  -- Now make the file exist (logger writes lazily on first message) and
  -- confirm :Mya log opens it in a split instead.
  util.info('test', 'hello')
  local win_count_before = #vim.api.nvim_list_wins()
  ok, err = pcall(vim.cmd, 'Mya log')
  T.ok(ok, ':Mya log errored on an existing file: ' .. tostring(err))
  T.ok(#vim.api.nvim_list_wins() > win_count_before, 'expected a new split window')
  T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'), vim.fn.fnamemodify(missing_path, ':p'))
  vim.cmd 'q'
end)

-- ---------------------------------------------------------------------
-- 4. helptags generation succeeds against the repo's doc/ directory (a
--    fresh temp copy, so the test never mutates the real doc/tags — though
--    committing a generated tags file is harmless, this keeps the test
--    side-effect-free).
-- ---------------------------------------------------------------------
T.test('doc/mya.txt: helptags generates cleanly (no duplicate/malformed tags)', function()
  local tmp_doc = vim.fn.tempname()
  vim.fn.mkdir(tmp_doc, 'p')
  local src = repo_root .. '/doc/mya.txt'
  T.ok(vim.fn.filereadable(src) == 1, 'doc/mya.txt is missing')
  vim.fn.writefile(vim.fn.readfile(src), tmp_doc .. '/mya.txt')

  local ok, err = pcall(vim.cmd, 'helptags ' .. vim.fn.fnameescape(tmp_doc))
  T.ok(ok, 'helptags failed: ' .. tostring(err))
  T.eq(vim.fn.filereadable(tmp_doc .. '/tags'), 1)

  -- No duplicate tags: every first column in the generated tags file is
  -- unique (a duplicate is exactly what makes real helptags runs noisy).
  local lines = vim.fn.readfile(tmp_doc .. '/tags')
  T.ok(#lines > 10, 'expected a substantial tags file, got ' .. #lines .. ' lines')
  local seen = {}
  for _, line in ipairs(lines) do
    local tag = line:match '^(%S+)\t'
    T.ok(tag ~= nil, 'malformed tags line: ' .. line)
    T.ok(not seen[tag], 'duplicate tag: ' .. tostring(tag))
    seen[tag] = true
  end
end)

T.finish()
