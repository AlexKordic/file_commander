-- fc_framework.lua
-- Preloaded before the test script. Provides convenience wrappers
-- around the C-registered fc.* primitives.

local _cpp_context = nil

function __framework_init(context)
  _cpp_context = context
  if fc.test_heartbeat then
    fc.test_heartbeat()
  end
end

-- Wrap fc.key to accept tables (sequences of keys)
local _raw_key = fc.key
fc.key = function(name_or_list)
  if type(name_or_list) == "table" then
    for _, name in ipairs(name_or_list) do
      _raw_key(name)
    end
  else
    _raw_key(name_or_list)
  end
end

-- Explicit command dispatch by stable command id (bypasses key binding dependence).
fc.cmd = function(command_id)
  return fc.command(command_id)
end

-- fc.wait_for_jobs is registered by C++ and checks the queue-drained predicate.

-- Test assertion with formatted message
function check(cond, fmt, ...)
  if not cond then
    error(string.format("FAIL: " .. fmt, ...), 2)
  end
end

-- Print pass marker (visible in fc error bar via report_error, or stdout)
function test_pass(name)
  print("[PASS] " .. name)
  if fc.test_heartbeat then
    fc.test_heartbeat()
  end
end
