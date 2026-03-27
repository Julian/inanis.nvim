local Job = require "inanis.job"

local headless = require("inanis.nvim_meta").is_headless

local inanis_dir = vim.fn.fnamemodify(debug.getinfo(1).source:match "@?(.*[/\\])", ":p:h:h:h")

local inanis = {}

local print_output = vim.schedule_wrap(function(_, ...)
  for _, v in ipairs { ... } do
    io.stdout:write(tostring(v))
    io.stdout:write "\n"
  end

  vim.cmd [[mode]]
end)

local color_table = {
  blue = 34,
  yellow = 33,
  green = 32,
  red = 31,
}

local function color_string(color, str)
  return string.format("%s[%sm%s%s[%sm", string.char(27), color_table[color] or 0, str, string.char(27), 0)
end

local function indent(msg, spaces)
  local prefix = string.rep(" ", spaces or 4)
  return prefix .. msg:gsub("\n", "\n" .. prefix)
end

local HEADER = string.rep("=", 40)

local function format_combined_results(all_results)
  local total_pass = 0
  local total_fail = 0
  local total_err = 0
  local total_pending = 0
  local all_failures = {}
  local all_errors = {}
  local all_pending = {}

  for _, res in ipairs(all_results) do
    total_pass = total_pass + #res.pass
    total_fail = total_fail + #res.fail
    total_err = total_err + #res.errs
    total_pending = total_pending + #res.pending

    for _, each in ipairs(res.fail) do
      table.insert(all_failures, {
        file = res.file,
        descriptions = each.descriptions,
        msg = each.msg,
      })
    end

    for _, each in ipairs(res.errs) do
      table.insert(all_errors, {
        file = res.file,
        descriptions = each.descriptions,
        msg = each.msg,
      })
    end

    for _, each in ipairs(res.pending) do
      table.insert(all_pending, {
        file = res.file,
        descriptions = each.descriptions,
      })
    end
  end

  io.stdout:write(HEADER .. "\n")

  if total_fail > 0 then
    io.stdout:write(color_string("red", "Failed Tests:") .. "\n\n")
    for i, each in ipairs(all_failures) do
      io.stdout:write(color_string("red", string.format("  %d) %s", i, table.concat(each.descriptions, " > "))) .. "\n")
      if each.msg then
        io.stdout:write(indent(each.msg, 5) .. "\n")
      end
      io.stdout:write "\n"
    end
  end

  if total_err > 0 then
    io.stdout:write(color_string("red", "Errors:") .. "\n\n")
    for i, each in ipairs(all_errors) do
      io.stdout:write(color_string("red", string.format("  %d) %s", i, table.concat(each.descriptions, " > "))) .. "\n")
      if each.msg then
        io.stdout:write(indent(each.msg, 5) .. "\n")
      end
      io.stdout:write "\n"
    end
  end

  if total_pending > 0 then
    io.stdout:write(color_string("yellow", "Pending:") .. "\n")
    for _, each in ipairs(all_pending) do
      io.stdout:write(color_string("yellow", "  - " .. table.concat(each.descriptions, " > ")) .. "\n")
    end
    io.stdout:write "\n"
  end

  local parts = {}
  table.insert(parts, color_string("green", total_pass .. " passed"))
  if total_fail > 0 then
    table.insert(parts, color_string("red", total_fail .. " failed"))
  end
  if total_err > 0 then
    table.insert(parts, color_string("red", total_err .. (total_err == 1 and " error" or " errors")))
  end
  if total_pending > 0 then
    table.insert(parts, color_string("yellow", total_pending .. " pending"))
  end

  io.stdout:write(table.concat(parts, ", ") .. "\n")
  io.stdout:write(HEADER .. "\n")
end

local get_nvim_output = function(job_id)
  return vim.schedule_wrap(function(bufnr, ...)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    for _, v in ipairs { ... } do
      vim.api.nvim_chan_send(job_id, v .. "\r\n")
    end
  end)
end

