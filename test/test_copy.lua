-- test/test_copy.lua
-- Comprehensive end-to-end copy operation tests.
--
-- Tests cover: basic copy, nested directories, symlinks (absolute, relative,
-- chains, cycles, dangling), follow-links mode, overwrite behavior,
-- special characters in filenames, hidden files, empty directories,
-- deep nesting, and mixed-content directories.
--
-- Usage: ./build/fc run test/test_copy.lua

local h = dofile("test/helpers.lua")

-- =========================================================================
-- Helper: run a single copy test case
-- =========================================================================

--- Setup panels, run copy, return number of NEW errors (since before copy).
--- src and dst must already exist.
--- opts is passed to h.do_copy() for checkbox toggling.
local function run_copy_test(src, dst, opts)
  h.cd(src, dst)

  check(fc.left_path() == src,  "left panel at source: got %s", fc.left_path())
  check(fc.right_path() == dst, "right panel at dest: got %s",  fc.right_path())

  local errs_before = #fc.errors()
  h.do_copy(opts)
  local errs_after = #fc.errors()

  return errs_after - errs_before
end

local function wait_until_job_items_done(min_items_done, timeout_ms)
  local deadline = os.clock() + ((timeout_ms or 5000) / 1000.0)
  while os.clock() < deadline do
    local s = fc.state()
    if s.jobs.items_done >= min_items_done then
      return true
    end
    fc.wait_event("job_progress", 250)
  end
  return false
end

-- =========================================================================
-- 1. Basic copy: single file
-- =========================================================================

