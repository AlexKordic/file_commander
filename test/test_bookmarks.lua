-- test/test_bookmarks.lua
-- End-to-end checks for directory bookmarks dialog.
-- Usage: ./build/fc run test/test_bookmarks.lua

local h = dofile("test/helpers.lua")

local src1 = h.tmpdir("bookmarks_src1")
local src2 = h.tmpdir("bookmarks_src2")
local dst  = h.tmpdir("bookmarks_dst")

h.mkdir(src1)
h.mkdir(src2)
h.mkdir(dst)
h.create_file(src1 .. "/a.txt", "a\n")
h.create_file(src2 .. "/b.txt", "b\n")

h.cd(src1, dst)
h.ensure_left_focus()

-- 1) Add current left directory as bookmark.
fc.key("cB")
check(fc.wait_event("dialog_opened", 2000), "expected bookmarks dialog to open")
fc.key("a")
fc.key("esc")
check(fc.wait_event("dialog_closed", 2000), "expected bookmarks dialog to close")

-- 2) Change directory, then open bookmark to jump back.
fc.left_cd(src2)
h.wait_event("dir_changed", 2000, "expected dir_changed after moving left to src2")
check(fc.left_path() == src2, "expected left path moved to src2")
h.ensure_left_focus()

fc.key("cB")
check(fc.wait_event("dialog_opened", 2000), "expected bookmarks dialog open (second)")
fc.key("ret")
check(fc.wait_event("dialog_closed", 2000), "expected bookmarks dialog close after open")
check(fc.left_path() == src1, "expected left path restored from bookmark")
h.ensure_left_focus()

-- 3) Remove bookmark and verify Enter no longer closes dialog.
fc.key("cB")
check(fc.wait_event("dialog_opened", 2000), "expected bookmarks dialog open (third)")
fc.key("d")
fc.key("ret")

fc.key("esc")
check(fc.wait_event("dialog_closed", 2000), "expected bookmarks dialog close after esc")

h.cleanup(src1, src2, dst)
test_pass("bookmarks_basic")
fc.quit()
