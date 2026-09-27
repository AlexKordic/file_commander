set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

find_program(ZIG_EXECUTABLE zig REQUIRED)

set(CMAKE_C_COMPILER "${ZIG_EXECUTABLE}")
set(CMAKE_C_COMPILER_ARG1 cc)
set(CMAKE_CXX_COMPILER "${ZIG_EXECUTABLE}")
set(CMAKE_CXX_COMPILER_ARG1 c++)

set(_zig_target "x86_64-linux-musl")
set(CMAKE_C_COMPILER_TARGET "${_zig_target}")
set(CMAKE_CXX_COMPILER_TARGET "${_zig_target}")

set(CMAKE_C_FLAGS_INIT "-target ${_zig_target}")
set(CMAKE_CXX_FLAGS_INIT "-target ${_zig_target}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-target ${_zig_target} -static")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-target ${_zig_target}")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Build target archives with Zig, including when the host is macOS.
foreach(FC_ZIG_TOOL ar ranlib)
  set(_fc_zig_wrapper "${CMAKE_BINARY_DIR}/zig-${FC_ZIG_TOOL}")
  configure_file("${CMAKE_CURRENT_LIST_DIR}/zig-tool.in" "${_fc_zig_wrapper}" @ONLY)
  file(CHMOD "${_fc_zig_wrapper}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
  string(TOUPPER "${FC_ZIG_TOOL}" _fc_zig_variable)
  set(CMAKE_${_fc_zig_variable} "${_fc_zig_wrapper}" CACHE FILEPATH "Zig target archive tool" FORCE)
endforeach()
