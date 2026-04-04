local dirname = function(p)
  return vim.fn.fnamemodify(p, ":h")
end

local function get_trace(element, level, msg)
  local function trimTrace(info)
    local index = info.traceback:find "\n%s*%[C]"
    info.traceback = info.traceback:sub(1, index)
    return info
  end
  level = level or 3

  local thisdir = dirname(debug.getinfo(1, "Sl").source, ":h")
  local info = debug.getinfo(level, "Sl")
  while
    info.what == "C"
    or info.short_src:match "luassert[/\\].*%.lua$"
    or (info.source:sub(1, 1) == "@" and thisdir == dirname(info.source))
  do
    level = level + 1
    info = debug.getinfo(level, "Sl")
  end

  info.traceback = debug.traceback("", level)
  info.message = msg

  -- local file = busted.getFile(element)
  local file = false
  return file and file.getTrace(file.name, info) or trimTrace(info)
end

local is_headless = require("inanis.nvim_meta").is_headless

-- We are shadowing print so people can reliably print messages
print = function(...)
  for _, v in ipairs { ... } do
    io.stdout:write(tostring(v))
    io.stdout:write "\t"
  end

  io.stdout:write "\r\n"
end

local mod = {}

local results = {}
local current_description = {}
local current_before_each = {}
local current_after_each = {}

local add_description = function(desc)
  table.insert(current_description, desc)

  return vim.deepcopy(current_description)
end

