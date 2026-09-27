-- test/helpers.lua
-- Shared test setup/teardown utilities for fc Lua tests.

local M = {}

function M.shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.tree_manifest(path)
  local python = os.getenv("FC_TEST_PYTHON") or "python3"
  local tool = os.getenv("FC_TEST_FIXTURE_TOOL") or "test/fixture_tool.py"
  local command = M.shell_quote(python) .. " " .. M.shell_quote(tool) .. " manifest " .. M.shell_quote(path)
  local stream = assert(io.popen(command, "r"))
  local output = stream:read("*a")
  local ok = stream:close()
  check(ok and output:sub(1, 1) == "{", "fixture manifest failed for %s", path)
  return output
end

function M.wait_event(name, timeout_ms, message)
  local ok = fc.wait_event(name, timeout_ms or 2000)
  check(ok, message or ("expected event: " .. tostring(name)))
end

function M.cd(left_path, right_path)
  if left_path then
    fc.left_cd(left_path)
    M.wait_event("dir_changed", 2000, "expected dir_changed after left_cd")
    check(fc.left_path() == left_path, "left path mismatch: expected %s got %s", left_path, fc.left_path())
  end
  if right_path then
    fc.right_cd(right_path)
    M.wait_event("dir_changed", 2000, "expected dir_changed after right_cd")
    check(fc.right_path() == right_path, "right path mismatch: expected %s got %s", right_path, fc.right_path())
  end
end