local function test_basic_single_file()
  local src = h.tmpdir("basic1_src")
  local dst = h.tmpdir("basic1_dst")
  h.mkdir(src)
  h.mkdir(dst)
  h.create_file(src .. "/hello.txt", "hello world\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "1: no new errors, got %d", new_errs)
  check(h.file_exists(dst .. "/hello.txt"), "1: file copied")
  check(h.read_file(dst .. "/hello.txt") == "hello world\n", "1: content matches")

  h.cleanup(src, dst)
  test_pass("1_basic_single_file")
end

-- =========================================================================
-- 2. Basic copy: multiple files
-- =========================================================================

local function test_basic_multiple_files()
  local src = h.tmpdir("basic2_src")
  local dst = h.tmpdir("basic2_dst")
  h.mkdir(src)
  h.mkdir(dst)
  h.create_file(src .. "/alpha.txt", "alpha content\n")
  h.create_file(src .. "/beta.txt",  "beta content\n")
  h.create_file(src .. "/gamma.txt", "gamma content\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "2: no new errors, got %d", new_errs)
  check(h.read_file(dst .. "/alpha.txt") == "alpha content\n", "2: alpha content")
  check(h.read_file(dst .. "/beta.txt")  == "beta content\n",  "2: beta content")
  check(h.read_file(dst .. "/gamma.txt") == "gamma content\n", "2: gamma content")

  h.cleanup(src, dst)
  test_pass("2_basic_multiple_files")
end

-- =========================================================================
-- 3. Nested directories
-- =========================================================================

local function test_nested_directories()
  local src = h.tmpdir("nested_src")
  local dst = h.tmpdir("nested_dst")
  h.mkdir(src .. "/a/b/c")
  h.mkdir(dst)
  h.create_file(src .. "/top.txt", "top\n")
  h.create_file(src .. "/a/mid.txt", "mid\n")
  h.create_file(src .. "/a/b/deep.txt", "deep\n")
  h.create_file(src .. "/a/b/c/bottom.txt", "bottom\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "3: no new errors, got %d", new_errs)
  check(h.file_exists(dst .. "/top.txt"), "3: top.txt")
  check(h.dir_exists(dst .. "/a"), "3: a/")
  check(h.dir_exists(dst .. "/a/b"), "3: a/b/")
  check(h.dir_exists(dst .. "/a/b/c"), "3: a/b/c/")
  check(h.read_file(dst .. "/a/mid.txt") == "mid\n", "3: a/mid.txt content")
  check(h.read_file(dst .. "/a/b/deep.txt") == "deep\n", "3: a/b/deep.txt content")
  check(h.read_file(dst .. "/a/b/c/bottom.txt") == "bottom\n", "3: a/b/c/bottom.txt content")

  h.cleanup(src, dst)
  test_pass("3_nested_directories")
end

-- =========================================================================
-- 4. Empty directory
-- =========================================================================

local function test_empty_directory()
  local src = h.tmpdir("empty_src")
  local dst = h.tmpdir("empty_dst")
  h.mkdir(src .. "/empty_dir")
  h.mkdir(dst)
  -- Also add a file so selection has something visible
  h.create_file(src .. "/marker.txt", "m\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "4: no errors, got %d", new_errs)
  check(h.dir_exists(dst .. "/empty_dir"), "4: empty dir exists")
  check(h.file_exists(dst .. "/marker.txt"), "4: marker file copied")

  h.cleanup(src, dst)
  test_pass("4_empty_directory")
end

-- =========================================================================
-- 5. Deep nesting (10 levels)
-- =========================================================================

local function test_deep_nesting()
  local src = h.tmpdir("deep_src")
  local dst = h.tmpdir("deep_dst")

  -- Build path: d0/d1/d2/.../d9
  local deep = src
  for i = 0, 9 do
    deep = deep .. "/d" .. i
  end
  h.mkdir(deep)
  h.create_file(deep .. "/leaf.txt", "leaf\n")
  h.mkdir(dst)

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "5: no errors, got %d", new_errs)

  -- Verify the leaf file exists at full depth
  local dst_deep = dst
  for i = 0, 9 do
    dst_deep = dst_deep .. "/d" .. i
  end
  check(h.dir_exists(dst_deep), "5: deep dir exists")
  check(h.read_file(dst_deep .. "/leaf.txt") == "leaf\n", "5: leaf content matches")

  h.cleanup(src, dst)
  test_pass("5_deep_nesting")
end

-- =========================================================================
-- 6. Hidden files and directories
-- =========================================================================

local function test_hidden_files()
  local src = h.tmpdir("hidden_src")
  local dst = h.tmpdir("hidden_dst")
  h.mkdir(src .. "/.hidden_dir")
  h.mkdir(dst)
  h.create_file(src .. "/.hidden_file", "hidden\n")
  h.create_file(src .. "/.hidden_dir/.nested_hidden", "nested hidden\n")
  h.create_file(src .. "/visible.txt", "visible\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "6: no errors, got %d", new_errs)
  check(h.file_exists(dst .. "/visible.txt"), "6: visible file")
  check(h.file_exists(dst .. "/.hidden_file"), "6: hidden file")
  check(h.dir_exists(dst .. "/.hidden_dir"), "6: hidden dir")
  check(h.file_exists(dst .. "/.hidden_dir/.nested_hidden"), "6: nested hidden file")

  h.cleanup(src, dst)
  test_pass("6_hidden_files")
end

-- =========================================================================
-- 7. Files with special characters in names
-- =========================================================================

local function test_special_characters()
  local src = h.tmpdir("special_src")
  local dst = h.tmpdir("special_dst")
  h.mkdir(src)
  h.mkdir(dst)

  -- Spaces, parentheses, brackets, unicode
  h.create_file(src .. "/file with spaces.txt", "spaces\n")
  h.create_file(src .. "/file(parens).txt", "parens\n")
  h.create_file(src .. "/file[brackets].txt", "brackets\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "7: no errors, got %d", new_errs)
  check(h.read_file(dst .. "/file with spaces.txt") == "spaces\n", "7: spaces file")
  check(h.read_file(dst .. "/file(parens).txt") == "parens\n", "7: parens file")
  check(h.read_file(dst .. "/file[brackets].txt") == "brackets\n", "7: brackets file")

  h.cleanup(src, dst)
  test_pass("7_special_characters")
end

-- =========================================================================
-- 8. Absolute symlink (default mode: preserve as absolute symlink)
-- =========================================================================

local function test_absolute_symlink()
  local src = h.tmpdir("abslink_src")
  local dst = h.tmpdir("abslink_dst")
  h.mkdir(src)
  h.mkdir(dst)

  -- Create a real file and an absolute symlink to it
  h.create_file(src .. "/target.txt", "target content\n")
  h.create_symlink(src .. "/target.txt", src .. "/abs_link.txt")

  -- Verify source setup
  check(h.is_symlink(src .. "/abs_link.txt"), "8: source symlink exists")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "8: no errors, got %d", new_errs)
  check(h.file_exists(dst .. "/target.txt"), "8: target file copied")

  -- The symlink should be recreated in destination pointing to the source's target
  -- (canonicalized absolute path)
  check(h.is_symlink(dst .. "/abs_link.txt"), "8: symlink recreated")

  -- Reading through the symlink should work (target was copied, but the symlink
  -- points to the *source* location's canonical path, not the destination copy)
  -- This is expected behavior — the absolute symlink target is preserved.
  local link_target = h.read_symlink(dst .. "/abs_link.txt")
  check(link_target ~= nil, "8: can read symlink target")

  h.cleanup(src, dst)
  test_pass("8_absolute_symlink")
end

-- =========================================================================
-- 9. Relative symlink (preserve mode, default)
-- =========================================================================

local function test_relative_symlink()
  local src = h.tmpdir("rellink_src")
  local dst = h.tmpdir("rellink_dst")
  h.mkdir(src .. "/sub")
  h.mkdir(dst)

  h.create_file(src .. "/target.txt", "rel target\n")
  h.create_file(src .. "/sub/inner.txt", "inner\n")

  -- Create relative symlinks
  h.create_symlink("./target.txt", src .. "/rel_same_dir.txt")
  h.create_symlink("../target.txt", src .. "/sub/rel_parent.txt")

  -- Verify source
  check(h.is_symlink(src .. "/rel_same_dir.txt"), "9: same-dir symlink")
  check(h.read_symlink(src .. "/rel_same_dir.txt") == "./target.txt", "9: same-dir target")
  check(h.is_symlink(src .. "/sub/rel_parent.txt"), "9: parent symlink")
  check(h.read_symlink(src .. "/sub/rel_parent.txt") == "../target.txt", "9: parent target")

  -- Default mode: preserve_relative_links=true, follow_links=false
  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "9: no errors, got %d", new_errs)

  -- Relative symlinks should be preserved verbatim
  check(h.is_symlink(dst .. "/rel_same_dir.txt"), "9: same-dir symlink in dest")
  check(h.read_symlink(dst .. "/rel_same_dir.txt") == "./target.txt",
        "9: same-dir symlink target preserved: got %s", h.read_symlink(dst .. "/rel_same_dir.txt"))

  check(h.is_symlink(dst .. "/sub/rel_parent.txt"), "9: parent symlink in dest")
  check(h.read_symlink(dst .. "/sub/rel_parent.txt") == "../target.txt",
        "9: parent symlink target preserved: got %s", h.read_symlink(dst .. "/sub/rel_parent.txt"))

  -- The relative links should resolve correctly within the copied tree
  check(h.read_file(dst .. "/rel_same_dir.txt") == "rel target\n",
        "9: same-dir symlink resolves to correct content")
  check(h.read_file(dst .. "/sub/rel_parent.txt") == "rel target\n",
        "9: parent symlink resolves to correct content")

  h.cleanup(src, dst)
  test_pass("9_relative_symlink")
end

-- =========================================================================
-- 10. Symlink chain: A -> B -> C (regular file)
-- =========================================================================

local function test_symlink_chain()
  local src = h.tmpdir("chain_src")
  local dst = h.tmpdir("chain_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/real_file.txt", "chain end\n")
  h.create_symlink("./real_file.txt", src .. "/link_b.txt")
  h.create_symlink("./link_b.txt", src .. "/link_a.txt")

  -- link_a -> link_b -> real_file.txt
  check(h.read_file(src .. "/link_a.txt") == "chain end\n", "10: chain resolves in source")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "10: no errors, got %d", new_errs)
  check(h.file_exists(dst .. "/real_file.txt"), "10: real file copied")

  -- With default preserve-relative mode, both links should be recreated as symlinks
  check(h.is_symlink(dst .. "/link_b.txt"), "10: link_b is symlink")
  check(h.is_symlink(dst .. "/link_a.txt"), "10: link_a is symlink")

  -- The chain should still resolve in the destination
  check(h.read_file(dst .. "/link_a.txt") == "chain end\n", "10: chain resolves in dest")

  h.cleanup(src, dst)
  test_pass("10_symlink_chain")
end

-- =========================================================================
-- 11. Circular symlinks: A -> B -> A
-- =========================================================================

local function test_circular_symlinks()
  local src = h.tmpdir("circular_src")
  local dst = h.tmpdir("circular_dst")
  h.mkdir(src)
  h.mkdir(dst)

  -- Create a non-symlink file so the directory isn't empty
  h.create_file(src .. "/normal.txt", "normal\n")

  -- Create circular symlink pair: cyc_a -> cyc_b, cyc_b -> cyc_a
  -- Use absolute paths to ensure the cycle is detected by resolve_symlink
  h.create_symlink(src .. "/cyc_b", src .. "/cyc_a")
  h.create_symlink(src .. "/cyc_a", src .. "/cyc_b")

  -- Verify cycle exists
  check(h.is_symlink(src .. "/cyc_a"), "11: cyc_a is symlink")
  check(h.is_symlink(src .. "/cyc_b"), "11: cyc_b is symlink")

  local new_errs = run_copy_test(src, dst)

  -- The normal file should still be copied
  check(h.file_exists(dst .. "/normal.txt"), "11: normal file copied despite cycle")
  check(h.read_file(dst .. "/normal.txt") == "normal\n", "11: normal content matches")

  -- The circular symlinks should be detected during discovery.
  -- With default mode (preserve_relative=true, follow=false), absolute symlinks
  -- go through resolve_symlink which detects the cycle.
  -- Error "Cyclic symlink" should be reported in discovery.
  -- Note: errors may or may not appear in fc.errors() depending on whether
  -- discovery errors propagate there. They are shown as warnings in the file list.

  h.cleanup(src, dst)
  test_pass("11_circular_symlinks")
end

-- =========================================================================
-- 12. Self-referencing symlink: A -> A
-- =========================================================================

local function test_self_referencing_symlink()
  local src = h.tmpdir("selfref_src")
  local dst = h.tmpdir("selfref_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/good.txt", "good\n")
  h.create_symlink(src .. "/self_link", src .. "/self_link")

  local new_errs = run_copy_test(src, dst)

  -- Good file should be copied regardless of the problematic symlink
  check(h.file_exists(dst .. "/good.txt"), "12: good file copied")

  h.cleanup(src, dst)
  test_pass("12_self_referencing_symlink")
end

-- =========================================================================
-- 13. Dangling symlink (target does not exist)
-- =========================================================================

local function test_dangling_symlink()
  local src = h.tmpdir("dangling_src")
  local dst = h.tmpdir("dangling_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/good.txt", "good\n")
  h.create_symlink("/nonexistent/path/file.txt", src .. "/dangling_link")

  check(h.is_symlink(src .. "/dangling_link"), "13: dangling symlink exists in source")

  local new_errs = run_copy_test(src, dst)

  -- Good file should be copied
  check(h.file_exists(dst .. "/good.txt"), "13: good file copied")

  -- Dangling symlink: behavior depends on implementation.
  -- With preserve mode, it may be recreated as a symlink to the nonexistent target.
  -- With follow mode, it would fail (can't read nonexistent target).
  -- Just verify the operation completes without crashing.

  h.cleanup(src, dst)
  test_pass("13_dangling_symlink")
end

-- =========================================================================
-- 14. Symlink to directory (default mode: preserve as symlink)
-- =========================================================================

local function test_symlink_to_directory()
  local src = h.tmpdir("dirlink_src")
  local dst = h.tmpdir("dirlink_dst")
  h.mkdir(src .. "/real_dir")
  h.mkdir(dst)
  h.create_file(src .. "/real_dir/in_dir.txt", "in dir\n")
  h.create_symlink("./real_dir", src .. "/link_to_dir")

  check(h.is_symlink(src .. "/link_to_dir"), "14: dir symlink exists")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "14: no errors, got %d", new_errs)

  -- Real directory and contents should be copied
  check(h.dir_exists(dst .. "/real_dir"), "14: real dir copied")
  check(h.file_exists(dst .. "/real_dir/in_dir.txt"), "14: file inside dir copied")

  -- Symlink should be preserved as a symlink (not a full directory copy)
  check(h.is_symlink(dst .. "/link_to_dir"), "14: dir symlink preserved")
  check(h.read_symlink(dst .. "/link_to_dir") == "./real_dir",
        "14: dir symlink target preserved: got %s", h.read_symlink(dst .. "/link_to_dir"))

  -- Reading through the symlink should work
  check(h.read_file(dst .. "/link_to_dir/in_dir.txt") == "in dir\n",
        "14: can read through dir symlink")

  h.cleanup(src, dst)
  test_pass("14_symlink_to_directory")
end

-- =========================================================================
-- 15. Follow links mode: symlink → file
-- =========================================================================

local function test_follow_links_file()
  local src = h.tmpdir("follow_file_src")
  local dst = h.tmpdir("follow_file_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/original.txt", "original content\n")
  h.create_symlink("./original.txt", src .. "/link_to_file.txt")

  local new_errs = run_copy_test(src, dst, {toggle_follow_links = true})
  check(new_errs == 0, "15: no errors, got %d", new_errs)

  -- Original file should still be copied
  check(h.file_exists(dst .. "/original.txt"), "15: original file copied")
  check(h.read_file(dst .. "/original.txt") == "original content\n", "15: original content")
  -- Follow mode should materialize the symlink entry as a regular file copy.
  check(h.file_exists(dst .. "/link_to_file.txt"), "15: followed link copied as file")
  check(not h.is_symlink(dst .. "/link_to_file.txt"), "15: followed link is not a symlink")
  check(h.read_file(dst .. "/link_to_file.txt") == "original content\n",
        "15: followed link content")

  h.cleanup(src, dst)
  test_pass("15_follow_links_file")
end

-- =========================================================================
-- 16. Follow links mode: symlink → directory
-- =========================================================================

local function test_follow_links_directory()
  local src = h.tmpdir("follow_dir_src")
  local dst = h.tmpdir("follow_dir_dst")
  h.mkdir(src .. "/actual_dir")
  h.mkdir(dst)
  h.create_file(src .. "/actual_dir/content.txt", "dir content\n")
  h.create_symlink("./actual_dir", src .. "/link_to_dir")

  local new_errs = run_copy_test(src, dst, {toggle_follow_links = true})
  check(new_errs == 0, "16: no errors, got %d", new_errs)

  -- The actual directory should be fully copied
  check(h.dir_exists(dst .. "/actual_dir"), "16: actual dir copied")
  check(h.file_exists(dst .. "/actual_dir/content.txt"), "16: content inside actual dir")
  -- Follow mode should make destination content reachable under link_to_dir.
  check(h.dir_exists(dst .. "/link_to_dir"), "16: followed dir path exists")
  check(h.file_exists(dst .. "/link_to_dir/content.txt"), "16: followed dir contains content")

  h.cleanup(src, dst)
  test_pass("16_follow_links_directory")
end

-- =========================================================================
-- 17. Overwrite existing file (smaller replaces larger)
-- =========================================================================

local function test_overwrite_smaller()
  local src = h.tmpdir("overwrite_sm_src")
  local dst = h.tmpdir("overwrite_sm_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/file.txt", "short\n")
  h.create_file(dst .. "/file.txt", "this is much longer content that should be overwritten\n")

  local orig_size = h.file_size(dst .. "/file.txt")
  check(orig_size > 10, "17: dest file is large initially: %d", orig_size)

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "17: no errors, got %d", new_errs)
  check(h.read_file(dst .. "/file.txt") == "short\n", "17: content overwritten with shorter")
  check(h.file_size(dst .. "/file.txt") == 6, "17: file truncated to source size")

  h.cleanup(src, dst)
  test_pass("17_overwrite_smaller")
end

-- =========================================================================
-- 18. Overwrite existing file (larger replaces smaller)
-- =========================================================================

local function test_overwrite_larger()
  local src = h.tmpdir("overwrite_lg_src")
  local dst = h.tmpdir("overwrite_lg_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/file.txt", "this is the new longer content\n")
  h.create_file(dst .. "/file.txt", "old\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "18: no errors, got %d", new_errs)
  check(h.read_file(dst .. "/file.txt") == "this is the new longer content\n",
        "18: content overwritten with larger")

  h.cleanup(src, dst)
  test_pass("18_overwrite_larger")
end

-- =========================================================================
-- 19. Overwrite: destination has extra files (they should remain)
-- =========================================================================

local function test_overwrite_extras_remain()
  local src = h.tmpdir("extras_src")
  local dst = h.tmpdir("extras_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/new.txt", "new\n")
  h.create_file(dst .. "/existing.txt", "existing\n")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "19: no errors, got %d", new_errs)
  check(h.read_file(dst .. "/new.txt") == "new\n", "19: new file copied")
  check(h.read_file(dst .. "/existing.txt") == "existing\n", "19: existing file untouched")

  h.cleanup(src, dst)
  test_pass("19_overwrite_extras_remain")
end

-- =========================================================================
-- 20. Mixed content: files + dirs + symlinks in one directory
-- =========================================================================

local function test_mixed_content()
  local src = h.tmpdir("mixed_src")
  local dst = h.tmpdir("mixed_dst")
  h.mkdir(src .. "/subdir")
  h.mkdir(dst)

  h.create_file(src .. "/regular.txt", "regular\n")
  h.create_file(src .. "/subdir/nested.txt", "nested\n")
  h.create_symlink("./regular.txt", src .. "/rel_link.txt")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "20: no errors, got %d", new_errs)
  check(h.file_exists(dst .. "/regular.txt"), "20: regular file")
  check(h.dir_exists(dst .. "/subdir"), "20: subdir")
  check(h.file_exists(dst .. "/subdir/nested.txt"), "20: nested file")
  check(h.is_symlink(dst .. "/rel_link.txt"), "20: symlink preserved")
  check(h.read_file(dst .. "/rel_link.txt") == "regular\n", "20: symlink resolves")

  h.cleanup(src, dst)
  test_pass("20_mixed_content")
end

-- =========================================================================
-- 21. Symlink chain through directories: dir_link -> real_dir/sub_link -> file
-- =========================================================================

local function test_symlink_chain_through_dirs()
  local src = h.tmpdir("dirchain_src")
  local dst = h.tmpdir("dirchain_dst")
  h.mkdir(src .. "/real_dir")
  h.mkdir(dst)

  h.create_file(src .. "/target_file.txt", "chain through dirs\n")
  -- sub_link inside real_dir points up to target_file.txt
  h.create_symlink("../target_file.txt", src .. "/real_dir/sub_link.txt")
  -- dir_link in root points to real_dir
  h.create_symlink("./real_dir", src .. "/dir_link")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "21: no errors, got %d", new_errs)

  -- All items should be preserved
  check(h.file_exists(dst .. "/target_file.txt"), "21: target file")
  check(h.dir_exists(dst .. "/real_dir"), "21: real dir")
  check(h.is_symlink(dst .. "/real_dir/sub_link.txt"), "21: sub_link is symlink")
  check(h.read_symlink(dst .. "/real_dir/sub_link.txt") == "../target_file.txt",
        "21: sub_link target: got %s", h.read_symlink(dst .. "/real_dir/sub_link.txt"))
  check(h.is_symlink(dst .. "/dir_link"), "21: dir_link is symlink")

  -- Reading through the chain should work in destination
  check(h.read_file(dst .. "/real_dir/sub_link.txt") == "chain through dirs\n",
        "21: sub_link resolves correctly")

  h.cleanup(src, dst)
  test_pass("21_symlink_chain_through_dirs")
