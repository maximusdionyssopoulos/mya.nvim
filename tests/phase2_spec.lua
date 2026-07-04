--- Phase 2 (sessions & event log) + Phase 7 (usage/statusline/url) tests.
--- Run with: nvim -l tests/phase2_spec.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. repo_root .. '/tests/?.lua;' .. package.path
vim.opt.rtp:prepend(repo_root)

local T = require 'harness'
local config = require 'mya.config'
local session = require 'mya.session'
local statusline = require 'mya.statusline'
local url = require 'mya.url'

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
    crash_sess = { command = 'nvim', args = fake_args 'session_crash' },
  },
  log = { level = 'debug' },
  notify = { turn_end = false, permission = false },
}

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

---@param sess mya.Session
---@param blocks table[]
---@return table
local function prompt_and_wait(sess, blocks)
  local done
  sess:prompt(blocks, function(err, stop)
    done = { err = err, stop = stop }
  end)
  T.wait(3000, function()
    return done ~= nil
  end)
  return done
end

local function kinds_of(events)
  local ks = {}
  for _, e in ipairs(events) do
    ks[#ks + 1] = e.kind
  end
  return ks
end

-- ---------------------------------------------------------------------
-- 1. session.new + prompt: full event-log structure.
-- ---------------------------------------------------------------------
T.test('session: new + prompt produces the expected event log (session_basic)', function()
  local sess = new_session 'basic_sess'
  T.eq(sess.created_here, true)
  T.ok(sess.config_options ~= nil, 'expected configOptions from session/new')

  local done = prompt_and_wait(sess, { { type = 'text', text = 'hi' } })
  T.eq(done.stop, 'end_turn')
  T.eq(sess.status, 'idle')

  T.eq(kinds_of(sess.events), { 'turn', 'message', 'message', 'message', 'tool_call', 'plan', 'turn' })

  local turn_start = sess.events[1]
  T.eq(turn_start.phase, 'start')
  T.ok(turn_start.config_snapshot ~= nil, 'turn-start must capture config snapshot')
  T.eq(turn_start.config_snapshot.model, 'fast')

  T.eq(sess.events[2].role, 'user')
  T.eq(sess.events[2].content, 'hi')

  -- Thought and agent chunks each coalesced into ONE message event.
  T.eq(sess.events[3].role, 'thought')
  T.eq(sess.events[3].content, 'thinking hard')
  T.eq(sess.events[4].role, 'agent')
  T.eq(sess.events[4].content, 'Hello world')
  T.eq(sess.events[4].complete, true)

  local tc = sess.events[5]
  T.eq(tc.id, 'tc-1')
  T.eq(tc.status, 'completed') -- merged from in_progress -> completed
  T.eq(tc.title, 'read file')
  T.ok(tc.content ~= nil and #tc.content == 1, 'tool call content merged in')
  T.eq(tc.locations[1].path, '/tmp/x.lua')

  T.eq(sess.events[6].kind, 'plan')
  T.eq(#sess.events[6].entries, 2)

  T.eq(sess.events[7].phase, 'end')
  T.eq(sess.events[7].stop_reason, 'end_turn')

  T.eq(sess.usage.used, 1000)
  T.eq(sess.usage.size, 200000)
  T.eq(sess.title, 'Test session')
  T.ok(sess.available_commands ~= nil and sess.available_commands[1].name == 'web', 'available_commands recorded')
  T.ok(sess.pending_tool_calls['tc-1'] ~= nil, 'tool call registered in pending_tool_calls')
end)

-- ---------------------------------------------------------------------
-- 2. subscriber deltas: append + mutate observed, batched, coalescing.
-- ---------------------------------------------------------------------
T.test('session: subscriber deltas are batched with append + mutate', function()
  local sess = new_session 'basic_sess'

  local batches = {}
  local all = {}
  local unsub = sess:subscribe(function(deltas, _s)
    batches[#batches + 1] = deltas
    for _, d in ipairs(deltas) do
      all[#all + 1] = d
    end
  end)

  local done = prompt_and_wait(sess, { { type = 'text', text = 'hi' } })
  T.eq(done.stop, 'end_turn')
  -- Give any trailing scheduled flush a chance to run.
  vim.wait(100)
  unsub()

  local has_append, has_mutate, tc_mutates = false, false, 0
  local agent_msg_appends = 0
  for _, d in ipairs(all) do
    if d.type == 'append' then
      has_append = true
      if d.event.kind == 'message' and d.event.role == 'agent' then
        agent_msg_appends = agent_msg_appends + 1
      end
    elseif d.type == 'mutate' then
      has_mutate = true
      if d.event.kind == 'tool_call' then
        tc_mutates = tc_mutates + 1
      end
    end
  end

  T.ok(has_append, 'expected at least one append delta')
  T.ok(has_mutate, 'expected at least one mutate delta')
  T.ok(tc_mutates >= 1, 'expected >=1 mutate for the tool call (tc-1)')
  T.eq(agent_msg_appends, 1, 'the 3 agent chunks must coalesce to ONE message event (one append)')
  -- Batching: more individual deltas than callbacks fired.
  T.ok(#all > #batches, ('batching should coalesce deltas: %d deltas across %d batches'):format(#all, #batches))
end)

-- ---------------------------------------------------------------------
-- 3. cancellation: cancelled stopReason, status idle, no trailing events.
-- ---------------------------------------------------------------------
T.test('session: cancel mid-turn resolves with stopReason cancelled', function()
  local sess = new_session 'cancel_sess'

  local done
  sess:prompt({ { type = 'text', text = 'go' } }, function(err, stop)
    done = { err = err, stop = stop }
  end)

  -- Let some chunks stream in.
  vim.wait(120)
  T.eq(sess.status, 'prompting')
  sess:cancel()
  T.eq(sess.cancelling, true)

  T.wait(3000, function()
    return done ~= nil
  end)
  T.eq(done.stop, 'cancelled')
  T.eq(sess.status, 'idle')

  local count = #sess.events
  vim.wait(200)
  T.eq(#sess.events, count, 'no further events after the cancelled turn ended')
end)

-- ---------------------------------------------------------------------
-- 4. session/load: paginated list + replay through the same path + reset.
-- ---------------------------------------------------------------------
T.test('session: list_remote paginates and load replays with a reset delta', function()
  local listed
  session.list_remote('load_sess', function(err, sessions)
    listed = { err = err, sessions = sessions }
  end)
  T.wait(3000, function()
    return listed ~= nil
  end)
  T.ok(listed.err == nil, vim.inspect(listed.err))
  T.eq(#listed.sessions, 2, 'expected 2 sessions across 2 pages')

  local loaded
  local reset_seen = false
  session.load('load_sess', listed.sessions[1].sessionId, function(err, sess)
    loaded = { err = err, sess = sess }
    if sess then
      sess:subscribe(function(deltas)
        for _, d in ipairs(deltas) do
          if d.type == 'reset' then
            reset_seen = true
          end
        end
      end)
    end
  end)
  T.wait(3000, function()
    return loaded ~= nil
  end)
  T.ok(loaded.err == nil, vim.inspect(loaded.err))
  T.eq(loaded.sess.status, 'idle')

  local has_msg = false
  for _, e in ipairs(loaded.sess.events) do
    if e.kind == 'message' then
      has_msg = true
    end
  end
  T.ok(has_msg, 'replayed conversation must have produced message events')

  T.wait(2000, function()
    return reset_seen
  end)
  T.ok(reset_seen, 'a reset delta must fire after load replay completes')
end)

-- ---------------------------------------------------------------------
-- 5. multi-session routing: each log only holds its own chunks.
-- ---------------------------------------------------------------------
T.test('session: concurrent sessions route updates by sessionId', function()
  local s1 = new_session 'multi_sess'
  local s2 = new_session 'multi_sess'
  T.ok(s1.id ~= s2.id, 'distinct session ids')

  local d1, d2
  s1:prompt({ { type = 'text', text = 'a' } }, function(_e, stop)
    d1 = stop or 'done'
  end)
  s2:prompt({ { type = 'text', text = 'b' } }, function(_e, stop)
    d2 = stop or 'done'
  end)
  T.wait(3000, function()
    return d1 ~= nil and d2 ~= nil
  end)

  local function agent_text(sess)
    local buf = {}
    for _, e in ipairs(sess.events) do
      if e.kind == 'message' and e.role == 'agent' then
        buf[#buf + 1] = e.content
      end
    end
    return table.concat(buf, '')
  end

  local t1, t2 = agent_text(s1), agent_text(s2)
  T.ok(t1:find(s1.id, 1, true) ~= nil, 's1 log should contain its own id')
  T.ok(t1:find(s2.id, 1, true) == nil, 's1 log must NOT contain s2 chunks')
  T.ok(t2:find(s2.id, 1, true) ~= nil, 's2 log should contain its own id')
  T.ok(t2:find(s1.id, 1, true) == nil, 's2 log must NOT contain s1 chunks')
end)

-- ---------------------------------------------------------------------
-- 6. second prompt while prompting is rejected.
-- ---------------------------------------------------------------------
T.test('session: second prompt while prompting is rejected', function()
  local sess = new_session 'basic_sess'

  local first
  sess:prompt({ { type = 'text', text = 'one' } }, function(err, stop)
    first = { err = err, stop = stop }
  end)
  T.eq(sess.status, 'prompting') -- set synchronously

  local rejected
  sess:prompt({ { type = 'text', text = 'two' } }, function(err, _stop)
    rejected = err
  end)
  T.wait(1000, function()
    return rejected ~= nil
  end)
  T.ok(rejected ~= nil, 'second prompt must be rejected')
  T.ok(tostring(rejected.message):find('busy', 1, true) ~= nil, 'error should mention busy: ' .. vim.inspect(rejected))

  -- Let the first prompt finish so it doesn't leak into later tests.
  T.wait(3000, function()
    return first ~= nil
  end)
end)

-- ---------------------------------------------------------------------
-- 7. statusline.component formatting.
-- ---------------------------------------------------------------------
T.test('statusline: component formats all parts / degrades gracefully', function()
  local co = {
    { id = 'model', category = 'model', currentValue = 'sonnet', options = { { value = 'sonnet', name = 'claude-sonnet' } } },
    { id = 'effort', category = 'effort', currentValue = 'high', options = { { value = 'high', name = 'high' } } },
  }
  local full = {
    agent_name = 'gemini',
    config_options = co,
    usage = { used = 84000, size = 200000, cost = { amount = 0.13, currency = 'USD' } },
  }
  T.eq(statusline.component(full), 'claude-sonnet · high · 42% ctx · gemini · $0.13')

  local no_usage = { agent_name = 'gemini', config_options = co }
  T.eq(statusline.component(no_usage), 'claude-sonnet · high · gemini')

  T.eq(statusline.component(nil), '')
end)

-- ---------------------------------------------------------------------
-- 8. url parse/format round-trip + malformed inputs.
-- ---------------------------------------------------------------------
T.test('url: parse/format round-trip and malformed inputs', function()
  T.eq(url.parse 'mya://gemini/sess-1/log', { agent = 'gemini', session_id = 'sess-1', view = 'log' })
  T.eq(url.format('gemini', 'sess-1', 'log'), 'mya://gemini/sess-1/log')

  local f = url.format('claude', 'abc', 'plan')
  T.eq(url.parse(f), { agent = 'claude', session_id = 'abc', view = 'plan' })

  T.eq(url.parse 'notaurl', nil)
  T.eq(url.parse 'mya://only', nil)
  T.eq(url.parse 'mya://a/b', nil)
  T.eq(url.parse 'mya://a//c', nil)
  T.eq(url.parse '', nil)
  T.eq(url.parse(nil), nil)
  T.eq(url.parse(42), nil)
end)

-- ---------------------------------------------------------------------
-- 9. agent crash mid-prompt: status error, subscriber notified, cb errors.
-- ---------------------------------------------------------------------
T.test('session: agent crash mid-prompt errors the session', function()
  local sess = new_session 'crash_sess'

  local notified = false
  sess:subscribe(function(_deltas, _s)
    notified = true
  end)

  local pdone
  sess:prompt({ { type = 'text', text = 'go' } }, function(err, stop)
    pdone = { err = err, stop = stop }
  end)

  T.wait(4000, function()
    return pdone ~= nil
  end)
  T.ok(pdone.err ~= nil, 'prompt cb must receive an error on crash')

  T.wait(3000, function()
    return sess.status == 'error'
  end)
  T.eq(sess.status, 'error')
  T.ok(notified, 'subscribers must be notified around the crash')
end)

T.finish()
