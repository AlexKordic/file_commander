#include "file_metadata.hpp"
#include "traversal.hpp"
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <algorithm>
#include <limits>
#include <sys/xattr.h>
#if defined(__APPLE__)
#include <copyfile.h>
#include <sys/acl.h>
#endif

namespace Perun {
namespace {
void failed(boost::system::error_code& ec) { ec.assign(errno, boost::system::system_category()); }
ssize_t list_attributes(const Filepath& path, char* names, size_t size) {
#if defined(__APPLE__)
  return ::listxattr(path.c_str(), names, size, XATTR_NOFOLLOW);
#else
  return ::llistxattr(path.c_str(), names, size);
#endif
}
ssize_t get_attribute(const Filepath& path, const char* name, void* bytes, size_t size, uint32_t offset = 0) {
#if defined(__APPLE__)
  return ::getxattr(path.c_str(), name, bytes, size, offset, XATTR_NOFOLLOW);
#else
  return ::lgetxattr(path.c_str(), name, bytes, size);
#endif
}
#if defined(__APPLE__)
std::vector<char> acl_bytes(const Filepath& path, boost::system::error_code& ec) {
  auto acl = ::acl_get_link_np(path.c_str(), ACL_TYPE_EXTENDED);
  if (!acl) {
    if (errno != ENOENT && errno != ENOTSUP) failed(ec);
    return {};
  }
  acl_entry_t entry;
  std::vector<char> bytes;
  if (::acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) == 0) {
    auto size = ::acl_size(acl);
    if (size < 0) failed(ec);
    else {
      bytes.resize(static_cast<size_t>(size));
      if (::acl_copy_ext(bytes.data(), acl, bytes.size()) < 0) failed(ec);
    }
  }
  ::acl_free(acl);
  return bytes;
}
#endif
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
  // Darwin's metadata copy can leave a newly created symlink's mtime intact.
  // Set it explicitly without touching the target, then verify below.
  if (!ec && S_ISLNK(src.st_mode)) {
    const timespec times[] = {src.st_atimespec, src.st_mtimespec};
    if (::utimensat(AT_FDCWD, destination.c_str(), times, AT_SYMLINK_NOFOLLOW) != 0) failed(ec);
  }
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
#if defined(__APPLE__)
    struct stat info {};
    if (::lstat(entry.path.c_str(), &info) != 0) failed(local);
    else if (const auto blocking = info.st_flags & (UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)) {
      // Metadata copying may have made an unpublished entry undeletable.
      // Only clear these flags on our staging entries, without following links.
      if (::lchflags(entry.path.c_str(), info.st_flags & ~blocking) != 0) failed(local);
    }
#endif
    if (!local && boost::filesystem::is_directory(entry.status)) secure_directory(entry.path, local);
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

void verify_entry_metadata(const Filepath& source, const Filepath& destination, boost::system::error_code& ec) {
  ec.clear();
  auto mismatch = [&] { ec = make_error_code(boost::system::errc::operation_not_supported); };
  struct stat src {}, dst {};
  if (::lstat(source.c_str(), &src) != 0 || ::lstat(destination.c_str(), &dst) != 0) { failed(ec); return; }
#if defined(__APPLE__)
  auto src_time = src.st_mtimespec, dst_time = dst.st_mtimespec;
#else
  auto src_time = src.st_mtim, dst_time = dst.st_mtim;
#endif
  if ((src.st_mode & 07777) != (dst.st_mode & 07777) || src.st_uid != dst.st_uid || src.st_gid != dst.st_gid ||
      src_time.tv_sec != dst_time.tv_sec || src_time.tv_nsec != dst_time.tv_nsec) { mismatch(); return; }
#if defined(__APPLE__)
  // copyfile(3) deliberately ignores some chmod/ACL/time errors. Verify the
  // result before letting a move delete its only original copy.
  const auto src_acl = acl_bytes(source, ec);
  if (ec) return;
  const auto dst_acl = acl_bytes(destination, ec);
  if (ec) return;
  if (src_acl != dst_acl) { mismatch(); return; }
#endif
  auto size = list_attributes(source, nullptr, 0);
  if (size < 0) { if (errno != ENOTSUP) failed(ec); return; }
  if (size == 0) return;
  std::vector<char> names(static_cast<size_t>(size));
  size = list_attributes(source, names.data(), names.size());
  if (size < 0) { failed(ec); return; }
  for (size_t at = 0; at < static_cast<size_t>(size);) {
    const char* name = names.data() + at;
    at += std::strlen(name) + 1;
    auto length = get_attribute(source, name, nullptr, 0);
    if (length < 0) { failed(ec); return; }
    auto dest_length = get_attribute(destination, name, nullptr, 0);
    if (dest_length < 0) { failed(ec); return; }
    if (length != dest_length) { mismatch(); return; }
    size_t chunk = static_cast<size_t>(length);
#if defined(__APPLE__)
    // Resource forks can be large; Darwin supports positional access to them.
    if (std::strcmp(name, XATTR_RESOURCEFORK_NAME) == 0) chunk = std::min(chunk, size_t{65536});
#endif
    std::vector<char> before(chunk), after(chunk);
    for (size_t offset = 0; offset < static_cast<size_t>(length); offset += chunk) {
      if (offset > std::numeric_limits<uint32_t>::max()) { mismatch(); return; }
      const auto count = std::min(chunk, static_cast<size_t>(length) - offset);
      auto read_src = get_attribute(source, name, before.data(), count, static_cast<uint32_t>(offset));
      if (read_src < 0) { failed(ec); return; }
      auto read_dst = get_attribute(destination, name, after.data(), count, static_cast<uint32_t>(offset));
      if (read_dst < 0) { failed(ec); return; }
      if (read_src != static_cast<ssize_t>(count) || read_dst != read_src || std::memcmp(before.data(), after.data(), count) != 0) { mismatch(); return; }
    }
  }
}
}
