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

project(fc LANGUAGES CXX VERSION 1.1.0)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
include(CTest)
include(cmake/manual_tests.cmake)
find_package(Threads REQUIRED)
option(FC_CORE_ONLY "Build headless core and tests without UI/Lua/editor dependencies" OFF)
option(FC_TEST_MACOS_NATIVE "Qualify the native macOS editor against this build's engine and Fresh" ${APPLE})

option(FC_BUILD_FRESH "Build local Fresh editor alongside file_commander" ON)
set(FC_FRESH_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../editor-fresh" CACHE PATH "Path to local Fresh source checkout")
option(FC_BUILD_SEVENZIP "Build 7-Zip's archive library (7z.so) from the pinned 7-Zip source" ON)
set(FC_SEVENZIP_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../7zip2604" CACHE PATH "Path to the pinned 7-Zip source")
set(FC_FTXUI_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../alex_ftxui" CACHE PATH "Path to local FTXUI source checkout")
set(FC_LUAJIT_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../luajit" CACHE PATH "Path to local LuaJIT source checkout")

# The headless build needs 7-Zip's interface headers too. Keep a fresh core
# checkout self-contained by using the same pinned archive as the bootstrapper.
if(FC_CORE_ONLY AND NOT EXISTS "${FC_SEVENZIP_SOURCE_DIR}/CPP/7zip/Archive/IArchive.h")
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/dependencies.json" _fc_dependencies)
  string(JSON _fc_7zip_archive GET "${_fc_dependencies}" sevenzip archive)
  string(JSON _fc_7zip_expected GET "${_fc_dependencies}" sevenzip archive_sha256)
  set(_fc_7zip_archive "${CMAKE_CURRENT_SOURCE_DIR}/${_fc_7zip_archive}")
  file(SHA256 "${_fc_7zip_archive}" _fc_7zip_actual)
  if(NOT "${_fc_7zip_actual}" STREQUAL "${_fc_7zip_expected}")
    message(FATAL_ERROR "Bundled 7-Zip source archive fingerprint mismatch")
  endif()
  set(_fc_core_7zip "${CMAKE_CURRENT_BINARY_DIR}/_deps/fc-sevenzip-src")
  if(NOT EXISTS "${_fc_core_7zip}/CPP/7zip/Archive/IArchive.h")
    file(MAKE_DIRECTORY "${_fc_core_7zip}")
    file(ARCHIVE_EXTRACT INPUT "${_fc_7zip_archive}" DESTINATION "${_fc_core_7zip}")
  endif()
  set(FC_SEVENZIP_SOURCE_DIR "${_fc_core_7zip}" CACHE PATH "Path to the pinned 7-Zip source" FORCE)
  message(STATUS "Using bundled pinned 7-Zip sources for the headless build")
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

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/remote_protocol.py" _fc_protocol_source)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/remote_agent.py" _fc_agent_source)
string(PREPEND _fc_agent_source "${_fc_protocol_source}\n")
configure_file(cmake/remote_agent_source.hpp.in generated/remote_agent_source.hpp @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS remote_agent.py remote_protocol.py)
add_library(fc_core STATIC
  commander.cpp operation.cpp copy_planner.cpp file_io_jobs.cpp archive.cpp location.cpp
  traversal.cpp settings.cpp workspace.cpp transfer_journal.cpp runtime_paths.cpp scheduled_updates.cpp file_metadata.cpp log.cpp err.cpp remote_fs.cpp remote_stream.cpp remote_copy.cpp
  sevenzip.cpp archive_formats.cpp)
target_include_directories(fc_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(fc_core PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(fc_core PUBLIC Boost::filesystem Boost::json Threads::Threads ${CMAKE_DL_LIBS})

# 7-Zip's archive library, 7z.so, built with its own makefile from the pinned
# source and loaded by fc at run time (sevenzip.cpp); RAR is left out.
set(_fc_sevenzip_lib "")
if(FC_BUILD_SEVENZIP)
  set(_sevenzip_bundles "${FC_SEVENZIP_SOURCE_DIR}/CPP/7zip/Bundles")
  if(EXISTS "${_sevenzip_bundles}/Format7zF/makefile.gcc")
    file(GLOB_RECURSE _sevenzip_inputs CONFIGURE_DEPENDS
      "${FC_SEVENZIP_SOURCE_DIR}/C/*.c" "${FC_SEVENZIP_SOURCE_DIR}/C/*.h"
      "${FC_SEVENZIP_SOURCE_DIR}/CPP/*.cpp" "${FC_SEVENZIP_SOURCE_DIR}/CPP/*.h"
      "${FC_SEVENZIP_SOURCE_DIR}/CPP/*.mak" "${FC_SEVENZIP_SOURCE_DIR}/CPP/makefile*")
    foreach(_lang C CXX)
      set(_sevenzip_${_lang} "${CMAKE_${_lang}_COMPILER}")
      if(CMAKE_${_lang}_COMPILER_ARG1)
        string(APPEND _sevenzip_${_lang} " ${CMAKE_${_lang}_COMPILER_ARG1}")
      endif()
      if(APPLE AND CMAKE_OSX_SYSROOT)
        string(APPEND _sevenzip_${_lang} " -isysroot \"${CMAKE_OSX_SYSROOT}\"")
      endif()
    endforeach()
    set(_sevenzip_env "CXX=${_sevenzip_CXX}" "CC=${_sevenzip_C}")
    if(APPLE AND CMAKE_OSX_DEPLOYMENT_TARGET)
      list(APPEND _sevenzip_env "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    set(_sevenzip_lib_dir "${CMAKE_BINARY_DIR}/third_party/7zip/_o")
    set(_fc_sevenzip_lib "${_sevenzip_lib_dir}/7z.so")
    add_custom_command(
      OUTPUT "${_fc_sevenzip_lib}"
      COMMAND ${CMAKE_COMMAND} -E remove_directory "${_sevenzip_lib_dir}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_sevenzip_lib_dir}"
      COMMAND ${CMAKE_COMMAND} -E env ${_sevenzip_env} make -f makefile.gcc DISABLE_RAR=1 O="${_sevenzip_lib_dir}" -C "${_sevenzip_bundles}/Format7zF"
      DEPENDS ${_sevenzip_inputs}
      WORKING_DIRECTORY "${_sevenzip_bundles}/Format7zF"
      COMMENT "Building 7z.so from the pinned 7-Zip source"
      VERBATIM
    )
    add_custom_target(sevenzip_lib ALL DEPENDS "${_fc_sevenzip_lib}")
    add_dependencies(fc_core sevenzip_lib)
  else()
    message(WARNING "FC_BUILD_SEVENZIP=ON but the 7-Zip source is missing at: ${FC_SEVENZIP_SOURCE_DIR}. Archives will need a 7z.so next to fc.")
  endif()
endif()
target_compile_definitions(fc_core PRIVATE FC_SEVENZIP_LIB_DEFAULT="${_fc_sevenzip_lib}")
# sevenzip.cpp includes 7-Zip's interface headers, and nothing else from the source.
target_include_directories(fc_core SYSTEM PRIVATE "${FC_SEVENZIP_SOURCE_DIR}")
if(BUILD_TESTING)
  find_package(Python3 3.12 REQUIRED COMPONENTS Interpreter)
  add_executable(fc_remote_protocol_tests test/remote_protocol.cpp)
  target_link_libraries(fc_remote_protocol_tests PRIVATE fc_core)
  add_test(NAME fc.remote.protocol COMMAND fc_remote_protocol_tests)
  add_test(NAME fc.remote.protocol_python COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/test/test_remote_protocol.py" $<TARGET_FILE:fc_remote_protocol_tests>)
  set_tests_properties(fc.remote.protocol fc.remote.protocol_python PROPERTIES LABELS "core;unit;remote" TIMEOUT 15)
  add_executable(fc_remote_stream_tests test/remote_stream.cpp)
  target_link_libraries(fc_remote_stream_tests PRIVATE fc_core)
  add_executable(fc_remote_copy_benchmark test/remote_copy_benchmark.cpp)
  target_link_libraries(fc_remote_copy_benchmark PRIVATE fc_core)
  add_test(NAME fc.remote.stream COMMAND fc_remote_stream_tests)
  set_tests_properties(fc.remote.stream PROPERTIES LABELS "core;integration;remote;lifetime" TIMEOUT 90
    ENVIRONMENT "FC_SSH_BIN=${CMAKE_CURRENT_SOURCE_DIR}/test/ssh_fixture.py")
  add_test(NAME fc.remote.verifier COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_remote_verifier.py")
  set_tests_properties(fc.remote.verifier PROPERTIES LABELS "core;unit;remote" TIMEOUT 20)
  add_executable(fc_remote_transfer_tests test/remote_transfer.cpp)
  target_link_libraries(fc_remote_transfer_tests PRIVATE fc_core)
  add_test(NAME fc.remote.transfers COMMAND fc_remote_transfer_tests)
  set_tests_properties(fc.remote.transfers PROPERTIES LABELS "core;integration;remote;lifetime" TIMEOUT 90
    ENVIRONMENT "FC_SSH_BIN=${CMAKE_CURRENT_SOURCE_DIR}/test/ssh_fixture.py")
  add_executable(fc_remote_fs_tests test/remote_fs.cpp)
  target_link_libraries(fc_remote_fs_tests PRIVATE fc_core)
  add_test(NAME fc.remote.filesystem COMMAND fc_remote_fs_tests)
  set_tests_properties(fc.remote.filesystem PROPERTIES LABELS "core;unit;remote" TIMEOUT 45
    ENVIRONMENT "FC_SSH_BIN=${CMAKE_CURRENT_SOURCE_DIR}/test/ssh_fixture.py")
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
  find_package(Python3 3.12 COMPONENTS Interpreter REQUIRED)
  add_executable(fc_sevenzip_tests test/sevenzip_contracts.cpp)
  target_link_libraries(fc_sevenzip_tests PRIVATE fc_core)
  target_compile_definitions(fc_sevenzip_tests PRIVATE FC_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}" FC_TEST_PYTHON="${Python3_EXECUTABLE}")
  foreach(_case load seven solid formats failures)
    add_test(NAME fc.sevenzip.${_case} COMMAND fc_sevenzip_tests ${_case})
    set_tests_properties(fc.sevenzip.${_case} PROPERTIES LABELS "core;unit;archive" TIMEOUT 60)
  endforeach()
  add_executable(fc_archive_tests test/archive_contracts.cpp)
  target_link_libraries(fc_archive_tests PRIVATE fc_core)
  target_compile_definitions(fc_archive_tests PRIVATE FC_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}" FC_TEST_PYTHON="${Python3_EXECUTABLE}")
  foreach(_case browse copy cancel nested formats extract names passwords damaged limits create)
    add_test(NAME fc.archive.${_case} COMMAND fc_archive_tests ${_case})
    set_tests_properties(fc.archive.${_case} PROPERTIES LABELS "core;unit;archive" TIMEOUT 120)
  endforeach()
  add_executable(fc_core_tests test/core_operations.cpp)
  target_link_libraries(fc_core_tests PRIVATE fc_core)
  add_test(NAME fc.core COMMAND fc_core_tests)
  set_tests_properties(fc.core PROPERTIES LABELS "unit;core" TIMEOUT 30)
endif()
# The application model without a UI toolkit, shared by the terminal interface
# and the macOS app: panes, tabs, commands, dialogs' workers, watchers, editor.
add_library(fc_model STATIC pane_model.cpp app_model.cpp dialog_models.cpp file_change_funnel.cpp editor_manager.cpp)
target_link_libraries(fc_model PUBLIC fc_core)
if(APPLE)
  target_link_libraries(fc_model PUBLIC "-framework CoreServices")
endif()
# The facade the macOS app imports through Swift's C++ interop (macos/).
add_library(fc_engine STATIC fc_engine.cpp)
target_link_libraries(fc_engine PUBLIC fc_model)
if(APPLE)
  # One archive with everything the app links: facade, model, core and Boost.
  set(_fc_engine_bundle "${CMAKE_BINARY_DIR}/libfc_engine_bundle.a")
  set(_fc_engine_parts $<TARGET_FILE:fc_engine> $<TARGET_FILE:fc_model> $<TARGET_FILE:fc_core>
    $<TARGET_FILE:Boost::filesystem> $<TARGET_FILE:Boost::json> $<TARGET_FILE:Boost::container>)
  if(TARGET Boost::atomic)
    list(APPEND _fc_engine_parts $<TARGET_FILE:Boost::atomic>)
  endif()
  add_custom_command(OUTPUT "${_fc_engine_bundle}"
    COMMAND libtool -static -no_warning_for_no_symbols -o "${_fc_engine_bundle}" ${_fc_engine_parts}
    DEPENDS fc_engine fc_model fc_core Boost::filesystem Boost::json Boost::container
    COMMENT "Bundling the engine libraries for the macOS app"
    VERBATIM)
  add_custom_target(fc_engine_bundle ALL DEPENDS "${_fc_engine_bundle}")
endif()
if(BUILD_TESTING)
  add_executable(fc_model_tests test/model_contracts.cpp)
  target_link_libraries(fc_model_tests PRIVATE fc_engine)
  target_compile_definitions(fc_model_tests PRIVATE FC_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
  foreach(_case panes commands rate engine editor)
    add_test(NAME fc.model.${_case} COMMAND fc_model_tests ${_case})
    set_tests_properties(fc.model.${_case} PROPERTIES LABELS "core;unit;model" TIMEOUT 30)
  endforeach()
  add_test(NAME fc.model.large COMMAND fc_model_tests large)
  set_tests_properties(fc.model.large PROPERTIES LABELS "extended;benchmark;model" TIMEOUT 120)
  # The macOS app's explainers: steps, anchors, commands and coverage, checked without the app (it reads only the scripts and the Swift sources, so it runs on every platform).
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_FOUND)
    add_test(NAME fc.macos.explainers COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/macos/tools/check_explainers.py")
    set_tests_properties(fc.macos.explainers PROPERTIES LABELS "unit;macos" TIMEOUT 30)
    # Fixture/ownership contracts use no GUI or SSH and run on both supported OSes.
    add_test(NAME fc.macos.compose_fixtures COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/macos/tools/test_qualify_compose.py")
    set_tests_properties(fc.macos.compose_fixtures PROPERTIES LABELS "unit;macos" TIMEOUT 30)
    add_test(NAME fc.macos.native_harness COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/macos/tools/test_native_editor_gate.py")
    set_tests_properties(fc.macos.native_harness PROPERTIES LABELS "unit;macos" TIMEOUT 30)
  endif()
endif()

if(FC_CORE_ONLY)
  fc_label_manual_tests()
  return()
endif()

option(FC_ALLOW_UNPINNED_DEPENDENCIES "Allow developer checkouts differing from dependencies.json" OFF)
if(NOT FC_ALLOW_UNPINNED_DEPENDENCIES)
  find_package(Python3 3.12 COMPONENTS Interpreter REQUIRED)
  set(_fc_dependency_check "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/check_dependencies.py"
    --ftxui "${FC_FTXUI_SOURCE_DIR}" --luajit "${FC_LUAJIT_SOURCE_DIR}" --fresh "${FC_FRESH_SOURCE_DIR}" --sevenzip "${FC_SEVENZIP_SOURCE_DIR}")
  if(NOT FC_BUILD_FRESH)
    list(APPEND _fc_dependency_check --skip-fresh)
  endif()
  if(NOT FC_BUILD_SEVENZIP)
    list(APPEND _fc_dependency_check --skip-sevenzip)
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

add_library(fc_ui STATIC app.cpp theme.cpp custom_controls.cpp dialogs.cpp commands.cpp job_dialogs.cpp settings_dialogs.cpp find_dialog.cpp shared_state.cpp)
target_link_libraries(fc_ui PUBLIC fc_model ftxui::component)
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
  # FC builds Fresh for speed: Fresh's release profile optimizes for size
  # (opt-level "z"), which doubles the time each frame of the macOS app's
  # native editor takes to build. FC's own profile, `fc-release`, is release
  # with opt-level 3; it builds into target/fc-release, so a plain
  # `cargo build --release` in the checkout keeps its own output.
  set(_fresh_profile_args --profile fc-release
    --config "profile.fc-release.inherits=\"release\""
    --config "profile.fc-release.opt-level=3")
  set(_fresh_built_bin "${FC_FRESH_SOURCE_DIR}/target/fc-release/fresh")
  set(_fresh_stage_dir "${CMAKE_BINARY_DIR}/third_party/fresh/bin")
  set(_fresh_stage_bin "${_fresh_stage_dir}/fresh")

  if(EXISTS "${_fresh_manifest}")
    # Cargo tracks implementation, build-script, workspace and lockfile changes.
    # Always ask it to check freshness, then stage only changed bytes. The web
    # feature gives FC sessions the scene channel the macOS app's native
    # editor window attaches over.
    add_custom_target(fresh_bin ALL
      BYPRODUCTS "${_fresh_stage_bin}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_fresh_stage_dir}"
      COMMAND cargo build ${_fresh_profile_args} --locked -p fresh-editor --bin fresh --features web --manifest-path "${_fresh_manifest}"
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

target_compile_definitions(fc_model PRIVATE FC_FRESH_DEFAULT_BIN="${_fc_fresh_default_bin}")

if(APPLE AND BUILD_TESTING AND FC_TEST_MACOS_NATIVE)
  find_program(FC_SWIFT_EXECUTABLE swift REQUIRED)
  add_test(NAME fc.macos.native_editor
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/macos/tools/run_native_editor_tests.py"
      --swift "${FC_SWIFT_EXECUTABLE}" --engine-build "${CMAKE_BINARY_DIR}"
      --fresh "${CMAKE_BINARY_DIR}/third_party/fresh/bin/fresh"
      --scratch-path "${CMAKE_BINARY_DIR}/native-editor"
      --configuration "$<IF:$<CONFIG:Debug>,debug,release>")
  # Swift compilation and native resource-heavy workflows should own the lane
  # while running; their private views do not open the installed application.
  set_tests_properties(fc.macos.native_editor PROPERTIES
    LABELS "integration;macos;native;compose" TIMEOUT 1200 RUN_SERIAL TRUE)
endif()


if(BUILD_TESTING)
  add_executable(fc_remote_ui_tests test/remote_ui.cpp)
  target_link_libraries(fc_remote_ui_tests PRIVATE fc_ui)
  add_test(NAME fc.remote.panels COMMAND fc_remote_ui_tests)
  set_tests_properties(fc.remote.panels PROPERTIES LABELS "integration;remote;native" TIMEOUT 45
    ENVIRONMENT "FC_SSH_BIN=${CMAKE_CURRENT_SOURCE_DIR}/test/ssh_fixture.py")
  add_executable(fc_review_tests test/review_regressions.cpp)
  target_link_libraries(fc_review_tests PRIVATE fc_lua)
  include(cmake/tests.cmake)
endif()

set(_fc_dist_root "${CMAKE_BINARY_DIR}/dist")
set(_fc_dist_name "fc-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
set(_fc_pack_script "${CMAKE_BINARY_DIR}/cmake/package_dist.cmake")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/package_dist.cmake.in" "${_fc_pack_script}" @ONLY)

add_custom_target(package_dist
  DEPENDS fc
  COMMAND ${CMAKE_COMMAND}
    -DFC_BIN=$<TARGET_FILE:fc>
    -DFC_DIST_ROOT=${_fc_dist_root}
    -DFC_DIST_NAME=${_fc_dist_name}
    -DFC_DIST_FRESH=${_fc_fresh_default_bin}
    -DFC_DIST_SEVENZIP=${_fc_sevenzip_lib}
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
      add_test(NAME fc.extended.ssh_editor COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_ssh_editor.py" "${_fc_fresh_default_bin}")
      set_tests_properties(fc.extended.ssh_editor PROPERTIES LABELS "extended;terminal;fresh;remote;posix" TIMEOUT 60)
      add_test(NAME fc.extended.editor_recovery COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_editor_recovery.py" "${_fc_fresh_default_bin}")
      set_tests_properties(fc.extended.editor_recovery PROPERTIES LABELS "extended;terminal;fresh;posix" TIMEOUT 90)
      add_test(NAME fc.extended.editor_restart COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_editor_restart.py" "${_fc_fresh_default_bin}")
      set_tests_properties(fc.extended.editor_restart PROPERTIES LABELS "extended;terminal;fresh;posix" TIMEOUT 60)
      add_test(NAME fc.extended.workspace_recovery COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_workspace_recovery.py" $<TARGET_FILE:fc> "${_fc_fresh_default_bin}")
      set_tests_properties(fc.extended.workspace_recovery PROPERTIES LABELS "extended;terminal;fresh;posix" TIMEOUT 90)
      add_test(NAME fc.harness.fresh_bundle COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_fresh_bundle.py" "${FC_FRESH_SOURCE_DIR}")
      set_tests_properties(fc.harness.fresh_bundle PROPERTIES LABELS "build;harness;fresh" TIMEOUT 90)
    endif()
    add_test(NAME fc.package_build COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_package.py" "${CMAKE_BINARY_DIR}" "${_fc_dist_root}/${_fc_dist_name}.tar.gz" --build-only)
    set_tests_properties(fc.package_build PROPERTIES LABELS "integration;package;build;posix" TIMEOUT 180 RUN_SERIAL TRUE)
    add_test(NAME fc.package COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test/test_package.py" "${CMAKE_BINARY_DIR}" "${_fc_dist_root}/${_fc_dist_name}.tar.gz")
    set_tests_properties(fc.package PROPERTIES LABELS "integration;package;posix" TIMEOUT 180 RUN_SERIAL TRUE SKIP_RETURN_CODE 77)
    if(FC_BUILD_SEVENZIP)
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

# TODO: conditional parts for mac and linux
# add_executable(dirnotify dir_notify/fsevents.cpp dir_notify/test.cpp)
# target_link_libraries(dirnotify Boost::filesystem "-framework CoreServices")
