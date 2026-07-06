--- The `mya://` URL scheme (tiny, pure). Phase 3's UI layer builds its
--- BufReadCmd routing and buffer registry on top of this; Phase 7's
--- statusline resolves a session from an mya:// buffer name through it.
---
--- Two shapes live under the scheme:
---   `mya://<agent>/<session>/<view>` — a session view; exactly three path
---     segments, none empty. `view` is `log` | `plan` (not enforced here;
---     the parser is purely structural so new views don't need a change).
---   `mya://dashboard`               — the session dashboard (`M.DASHBOARD`).
---     A scheme-level singleton, not tied to any agent/session, so it can't
---     collide with a session URL (those always have three segments).

local M = {}

--- The dashboard's URL. It rides the mya:// scheme (routed through the same
--- BufReadCmd as the session views) so `:edit!` re-reads it — that is how
--- the dashboard refreshes, the fugitive way, with no dedicated `R` map.
M.DASHBOARD = 'mya://dashboard'

--- Whether `str` is the dashboard URL.
---@param str any
---@return boolean
function M.is_dashboard(str)
  return str == M.DASHBOARD
end

---@class mya.Url
---@field agent string
---@field session_id string
---@field view string

--- Parse an mya:// URL into its parts. Returns nil for anything that is not
--- a well-formed three-segment mya:// URL (wrong scheme, missing segments,
--- empty segments, non-string input).
---@param str any
---@return mya.Url?
function M.parse(str)
  if type(str) ~= 'string' then
    return nil
  end
  local rest = str:match '^mya://(.+)$'
  if not rest then
    return nil
  end
  -- Exactly three non-empty, slash-free segments.
  local agent, session_id, view = rest:match '^([^/]+)/([^/]+)/([^/]+)$'
  if not agent then
    return nil
  end
  return { agent = agent, session_id = session_id, view = view }
end

--- Build an mya:// URL from its parts. Inverse of `parse` for well-formed
--- inputs.
---@param agent string
---@param session_id string
---@param view string
---@return string
function M.format(agent, session_id, view)
  return ('mya://%s/%s/%s'):format(agent, session_id, view)
end

return M
