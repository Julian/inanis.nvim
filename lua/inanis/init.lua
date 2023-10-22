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

--- Run any kind of tests -- directories or files.
function inanis.run(args)
  local tests = {}
  local opts = {}

  for key, value in pairs(args) do
    if type(key) == "number" then
      table.insert(tests, value)
    else
      opts[key] = value
    end
  end

  for _, each in ipairs(tests) do
    if vim.fn.isdirectory(each) == 1 then
      inanis.test_directory(each, opts)
    else
      inanis.test_file(each, opts)
    end
  end
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

function inanis.test_directory_command(command)
  local split_string = vim.split(command, " ")
  local directory = vim.fn.expand(table.remove(split_string, 1))

  local opts = assert(loadstring("return " .. table.concat(split_string, " ")))()

  return inanis.test_directory(directory, opts)
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
  local outputter_ = headless and print_ or get_nvim_output(res.job_id)

  local path_len = #paths
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

      -- Can be turned on to debug
      on_stdout = function(_, data)
        if path_len == 1 then
          outputter(res.bufnr, data)
        end
      end,

      on_stderr = function(_, data)
        if path_len == 1 then
          outputter(res.bufnr, data)
        end
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
    outputter_(res.bufnr, j.nvim_busted_path .. "\t")
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
    table.remove(jobs, table.getn(jobs))
    for _, each in ipairs(jobs) do
      if each.code ~= 0 then
        failure = true
      end
    end
  end
  vim.wait(100)

  if headless then
    if failure then
      return vim.cmd "1cq"
    end

    return vim.cmd "0cq"
  end
end

function inanis.test_directory(directory, opts)
  print "Starting..."
  directory = directory:gsub("\\", "/")
  local paths = inanis._find_files_to_run(directory)

  -- Paths work strangely on Windows, so lets have abs paths
  if vim.fn.has "win32" == 1 or vim.fn.has "win64" == 1 then
    paths = vim.tbl_map(function(p)
      return p.filename
    end, paths)
  end

  test_paths(paths, opts)
end

function inanis.test_file(filepath, opts)
  test_paths({ filepath }, opts)
end

function inanis._find_files_to_run(directory)
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

function inanis._run_path(test_type, directory)
  local paths = inanis._find_files_to_run(directory)

  local bufnr = 0
  local win_id = 0

  for _, p in pairs(paths) do
    print " "
    print("Loading Tests For: ", p, "\n")

    local ok, _ = pcall(function()
      dofile(p)
    end)

    if not ok then
      print "Failed to load file"
    end
  end

  inanis:run(test_type, bufnr, win_id)
  vim.cmd "qa!"

  return paths
end

return inanis
