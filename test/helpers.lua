-- test/helpers.lua
-- Shared test setup/teardown utilities for fc Lua tests.

local M = {}

--- Generate a unique temp directory path.
function M.tmpdir(name)
  return "/tmp/fc_test_" .. name .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
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
function M.do_copy(opts)
  opts = opts or {}

  -- Ensure left panel has focus.
  -- fc.selected() returns selected items from the focused panel.
  -- We try selecting, check if selected paths are under left_path,
  -- if not, toggle focus and retry.
  local left_path = fc.left_path()

  local function try_select()
    fc.key("cA")
    local sel = fc.selected()
    if #sel == 0 then return false end
    -- Check if selected items are under the left panel's path
    if sel[1]:sub(1, #left_path) == left_path then return true end
    -- Selected from wrong panel — deselect and toggle
    fc.key("cA")  -- toggle off
    return false
  end

  if not try_select() then
    fc.key("tab")
    fc.sleep(50)
    if not try_select() then
      error("do_copy: no items selected in left panel after toggle — left_path=" .. left_path)
    end
  end

  -- Open copy dialog (F5) and wait for discovery
  fc.key("f5")
  fc.wait_event("discovery_completed", 10000)

  -- Toggle checkboxes if requested
  -- Dialog focus starts on Cancel button (OnShow calls button_cancel->TakeFocus())
  -- Navigation order: [COPY, Cancel], Follow Links checkbox, Keep relative links checkbox, filelist
  if opts.toggle_follow_links then
    -- Navigate from Cancel to Follow Links checkbox (down), toggle with return
    fc.key({"down", "ret"})
    -- Discovery restarts on checkbox change — wait again
    fc.wait_event("discovery_completed", 10000)
    -- Navigate back up to button row
    fc.key("up")
  end

  if opts.toggle_preserve_relative then
    -- Navigate from Cancel to Keep relative links checkbox (down, down), toggle
    fc.key({"down", "down", "ret"})
    -- Discovery restarts on checkbox change — wait again
    fc.wait_event("discovery_completed", 10000)
    -- Navigate back up to button row
    fc.key({"up", "up"})
  end

  -- Navigate from Cancel to COPY button (left) and confirm (return)
  fc.key({"<-", "ret"})

  -- Wait for background copy job to complete
  fc.wait_for_jobs()
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