end

-- =========================================================================
-- 22. Multiple files in many-item directory
-- =========================================================================

local function test_many_files()
  local src = h.tmpdir("many_src")
  local dst = h.tmpdir("many_dst")
  h.mkdir(src)
  h.mkdir(dst)

  local count = 30
  for i = 1, count do
    h.create_file(src .. string.format("/file_%03d.txt", i),
                  string.format("content %d\n", i))
  end

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "22: no errors, got %d", new_errs)

  -- Verify all files
  for i = 1, count do
    local name = string.format("/file_%03d.txt", i)
    check(h.file_exists(dst .. name), "22: " .. name .. " exists")
  end

  -- Spot-check content
  check(h.read_file(dst .. "/file_001.txt") == "content 1\n", "22: first file content")
  check(h.read_file(dst .. string.format("/file_%03d.txt", count)) ==
        string.format("content %d\n", count), "22: last file content")

  local dst_count = h.count_items(dst)
  check(dst_count == count, "22: destination has %d items, expected %d", dst_count, count)

  h.cleanup(src, dst)
  test_pass("22_many_files")
end

-- =========================================================================
-- 23. Nested symlink: link to link to directory
-- =========================================================================

local function test_nested_symlink_to_dir()
  local src = h.tmpdir("nestedlink_src")
  local dst = h.tmpdir("nestedlink_dst")
  h.mkdir(src .. "/real_dir")
  h.mkdir(dst)

  h.create_file(src .. "/real_dir/data.txt", "nested link data\n")
  -- link_1 -> real_dir, link_2 -> link_1
  h.create_symlink("./real_dir", src .. "/link_1")
  h.create_symlink("./link_1", src .. "/link_2")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "23: no errors, got %d", new_errs)

  -- Real dir should be fully copied
  check(h.dir_exists(dst .. "/real_dir"), "23: real dir copied")
  check(h.file_exists(dst .. "/real_dir/data.txt"), "23: data.txt copied")

  -- Both symlinks should be preserved
  check(h.is_symlink(dst .. "/link_1"), "23: link_1 is symlink")
  check(h.is_symlink(dst .. "/link_2"), "23: link_2 is symlink")

  h.cleanup(src, dst)
  test_pass("23_nested_symlink_to_dir")
