#pragma once
#include "bfs.hpp"

namespace Perun {
// Returns true only for a newly created directory. Existing directories are
// left unchanged; failure is reported through ec.
bool create_private_directory(const Filepath&, boost::system::error_code&);
void copy_directory_access(const Filepath& source, const Filepath& destination, boost::system::error_code&);
}
