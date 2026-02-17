-- test/test_single_panel.lua
-- End-to-end checks for single-panel full-width mode toggle.
-- Usage: ./build/fc run test/test_single_panel.lua

local h = dofile("test/helpers.lua")

local left_dir  = h.tmpdir("single_left")
local right_dir = h.tmpdir("single_right")
h.mkdir(left_dir)
h.mkdir(right_dir)
h.create_file(left_dir .. "/left.txt", "left\n")
h.create_file(right_dir .. "/right.txt", "right\n")

fc.left_cd(left_dir)
fc.right_cd(right_dir)
fc.sleep(120)

local function focused_side()
  local focused = fc.focused()
  check(focused ~= nil, "focused item should exist")
  if focused:sub(1, #left_dir) == left_dir then return "left" end
  if focused:sub(1, #right_dir) == right_dir then return "right" end
  return "unknown"
end

local function ensure_left_focus()
  if focused_side() ~= "left" then
    fc.key("tab")
    fc.sleep(80)
    check(focused_side() == "left", "failed to focus left panel")
  end
end

ensure_left_focus()

local st = fc.state()
check(st.single_panel_mode == false, "single_panel_mode should be false at startup")

-- 1) Direct shortcut toggle.
fc.key("toggle_single_panel_mode")
fc.sleep(120)
st = fc.state()
check(st.single_panel_mode == true, "single_panel_mode should be true after toggle action")

-- Switch-panel command still works while single-panel mode is active.
local before = focused_side()
fc.key("switch_panel")
fc.sleep(120)
local after = focused_side()
check(before ~= after, "switch command should change focused side in single mode")

-- 2) Palette toggle command.
fc.key("toggle_single_panel_mode")
fc.sleep(120)
st = fc.state()
check(st.single_panel_mode == false, "single_panel_mode should be false after second toggle action")

h.cleanup(left_dir, right_dir)
test_pass("single_panel_toggle")
fc.quit()
