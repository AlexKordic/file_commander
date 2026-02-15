
local h = dofile("test/helpers.lua")

local function setup_copy_test()
  -- local src = h.tmpdir("copy_src")
  -- local dst = h.tmpdir("copy_dst")
  -- h.mkdir(src)
  -- h.mkdir(dst)
  -- local file_count = 100
  -- local file_size = 1024 * 128
  -- for i = 1, file_count do
  --   h.create_file_sized(src .. string.format("/file_%02d.bin", i), file_size)
  -- end
  -- local rate = 2 * 1024 * 128
  -- fc.set_transfer_rate(rate)

  -- fc.left_cd(src)
  -- fc.right_cd(dst)
  -- fc.sleep(100)

  -- -- Select all files in left panel
  -- local left_path = fc.left_path()
  -- local function try_select()
  --   fc.key("cA")
  --   local sel = fc.selected()
  --   if #sel == 0 then return false end
  --   if sel[1]:sub(1, #left_path) == left_path then return true end
  --   fc.key("cA")  -- deselect wrong panel
  --   return false
  -- end
  -- if not try_select() then
  --   fc.key("tab")
  --   fc.sleep(50)
  --   assert(try_select(), "cancel test: failed to select in left panel")
  -- end

  -- -- Open copy dialog and wait for discovery
  -- fc.key("f5")  

  fc.left_cd("/tmp/fc_test_copy_src_1771147462_81478")
  fc.right_cd("/tmp/fc_test_copy_dst_1771147462_72896")
  fc.sleep(100)
  fc.key("cA")
  fc.sleep(100)
  fc.key("f5")
end

setup_copy_test()
