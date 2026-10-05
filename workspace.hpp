#pragma once
#include "settings.hpp"

struct TabWorkspace : PanelSettings {
  std::string focused, filter;
  std::vector<std::string> selected;
};
struct PanelWorkspace {
  std::vector<TabWorkspace> tabs;
  size_t active = 0;
};
struct AppWorkspace {
  PanelWorkspace left, right;
  bool single_panel = false;
  std::string focused_panel = "left";
};
class WorkspaceStore {
 public:
  static std::optional<AppWorkspace> load(const Filepath&);
  static std::string encode(const AppWorkspace&);
};

// One interactive FC owns workspace and transfer journals for a config profile.
// Editor identity has its own short lock so callers can safely reuse it too.
class WorkspaceLease {
  int fd = -1;
 public:
  explicit WorkspaceLease(const Filepath&);
  ~WorkspaceLease();
  WorkspaceLease(const WorkspaceLease&) = delete;
  WorkspaceLease& operator=(const WorkspaceLease&) = delete;
};
