set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

find_program(ZIG_EXECUTABLE zig REQUIRED)

set(CMAKE_C_COMPILER "${ZIG_EXECUTABLE}")
set(CMAKE_C_COMPILER_ARG1 cc)
set(CMAKE_CXX_COMPILER "${ZIG_EXECUTABLE}")
set(CMAKE_CXX_COMPILER_ARG1 c++)

set(_zig_target "aarch64-linux-musl")
set(CMAKE_C_COMPILER_TARGET "${_zig_target}")
set(CMAKE_CXX_COMPILER_TARGET "${_zig_target}")

set(CMAKE_C_FLAGS_INIT "-target ${_zig_target}")
set(CMAKE_CXX_FLAGS_INIT "-target ${_zig_target}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-target ${_zig_target} -static")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-target ${_zig_target}")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
