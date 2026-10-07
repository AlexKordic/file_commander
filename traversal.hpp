#pragma once
#include "bfs.hpp"
#include <functional>
#include <optional>
#include <vector>

struct TraversalPolicy {
  bool follow_links = false;
  size_t max_entries = 1000000;
  size_t max_depth = 1024;
};
struct TraversalEntry {
  Filepath path, relative;
  boost::filesystem::file_status status;
  std::optional<Filepath> link_text;
  std::optional<Filepath> duplicate_of;
  std::optional<int64_t> bytes;
  std::optional<std::time_t> modified;
};
struct TraversalResult { size_t entries = 0, errors = 0; bool cancelled = false, truncated = false; };
struct TraversalCallbacks {
  std::function<bool()> cancelled = [] { return false; };
  // Return false to prune this entry's children. Leave is still called.
  std::function<bool(const TraversalEntry&)> enter = [](const auto&) { return true; };
  std::function<void(const TraversalEntry&)> leave = [](const auto&) {};
  std::function<void(const Filepath&, const std::string&)> error = [](const auto&, const auto&) {};
};
// Depth-first, iterative; at most max_depth iterators, no breadth-sized frontier.
TraversalResult traverse(const std::vector<Filepath>& roots, const TraversalPolicy&, const TraversalCallbacks&);
