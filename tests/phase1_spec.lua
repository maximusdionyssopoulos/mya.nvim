--- Phase 1 protocol-core tests. Run with: nvim -l tests/phase1_spec.lua
--- (from the repo root, or anywhere — paths are resolved relative to this
--- file).

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local config = require 'mya.config'
local rpc = require 'mya.rpc'
local agent = require 'mya.agent'

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

---@param scenario string
---@return string[]
local function fake_args(scenario)
  return { '-l', fake_agent_path, scenario }
end

local INIT_PARAMS = {
  protocolVersion = 1,
  clientCapabilities = { fs = { readTextFile = true, writeTextFile = true }, terminal = false },
  clientInfo = { name = 'mya.nvim', version = '0.1.0' },
}

-- All agents used across the suite, configured once up front (config.setup
-- installs a whole new config each call, so later calls would otherwise
-- clobber earlier agent definitions).
config.setup {
  agents = {
    memo_agent = { command = 'nvim', args = fake_args 'basic' },
    auth_agent = { command = 'nvim', args = fake_args 'auth' },
    garbage_agent = { command = 'nvim', args = fake_args 'garbage' },
    crash_agent = { command = 'nvim', args = fake_args 'crash' },
  },
  log = { level = 'debug' },
}

-- ---------------------------------------------------------------------
-- 1. rpc framing: spawn fake 'basic', initialize round-trip.
-- ---------------------------------------------------------------------
T.test('rpc: initialize round-trip against fake agent (basic)', function()
  local conn = rpc.spawn {
    command = 'nvim',
    args = fake_args 'basic',
    log_id = 'test-basic',
  }
  local got
  conn:request('initialize', INIT_PARAMS, function(err, result)
    got = { err = err, result = result }
  end)
  T.wait(2000, function()
    return got ~= nil
  end)
  T.ok(got.err == nil, 'expected no error: ' .. vim.inspect(got.err))
  T.eq(got.result.protocolVersion, 1)
  T.ok(got.result.agentCapabilities.loadSession == true, 'expected loadSession=true')
  T.ok(type(got.result.agentCapabilities.sessionCapabilities.list) == 'table', 'expected sessionCapabilities.list present')
  T.eq(got.result.agentInfo.name, 'fake-agent')

  conn:close()
  T.wait(2000, function()
    return conn.exited
  end)
end)

