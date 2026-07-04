--- Logging and async-safety helpers shared across the mya.nvim modules.
---
--- Nothing in this module touches nvim API from a non-main-loop context; the
--- logger itself is written so that it is cheap to call from vim.schedule'd
--- callbacks (the common case) but never assumes it — file IO here goes
--- through vim.uv/io directly, which is safe from any context in Neovim.

local M = {}

---@alias mya.LogLevel "trace"|"rpc_trace"|"debug"|"info"|"warn"|"error"

-- Ordered so that `level_num(cur) <= level_num(msg)` means "log it".
-- rpc_trace is intentionally noisier than plain trace (full frame dumps).
local LEVELS = {
  trace = 1,
  rpc_trace = 1, -- alias: full-frame tracing gates on the same "trace" knob
  debug = 2,
  info = 3,
  warn = 4,
  error = 5,
}

local state = {
  level = LEVELS.info,
  file = nil, ---@type string?
  fd = nil, ---@type integer? -- luv fs fd, opened lazily/lazily-reopened
}

---@param level mya.LogLevel
local function level_num(level)
  return LEVELS[level] or LEVELS.info
end

--- Configure the logger. Safe to call multiple times (e.g. re-applied on
--- config.setup()). Does not itself open the file; that happens lazily on
--- first write so a configured-but-unused logger costs nothing.
---@param opts { level: mya.LogLevel?, file: string? }
function M.set_config(opts)
  opts = opts or {}
  if opts.level then
    state.level = level_num(opts.level)
  end
  if opts.file then
    if opts.file ~= state.file and state.fd then
      pcall(vim.uv.fs_close, state.fd)
      state.fd = nil
    end
    state.file = opts.file
  end
end

---@return string
local function default_path()
  return vim.fn.stdpath('log') .. '/mya.log'
end

local function ensure_fd()
  if state.fd then
    return state.fd
  end
  local path = state.file or default_path()
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p')
  local fd = vim.uv.fs_open(path, 'a', 438) -- 0666
  state.fd = fd
  return fd
end

local function fmt_line(level, tag, msg)
  return string.format(
    '%s [%s]%s %s\n',
    os.date('%Y-%m-%d %H:%M:%S'),
    level,
    tag and (' [' .. tag .. ']') or '',
    msg
  )
end

--- Write a log line if `level` is at or above the configured threshold.
--- Cheap no-op (single number compare) when below threshold.
---@param level mya.LogLevel
---@param tag string? free-form tag, e.g. an agent name
---@param msg string|fun():string either a preformatted string, or a
---  zero-arg function returning one (use the function form to avoid paying
---  for string.format on filtered-out log lines)
function M.log(level, tag, msg)
  if level_num(level) < state.level then
    return
  end
  if type(msg) == 'function' then
    msg = msg()
  end
  local fd = ensure_fd()
  if not fd then
    return
  end
  local line = fmt_line(level, tag, msg)
  -- fs_write is synchronous-capable when passed no callback; fine for a
  -- log file, and works from both uv callbacks and the main loop.
  pcall(vim.uv.fs_write, fd, line, -1)
end

function M.trace(tag, msg)
  M.log('trace', tag, msg)
end
function M.rpc_trace(tag, msg)
  M.log('rpc_trace', tag, msg)
end
function M.debug(tag, msg)
  M.log('debug', tag, msg)
end
function M.info(tag, msg)
  M.log('info', tag, msg)
end
function M.warn(tag, msg)
  M.log('warn', tag, msg)
end
function M.error(tag, msg)
  M.log('error', tag, msg)
end

--- True when rpc-trace (full in/out frame) logging is enabled, so callers
--- can skip building the frame dump string entirely when it is not.
---@return boolean
function M.rpc_trace_enabled()
  return state.level <= LEVELS.trace
end

--- Wrap `fn` so that however/whenever it is invoked (uv callback, timer,
--- etc.), the body always runs on the main loop via vim.schedule. Extra
--- args at call time are forwarded.
---@param fn function
---@return function
function M.schedule_wrap(fn)
  return function(...)
    local args = { ... }
    local n = select('#', ...)
    vim.schedule(function()
      fn(unpack(args, 1, n))
    end)
  end
end

--- Return the currently configured/default log file path (for :checkhealth
--- or a future `:Mya log` command).
---@return string
function M.log_path()
  return state.file or default_path()
end

return M
