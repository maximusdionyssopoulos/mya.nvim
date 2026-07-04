--- Plan view renderer (`mya://<agent>/<session>/plan`): the session's
--- current plan as a checkbox list. Full re-render on every plan change —
--- plans are small; incremental accounting isn't worth it here.

local M = {}

local api = vim.api

local NS = api.nvim_create_namespace 'mya_plan'

-- Shared groups also defined by ui/log.lua; `default = true` makes the
-- duplicate definition harmless whichever module loads first.
api.nvim_set_hl(0, 'MyaLogHeader', { link = 'Title', default = true })
api.nvim_set_hl(0, 'MyaLogMeta', { link = 'NonText', default = true })
api.nvim_set_hl(0, 'MyaLogToolTitle', { link = 'Function', default = true })

local CHECKBOX = { pending = '[ ]', in_progress = '[~]', completed = '[x]' }

--- { buf, sess, unsub } per buffer.
local states = {}

---@param sess mya.Session
---@return table? the (single, mutable) plan event, if any
local function find_plan(sess)
  local plan
  for _, ev in ipairs(sess.events) do
    if ev.kind == 'plan' then
      plan = ev
    end
  end
  return plan
end

local function render(st)
  if not api.nvim_buf_is_valid(st.buf) then
    return
  end
  local sess = st.sess
  local lines = { ('# Plan — %s'):format(sess.title or sess.id), '' }
  local hls = { { row = 0, group = 'MyaLogHeader' } }

  local plan = find_plan(sess)
  if plan and type(plan.entries) == 'table' and #plan.entries > 0 then
    for _, entry in ipairs(plan.entries) do
      local box = CHECKBOX[entry.status] or CHECKBOX.pending
      local pri = entry.priority == 'high' and ' (!)' or ''
      lines[#lines + 1] = ('%s%s %s'):format(box, pri, tostring(entry.content or ''))
      if entry.status == 'completed' then
        hls[#hls + 1] = { row = #lines - 1, group = 'MyaLogMeta' }
      elseif entry.status == 'in_progress' then
        hls[#hls + 1] = { row = #lines - 1, group = 'MyaLogToolTitle' }
      end
    end
  else
    lines[#lines + 1] = '— no plan —'
    hls[#hls + 1] = { row = #lines - 1, group = 'MyaLogMeta' }
  end

  vim.bo[st.buf].modifiable = true
  api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  vim.bo[st.buf].modified = false

  api.nvim_buf_clear_namespace(st.buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, st.buf, NS, h.row, 0, {
      end_row = h.row + 1,
      end_col = 0,
      hl_group = h.group,
    })
  end
end

--- Attach the plan renderer. Idempotent for the same buffer+session (no
--- duplicate subscription on :edit re-fire).
---@param bufnr integer
---@param sess mya.Session
function M.attach(bufnr, sess)
  local st = states[bufnr]
  if st and st.sess == sess then
    render(st)
    return
  end
  if st then
    M.detach(bufnr)
  end

  st = { buf = bufnr, sess = sess }
  states[bufnr] = st
  render(st)
  st.unsub = sess:subscribe(function(deltas)
    if not api.nvim_buf_is_valid(bufnr) then
      M.detach(bufnr)
      return
    end
    -- Re-render on plan appends/mutates and resets; an empty batch signals a
    -- header change (the title lives in our header line).
    local relevant = #deltas == 0
    for _, d in ipairs(deltas) do
      if d.type == 'reset' or (d.event and d.event.kind == 'plan') then
        relevant = true
        break
      end
    end
    if relevant then
      render(st)
    end
  end)
end

---@param bufnr integer
function M.detach(bufnr)
  local st = states[bufnr]
  if not st then
    return
  end
  states[bufnr] = nil
  if st.unsub then
    pcall(st.unsub)
  end
end

--- Test/introspection access.
---@param bufnr integer
---@return table?
function M._state(bufnr)
  return states[bufnr]
end

return M
