-- test/test_tabs.lua
-- End-to-end checks for per-panel tabs.
-- Usage: ./build/fc run test/test_tabs.lua

local h = dofile("test/helpers.lua")

local left_a = h.tmpdir("tabs_left_a")
local left_b = h.tmpdir("tabs_left_b")
local right_dir = h.tmpdir("tabs_right")
h.mkdir(left_a)
h.mkdir(left_b)
h.mkdir(right_dir)
h.create_file(left_a .. "/a.txt", "a\n")
h.create_file(left_b .. "/b.txt", "b\n")
h.create_file(right_dir .. "/r.txt", "r\n")

fc.left_cd(left_a)
fc.right_cd(right_dir)
fc.sleep(120)

local function focused_side()
  local focused = fc.focused()
  if focused and focused:sub(1, #left_a) == left_a then return "left" end
  if focused and focused:sub(1, #left_b) == left_b then return "left" end
  if focused and focused:sub(1, #right_dir) == right_dir then return "right" end
  return "unknown"
end

local function ensure_left_focus()
  local left_path = fc.left_path()

  local function selected_in_left()
    fc.key("cA")
    local sel = fc.selected()
    if #sel == 0 then return false end
    local ok = sel[1]:sub(1, #left_path) == left_path
    fc.key("esc")
    return ok
  end

  if selected_in_left() then return end
  for _ = 1, 2 do
    fc.key("tab")
    fc.sleep(80)
    if selected_in_left() then return end
  end
  check(false, "failed to focus left panel")
end

local function count_tabs(side_state)
  return #side_state.tabs
end

local function active_tab_path(side_state)
  for _, t in ipairs(side_state.tabs) do
    if t.active then return t.path end
  end
  return nil
end

ensure_left_focus()

local st = fc.state()
check(count_tabs(st.left) == 1, "left should start with one tab")
check(active_tab_path(st.left) == left_a, "initial left tab path should be left_a")

-- 1) Create tab from current path.
fc.key("tab_new")
fc.sleep(120)
st = fc.state()
check(
  count_tabs(st.left) == 2,
  "left should have two tabs after tab_new (left=%d right=%d)",
  count_tabs(st.left),
  count_tabs(st.right)
)
check(active_tab_path(st.left) == left_a, "new tab should clone current directory")

-- 2) Move active tab to a different path.
fc.left_cd(left_b)
fc.sleep(120)
st = fc.state()
check(active_tab_path(st.left) == left_b, "active tab should move to left_b")
check(st.left.tabs[1].path == left_a, "first tab should keep original path")

-- 3) Switch back/forward tabs.
fc.key("tab_prev")
fc.sleep(120)
st = fc.state()
check(active_tab_path(st.left) == left_a, "tab_prev should switch back to left_a")

fc.key("tab_next")
fc.sleep(120)
st = fc.state()
check(active_tab_path(st.left) == left_b, "tab_next should switch to left_b")

-- 4) Close active tab and ensure fallback tab is focused.
fc.key("tab_close")
fc.sleep(120)
st = fc.state()
check(count_tabs(st.left) == 1, "left should have one tab after tab_close")
check(active_tab_path(st.left) == left_a, "closing second tab should return to first")
check(fc.left_path() == left_a, "left_path should match active tab path after close")

h.cleanup(left_a, left_b, right_dir)
test_pass("tabs_basic")
fc.quit()
