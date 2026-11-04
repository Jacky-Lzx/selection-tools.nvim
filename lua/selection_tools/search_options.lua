local M = {}
local cases = { smart = "sensitive", sensitive = "ignore", ignore = "smart" }

function M.set(picker, changes)
  if picker.closed or not picker.opts.search_options then
    return false
  end
  local values = {}
  for name, value in pairs(changes) do
    if name == "cwd" then
      assert(type(value) == "string" and value ~= "", "cwd must be a directory")
      value = vim.fn.expand(value)
      if not value:match("^[/\\]") and not value:match("^%a:[/\\]") then
        value = vim.fs.joinpath(picker.opts.cwd, value)
      end
      value = vim.uv.fs_realpath(value)
      assert(value and vim.fn.isdirectory(value) == 1, "cwd must be an existing directory")
    elseif name == "globs" then
      assert(type(value) == "table" and vim.islist(value), "globs must be a list")
      for _, glob in ipairs(value) do
        assert(type(glob) == "string" and glob ~= "" and not glob:find("%z"), "invalid glob")
      end
    elseif name == "case" then
      assert(cases[value], "case must be smart, sensitive or ignore")
    elseif name == "regex" or name == "hidden" or name == "ignored" then
      assert(type(value) == "boolean", name .. " must be boolean")
    else
      error("Unknown search option: " .. name)
    end
    values[name] = value
  end
  for name, value in pairs(values) do
    picker.opts[name] = vim.deepcopy(value)
    picker.opts.source_opts = picker.opts.source_opts or {}
    picker.opts.source_opts[name] = vim.deepcopy(value)
  end
  picker:_find()
  return true
end

function M.label(opts)
  local flags = {}
  if opts.source == "grep" then
    flags = { opts.regex and "regex" or "literal", opts.case or "smart" }
  end
  flags[#flags + 1] = opts.hidden and "hidden:on" or "hidden:off"
  flags[#flags + 1] = opts.ignored and "ignore:off" or "ignore:on"
  for _, glob in ipairs(opts.globs or {}) do
    flags[#flags + 1] = glob
  end
  return table.concat(flags, " · ")
end

function M.action(picker, name)
  if not picker.opts.search_options or picker.closed then
    return
  end
  if (name == "regex" or name == "case") and picker.opts.source ~= "grep" then
    return
  end
  if name == "scope" or name == "globs" then
    if picker.prompting then
      return
    end
    picker.prompting = true
    vim.ui.input({
      prompt = name == "scope" and "Search directory: " or "File globs (comma separated, ! to exclude): ",
      default = name == "scope" and picker.opts.cwd or table.concat(picker.opts.globs or {}, ","),
      completion = name == "scope" and "dir" or nil,
    }, function(value)
      vim.schedule(function()
        picker.prompting = false
        if picker.closed then
          return
        end
        vim.api.nvim_set_current_win(picker.input_win)
        vim.cmd.startinsert({ bang = true })
        if value ~= nil then
          local update = name == "scope" and { cwd = value } or { globs = vim.split(value, ",", { trimempty = true }) }
          if update.globs then
            update.globs = vim.tbl_map(vim.trim, update.globs)
          end
          local ok, err = pcall(M.set, picker, update)
          if not ok then
            vim.notify(tostring(err), vim.log.levels.WARN)
          end
        end
      end)
    end)
  elseif name == "case" then
    M.set(picker, { case = cases[picker.opts.case or "smart"] })
  else
    M.set(picker, { [name] = not picker.opts[name] })
  end
end
return M