function M.ensure_left_focus()
  local left_path = fc.left_path()
  local function probe_left()
    fc.key("cA")
    local sel = fc.selected()
    if #sel == 0 then return false end
    local ok = sel[1]:sub(1, #left_path) == left_path
    if ok then
      fc.key("esc")
    else
      fc.key("cA")
    end
    return ok
  end

  if probe_left() then return end
  for _ = 1, 2 do
    fc.key("tab")
    M.wait_event("focus_changed", 2000, "expected focus_changed after tab")
    if probe_left() then return end
  end
  check(false, "failed to focus left panel")
end

--- Generate a unique temp directory path.
function M.tmpdir(name)
  return (os.getenv("FC_TEST_TMPDIR") or "/tmp") .. "/fc_test_" .. name .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
end

--- Create a file with given content.
function M.create_file(path, content)
  local f = io.open(path, "w")
  assert(f, "failed to create file: " .. path)
  f:write(content or "test content\n")
  f:close()
end

--- Create a file of approximately `size` bytes.
function M.create_file_sized(path, size)
  local f = io.open(path, "w")
  assert(f, "failed to create file: " .. path)
  local chunk = string.rep("X", math.min(size, 4096))
  local written = 0
  while written < size do
    local to_write = math.min(#chunk, size - written)
    f:write(chunk:sub(1, to_write))
    written = written + to_write
  end
  f:close()
end

--- Check if a file exists (regular file or symlink target is a file).
function M.file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

--- Check if a directory exists.
function M.dir_exists(path)
  local ok = os.execute("test -d '" .. path .. "'")
  return ok == 0 or ok == true
end

--- Check if a symlink exists (does not follow the link).
function M.symlink_exists(path)
  local ok = os.execute("test -L '" .. path .. "'")
  return ok == 0 or ok == true
end

--- Read symlink target (returns the raw target string).
function M.read_symlink(path)
  local f = io.popen("readlink '" .. path .. "'")
  if not f then return nil end
  local target = f:read("*l")
  f:close()
  return target
end

--- Read entire file content.
function M.read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Get file size in bytes.
function M.file_size(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

--- Count files in a directory (non-recursive, excludes . and ..).
function M.count_items(path)
  local count = 0
  local f = io.popen("ls -1A '" .. path .. "' 2>/dev/null")
  if f then
    for _ in f:lines() do count = count + 1 end
    f:close()
  end
  return count
end

--- Create a symlink.  target is what the link points to, link_path is where the link is created.
function M.create_symlink(target, link_path)
  local ok = os.execute("ln -s '" .. target .. "' '" .. link_path .. "'")
  assert(ok == 0 or ok == true, "failed to create symlink: " .. link_path .. " -> " .. target)
end

--- Remove directory recursively.
function M.rmdir(path)
  os.execute("rm -rf '" .. path .. "'")
end

--- Create a directory (with parents).
function M.mkdir(path)
  os.execute("mkdir -p '" .. path .. "'")
end

--- Check if path is a symlink (not following).
function M.is_symlink(path)
  return M.symlink_exists(path)
end

--- Get real/canonical path.
function M.realpath(path)
  local f = io.popen("realpath '" .. path .. "' 2>/dev/null")
  if not f then return nil end
  local result = f:read("*l")
  f:close()
  return result
end

--- Execute a copy operation in fc:
--- select all in left panel, open copy dialog, wait for discovery, confirm, wait for job.
--- Options:
---   toggle_follow_links (bool) — press down+ret to toggle "Follow Links" checkbox
---   toggle_preserve_relative (bool) — navigate to and toggle "Keep relative links"
---   conflict_mode (string) — "replace" (default), "update", or "skip"
function M.do_copy(opts)
  opts = opts or {}
  local confirm_with_copy_hotkey = false

  -- Ensure left panel has focus.
  local left_path = fc.left_path()
  local left_real = M.realpath(left_path)

  local function path_under_left(path)
    if path:sub(1, #left_path) == left_path then return true end
    if not left_real then return false end
    local path_real = M.realpath(path)
    return path_real ~= nil and path_real:sub(1, #left_real) == left_real
  end

  M.ensure_left_focus()
  fc.key("cA")
  local sel = fc.selected()
  if #sel == 0 or not path_under_left(sel[1]) then
    error("do_copy: no items selected in left panel — left_path=" .. left_path)
  end

  -- Open copy dialog (F5) and wait for discovery
  fc.key("f5")
  M.wait_event("discovery_completed", 10000, "expected copy discovery completed")

  -- Toggle checkboxes if requested
  -- Dialog focus starts on Cancel button (OnShow calls button_cancel->TakeFocus())
  -- Navigation order: [COPY, Cancel], Follow Links checkbox, Keep relative links checkbox, filelist
  if opts.toggle_follow_links then
    -- Navigate from Cancel to Follow Links checkbox (down), toggle with return
    fc.key({"down", "ret"})
    -- Discovery restarts on checkbox change — wait again
    M.wait_event("discovery_completed", 10000, "expected discovery after follow-links toggle")
    -- Navigate back up to button row
    fc.key("up")
  end

  if opts.toggle_preserve_relative then
    -- Navigate from Cancel to Keep relative links checkbox (down, down), toggle
    fc.key({"down", "down", "ret"})
    -- Discovery restarts on checkbox change — wait again
    M.wait_event("discovery_completed", 10000, "expected discovery after preserve-relative toggle")
    -- Navigate back up to button row
    fc.key({"up", "up"})
  end

  if opts.conflict_mode == "update" then
    -- Focus the conflict control before its digit shortcut: 1=replace, 2=update, 3=skip.
    fc.key({"down", "down", "down", "2"})
    confirm_with_copy_hotkey = true
  elseif opts.conflict_mode == "skip" then
    fc.key({"down", "down", "down", "3"})
    confirm_with_copy_hotkey = true
  end

  if confirm_with_copy_hotkey then
    fc.key("f5")
  else
    -- Navigate from Cancel to COPY button (left) and confirm (return)
    fc.key({"<-", "ret"})
  end

  -- Wait for background copy job to complete
  check(fc.wait_for_jobs(30000), "expected copy job completion")
end

--- Setup for the basic copy test.
-- Creates a source directory with test files and an empty destination directory.
-- Returns source_path, dest_path.
function M.setup_copy_test()
  local src = M.tmpdir("copy_src")
  local dst = M.tmpdir("copy_dst")
  M.mkdir(src .. "/subdir")
  M.mkdir(dst)
  M.create_file(src .. "/alpha.txt", "alpha content\n")
  M.create_file(src .. "/beta.txt",  "beta content\n")
  M.create_file(src .. "/subdir/gamma.txt", "gamma content\n")
  return src, dst
end

--- Cleanup temp directories.
function M.cleanup(...)
  for _, path in ipairs({...}) do
    M.rmdir(path)
  end
end

return M