end

-- =========================================================================
-- 24. Unicode filenames
-- =========================================================================

local function test_unicode_filenames()
  local src = h.tmpdir("unicode_src")
  local dst = h.tmpdir("unicode_dst")
  h.mkdir(src)
  h.mkdir(dst)

  -- Create files with unicode names via shell (safer than Lua string handling)
  os.execute("printf 'cafe\\n' > '" .. src .. "/café.txt'")
  os.execute("printf 'japanese\\n' > '" .. src .. "/日本語.txt'")
  os.execute("printf 'emoji\\n' > '" .. src .. "/🎉.txt'")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "24: no errors, got %d", new_errs)

  check(h.read_file(dst .. "/café.txt") == "cafe\n", "24: café.txt content")
  check(h.read_file(dst .. "/日本語.txt") == "japanese\n", "24: 日本語.txt content")
  check(h.read_file(dst .. "/🎉.txt") == "emoji\n", "24: emoji file content")

  h.cleanup(src, dst)
  test_pass("24_unicode_filenames")
end

-- =========================================================================
-- 25. Copy directory containing only symlinks
-- =========================================================================

local function test_dir_of_symlinks()
  local src = h.tmpdir("dirsym_src")
  local dst = h.tmpdir("dirsym_dst")
  h.mkdir(src .. "/links")
  h.mkdir(dst)

  h.create_file(src .. "/target_a.txt", "a\n")
  h.create_file(src .. "/target_b.txt", "b\n")
  h.create_symlink("../target_a.txt", src .. "/links/link_a.txt")
  h.create_symlink("../target_b.txt", src .. "/links/link_b.txt")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "25: no errors, got %d", new_errs)

  check(h.dir_exists(dst .. "/links"), "25: links dir")
  check(h.is_symlink(dst .. "/links/link_a.txt"), "25: link_a preserved")
  check(h.is_symlink(dst .. "/links/link_b.txt"), "25: link_b preserved")
  check(h.read_symlink(dst .. "/links/link_a.txt") == "../target_a.txt",
        "25: link_a target: got %s", h.read_symlink(dst .. "/links/link_a.txt"))

  -- They should resolve correctly
  check(h.read_file(dst .. "/links/link_a.txt") == "a\n", "25: link_a resolves")
  check(h.read_file(dst .. "/links/link_b.txt") == "b\n", "25: link_b resolves")

  h.cleanup(src, dst)
  test_pass("25_dir_of_symlinks")
