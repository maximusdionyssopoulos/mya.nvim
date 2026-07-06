--- Prompt composition: the compose buffer attached to a session, plus the
--- content-block building and context staging shared with `:Mya send` /
--- `:Mya include` (`ui/cmd.lua`).
---
--- ## The compose buffer is a commit-message buffer, not a chat box
---
--- Composing a prompt follows the `gitcommit` model: `cc` (or bare
--- `:Mya send`) opens a plain `buftype=acwrite` scratch buffer named
--- `mya-compose://<agent>/<session>`, you edit it like any buffer, and
--- **`:w` submits** (BufWriteCmd). `:wq` submits and closes. There are no
--- insert-mode maps: <CR> stays <CR>, completion plugins attach through the
--- stable `mya-compose` filetype, and native `<C-x><C-f>` completes file
--- paths. Direct one-liners skip the buffer entirely: `:Mya send {text}`
--- (with cmdline history as the prompt history).
---
--- ## Context is staged explicitly, never parsed out of the text
---
--- `:{range}Mya include`, `:Mya include {path...}`, and `:{range}Mya send`
--- stage `resource` content blocks that attach to the next submission. They
--- show as REAL `# staged: <label>` comment lines at the bottom of the
--- compose buffer (gitcommit-style): delete a line to unstage that block,
--- and on submit those lines are stripped from the sent message. Only the
--- exact `# staged: ` prefix is magic — a markdown `# heading` in the draft
--- is ordinary prompt text and is sent as-is.
--- The plugin does NOT scan prompt text for `@path` tokens — `@foo` is sent
--- verbatim (it may well be an agent-side subagent mention); the vim way to
--- reference a file is an explicit include or a range.
---
--- ## Current-session resolution
---
--- `M.resolve(bufnr)`: a compose buffer targets its own session; an mya://
--- buffer targets that session; anything else targets the most recently
--- *entered* mya:// session buffer (tracked via a `BufEnter` autocmd
--- installed by `plugin/mya.lua`). This one ambient rule lets every `:Mya`
--- subcommand run from any buffer, fugitive-style.

local M = {}

local api = vim.api

---@type table<mya.Session, table> per-session compose buffer state: { buf, sess }
local compose_bufs = {}

---@type table<integer, table> bufnr -> compose state (reverse index)
local compose_bufs_by_buf = {}

---@type table<mya.Session, table[]> staged content blocks, cleared on next submit
local staged_blocks = {}

---@type integer? bufnr of the most recently BufEnter'd mya://.../log buffer
local last_session_buf = nil

-- Staged blocks show as REAL `# staged: <label>` lines at the bottom of the
-- compose buffer (git-style): the user deletes a line to unstage it, and the
-- managed lines are stripped from the submitted message. Only the exact
-- `# staged: ` prefix is stripped — a markdown `# heading` in the prompt is
-- real content. STAGED_NS carries the `Comment` highlight on the managed
-- lines (real lines, so highlighted via extmarks, not syntax).
local STAGED_PREFIX = '# staged: '
local STAGED_NS = api.nvim_create_namespace 'mya_prompt_staged'

-- ---------------------------------------------------------------------
-- Current-session tracking + resolution
-- ---------------------------------------------------------------------

--- Called from plugin/mya.lua's BufEnter autocmd on `mya://*` buffers.
---@param bufnr integer
function M._track(bufnr)
  local entry = require('mya.ui.buf').entry(bufnr)
  if entry and entry.view == 'log' and entry.sess then
    last_session_buf = bufnr
  end
end

--- The ambient "current session": most recently entered mya:// log buffer.
---@return mya.Session?
function M.current_session()
  if not last_session_buf or not api.nvim_buf_is_valid(last_session_buf) then
    return nil
  end
  local entry = require('mya.ui.buf').entry(last_session_buf)
  return entry and entry.sess or nil
end

