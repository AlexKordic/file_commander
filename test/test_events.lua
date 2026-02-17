-- test/test_events.lua
-- Verifies Lua event stream for selection/items/errors.

local h = dofile("test/helpers.lua")

local src = h.tmpdir("events_src")
local dst = h.tmpdir("events_dst")
h.mkdir(src)
h.mkdir(dst)
h.create_file(src .. "/a.txt", "a\n")
h.create_file(src .. "/b.txt", "b\n")

h.cd(src, dst)

local function drain_events()
  fc.wait_event("__drain__", 20)
end

h.ensure_left_focus()

-- 1) selection_changed

drain_events()
fc.key(" ")
check(fc.wait_event("selection_changed", 1000), "expected selection_changed on select")
fc.key("esc")
check(fc.wait_event("selection_changed", 1000), "expected selection_changed on clear")

-- 2) items_updated

drain_events()
h.create_file(src .. "/c.txt", "c\n")
fc.key("cR")
check(fc.wait_event("items_updated", 1000), "expected items_updated after refresh")

-- 3) error_reported + errors_cleared

drain_events()
fc.left_cd(src .. "/does_not_exist")
check(fc.wait_event("error_reported", 1000), "expected error_reported after invalid cd")
fc.key({"esc", "esc", "esc"})
check(fc.wait_event("errors_cleared", 1000), "expected errors_cleared after triple-esc")

-- 4) sequential waits should preserve trailing events from same poll cycle

drain_events()
h.ensure_left_focus()
fc.key("cA")
fc.key("f5")
check(fc.wait_event("dialog_opened", 2000), "expected copy dialog open")
check(fc.wait_event("discovery_completed", 10000), "expected discovery_completed after dialog_opened")
fc.key("esc")
check(fc.wait_event("dialog_closed", 2000), "expected copy dialog close")

h.cleanup(src, dst)
test_pass("events_basic")
fc.quit()
