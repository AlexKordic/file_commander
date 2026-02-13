-- test/test_copy.lua
-- End-to-end test: copy files from left panel to right panel.
--
-- Usage: ./fc run test/test_copy.lua

local h = dofile("test/helpers.lua")

-- Setup test environment
local src, dst = h.setup_copy_test()
-- src contains: alpha.txt, beta.txt, subdir/gamma.txt

-- Navigate panels to test directories
fc.left_cd(src)
fc.right_cd(dst)

-- Verify panels are at the right locations
check(fc.left_path() == src,  "left panel at source: got %s", fc.left_path())
check(fc.right_path() == dst, "right panel at dest: got %s",  fc.right_path())

-- Verify source has the expected files
local s = fc.state()
check(s.left.item_count >= 3, "source has >= 3 items, got %d", s.left.item_count)

-- Select all files in left panel
fc.key("cA")
local sel = fc.selected()
check(#sel >= 3, "selected >= 3 items, got %d", #sel)

-- Open copy dialog (F5) and wait for discovery to finish
fc.key("f5")
fc.wait_event("discovery_completed", 5000)

-- Navigate from Cancel to COPY button and confirm
fc.key({"<-", "ret"})

-- Wait for background copy job to complete
fc.wait_for_jobs()

-- Verify no errors
local errs = fc.errors()
check(#errs == 0, "no errors after copy, got %d", #errs)

-- Verify files exist in destination
check(h.file_exists(dst .. "/alpha.txt"),          "alpha.txt copied")
check(h.file_exists(dst .. "/beta.txt"),           "beta.txt copied")
check(h.dir_exists(dst .. "/subdir"),              "subdir/ copied")
check(h.file_exists(dst .. "/subdir/gamma.txt"),   "subdir/gamma.txt copied")

-- Verify content is correct
check(h.read_file(dst .. "/alpha.txt") == "alpha content\n",          "alpha.txt content matches")
check(h.read_file(dst .. "/beta.txt")  == "beta content\n",           "beta.txt content matches")
check(h.read_file(dst .. "/subdir/gamma.txt") == "gamma content\n",   "gamma.txt content matches")

-- Cleanup temp directories
h.cleanup(src, dst)

test_pass("test_copy")
fc.quit()
