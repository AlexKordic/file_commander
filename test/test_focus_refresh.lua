-- test/test_focus_refresh.lua
-- Verifies focused item stays stable on refresh when a new file sorts before it.

local h = dofile("test/helpers.lua")

local function norm(path)
  if not path then return nil end
  return h.realpath(path) or path
end

local src = h.tmpdir("focus_refresh_src")
local dst = h.tmpdir("focus_refresh_dst")
h.mkdir(src)
h.mkdir(dst)
h.create_file(src .. "/b.txt", "b\n")
h.create_file(src .. "/c.txt", "c\n")

fc.left_cd(src)
fc.right_cd(dst)
fc.sleep(150)

-- Ensure focused panel is left.
local left_norm = norm(src)
local focused = fc.focused()
if not focused or not norm(focused):find(left_norm, 1, true) then
  fc.key("tab")
  fc.sleep(80)
  focused = fc.focused()
end
check(focused ~= nil, "focused item exists")
check(norm(focused):find(left_norm, 1, true) ~= nil, "left panel focused")

-- Move focus from b.txt -> c.txt.
fc.key("down")
fc.sleep(80)
local focused_before = fc.focused()
check(focused_before ~= nil, "focused_before exists")
check(norm(focused_before) == norm(src .. "/c.txt"),
      "expected focus on c.txt, got %s", tostring(focused_before))

-- External file creation that sorts before current focus.
h.create_file(src .. "/a.txt", "a\n")

-- Trigger explicit refresh (Ctrl+R) for deterministic test behavior.
fc.key("cR")
fc.sleep(120)

local state = fc.state()
check(state.left.item_count >= 3, "expected refreshed item_count >= 3, got %d", state.left.item_count)

local focused_after = fc.focused()
check(norm(focused_after) == norm(focused_before),
      "focus drifted after refresh: before=%s after=%s", tostring(focused_before), tostring(focused_after))

h.cleanup(src, dst)
test_pass("focus_refresh_stable")
fc.quit()
