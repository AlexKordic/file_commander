-- test/test_glob.lua
-- End-to-end checks for glob select / deselect dialog (Priority 2.3).
-- Usage: ./build/fc run test/test_glob.lua

local h = dofile("test/helpers.lua")

local src = h.tmpdir("glob_src")
local dst = h.tmpdir("glob_dst")

h.mkdir(src)
h.mkdir(dst)
h.create_file(src .. "/apple.txt", "apple\n")
h.create_file(src .. "/banana.txt", "banana\n")
h.create_file(src .. "/cherry.log", "cherry\n")
h.create_file(src .. "/delta.md", "delta\n")

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

local function contains_path_suffix(paths, suffix)
  for _, p in ipairs(paths) do
    if p:sub(-#suffix) == suffix then return true end
  end
  return false
end

ensure_left_focus()
fc.key("esc")

-- 1) '+' opens select dialog and selects matching files.
fc.key("+")
check(fc.wait_event("dialog_opened", 2000), "expected glob select dialog to open")
fc.key({"*", ".", "t", "x", "t", "ret"})
check(fc.wait_event("dialog_closed", 2000), "expected glob select dialog to close")

local selected = fc.selected()
check(#selected == 2, "expected 2 selected after '*.txt', got %d", #selected)
check(contains_path_suffix(selected, "/apple.txt"), "expected apple.txt selected")
check(contains_path_suffix(selected, "/banana.txt"), "expected banana.txt selected")

-- 2) '-' opens deselect dialog and deselects by glob.
fc.key("-")
check(fc.wait_event("dialog_opened", 2000), "expected glob deselect dialog to open")
fc.key({"a", "p", "p", "l", "e", "*", "ret"})
check(fc.wait_event("dialog_closed", 2000), "expected glob deselect dialog to close")

selected = fc.selected()
check(#selected == 1, "expected 1 selected after deselect, got %d", #selected)
check(contains_path_suffix(selected, "/banana.txt"), "expected banana.txt to remain selected")

-- 3) Palette path can open glob select command.
fc.key("f1")
check(fc.wait_event("dialog_opened", 2000), "expected command palette to open")
fc.key({"g", "l", "o", "b", " ", "s", "e", "l", "e", "c", "t", "ret"})
check(fc.wait_event("dialog_opened", 2000), "expected glob select to open from palette")
fc.key("esc")
check(fc.wait_event("dialog_closed", 2000), "expected glob select close")

h.cleanup(src, dst)
test_pass("glob_select_deselect")
fc.quit()
