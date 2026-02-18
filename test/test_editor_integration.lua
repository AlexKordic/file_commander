-- test/test_editor_integration.lua
-- Deterministic editor integration test using a fake Fresh binary.
--
-- Run:
-- FC_FRESH_BIN=./test/fakes/fresh_fake.sh \
-- FC_FRESH_FAKE_LOG=/tmp/fc_fresh_fake.log \
-- ./build/fc run test/test_editor_integration.lua

local h = dofile("test/helpers.lua")

local fake_bin = os.getenv("FC_FRESH_BIN") or ""
if fake_bin == "" then
  test_pass("editor_integration_skipped_no_FC_FRESH_BIN")
  fc.quit()
  return
end

local log_path = os.getenv("FC_FRESH_FAKE_LOG") or "/tmp/fc_fresh_fake.log"
os.remove(log_path)

local function read_log()
  local f = io.open(log_path, "r")
  if not f then return "" end
  local txt = f:read("*a") or ""
  f:close()
  return txt
end

local function count_lines(txt)
  local n = 0
  for _ in txt:gmatch("[^\n]+") do
    n = n + 1
  end
  return n
end

local function wait_for_log_contains(needle, timeout_ms)
  timeout_ms = timeout_ms or 3000
  local iterations = math.max(1, math.floor(timeout_ms / 25))
  for _ = 1, iterations do
    local txt = read_log()
    if txt:find(needle, 1, true) then return txt end
    fc.sleep(25)
  end
  check(false, "timeout waiting for log entry containing: %s", needle)
end

local function wait_for_line_count(min_count, timeout_ms)
  timeout_ms = timeout_ms or 3000
  local iterations = math.max(1, math.floor(timeout_ms / 25))
  for _ = 1, iterations do
    local txt = read_log()
    if count_lines(txt) >= min_count then return txt end
    fc.sleep(25)
  end
  check(false, "timeout waiting for >= %d log lines", min_count)
end

local src = h.tmpdir("editor_src")
local dst = h.tmpdir("editor_dst")
h.mkdir(src)
h.mkdir(dst)
h.create_file(src .. "/a.txt", "a\n")
h.create_file(src .. "/b.txt", "b\n")
h.cd(src, dst)
h.ensure_left_focus()

-- Open selected files in editor (F9).
fc.key("cA")
check(#fc.selected() > 0, "expected selected files before opening editor")
fc.key("f9")

local log_txt = wait_for_log_contains("args=[--cmd][session][open-file]", 5000)
check(log_txt:find("args=[-a][", 1, true), "expected attach command after open-file")

local initial_lines = count_lines(log_txt)
check(initial_lines >= 2, "expected at least open-file + attach calls")

-- Cycle sessions via shortcuts (same single session still issues attach calls).
fc.key("cY")
fc.key("cU")
log_txt = wait_for_line_count(initial_lines + 2, 5000)

local attach_count = 0
for line in log_txt:gmatch("[^\n]+") do
  if line:find("args=[-a][", 1, true) then attach_count = attach_count + 1 end
end
check(attach_count >= 3, "expected multiple attach calls, got %d", attach_count)

h.cleanup(src, dst)
test_pass("editor_integration_fake_fresh")
fc.quit()
