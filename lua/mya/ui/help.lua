--- `g?` help: jump to the buffer's section of the real manual (`:help
--- mya-dashboard-maps` etc.), the way fugitive's `g?` opens fugitive-maps.
--- Real vimdoc is searchable, linked, and renders with the user's help
--- window preferences — no bespoke float.

local M = {}

--- Open `:help {tag}`; explain the fix if helptags were never generated
--- (plugin managers do this automatically; a manual checkout may not have).
---@param tag string e.g. 'mya-dashboard-maps'
function M.open(tag)
  local ok = pcall(vim.cmd.help, tag)
  if not ok then
    vim.notify(
      ('[mya] :help %s not found — generate helptags for the plugin\'s doc/ directory (:helptags ALL)'):format(tag),
      vim.log.levels.WARN
    )
  end
end

return M
