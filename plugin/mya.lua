if vim.fn.has("nvim-0.10") == 0 then
	vim.notify("[mya] requires Neovim >= 0.10", vim.log.levels.ERROR)
	return
end

if vim.g.loaded_mya then
	return
end
vim.g.loaded_mya = true

vim.api.nvim_create_autocmd("BufReadCmd", {
	group = vim.api.nvim_create_augroup("mya", { clear = true }),
	pattern = "mya://*",
	callback = function(ev)
		-- Lazy require: the UI layer only loads when an mya:// buffer is opened.
		require("mya.ui.buf").attach(ev.buf)
	end,
	desc = "[mya] route mya:// URLs to their view renderers",
})

-- Tracks the most-recently-entered mya://.../log buffer: the ambient
-- "current session" that session-scoped `:Mya` subcommands (send/include/
-- cancel/…) target when run from a buffer with no session of its own
-- (fugitive-style — like :Ggrep working from any buffer of the repo).
vim.api.nvim_create_autocmd("BufEnter", {
	group = vim.api.nvim_create_augroup("mya_track", { clear = true }),
	pattern = "mya://*",
	callback = function(ev)
		require("mya.ui.prompt")._track(ev.buf)
	end,
	desc = "[mya] track the ambient current session for :Mya subcommands",
})

vim.api.nvim_create_user_command("Mya", function(opts)
	-- Lazy require: reading config for defaults must not hard-crash even if
	-- setup() was never called; the dispatcher itself handles that gracefully.
	require("mya.ui.cmd").run(opts)
end, {
	desc = "[mya] dashboard / session commands",
	nargs = "*",
	range = true,
	complete = function(arglead, cmdline, cursorpos)
		return require("mya.ui.cmd").complete(arglead, cmdline, cursorpos)
	end,
})
