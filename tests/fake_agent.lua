--- Scriptable ACP agent for integration tests.
---
--- Run as: nvim -l tests/fake_agent.lua <scenario>
---
--- Speaks newline-delimited JSON-RPC 2.0 on real stdin/stdout using vim.uv
--- pipes opened on fds 0/1, driven by uv.run() — proven reliable here (see
--- dev notes) over a blocking io.read loop, mainly because several
--- scenarios need timers (delayed responses, self-timeouts) running
--- alongside the read loop.
---
--- IMPORTANT: nothing except protocol frames may go to stdout. All
--- diagnostics go to stderr.

-- Reuse the repo's own newline-delimited-JSON chunk splitter instead of
-- duplicating it.
local repo_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h')
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path
local parse_chunk = require('mya.rpc')._parse_chunk

local uv = vim.uv

local scenario_name = (arg and arg[1]) or 'basic'

local function log(msg)
  io.stderr:write(('[fake_agent:%s] %s\n'):format(scenario_name, tostring(msg)))
  io.stderr:flush()
end

local stdin = uv.new_pipe(false)
stdin:open(0)
local stdout = uv.new_pipe(false)
stdout:open(1)

--- Write one JSON-RPC object as a single ndjson frame.
local function send(obj)
  local ok, encoded = pcall(vim.json.encode, obj)
  if not ok then
    log('failed to encode outgoing message: ' .. tostring(encoded))
    return
  end
  uv.write(stdout, encoded .. '\n')
end

--- Write a raw (possibly malformed) line, for the `garbage` scenario.
local function send_raw(line)
  uv.write(stdout, line .. '\n')
end

--- Exit after a short delay so any just-queued uv.write() calls actually
--- flush to the pipe before the process disappears.
local function delayed_exit(code)
  local t = uv.new_timer()
  t:start(15, 0, function()
    os.exit(code)
  end)
end

-- ---------------------------------------------------------------------
-- Outgoing-request bookkeeping (for the agent_calls_us scenario, where we
-- originate a request to the client and need to correlate its response).
-- ---------------------------------------------------------------------

local next_out_id = 1
local outgoing_pending = {}

local function send_request(method, params, cb)
  local id = next_out_id
  next_out_id = next_out_id + 1
  outgoing_pending[id] = cb
  send { jsonrpc = '2.0', id = id, method = method, params = params }
end

-- ---------------------------------------------------------------------
-- Scenario state + method handlers
-- ---------------------------------------------------------------------

local ctx = {
  authenticated = false,
  initialize_count = 0,
  session_count = 0,
  sessions = {}, ---@type table<string, table> per-session scratch state (Phase 2 scenarios)
}

--- Send a session/update notification for `sid` with the given update table.
local function send_update(sid, update)
  send { jsonrpc = '2.0', method = 'session/update', params = { sessionId = sid, update = update } }
end

local function default_initialize_result()
  local result = {
    protocolVersion = 1,
    agentCapabilities = {
      loadSession = true,
      sessionCapabilities = { list = vim.empty_dict(), delete = vim.empty_dict() },
      promptCapabilities = { image = false, audio = false, embeddedContext = false },
    },
    agentInfo = { name = 'fake-agent', version = '0.0.1' },
    authMethods = {},
  }
  if scenario_name == 'auth' then
    result.authMethods = { { id = 'apikey', name = 'API key' } }
  end
  if scenario_name == 'no_list' then
    -- Phase 4: an agent that does NOT advertise session/list — the
    -- dashboard must show it as a "(no session listing)" group with only
    -- in-memory sessions. Also no delete/close: exercises the delete gating.
    result.agentCapabilities.sessionCapabilities = vim.empty_dict()
  end
  if scenario_name == 'close_only' then
    -- Opencode-shaped capabilities: list + close but NO delete (opencode's
    -- ACP layer as of 2026-07) — the dashboard must fall back to the
    -- configured session_delete_command CLI, closing the live session first.
    result.agentCapabilities.sessionCapabilities = { list = vim.empty_dict(), close = vim.empty_dict() }
  end
  return result
