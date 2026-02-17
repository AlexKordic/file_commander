-- test/test_rebind.lua
-- End-to-end checks for command shortcut rebinding from command palette.
-- Usage: ./build/fc run test/test_rebind.lua

local h = dofile("test/helpers.lua")

local src = h.tmpdir("rebind_src")
local dst = h.tmpdir("rebind_dst")

h.mkdir(src)
h.mkdir(dst)
h.create_file(src .. "/alpha.txt", "alpha\n")

h.cd(src, dst)

-- Rebind copy from F5 to F9 using command palette rebind mode.
fc.key("f1")
check(fc.wait_event("dialog_opened", 2000), "expected command palette open")
fc.key({"c", "o", "p", "y"})
fc.key("cK")
fc.key("f9")
fc.key("esc")
check(fc.wait_event("dialog_closed", 2000), "expected command palette close")

-- Verify new key executes copy dialog.
fc.key("f9")
check(fc.wait_event("dialog_opened", 2000), "expected copy dialog open on rebound f9")
check(fc.wait_event("discovery_completed", 10000), "expected copy discovery complete")
fc.key("esc")
check(fc.wait_event("dialog_closed", 2000), "expected copy dialog close")

h.cleanup(src, dst)
test_pass("rebind_copy_key_basic")
fc.quit()
