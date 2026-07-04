--- Tiny shared ticker for the plain ASCII "working" indicators used by both
--- `ui/log.lua` (per-buffer working line) and `ui/dashboard.lua` (per-row
--- indicator column). One `vim.uv` timer for the whole plugin, ~120ms;
--- renderers register/unregister interest and get called with the current
--- frame on every tick. The timer itself only runs while at least one
--- renderer is registered (no interested spinner => no background timer).

local M = {}

M.FRAMES = { '-', '\\', '|', '/' }

local timer = nil
local frame_idx = 1
---@type table<any, fun(frame: string)>
local renderers = {}

local function tick()
  frame_idx = (frame_idx % #M.FRAMES) + 1
  local frame = M.FRAMES[frame_idx]
  -- Stable-order-agnostic snapshot: a renderer may unregister itself (or
  -- another) from within its own callback.
  local keys = {}
  for k in pairs(renderers) do
    keys[#keys + 1] = k
  end
  for _, k in ipairs(keys) do
    local fn = renderers[k]
    if fn then
      local ok, err = pcall(fn, frame)
      if not ok then
        local ok_util, util = pcall(require, 'mya.util')
        if ok_util then
          util.error('spinner', 'renderer error: ' .. tostring(err))
        end
      end
    end
  end
end

local function ensure_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(120, 120, function()
    vim.schedule(tick)
  end)
end

local function stop_timer()
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timer = nil
  end
end

--- Register interest in ticks under `key` (any stable identifier — a bufnr
--- works well). Starts the shared timer if it wasn't already running.
---@param key any
---@param fn fun(frame: string)
function M.register(key, fn)
  vim.validate { fn = { fn, 'function' } }
  renderers[key] = fn
  ensure_timer()
end

--- Drop interest registered under `key`. Stops the shared timer once nobody
--- is interested any more.
---@param key any
function M.unregister(key)
  renderers[key] = nil
  if not next(renderers) then
    stop_timer()
  end
end

--- The current frame (for immediate first-paint before the next tick).
---@return string
function M.current_frame()
  return M.FRAMES[frame_idx]
end

--- Test-only: whether the shared timer is currently running.
---@return boolean
function M._running()
  return timer ~= nil
end

return M
