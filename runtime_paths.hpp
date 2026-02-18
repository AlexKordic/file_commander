#ifndef FC_RUNTIME_PATHS_HPP_
#define FC_RUNTIME_PATHS_HPP_

#include "commander.hpp"

#include <string>

Filepath executable_dir_path();
std::string normalize_tool_reference(std::string value);

#endif  // FC_RUNTIME_PATHS_HPP_
