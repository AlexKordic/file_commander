-- test/test_find.lua
-- End-to-end checks for Find dialog (Priority 4.1).
-- Usage: ./build/fc run test/test_find.lua

local h = dofile("test/helpers.lua")

local src = h.tmpdir("find_src")
local dst = h.tmpdir("find_dst")

h.mkdir(src)
h.mkdir(dst)
h.mkdir(src .. "/nested")
h.mkdir(src .. "/nested/deeper")
h.create_file(src .. "/nested/deeper/needle.txt", "needle\n")
h.create_file(src .. "/nested/deeper/other.log", "other\n")
h.create_file(src .. "/top.txt", "top\n")

fc.left_cd(src)
fc.right_cd(dst)
fc.sleep(120)

local function ensure_left_focus()
  local left_path = fc.left_path()
  local function probe_left()
    fc.key("cA")
    local sel = fc.selected()
    if #sel == 0 then return false end
    local ok = sel[1]:sub(1, #left_path) == left_path
    fc.key("esc")
    return ok
  end
  if not probe_left() then
    fc.key("tab")
    fc.sleep(60)
    check(probe_left(), "failed to focus left panel")
  end
end

ensure_left_focus()

fc.key("f3")
check(fc.wait_event("dialog_opened", 2000), "expected find dialog to open")

fc.key({"n", "e", "e", "d", "l", "e", ".", "t", "x", "t", "ret"})
fc.sleep(350)

fc.key({"down", "ret"})
check(fc.wait_event("dialog_closed", 2000), "expected find dialog to close after opening result")

local expected_dir = src .. "/nested/deeper"
local expected_file = expected_dir .. "/needle.txt"
check(fc.left_path() == expected_dir, "expected left path %s, got %s", expected_dir, fc.left_path())
check(fc.focused() == expected_file, "expected focused file %s, got %s", expected_file, fc.focused())

h.cleanup(src, dst)
test_pass("find_dialog_basic")
fc.quit()
