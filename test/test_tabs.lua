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

h.cd(left_a, right_dir)

local function count_tabs(side_state)
  return #side_state.tabs
end

local function active_tab_path(side_state)
  for _, t in ipairs(side_state.tabs) do
    if t.active then return t.path end
  end
  return nil
end

h.ensure_left_focus()

local st = fc.state()
check(count_tabs(st.left) == 1, "left should start with one tab")
check(active_tab_path(st.left) == left_a, "initial left tab path should be left_a")
local initial_perm = st.left.show_permissions_column
local initial_owner_group = st.left.show_owner_group_column

-- 1) Create tab from current path.
fc.key("tab_new")
check(fc.wait_event("tab_created", 2000), "expected tab_created")
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
check(fc.wait_event("dir_changed", 2000), "expected dir_changed after left_cd(left_b)")
st = fc.state()
check(active_tab_path(st.left) == left_b, "active tab should move to left_b")
check(st.left.tabs[1].path == left_a, "first tab should keep original path")

-- 3) Toggle per-tab column visibility in active (second) tab.
fc.key("toggle_permissions_column")
fc.key("toggle_owner_group_column")
st = fc.state()
check(
  st.left.show_permissions_column == (not initial_perm),
  "permissions column toggle should apply in active tab"
)
check(
  st.left.show_owner_group_column == (not initial_owner_group),
  "owner/group column toggle should apply in active tab"
)

-- 4) Switch back/forward tabs and verify per-tab column state.
fc.key("tab_prev")
check(fc.wait_event("tab_switched", 2000), "expected tab_switched (prev)")
st = fc.state()
check(active_tab_path(st.left) == left_a, "tab_prev should switch back to left_a")
check(
  st.left.show_permissions_column == initial_perm,
  "first tab should keep original permissions column visibility"
)
check(
  st.left.show_owner_group_column == initial_owner_group,
  "first tab should keep original owner/group column visibility"
)

fc.key("tab_next")
check(fc.wait_event("tab_switched", 2000), "expected tab_switched (next)")
st = fc.state()
check(active_tab_path(st.left) == left_b, "tab_next should switch to left_b")
check(
  st.left.show_permissions_column == (not initial_perm),
  "second tab should keep toggled permissions column visibility"
)
check(
  st.left.show_owner_group_column == (not initial_owner_group),
  "second tab should keep toggled owner/group column visibility"
)

-- 5) Close active tab and ensure fallback tab is focused.
fc.key("tab_close")
check(fc.wait_event("tab_closed", 2000), "expected tab_closed")
st = fc.state()
check(count_tabs(st.left) == 1, "left should have one tab after tab_close")
check(active_tab_path(st.left) == left_a, "closing second tab should return to first")
check(fc.left_path() == left_a, "left_path should match active tab path after close")
check(
  st.left.show_permissions_column == initial_perm,
  "after closing second tab, permissions column visibility should match first tab"
)
check(
  st.left.show_owner_group_column == initial_owner_group,
  "after closing second tab, owner/group column visibility should match first tab"
)

h.cleanup(left_a, left_b, right_dir)
test_pass("tabs_basic")
fc.quit()
