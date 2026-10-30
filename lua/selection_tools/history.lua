local M = {}
local sessions = {}

local function path(opts)
  return opts.path or (vim.fn.stdpath("state") .. "/selection-tools/history.json")
end

function M.get(key, opts)
  local store = opts.persist and path(opts) or "session"
  if not sessions[store] then
    local data = {}
    if opts.persist then
      local ok, value = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(store), "\n"))
      end)
      if ok and type(value) == "table" then
        data = value
      end
    end
    sessions[store] = data
  end
  local ret = {}
  for _, value in ipairs(type(sessions[store][key]) == "table" and sessions[store][key] or {}) do
    if type(value) == "string" then
      ret[#ret + 1] = value
    end
  end
  return ret
end

function M.add(key, query, opts)
  if query == "" then
    return
  end
  local values = M.get(key, opts)
  values = vim.tbl_filter(function(value)
    return value ~= query
  end, values)
  values[#values + 1] = query
  while #values > math.max(1, opts.limit) do
    table.remove(values, 1)
  end
  local store = opts.persist and path(opts) or "session"
  sessions[store][key] = values
  if opts.persist then
    local temporary = store .. "." .. vim.uv.os_getpid() .. ".tmp"
    local ok, err = pcall(function()
      vim.fn.mkdir(vim.fs.dirname(store), "p")
      assert(vim.fn.writefile({ vim.json.encode(sessions[store]) }, temporary) == 0)
      assert(vim.uv.fs_rename(temporary, store))
    end)
    if not ok then
      vim.uv.fs_unlink(temporary)
      vim.notify("selection-tools: could not save history: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

return M
