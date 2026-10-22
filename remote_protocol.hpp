#pragma once
#include <boost/json.hpp>
#include <array>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>

// FC SSH protocol 2. All integers are big endian. Strings are byte strings;
// paths, attributes, data and digests are never transcoded for the wire.
namespace RemoteFS::Wire {
inline constexpr std::string_view hello{"FCSSH\0\2\0", 8};
inline constexpr uint32_t max_payload = 64 * 1024 * 1024;
inline constexpr uint32_t block_size = 1024 * 1024;
enum Kind : uint8_t { Request = 1, Result, Error, Event, Data, End };
inline constexpr std::array methods{
    "", "stat", "list", "realpath", "read", "write", "mkdir", "remove", "rename",
    "symlink", "metadata", "digest", "fsync", "access", "tree", "attributes", "set_attributes",
    "copy", "stream_read", "stream_write", "stream_copy", "stream_control"};
inline constexpr std::array fields{
    "", "path", "destination", "target", "follow", "offset", "length", "data", "exclusive",
    "recursive", "replace", "expected", "mode", "mtime_ns", "ctime_ns", "exists", "dev", "ino",
    "uid", "gid", "size", "link", "owner", "group", "target_dir", "entries", "name", "relative",
    "stamp", "attributes", "platform", "acl", "allowed", "sha256", "bytes", "errno", "message",
    "checkpoint", "verified", "durable", "rate", "paused", "cancelled", "source", "phase"};
inline uint16_t opcode(std::string_view name) {
  for (uint16_t n = 1; n < methods.size(); ++n)
    if (name == methods[n]) return n;
  throw std::runtime_error("Unknown SSH operation");
}
inline void integer(std::string &out, uint64_t n, unsigned width) {
  for (unsigned i = width; i; --i) out += char(n >> ((i - 1) * 8));
}
inline uint64_t integer(std::string_view &in, unsigned width) {
  if (in.size() < width) throw std::runtime_error("Truncated SSH binary message");
  uint64_t n = 0;
  for (unsigned i = 0; i < width; ++i) n = (n << 8) | uint8_t(in[i]);
  in.remove_prefix(width);
  return n;
}
inline void bytes(std::string &out, std::string_view s) {
  if (s.size() > max_payload) throw std::runtime_error("SSH byte string exceeds limit");
  integer(out, s.size(), 4); out.append(s);
}
inline std::string_view bytes(std::string_view &in) {
  auto n = integer(in, 4);
  if (n > in.size()) throw std::runtime_error("Truncated SSH byte string");
  auto s = in.substr(0, n); in.remove_prefix(n); return s;
}
inline void encode(std::string &out, const boost::json::value &v, unsigned depth = 0) {
  if (depth > 32 || out.size() > max_payload) throw std::runtime_error("SSH value exceeds limit");
  if (v.is_null()) out += char(0);
  else if (v.is_bool()) out += char(v.as_bool() ? 2 : 1);
  else if (v.is_int64()) { out += char(3); integer(out, uint64_t(v.as_int64()), 8); }
  else if (v.is_uint64()) { out += char(4); integer(out, v.as_uint64(), 8); }
  else if (v.is_string()) { out += char(5); bytes(out, v.as_string()); }
  else if (v.is_array()) {
    out += char(6); integer(out, v.as_array().size(), 4);
    for (const auto &item : v.as_array()) encode(out, item, depth + 1);
  } else if (v.is_object()) {
    out += char(7); integer(out, v.as_object().size(), 4);
    for (const auto &item : v.as_object()) {
      uint16_t key = 0;
      for (uint16_t i = 1; i < fields.size(); ++i) if (item.key() == fields[i]) { key = i; break; }
      integer(out, key, 2);
      if (!key) bytes(out, item.key());
      encode(out, item.value(), depth + 1);
    }
  } else throw std::runtime_error("Unsupported SSH binary value");
}
inline std::string encode(const boost::json::value &v) {
  std::string out; encode(out, v);
  if (out.size() > max_payload) throw std::runtime_error("SSH value exceeds limit");
  return out;
}
inline boost::json::value decode_value(std::string_view &in, unsigned depth, size_t &nodes) {
  if (depth > 32 || ++nodes > 1000000) throw std::runtime_error("SSH value exceeds limit");
  auto kind = integer(in, 1);
  switch (kind) {
  case 0: return nullptr;
  case 1: return false;
  case 2: return true;
  case 3: return int64_t(integer(in, 8));
  case 4: return integer(in, 8);
  case 5: return boost::json::string(bytes(in));
  case 6: {
    auto n = integer(in, 4);
    if (n > in.size() || n > 1000000) throw std::runtime_error("Invalid SSH array size");
    boost::json::array a;
    for (uint64_t i = 0; i < n; ++i) a.push_back(decode_value(in, depth + 1, nodes));
    return a;
  }
  case 7: {
    auto n = integer(in, 4);
    if (n > in.size() / 3 || n > 1000000) throw std::runtime_error("Invalid SSH object size");
    boost::json::object o;
    for (uint64_t i = 0; i < n; ++i) {
      auto k = integer(in, 2);
      if (k >= fields.size()) throw std::runtime_error("Unknown SSH field");
      std::string key(k ? std::string_view(fields[k]) : bytes(in));
      if (o.contains(key)) throw std::runtime_error("Duplicate SSH field");
      o[key] = decode_value(in, depth + 1, nodes);
    }
    return o;
  }
  default: throw std::runtime_error("Unknown SSH binary value");
  }
}
inline boost::json::value decode(std::string_view in) {
  size_t nodes = 0;
  auto v = decode_value(in, 0, nodes);
  if (!in.empty()) throw std::runtime_error("Trailing SSH binary data");
  return v;
}
struct Frame {
  uint8_t kind = 0;
  uint16_t operation = 0;
  uint64_t id = 0;
  std::string payload;
};
inline std::string header(uint8_t kind, uint16_t operation, uint64_t id, size_t length) {
  if (length > max_payload || (kind == Data && length > block_size))
    throw std::runtime_error("SSH frame exceeds limit");
  std::string out; out.reserve(16);
  out += char(kind); out += char(0);
  integer(out, operation, 2); integer(out, id, 8); integer(out, length, 4);
  return out;
}
inline Frame header(std::string_view in, uint32_t &length) {
  if (in.size() != 16) throw std::runtime_error("Invalid SSH header size");
  Frame f; f.kind = integer(in, 1);
  if (integer(in, 1) || f.kind < Request || f.kind > End) throw std::runtime_error("Invalid SSH frame flags or kind");
  f.operation = integer(in, 2); f.id = integer(in, 8); length = integer(in, 4);
  if (f.operation == 0 || f.operation >= methods.size() || length > max_payload ||
      (f.kind == Data && length > block_size)) throw std::runtime_error("Invalid SSH frame bounds");
  return f;
}
} // namespace RemoteFS::Wire
