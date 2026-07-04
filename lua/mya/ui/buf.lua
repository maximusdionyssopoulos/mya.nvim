--- mya:// buffer registry + BufReadCmd routing.
---
--- Every mya:// view is a real scratch buffer (buftype=nofile) resolved from
--- its URL: `mya://<agent>/<session>/<view>` with view = log | plan. The
--- registry maps bufnr -> { agent, session_id, view }; :edit re-fires
--- BufReadCmd and re-attaches idempotently (renderers keep their single
--- subscription); BufWipeout cleans up.
---
--- Resolution order (concepts-v3):
---   1. session in memory        -> render + subscribe
---   2. agent supports loadSession -> session/load with a loading line
---   3. neither                  -> in-buffer "not resumable" explanation

local url = require 'mya.url'

local M = {}

local api = vim.api

---@class mya.ui.BufEntry
---@field key string canonical mya:// URL
---@field agent string
---@field session_id string
---@field view "log"|"plan"
---@field sess mya.Session?
---@field live boolean renderer attached (session resolved)

---@type table<integer, mya.ui.BufEntry>
local registry = {}

local VIEWS = { log = true, plan = true }

--- Replace the whole buffer content around the nomodifiable option.
---@param bufnr integer
---@param lines string[]
local function write_lines(bufnr, lines)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
end

---@param bufnr integer
---@param view string?
local function set_common_opts(bufnr, view)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  if view == 'log' then
    vim.bo[bufnr].filetype = 'myalog'
  elseif view == 'plan' then
    vim.bo[bufnr].filetype = 'myaplan'
  end
end

--- Session info bar on mya:// windows, gated by config `ui.bar`:
---   'statusline' (default) — the stock statusline layout with the session
---     component right-aligned before the ruler, so it inherits the
---     colorscheme's StatusLine highlight and reads as the normal bar;
---   'winbar' — a separate bar at the top of the window;
---   false — nothing.
--- A %{...} expr keeps it fresh on every redraw (the log renderer calls
--- :redrawstatus on header-state deltas); the plain form — not %{%...%} — so
--- literal '%' in the component ("42% ctx") survives. The window-local
--- option is cleared on BufWinLeave so it doesn't leak onto other buffers
--- shown in the window.
---@param bufnr integer
local function setup_bar(bufnr)
  local ok, config = pcall(require, 'mya.config')
  local cfg = ok and config.get { soft = true } or {}
  local mode = cfg.ui and cfg.ui.bar
  if mode == false then
    return
  end
  local opt, expr
  if mode == 'winbar' then
    opt = 'winbar'
    expr = ("%%{v:lua.require'mya'.statusline(%d)}"):format(bufnr)
  else
    opt = 'statusline'
    expr = ("%%<%%f %%h%%w%%m%%r%%=%%{v:lua.require'mya'.statusline(%d,'  ')}%%-14.(%%l,%%c%%V%%) %%P"):format(bufnr)
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    pcall(api.nvim_set_option_value, opt, expr, { win = win })
  end
  local group = api.nvim_create_augroup('mya_bar_' .. bufnr, { clear = true })
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = bufnr,
    callback = function()
      pcall(api.nvim_set_option_value, opt, expr, { win = api.nvim_get_current_win() })
    end,
    desc = '[mya] session bar on mya:// windows',
  })
  api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = bufnr,
    callback = function()
      pcall(api.nvim_set_option_value, opt, '', { win = api.nvim_get_current_win() })
    end,
    desc = '[mya] restore the window bar when the mya:// buffer leaves',
  })
end

---@param bufnr integer
---@param entry mya.ui.BufEntry
local function attach_renderer(bufnr, entry)
  if entry.view == 'log' then
    require('mya.ui.log').attach(bufnr, entry.sess)
  else
    require('mya.ui.plan').attach(bufnr, entry.sess)
  end
end

--- Drop a buffer from the registry and detach its renderer/autocmds.
---@param bufnr integer
local function cleanup(bufnr)
  local entry = registry[bufnr]
  if not entry then
    return
  end
  registry[bufnr] = nil
  if entry.view == 'log' then
    pcall(function()
      require('mya.ui.log').detach(bufnr)
    end)
  elseif entry.view == 'plan' then
    pcall(function()
      require('mya.ui.plan').detach(bufnr)
    end)
  end
  pcall(api.nvim_del_augroup_by_name, 'mya_buf_' .. bufnr)
  pcall(api.nvim_del_augroup_by_name, 'mya_bar_' .. bufnr)
