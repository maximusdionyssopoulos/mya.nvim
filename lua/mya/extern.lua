--- Out-of-band agent operations: things an agent's own CLI can do that its
--- ACP surface doesn't (yet) expose. Deliberately OUTSIDE the protocol
--- modules — `agent.lua`/`session.lua` speak pure, capability-gated ACP; the
--- only coupling here is per-agent configuration and callers (the dashboard)
--- choosing this as a fallback when a capability is absent.
---
--- Motivating case: opencode implements `session/list` but not
--- `session/delete` (its ACP layer advertises `sessionCapabilities = {
--- close, fork, list, resume }` as of 2026-07), while `opencode session
--- delete <id>` deletes from the same storage its `session/list` reads.
--- Configure:
---
---   agents.opencode = {
---     command = 'opencode', args = { 'mya' },
---     session_delete_command = { 'opencode', 'session', 'delete', '{sessionId}' },
---   }
---
--- Deleting storage out-of-band doesn't tell the running agent process
--- anything: a session it still holds live would reappear in the next
--- `session/list`. So when the session is live here and the agent advertises
--- `sessionCapabilities.close`, `session/close` is sent first (best-effort)
--- so the agent lets go before the CLI removes it.

local config = require 'mya.config'
local util = require 'mya.util'

local M = {}

local PLACEHOLDER = '{sessionId}'

--- Whether an out-of-band delete command is configured for this agent.
---@param agent_name string
---@return boolean
function M.can_delete(agent_name)
  local ok, agent_cfg = pcall(config.get_agent, agent_name)
  return ok and agent_cfg.session_delete_command ~= nil
end

--- Resolve a `session_delete_command` spec to a concrete argv. List form:
--- every argument that is exactly '{sessionId}' is replaced; if none is, the
--- id is appended. Function form: called with the id, must return string[].
---@param spec string[]|fun(session_id: string): string[]
---@param session_id string
---@return string[]? argv
---@return string? err
local function build_argv(spec, session_id)
  if type(spec) == 'function' then
    local ok, argv = pcall(spec, session_id)
    if not ok then
      return nil, 'session_delete_command function errored: ' .. tostring(argv)
    end
    if type(argv) ~= 'table' or #argv == 0 or type(argv[1]) ~= 'string' then
      return nil, 'session_delete_command function must return a non-empty string[]'
    end
    return argv
  end
  local argv, substituted = {}, false
  for _, a in ipairs(spec) do
    if a == PLACEHOLDER then
      argv[#argv + 1] = session_id
      substituted = true
    else
      argv[#argv + 1] = a
    end
  end
  if not substituted then
    argv[#argv + 1] = session_id
  end
  return argv
end

---@param argv string[]
---@param agent_cfg mya.AgentConfig
---@param cb fun(err: table?)
local function run(argv, agent_cfg, cb)
  local ok, err = pcall(vim.system, argv, {
    text = true,
    cwd = agent_cfg.cwd,
    timeout = 30000,
  }, function(out)
    vim.schedule(function()
      if out.code == 0 then
        cb(nil)
        return
      end
      local detail = vim.trim((out.stderr or '') .. (out.stdout or ''))
      cb {
        message = ('`%s` exited %d%s'):format(
          table.concat(argv, ' '),
          out.code,
          detail ~= '' and (': ' .. detail) or ''
        ),
      }
    end)
  end)
  if not ok then
    -- vim.system throws synchronously when the executable doesn't exist.
    vim.schedule(function()
      cb { message = tostring(err) }
    end)
  end
end

--- Delete a session via the agent's configured CLI command. If the session
--- is live in this instance and the agent advertises
--- `sessionCapabilities.close`, `session/close` is sent first (best-effort:
--- a close failure is logged, not fatal) so the agent's live handle doesn't
--- resurrect the session in its next `session/list`. On CLI success the
--- session is dropped from the in-memory registry. `cb(err)` is always
--- called on the main loop.
---@param agent_name string
---@param session_id string
---@param cb fun(err: table?)
function M.delete_session(agent_name, session_id, cb)
  local ok, agent_cfg = pcall(config.get_agent, agent_name)
  local spec = ok and agent_cfg.session_delete_command or nil
  if not spec then
    vim.schedule(function()
      cb { message = ('[mya] no session_delete_command configured for %s'):format(agent_name) }
    end)
    return
  end
  local argv, argv_err = build_argv(spec, session_id)
  if not argv then
    vim.schedule(function()
      cb { message = '[mya] ' .. argv_err }
    end)
    return
  end

  local session = require 'mya.session' -- lazy: avoid module cycle at require time
  local function run_cli()
    util.debug(agent_name, 'extern delete: ' .. table.concat(argv, ' '))
    run(argv, agent_cfg, function(err)
      if err then
        cb(err)
        return
      end
      session.forget(agent_name, session_id)
      cb(nil)
    end)
  end

  local live = session.get(agent_name, session_id)
  if live and require('mya.agent').get(agent_name):supports 'close' then
    live:close(function(cerr)
      if cerr then
        util.debug(agent_name, 'extern delete: best-effort session/close failed: ' .. tostring(cerr.message))
      end
      run_cli()
    end)
  else
    run_cli()
  end
end

return M
