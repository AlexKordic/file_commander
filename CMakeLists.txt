cmake_minimum_required (VERSION 3.14)

# Set deployment target before project() to avoid linker version mismatch warnings.
if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  execute_process(
    COMMAND sw_vers -productVersion
    OUTPUT_VARIABLE _macos_version
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  set(CMAKE_OSX_DEPLOYMENT_TARGET "${_macos_version}" CACHE STRING "Minimum macOS deployment version")
endif()

project(fc LANGUAGES CXX VERSION 1.0.0)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(FC_STATIC_MODE "Prefer static linking for non-system libraries" OFF)
option(FC_BUILD_FRESH "Build local Fresh editor alongside file_commander" ON)
set(FC_FRESH_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../editor-fresh" CACHE PATH "Path to local Fresh source checkout")
option(FC_BUILD_LZMA_TOOL "Build local 7zr from LZMA SDK" ON)
set(FC_LZMA_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../lzma2600" CACHE PATH "Path to local LZMA SDK checkout")
set(FC_FTXUI_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../alex_ftxui" CACHE PATH "Path to local FTXUI source checkout")
set(FC_LUAJIT_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../luajit" CACHE PATH "Path to local LuaJIT source checkout")

if(FC_STATIC_MODE)
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build shared libraries" FORCE)
  set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
  set(CMAKE_POSITION_INDEPENDENT_CODE OFF)
  if(NOT APPLE)
    string(APPEND CMAKE_EXE_LINKER_FLAGS " -static")
  endif()
endif()

include(FetchContent)
include(ExternalProject)

# FetchContent_Declare(ftxui-grid-container
#   GIT_REPOSITORY https://github.com/mingsheng13/grid-container-ftxui
#   GIT_TAG master
# )

# Add boost lib sources (via FetchContent for dependencies)
# NOTE: filesystem is NOT in this list -- we build it from our local git subtree (boost/filesystem/).
# All of filesystem's direct and transitive dependencies must be listed here so their CMake targets exist.
set(BOOST_INCLUDE_LIBRARIES
  thread system smart_ptr                                                     # project deps (ftxui uses smart_ptr, thread)
  assert config container_hash core detail io iterator predef scope type_traits # filesystem deps
)
set(BOOST_ENABLE_CMAKE ON)

# Use local boost tarball if present in repo root, otherwise download from GitHub.
# To avoid repeated downloads on full rebuilds, download once:
#   curl -LO https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-cmake.tar.gz
set(_boost_local_tarball "${CMAKE_CURRENT_SOURCE_DIR}/boost-1.90.0-cmake.tar.gz")
if(EXISTS "${_boost_local_tarball}")
  message(STATUS "Using local boost tarball: ${_boost_local_tarball}")
  FetchContent_Declare(
      Boost
      URL "file://${_boost_local_tarball}"
      DOWNLOAD_NO_EXTRACT FALSE
  )
else()
  message(STATUS "Local boost tarball not found. Downloading from GitHub (this will take some time)...")
  Set(FETCHCONTENT_QUIET FALSE) # Needed to print downloading progress
  FetchContent_Declare(
      Boost
      URL https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-cmake.tar.gz
      USES_TERMINAL_DOWNLOAD TRUE
      DOWNLOAD_NO_EXTRACT FALSE
  )
endif()

# Boost deps must be available before alex_ftxui (it uses boost::local_shared_ptr) and our filesystem
FetchContent_MakeAvailable(Boost)

# Build Boost.Filesystem from our local git subtree (boost/filesystem/).
# This lets us modify filesystem sources and track changes in git.
# Pre-set BOOST_LIBRARY_INCLUDES so filesystem's configure checks find Boost headers from FetchContent.
file(GLOB _boost_lib_include_dirs "${boost_SOURCE_DIR}/libs/*/include")
set(BOOST_LIBRARY_INCLUDES ${_boost_lib_include_dirs} CACHE INTERNAL "Boost library include paths for config checks")
add_subdirectory(boost/filesystem)

set(FTXUI_USE_LOCAL_SHARED_PTR ON CACHE BOOL "" FORCE)
set(FTXUI_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
if(EXISTS "${FC_FTXUI_SOURCE_DIR}/CMakeLists.txt")
  add_subdirectory("${FC_FTXUI_SOURCE_DIR}" ftxui)
else()
  message(FATAL_ERROR "Local FTXUI source not found at ${FC_FTXUI_SOURCE_DIR}. Set FC_FTXUI_SOURCE_DIR to your local alex_ftxui checkout.")
endif()

set(_luajit_src_lib "${FC_LUAJIT_SOURCE_DIR}/src/libluajit.a")
set(_luajit_stage_dir "${CMAKE_BINARY_DIR}/third_party/luajit/lib")
set(_luajit_stage_lib "${_luajit_stage_dir}/libluajit.a")
if(EXISTS "${FC_LUAJIT_SOURCE_DIR}/src/luajit.h")
  set(_luajit_cc "${CMAKE_C_COMPILER}")
  if(CMAKE_C_COMPILER_ARG1)
    string(APPEND _luajit_cc " ${CMAKE_C_COMPILER_ARG1}")
  endif()
  if(CMAKE_C_COMPILER_TARGET)
    string(APPEND _luajit_cc " -target ${CMAKE_C_COMPILER_TARGET}")
  endif()

  set(_luajit_host_cc "${CMAKE_C_COMPILER}")
  if(CMAKE_CROSSCOMPILING)
    find_program(FC_HOST_CC NAMES cc clang gcc REQUIRED)
    set(_luajit_host_cc "${FC_HOST_CC}")
  endif()

  set(_luajit_make_args BUILDMODE=static)
  if(CMAKE_CROSSCOMPILING AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(APPEND _luajit_make_args TARGET_SYS=Linux)
  endif()

  add_custom_command(
    OUTPUT "${_luajit_stage_lib}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_luajit_stage_dir}"
    COMMAND ${CMAKE_COMMAND} -E env
      "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
      make -C "${FC_LUAJIT_SOURCE_DIR}/src"
      "CC=${_luajit_cc}"
      "HOST_CC=${_luajit_host_cc}"
      clean
    COMMAND ${CMAKE_COMMAND} -E env
      "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
      make -C "${FC_LUAJIT_SOURCE_DIR}/src"
      "CC=${_luajit_cc}"
      "HOST_CC=${_luajit_host_cc}"
      ${_luajit_make_args}
      libluajit.a
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_luajit_src_lib}" "${_luajit_stage_lib}"
    DEPENDS "${FC_LUAJIT_SOURCE_DIR}/src/luajit.h"
    WORKING_DIRECTORY "${FC_LUAJIT_SOURCE_DIR}"
    COMMENT "Building LuaJIT static library from local source"
    VERBATIM
  )
  add_custom_target(luajit_lib ALL DEPENDS "${_luajit_stage_lib}")
  add_library(luajit STATIC IMPORTED GLOBAL)
  set_target_properties(luajit PROPERTIES
    IMPORTED_LOCATION "${_luajit_stage_lib}"
    INTERFACE_INCLUDE_DIRECTORIES "${FC_LUAJIT_SOURCE_DIR}/src"
  )
  add_dependencies(luajit luajit_lib)
else()
  message(FATAL_ERROR "LuaJIT source not found at ${FC_LUAJIT_SOURCE_DIR}. Set FC_LUAJIT_SOURCE_DIR.")
endif()

add_executable(fc
  main.cpp
  scripting.cpp
  log.cpp
  err.cpp
  commander.cpp
  theme.cpp
  custom_controls.cpp
  dialogs.cpp
  shared_state.cpp
  file_change_funnel.cpp
  file_io_jobs.cpp
  editor_manager.cpp
  archive.cpp
  runtime_paths.cpp
)
if(APPLE)
  target_link_libraries(fc PRIVATE ftxui::component Boost::filesystem luajit "-framework CoreServices")
else()
  target_link_libraries(fc PRIVATE ftxui::component Boost::filesystem luajit)
endif()

set(_fc_fresh_default_bin "fresh")
if(FC_BUILD_FRESH)
  set(_fresh_manifest "${FC_FRESH_SOURCE_DIR}/Cargo.toml")
  set(_fresh_built_bin "${FC_FRESH_SOURCE_DIR}/target/release/fresh")
  set(_fresh_stage_dir "${CMAKE_BINARY_DIR}/third_party/fresh/bin")
  set(_fresh_stage_bin "${_fresh_stage_dir}/fresh")

  if(EXISTS "${_fresh_manifest}")
    add_custom_command(
      OUTPUT "${_fresh_stage_bin}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_fresh_stage_dir}"
      COMMAND cargo build --release --manifest-path "${_fresh_manifest}"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_fresh_built_bin}" "${_fresh_stage_bin}"
      DEPENDS "${_fresh_manifest}"
      WORKING_DIRECTORY "${FC_FRESH_SOURCE_DIR}"
      COMMENT "Building Fresh editor from local source"
      VERBATIM
    )
    add_custom_target(fresh_bin ALL DEPENDS "${_fresh_stage_bin}")
    add_dependencies(fc fresh_bin)
    set(_fc_fresh_default_bin "${_fresh_stage_bin}")
  else()
    message(WARNING "FC_BUILD_FRESH=ON but Fresh source is missing Cargo.toml at: ${_fresh_manifest}. Falling back to PATH lookup for fresh.")
  endif()
endif()

target_compile_definitions(fc PRIVATE FC_FRESH_DEFAULT_BIN="${_fc_fresh_default_bin}")

set(_fc_archive_default_bin "7zr")
if(FC_BUILD_LZMA_TOOL)
  set(_lzma_makefile_dir "${FC_LZMA_SOURCE_DIR}/CPP/7zip/Bundles/Alone7z")
  set(_lzma_makefile "${_lzma_makefile_dir}/makefile.gcc")
  set(_lzma_obj_dir "${CMAKE_BINARY_DIR}/third_party/lzma/_o")
  set(_lzma_bin "${_lzma_obj_dir}/7zr")
  if(EXISTS "${_lzma_makefile}")
    add_custom_command(
      OUTPUT "${_lzma_bin}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_lzma_obj_dir}"
      COMMAND ${CMAKE_COMMAND} -E env CXX=${CMAKE_CXX_COMPILER} CC=${CMAKE_C_COMPILER} make -f makefile.gcc O="${_lzma_obj_dir}" -C "${_lzma_makefile_dir}"
      DEPENDS "${_lzma_makefile}"
      WORKING_DIRECTORY "${_lzma_makefile_dir}"
      COMMENT "Building 7zr from local LZMA SDK"
      VERBATIM
    )
    add_custom_target(lzma_7zr ALL DEPENDS "${_lzma_bin}")
    add_dependencies(fc lzma_7zr)
    set(_fc_archive_default_bin "${_lzma_bin}")
  else()
    message(WARNING "FC_BUILD_LZMA_TOOL=ON but LZMA makefile is missing at: ${_lzma_makefile}. Falling back to PATH lookup for 7zr.")
  endif()
endif()

target_compile_definitions(fc PRIVATE FC_ARCHIVE_TOOL_DEFAULT="${_fc_archive_default_bin}")

set(_fc_dist_root "${CMAKE_BINARY_DIR}/dist")
set(_fc_dist_name "fc-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
set(_fc_pack_script "${CMAKE_BINARY_DIR}/cmake/package_dist.cmake")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/package_dist.cmake.in" "${_fc_pack_script}" @ONLY)

add_custom_target(package_static_dist
  DEPENDS fc
  COMMAND ${CMAKE_COMMAND}
    -DFC_BIN=$<TARGET_FILE:fc>
    -DFC_DIST_ROOT=${_fc_dist_root}
    -DFC_DIST_NAME=${_fc_dist_name}
    -DFC_DIST_FRESH=${_fc_fresh_default_bin}
    -DFC_DIST_ARCHIVE=${_fc_archive_default_bin}
    -P "${_fc_pack_script}"
  COMMENT "Creating self-contained distribution tarball"
  VERBATIM
)

add_custom_target(smoke_lua_suite
  DEPENDS fc
  COMMAND ${CMAKE_COMMAND} -E chdir "${CMAKE_CURRENT_SOURCE_DIR}" "$<TARGET_FILE:fc>" run "test/test_events.lua"
  COMMAND ${CMAKE_COMMAND} -E chdir "${CMAKE_CURRENT_SOURCE_DIR}" "$<TARGET_FILE:fc>" run "test/test_palette.lua"
  COMMAND ${CMAKE_COMMAND} -E chdir "${CMAKE_CURRENT_SOURCE_DIR}" "$<TARGET_FILE:fc>" run "test/test_archive.lua"
  COMMENT "Running smoke Lua suite"
  VERBATIM
)

# add_executable(playground playground.cpp log.cpp err.cpp commander.cpp theme.cpp custom_controls.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp)
# target_link_libraries(playground PRIVATE ftxui::component ftxui::dom ftxui::screen Boost::filesystem "-framework CoreServices")

# TODO: conditional parts for mac and linux
# add_executable(dirnotify dir_notify/fsevents.cpp dir_notify/test.cpp)
# target_link_libraries(dirnotify Boost::filesystem "-framework CoreServices")
