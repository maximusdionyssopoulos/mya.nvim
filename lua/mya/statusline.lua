--- Statusline/winbar component: a pure, cheap projection of in-memory session
--- state (config options + usage). No protocol calls, no UI/imports — just
--- formatting. Every part degrades to omission; only when NOTHING is
--- available does it return the lone em-dash placeholder.
---
--- Produces e.g. `claude-sonnet · high · 42% ctx · gemini · $0.13`.
--- Part order: model · effort · context% · agent · cost.

local M = {}

local SEP = ' · '

--- Currency code -> symbol for the common cases; anything else renders as
--- `<amount> <code>`.
local CURRENCY_SYMBOL = { USD = '$', EUR = '€', GBP = '£', JPY = '¥' }

--- The human display for a SessionConfigOption's current value: look up the
--- option in its `options` list (flat or grouped) whose `value` matches
--- `currentValue` and use that option's `name`; fall back to the raw value id.
---@param opt table?
---@return string?
local function current_display(opt)
  if type(opt) ~= 'table' then
    return nil
  end
  local cur = opt.currentValue
  if cur == nil then
    return nil
  end
  local options = opt.options
  if type(options) == 'table' then
    for _, o in ipairs(options) do
      if o.value == cur then
        return o.name or o.value
      end
      -- Grouped form (SessionConfigSelectGroup): { name, options = [...] }.
      if type(o.options) == 'table' then
        for _, go in ipairs(o.options) do
          if go.value == cur then
            return go.name or go.value
          end
        end
      end
    end
  end
  return tostring(cur)
end

--- Find the first config option matching `pred` (and not `exclude`).
---@param config_options table?
---@param pred fun(opt: table): boolean
---@param exclude table?
---@return table?
local function find_option(config_options, pred, exclude)
  if type(config_options) ~= 'table' then
    return nil
  end
  for _, opt in ipairs(config_options) do
    if opt ~= exclude and pred(opt) then
      return opt
    end
  end
  return nil
end

--- Heuristic: the "model" option is the one whose category is exactly `model`
--- or whose id contains `model`.
local function is_model(opt)
  local cat = (opt.category or ''):lower()
  local id = (opt.id or ''):lower()
  return cat == 'model' or id:find('model', 1, true) ~= nil
end

--- Heuristic: the "effort/thinking/mode" option. Uses substring matches for
--- the unambiguous terms and an *exact* match for `mode` (so it doesn't grab
--- the "model" option, since "model" contains "mode").
local function is_effort(opt)
  local cat = (opt.category or ''):lower()
  local id = (opt.id or ''):lower()
  local function has(s)
    return cat:find(s, 1, true) ~= nil or id:find(s, 1, true) ~= nil
  end
  return has 'effort' or has 'thinking' or has 'thought' or has 'reason' or cat == 'mode' or id == 'mode'
end

---@param cost table? { amount: number, currency: string }
---@return string?
local function format_cost(cost)
  if type(cost) ~= 'table' or type(cost.amount) ~= 'number' then
    return nil
  end
  local sym = CURRENCY_SYMBOL[cost.currency]
  if sym then
    return ('%s%.2f'):format(sym, cost.amount)
  end
  return ('%.2f %s'):format(cost.amount, cost.currency or '')
end

--- The model/effort/other-config-option display parts for a session, IN
--- ORDER (model, effort, then every other config option in listed order) —
--- no context%/agent/cost. Shared by `component()` (winbar/statusline) and
--- the dashboard row (which wants the same "known config" bit without the
--- usage/agent columns it renders separately).
---@param session mya.Session?
---@return string[]
function M.config_parts(session)
  if not session then
    return {}
  end
  local co = session.config_options
  local parts = {}

  local model_opt = find_option(co, is_model)
  local model = current_display(model_opt)
  if model then
    parts[#parts + 1] = model
  end

  local effort_opt = find_option(co, is_effort, model_opt)
  local effort = current_display(effort_opt)
  if effort then
    parts[#parts + 1] = effort
  end

  -- Product decision: show every OTHER config option too (e.g. a `variant`
  -- option), before the ctx%/agent/cost parts, in the order the agent listed
  -- them.
  if type(co) == 'table' then
    for _, opt in ipairs(co) do
      if opt ~= model_opt and opt ~= effort_opt then
        local disp = current_display(opt)
        if disp then
          parts[#parts + 1] = disp
        end
      end
    end
  end

  return parts
end

--- Public: the human display for a SessionConfigOption's current value (see
--- `current_display` above) — exposed for `ui/prompt.lua`'s config picker.
---@param opt table?
---@return string?
function M.current_display(opt)
  return current_display(opt)
end

--- Public: the session's "model" config option (same heuristic as the
--- statusline component), if the agent advertises one — for `:Mya model`.
---@param session mya.Session?
---@return table?
function M.model_option(session)
  return session and find_option(session.config_options, is_model) or nil
end

--- Build the component string for a session (or nil).
---@param session mya.Session? in-memory session (reads config_options, usage, agent_name)
---@return string
function M.component(session)
  if not session then
    return ''
  end

  local parts = M.config_parts(session)

  local usage = session.usage
  if usage and type(usage.used) == 'number' and type(usage.size) == 'number' and usage.size > 0 then
    parts[#parts + 1] = ('%d%% ctx'):format(math.floor(usage.used / usage.size * 100 + 0.5))
  end

  if session.agent_name then
    parts[#parts + 1] = session.agent_name
  end

  local cost = usage and format_cost(usage.cost)
  if cost then
    parts[#parts + 1] = cost
  end

  if #parts == 0 then
    return '—'
  end
  return table.concat(parts, SEP)
end

return M