end

local function handle_initialize(_params, respond)
  ctx.initialize_count = ctx.initialize_count + 1
  local result = default_initialize_result()

  local function finish()
    respond(result)

    if scenario_name == 'garbage' then
      send_raw '{ this is not valid json ]'
    elseif scenario_name == 'crash' then
      -- Longer than the generic delayed_exit() so tests have a reliable
      -- window to get a request in flight before the process disappears.
      local t = uv.new_timer()
      t:start(150, 0, function()
        os.exit(1)
      end)
    elseif scenario_name == 'agent_calls_us' then
      send_request('client/bogus_method', {}, function(err, res)
        if err and err.code == -32601 then
          log 'assertion passed: got -32601 for unknown method as expected'
          delayed_exit(0)
        else
          log(('assertion FAILED: expected error code -32601, got err=%s result=%s'):format(vim.inspect(err), vim.inspect(res)))
          delayed_exit(1)
        end
      end)
      -- Safety net: don't hang forever if the client never answers.
      local timeout = uv.new_timer()
      timeout:start(5000, 0, function()
        log 'assertion FAILED: no response to client/bogus_method within timeout'
        os.exit(1)
      end)
    end
  end

  if scenario_name == 'slow' then
    local t = uv.new_timer()
    t:start(200, 0, finish)
  else
    finish()
  end
end

-- Phase 6 scenarios: driven from session/prompt; no hello-on-new update.
local PHASE6_SCENARIOS = {
  review_flow = true,
  fs_ops = true,
  fs_enoent = true,
  permission_select = true,
  permission_cancel = true,
}

-- Phase 8 (terminal capability) scenarios: also driven from session/prompt.
local PHASE8_SCENARIOS = {
  terminal_flow = true,
  terminal_truncate = true,
  terminal_crash = true,
}

local function handle_session_new(params, respond)
  if scenario_name == 'auth' and not ctx.authenticated then
    respond(nil, { code = -32000, message = 'authentication required' })
    return
  end
  ctx.session_count = ctx.session_count + 1

  local sid
  if scenario_name == 'session_basic' then
    sid = 'sess-1'
  elseif scenario_name == 'session_multi' then
    sid = 'sess-' .. ctx.session_count
  else
    sid = 'fake-session-' .. ctx.session_count
  end

  local result = { sessionId = sid }
  if scenario_name == 'session_basic' then
    ctx.sessions[sid] = {
      prompt_count = 0,
      configOptions = {
        {
          id = 'model',
          name = 'Model',
          type = 'select',
          currentValue = 'fast',
          options = { { value = 'fast', name = 'Fast' }, { value = 'smart', name = 'Smart' } },
        },
      },
    }
    result.configOptions = ctx.sessions[sid].configOptions
  elseif scenario_name == 'config_opts' then
    -- Phase 5: a session/new response advertising model + mode + variant
    -- config options, for the ":Mya config" / "co" picker + extended
    -- statusline tests.
    ctx.sessions[sid] = {
      prompt_count = 0,
      configOptions = {
        {
          id = 'model',
          name = 'Model',
          category = 'model',
          currentValue = 'sonnet',
          options = { { value = 'sonnet', name = 'claude-sonnet' }, { value = 'opus', name = 'claude-opus' } },
        },
        {
          id = 'mode',
          name = 'Mode',
          category = 'mode',
          currentValue = 'code',
          options = { { value = 'code', name = 'Code' }, { value = 'chat', name = 'Chat' } },
        },
        {
          id = 'variant',
          name = 'Variant',
          category = 'variant',
          currentValue = 'default',
          options = { { value = 'default', name = 'Default' }, { value = 'fast', name = 'Fast' } },
        },
      },
    }
    result.configOptions = ctx.sessions[sid].configOptions
  else
    ctx.sessions[sid] = { prompt_count = 0 }
  end
  -- Phase 6 scenarios build client-served fs/permission paths off the
  -- session cwd (from session/new params).
  ctx.sessions[sid].cwd = params and params.cwd
  respond(result)

  -- Legacy Phase 1 scenarios ('basic' etc.) expect a session/update on new;
  -- the Phase 2 'session_*' scenarios script their updates on prompt instead.
  if not scenario_name:match '^session_' and not PHASE6_SCENARIOS[scenario_name] and not PHASE8_SCENARIOS[scenario_name] then
    send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'hello from fake agent' } })
  end