end

-- =========================================================================
-- 26. Dangling relative symlink
-- =========================================================================

local function test_dangling_relative_symlink()
  local src = h.tmpdir("dangrel_src")
  local dst = h.tmpdir("dangrel_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/good.txt", "good\n")
  -- Create a relative symlink to a file that doesn't exist
  h.create_symlink("./nonexistent.txt", src .. "/dangling_rel")

  check(h.is_symlink(src .. "/dangling_rel"), "26: dangling relative symlink exists")

  local new_errs = run_copy_test(src, dst)

  -- Good file should be copied
  check(h.file_exists(dst .. "/good.txt"), "26: good file copied")

  -- Dangling relative symlink should be preserved as-is (preserve_relative_links=true)
  -- since the target string is relative and the flag is on
  if h.is_symlink(dst .. "/dangling_rel") then
    check(h.read_symlink(dst .. "/dangling_rel") == "./nonexistent.txt",
          "26: dangling relative target preserved: got %s",
          h.read_symlink(dst .. "/dangling_rel"))
  end
  -- Either way, no crash

  h.cleanup(src, dst)
  test_pass("26_dangling_relative_symlink")
end

-- =========================================================================
-- 27. Three-way circular symlinks: A -> B -> C -> A
-- =========================================================================

local function test_three_way_circular()
  local src = h.tmpdir("tri_circ_src")
  local dst = h.tmpdir("tri_circ_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/safe.txt", "safe\n")

  -- Create three-way cycle with absolute paths
  h.create_symlink(src .. "/cyc_b", src .. "/cyc_a")
  h.create_symlink(src .. "/cyc_c", src .. "/cyc_b")
  h.create_symlink(src .. "/cyc_a", src .. "/cyc_c")

  local new_errs = run_copy_test(src, dst)

  -- Safe file should be copied regardless
  check(h.file_exists(dst .. "/safe.txt"), "27: safe file copied")

  h.cleanup(src, dst)
  test_pass("27_three_way_circular")
