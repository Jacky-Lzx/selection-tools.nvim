local Matcher = {}
Matcher.__index = Matcher

function Matcher.new(opts)
  assert(vim.tbl_contains({ "auto", "native", "skim" }, opts.backend), "selection-tools: invalid matcher backend")
  assert(
    type(opts.threshold) == "number" and opts.threshold >= 1,
    "selection-tools: matcher threshold must be positive"
  )
  assert(type(opts.skim.command) == "string" and opts.skim.command ~= "", "selection-tools: invalid skim command")
  assert(type(opts.skim.algorithm) == "string" and opts.skim.algorithm ~= "", "selection-tools: invalid skim algorithm")
  assert(
    type(opts.skim.debounce_ms) == "number" and opts.skim.debounce_ms >= 0,
    "selection-tools: invalid skim debounce"
  )
  assert(type(opts.skim.timeout_ms) == "number" and opts.skim.timeout_ms > 0, "selection-tools: invalid skim timeout")
  return setmetatable({ opts = opts, generation = 0, entries = {}, texts = {}, lookup = {} }, Matcher)
end

function Matcher:cancel()
  self.generation = self.generation + 1
  local timer, process = self.timer, self.process
  self.timer, self.process, self.pending = nil, nil, false
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  if process and not process:is_closing() then
    pcall(process.kill, process, 15)
  end
end

function Matcher:set_entries(entries)
  self:cancel()
  self.entries, self.texts, self.lookup, self.payload = entries, {}, {}, nil
  for i, entry in ipairs(entries) do
    self.texts[i] = entry.text
    local existing = self.lookup[entry.text]
    if not existing then
      self.lookup[entry.text] = entry
    elseif existing.index then
      self.lookup[entry.text] = { existing, entry }
    else
      existing[#existing + 1] = entry
    end
  end
end

function Matcher:select(query)
  if self.opts.backend == "native" or self.failed then
    return "native"
  end
  if self.opts.backend == "auto" and #self.entries < self.opts.threshold then
    return "native"
  end
  -- skim's extended-query syntax differs from literal, sequential matching.
  -- Keep these queries on the native path rather than reinterpret filenames.
  if query:find("[%s!^$|'\"\\%z]") or vim.fn.strchars(query) > 1024 then
    return "native"
  end
  if vim.fn.executable(self.opts.skim.command) ~= 1 then
    self.last_error = "skim executable not found: " .. self.opts.skim.command
    return "native"
  end
  return "skim"
end

function Matcher:_native(query)
  local result = vim.fn.matchfuzzypos(self.texts, query, { matchseq = 1 })
  local matches, occurrences = {}, {}
  for i, text in ipairs(result[1]) do
    local entry = self.lookup[text]
    if not entry.index then
      occurrences[text] = (occurrences[text] or 0) + 1
      entry = entry[occurrences[text]]
    end
    matches[i] = entry
  end
  return matches, result[2]
end

function Matcher:run(query, backend, done)
  self:cancel()
  self.backend = backend
  if backend == "native" then
    local matches, positions = self:_native(query)
    done(matches, positions, "native")
    return
  end
  self.pending, self.last_error = true, nil
  local generation = self.generation
  local entries = self.entries
  local function current()
    return self.generation == generation
  end
  local function fail(err)
    if not current() then
      return
    end
    self.failed, self.last_error, self.pending, self.backend = true, tostring(err), false, "native"
    vim.notify("selection-tools: skim failed; using native matching: " .. self.last_error, vim.log.levels.WARN)
    local matches, positions = self:_native(query)
    done(matches, positions, "native")
  end
  local function receive(result)
    if not current() then
      return
    end
    self.process = nil
    if result.code ~= 0 and not (result.code == 1 and (result.stdout or "") == "" and (result.stderr or "") == "") then
      fail(result.stderr ~= "" and result.stderr or ("exit code " .. tostring(result.code)))
      return
    end
    local output, offset, matches, seen = result.stdout or "", 1, {}, {}
    -- Yield while decoding large result sets so a new query can cancel promptly.
    local function decode()
      if not current() then
        return
      end
      for _ = 1, 2000 do
        if offset > #output then
          self.pending = false
          done(matches, {}, "skim")
          return
        end
        local finish = output:find("\0", offset, true)
        local tab = output:find("\t", offset, true)
        if not finish or not tab or tab >= finish then
          fail("invalid result framing")
          return
        end
        local id = tonumber(output:sub(offset, tab - 1))
        local entry = id and entries[id] or nil
        if not entry or seen[id] or output:sub(tab + 1, finish - 1) ~= entry.text then
          fail("invalid result identity")
          return
        end
        seen[id], matches[#matches + 1], offset = true, entry, finish + 1
      end
      vim.schedule(decode)
    end
    decode()
  end
  local function start()
    self.timer = nil
    if not current() then
      return
    end
    if not self.payload then
      local records = {}
      for i, entry in ipairs(entries) do
        records[i] = i .. "\t" .. entry.text
      end
      self.payload = table.concat(records, "\0") .. "\0"
    end
    local opts = self.opts.skim
    local ok, process = pcall(vim.system, {
      opts.command,
      "--algo",
      opts.algorithm,
      "--case",
      "smart",
      "--no-typos",
      "--delimiter",
      "\t",
      "--nth",
      "2..",
      "--tiebreak",
      "score,index",
      "--read0",
      "--print0",
      "--filter=" .. query,
    }, {
      stdin = self.payload,
      timeout = opts.timeout_ms,
      env = { SKIM_DEFAULT_OPTIONS = "", SKIM_DEFAULT_COMMAND = "" },
    }, function(result)
      vim.schedule(function()
        receive(result)
      end)
    end)
    if not ok then
      fail(process)
    elseif current() then
      self.process = process
    elseif not process:is_closing() then
      pcall(process.kill, process, 15)
    end
  end
  if self.opts.skim.debounce_ms == 0 then
    start()
  else
    self.timer = vim.defer_fn(start, self.opts.skim.debounce_ms)
  end
end

return Matcher