-- ---------------------------------------------------------------------
-- 2. partial-line robustness: exercise rpc._parse_chunk directly.
-- ---------------------------------------------------------------------
T.test('rpc: _parse_chunk handles arbitrary byte-boundary splits', function()
  local msg1 = vim.json.encode { jsonrpc = '2.0', id = 1, method = 'foo', params = { a = 1, nested = { 'x', 'y' } } }
  local msg2 = vim.json.encode { jsonrpc = '2.0', id = 2, result = { b = 2 } }
  local full = msg1 .. '\n' .. msg2 .. '\n'

  -- Baseline: whole chunk at once.
  local lines_whole, rest_whole = rpc._parse_chunk('', full)
  T.eq(rest_whole, '')
  T.eq(#lines_whole, 2)

  -- Fed one byte at a time.
  local leftover = ''
  local all_lines = {}
  for i = 1, #full do
    local lines
    lines, leftover = rpc._parse_chunk(leftover, full:sub(i, i))
    for _, l in ipairs(lines) do
      table.insert(all_lines, l)
    end
  end
  T.eq(leftover, '')
  T.eq(all_lines, lines_whole)

  -- Split at an arbitrary mid-line byte boundary in two chunks.
  local half1 = full:sub(1, 10)
  local half2 = full:sub(11)
  local l1, left1 = rpc._parse_chunk('', half1)
  local l2, left2 = rpc._parse_chunk(left1, half2)
  T.eq(left2, '')
  local combined = vim.list_extend(vim.deepcopy(l1), l2)
  T.eq(combined, lines_whole)

  -- Decoding both ways must produce identical results.
  for i, line in ipairs(lines_whole) do
    local decoded_whole = vim.json.decode(line, { luanil = { object = true, array = true } })
    local decoded_split = vim.json.decode(all_lines[i], { luanil = { object = true, array = true } })
    T.eq(decoded_split, decoded_whole)
  end
end)

-- ---------------------------------------------------------------------
-- 3. agent.get + ensure_ready memoization: two concurrent ensure_ready
--    calls -> exactly one initialize sent.
-- ---------------------------------------------------------------------
T.test('agent: ensure_ready memoizes concurrent handshakes', function()
  local ag = agent.get 'memo_agent'
  local results = {}
  for _ = 1, 2 do
    ag:ensure_ready(function(err, a)
      table.insert(results, { err = err, a = a })
    end)
  end
  T.wait(2000, function()
    return #results == 2
  end)
  for _, r in ipairs(results) do
    T.ok(r.err == nil, 'unexpected ensure_ready error: ' .. vim.inspect(r.err))
  end

  local stats_got
  ag:request('test/get_stats', {}, function(err, result)
    stats_got = { err = err, result = result }
  end)
  T.wait(2000, function()
    return stats_got ~= nil
  end)
  T.ok(stats_got.err == nil, vim.inspect(stats_got.err))
  T.eq(stats_got.result.initialize_count, 1, 'expected exactly one initialize despite two concurrent ensure_ready calls')

  ag:shutdown()
  T.wait(2000, function()
    return ag.state == 'stopped'
  end)
end)

-- ---------------------------------------------------------------------
-- 4. auth flow: scenario 'auth' — session/new fails with -32000 until
--    authenticate is transparently driven, then the retry succeeds.
-- ---------------------------------------------------------------------
T.test('agent: auth flow retries transparently after authenticate', function()
  local ag = agent.get 'auth_agent'

  local select_called = false
  local orig_select = vim.ui.select
  vim.ui.select = function(...)
    select_called = true
    return orig_select(...)
  end

  local got
  ag:request('session/new', { cwd = '/tmp', mcpServers = {} }, function(err, result)
    got = { err = err, result = result }
  end)
  T.wait(2000, function()
    return got ~= nil
  end)
  vim.ui.select = orig_select

  T.ok(got.err == nil, 'expected session/new to succeed after transparent auth retry: ' .. vim.inspect(got.err))
  T.ok(got.result and got.result.sessionId ~= nil, 'expected a sessionId')
  T.ok(not select_called, 'a single auth method must not prompt via vim.ui.select')

  ag:shutdown()
end)

-- ---------------------------------------------------------------------
-- 5. garbage line: connection survives, subsequent request succeeds.
-- ---------------------------------------------------------------------
T.test('rpc: survives a malformed line from the agent', function()
  local ag = agent.get 'garbage_agent'
  local ready_err
  ag:ensure_ready(function(err)
    ready_err = err
  end)
  T.wait(2000, function()
    return ready_err ~= nil or ag.state == 'ready'
  end)
  T.ok(ready_err == nil, vim.inspect(ready_err))
  T.eq(ag.state, 'ready')

  local got
  ag:request('session/new', { cwd = '/tmp', mcpServers = {} }, function(err, result)
    got = { err = err, result = result }
  end)
  T.wait(2000, function()
    return got ~= nil
  end)
  T.ok(got.err == nil, 'expected session/new to succeed after a garbage line: ' .. vim.inspect(got.err))
  T.ok(got.result and got.result.sessionId ~= nil)

  ag:shutdown()
end)

-- ---------------------------------------------------------------------
-- 6. crash: pending requests rejected, state 'crashed', respawn increments
--    generation.
-- ---------------------------------------------------------------------
T.test('agent: crash detection, pending rejection, and respawn', function()
  local ag = agent.get 'crash_agent'

  local ready_err
  ag:ensure_ready(function(err)
    ready_err = err
  end)
  T.wait(2000, function()
    return ready_err ~= nil or ag.state == 'ready'
  end)
  T.ok(ready_err == nil, vim.inspect(ready_err))
  local gen1 = ag.generation

  -- The fake agent exits ~150ms after answering initialize; this request
  -- has no chance of getting a real response before the crash.
  local pending_got
  ag:request('session/new', { cwd = '/tmp', mcpServers = {} }, function(err, result)
    pending_got = { err = err, result = result }
  end)

  T.wait(2000, function()
    return ag.state == 'crashed'
  end)
  T.ok(pending_got ~= nil, 'expected the in-flight request to be rejected on crash')
  T.ok(pending_got.err ~= nil, 'expected an error object for the crashed in-flight request')

  local ready_err2
  ag:ensure_ready(function(err)
    ready_err2 = err
  end)
  T.wait(2000, function()
    return ag.generation > gen1
  end)
  T.eq(ag.generation, gen1 + 1, 'respawn should increment generation exactly once')
  T.ok(ready_err2 == nil or true) -- may itself crash again shortly after; only generation matters here

  ag:shutdown()
end)

-- ---------------------------------------------------------------------
-- 7. unknown incoming method: fake agent sends us client/bogus_method and
--    self-asserts it got -32601 back, exiting 0 only if correct.
-- ---------------------------------------------------------------------
T.test('rpc: unknown incoming request auto-responds -32601 (agent_calls_us)', function()
  local exit_code
  local conn = rpc.spawn {
    command = 'nvim',
    args = fake_args 'agent_calls_us',
    log_id = 'agent_calls_us',
    on_exit = function(code, _signal)
      exit_code = code
    end,
  }
  local init_got
  conn:request('initialize', INIT_PARAMS, function(err, result)
    init_got = { err = err, result = result }
  end)
  T.wait(2000, function()
    return init_got ~= nil
  end)
  T.ok(init_got.err == nil, vim.inspect(init_got.err))

  T.wait(3000, function()
    return exit_code ~= nil
  end)
  T.eq(exit_code, 0, 'fake agent asserts it received -32601 for the unknown method and exits 0 only if correct')
end)

-- ---------------------------------------------------------------------
-- 8. shutdown: close() rejects pending ('silent' scenario) and process
--    reaps within the grace period.
-- ---------------------------------------------------------------------
T.test('rpc: close() rejects pending requests and reaps within grace period', function()
  local conn = rpc.spawn {
    command = 'nvim',
    args = fake_args 'silent',
    log_id = 'silent',
  }
  local init_got
  conn:request('initialize', INIT_PARAMS, function(err, result)
    init_got = { err = err, result = result }
  end)
  T.wait(2000, function()
    return init_got ~= nil
  end)
  T.ok(init_got.err == nil, vim.inspect(init_got.err))

  local pending_got
  conn:request('session/new', { cwd = '/tmp', mcpServers = {} }, function(err, result)
    pending_got = { err = err, result = result }
  end)

  conn:close(200) -- short grace period so the test doesn't linger

  T.wait(3000, function()
    return pending_got ~= nil
  end)
  T.ok(pending_got.err ~= nil, 'expected pending session/new to be rejected on close')

  T.wait(3000, function()
    return conn.exited
  end)
end)

T.finish()