end

--- BufReadCmd entry point: parse the buffer name, register, resolve the
--- session, hand off to the view renderer. Safe to call repeatedly for the
--- same buffer (:edit) — re-attaches without duplicating subscriptions.
---@param bufnr integer
function M.attach(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local name = api.nvim_buf_get_name(bufnr)
  local parsed = url.parse(name)
  if not parsed then
    set_common_opts(bufnr, nil)
    write_lines(bufnr, { ('— invalid mya:// URL: %s —'):format(name) })
    return
  end
  if not VIEWS[parsed.view] then
    set_common_opts(bufnr, nil)
    write_lines(bufnr, {
      ('— unknown mya view %q —'):format(parsed.view),
      '  expected mya://<agent>/<session>/log or mya://<agent>/<session>/plan',
    })
    return
  end

  local key = url.format(parsed.agent, parsed.session_id, parsed.view)
  local existing = registry[bufnr]
  if existing and existing.key == key and existing.live then
    -- :edit re-fired BufReadCmd on an already-attached buffer: idempotent
    -- re-render, no new subscription.
    attach_renderer(bufnr, existing)
    return
  end
  if existing then
    cleanup(bufnr)
  end

  ---@type mya.ui.BufEntry
  local entry = {
    key = key,
    agent = parsed.agent,
    session_id = parsed.session_id,
    view = parsed.view,
    live = false,
  }
  registry[bufnr] = entry
  set_common_opts(bufnr, parsed.view)

  api.nvim_create_autocmd('BufWipeout', {
    group = api.nvim_create_augroup('mya_buf_' .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function()
      cleanup(bufnr)
    end,
    desc = '[mya] drop wiped mya:// buffer from the registry',
  })
  setup_bar(bufnr)

  local session = require 'mya.session'
  local sess = session.get(parsed.agent, parsed.session_id)
  if sess then
    entry.sess = sess
    entry.live = true
    attach_renderer(bufnr, entry)
    return
  end

  -- Not in memory. The agent may not even be configured (URL typed by hand).
  local okc = pcall(require('mya.config').get_agent, parsed.agent)
  if not okc then
    write_lines(bufnr, { ('— no agent named %q configured —'):format(parsed.agent) })
    return
  end

  -- Try session/load; the capability check happens inside session.load once
  -- the agent handshake settles.
  write_lines(bufnr, { ('— loading session %s from %s … —'):format(parsed.session_id, parsed.agent) })
  session.load(parsed.agent, parsed.session_id, function(err, loaded)
    if not api.nvim_buf_is_valid(bufnr) or registry[bufnr] ~= entry then
      return -- buffer wiped or re-pointed while loading
    end
    if err then
      if err.code == -32601 or tostring(err.message or ''):find('loadSession', 1, true) then
        -- concepts-v3 "list-but-no-load" consequence: nothing cached to show.
        write_lines(bufnr, {
          ('— session %s is not resumable —'):format(parsed.session_id),
          ('  agent %q does not support session/load, and no local transcript is kept'):format(parsed.agent),
          '  (sessions from this agent are view-only in the dashboard)',
        })
      else
        write_lines(bufnr, {
          ('— failed to load session %s: %s —'):format(parsed.session_id, tostring(err.message or vim.inspect(err))),
        })
      end
      return
    end
    entry.sess = loaded
    entry.live = true
    attach_renderer(bufnr, entry)
  end)
end

--- Open (or jump to) the mya:// view for a session.
---@param agent string
---@param session_id string
---@param view string? default 'log'
---@param opts { split: "current"|"split"|"vsplit"|"tab"? }?
---@return integer bufnr
function M.open(agent, session_id, view, opts)
  local u = url.format(agent, session_id, view or 'log')
  local split = (opts and opts.split) or 'current'
  local cmd = ({ current = 'edit', split = 'split', vsplit = 'vsplit', tab = 'tabedit' })[split] or 'edit'
  vim.cmd(('%s %s'):format(cmd, vim.fn.fnameescape(u)))
  return api.nvim_get_current_buf()
end

--- Registry lookup (dashboard/prompt phases + tests).
---@param bufnr integer
---@return mya.ui.BufEntry?
function M.entry(bufnr)
  return registry[bufnr]
end

return M
