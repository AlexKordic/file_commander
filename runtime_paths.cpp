#include "runtime_paths.hpp"

#include <boost/filesystem.hpp>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#elif defined(__linux__)
#include <unistd.h>
#endif

namespace {

Filepath fallback_dir() {
  boost::system::error_code ec;
  Filepath                  cwd = boost::filesystem::current_path(ec);
  if (ec.failed()) return Filepath(".");
  return cwd;
}

bool file_exists(const Filepath& path) {
  boost::system::error_code ec;
  const bool                exists = boost::filesystem::exists(path, ec);
  return !ec.failed() && exists;
}

bool contains_path_separator(const std::string& value) {
  return value.find('/') != std::string::npos || value.find('\\') != std::string::npos;
}

}  // namespace

Filepath executable_dir_path() {
#if defined(__APPLE__)
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::string buf(size, '\0');
  if (_NSGetExecutablePath(buf.data(), &size) == 0) {
    Filepath raw(buf.c_str());
    boost::system::error_code ec;
    Filepath canonical = boost::filesystem::canonical(raw, ec);
    if (!ec.failed()) return canonical.parent_path();
    return raw.parent_path().lexically_normal();
  }
#elif defined(__linux__)
  std::string buf(4096, '\0');
  const ssize_t n = readlink("/proc/self/exe", buf.data(), buf.size() - 1);
  if (n > 0) {
    buf.resize(static_cast<size_t>(n));
    Filepath raw(buf);
    boost::system::error_code ec;
    Filepath canonical = boost::filesystem::canonical(raw, ec);
    if (!ec.failed()) return canonical.parent_path();
    return raw.parent_path().lexically_normal();
  }
#endif
  return fallback_dir();
}

std::string normalize_tool_reference(std::string value) {
  if (value.empty()) return value;

  const Filepath exe_dir = executable_dir_path();
  Filepath       p(value);

  if (p.is_absolute()) {
    if (file_exists(p)) return p.lexically_normal().native();
    const Filepath local = exe_dir / p.filename();
    if (file_exists(local)) return local.lexically_normal().native();
    return p.lexically_normal().native();
  }

  if (contains_path_separator(value)) {
    Filepath local = (exe_dir / p).lexically_normal();
    if (file_exists(local)) return local.native();
    return local.native();
  }

  Filepath local = (exe_dir / p).lexically_normal();
  if (file_exists(local)) return local.native();
  return value;
}
