cmake_minimum_required (VERSION 3.19)

# Set deployment target before project() to avoid linker version mismatch warnings.
if(CMAKE_HOST_APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
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
include(CTest)
include(cmake/manual_tests.cmake)
find_package(Threads REQUIRED)
option(FC_CORE_ONLY "Build headless core and tests without UI/Lua/editor dependencies" OFF)

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
  json thread system smart_ptr                                                     # project deps (ftxui uses smart_ptr, thread)
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
      URL_HASH SHA256=913ca43d49e93d1b158c9862009add1518a4c665e7853b349a6492d158b036d4
      DOWNLOAD_NO_EXTRACT FALSE
  )
else()
  message(STATUS "Local boost tarball not found. Downloading from GitHub (this will take some time)...")
  Set(FETCHCONTENT_QUIET FALSE) # Needed to print downloading progress
  FetchContent_Declare(
      Boost
      URL https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-cmake.tar.gz
      USES_TERMINAL_DOWNLOAD TRUE
      URL_HASH SHA256=913ca43d49e93d1b158c9862009add1518a4c665e7853b349a6492d158b036d4
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

add_library(fc_core STATIC
  commander.cpp operation.cpp copy_planner.cpp file_io_jobs.cpp archive.cpp location.cpp
  traversal.cpp settings.cpp workspace.cpp transfer_journal.cpp runtime_paths.cpp scheduled_updates.cpp file_metadata.cpp log.cpp err.cpp)
target_include_directories(fc_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(fc_core PUBLIC Boost::filesystem Boost::json Threads::Threads)
if(BUILD_TESTING)
  add_executable(fc_resource_tests test/resource_stress.cpp)
  target_link_libraries(fc_resource_tests PRIVATE fc_core)
  add_test(NAME fc.extended.resources COMMAND fc_resource_tests stress)
  set_tests_properties(fc.extended.resources PROPERTIES LABELS "extended;stress;core" TIMEOUT 90)
  add_test(NAME fc.benchmark.publication COMMAND fc_resource_tests benchmark)
  set_tests_properties(fc.benchmark.publication PROPERTIES LABELS "extended;benchmark;core" TIMEOUT 120)
  add_executable(fc_transfer_recovery_tests test/transfer_recovery.cpp)
  target_link_libraries(fc_transfer_recovery_tests PRIVATE fc_core)
  foreach(_case states copy_before_commit copy_after_commit copy_progress move_rename move_commit move_cleanup move_conflict shutdown directory cancel invalid blocked unsupported)
    add_test(NAME fc.recovery.${_case} COMMAND fc_transfer_recovery_tests ${_case})
    set_tests_properties(fc.recovery.${_case} PROPERTIES LABELS "unit;core;recovery;posix" TIMEOUT 30)
  endforeach()
  add_executable(fc_contract_tests test/core_contracts.cpp)
  target_link_libraries(fc_contract_tests PRIVATE fc_core)
  foreach(_case locations settings workspace directory traversal events retention typed)
    add_test(NAME fc.contract.${_case} COMMAND fc_contract_tests ${_case})
    set_tests_properties(fc.contract.${_case} PROPERTIES LABELS "core;unit;contract" TIMEOUT 30)
  endforeach()
  add_executable(fc_lifetime_tests test/lifetime_contracts.cpp)
  target_link_libraries(fc_lifetime_tests PRIVATE fc_core)
  foreach(_case latest mailbox queue jobs scheduler)
    add_test(NAME fc.lifetime.${_case} COMMAND fc_lifetime_tests ${_case})
    set_tests_properties(fc.lifetime.${_case} PROPERTIES LABELS "core;unit;lifetime" TIMEOUT 20)
  endforeach()
  add_executable(fc_file_fault_tests test/file_faults.cpp)
  target_link_libraries(fc_file_fault_tests PRIVATE fc_core)
  foreach(_case copy long_names rename directory_access settings move move_metadata partial exdev)
    add_test(NAME fc.fault.${_case} COMMAND fc_file_fault_tests ${_case})
    set_tests_properties(fc.fault.${_case} PROPERTIES LABELS "core;fault;integration" TIMEOUT 30)
  endforeach()
  set_tests_properties(fc.fault.exdev PROPERTIES LABELS "platform;extended;exdev" SKIP_RETURN_CODE 77)
  add_executable(fc_core_tests test/core_operations.cpp)
  target_link_libraries(fc_core_tests PRIVATE fc_core)
  add_test(NAME fc.core COMMAND fc_core_tests)
  set_tests_properties(fc.core PROPERTIES LABELS "unit;core" TIMEOUT 30)
endif()
if(FC_CORE_ONLY)
  fc_label_manual_tests()
  return()
endif()

option(FC_ALLOW_UNPINNED_DEPENDENCIES "Allow developer checkouts differing from dependencies.json" OFF)
if(NOT FC_ALLOW_UNPINNED_DEPENDENCIES)
  find_package(Python3 3.12 COMPONENTS Interpreter REQUIRED)
  set(_fc_dependency_check "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/check_dependencies.py"
    --ftxui "${FC_FTXUI_SOURCE_DIR}" --luajit "${FC_LUAJIT_SOURCE_DIR}" --fresh "${FC_FRESH_SOURCE_DIR}" --lzma "${FC_LZMA_SOURCE_DIR}")
  if(NOT FC_BUILD_FRESH)
    list(APPEND _fc_dependency_check --skip-fresh)
  endif()
  if(NOT FC_BUILD_LZMA_TOOL)
    list(APPEND _fc_dependency_check --skip-lzma)
  endif()
  execute_process(COMMAND ${_fc_dependency_check} RESULT_VARIABLE _fc_dependency_result OUTPUT_VARIABLE _fc_dependency_output ERROR_VARIABLE _fc_dependency_error)
  if(NOT _fc_dependency_result EQUAL 0)
    message(FATAL_ERROR "Dependency validation failed: ${_fc_dependency_error}\nUse the pinned inputs or explicitly set FC_ALLOW_UNPINNED_DEPENDENCIES=ON for development.")
  endif()
  add_custom_target(fc_validate_dependencies COMMAND ${_fc_dependency_check} VERBATIM)
  add_dependencies(fc_core fc_validate_dependencies)
else()
  message(WARNING "Dependency revision validation disabled for this development build")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/dependencies.json")

set(FTXUI_USE_LOCAL_SHARED_PTR ON CACHE BOOL "" FORCE)
set(FTXUI_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
if(EXISTS "${FC_FTXUI_SOURCE_DIR}/CMakeLists.txt")
  add_subdirectory("${FC_FTXUI_SOURCE_DIR}" ftxui)
else()
  message(FATAL_ERROR "Local FTXUI source not found at ${FC_FTXUI_SOURCE_DIR}. Set FC_FTXUI_SOURCE_DIR to your local alex_ftxui checkout.")
endif()

set(_luajit_build_dir "${CMAKE_BINARY_DIR}/third_party/luajit/source")
set(_luajit_src_lib "${_luajit_build_dir}/src/libluajit.a")
file(GLOB_RECURSE _luajit_inputs CONFIGURE_DEPENDS
  "${FC_LUAJIT_SOURCE_DIR}/src/*.c" "${FC_LUAJIT_SOURCE_DIR}/src/*.h"
  "${FC_LUAJIT_SOURCE_DIR}/src/*.lua" "${FC_LUAJIT_SOURCE_DIR}/src/*.dasc"
  "${FC_LUAJIT_SOURCE_DIR}/src/Makefile*" "${FC_LUAJIT_SOURCE_DIR}/dynasm/*")
set(_luajit_stage_dir "${CMAKE_BINARY_DIR}/third_party/luajit/lib")
set(_luajit_stage_lib "${_luajit_stage_dir}/libluajit.a")
set(_luajit_stamp "${_luajit_stage_dir}/built.stamp")
if(EXISTS "${FC_LUAJIT_SOURCE_DIR}/src/lua.h")
  # luajit.h is generated by LuaJIT, so a pristine pinned checkout does not
  # contain it. Consumers must use headers from the private build tree.
  file(MAKE_DIRECTORY "${_luajit_build_dir}/src")
  set(_luajit_cc "${CMAKE_C_COMPILER}")
  if(CMAKE_C_COMPILER_ARG1)
    string(APPEND _luajit_cc " ${CMAKE_C_COMPILER_ARG1}")
  endif()
  if(CMAKE_C_COMPILER_TARGET)
    string(APPEND _luajit_cc " -target ${CMAKE_C_COMPILER_TARGET}")
  endif()

  if(APPLE AND CMAKE_OSX_SYSROOT)
    string(APPEND _luajit_cc " -isysroot \"${CMAKE_OSX_SYSROOT}\"")
  elseif(CMAKE_SYSROOT)
    string(APPEND _luajit_cc " --sysroot=\"${CMAKE_SYSROOT}\"")
  endif()

  set(_luajit_host_cc "${_luajit_cc}")
  if(CMAKE_CROSSCOMPILING)
    find_program(FC_HOST_CC NAMES cc clang gcc REQUIRED)
    set(_luajit_host_cc "${FC_HOST_CC}")
  endif()

  set(_luajit_make_args BUILDMODE=static)
  if(CMAKE_CROSSCOMPILING AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(APPEND _luajit_make_args TARGET_SYS=Linux "TARGET_AR=\"${CMAKE_AR}\" rcus")
  endif()

  add_custom_command(
    OUTPUT "${_luajit_stamp}"
    BYPRODUCTS "${_luajit_stage_lib}" "${_luajit_build_dir}/src/luajit.h"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_luajit_stage_dir}"
    COMMAND ${CMAKE_COMMAND} "-DSOURCE=${FC_LUAJIT_SOURCE_DIR}" "-DDEST=${_luajit_build_dir}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/stage_luajit.cmake"
    COMMAND ${CMAKE_COMMAND} -E env
      "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
      make -C "${_luajit_build_dir}/src"
      "CC=${_luajit_cc}"
      "HOST_CC=${_luajit_host_cc}"
      clean
    COMMAND ${CMAKE_COMMAND} -E env
      "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
      make -C "${_luajit_build_dir}/src"
      "CC=${_luajit_cc}"
      "HOST_CC=${_luajit_host_cc}"
      ${_luajit_make_args}
      libluajit.a
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_luajit_src_lib}" "${_luajit_stage_lib}"
    COMMAND ${CMAKE_COMMAND} -E touch "${_luajit_stamp}"
    DEPENDS ${_luajit_inputs} "${CMAKE_CURRENT_SOURCE_DIR}/cmake/stage_luajit.cmake"
    WORKING_DIRECTORY "${FC_LUAJIT_SOURCE_DIR}"
    COMMENT "Building LuaJIT static library from local source"
    VERBATIM
  )
  add_custom_target(luajit_lib ALL DEPENDS "${_luajit_stamp}")
  add_library(luajit STATIC IMPORTED GLOBAL)
  set_target_properties(luajit PROPERTIES
    IMPORTED_LOCATION "${_luajit_stage_lib}"
    INTERFACE_INCLUDE_DIRECTORIES "${_luajit_build_dir}/src"
  )
  add_dependencies(luajit luajit_lib)
else()
  message(FATAL_ERROR "LuaJIT source not found at ${FC_LUAJIT_SOURCE_DIR}. Set FC_LUAJIT_SOURCE_DIR.")
endif()

set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/fc_framework.lua")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/fc_framework.lua" FC_FRAMEWORK_SOURCE)
configure_file(cmake/fc_framework.hpp.in "${CMAKE_CURRENT_BINARY_DIR}/generated/fc_framework.hpp" @ONLY)

add_library(fc_ui STATIC app.cpp theme.cpp custom_controls.cpp dialogs.cpp commands.cpp job_dialogs.cpp settings_dialogs.cpp find_dialog.cpp shared_state.cpp
  file_change_funnel.cpp editor_manager.cpp)
target_link_libraries(fc_ui PUBLIC fc_core ftxui::component)
if(APPLE)
  target_link_libraries(fc_ui PRIVATE "-framework CoreServices")
endif()
add_library(fc_lua STATIC scripting.cpp)
target_include_directories(fc_lua PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(fc_lua PUBLIC fc_ui luajit)
add_executable(fc main.cpp)
target_link_libraries(fc PRIVATE fc_lua)

set(_fc_fresh_default_bin "fresh")
if(FC_BUILD_FRESH)
  if(CMAKE_CROSSCOMPILING)
    message(FATAL_ERROR "Fresh cross-compilation requires a separately configured Rust target; use FC_BUILD_FRESH=OFF and provide a target-built editor when packaging.")
  endif()
  set(_fresh_manifest "${FC_FRESH_SOURCE_DIR}/Cargo.toml")
  set(_fresh_built_bin "${FC_FRESH_SOURCE_DIR}/target/release/fresh")
  set(_fresh_stage_dir "${CMAKE_BINARY_DIR}/third_party/fresh/bin")
  set(_fresh_stage_bin "${_fresh_stage_dir}/fresh")

  if(EXISTS "${_fresh_manifest}")
    # Cargo tracks implementation, build-script, workspace and lockfile changes.
    # Always ask it to check freshness, then stage only changed bytes.
    add_custom_target(fresh_bin ALL
      BYPRODUCTS "${_fresh_stage_bin}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_fresh_stage_dir}"
      COMMAND cargo build --release --locked -p fresh-editor --bin fresh --manifest-path "${_fresh_manifest}"
      # Replace the executable atomically: a detached editor may still have
      # the previous binary mapped while a new build is being staged.
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_fresh_built_bin}" "${_fresh_stage_bin}.new"
      COMMAND ${CMAKE_COMMAND} -E rename "${_fresh_stage_bin}.new" "${_fresh_stage_bin}"
      DEPENDS "${_fresh_manifest}"
      WORKING_DIRECTORY "${FC_FRESH_SOURCE_DIR}"
      COMMENT "Building Fresh editor from local source"
      VERBATIM
    )
    add_dependencies(fc fresh_bin)
    set(_fc_fresh_default_bin "${_fresh_stage_bin}")
  else()
    message(WARNING "FC_BUILD_FRESH=ON but Fresh source is missing Cargo.toml at: ${_fresh_manifest}. Falling back to PATH lookup for fresh.")
  endif()
endif()

target_compile_definitions(fc_ui PRIVATE FC_FRESH_DEFAULT_BIN="${_fc_fresh_default_bin}")

set(_fc_archive_default_bin "7zr")
if(FC_BUILD_LZMA_TOOL)
  set(_lzma_makefile_dir "${FC_LZMA_SOURCE_DIR}/CPP/7zip/Bundles/Alone7z")
  set(_lzma_makefile "${_lzma_makefile_dir}/makefile.gcc")
  set(_lzma_obj_dir "${CMAKE_BINARY_DIR}/third_party/lzma/_o")
  set(_lzma_bin "${_lzma_obj_dir}/7zr")
  if(EXISTS "${_lzma_makefile}")
    file(GLOB_RECURSE _lzma_inputs CONFIGURE_DEPENDS
      "${FC_LZMA_SOURCE_DIR}/C/*.c" "${FC_LZMA_SOURCE_DIR}/C/*.h"
      "${FC_LZMA_SOURCE_DIR}/CPP/*.cpp" "${FC_LZMA_SOURCE_DIR}/CPP/*.h"
      "${FC_LZMA_SOURCE_DIR}/CPP/*.mak" "${FC_LZMA_SOURCE_DIR}/CPP/makefile*")
    foreach(_lang C CXX)
      set(_lzma_${_lang} "${CMAKE_${_lang}_COMPILER}")
      if(CMAKE_${_lang}_COMPILER_ARG1)
        string(APPEND _lzma_${_lang} " ${CMAKE_${_lang}_COMPILER_ARG1}")
      endif()
      if(CMAKE_${_lang}_COMPILER_TARGET)
        string(APPEND _lzma_${_lang} " -target ${CMAKE_${_lang}_COMPILER_TARGET}")
      endif()
      if(APPLE AND CMAKE_OSX_SYSROOT)
        string(APPEND _lzma_${_lang} " -isysroot \"${CMAKE_OSX_SYSROOT}\"")
      elseif(CMAKE_SYSROOT)
        string(APPEND _lzma_${_lang} " --sysroot=\"${CMAKE_SYSROOT}\"")
      endif()
    endforeach()
    add_custom_command(
      OUTPUT "${_lzma_bin}"
      COMMAND ${CMAKE_COMMAND} -E remove_directory "${_lzma_obj_dir}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_lzma_obj_dir}"
      COMMAND ${CMAKE_COMMAND} -E env "CXX=${_lzma_CXX}" "CC=${_lzma_C}" make -f makefile.gcc O="${_lzma_obj_dir}" -C "${_lzma_makefile_dir}"
      DEPENDS ${_lzma_inputs}
      WORKING_DIRECTORY "${_lzma_makefile_dir}"
      COMMENT "Building 7zr from local LZMA SDK"
      VERBATIM
    )
    add_custom_target(lzma_7zr ALL DEPENDS "${_lzma_bin}")
    add_dependencies(fc_core lzma_7zr)
    set(_fc_archive_default_bin "${_lzma_bin}")
  else()
    message(WARNING "FC_BUILD_LZMA_TOOL=ON but LZMA makefile is missing at: ${_lzma_makefile}. Falling back to PATH lookup for 7zr.")
  endif()
endif()

target_compile_definitions(fc_core PRIVATE FC_ARCHIVE_TOOL_DEFAULT="${_fc_archive_default_bin}")

if(BUILD_TESTING)
  add_executable(fc_review_tests test/review_regressions.cpp)
  target_link_libraries(fc_review_tests PRIVATE fc_lua)
  include(cmake/tests.cmake)
endif()

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

if(UNIX AND NOT CMAKE_CROSSCOMPILING)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_custom_target(smoke_lua_suite DEPENDS fc
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/run_lua_suite.py" --binary $<TARGET_FILE:fc> --logs "${CMAKE_CURRENT_BINARY_DIR}/test-logs/smoke"
    COMMENT "Running the complete Lua integration suite in isolated PTYs" VERBATIM)
  if(BUILD_TESTING)
    foreach(_case success failure)
      set(_fresh_args)
      if(_case STREQUAL "failure")
        list(APPEND _fresh_args --failure)
      endif()
      add_test(NAME fc.extended.fresh_${_case} COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_fresh_terminal.py"
        $<TARGET_FILE:fc> "${_fc_fresh_default_bin}" ${_fresh_args})
      set_tests_properties(fc.extended.fresh_${_case} PROPERTIES LABELS "extended;terminal;fresh;posix" TIMEOUT 40 SKIP_RETURN_CODE 77)
    endforeach()
    if(FC_BUILD_FRESH)
      add_test(NAME fc.extended.editor_recovery COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_editor_recovery.py" "${_fc_fresh_default_bin}")
      set_tests_properties(fc.extended.editor_recovery PROPERTIES LABELS "extended;terminal;fresh;posix" TIMEOUT 90)
      add_test(NAME fc.extended.workspace_recovery COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_workspace_recovery.py" $<TARGET_FILE:fc> "${_fc_fresh_default_bin}")
      set_tests_properties(fc.extended.workspace_recovery PROPERTIES LABELS "extended;terminal;fresh;posix" TIMEOUT 90)
      add_test(NAME fc.harness.fresh_bundle COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_fresh_bundle.py" "${FC_FRESH_SOURCE_DIR}")
      set_tests_properties(fc.harness.fresh_bundle PROPERTIES LABELS "build;harness;fresh" TIMEOUT 90)
    endif()
    add_test(NAME fc.package_build COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_package.py" "${CMAKE_BINARY_DIR}" "${_fc_dist_root}/${_fc_dist_name}.tar.gz" --build-only)
    set_tests_properties(fc.package_build PROPERTIES LABELS "integration;package;build;posix" TIMEOUT 180 RUN_SERIAL TRUE)
    add_test(NAME fc.package COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_package.py" "${CMAKE_BINARY_DIR}" "${_fc_dist_root}/${_fc_dist_name}.tar.gz")
    set_tests_properties(fc.package PROPERTIES LABELS "integration;package;posix" TIMEOUT 180 RUN_SERIAL TRUE SKIP_RETURN_CODE 77)
    if(FC_BUILD_LZMA_TOOL)
      option(FC_TEST_DEPENDENCY_REBUILDS "Run slow source-timestamp rebuild checks in CTest" OFF)
      add_test(NAME fc.dependency_rebuild COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_dependency_rebuild.py" "${CMAKE_BINARY_DIR}")
      set_tests_properties(fc.dependency_rebuild PROPERTIES LABELS "build;slow;posix" TIMEOUT 600 RUN_SERIAL TRUE)
      if(NOT FC_TEST_DEPENDENCY_REBUILDS)
        set_tests_properties(fc.dependency_rebuild PROPERTIES DISABLED TRUE)
      endif()
    endif()
  endif()
endif()

fc_label_manual_tests()

# add_executable(playground playground.cpp log.cpp err.cpp commander.cpp theme.cpp custom_controls.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp)
# target_link_libraries(playground PRIVATE ftxui::component ftxui::dom ftxui::screen Boost::filesystem "-framework CoreServices")

# TODO: conditional parts for mac and linux
# add_executable(dirnotify dir_notify/fsevents.cpp dir_notify/test.cpp)
# target_link_libraries(dirnotify Boost::filesystem "-framework CoreServices")
