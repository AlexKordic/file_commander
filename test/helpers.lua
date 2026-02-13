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

--- Check if a file exists.
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

--- Read entire file content.
function M.read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Remove directory recursively.
function M.rmdir(path)
  os.execute("rm -rf '" .. path .. "'")
end

--- Setup for the copy test.
-- Creates a source directory with test files and an empty destination directory.
-- Returns source_path, dest_path.
function M.setup_copy_test()
  local src = M.tmpdir("copy_src")
  local dst = M.tmpdir("copy_dst")
  os.execute("mkdir -p '" .. src .. "/subdir'")
  os.execute("mkdir -p '" .. dst .. "'")
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
