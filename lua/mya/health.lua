--- `:checkhealth mya` (Neovim's `lua/<name>/health.lua` convention — no extra
--- wiring needed beyond this file existing on the runtimepath).
---
--- Deliberately READ-ONLY: this module never spawns an agent process. A
--- configured-but-not-yet-started agent is reported as "not running yet";
--- users spawn it themselves by opening `:Mya` (concepts-v3: "the plugin
--- does nothing until configured... docs and :checkhealth mya need to make
--- the empty state obvious").

local M = {}

--- `vim.health.start/ok/warn/error/info` moved from `vim.health` (new) out of
--- the deprecated `vim.health.report_*` names somewhere around 0.10; this
--- plugin targets >=0.10 so the new names are always present.
---@return table
local function health()
  return vim.health
end

--- Whether an agent record already exists AND its connection is alive.
--- `agent.get()` itself never spawns (spawning is lazy, on
--- `ensure_ready`/`request`/`notify`), so calling it here is side-effect-free
--- even for an agent nobody has used yet this session.
---@param agent_mod table
---@param name string
---@return mya.Agent? live_agent
local function live_agent(agent_mod, name)
  local ok, ag = pcall(agent_mod.get, name)
  if not ok then
    return nil
  end
  if ag.state == 'ready' and ag.conn and ag.conn:is_alive() then
    return ag
  end
  return nil
end

--- Config options observed so far on any in-memory session for this agent
--- (there is no agent-level config-options concept in the protocol — only
--- per-session, from a `session/new`/`session/load` response). Read-only:
--- does not create a session to find out.
---@param session_mod table
---@param agent_name string
---@return table[]?
local function config_options_seen(session_mod, agent_name)
  for _, sess in ipairs(session_mod.all()) do
    if sess.agent_name == agent_name and type(sess.config_options) == 'table' and #sess.config_options > 0 then
      return sess.config_options
    end
  end
  return nil
end

function M.check()
  local h = health()
  h.start 'mya.nvim'

  if vim.fn.has 'nvim-0.10' == 1 then
    h.ok(('Neovim %s (>= 0.10 required)'):format(tostring(vim.version())))
  else
    h.error(('Neovim >= 0.10 is required; this is %s'):format(tostring(vim.version())))
  end

  local config = require 'mya.config'
  if not config.is_configured() then
    h.warn(
      'require("mya").setup() has not been called yet -- the plugin does nothing until configured (no :Mya dashboard, no agents).',
      {
        'Call require("mya").setup({ agents = { <name> = { command = "...", args = {...} } } }) from your config.',
        'See :help mya-setup for every option and a couple of ready-made agent recipes.',
      }
    )
    return
  end
  h.ok 'setup() has been called'

  local cfg = config.get()
  local names = {}
  for name in pairs(cfg.agents) do
    names[#names + 1] = name
  end
  table.sort(names)

  if #names == 0 then
    h.warn(
      'setup() was called with an empty agents table -- there is nothing to talk to.',
      { 'Add at least one entry under agents = { ... } (see :help mya-setup).' }
    )
    return
  end

  local agent_mod = require 'mya.agent'
  local session_mod = require 'mya.session'

  for _, name in ipairs(names) do
    local acfg = cfg.agents[name]
    h.info(('agent %q: %s %s'):format(name, acfg.command, table.concat(acfg.args or {}, ' ')))

    if vim.fn.executable(acfg.command) == 1 then
      h.ok(('%q: %q is executable'):format(name, acfg.command))
    else
      h.error(('%q: %q was not found on $PATH / is not executable'):format(name, acfg.command))
    end

    local ag = live_agent(agent_mod, name)
    if not ag then
      h.info(('%q: not running -- capabilities unknown (open :Mya to spawn)'):format(name))
    else
      h.ok(('%q: agent process is running (pid=%s)'):format(name, tostring(ag.conn and ag.conn.pid)))
      h.info(('  loadSession: %s'):format(tostring(ag:supports 'loadSession')))
      h.info(('  session list: %s'):format(tostring(ag:supports 'list')))
      local seen = config_options_seen(session_mod, name)
      if seen then
        h.info('  config options seen: ' .. vim.inspect(seen))
      else
        h.info '  config options seen: none yet (no session with config options opened this instance)'
      end
      if ag.info then
        h.info('  agentInfo: ' .. vim.inspect(ag.info))
      end
    end
  end
end

return M
