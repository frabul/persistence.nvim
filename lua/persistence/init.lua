local Config = require("persistence.config")

local uv = vim.uv or vim.loop

local M = {}
M._active = false

local e = vim.fn.fnameescape

---@param opts? {branch?: boolean}
function M.current(opts)
  opts = opts or {}
  local name = vim.fn.getcwd():gsub("[\\/:]+", "%%")
  if Config.options.branch and opts.branch ~= false then
    local branch = M.branch()
    if branch and branch ~= "main" and branch ~= "master" then
      name = name .. "%%" .. branch:gsub("[\\/:]+", "%%")
    end
  end
  return Config.options.dir .. name .. ".vim"
end

function M.setup(opts)
  Config.setup(opts)
  M.start()
end

function M.fire(event)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "Persistence" .. event,
  })
end

-- Check if a session is active
function M.active()
  return M._active
end

function M.start()
  M._active = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("persistence", { clear = true }),
    callback = function()
      M.fire("SavePre")

      if Config.options.need > 0 then
        local bufs = vim.tbl_filter(function(b)
          if vim.bo[b].buftype ~= "" or vim.tbl_contains({ "gitcommit", "gitrebase", "jj" }, vim.bo[b].filetype) then
            return false
          end
          return vim.api.nvim_buf_get_name(b) ~= ""
        end, vim.api.nvim_list_bufs())
        if #bufs < Config.options.need then
          return
        end
      end

      M.save()
      M.fire("SavePost")
    end,
  })
end

function M.stop()
  M._active = false
  pcall(vim.api.nvim_del_augroup_by_name, "persistence")
end

function M.save()
  vim.cmd("mks! " .. e(M.current()))
end

---@param opts? { last?: boolean }
function M.load(opts)
  opts = opts or {}
  ---@type string
  local file
  if opts.last then
    file = M.last()
  else
    file = M.current()
    if vim.fn.filereadable(file) == 0 then
      file = M.current({ branch = false })
    end
  end
  if file and vim.fn.filereadable(file) ~= 0 then
    M.fire("LoadPre")
    vim.cmd("silent! source " .. e(file))
    M.fire("LoadPost")
  end
end

---@return string[]
function M.list()
  local sessions = vim.fn.glob(Config.options.dir .. "*.vim", true, true)
  table.sort(sessions, function(a, b)
    return uv.fs_stat(a).mtime.sec > uv.fs_stat(b).mtime.sec
  end)
  return sessions
end

function M.last()
  return M.list()[1]
end

---@class session_item
---@field session string
---@field dir string
---@field branch? string
---
---@class session_picker_opts
---@field prompt string
---@field handler fun(item: session_item)
---@field allow_multi boolean

---@param opts session_picker_opts
function M.handle_selected(opts)
  -- create items
  ---@type { session: string, dir: string, branch?: string }[]
  local items = {}
  local have = {} ---@type table<string, boolean>
  for _, session in ipairs(M.list()) do
    if uv.fs_stat(session) then
      local file = session:sub(#Config.options.dir + 1, -5)
      local dir, branch = unpack(vim.split(file, "%%", { plain = true }))
      dir = dir:gsub("%%", "/")
      if jit.os:find("Windows") then
        dir = dir:gsub("^(%w)/", "%1:/")
      end
      if not have[dir] then
        have[dir] = true
        items[#items + 1] = { session = session, dir = dir, branch = branch }
      end
    end
  end
  -- sanitize handler
  local sanitized_handler = opts.handler
  opts.handler = function(item)
    if item then
      sanitized_handler(item)
    end
  end
  M.snacks_picker_wrapper(items, opts)
end

-- select a session to load
function M.select()
  M.handle_selected({
    prompt = "Select a session: ",
    allow_multi = false,
    handler = function(item)
      vim.fn.chdir(item.dir)
      M.load()
    end,
  })
end

-- select a session to delete
function M.delete()
  M.handle_selected({
    prompt = "Delete a session: ",
    allow_multi = true,
    handler = function(item)
      os.remove(item.session)
      print("Deleted " .. item.session)
    end,
  })
end

--- get current branch name
---@return string?
function M.branch()
  if uv.fs_stat(".git") then
    local ret = vim.fn.systemlist("git branch --show-current")[1]
    return vim.v.shell_error == 0 and ret or nil
  end
end

---@param items table
---@param opts session_picker_opts
function M.snacks_picker_wrapper(items, opts)
  local format_item = function(item)
    return vim.fn.fnamemodify(item.dir, ":p:~")
  end
  local title = opts.prompt
  title = title:gsub("^%s*", ""):gsub("[%s:]*$", "")
  local completed = false

  ---@type snacks.picker.select.Config
  ---@diagnostic disable-next-line: missing-fields
  local picker_opts = {
    source = "select",
    finder = function()
      local ret = {}
      for idx, item in ipairs(items) do
        local text = format_item(item)
        ---@type snacks.picker.finder.Item
        local it = type(item) == "table" and setmetatable({}, { __index = item }) or {}
        it.text = idx .. " " .. text
        it.item = item
        it.idx = idx
        ret[#ret + 1] = it
      end
      return ret
    end,
    format = Snacks.picker.format.ui_select({ format_item = format_item }),
    title = title,
    layout = {
      config = function(layout)
        -- Fit list height to number of items, up to 10
        for _, box in ipairs(layout.layout) do
          if box.win == "list" and not box.height then
            box.height = math.max(math.min(#items, vim.o.lines * 0.8 - 10), 2)
          end
        end
      end,
    },

    actions = {
      confirm = function(picker, item)
        if completed then
          return
        end
        completed = true

        local selected = {}
        if opts.allow_multi then
          -- Capture multi-selection BEFORE closing the picker
          selected = picker:selected() or {} -- returns {Item, ...}
        end

        picker:close()
        vim.schedule(function()
          if #selected > 0 then
            for _, it in ipairs(selected) do
              opts.handler(it.item)
            end
          else
            -- print("The item is " .. vim.inspect(item))
            opts.handler(item and item.item) -- single (legacy)
          end
        end)
      end,
    },

    on_close = function()
      if completed then
        return
      end
      completed = true
      vim.schedule(opts.handler) -- nil => cancelled
    end,
  }

  -- merge custom picker options
  ---@diagnostic disable-next-line: undefined-field
  if opts.snacks then
    picker_opts = Snacks.config.merge({}, vim.deepcopy(picker_opts), opts.snacks)
  end

  -- get full picker config
  picker_opts = Snacks.picker.config.get(picker_opts)

  -- merge kind options
  local kind_opts = picker_opts.kinds and picker_opts.kinds[opts.kind]
  if kind_opts then
    picker_opts = Snacks.config.merge({}, picker_opts, kind_opts)
  end

  Snacks.picker.pick(picker_opts)
end

return M
