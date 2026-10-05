#include "file_metadata.hpp"
#include "traversal.hpp"
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#if defined(__APPLE__)
#include <copyfile.h>
#include <sys/acl.h>
#elif defined(__linux__)
#include <sys/xattr.h>
#endif

namespace Perun {
namespace {
void failed(boost::system::error_code& ec) { ec.assign(errno, boost::system::system_category()); }
#if defined(__linux__)
bool absent_attribute() { return errno == ENODATA || errno == ENOTSUP; }
bool copy_attribute(const Filepath& source, const Filepath& destination, const char* name, boost::system::error_code& ec) {
  auto size = ::getxattr(source.c_str(), name, nullptr, 0);
  if (size < 0) {
    if (!absent_attribute()) { failed(ec); return false; }
    if (::removexattr(destination.c_str(), name) != 0 && !absent_attribute()) { failed(ec); return false; }
    return true;
  }
  std::vector<char> bytes(static_cast<size_t>(size));
  auto read = ::getxattr(source.c_str(), name, bytes.data(), bytes.size());
  if (read < 0) { failed(ec); return false; }
  if (::setxattr(destination.c_str(), name, bytes.data(), static_cast<size_t>(read), 0) != 0) { failed(ec); return false; }
  return true;
}
#endif
void secure_directory(const Filepath& path, boost::system::error_code& ec) {
#if defined(__APPLE__)
  auto acl = ::acl_init(0);
  if (!acl) failed(ec);
  else {
    if (::acl_set_file(path.c_str(), ACL_TYPE_EXTENDED, acl) != 0 && errno != ENOTSUP) failed(ec);
    ::acl_free(acl);
  }
#elif defined(__linux__)
  for (auto name : {"system.posix_acl_access", "system.posix_acl_default"})
    if (::removexattr(path.c_str(), name) != 0 && !absent_attribute()) { failed(ec); break; }
#endif
  if (!ec && ::chmod(path.c_str(), 0700) != 0) failed(ec);
}
}

bool create_private_directory(const Filepath& path, boost::system::error_code& ec) {
  ec.clear();
  if (::mkdir(path.c_str(), 0700) != 0) {
    const int creation_error = errno;
    if (creation_error == EEXIST && boost::filesystem::is_directory(path, ec)) { ec.clear(); return false; }
    if (!ec) ec.assign(creation_error, boost::system::system_category());
    return false;
  }
  // Remove inherited ACL grants while empty, before writing any payload.
  secure_directory(path, ec);
  if (ec) { ::rmdir(path.c_str()); return false; }
  return true;
}

void copy_directory_access(const Filepath& source, const Filepath& destination, boost::system::error_code& ec) {
  ec.clear();
  struct stat info {};
  if (::stat(source.c_str(), &info) != 0) { failed(ec); return; }
  if (!S_ISDIR(info.st_mode)) { ec = make_error_code(boost::system::errc::not_a_directory); return; }
#if defined(__APPLE__)
  auto acl = ::acl_get_file(source.c_str(), ACL_TYPE_EXTENDED);
  // Darwin reports ENOENT for an existing object with no extended ACL.
  if (!acl && errno == ENOENT) {
    struct stat still_exists {};
    if (::stat(source.c_str(), &still_exists) != 0) { failed(ec); return; }
    acl = ::acl_init(0);
    if (!acl) { failed(ec); return; }
  }
  if (!acl) {
    if (errno != ENOTSUP) { failed(ec); return; }
  } else {
    acl_entry_t entry;
    const bool empty = ::acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) != 0;
    if (::acl_set_file(destination.c_str(), ACL_TYPE_EXTENDED, acl) != 0 && !(empty && errno == ENOTSUP)) failed(ec);
    ::acl_free(acl);
    if (ec) return;
  }
#elif defined(__linux__)
  for (auto name : {"system.posix_acl_access", "system.posix_acl_default"})
    if (!copy_attribute(source, destination, name, ec)) return;
#endif
  if (::chmod(destination.c_str(), info.st_mode & 07777) != 0) failed(ec);
}

void copy_entry_metadata(const Filepath& source, const Filepath& destination, boost::system::error_code& ec) {
  ec.clear();
  struct stat src {}, dst {};
  if (::lstat(source.c_str(), &src) != 0 || ::lstat(destination.c_str(), &dst) != 0) { failed(ec); return; }
  // Ownership changes can clear mode bits and security attributes: do them first.
  if ((src.st_uid != dst.st_uid || src.st_gid != dst.st_gid) &&
      ::lchown(destination.c_str(), src.st_uid, src.st_gid) != 0) { failed(ec); return; }
#if defined(__APPLE__)
  auto state = ::copyfile_state_alloc();
  if (!state) { ec = make_error_code(boost::system::errc::not_enough_memory); return; }
  uint32_t preserve = 1;
  if (::copyfile_state_set(state, COPYFILE_STATE_PRESERVE_SUID, &preserve) != 0 ||
      ::copyfile(source.c_str(), destination.c_str(), state, COPYFILE_METADATA | COPYFILE_NOFOLLOW) != 0) failed(ec);
  ::copyfile_state_free(state);
#elif defined(__linux__)
  auto size = ::llistxattr(source.c_str(), nullptr, 0);
  if (size < 0 && errno != ENOTSUP) { failed(ec); return; }
  if (size > 0) {
    std::vector<char> names(static_cast<size_t>(size));
    size = ::llistxattr(source.c_str(), names.data(), names.size());
    if (size < 0) { failed(ec); return; }
    for (size_t at = 0; at < static_cast<size_t>(size);) {
      const char* name = names.data() + at;
      at += std::strlen(name) + 1;
      auto length = ::lgetxattr(source.c_str(), name, nullptr, 0);
      if (length < 0) { failed(ec); return; }
      std::vector<char> value(static_cast<size_t>(length));
      length = ::lgetxattr(source.c_str(), name, value.data(), value.size());
      if (length < 0 || ::lsetxattr(destination.c_str(), name, value.data(), static_cast<size_t>(length), 0) != 0) { failed(ec); return; }
    }
  }
  if (!S_ISLNK(src.st_mode) && ::chmod(destination.c_str(), src.st_mode & 07777) != 0) { failed(ec); return; }
  const timespec times[] = {src.st_atim, src.st_mtim};
  if (::utimensat(AT_FDCWD, destination.c_str(), times, AT_SYMLINK_NOFOLLOW) != 0) failed(ec);
#else
  ec = make_error_code(boost::system::errc::operation_not_supported);
#endif
}

void remove_owned_staging(const Filepath& root, boost::system::error_code& ec) {
  ec.clear();
  TraversalCallbacks cb;
  cb.error = [&](const Filepath&, const std::string&) { if (!ec) ec = make_error_code(boost::system::errc::io_error); };
  cb.enter = [&](const TraversalEntry& entry) {
    boost::system::error_code local;
    if (boost::filesystem::is_directory(entry.status)) secure_directory(entry.path, local);
    if (local && !ec) ec = local;
    return !local;
  };
  cb.leave = [&](const TraversalEntry& entry) {
    boost::system::error_code local;
    boost::filesystem::remove(entry.path, local);
    if (local && !ec) ec = local;
  };
  traverse({root}, {}, cb);
}
}
