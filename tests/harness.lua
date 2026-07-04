--- Minimal, dependency-free test harness for `nvim -l` spec files.

local M = {}

local stats = { passed = 0, failed = 0, failures = {} }

--- Run one test. Failures are caught and recorded; execution continues.
---@param name string
---@param fn fun()
function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    stats.passed = stats.passed + 1
    io.stderr:write(('[PASS] %s\n'):format(name))
  else
    stats.failed = stats.failed + 1
    table.insert(stats.failures, { name = name, err = err })
    io.stderr:write(('[FAIL] %s: %s\n'):format(name, tostring(err)))
  end
end

--- Deep-equality assertion.
function M.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(('%sexpected %s, got %s'):format(msg and (msg .. ': ') or '', vim.inspect(b), vim.inspect(a)), 2)
  end
end

--- Boolean assertion.
function M.ok(cond, msg)
  if not cond then
    error(msg or 'expected condition to be truthy', 2)
  end
end

--- Pump the event loop with vim.wait until `predicate()` is true or
--- `timeout_ms` elapses; errors (failing the calling test) on timeout.
---@param timeout_ms integer
---@param predicate fun(): boolean
---@param interval_ms integer?
---@return boolean
function M.wait(timeout_ms, predicate, interval_ms)
  local ok = vim.wait(timeout_ms, predicate, interval_ms or 10)
  if not ok then
    error(('timed out after %dms waiting for predicate'):format(timeout_ms), 2)
  end
  return true
end

--- Print a summary and exit: cquit() (exit 1) if anything failed, exit 0
--- otherwise. Never returns.
function M.finish()
  io.stderr:write(('\n%d passed, %d failed\n'):format(stats.passed, stats.failed))
  if stats.failed > 0 then
    for _, f in ipairs(stats.failures) do
      io.stderr:write(('  FAIL %s: %s\n'):format(f.name, tostring(f.err)))
    end
    vim.cmd.cquit()
  else
    os.exit(0)
  end
end

return M
