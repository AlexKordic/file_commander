#include "location.hpp"
#include <stdexcept>
namespace {
std::string escape(const std::string &text) {
  const char *hex = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : text) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ||
        c == '.')
      out += c;
    else {
      out += '%';
      out += hex[c >> 4];
      out += hex[c & 15];
    }
  }
  return out;
}
std::string unescape(const std::string &text) {
  auto digit = [](char c) -> int {
    if (c >= '0' && c <= '9')
      return c - '0';
    if (c >= 'A' && c <= 'F')
      return c - 'A' + 10;
    throw std::runtime_error("invalid archive location escape");
  };
  std::string out;
  for (size_t i = 0; i < text.size(); ++i) {
    char c = text[i];
    if (c == '%') {
      if (i + 2 >= text.size())
        throw std::runtime_error("invalid archive location");
      c = char(digit(text[i + 1]) * 16 + digit(text[i + 2]));
      i += 2;
    }
    if (!c)
      throw std::runtime_error("NUL in archive location");
    out += c;
  }
  return out;
}
// lexically_normal() keeps a trailing separator as a "." element
// ("/tmp/fc/" becomes "/tmp/fc/."). A location names the directory itself.
Filepath normal_path(const Filepath &p) {
  auto out = p.lexically_normal();
  if (out.filename() == "." && out.has_parent_path())
    out = out.parent_path();
  return out;
}
// An internal path without "." elements or a trailing separator; empty for the root.
Filepath normal_internal(const Filepath &p) {
  Filepath out;
  for (const auto &part : p)
    if (!part.empty() && part != "." && part != "/")
      out /= part;
  return out;
}
void validate_relative(const Filepath &p) {
  if (p.is_absolute())
    throw std::runtime_error("absolute internal archive path");
  for (const auto &part : p)
    if (part == "..")
      throw std::runtime_error("archive path escapes its root");
}
} // namespace
std::string Location::encode() const {
  if (remote())
    return "fc-ssh:" + escape(ssh) + ":" + local.native();
  if (is_remote(local))
    return Location::decode(local.native()).encode();
  if (!read_only())
    return local.native();
  std::string out = "fc-archive:";
  for (const auto &p : archives)
    out += escape(p.native()) + "!";
  const auto inside = normal_internal(internal);
  return inside.empty() ? out : out + "/" + inside.native();
}
std::string Location::display() const {
  if (remote())
    return "ssh://" + ssh + local.native();
  if (is_remote(local))
    return Location::decode(local.native()).display();
  if (!read_only())
    return local.native();
  std::string out;
  for (const auto &p : archives)
    out += p.native() + "!/";
  return out + (internal == "." ? "" : internal.native());
}
Location Location::decode(const std::string &text) {
  Location result;
  if (text.rfind("fc-ssh:", 0) == 0 || text.rfind("ssh://", 0) == 0 || text.rfind("ssh:/", 0) == 0) {
    size_t begin, end;
    if (text.rfind("fc-ssh:", 0) == 0) {
      begin = 7;
      end = text.find(':', begin);
    } else {
      begin = text.rfind("ssh://", 0) == 0 ? 6 : 5;
      end = text.find('/', begin);
    }
    if (end == std::string::npos)
      throw std::runtime_error("SSH location requires a host and an absolute path");
    result.ssh = unescape(text.substr(begin, end - begin));
    if (result.ssh.empty() || result.ssh.front() == '-' ||
        result.ssh.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@") !=
            std::string::npos)
      throw std::runtime_error("Use an SSH config alias or user@host for the SSH location");
    auto value = text.substr(end + (begin == 7 ? 1 : 0));
    if (value.empty())
      value = "/";
    if (value.front() != '/')
      throw std::runtime_error("SSH paths must be absolute");
    result.local = normal_path(value);
    return result;
  }
  if (text.rfind("fc-archive:", 0) != 0) {
    result.local = normal_path(text);
    return result;
  }
  // The internal path starts after the first "!/" and is stored as is; before it, chain
  // elements are escaped and so hold no '!' or '/'. Older strings escape the internal path
  // too and keep it after the last '!'.
  const auto raw = text.find("!/", 11);
  const auto chain_end = raw == std::string::npos ? text.size() : raw + 1;
  size_t at = 11, end;
  while ((end = text.find('!', at)) != std::string::npos && end < chain_end) {
    result.archives.emplace_back(unescape(text.substr(at, end - at)));
    at = end + 1;
  }
  if (result.archives.empty() || !result.archives.front().is_absolute() || result.archives.size() > 32)
    throw std::runtime_error("invalid archive location chain");
  for (size_t i = 1; i < result.archives.size(); ++i)
    validate_relative(result.archives[i]);
  if (raw != std::string::npos) {
    const auto inside = text.substr(raw + 2);
    if (inside.find('\0') != std::string::npos)
      throw std::runtime_error("NUL in archive location");
    result.internal = inside;
  } else
    result.internal = unescape(text.substr(at));
  validate_relative(result.internal);
  result.internal = normal_internal(result.internal);
  return result;
}
Filepath Location::resource() const { return remote() || read_only() ? Filepath(encode()) : local; }
bool is_remote(const Filepath &p) {
  auto s = p.native();
  return s.starts_with("fc-ssh:") || s.starts_with("ssh://") || s.starts_with("ssh:/");
}
bool is_archive_path(const Filepath &p) { return p.native().starts_with("fc-archive:"); }
Location location_of(const Filepath &p) {
  if (is_virtual_path(p))
    return Location::decode(p.native());
  Location l;
  l.local = p.lexically_normal();
  return l;
}
Filepath normalize_location(const Filepath &p) {
  return is_virtual_path(p) ? Location::decode(p.native()).resource() : p;
}
Filepath location_parent(const Filepath &p) {
  if (is_archive_path(p)) {
    auto l = Location::decode(p.native());
    if (!l.internal.empty()) {
      l.internal = l.internal.parent_path();
      return l.resource();
    }
    // An archive's root: the folder holding the archive file, which may be inside another archive.
    auto file = l.archives.back();
    l.archives.pop_back();
    if (l.archives.empty())
      return file.parent_path();
    l.internal = file.parent_path();
    return l.resource();
  }
  if (!is_remote(p))
    return p.parent_path();
  auto l = Location::decode(p.native());
  l.local = l.local.parent_path();
  if (l.local.empty())
    l.local = "/";
  return l.resource();
}
