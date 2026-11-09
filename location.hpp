#pragma once
#include "bfs.hpp"
#include <string>
#include <vector>

// Durable identity: local directory, or outer archive + nested archive names + internal directory.
// An archive location's path form is "fc-archive:" + the escaped chain, each element followed by '!', then
// "/" + the internal path as is: "fc-archive:%2Fhome%2Fa.7z!/docs/b.md". The archive's root ends at the
// last '!'. So `path / name`, `parent_path()` and `filename()` work inside an archive as on local paths.
struct Location {
  Filepath local;
  std::vector<Filepath> archives;
  Filepath internal;
  // SSH config target, separate from the path on that filesystem.
  std::string ssh;
  bool remote() const { return !ssh.empty(); }
  Filepath resource() const;
  bool read_only() const { return !archives.empty(); }
  std::string encode() const;
  std::string display() const;
  static Location decode(const std::string &);
  bool operator==(const Location &) const = default;
};
bool is_remote(const Filepath &);
bool is_archive_path(const Filepath &);
// The location a listing or item path names: SSH and archive paths decoded, local ones as they are.
Location location_of(const Filepath &);
// Neither local: an SSH path or a path inside an archive.
inline bool is_virtual_path(const Filepath &p) { return is_remote(p) || is_archive_path(p); }
Filepath normalize_location(const Filepath &);
Filepath location_parent(const Filepath &);
