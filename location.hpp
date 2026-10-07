#pragma once
#include "bfs.hpp"
#include <string>
#include <vector>

// Durable identity: local directory, or outer archive + nested archive names + internal directory.
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
  static Location decode(const std::string&);
  bool operator==(const Location&) const = default;
};
bool is_remote(const Filepath&);
Filepath normalize_location(const Filepath&);
Filepath location_parent(const Filepath&);
