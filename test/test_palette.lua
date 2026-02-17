-- test/test_palette.lua
-- End-to-end checks for P3.1 command palette.
-- Usage: ./build/fc run test/test_palette.lua

local h = dofile("test/helpers.lua")

local src = h.tmpdir("palette_src")
local dst = h.tmpdir("palette_dst")

h.mkdir(src)
h.mkdir(dst)
h.create_file(src .. "/left_a.txt", "left\n")
h.create_file(src .. "/left_b.txt", "left\n")
h.create_file(dst .. "/right_a.txt", "right\n")

h.cd(src, dst)

local function select_all_from_focused_panel()
  fc.key("cA")
  local sel = fc.selected()
  check(#sel > 0, "expected non-empty selection")
  return sel
end

-- Ensure initial focus is on the left panel.
local sel = select_all_from_focused_panel()
if sel[1]:sub(1, #src) ~= src then
  fc.key("cA")
  fc.key("tab")
  h.wait_event("focus_changed", 2000, "expected focus_changed to left panel")
  sel = select_all_from_focused_panel()
  check(sel[1]:sub(1, #src) == src, "failed to move focus to left panel")
end
fc.key("cA")

-- 1) Open palette and run Copy command via fuzzy filter.
fc.key("f1")
check(fc.wait_event("dialog_opened", 2000), "expected palette to open")

fc.key({"c", "o", "p", "y", "ret"})
check(fc.wait_event("dialog_opened", 2000), "expected Copy dialog to open from palette")

-- Close copy dialog without executing copy.
fc.key("esc")
check(fc.wait_event("dialog_closed", 2000), "expected Copy dialog close")

-- 2) Re-open palette and run Switch Panel command.
local before = select_all_from_focused_panel()
local before_is_left = before[1]:sub(1, #src) == src
fc.key("cA")

fc.key("f1")
check(fc.wait_event("dialog_opened", 2000), "expected palette to re-open")
fc.key({"s", "w", "i", "t", "c", "h", "ret"})
check(fc.wait_event("focus_changed", 2000), "expected focus_changed after switch panel command")

local after = select_all_from_focused_panel()
local after_is_left = after[1]:sub(1, #src) == src
check(before_is_left ~= after_is_left, "expected switch panel command to change focus")
fc.key("cA")

h.cleanup(src, dst)
test_pass("command_palette_basic")
fc.quit()
