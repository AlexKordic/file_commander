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

include(FetchContent)

FetchContent_Declare(ftxui
  GIT_REPOSITORY https://github.com/AlexKordic/ftxui
  GIT_TAG 34f7464263d71ef7b2b1c92d39ccb80debc608f8
)

# FetchContent_Declare(ftxui-grid-container
#   GIT_REPOSITORY https://github.com/mingsheng13/grid-container-ftxui
#   GIT_TAG master
# )

# Add boost lib sources
set(BOOST_INCLUDE_LIBRARIES thread filesystem system smart_ptr)
set(BOOST_ENABLE_CMAKE ON)

# Download and extract the boost library from GitHub
message(STATUS "Downloading and extracting boost library sources. This will take some time...")
Set(FETCHCONTENT_QUIET FALSE) # Needed to print downloading progress
FetchContent_Declare(
    Boost
    URL https://github.com/boostorg/boost/releases/download/boost-1.84.0/boost-1.84.0.tar.gz # downloading a zip release speeds up the download
    USES_TERMINAL_DOWNLOAD TRUE 
    GIT_PROGRESS TRUE   
    DOWNLOAD_NO_EXTRACT FALSE
)

# Boost must be available before alex_ftxui (it uses boost::local_shared_ptr)
FetchContent_MakeAvailable(Boost)

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

add_executable(fc main.cpp log.cpp err.cpp commander.cpp theme.cpp file_panel.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp)
target_link_libraries(fc PRIVATE ftxui::component Boost::filesystem luajit "-framework CoreServices")

# add_executable(playground playground.cpp log.cpp err.cpp commander.cpp theme.cpp file_panel.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp)
# target_link_libraries(playground PRIVATE ftxui::component ftxui::dom ftxui::screen Boost::filesystem "-framework CoreServices")

# TODO: conditional parts for mac and linux
# add_executable(dirnotify dir_notify/fsevents.cpp dir_notify/test.cpp)
# target_link_libraries(dirnotify Boost::filesystem "-framework CoreServices")