local function test_paths(paths, opts)
  local minimal = not opts or not opts.init or opts.minimal or opts.minimal_init

  opts = vim.tbl_deep_extend("force", {
    nvim_cmd = vim.v.progpath,
    winopts = { winblend = 3 },
    sequential = false,
    keep_going = true,
    timeout = 50000,
  }, opts or {})

  vim.env.INANIS_TEST_TIMEOUT = opts.timeout

  local res = {}
  if not headless then
    local bufnr = vim.api.nvim_create_buf(false, true)
    local win_id = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      style = "minimal",
      width = 80, -- FIXME: Hardcoded for now
      height = 50,
      row = 1,
      col = 1,
    })

    res.job_id = vim.api.nvim_open_term(bufnr, {})
    vim.api.nvim_buf_set_keymap(bufnr, "n", "q", ":q<CR>", {})

    vim.api.nvim_win_set_option(win_id, "winhl", "Normal:Normal")
    vim.api.nvim_win_set_option(win_id, "conceallevel", 3)
    vim.api.nvim_win_set_option(win_id, "concealcursor", "n")

    if res.border_win_id then
      vim.api.nvim_win_set_option(res.border_win_id, "winhl", "Normal:Normal")
    end

    if res.bufnr then
      vim.api.nvim_buf_set_option(res.bufnr, "filetype", "InanisTestPopup")
    end
    vim.cmd "mode"
  end

  local outputter = headless and print_output or get_nvim_output(res.job_id)

  local failure = false

  local jobs = vim.tbl_map(function(p)
    local args = {
      "--headless",
      "-c",
      "set rtp+=.," .. vim.fn.escape(inanis_dir, " "),
    }

    if minimal then
      table.insert(args, "--noplugin")
      if opts.minimal_init then
        table.insert(args, "-u")
        table.insert(args, opts.minimal_init)
      end
    elseif opts.init ~= nil then
      table.insert(args, "-u")
      table.insert(args, opts.init)
    end

    table.insert(args, "-c")
    table.insert(args, string.format('lua require("inanis.busted").run("%s")', p:gsub("\\", "\\\\")))

    local job = Job:new {
      command = opts.nvim_cmd,
      args = args,

      on_stdout = function(_, data)
        outputter(res.bufnr, data)
      end,

      on_exit = vim.schedule_wrap(function(_, _, _)
        vim.cmd "mode"
      end),
    }
    job.nvim_busted_path = p
    return job
  end, paths)

  for _, j in ipairs(jobs) do
    j:start()
    if opts.sequential then
      if not Job.join(j, opts.timeout) then
        failure = true
        pcall(function()
          j.handle:kill(15) -- SIGTERM
        end)
      else
        failure = failure or j.code ~= 0 or j.signal ~= 0
      end
      if failure and not opts.keep_going then
        break
      end
    end
  end

  -- TODO: Probably want to let people know when we've completed everything.
  if not headless then
    return
  end

  if not opts.sequential then
    table.insert(jobs, opts.timeout)
    Job.join(unpack(jobs))
    table.remove(jobs, #jobs)
    for _, each in ipairs(jobs) do
      if each.code ~= 0 then
        failure = true
      end
    end
  end
  vim.wait(100)

  -- Collect JSON results from stderr of each subprocess.
  -- Non-JSON lines (e.g. nvim errors, crashes) are preserved as diagnostic output.
  local all_results = {}
  local stderr_noise = {}
  for _, j in ipairs(jobs) do
    local found_json = false
    for _, line in ipairs(j:stderr_result()) do
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" and decoded.file then
        table.insert(all_results, decoded)
        found_json = true
      elseif line ~= "" then
        table.insert(stderr_noise, line)
      end
    end
    if not found_json and j.code ~= 0 then
      table.insert(stderr_noise, color_string("red", "Subprocess crashed: " .. (j.nvim_busted_path or "unknown")))
    end
  end

  if headless then
    if #stderr_noise > 0 then
      io.stdout:write "\n"
      for _, line in ipairs(stderr_noise) do
        io.stdout:write(line .. "\n")
      end
    end

    if #all_results > 0 then
      format_combined_results(all_results)
    end

    if failure then
      return vim.cmd "1cq"
    end

    return vim.cmd "0cq"
  end
end

--- Run any kind of specs -- directories or files.
function inanis.run(opts)
  local specs = opts.specs or {}
  opts.specs = nil

  local flattened = {}

  for _, each in ipairs(specs) do
    if vim.fn.isdirectory(each) == 1 then
      vim.list_extend(flattened, inanis._discover_specs_in(each))
    else
      table.insert(flattened, each)
    end
  end

  test_paths(flattened, opts)
end

function inanis.test_file(filepath, opts)
  opts = vim.tbl_deep_extend("error", { specs = { filepath } }, opts)
  inanis.run(opts)
end

local function _find_via_subprocess(directory)
  local finder
  if vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1 then
    -- On windows use powershell Get-ChildItem instead
    local cmd = vim.fn.executable "pwsh.exe" == 1 and "pwsh" or "powershell"
    finder = Job:new {
      command = cmd,
      args = { "-NoProfile", "-Command", [[Get-ChildItem -Recurse -n -Filter "*_spec.lua"]] },
      cwd = directory,
    }
  else
    -- everywhere else use find
    finder = Job:new {
      command = "find",
      args = { directory, "-type", "f", "-name", "*_spec.lua" },
    }
  end

  return finder:sync(vim.env.INANIS_TEST_TIMEOUT)
end

function inanis._discover_specs_in(directory)
  directory = directory:gsub("\\", "/")
  local paths = _find_via_subprocess(directory)
  -- Paths work strangely on Windows, so lets have abs paths
  if vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1 then
    paths = vim.tbl_map(function(p)
      return p.filename
    end, paths)
  end
  return paths
end

return inanis
