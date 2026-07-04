--- Headless smoke check: config.setup with a fake agent, ensure_ready, print
--- capabilities. Run with: nvim -l tests/smoke.lua

local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ':h:h')

package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local config = require 'mya.config'
local agent = require 'mya.agent'

local fake_agent_path = repo_root .. '/tests/fake_agent.lua'

config.setup {
  agents = {
    fake = { command = 'nvim', args = { '-l', fake_agent_path, 'basic' } },
  },
  log = { level = 'info' },
}

local done = false
local failed = false

local ag = agent.get 'fake'
ag:ensure_ready(function(err, a)
  done = true
  if err then
    failed = true
    io.stderr:write('[smoke] ensure_ready failed: ' .. vim.inspect(err) .. '\n')
    return
  end
  print('[smoke] capabilities: ' .. vim.inspect(a.capabilities))
  print('[smoke] agentInfo: ' .. vim.inspect(a.info))
  print('[smoke] auth_methods: ' .. vim.inspect(a.auth_methods))
end)

local waited = vim.wait(3000, function()
  return done
end)

if not waited then
  io.stderr:write '[smoke] timed out waiting for ensure_ready\n'
  os.exit(1)
end
if failed then
  os.exit(1)
end

ag:shutdown()
vim.wait(1000, function()
  return ag.state == 'stopped'
end)

print '[smoke] OK'
os.exit(0)
