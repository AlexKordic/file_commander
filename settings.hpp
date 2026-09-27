#pragma once
#include "commander.hpp"
#include <map>
#include <optional>

struct PanelSettings {
  std::string path;
  Orderby sort = Orderby::NAME_ASC;
  bool permissions = false, owner_group = false;
};
struct AppSettings {
  PanelSettings left, right;
  bool single_panel = false;
  std::string focused_panel = "left";
  std::vector<std::string> bookmarks;
  std::map<std::string, int> command_use_count;
  std::map<std::string, std::string> key_bindings;
  std::string fresh_binary_path, last_editor_session_id;
};
class SettingsStore {
 public:
  static Filepath path(const std::string& name = "settings.json");
  // Missing files are normal. Malformed files throw before any application mutation.
  static std::optional<AppSettings> load(const Filepath& path);
  static void save(const Filepath& path, const AppSettings& value);
  static std::map<std::string, std::string> load_colors();
  static void save_colors(const std::map<std::string, std::string>& colors);
  // The injectable replacement permits deterministic failure testing.
  using Replace = std::function<void(const Filepath&, const Filepath&)>;
  static void atomic_write(const Filepath&, const std::string&, Replace replace = {});
};