--- Resolve the session an `:Mya` subcommand should act on, from `bufnr`
--- (default: current buffer) outward: compose buffer -> its session;
--- mya:// buffer -> that session; otherwise the ambient current session.
---@param bufnr integer?
---@return mya.Session?
function M.resolve(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local st = compose_bufs_by_buf[bufnr]
  if st then
    return st.sess
  end
  local entry = require('mya.ui.buf').entry(bufnr)
  if entry and entry.sess then
    return entry.sess
  end
  return M.current_session()
end

-- ---------------------------------------------------------------------
-- Staged content blocks
-- ---------------------------------------------------------------------

---@param sess mya.Session
---@param block table ContentBlock
---@param label string shown in the staged-line + notify
function M.stage(sess, block, label)
  local list = staged_blocks[sess]
  if not list then
    list = {}
    staged_blocks[sess] = list
  end
  list[#list + 1] = { block = block, label = label }
  vim.notify(('[mya] staged for next prompt: %s'):format(label), vim.log.levels.INFO)
  local st = compose_bufs[sess]
  if st then
    M._render_staged(st)
  end
end

---@param sess mya.Session
---@return table[] entries { block, label }
function M.staged(sess)
  return staged_blocks[sess] or {}
end

---@param sess mya.Session
function M.clear_staged(sess)
  staged_blocks[sess] = nil
  local st = compose_bufs[sess]
  if st then
    M._render_staged(st)
  end
end

--- Stage one file as a `resource` block (loaded-buffer content wins over
--- disk, same as fs/read_text_file). An optional `note` is the mini-review
--- instruction that travels WITH the file: it is prepended to the resource
--- text (so the agent reads it inline) and folded into the label / `name`.
---@param sess mya.Session
---@param path string relative (to session cwd) or absolute
---@param note string? annotation to attach to this include
function M.stage_file(sess, path, note)
  local abs = path
  if not abs:match '^/' then
    abs = (sess.cwd and sess.cwd ~= '' and sess.cwd or vim.fn.getcwd()) .. '/' .. abs
  end
  abs = vim.fn.fnamemodify(abs, ':p')

  local client = require 'mya.client'
  local text
  local buf = client.find_loaded_buf(abs)
  if buf then
    text = client.lines_to_text(api.nvim_buf_get_lines(buf, 0, -1, false))
  else
    local f = io.open(abs, 'r')
    if not f then
      error('[mya] include: no such file: ' .. abs, 0)
    end
    text = f:read '*a'
    f:close()
  end

  local rel = vim.fn.fnamemodify(abs, ':.')
  local label = rel
  if note and note ~= '' then
    label = rel .. ' — ' .. note
    text = ('%s:\n%s'):format(label, text)
  end
  local block = { type = 'resource', resource = { uri = 'file://' .. abs, text = text, name = label } }
  M.stage(sess, block, label)
end

--- Stage a line range of `bufnr` (default: current buffer) as a `resource`
--- block. This is what `:{range}Mya include` and `:{range}Mya send` share.
--- An optional `note` (the mini-review instruction) is folded into the
--- resource header, so the agent reads "<file> (<span>) — <note>:" above the
--- snippet.
---@param sess mya.Session
---@param line1 integer
---@param line2 integer
---@param bufnr integer?
---@param note string? annotation to attach to this range
function M.stage_range(sess, line1, line2, bufnr, note)
  bufnr = bufnr or 0
  local path = api.nvim_buf_get_name(bufnr)
  if path == '' then
    error('[mya] include: current buffer has no file name', 0)
  end
  local lines = api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
  local span = ('#L%d-L%d'):format(line1, line2)
  local rel = vim.fn.fnamemodify(path, ':.')
  local label = ('%s (%s)'):format(rel, span)
  if note and note ~= '' then
    label = label .. ' — ' .. note
  end
  local text = ('%s:\n%s'):format(label, table.concat(lines, '\n'))
  local block = {
    type = 'resource',
    resource = { uri = 'file://' .. path .. span, text = text, name = label },
  }
  M.stage(sess, block, label)
end

--- Split `:Mya include` fargs into file paths and an optional trailing note.
--- A literal `--` token is the paths/note separator (everything after it is
--- the note); with a range and no `--`, ALL args are the note (a range needs
--- no path). Otherwise the args are paths (the backward-compatible form).
---@param args string[]
---@param has_range boolean
---@return string[] paths, string? note
local function split_include_args(args, has_range)
  for i, a in ipairs(args) do
    if a == '--' then
      local paths, note = {}, {}
      for j = 1, i - 1 do
        paths[#paths + 1] = args[j]
      end
      for j = i + 1, #args do
        note[#note + 1] = args[j]
      end
      local n = table.concat(note, ' ')
      return paths, n ~= '' and n or nil
    end
  end
  if has_range then
    local n = table.concat(args, ' ')
    return {}, n ~= '' and n or nil
  end
  return args, nil
end

--- `:Mya include` implementation (called by `ui/cmd.lua`). `opts` is the
--- `nvim_create_user_command` callback table (for `.range`/`.line1`/`.line2`);
--- `args` is the subcommand's remaining fargs — file paths and/or a `--`
--- separated note (see `split_include_args`).
---@param opts table
---@param args string[]
function M.cmd_include(opts, args)
  local sess = M.resolve()
  if not sess then
    error('[mya] no current session; open one with :Mya or :Mya open', 0)
  end
  local has_range = opts.range and opts.range > 0
  local paths, note = split_include_args(args, has_range)
  if #paths > 0 then
    for _, p in ipairs(paths) do
      M.stage_file(sess, p, note)
    end
  elseif has_range then
    M.stage_range(sess, opts.line1, opts.line2, nil, note)
  else
    M.stage_file(sess, api.nvim_buf_get_name(0), note)
  end
end

-- ---------------------------------------------------------------------
-- Content-block building (shared by the compose submit + :Mya send)
-- ---------------------------------------------------------------------

--- Build the [ContentBlock] array for one prompt submission: the typed text,
--- then the session's staged blocks (cleared after this call). The text is
--- sent verbatim — no client-side `@` token parsing (see module doc).
---@param sess mya.Session
---@param text string
---@return table[]
function M.build_blocks(sess, text)
  local blocks = { { type = 'text', text = text } }
  for _, entry in ipairs(M.staged(sess)) do
    blocks[#blocks + 1] = entry.block
  end
  M.clear_staged(sess)
  return blocks
end

--- Send plain text (from `:Mya send` or the compose buffer). Notifies on a
--- busy-session error (concepts-v3: one prompt in flight, no queueing).
---@param sess mya.Session
---@param text string
function M.send_text(sess, text)
  local blocks = M.build_blocks(sess, text)
  sess:prompt(blocks, function(err, _stop)
    if err then
      vim.schedule(function()
        pcall(vim.notify, '[mya] ' .. tostring(err.message or vim.inspect(err)), vim.log.levels.WARN)
      end)
    end
  end)
end

-- ---------------------------------------------------------------------
-- Compose buffer (acwrite; :w submits)
-- ---------------------------------------------------------------------

--- Whether `bufnr` is one of our compose buffers.
---@param bufnr integer
---@return boolean
function M.is_prompt_buf(bufnr)
  return compose_bufs_by_buf[bufnr] ~= nil
end

--- The session a compose buffer belongs to, if any.
---@param bufnr integer
---@return mya.Session?
function M.session_for_buf(bufnr)
  local st = compose_bufs_by_buf[bufnr]
  return st and st.sess or nil
end

--- Re-apply the `Comment` highlight over every managed `# staged: ` line.
--- Real lines, so highlighted via extmarks rather than syntax. Idempotent;
--- called after any render/prune.
---@param st table
function M._highlight_staged(st)
  if not api.nvim_buf_is_valid(st.buf) then
    return
  end
  api.nvim_buf_clear_namespace(st.buf, STAGED_NS, 0, -1)
  local lines = api.nvim_buf_get_lines(st.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find('^# staged: ') then
      pcall(api.nvim_buf_set_extmark, st.buf, STAGED_NS, i - 1, 0, { line_hl_group = 'Comment' })
    end
  end
end

--- Re-render the managed `# staged:` lines: strip every existing one, then
--- append one per staged entry at the BOTTOM of the buffer (below the draft,
--- gitcommit-style). Only touches managed lines — the user's draft is never
--- clobbered. WRITES to the buffer, so must NOT be called from TextChanged
--- (see M._prune_staged). Called on stage()/clear_staged() and compose open.
---@param st table
function M._render_staged(st)
  if not api.nvim_buf_is_valid(st.buf) then
    return
  end
  local kept = {}
  for _, l in ipairs(api.nvim_buf_get_lines(st.buf, 0, -1, false)) do
    if not l:find('^# staged: ') then
      kept[#kept + 1] = l
    end
  end
  for _, e in ipairs(M.staged(st.sess)) do
    kept[#kept + 1] = STAGED_PREFIX .. e.label
  end
  api.nvim_buf_set_lines(st.buf, 0, -1, false, kept)
  M._highlight_staged(st)
end

--- Prune staged state to match the buffer after the user edits it: drop
--- entries whose `# staged:` line was deleted (or a user-typed bogus one that
--- matches no entry attaches nothing). Duplicate labels are legal (the same
--- range staged twice), so entries are matched against a multiset of the
--- surviving labels, keeping at most as many per label as there are lines and
--- preserving order. NEVER writes to the buffer — re-rendering from
--- TextChanged would fight the user's edit; it only prunes state, notifies
--- per dropped entry, and refreshes highlights.
---@param st table
function M._prune_staged(st)
  if not api.nvim_buf_is_valid(st.buf) then
    return
  end
  local entries = staged_blocks[st.sess]
  if not entries or #entries == 0 then
    M._highlight_staged(st)
    return
  end
  local surviving = {} -- label -> count of matching lines still in the buffer
  for _, l in ipairs(api.nvim_buf_get_lines(st.buf, 0, -1, false)) do
    local label = l:match '^# staged: (.*)$'
    if label then
      surviving[label] = (surviving[label] or 0) + 1
    end
  end
  local kept, dropped = {}, {}
  for _, e in ipairs(entries) do
    if (surviving[e.label] or 0) > 0 then
      surviving[e.label] = surviving[e.label] - 1
      kept[#kept + 1] = e
    else
      dropped[#dropped + 1] = e
    end
  end
  if #dropped > 0 then
    staged_blocks[st.sess] = #kept > 0 and kept or nil
    for _, e in ipairs(dropped) do
      vim.notify(('[mya] unstaged: %s'):format(e.label), vim.log.levels.INFO)
    end
  end
  M._highlight_staged(st)
end

---@param sess mya.Session
---@return table st
local function ensure_compose_buf(sess)
  local st = compose_bufs[sess]
  if st and api.nvim_buf_is_valid(st.buf) then
    return st
  end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  pcall(api.nvim_buf_set_name, buf, ('mya-compose://%s/%s'):format(sess.agent_name, sess.id))

  st = { buf = buf, sess = sess }
  compose_bufs[sess] = st
  compose_bufs_by_buf[buf] = st

  -- Set AFTER registering in compose_bufs_by_buf: FileType autocmds (user
  -- config, completion plugins) may call is_prompt_buf()/session_for_buf().
  vim.bo[buf].filetype = 'mya-compose'

  -- :w is the submit gesture (the gitcommit model). Submitting clears the
  -- draft; 'modified' is reset either way so :wq and :q behave normally.
  api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      -- Belt-and-braces prune in case no TextChanged fired since the last
      -- edit, then the message is every line EXCEPT the managed `# staged: `
      -- ones (markdown `# headings` are ordinary content and stay).
      M._prune_staged(st)
      local body = {}
      for _, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if not l:find('^# staged: ') then
          body[#body + 1] = l
        end
      end
      local message = table.concat(body, '\n')
      if vim.trim(message) ~= '' then
        api.nvim_buf_set_lines(buf, 0, -1, false, {})
        M.send_text(st.sess, message)
      end
      vim.bo[buf].modified = false
    end,
    desc = '[mya] :w submits the composed prompt',
  })

  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function()
      M._prune_staged(st)
    end,
    desc = '[mya] delete a `# staged:` line to unstage it (prune state, never re-render)',
  })

  local keys = require('mya.config').get({ soft = true }).keymaps.compose
  if keys.close then
    vim.keymap.set('n', keys.close, function()
      M.close(sess)
    end, { buffer = buf, nowait = true, desc = '[mya] close compose window' })
  end

  if keys.help then
    vim.keymap.set('n', keys.help, function()
      require('mya.ui.help').open 'mya-compose'
    end, { buffer = buf, nowait = true, desc = '[mya] open :help mya-compose' })
  end

  api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      compose_bufs[sess] = nil
      compose_bufs_by_buf[buf] = nil
    end,
  })

  return st
end

--- Open (or focus) the compose window for `sess`, split below the current
--- window. Public entry point for the log/review `cc` maps and bare
--- `:Mya send`.
---@param sess mya.Session
function M.open_for_session(sess)
  local st = ensure_compose_buf(sess)
  M._render_staged(st)

  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == st.buf then
      api.nvim_set_current_win(win)
      return
    end
  end

  vim.cmd 'belowright split'
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, st.buf)
  pcall(api.nvim_win_set_height, win, 8)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
end

--- `cc` map entry point from an mya:// log buffer: resolve the session from
--- the buffer, then delegate to `open_for_session`.
---@param bufnr integer
function M.open_for(bufnr)
  local entry = require('mya.ui.buf').entry(bufnr)
  if not entry or not entry.sess then
    vim.notify('[mya] open a session buffer first (:Mya, then <CR> on a session)', vim.log.levels.ERROR)
    return
  end
  M.open_for_session(entry.sess)
end

--- Close the window (not the buffer) showing a session's compose buffer.
---@param sess mya.Session
function M.close(sess)
  local st = compose_bufs[sess]
  if not st or not api.nvim_buf_is_valid(st.buf) then
    return
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == st.buf and #api.nvim_list_wins() > 1 then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

-- ---------------------------------------------------------------------
-- Config picker (`:Mya config` / `co` map)
-- ---------------------------------------------------------------------

--- `session/set_config_option` with the standard error notify. Shared by the
--- `:Mya config` picker and `:Mya model`.
---@param sess mya.Session
---@param opt_id string
---@param value any
local function set_option(sess, opt_id, value)
  sess:set_config_option(opt_id, value, function(err)
    if err then
      vim.schedule(function()
        pcall(vim.notify, '[mya] set_config_option failed: ' .. tostring(err.message or vim.inspect(err)), vim.log.levels.ERROR)
      end)
    end
  end)
end

--- Flatten a SessionConfigOption's `options` (handles the grouped
--- `SessionConfigSelectGroup` form: `{ name, options = [...] }`).
---@param options table[]?
---@return table[]
local function flatten_options(options)
  local flat = {}
  for _, o in ipairs(options or {}) do
    if o.value ~= nil then
      flat[#flat + 1] = o
    elseif type(o.options) == 'table' then
      for _, go in ipairs(o.options) do
        flat[#flat + 1] = go
      end
    end
  end
  return flat
end

--- `:Mya config` / `co`: vim.ui.select over `sess.config_options`, then over
--- that option's values, then `sess:set_config_option`. Falls back to a mode
--- picker (`session/set_mode`) when the agent has no config_options but does
--- have `_modes` (deprecated modes API, still-live per plan.lua).
---@param sess mya.Session
function M.config_picker(sess)
  local statusline = require 'mya.statusline'
  local co = sess.config_options

  if type(co) == 'table' and #co > 0 then
    vim.ui.select(co, {
      prompt = '[mya] config option:',
      format_item = function(opt)
        return ('%s: %s'):format(opt.name or opt.id, statusline.current_display(opt) or tostring(opt.currentValue))
      end,
    }, function(opt)
      if not opt then
        return
      end
      local values = flatten_options(opt.options)
      vim.ui.select(values, {
        prompt = ('[mya] %s:'):format(opt.name or opt.id),
        format_item = function(v)
          return v.name or v.value
        end,
      }, function(v)
        if not v then
          return
        end
        set_option(sess, opt.id, v.value)
      end)
    end)
    return
  end

  if type(sess._modes) == 'table' and #sess._modes > 0 then
    vim.ui.select(sess._modes, {
      prompt = '[mya] mode:',
      format_item = function(m)
        return m.name or m.id
      end,
    }, function(m)
      if not m then
        return
      end
      sess:set_mode(m.id, function(err)
        if err then
          vim.schedule(function()
            pcall(vim.notify, '[mya] set_mode failed: ' .. tostring(err.message or vim.inspect(err)), vim.log.levels.ERROR)
          end)
        end
      end)
    end)
    return
  end

  vim.notify('[mya] no config options or modes available for this session', vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------
-- Model picker (`:Mya model [value]`) — a fast path over `:Mya config`
-- ---------------------------------------------------------------------

--- The session's model config option plus its flattened value list, if the
--- agent advertises one (statusline's `is_model` heuristic).
---@param sess mya.Session
---@return table? opt, table[] values
local function model_option(sess)
  local opt = require('mya.statusline').model_option(sess)
  return opt, opt and flatten_options(opt.options) or {}
end

--- `:Mya model` completion candidates: the model option's value ids (stable,
--- space-free — the display `name` is not the completion surface).
---@param sess mya.Session
---@return string[]
function M.model_value_candidates(sess)
  local _, values = model_option(sess)
  local out = {}
  for _, v in ipairs(values) do
    if v.value ~= nil then
      out[#out + 1] = tostring(v.value)
    end
  end
  return out
end

--- `:Mya model [value]`. With `value`, set that model directly (matched by
--- value id against the model option's values — this is the native-completion
--- fast path). With no `value`, fall back to a `vim.ui.select` over just the
--- model values (the normal picker, scoped to model).
---@param sess mya.Session
---@param value string?
function M.set_model(sess, value)
  local opt, values = model_option(sess)
  if not opt then
    vim.notify('[mya] this session has no model config option (try :Mya config)', vim.log.levels.INFO)
    return
  end
  if value and value ~= '' then
    for _, v in ipairs(values) do
      if tostring(v.value) == value then
        set_option(sess, opt.id, v.value)
        return
      end
    end
    vim.notify(('[mya] no such model: %q'):format(value), vim.log.levels.ERROR)
    return
  end
  vim.ui.select(values, {
    prompt = ('[mya] %s:'):format(opt.name or opt.id),
    format_item = function(v)
      return v.name or v.value
    end,
  }, function(v)
    if v then
      set_option(sess, opt.id, v.value)
    end
  end)
end

--- Test/introspection: the compose buffer state for a session, if any.
---@param sess mya.Session
---@return table?
function M._state(sess)
  return compose_bufs[sess]
end

return M
