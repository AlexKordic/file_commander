# luarewrite: File Commander Lua/JIT rewrite
# Builds fc_lua executable - Lua high-level + C++ low-level (FTXUI, filesystem)
# Expects parent (file_commander) to provide: ftxui::component, Boost::filesystem

# Resolve workspace path for LuaJIT (luarewrite is file_commander/luarewrite)
get_filename_component(FC_PARENT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../.. ABSOLUTE)
set(LUAJIT_DIR ${FC_PARENT_DIR}/luajit)

if(NOT EXISTS ${LUAJIT_DIR}/src/lua.h)
  message(FATAL_ERROR "LuaJIT not found at ${LUAJIT_DIR}. Add luajit to workspace.")
endif()

# --- LuaJIT ---
# Use luajit-cmake for proper CMake build (handles buildvm, etc.)
include(FetchContent)
set(LUAJIT_DIR ${LUAJIT_DIR} CACHE PATH "LuaJIT source directory")
FetchContent_Declare(luajit-cmake
  GIT_REPOSITORY https://github.com/zhaozg/luajit-cmake
  GIT_TAG        master
)
FetchContent_MakeAvailable(luajit-cmake)

# --- alex_ftxui, Boost ---
# Provided by parent file_commander/CMakeLists.txt

# --- fc_lua executable ---
# Minimal host: embed LuaJIT, load main.lua, run FTXUI loop
add_executable(fc_lua cpp/host.cpp)
set_target_properties(fc_lua PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
target_include_directories(fc_lua PRIVATE
  ${LUAJIT_DIR}/src
  ${luajit-cmake_BINARY_DIR}  # luajit.h generated here
)
target_link_libraries(fc_lua PRIVATE
  luajit::lib
  ftxui::component
  Boost::filesystem
)
if(APPLE)
  target_link_libraries(fc_lua PRIVATE "-framework CoreServices")
endif()
# Copy Lua scripts to build dir so executable finds them
set(LUA_SCRIPT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/lua)
add_custom_command(TARGET fc_lua POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${LUA_SCRIPT_DIR} $<TARGET_FILE_DIR:fc_lua>/lua
  COMMENT "Copy Lua scripts to build directory"
)
