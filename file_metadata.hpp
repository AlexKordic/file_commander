#pragma once
#include "bfs.hpp"

namespace Perun {
// Returns true only for a newly created directory. Existing directories are
// left unchanged; failure is reported through ec.
bool create_private_directory(const Filepath&, boost::system::error_code&);
void copy_directory_access(const Filepath& source, const Filepath& destination, boost::system::error_code&);
// Applied before an EXDEV commit; failure retains the original entry.
void copy_entry_metadata(const Filepath& source, const Filepath& destination, boost::system::error_code&);
void verify_entry_metadata(const Filepath& source, const Filepath& destination, boost::system::error_code&);
// Only for our unpublished staging trees, never source/user directories.
void remove_owned_staging(const Filepath&, boost::system::error_code&);
}
