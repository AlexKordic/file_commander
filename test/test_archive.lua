-- test/test_archive.lua
-- End-to-end archive workflow:
-- 1) Create .7z from copy dialog
-- 2) Enter archive as if it were a directory
-- 3) Copy files out of archive with copy dialog
-- 4) Leave archive root back to parent directory

local h = require("test/helpers")

local src = h.tmpdir("archive_src")
local dst = h.tmpdir("archive_dst")
local out = h.tmpdir("archive_out")

h.mkdir(src)
h.mkdir(dst)
h.mkdir(out)
h.mkdir(src .. "/sub")
h.create_file(src .. "/alpha.txt", "alpha\n")
h.create_file(src .. "/sub/bravo.txt", "bravo\n")

h.cd(src, dst)
h.ensure_left_focus()

-- Create archive in right directory via copy dialog.
fc.key("cA")
fc.key("f5")
check(fc.wait_event("discovery_completed", 10000), "expected discovery for archive create")

-- Focus destination input and append archive file name.
fc.key("up")
for c in string.gmatch("/bundle.7z", ".") do
  fc.key(c)
end

-- Confirm copy (now archive create job).
fc.key("f5")
check(fc.wait_event("dialog_closed", 2000), "expected copy dialog to close after archive create submit")
check(fc.wait_for_jobs(30000), "expected archive creation job completion")
check(h.file_exists(dst .. "/bundle.7z"), "archive should exist after creation")
fc.right_cd(dst)
h.wait_event("dir_changed", 2000, "expected dir_changed after right_cd(dst)")

-- Focus right panel and enter archive file.
fc.key("tab")
h.wait_event("focus_changed", 2000, "expected focus_changed to right panel")
fc.key("ret")
h.wait_event("dir_changed", 5000, "expected dir_changed after entering archive")
check(fc.right_path() ~= dst, "right panel should point to extracted archive content")

-- Copy extracted content to explicit output directory using copy dialog.
fc.left_cd(out)
h.wait_event("dir_changed", 2000, "expected dir_changed after left_cd(out)")
fc.key("cA")
local sel = fc.selected()
check(#sel > 0 and sel[1]:sub(1, #fc.right_path()) == fc.right_path(), "expected selection from archive panel")
fc.key("f5")
check(fc.wait_event("discovery_completed", 10000), "expected discovery in archive copy")
fc.key({"<-", "ret"})
check(fc.wait_event("dialog_closed", 2000), "expected copy dialog to close after extraction submit")
check(fc.wait_for_jobs(30000), "expected extraction copy job completion")

check(h.file_exists(out .. "/alpha.txt"), "alpha should be extracted")
check(h.file_exists(out .. "/sub/bravo.txt"), "bravo should be extracted")

-- Leave archive root and return to parent directory with archive file focused.
fc.key("?")
h.wait_event("dir_changed", 5000, "expected dir_changed after leaving archive root")
check(h.realpath(fc.right_path()) == h.realpath(dst), "right panel should return to archive parent directory")

h.cleanup(src, dst, out)
test_pass("archive_create_enter_extract")
fc.quit()
