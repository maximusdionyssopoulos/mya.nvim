--- JSON-RPC 2.0 over stdio, newline-delimited framing (ACP framing — NOT
--- LSP's Content-Length headers; see spec/notes.md).
---
--- A `Connection` wraps one spawned agent process. All uv callbacks
--- (stdout/stderr data, process exit) funnel through `vim.schedule` before
--- touching handler code or any nvim API; internal buffer bookkeeping (line
--- splitting) happens outside vim.schedule since it is plain Lua string
--- work, not a nvim API call, and we want partial chunks accumulated even if
--- the scheduled callback for a previous chunk hasn't run yet.

local util = require 'mya.util'

local M = {}

local uv = vim.uv

--- Synthetic error code used for transport-level failures (process exited
--- / write failed) that never got a real JSON-RPC error from the peer. We
--- reuse the standard JSON-RPC "Internal error" code (-32603) but always
--- tag `data.mya_transport = true` so callers can distinguish a genuine
--- peer-returned -32603 from our own synthetic one.
M.TRANSPORT_ERROR_CODE = -32603

--- Split `leftover .. chunk` into complete newline-delimited lines plus a
--- new leftover (the trailing partial line, possibly empty). Pure function,
--- no IO — exported for direct unit testing of partial-line robustness.
--- A trailing '\r' on a line (CRLF-emitting agents) is stripped.
---@param leftover string
---@param chunk string
---@return string[] lines
---@return string new_leftover
function M._parse_chunk(leftover, chunk)
  local data = leftover .. chunk
  local lines = {}
  local start = 1
  while true do
    local nl = data:find('\n', start, true)
    if not nl then
      break
    end
    local line = data:sub(start, nl - 1)
    if line:sub(-1) == '\r' then
      line = line:sub(1, -2)
    end
    lines[#lines + 1] = line
    start = nl + 1
  end
  return lines, data:sub(start)
end

---@class mya.rpc.Handlers
---@field requests table<string, fun(params: table?, respond: fun(result: table?, err: table?))>?
---@field notifications table<string, fun(params: table?)>?
---@field on_cancel_request (fun(request_id: integer|string))? -- called when peer sends $/cancel_request

---@class mya.rpc.Connection
---@field pid integer?
---@field exited boolean
---@field exit_code integer?
---@field exit_signal integer?
local Connection = {}
Connection.__index = Connection

---@param overrides table<string,string>?
---@return string[]? -- nil means "inherit parent env unchanged"
local function build_env(overrides)
  if not overrides or vim.tbl_isempty(overrides) then
    return nil
  end
  local merged = vim.fn.environ()
  for k, v in pairs(overrides) do
    merged[k] = v
  end
  local list = {}
  for k, v in pairs(merged) do
    list[#list + 1] = k .. '=' .. tostring(v)
  end
  return list
end

--- Encode and write one JSON-RPC message. No-op (with a warn log) if the
--- connection has already exited.
---@param obj table
function Connection:_send(obj)
  if self.exited then
    util.warn(self.log_id, ('send after exit dropped: %s'):format(obj.method or 'response'))
    return
  end
  local ok, encoded = pcall(vim.json.encode, obj)
  if not ok then
    util.error(self.log_id, 'failed to encode outgoing message: ' .. tostring(encoded))
    return
  end
  if util.rpc_trace_enabled() then
    util.rpc_trace(self.log_id, 'out: ' .. encoded)
  end
  -- vim.json.encode escapes embedded newlines in strings, so `encoded`
  -- itself is guaranteed newline-free; appending exactly one '\n' here is
  -- what makes the frame well-formed ndjson.
  uv.write(self.stdin, encoded .. '\n', function(err)
    if err then
      vim.schedule(function()
        util.error(self.log_id, 'stdin write error: ' .. tostring(err))
      end)
    end
  end)
end

--- Send a request. Returns the request id (also passed to any future
--- `conn:cancel(id)` call). `callback(err, result)`: `err` is either the
--- peer's JSON-RPC error object, or a synthetic transport error table (see
--- `M.TRANSPORT_ERROR_CODE`).
---@param method string
---@param params table?
---@param callback (fun(err: table?, result: table?))?
---@return integer? id nil if the connection has already exited
function Connection:request(method, params, callback)
  if self.exited then
    if callback then
      vim.schedule(function()
        callback({
          code = M.TRANSPORT_ERROR_CODE,
          message = '[mya] agent process has already exited',
          data = { mya_transport = true },
        }, nil)
      end)
    end
    return nil
  end
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = { callback = callback, method = method }
  self:_send { jsonrpc = '2.0', id = id, method = method, params = params }
  return id
end

--- Send a notification (no response expected).
---@param method string
---@param params table?
function Connection:notify(method, params)
  self:_send { jsonrpc = '2.0', method = method, params = params }
end

--- Ask the peer to cancel a request we sent earlier, via `$/cancel_request`.
---@param id integer
function Connection:cancel(id)
  self:notify('$/cancel_request', { requestId = id })
end

---@param msg table
function Connection:_dispatch(msg)
  if msg.method then
    if msg.id ~= nil then
      self:_dispatch_request(msg)
    else
      self:_dispatch_notification(msg)
    end
    return
  end

  -- Response: must correlate to a pending request.
  local id = msg.id
  local pending = id ~= nil and self.pending[id] or nil
  if not pending then
    util.warn(self.log_id, ('response for unknown/stale id %s'):format(vim.inspect(id)))
    return
  end
  self.pending[id] = nil
  if pending.callback then
    -- `luanil` decoding means an explicit JSON `null` result/error collapses
    -- to Lua nil, same as an absent key — msg.error ~= nil is still the
    -- correct success/failure discriminator since JSON-RPC never sets both.
    if msg.error ~= nil then
      pending.callback(msg.error, nil)
    else
      pending.callback(nil, msg.result)
    end
  end
end

---@param msg table
function Connection:_dispatch_notification(msg)
  local method, params = msg.method, msg.params
  if method == '$/cancel_request' then
    if self.handlers.on_cancel_request then
      local ok, err = pcall(self.handlers.on_cancel_request, params and params.requestId)
      if not ok then
        util.error(self.log_id, 'on_cancel_request handler error: ' .. tostring(err))
      end
    else
      util.debug(self.log_id, ('received $/cancel_request for id=%s'):format(vim.inspect(params and params.requestId)))
    end
    return
  end

  local handler = self.handlers.notifications and self.handlers.notifications[method]
  if handler then
    local ok, err = pcall(handler, params)
    if not ok then
      util.error(self.log_id, ('notification handler error for %s: %s'):format(method, tostring(err)))
    end
  else
    util.debug(self.log_id, 'unhandled notification: ' .. method)
  end
end

---@param msg table
function Connection:_dispatch_request(msg)
  local method, params, id = msg.method, msg.params, msg.id
  local responded = false
  local function respond(result, err)
    if responded then
      util.warn(self.log_id, ('double respond() for request id %s (%s) ignored'):format(vim.inspect(id), method))
      return
    end
    responded = true
    if err then
      self:_send { jsonrpc = '2.0', id = id, error = err }
    else
      -- JSON-RPC responses must carry a `result` key even when the value is
      -- null; vim.NIL round-trips through vim.json.encode as `null`.
      self:_send { jsonrpc = '2.0', id = id, result = result == nil and vim.NIL or result }
    end
  end

  local handler = self.handlers.requests and self.handlers.requests[method]
  if handler then
    local ok, err = pcall(handler, params, respond)
    if not ok then
      util.error(self.log_id, ('request handler error for %s: %s'):format(method, tostring(err)))
      respond(nil, { code = M.TRANSPORT_ERROR_CODE, message = 'handler error: ' .. tostring(err) })
    end
  else
    respond(nil, { code = -32601, message = 'Method not found: ' .. method })
  end
end

---@param line string
function Connection:_handle_line(line)
  if line == '' then
    return
  end
  if util.rpc_trace_enabled() then
    util.rpc_trace(self.log_id, 'in: ' .. line)
  end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= 'table' then
    util.warn(self.log_id, 'malformed JSON line, dropping: ' .. line)
    return
  end
  self:_dispatch(msg)
end

function Connection:_start_reading()
  self.stdout:read_start(function(err, chunk)
    if err then
      vim.schedule(function()
        util.error(self.log_id, 'stdout read error: ' .. tostring(err))
      end)
      return
    end
    if chunk == nil then
      return -- EOF; process exit is handled by the spawn on_exit callback
    end
    local lines
    lines, self._leftover = M._parse_chunk(self._leftover, chunk)
    if #lines == 0 then
      return
    end
    -- Schedule once per chunk (not per line) before touching handler code.
    vim.schedule(function()
      for _, line in ipairs(lines) do
        self:_handle_line(line)
      end
    end)
  end)
end

function Connection:_start_stderr()
  self.stderr:read_start(function(err, chunk)
    if err or not chunk then
      return
    end
    vim.schedule(function()
      util.warn(self.log_id .. ':stderr', (chunk:gsub('%s+$', '')))
    end)
  end)
end

--- Handle process exit exactly once: reject all pending requests, close
--- pipes, and invoke the user's on_exit callback. Always called on the main
--- loop.
---@param code integer
---@param signal integer
function Connection:_handle_exit(code, signal)
  if self._exit_handled then
    return
  end
  self._exit_handled = true
  self.exited = true
  self.exit_code = code
  self.exit_signal = signal

  if self._grace_timer then
    pcall(function()
      self._grace_timer:stop()
      self._grace_timer:close()
    end)
    self._grace_timer = nil
  end

  local pending = self.pending
  self.pending = {}
  for _, p in pairs(pending) do
    if p.callback then
      local ok, err = pcall(p.callback, {
        code = M.TRANSPORT_ERROR_CODE,
        message = '[mya] agent process exited before responding',
        data = { mya_transport = true, exit_code = code, exit_signal = signal },
      }, nil)
      if not ok then
        util.error(self.log_id, 'pending callback error during exit: ' .. tostring(err))
      end
    end
  end

  for _, h in ipairs { self.stdin, self.stdout, self.stderr } do
    if h and not h:is_closing() then
      h:close()
    end
  end

  util.info(self.log_id, ('process exited: code=%s signal=%s'):format(tostring(code), tostring(signal)))

  if self.on_exit then
    local ok, err = pcall(self.on_exit, code, signal)
    if not ok then
      util.error(self.log_id, 'on_exit handler error: ' .. tostring(err))
    end
  end
end

--- Immediate SIGKILL.
function Connection:kill()
  if self.handle and not self.handle:is_closing() then
    pcall(function()
      self.handle:kill 'sigkill'
    end)
  end
end

--- Graceful shutdown: close stdin (many agents treat EOF as "wrap up"), and
--- SIGKILL after `grace_ms` if the process hasn't exited by then.
---@param grace_ms integer?
function Connection:close(grace_ms)
  if self.exited or self.closing then
    return
  end
  self.closing = true
  grace_ms = grace_ms or 500

  if self.stdin and not self.stdin:is_closing() then
    pcall(uv.shutdown, self.stdin, function() end)
  end

  self._grace_timer = uv.new_timer()
  self._grace_timer:start(grace_ms, 0, function()
    self._grace_timer = nil
    if not self.exited then
      self:kill()
    end
  end)
end

--- Whether the connection is still usable (process running).
---@return boolean
function Connection:is_alive()
  return not self.exited
end

---@class mya.rpc.SpawnOpts
---@field command string
---@field args string[]?
---@field env table<string,string>?
---@field cwd string?
---@field handlers mya.rpc.Handlers?
---@field on_exit (fun(code: integer, signal: integer))?
---@field log_id string? -- tag used in log lines; defaults to `command`

--- Spawn an agent process and wire up a JSON-RPC connection over its
--- stdio. Never call nvim API from inside handler callbacks without going
--- through `respond`/the connection's own scheduling — that's handled here.
---@param opts mya.rpc.SpawnOpts
---@return mya.rpc.Connection
function M.spawn(opts)
  vim.validate {
    command = { opts.command, 'string' },
    args = { opts.args, { 'table', 'nil' } },
    env = { opts.env, { 'table', 'nil' } },
    cwd = { opts.cwd, { 'string', 'nil' } },
    handlers = { opts.handlers, { 'table', 'nil' } },
    on_exit = { opts.on_exit, { 'function', 'nil' } },
    log_id = { opts.log_id, { 'string', 'nil' } },
  }

  local self = setmetatable({}, Connection)
  self.log_id = opts.log_id or opts.command
  self.handlers = opts.handlers or {}
  self.on_exit = opts.on_exit
  self.pending = {}
  self.next_id = 1
  self._leftover = ''
  self.exited = false
  self.closing = false

  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  local handle, pid_or_err = uv.spawn(opts.command, {
    args = opts.args or {},
    stdio = { self.stdin, self.stdout, self.stderr },
    env = build_env(opts.env),
    cwd = opts.cwd,
  }, function(code, signal)
    vim.schedule(function()
      self:_handle_exit(code, signal)
    end)
  end)

  if not handle then
    pcall(function()
      self.stdin:close()
      self.stdout:close()
      self.stderr:close()
    end)
    error(('[mya] failed to spawn %q: %s'):format(opts.command, tostring(pid_or_err)), 2)
  end

  self.handle = handle
  self.pid = pid_or_err

  self:_start_reading()
  self:_start_stderr()

  util.info(self.log_id, ('spawned pid=%s: %s %s'):format(tostring(self.pid), opts.command, table.concat(opts.args or {}, ' ')))

  return self
end

M.Connection = Connection

return M
