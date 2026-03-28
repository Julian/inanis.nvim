local Job = require "inanis.job"

local headless = require("inanis.nvim_meta").is_headless

local inanis_dir = vim.fn.fnamemodify(debug.getinfo(1).source:match "@?(.*[/\\])", ":p:h:h:h")

local inanis = {}

local print_ = vim.schedule_wrap(function(_, ...)
  for _, v in ipairs { ... } do
    io.stdout:write(tostring(v))
  end

  vim.cmd [[mode]]
end)

local print_output = vim.schedule_wrap(function(_, ...)
  for _, v in ipairs { ... } do
    io.stdout:write(tostring(v))
    io.stdout:write "\n"
  end

  vim.cmd [[mode]]
end)

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
  local outputter_ = headless and print_ or get_nvim_output(res.job_id)

  local path_len = #paths
  local failure = false
  local active = 0

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

      -- Can be turned on to debug
      on_stdout = function(_, data)
        if path_len == 1 then
          outputter(res.bufnr, data)
        end
      end,

      on_stderr = function(_, data)
        outputter(res.bufnr, data)
      end,

      on_exit = vim.schedule_wrap(function(j_self, _, _)
        if path_len ~= 1 then
          outputter(res.bufnr, unpack(j_self:stderr_result()))
          outputter(res.bufnr, unpack(j_self:result()))
        end

        vim.cmd "mode"
      end),
    }
    job.nvim_busted_path = p
    return job
  end, paths)

  for _, j in ipairs(jobs) do
    j:add_on_exit_callback(vim.schedule_wrap(function(j_self, code, signal)
      if code ~= 0 or signal ~= 0 then
        failure = true
      end
      active = active - 1
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
    outputter_(res.bufnr, j.nvim_busted_path .. "\t")
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