end

local function handle_session_prompt(params, respond)
  local sid = params and params.sessionId
  local st = ctx.sessions[sid] or {}
  st.prompt_count = (st.prompt_count or 0) + 1

  if scenario_name == 'session_basic' then
    if st.prompt_count == 1 then
      send_update(sid, { sessionUpdate = 'agent_thought_chunk', content = { type = 'text', text = 'thinking' } })
      send_update(sid, { sessionUpdate = 'agent_thought_chunk', content = { type = 'text', text = ' hard' } })
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'Hello' } })
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = ' ' } })
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'world' } })
      send_update(sid, {
        sessionUpdate = 'tool_call',
        toolCallId = 'tc-1',
        title = 'read file',
        kind = 'read',
        status = 'in_progress',
        locations = { { path = '/tmp/x.lua', line = 3 } },
      })
      send_update(sid, {
        sessionUpdate = 'tool_call_update',
        toolCallId = 'tc-1',
        status = 'completed',
        content = { { type = 'content', content = { type = 'text', text = 'done' } } },
      })
      send_update(sid, {
        sessionUpdate = 'plan',
        entries = {
          { content = 'step one', priority = 'high', status = 'pending' },
          { content = 'step two', priority = 'low', status = 'pending' },
        },
      })
      send_update(sid, { sessionUpdate = 'usage_update', used = 1000, size = 200000, cost = { amount = 0.01, currency = 'USD' } })
      send_update(sid, { sessionUpdate = 'session_info_update', title = 'Test session' })
      send_update(sid, { sessionUpdate = 'available_commands_update', availableCommands = { { name = 'web', description = 'search' } } })
      respond { stopReason = 'end_turn' }
    else
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'again' } })
      respond { stopReason = 'end_turn' }
    end
  elseif scenario_name == 'session_cancel' then
    -- Stream a chunk every 50ms (20 total) until cancelled.
    local count = 0
    local timer = uv.new_timer()
    st.cancel_timer = timer
    st.respond = respond
    timer:start(50, 50, function()
      count = count + 1
      if count > 20 then
        timer:stop()
        pcall(function()
          timer:close()
        end)
        st.cancel_timer = nil
        if st.respond then
          st.respond { stopReason = 'end_turn' }
          st.respond = nil
        end
        return
      end
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'chunk' .. count } })
    end)
  elseif scenario_name == 'session_multi' then
    for i = 1, 3 do
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = sid .. '-' .. i } })
    end
    respond { stopReason = 'end_turn' }
  elseif scenario_name == 'session_crash' then
    -- Stream one chunk, then die without responding (mid-turn crash).
    send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'partial' } })
    local t = uv.new_timer()
    t:start(30, 0, function()
      os.exit(1)
    end)
  elseif scenario_name == 'review_flow' then
    -- Multi-file edit tool call -> request_permission -> (on allow) an
    -- fs/write for one of the accepted files -> tool_call_update -> end_turn.
    local cwd = st.cwd or '/tmp'
    local tcid = 'tc-edit-' .. st.prompt_count
    local rev_a_new = 'line1\nCHANGED\nline2\n'
    send_update(sid, {
      sessionUpdate = 'tool_call',
      toolCallId = tcid,
      title = 'edit files',
      kind = 'edit',
      status = 'pending',
      content = {
        { type = 'diff', path = cwd .. '/rev_a.txt', oldText = 'line1\nline2\n', newText = rev_a_new },
        -- No oldText (new file) + parent dir that does not exist yet.
        { type = 'diff', path = cwd .. '/sub/rev_b.txt', newText = 'new file\n' },
      },
    })
    send_request('session/request_permission', {
      sessionId = sid,
      toolCall = { toolCallId = tcid }, -- correlate-by-id: content lives on the tool_call update
      options = {
        { optionId = 'y', name = 'Allow', kind = 'allow_once' },
        { optionId = 'ya', name = 'Always', kind = 'allow_always' },
        { optionId = 'n', name = 'Deny', kind = 'reject_once' },
      },
    }, function(err, res)
      if err then
        log('assertion FAILED: request_permission errored: ' .. vim.inspect(err))
        delayed_exit(1)
        return
      end
      local oc = res and res.outcome
      if oc and oc.outcome == 'cancelled' then
        respond { stopReason = 'cancelled' }
      elseif oc and oc.outcome == 'selected' and (oc.optionId == 'y' or oc.optionId == 'ya') then
        -- Accepted: this write matches accepted unit content -> the client
        -- must answer success (already applied on accept).
        send_request('fs/write_text_file', { sessionId = sid, path = cwd .. '/rev_a.txt', content = rev_a_new }, function(werr)
          if werr then
            log('assertion FAILED: accepted-unit fs/write was rejected: ' .. vim.inspect(werr))
            delayed_exit(1)
            return
          end
          send_update(sid, { sessionUpdate = 'tool_call_update', toolCallId = tcid, status = 'completed' })
          respond { stopReason = 'end_turn' }
        end)
      else
        send_update(sid, { sessionUpdate = 'tool_call_update', toolCallId = tcid, status = 'failed' })
        respond { stopReason = 'end_turn' }
      end
    end)
  elseif scenario_name == 'fs_ops' then
    -- Reads served immediately (from a MODIFIED loaded buffer, honoring
    -- line+limit), then a permissionless fs/write that the client must hold.
    local cwd = st.cwd or '/tmp'
    send_request('fs/read_text_file', { sessionId = sid, path = cwd .. '/fs_read.txt', line = 2, limit = 2 }, function(err, res)
      local expected = 'EDITED\nline3\n'
      if err or not res or res.content ~= expected then
        log(('assertion FAILED: fs/read content mismatch: err=%s res=%s (expected %q)'):format(vim.inspect(err), vim.inspect(res), expected))
        delayed_exit(1)
        return
      end
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = res.content } })
      send_request('fs/write_text_file', { sessionId = sid, path = cwd .. '/fs_new.txt', content = 'written\n' }, function(werr)
        if werr then
          log('assertion FAILED: held fs/write was rejected: ' .. vim.inspect(werr))
          delayed_exit(1)
          return
        end
        respond { stopReason = 'end_turn' }
      end)
    end)
  elseif scenario_name == 'fs_enoent' then
    -- Read of a missing file must produce -32002 Resource not found.
    local cwd = st.cwd or '/tmp'
    send_request('fs/read_text_file', { sessionId = sid, path = cwd .. '/no_such_dir/nope.txt' }, function(err, res)
      if not (err and err.code == -32002) then
        log(('assertion FAILED: expected -32002 for missing file, got err=%s res=%s'):format(vim.inspect(err), vim.inspect(res)))
        delayed_exit(1)
        return
      end
      send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'enoent ok' } })
      respond { stopReason = 'end_turn' }
    end)
  elseif scenario_name == 'permission_select' then
    -- Execute-kind tool call, NO diff content: exercises the vim.ui.select
    -- fallback path client-side.
    local tcid = 'tc-exec-' .. st.prompt_count
    send_request('session/request_permission', {
      sessionId = sid,
      toolCall = { toolCallId = tcid, title = 'run tests', kind = 'execute', status = 'pending' },
      options = {
        { optionId = 'y', name = 'Allow', kind = 'allow_once' },
        { optionId = 'n', name = 'Deny', kind = 'reject_once' },
      },
    }, function(err, res)
      if err then
        log('assertion FAILED: request_permission errored: ' .. vim.inspect(err))
        delayed_exit(1)
        return
      end
      local oc = res and res.outcome
      if oc and oc.outcome == 'cancelled' then
        respond { stopReason = 'cancelled' }
      elseif oc and oc.outcome == 'selected' and oc.optionId == 'y' then
        send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'allowed' } })
        respond { stopReason = 'end_turn' }
      else
        respond { stopReason = 'end_turn' }
      end
    end)
  elseif scenario_name == 'permission_cancel' then
    -- Ask permission and never resend; the client is expected to cancel the
    -- turn, which MUST answer this request with outcome 'cancelled'.
    local cwd = st.cwd or '/tmp'
    local tcid = 'tc-cancel-' .. st.prompt_count
    send_request('session/request_permission', {
      sessionId = sid,
      -- Full ToolCallUpdate incl. diff content for an UNKNOWN toolCallId:
      -- exercises create-on-unknown-id in the client's merge path.
      toolCall = {
        toolCallId = tcid,
        title = 'edit file',
        kind = 'edit',
        status = 'pending',
        content = { { type = 'diff', path = cwd .. '/cancel_me.txt', oldText = 'a\n', newText = 'b\n' } },
      },
      options = {
        { optionId = 'y', name = 'Allow', kind = 'allow_once' },
        { optionId = 'n', name = 'Deny', kind = 'reject_once' },
      },
    }, function(err, res)
      local oc = res and res.outcome
      if err or not (oc and oc.outcome == 'cancelled') then
        log(('assertion FAILED: expected cancelled outcome, got err=%s res=%s'):format(vim.inspect(err), vim.inspect(res)))
        delayed_exit(1)
        return
      end
      respond { stopReason = 'cancelled' }
    end)
  elseif scenario_name == 'terminal_flow' then
    -- Full terminal/* round-trip: create -> embed in a tool_call_update ->
    -- poll output -> wait_for_exit (exit code visible) -> final output read
    -- -> release -> end_turn. Portable command (no reliance on GNU-isms).
    local tcid = 'tc-term-' .. st.prompt_count
    send_update(sid, {
      sessionUpdate = 'tool_call',
      toolCallId = tcid,
      title = 'run command',
      kind = 'execute',
      status = 'in_progress',
    })
    send_request('terminal/create', {
      sessionId = sid,
      command = 'sh',
      args = { '-c', 'printf out; exit 3' },
    }, function(err, res)
      if err or not (res and res.terminalId) then
        log('assertion FAILED: terminal/create errored: ' .. vim.inspect(err))
        delayed_exit(1)
        return
      end
      local term_id = res.terminalId
      send_update(sid, {
        sessionUpdate = 'tool_call_update',
        toolCallId = tcid,
        content = { { type = 'terminal', terminalId = term_id } },
      })
      -- Best-effort poll before exit (not asserted here — timing-dependent;
      -- the client-side spec asserts the round trip via the session log).
      send_request('terminal/output', { sessionId = sid, terminalId = term_id }, function(oerr)
        if oerr then
          log('assertion FAILED: terminal/output (pre-exit) errored: ' .. vim.inspect(oerr))
          delayed_exit(1)
          return
        end
        send_request('terminal/wait_for_exit', { sessionId = sid, terminalId = term_id }, function(werr, wres)
          if werr or not wres or wres.exitCode ~= 3 then
            log(('assertion FAILED: wait_for_exit expected exitCode 3, got err=%s res=%s'):format(vim.inspect(werr), vim.inspect(wres)))
            delayed_exit(1)
            return
          end
          send_request('terminal/output', { sessionId = sid, terminalId = term_id }, function(o2err, o2res)
            if o2err or not o2res or o2res.output ~= 'out' then
              log(('assertion FAILED: final terminal/output mismatch: err=%s res=%s'):format(vim.inspect(o2err), vim.inspect(o2res)))
              delayed_exit(1)
              return
            end
            send_request('terminal/release', { sessionId = sid, terminalId = term_id }, function(rerr)
              if rerr then
                log('assertion FAILED: terminal/release errored: ' .. vim.inspect(rerr))
                delayed_exit(1)
                return
              end
              send_update(sid, { sessionUpdate = 'tool_call_update', toolCallId = tcid, status = 'completed' })
              respond { stopReason = 'end_turn' }
            end)
          end)
        end)
      end)
    end)
  elseif scenario_name == 'terminal_truncate' then
    -- outputByteLimit smaller than the command's output: client must keep
    -- only the LAST `outputByteLimit` bytes and report truncated=true. Left
    -- registered (no release) so the client-side spec can inspect it.
    send_request('terminal/create', {
      sessionId = sid,
      command = 'sh',
      args = { '-c', 'printf 0123456789' },
      outputByteLimit = 4,
    }, function(err, res)
      if err or not (res and res.terminalId) then
        log('assertion FAILED: terminal/create (truncate) errored: ' .. vim.inspect(err))
        delayed_exit(1)
        return
      end
      local term_id = res.terminalId
      send_request('terminal/wait_for_exit', { sessionId = sid, terminalId = term_id }, function(werr)
        if werr then
          log('assertion FAILED: wait_for_exit (truncate) errored: ' .. vim.inspect(werr))
          delayed_exit(1)
          return
        end
        send_update(sid, {
          sessionUpdate = 'tool_call',
          toolCallId = 'tc-trunc-' .. st.prompt_count,
          title = 'truncated output',
          kind = 'execute',
          status = 'completed',
          content = { { type = 'terminal', terminalId = term_id } },
        })
        respond { stopReason = 'end_turn' }
      end)
    end)
  elseif scenario_name == 'terminal_crash' then
    -- Create a long-lived terminal, then crash (unexpected exit) without
    -- releasing it. The client is expected to notice the crash and kill the
    -- terminal itself (nothing else can ever reach that process again).
    send_request('terminal/create', {
      sessionId = sid,
      command = 'sh',
      args = { '-c', 'sleep 5' },
    }, function(err, res)
      if err or not (res and res.terminalId) then
        log('assertion FAILED: terminal/create (crash) errored: ' .. vim.inspect(err))
        os.exit(1)
        return
      end
      local t = uv.new_timer()
      t:start(80, 0, function()
        os.exit(1) -- simulate an unexpected crash mid-turn
      end)
    end)
  else
    respond { stopReason = 'end_turn' }
  end
end

local function handle_session_list(params, respond)
  -- session_load: two pages of one session each, to exercise pagination.
  -- updatedAt is "now" (UTC) so dashboard relative-time rendering has
  -- something deterministic ("just now") to assert against.
  local now = os.date '!%Y-%m-%dT%H:%M:%SZ'
  local cursor = params and params.cursor
  if not cursor then
    respond { sessions = { { sessionId = 'loaded-1', cwd = '/tmp', title = 'First', updatedAt = now } }, nextCursor = 'page2' }
  else
    respond { sessions = { { sessionId = 'loaded-2', cwd = '/tmp', title = 'Second', updatedAt = now } } }
  end
end

local function handle_session_load(params, respond)
  -- Replay a canned conversation as notifications BEFORE responding.
  local sid = params and params.sessionId
  send_update(sid, { sessionUpdate = 'user_message_chunk', content = { type = 'text', text = 'hi there' } })
  send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'replayed ' } })
  send_update(sid, { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'answer' } })
  send_update(sid, { sessionUpdate = 'tool_call', toolCallId = 'tc-load', title = 'ran cmd', kind = 'execute', status = 'completed' })
  respond(vim.empty_dict())
end

local function handle_set_config_option(params, respond)
  local st = ctx.sessions[params and params.sessionId]
  if st and st.configOptions then
    for _, opt in ipairs(st.configOptions) do
      if opt.id == params.configId then
        opt.currentValue = params.value
      end
    end
    respond { configOptions = st.configOptions }
  else
    respond { configOptions = {} }
  end
end

local function handle_session_delete(_params, respond)
  respond(vim.empty_dict())
end

local function handle_session_close(params, respond)
  ctx.close_count = (ctx.close_count or 0) + 1
  ctx.sessions[params and params.sessionId] = nil
  respond(vim.empty_dict())
end

local function handle_set_mode(params, respond)
  local st = ctx.sessions[params and params.sessionId]
  if st then
    st.currentModeId = params.modeId
  end
  respond(vim.empty_dict())
end

local function handle_authenticate(params, respond)
  if not (params and params.methodId) then
    respond(nil, { code = -32602, message = 'missing methodId' })
    return
  end
  ctx.authenticated = true
  respond(vim.empty_dict())
end

local function handle_get_stats(_params, respond)
  respond {
    initialize_count = ctx.initialize_count,
    session_count = ctx.session_count,
    close_count = ctx.close_count or 0,
  }
end

local handlers = {
  initialize = handle_initialize,
  ['session/new'] = handle_session_new,
  ['session/prompt'] = handle_session_prompt,
  ['session/list'] = handle_session_list,
  ['session/load'] = handle_session_load,
  ['session/set_config_option'] = handle_set_config_option,
  ['session/delete'] = handle_session_delete,
  ['session/close'] = handle_session_close,
  ['session/set_mode'] = handle_set_mode,
  authenticate = handle_authenticate,
  ['test/get_stats'] = handle_get_stats,
}

local function handle_request(id, method, params)
  local responded = false
  local function respond(result, err)
    if responded then
      return
    end
    responded = true
    if err then
      send { jsonrpc = '2.0', id = id, error = err }
    else
      send { jsonrpc = '2.0', id = id, result = result == nil and vim.empty_dict() or result }
    end
  end

  if (scenario_name == 'silent' or scenario_name == 'crash') and method ~= 'initialize' then
    -- silent: never answers anything past initialize, by design.
    -- crash: dies shortly after answering initialize; anything else that
    -- arrives in that window must go unanswered so it's the process exit
    -- (not a real response) that resolves it, matching a real crash.
    log(scenario_name .. ' scenario: intentionally not responding to ' .. method)
    return
  end

  local h = handlers[method]
  if h then
    h(params, respond)
  else
    respond(nil, { code = -32601, message = 'Method not found: ' .. method })
  end
end

local function handle_notification(method, params)
  if method == 'session/cancel' and scenario_name == 'session_cancel' then
    local st = ctx.sessions[params and params.sessionId]
    if st and st.cancel_timer then
      st.cancel_timer:stop()
      pcall(function()
        st.cancel_timer:close()
      end)
      st.cancel_timer = nil
    end
    if st and st.respond then
      st.respond { stopReason = 'cancelled' }
      st.respond = nil
    end
    return
  end
  if method == '$/cancel_request' then
    log('received $/cancel_request for id=' .. vim.inspect(params and params.requestId))
  else
    log('received notification: ' .. method)
  end
end

local function handle_response(msg)
  local cb = outgoing_pending[msg.id]
  if not cb then
    log('response for unknown outgoing id ' .. tostring(msg.id))
    return
  end
  outgoing_pending[msg.id] = nil
  cb(msg.error, msg.result)
end

local function handle_line(line)
  if line == '' then
    return
  end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= 'table' then
    log('received malformed line, ignoring: ' .. line)
    return
  end
  if msg.method then
    if msg.id ~= nil then
      handle_request(msg.id, msg.method, msg.params)
    else
      handle_notification(msg.method, msg.params)
    end
  else
    handle_response(msg)
  end
end

-- ---------------------------------------------------------------------
-- Read loop
-- ---------------------------------------------------------------------

local leftover = ''
stdin:read_start(function(err, chunk)
  if err then
    log('stdin read error: ' .. tostring(err))
    return
  end
  if chunk == nil then
    if scenario_name == 'silent' then
      log 'stdin EOF but silent scenario ignores it (forces caller to kill us)'
      return
    end
    log 'stdin EOF, exiting'
    os.exit(0)
    return
  end
  local lines
  lines, leftover = parse_chunk(leftover, chunk)
  for _, line in ipairs(lines) do
    handle_line(line)
  end
end)

log('starting scenario ' .. scenario_name)
uv.run()