local pop_description = function()
  current_description[#current_description] = nil
end

local add_new_each = function()
  current_before_each[#current_description] = {}
  current_after_each[#current_description] = {}
end

local clear_last_each = function()
  current_before_each[#current_description] = nil
  current_after_each[#current_description] = nil
end

local call_inner = function(desc, func)
  local desc_stack = add_description(desc)
  add_new_each()
  local ok, msg = xpcall(func, function(msg)
    -- debug.traceback
    -- return vim.inspect(get_trace(nil, 3, msg))
    local trace = get_trace(nil, 3, msg)
    return trace.message .. "\n" .. trace.traceback
  end)
  clear_last_each()
  pop_description()

  return ok, msg, desc_stack
end

local color_table = {
  blue = 34,
  yellow = 33,
  green = 32,
  red = 31,
}

local color_string = function(color, str)
  if not is_headless then
    return str
  end

  return string.format("%s[%sm%s%s[%sm", string.char(27), color_table[color] or 0, str, string.char(27), 0)
end

local SUCCESS = color_string("green", ".")
local FAIL = color_string("red", "!")
local PENDING = color_string("yellow", "P")
local SLOW = color_string("blue", "~")

local HEADER = string.rep("=", 40)

--- Write results as JSON to a file for the parent process to collect.
local write_results = function(results_file, res, file)
  if not results_file then
    return
  end

  local json_results = {
    file = file,
    pass = {},
    fail = {},
    errs = {},
    pending = {},
  }

  for _, each in ipairs(res.pass or {}) do
    table.insert(json_results.pass, {
      descriptions = each.descriptions,
      runtime_ns = each.runtime_ns,
    })
  end

  for _, each in ipairs(res.fail or {}) do
    table.insert(json_results.fail, {
      descriptions = each.descriptions,
      msg = each.msg,
      runtime_ns = each.runtime_ns,
    })
  end

  for _, each in ipairs(res.errs or {}) do
    table.insert(json_results.errs, {
      descriptions = each.descriptions,
      msg = each.msg,
    })
  end

  for _, each in ipairs(res.pending or {}) do
    table.insert(json_results.pending, {
      descriptions = each.descriptions,
    })
  end

  local f = io.open(results_file, "w")
  if f then
    f:write(vim.json.encode(json_results))
    f:close()
  end
end

mod.describe = function(desc, func)
  results.pass = results.pass or {}
  results.fail = results.fail or {}
  results.errs = results.errs or {}

  describe = mod.inner_describe
  local ok, msg, desc_stack = call_inner(desc, func)
  describe = mod.describe

  if not ok then
    table.insert(results.errs, {
      descriptions = desc_stack,
      msg = msg,
    })
  end
end

mod.inner_describe = function(desc, func)
  local ok, msg, desc_stack = call_inner(desc, func)

  if not ok then
    table.insert(results.errs, {
      descriptions = desc_stack,
      msg = msg,
    })
  end
end

mod.before_each = function(fn)
  table.insert(current_before_each[#current_description], fn)
end

mod.after_each = function(fn)
  table.insert(current_after_each[#current_description], fn)
end

mod.clear = function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
end

local indent = function(msg, spaces)
  if spaces == nil then
    spaces = 4
  end

  local prefix = string.rep(" ", spaces)
  return prefix .. msg:gsub("\n", "\n" .. prefix)
end

local run_each = function(tbl)
  for _, v in ipairs(tbl) do
    for _, w in ipairs(v) do
      if type(w) == "function" then
        w()
      end
    end
  end
end

mod.it = function(desc, func)
  local started = vim.uv.hrtime()
  run_each(current_before_each)
  local ok, msg, desc_stack = call_inner(desc, func)
  run_each(current_after_each)
  local runtime_ns = vim.uv.hrtime() - started

  local test_result = {
    descriptions = desc_stack,
    msg = nil,
    runtime_ns = runtime_ns,
  }

  -- TODO: We should figure out how to determine whether
  -- and assert failed or whether it was an error...

  local to_insert
  if not ok then
    to_insert = results.fail
    test_result.msg = msg

    local test_name = table.concat(test_result.descriptions, " > ")
    print(FAIL .. " " .. test_name)
    print(indent(msg, 5))
  else
    local runtime_ms = test_result.runtime_ns / 1000 / 1000
    local threshold = tonumber(os.getenv "SLOW_TEST_MS" or 1000)
    if runtime_ms > threshold then
      local test_name = table.concat(desc_stack, " > ")
      print(SLOW .. " " .. test_name .. " (" .. string.format("%.0f", runtime_ms) .. "ms)")
    else
      io.stdout:write(SUCCESS)
    end
    to_insert = results.pass
  end

  table.insert(to_insert, test_result)
end

mod.pending = function(desc, func)
  results.pending = results.pending or {}
  local curr_stack = vim.deepcopy(current_description)
  table.insert(curr_stack, desc)
  io.stdout:write(PENDING)
  table.insert(results.pending, { descriptions = curr_stack })
end

_InanisBustedOldAssert = _InanisBustedOldAssert or assert

describe = mod.describe
it = mod.it
pending = mod.pending
before_each = mod.before_each
after_each = mod.after_each
clear = mod.clear
---@type Luassert
assert = require "luassert"

mod.run = function(file, results_file)
  file = file:gsub("\\", "/")
  local display_name = vim.fn.fnamemodify(file, ":t")
  local loaded, msg = loadfile(file)

  if not loaded then
    print(HEADER)
    print "FAILED TO LOAD FILE"
    print(color_string("red", msg))
    print(HEADER)
    write_results(results_file, {
      pass = {},
      fail = {},
      errs = { { descriptions = { display_name }, msg = msg } },
      pending = {},
    }, display_name)
    if is_headless then
      return vim.cmd "2cq"
    else
      return
    end
  end

  coroutine.wrap(function()
    local ok, run_err = xpcall(loaded, function(err)
      return err .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
      -- Flush any dots from tests that ran before the crash
      print ""
      write_results(results_file, {
        pass = {},
        fail = {},
        errs = { { descriptions = { display_name }, msg = run_err } },
        pending = {},
      }, display_name)
      if is_headless then
        return vim.cmd "2cq"
      else
        return
      end
    end

    -- If nothing runs (empty file without top level describe)
    if not results.pass then
      write_results(results_file, {
        pass = {},
        fail = {},
        errs = {},
        pending = {},
      }, display_name)
      if is_headless then
        return vim.cmd "0cq"
      else
        return
      end
    end

    print ""
    write_results(results_file, results, display_name)

    if #results.errs ~= 0 then
      if is_headless then
        return vim.cmd "2cq"
      end
    elseif #results.fail > 0 then
      if is_headless then
        return vim.cmd "1cq"
      end
    else
      if is_headless then
        return vim.cmd "0cq"
      end
    end
  end)()
end

return mod