end

-- =========================================================================
-- 28. Symlink inside subdirectory pointing outside the copied tree
-- =========================================================================

local function test_symlink_outside_tree()
  local src = h.tmpdir("outside_src")
  local dst = h.tmpdir("outside_dst")
  local external = h.tmpdir("outside_ext")
  h.mkdir(src .. "/sub")
  h.mkdir(dst)
  h.mkdir(external)

  h.create_file(external .. "/external.txt", "external\n")
  h.create_file(src .. "/local.txt", "local\n")
  -- Symlink inside source tree pointing to a file outside the tree
  h.create_symlink(external .. "/external.txt", src .. "/sub/ext_link.txt")

  local new_errs = run_copy_test(src, dst)
  check(new_errs == 0, "28: no errors, got %d", new_errs)

  check(h.file_exists(dst .. "/local.txt"), "28: local file copied")

  -- The symlink should be recreated (absolute target since it's not relative)
  -- It should resolve to the external file
  if h.is_symlink(dst .. "/sub/ext_link.txt") then
    check(h.read_file(dst .. "/sub/ext_link.txt") == "external\n",
          "28: external symlink resolves")
  end

  h.cleanup(src, dst, external)
  test_pass("28_symlink_outside_tree")
end

-- =========================================================================
-- 29. Cancel copy mid-job
-- =========================================================================

local function test_cancel_copy()
  local src = h.tmpdir("cancel_src")
  local dst = h.tmpdir("cancel_dst")
  h.mkdir(src)
  h.mkdir(dst)

  -- Create 10 files of 1MB each = 10MB total
  local file_count = 10
  local file_size = 1024 * 1024  -- 1MB
  for i = 1, file_count do
    h.create_file_sized(src .. string.format("/file_%02d.bin", i), file_size)
  end

  -- Set transfer rate to 20MB/s → full copy ~5s, cancel after ~0.25s
  local rate = 20 * 1024 * 1024
  fc.set_transfer_rate(rate)

  h.cd(src, dst)

  local errs_before = #fc.errors()

  -- Select all files in left panel
  h.ensure_left_focus()
  fc.key("cA")

  -- Open copy dialog and wait for discovery
  fc.key("f5")
  h.wait_event("discovery_completed", 10000, "expected discovery in cancel test")

  -- Confirm the copy (navigate to COPY button and press)
  fc.key({"<-", "ret"})

  -- Wait until at least one file is copied, then cancel.
  check(wait_until_job_items_done(1, 8000), "29: expected job progress before cancel")

  -- Cancel the running job
  local cancelled = fc.cancel_job()
  check(cancelled, "29: cancel_job returned true")

  -- Wait for the job to finish (cancel triggers job_completed event)
  check(fc.wait_for_jobs(15000), "29: expected job completion after cancel")

  -- Reset transfer rate for subsequent tests
  fc.set_transfer_rate(0)

  -- Check that the job state is "cancelled"
  local s = fc.state()
  check(s.jobs.state == "cancelled", "29: job state is cancelled, got %s", tostring(s.jobs.state))

  -- Count files actually copied to destination
  local copied_count = h.count_items(dst)

  -- Should be partial: more than 0 but less than all 10
  check(copied_count > 0,          "29: some files were copied: got %d", copied_count)
  check(copied_count < file_count, "29: not all files copied: got %d/%d", copied_count, file_count)

  -- No new errors (cancel is clean, not an error)
  local errs_after = #fc.errors()
  local new_errs = errs_after - errs_before
  check(new_errs == 0, "29: no new errors from cancel, got %d", new_errs)

  h.cleanup(src, dst)
  test_pass("29_cancel_copy")
end

-- =========================================================================
-- Test 30: Pause/resume copy mid-job
-- =========================================================================

local function test_pause_copy()
  local src = h.tmpdir("pause_src")
  local dst = h.tmpdir("pause_dst")
  h.mkdir(src)
  h.mkdir(dst)

  -- Create 10 files of 1MB each = 10MB total
  local file_count = 10
  local file_size = 1024 * 1024  -- 1MB
  for i = 1, file_count do
    h.create_file_sized(src .. string.format("/file_%02d.bin", i), file_size)
  end

  -- Set transfer rate to 20MB/s → full copy ~5s, pause after ~0.25s
  local rate = 20 * 1024 * 1024
  fc.set_transfer_rate(rate)

  h.cd(src, dst)

  local errs_before = #fc.errors()

  -- Select all files in left panel
  h.ensure_left_focus()
  fc.key("cA")

  -- Open copy dialog and wait for discovery
  fc.key("f5")
  h.wait_event("discovery_completed", 10000, "expected discovery in pause test")

  -- Confirm the copy (navigate to COPY button and press)
  fc.key({"<-", "ret"})

  -- Wait until at least one file is copied, then pause.
  check(wait_until_job_items_done(1, 8000), "30: expected job progress before pause")

  -- Pause the running job
  local paused = fc.pause_job()
  check(paused, "30: pause_job returned true")

  -- Pause state should become visible quickly.
  local saw_paused = false
  for _ = 1, 30 do
    fc.wait_event("job_state_changed", 500)
    local state = fc.state()
    if state.jobs.state == "paused" then
      saw_paused = true
      break
    end
  end
  check(saw_paused, "30: expected paused state")

  -- Resume and wait for completion.
  local resumed = fc.pause_job()
  check(resumed, "30: resume pause_job returned true")
  check(fc.wait_for_jobs(20000), "30: expected completion after resume")

  -- Reset transfer rate for subsequent tests
  fc.set_transfer_rate(0)

  -- Check that the job state is completed
  local s = fc.state()
  check(
    s.jobs.state == "completed" or s.jobs.state == "completed_with_errors",
    "30: job state is completed, got %s",
    tostring(s.jobs.state)
  )

  -- Count files actually copied to destination
  local copied_count = h.count_items(dst)

  -- Full copy should complete after resume.
  check(copied_count == file_count, "30: all files copied after resume: got %d/%d", copied_count, file_count)

  -- No new errors (pause is clean, not an error)
  local errs_after = #fc.errors()
  local new_errs = errs_after - errs_before
  check(new_errs == 0, "30: no new errors from pause, got %d", new_errs)

  h.cleanup(src, dst)
  test_pass("30_pause_copy")
end

-- =========================================================================
-- Test 31: Job history - verify completed and paused jobs appear in history
-- =========================================================================

local function test_job_history()
  local src = h.tmpdir("hist_src")
  local dst = h.tmpdir("hist_dst")
  h.mkdir(src)
  h.mkdir(dst)

  -- Create a few small files for a fast copy
  for i = 1, 3 do
    h.create_file_sized(src .. string.format("/file_%02d.bin", i), 1024)
  end

  h.cd(src, dst)

  -- Check history is initially empty (or has previous test jobs)
  local hist_before = fc.job_history()
  local hist_count_before = #hist_before

  -- Run a normal copy
  h.do_copy()
  local s = fc.state()
  check(
    s.jobs.state == "completed" or s.jobs.state == "completed_with_errors",
    "31: expected completed state after copy, got %s",
    tostring(s.jobs.state)
  )

  -- Check job history has at least one new entry
  local hist_after = fc.job_history()
  check(#hist_after >= hist_count_before + 1, "31: history did not grow, got %d (was %d)", #hist_after, hist_count_before)

  -- Find the newly added copy entry for this 3-file run.
  local matching = nil
  for i = hist_count_before + 1, #hist_after do
    local job = hist_after[i]
    if job.type == "copy" and job.items_total == 3 then
      matching = job
      break
    end
  end
  check(matching ~= nil, "31: expected new copy job in history")
  check(
    matching.state == "completed" or matching.state == "completed_with_errors",
    "31: expected completed state, got %s",
    tostring(matching.state)
  )
  check(matching.items_done == 3, "31: 3 items done, got %d", matching.items_done)

  -- Open job list dialog with F4
  fc.key("f4")
  h.wait_event("dialog_opened", 2000, "31: expected job list open")

  -- Close it with Escape
  fc.key("esc")
  h.wait_event("dialog_closed", 2000, "31: expected job list close")

  h.cleanup(src, dst)
  test_pass("31_job_history")
end

-- =========================================================================
-- Test 32: Conflict mode "skip" keeps existing destination files
-- =========================================================================

local function test_conflict_skip()
  local src = h.tmpdir("conflict_skip_src")
  local dst = h.tmpdir("conflict_skip_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/file.txt", "source content\n")
  h.create_file(dst .. "/file.txt", "destination content\n")

  local new_errs = run_copy_test(src, dst, {conflict_mode = "skip"})
  check(new_errs == 0, "32: no errors, got %d", new_errs)
  check(h.read_file(dst .. "/file.txt") == "destination content\n", "32: destination kept in skip mode")

  h.cleanup(src, dst)
  test_pass("32_conflict_skip")
end

-- =========================================================================
-- Test 33: Conflict mode "update" copies only newer source files
-- =========================================================================

local function test_conflict_update()
  local src = h.tmpdir("conflict_update_src")
  local dst = h.tmpdir("conflict_update_dst")
  h.mkdir(src)
  h.mkdir(dst)

  h.create_file(src .. "/file.txt", "source older\n")
  h.create_file(dst .. "/file.txt", "destination newer\n")
  os.execute("touch -mt 202001010000 '" .. src .. "/file.txt'")
  os.execute("touch -mt 202401010000 '" .. dst .. "/file.txt'")

  local new_errs = run_copy_test(src, dst, {conflict_mode = "update"})
  check(new_errs == 0, "33: no errors in update skip phase, got %d", new_errs)
  check(h.read_file(dst .. "/file.txt") == "destination newer\n", "33: older source skipped")

  h.create_file(src .. "/file.txt", "source newer\n")
  os.execute("touch -mt 202501010000 '" .. src .. "/file.txt'")

  new_errs = run_copy_test(src, dst, {conflict_mode = "update"})
  check(new_errs == 0, "33: no errors in update overwrite phase, got %d", new_errs)
  check(h.read_file(dst .. "/file.txt") == "source newer\n", "33: newer source overwritten")

  h.cleanup(src, dst)
  test_pass("33_conflict_update")
end

-- =========================================================================
-- Test 34: Guard copy directory into its own subtree
-- =========================================================================

local function test_copy_dir_into_subdir_guard()
  local parent = h.tmpdir("copy_into_self_parent")
  local src = parent .. "/src"
  local dst = src .. "/dest"
  h.mkdir(src .. "/nested")
  h.mkdir(dst)
  h.create_file(src .. "/nested/file.txt", "payload\n")

  -- Left panel on parent (selects src), right panel inside src subtree.
  local new_errs = run_copy_test(parent, dst)
  check(new_errs == 0, "34: no new global errors, got %d", new_errs)
  check(not h.dir_exists(dst .. "/src"), "34: src was not copied into its own subtree")

  h.cleanup(parent)
  test_pass("34_copy_dir_into_subdir_guard")
end

-- =========================================================================
-- Run all tests
-- =========================================================================

test_basic_single_file()
test_basic_multiple_files()
test_nested_directories()
test_empty_directory()
test_deep_nesting()
test_hidden_files()
test_special_characters()
test_absolute_symlink()
test_relative_symlink()
test_symlink_chain()
test_circular_symlinks()
test_self_referencing_symlink()
test_dangling_symlink()
test_symlink_to_directory()
test_follow_links_file()
test_follow_links_directory()
test_overwrite_smaller()
test_overwrite_larger()
test_overwrite_extras_remain()
test_mixed_content()
test_symlink_chain_through_dirs()
test_many_files()
test_nested_symlink_to_dir()
test_unicode_filenames()
test_dir_of_symlinks()
test_dangling_relative_symlink()
test_three_way_circular()
test_symlink_outside_tree()
test_cancel_copy()
test_pause_copy()
test_conflict_skip()
test_conflict_update()
test_copy_dir_into_subdir_guard()
test_job_history()

test_pass("ALL COPY TESTS PASSED")
fc.quit()
