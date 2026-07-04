--- Phase 8 (terminal capability) tests.
--- Run with: nvim -l tests/phase8_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local config = require 'mya.config'
local session = require 'mya.session'
local terminal = require 'mya.terminal'

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

---@param scenario string
---@return string[]
local function fake_args(scenario)
  return { '-l', fake_agent_path, scenario }
end

config.setup {
  agents = {
    term_ag = { command = 'nvim', args = fake_args 'terminal_flow' },
    trunc_ag = { command = 'nvim', args = fake_args 'terminal_truncate' },
    crash_ag = { command = 'nvim', args = fake_args 'terminal_crash' },
  },
  log = { level = 'debug' },
  notify = { turn_end = false, permission = false },
}

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
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

--- Find the terminalId embedded in a `{type='terminal', terminalId=...}`
--- content item anywhere in the session's tool_call events.
---@param sess mya.Session
---@return string?
local function find_terminal_id(sess)
  for _, ev in ipairs(sess.events) do
    if ev.kind == 'tool_call' then
      for _, c in ipairs(type(ev.content) == 'table' and ev.content or {}) do
        if type(c) == 'table' and c.type == 'terminal' and c.terminalId then
          return c.terminalId
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- 1. Round trip: create/output/wait_for_exit (exit code visible)/release.
-- ---------------------------------------------------------------------
T.test('terminal: create/output/wait_for_exit round-trip, exit code visible, release cleans up', function()
  local sess = new_session('term_ag', tmpdir())
  local done = start_prompt(sess)

  T.wait(3000, function()
    return done() ~= nil
  end)
  T.ok(done().err == nil, 'prompt errored: ' .. vim.inspect(done().err))
  T.eq(done().stop, 'end_turn')

  local term_id = find_terminal_id(sess)
  T.ok(term_id ~= nil, 'tool_call carried a terminal content item')

  -- The fake agent already asserted (agent-side) that:
  --   - terminal/create returned a terminalId
  --   - terminal/wait_for_exit resolved with exitCode == 3
  --   - the final terminal/output read back exactly "out"
  --   - terminal/release did not error
  -- Client-side: after release, the entry must be gone from the registry.
  T.eq(terminal.get('term_ag', sess.id, term_id), nil, 'released terminal is no longer known')
end)

-- ---------------------------------------------------------------------
-- 2. Output byte-limit truncation: keep only the last N bytes, flag it.
-- ---------------------------------------------------------------------
T.test('terminal: output ring buffer truncates from the front and flags truncated', function()
  local sess = new_session('trunc_ag', tmpdir())
  local done = start_prompt(sess)

  T.wait(3000, function()
    return done() ~= nil
  end)
  T.ok(done().err == nil, 'prompt errored: ' .. vim.inspect(done().err))
  T.eq(done().stop, 'end_turn')

  local term_id = find_terminal_id(sess)
  T.ok(term_id ~= nil, 'tool_call carried a terminal content item')

  local term = terminal.get('trunc_ag', sess.id, term_id)
  T.ok(term ~= nil, 'terminal still registered (this scenario never releases it)')
  T.eq(term.truncated, true)
  T.eq(term.output, '6789', 'only the last 4 bytes of "0123456789" are kept')
  T.eq(term.exited, true)
  T.eq(term.exit_status.exitCode, 0)
end)

-- ---------------------------------------------------------------------
-- 3. Agent crash kills every terminal it owns.
-- ---------------------------------------------------------------------
T.test('terminal: an agent crash kills its live terminals', function()
  local sess = new_session('crash_ag', tmpdir())
  local done = start_prompt(sess)

  -- Wait for the fake agent to have created its terminal (registered here
  -- client-side as soon as terminal/create is handled).
  local terms
  T.wait(3000, function()
    terms = terminal._for_session('crash_ag', sess.id)
    return next(terms) ~= nil
  end)
  local term_id = next(terms)
  T.eq(terms[term_id].exited, false, 'terminal is running before the crash')

  -- The agent process crashes ~80ms later; session.lua's on_crash hook marks
  -- the session errored, and the prompt callback resolves with a transport
  -- error either way -- both are the crash-propagation signal we wait on.
  T.wait(3000, function()
    return sess.status == 'error' or done() ~= nil
  end)

  T.wait(2000, function()
    local t = terminal.get('crash_ag', sess.id, term_id)
    return t ~= nil and t.exited == true
  end)
end)

T.finish()
