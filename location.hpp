#pragma once
#include "bfs.hpp"
#include <string>
#include <vector>

// Durable identity: local directory, or outer archive + nested archive names + internal directory.
struct Location {
  Filepath local;
  std::vector<Filepath> archives;
  Filepath internal;
  bool read_only() const { return !archives.empty(); }
  std::string encode() const;
  std::string display() const;
  static Location decode(const std::string&);
  bool operator==(const Location&) const = default;
};
