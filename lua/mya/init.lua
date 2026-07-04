--- Public entrypoint. Phase 1: setup() + process teardown only — the
--- session/UI surface lands in later phases.

local M = {}

local did_autocmd = false

---@param opts mya.Config?
function M.setup(opts)
  local config = require 'mya.config'
  config.setup(opts)

  if not did_autocmd then
    did_autocmd = true
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = vim.api.nvim_create_augroup('mya_shutdown', { clear = true }),
      callback = function()
        require('mya.agent').stop_all()
      end,
      desc = '[mya] gracefully stop all agent processes on exit',
    })
  end
end

--- Statusline/winbar component for a session. Wire into your own statusline:
---   `:lua vim.o.statusline = "%{v:lua.require('mya').statusline()}"`
--- (the plain %{} form — %{%...%} would re-parse the '%' in "42% ctx")
--- With `bufnr` it resolves the session from an `mya://<agent>/<id>/<view>`
--- buffer name; without one (or when it can't resolve) it returns ''.
--- `suffix` is appended only when the component is non-empty — the built-in
--- statusline wiring uses it to space the component from the ruler.
---@param bufnr integer?
---@param suffix string?
---@return string
function M.statusline(bufnr, suffix)
  local sess, view
  if bufnr then
    local name = vim.api.nvim_buf_get_name(bufnr)
    local url = require('mya.url').parse(name)
    if url then
      view = url.view
      sess = require('mya.session').get(url.agent, url.session_id)
    end
  end
  local comp = require('mya.statusline').component(sess)

  -- Product decision: the log view's bar also shows the buffer's line
  -- count (a cheap, always-available signal distinct from the protocol-only
  -- statusline parts).
  if sess and view == 'log' and bufnr then
    local lines = ('%d lines'):format(vim.api.nvim_buf_line_count(bufnr))
    comp = (comp == '' or comp == '—') and lines or (comp .. ' · ' .. lines)
  end

  if suffix and comp ~= '' then
    comp = comp .. suffix
  end
  return comp
end

return M
