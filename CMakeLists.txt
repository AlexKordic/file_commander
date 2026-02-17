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

option(FC_BUILD_FRESH "Build local Fresh editor alongside file_commander" ON)
set(FC_FRESH_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../editor-fresh" CACHE PATH "Path to local Fresh source checkout")

include(FetchContent)

FetchContent_Declare(ftxui
  GIT_REPOSITORY https://github.com/AlexKordic/ftxui
  GIT_TAG 34f7464263d71ef7b2b1c92d39ccb80debc608f8
)

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
# FetchContent_MakeAvailable(ftxui)
add_subdirectory(/Users/alexkordic/code/alex_ftxui ftxui)

# LuaJIT (local build from ../luajit, run: MACOSX_DEPLOYMENT_TARGET=$(sw_vers -productVersion) make -C ../luajit)
set(LUAJIT_DIR /Users/alexkordic/code/luajit)
add_library(luajit STATIC IMPORTED)
set_target_properties(luajit PROPERTIES
  IMPORTED_LOCATION ${LUAJIT_DIR}/src/libluajit.a
  INTERFACE_INCLUDE_DIRECTORIES ${LUAJIT_DIR}/src
)

add_executable(fc main.cpp scripting.cpp log.cpp err.cpp commander.cpp theme.cpp custom_controls.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp editor_manager.cpp)
target_link_libraries(fc PRIVATE ftxui::component Boost::filesystem luajit "-framework CoreServices")

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

# add_executable(playground playground.cpp log.cpp err.cpp commander.cpp theme.cpp custom_controls.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp)
# target_link_libraries(playground PRIVATE ftxui::component ftxui::dom ftxui::screen Boost::filesystem "-framework CoreServices")

# TODO: conditional parts for mac and linux
# add_executable(dirnotify dir_notify/fsevents.cpp dir_notify/test.cpp)
# target_link_libraries(dirnotify Boost::filesystem "-framework CoreServices")
