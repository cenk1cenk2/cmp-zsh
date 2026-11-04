local cmp = require'cmp'
local luv = require'luv'

local script_abspath = function()
  -- これでこの関数を呼出したファイルの絶対パスが取得できる
  -- pprint(debug.getinfo(2, 'S').source:sub(2))
  return debug.getinfo(2, 'S').source:sub(2)
end
local capture_script_path_base = script_abspath():match('(.*)/lua/cmp_zsh.lua$') .. '/bin/'

local M = {
  config = {
    zshrc = false,
    filetypes = {"*"},
    timeout = 3000,
  },
  env = {},
  capture_script_path = capture_script_path_base .. 'cmp_capture.zsh'
}

M.setup = function(opts)
  opts = vim.tbl_deep_extend('keep', opts, M.config)
  M.config = opts
  M.env = opts.env or {}

  local script = opts.zshrc and 'cmp_capture_zshrc.zsh' or 'cmp_capture.zsh'
  M.capture_script_path = capture_script_path_base .. script
end

M.new = function()
  local self = setmetatable({}, { __index = M })
  return self
end

M.get_keyword_pattern = function()
  return [[\S\+]]
end

-- -- 利用可能かどうかを返す
-- M.is_available = function()
--   return vim.bo.filetype == 'zsh'
-- end

local line = function(str)
  str = str:gsub('\r', '')
  local s, e, cap = string.find(str, '\n')
  if not s then
    return nil, str
  end
  local l = string.sub(str, 1, s - 1)
  local rest = string.sub(str, e + 1)
  return l, rest
end

-- LSP の仕様に沿ったものを返す
-- https://microsoft.github.io/language-server-protocol/specifications/specification-3-17/#completionItem
-- TODO: documentation
local result = function(words)
  local items = {}
  for _, v in ipairs(words) do
    -- table.insert(items, { label=v.label, documentation = v.documentation })
    table.insert(items, {
      label = v.label,
      documentation = v.documentation,
      dup = 0,
    })
  end
  return { items = items, isIncomplete = true }
end

-- luv replaces the whole environment when given one, so inherit nvim's and
-- layer the configured variables over it as NAME=value pairs
local environment = function(extra)
  local env = vim.tbl_extend('force', vim.fn.environ(), extra)
  local pairs_ = {}
  for k, v in pairs(env) do
    table.insert(pairs_, k .. '=' .. tostring(v))
  end
  return pairs_
end

local pipes = function()
  local stdin = luv.new_pipe(false)
  local stdout = luv.new_pipe(false)
  local stderr = luv.new_pipe(false)
  return { stdin, stdout, stderr }
end

M.complete = function(self, request, callback)
  -- local q = string.sub(request.context.cursor_before_line, request.offset)
  local q = request.context.cursor_before_line
  local stdioe = pipes()
  local handle, pid, timer
  local buf = ''
  local words = {}
  local superseded = false

  -- the capture script runs its own zsh in a pty, so signal the whole group
  local kill = function()
    if pid then
      pcall(luv.kill, -pid, 'sigterm')
    end
  end
  local cancel = function()
    superseded = true
    kill()
  end

  -- a newer request replaces this one; the zsh behind the old one has nothing
  -- left to answer and would otherwise run to completion on every keystroke
  if self.cancel_running then
    self.cancel_running()
  end

  do
    local spawn_params = {
      args = { self.capture_script_path, q },
      stdio = stdioe,
      env = environment(self.env),
      detached = true,
    }

    handle, pid = luv.spawn('zsh', spawn_params, function(code, signal)
      if timer then
        timer:stop()
        timer:close()
      end
      for _, pipe in ipairs(stdioe) do
        if not pipe:is_closing() then
          pipe:close()
        end
      end
      handle:close()
      if self.cancel_running == cancel then
        self.cancel_running = nil
      end
      if not superseded then
        vim.schedule_wrap(callback)(result(words))
      end
    end)

    if handle == nil then
      for _, pipe in ipairs(stdioe) do
        pipe:close()
      end
      vim.notify(string.format('cmp-zsh: starting zsh failed: %s', pid), vim.log.levels.ERROR)
      callback(result({}))
      return
    end

    self.cancel_running = cancel

    -- a completion function that never returns would leave zsh running forever
    timer = luv.new_timer()
    timer:start(M.config.timeout, 0, kill)

    -- drained so a chatty zsh cannot fill the pipe and block
    luv.read_start(stdioe[3], function() end)

    luv.read_start(stdioe[2], function(err, chunk)
      if err then
        return
      end
      if chunk then
        buf = buf .. chunk
      end
      while true do
        local l, rest = line(buf)
        if l == nil then
          break
        end
        buf = rest
        local pieces = vim.split(l, ' -- ', true)
        if pieces[1] ~= "" then
          if #pieces > 1 then
            table.insert(words, {label = pieces[1], documentation = pieces[2]})
          else
            table.insert(words, {label = pieces[1]})
          end
        end
      end
    end)
  end
end

M.is_available = function(self)
  return vim.deep_equal(self.config.filetypes, {"*"}) or vim.tbl_contains(self.config.filetypes, vim.bo.filetype)
end

return M
