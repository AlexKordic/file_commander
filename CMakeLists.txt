cmake_minimum_required (VERSION 3.14)
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
set(BOOST_INCLUDE_LIBRARIES thread filesystem system)
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

# FetchContent_MakeAvailable(ftxui)
add_subdirectory(/Users/alexkordic/code/alex_ftxui ftxui)
FetchContent_MakeAvailable(Boost)
add_executable(fc main.cpp log.cpp err.cpp commander.cpp theme.cpp file_panel.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp)
target_link_libraries(fc PRIVATE ftxui::component Boost::filesystem "-framework CoreServices")

# add_executable(playground playground.cpp log.cpp err.cpp commander.cpp theme.cpp file_panel.cpp dialogs.cpp shared_state.cpp file_change_funnel.cpp file_io_jobs.cpp)
# target_link_libraries(playground PRIVATE ftxui::component ftxui::dom ftxui::screen Boost::filesystem "-framework CoreServices")

# TODO: conditional parts for mac and linux
add_executable(dirnotify dir_notify/fsevents.cpp dir_notify/test.cpp)
target_link_libraries(dirnotify Boost::filesystem "-framework CoreServices")
