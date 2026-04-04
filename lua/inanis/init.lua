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

  for _, r in ipairs(all_results) do
    total_pass = total_pass + #r.pass
    total_fail = total_fail + #r.fail
    total_err = total_err + #r.errs
    total_pending = total_pending + #r.pending

    for _, each in ipairs(r.fail) do
      table.insert(all_failures, each)
    end
    for _, each in ipairs(r.errs) do
      table.insert(all_errors, each)
    end
    for _, each in ipairs(r.pending) do
      table.insert(all_pending, each)
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

  local ncpus = #vim.loop.cpu_info()

  opts = vim.tbl_deep_extend("force", {
    nvim_cmd = vim.v.progpath,
    winopts = { winblend = 3 },
    keep_going = true,
    timeout = 50000,
    concurrent = ncpus + 1,
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
  local active = 0
  local results_dir = vim.fn.tempname()
  vim.fn.mkdir(results_dir, "p")

  local jobs = {}
  for i, p in ipairs(paths) do
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

    local results_file = results_dir .. "/" .. i .. ".json"

    table.insert(args, "-c")
    table.insert(args, string.format(
      'lua require("inanis.busted").run("%s", "%s")',
      p:gsub("\\", "\\\\"),
      results_file:gsub("\\", "\\\\")
    ))

    local job = Job:new {
      command = opts.nvim_cmd,
      args = args,

      on_stdout = function(_, data)
        outputter(res.bufnr, data)
      end,

      on_stderr = function(_, data)
        outputter(res.bufnr, data)
      end,

      on_exit = vim.schedule_wrap(function(_, _, _)
        vim.cmd "mode"
      end),
    }
    job.nvim_busted_path = p
    jobs[i] = job
  end

  for _, j in ipairs(jobs) do
    j:add_on_exit_callback(vim.schedule_wrap(function(_, code, signal)
      if code ~= 0 or signal ~= 0 then
        failure = true
      end
      active = active - 1
      if active == 0 and not headless then
        vim.fn.delete(results_dir, "rf")
      end
    end))
  end

  for _, j in ipairs(jobs) do
    -- Wait for a concurrency slot to open up
    if not vim.wait(opts.timeout, function()
      return active < opts.concurrent
    end, 10) then
      -- A running job exceeded the timeout; kill all still-running jobs
      for _, running in ipairs(jobs) do
        if running.handle and not running.is_shutdown then
          pcall(function()
            running.handle:kill(15) -- SIGTERM
          end)
        end
      end
      failure = true
      break
    end

    if not opts.keep_going and failure then
      break
    end

    active = active + 1
    j:start()
  end

  if not headless then
    return
  end

  -- Wait for all in-flight jobs to complete
  vim.wait(opts.timeout, function()
    return active == 0
  end, 10)

  vim.wait(100)

  -- Collect JSON results from temp files
  local all_results = {}
  for i, j in ipairs(jobs) do
    local results_file = results_dir .. "/" .. i .. ".json"
    local display = vim.fn.fnamemodify(j.nvim_busted_path or "unknown", ":t")
    local f = io.open(results_file, "r")
    if f then
      local content = f:read "*a"
      f:close()
      local ok, decoded = pcall(vim.json.decode, content)
      if ok and decoded then
        table.insert(all_results, decoded)
      else
        table.insert(all_results, {
          file = display,
          pass = {},
          fail = {},
          errs = { { descriptions = { display }, msg = "Failed to parse results JSON" } },
          pending = {},
        })
      end
    else
      table.insert(all_results, {
        file = display,
        pass = {},
        fail = {},
        errs = { { descriptions = { display }, msg = "No results (subprocess exited with code " .. (j.code or "?") .. ")" } },
        pending = {},
      })
    end
  end

  -- Clean up temp dir
  vim.fn.delete(results_dir, "rf")

  if #all_results > 0 then
    format_combined_results(all_results)
  end

  if failure then
    return vim.cmd "1cq"
  end

  return vim.cmd "0cq"
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
