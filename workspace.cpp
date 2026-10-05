#include "workspace.hpp"
#include "location.hpp"
#include <boost/json.hpp>
#include <fstream>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

namespace {
namespace j = boost::json;
std::string string(const j::value& v) { return std::string(v.as_string()); }
j::object panel(const PanelWorkspace& p) {
  j::array tabs;
  for (const auto& t : p.tabs) {
    j::array selected; for (const auto& path : t.selected) selected.emplace_back(path);
    tabs.emplace_back(j::object{{"path", t.path}, {"focused", t.focused}, {"filter", t.filter},
      {"selected", std::move(selected)}, {"sort", int(t.sort)},
      {"permissions", t.permissions}, {"owner_group", t.owner_group}});
  }
  return {{"active", p.active}, {"tabs", std::move(tabs)}};
}
PanelWorkspace panel(const j::object& o) {
  PanelWorkspace p;
  auto active = o.at("active").as_int64();
  const auto& tabs = o.at("tabs").as_array();
  if (tabs.empty() || tabs.size() > 512 || active < 0 || size_t(active) >= tabs.size())
    throw std::runtime_error("Invalid workspace tab list");
  p.active = size_t(active);
  for (const auto& value : tabs) {
    const auto& t = value.as_object();
    TabWorkspace tab;
    tab.path = string(t.at("path"));
    if (tab.path.empty()) throw std::runtime_error("Empty workspace location");
    Location::decode(tab.path);
    tab.focused = string(t.at("focused"));
    if (!tab.focused.empty()) Location::decode(tab.focused);
    tab.filter = string(t.at("filter"));
    auto sort = t.at("sort").as_int64();
    if (sort < 0 || sort > 5) throw std::runtime_error("Invalid workspace sort");
    tab.sort = static_cast<Orderby>(sort);
    tab.permissions = t.at("permissions").as_bool();
    tab.owner_group = t.at("owner_group").as_bool();
    for (const auto& selected : t.at("selected").as_array()) {
      tab.selected.push_back(string(selected));
      Location::decode(tab.selected.back());
    }
    p.tabs.push_back(std::move(tab));
  }
  return p;
}
}

std::optional<AppWorkspace> WorkspaceStore::load(const Filepath& path) {
  if (!boost::filesystem::exists(path)) return {};
  if (boost::filesystem::file_size(path) > 16 * 1024 * 1024) throw std::runtime_error("Workspace exceeds 16 MiB");
  std::ifstream in(path.string());
  if (!in) throw std::runtime_error("Cannot read workspace");
  auto o = j::parse(std::string(std::istreambuf_iterator<char>(in), {})).as_object();
  if (o.at("version").as_int64() != 1) throw std::runtime_error("Unsupported workspace version");
  AppWorkspace w;
  w.left = panel(o.at("left").as_object());
  w.right = panel(o.at("right").as_object());
  w.single_panel = o.at("single_panel").as_bool();
  w.focused_panel = string(o.at("focused_panel"));
  if (w.focused_panel != "left" && w.focused_panel != "right") throw std::runtime_error("Invalid workspace focus");
  return w;
}

std::string WorkspaceStore::encode(const AppWorkspace& w) {
  return j::serialize(j::object{{"version", 1}, {"left", panel(w.left)}, {"right", panel(w.right)},
    {"single_panel", w.single_panel}, {"focused_panel", w.focused_panel}}) + "\n";
}

WorkspaceLease::WorkspaceLease(const Filepath& path) {
  boost::filesystem::create_directories(path.parent_path());
  fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) throw std::runtime_error("Cannot open workspace lock: " + path.native());
  if (::flock(fd, LOCK_EX | LOCK_NB) != 0) {
    ::close(fd); fd = -1;
    throw std::runtime_error("This FC profile is already open. Return to its terminal or use a different XDG_CONFIG_HOME.");
  }
}
WorkspaceLease::~WorkspaceLease() { if (fd >= 0) ::close(fd); }
