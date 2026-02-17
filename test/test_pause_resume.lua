-- test/test_pause_resume.lua
-- End-to-end checks for pause/resume behavior of running copy jobs.
-- Usage: ./build/fc run test/test_pause_resume.lua

local h = dofile("test/helpers.lua")

local src = h.tmpdir("pause_src")
local dst = h.tmpdir("pause_dst")

h.mkdir(src)
h.mkdir(dst)
h.create_file_sized(src .. "/big.bin", 512 * 1024)

h.cd(src, dst)
h.ensure_left_focus()

-- Slow down copy so pause state is observable in test.
fc.set_transfer_rate(100 * 1024)

fc.key("cA")
fc.key("f5")
check(fc.wait_event("dialog_opened", 2000), "expected copy dialog open")
check(fc.wait_event("discovery_completed", 10000), "expected discovery complete")
fc.key({"<-", "ret"})

check(fc.wait_event("job_started", 3000), "expected copy job start")
fc.pause_job() -- pause

local paused = false
for _ = 1, 20 do
  fc.wait_event("job_state_changed", 500)
  local s = fc.state()
  if s.jobs.state == "paused" then
    paused = true
    break
  end
end
check(paused, "expected job state to become paused")

fc.pause_job() -- resume
check(fc.wait_for_jobs(15000), "expected job completion after resume")

local s = fc.state()
check(s.jobs.state == "completed" or s.jobs.state == "completed_with_errors", "expected completed state, got %s", tostring(s.jobs.state))
check(h.file_exists(dst .. "/big.bin"), "expected destination file created")
check(h.file_size(dst .. "/big.bin") == 512 * 1024, "expected destination size 512KiB")

h.cleanup(src, dst)
test_pass("pause_resume_copy_basic")
fc.quit()
