#include "settings.hpp"
#include <boost/json.hpp>
#include <fstream>
#include <limits>
#include <unistd.h>
#include <fcntl.h>

namespace {
namespace j = boost::json;
const char* sorts[] = {"NAME_ASC", "NAME_DESC", "SIZE_ASC", "SIZE_DESC", "TIME_ASC", "TIME_DESC"};
std::optional<j::object> read(const Filepath& path) {
  boost::system::error_code ec;
  if (!boost::filesystem::exists(path, ec) && (!ec || ec == boost::system::errc::no_such_file_or_directory)) return {};
  if (ec) throw std::runtime_error(ec.message());
  if (boost::filesystem::file_size(path) > 4 * 1024 * 1024) throw std::runtime_error("settings file exceeds 4 MiB");
  std::ifstream in(path.string());
  if (!in) throw std::runtime_error("cannot read " + path.string());
  std::string data((std::istreambuf_iterator<char>(in)), {});
  auto result = j::parse(data).as_object();
  if (auto version = result.if_contains("version"); version && version->as_int64() != 1)
    throw std::runtime_error("unsupported settings version");
  return result;
}
std::string str(const j::value& v) { return std::string(v.as_string()); }
void string_field(const j::object& o, const std::string& key, std::string& out) { if (auto v=o.if_contains(key)) out=str(*v); }
void bool_field(const j::object& o, const std::string& key, bool& out) { if (auto v=o.if_contains(key)) out=v->as_bool(); }
std::map<std::string, std::string> string_map(const j::value& v) {
  std::map<std::string, std::string> out;
  for (const auto& kv : v.as_object()) out[std::string(kv.key())] = str(kv.value());
  return out;
}
j::object object(const std::map<std::string,std::string>& m) {
  j::object out; for (const auto& [k,v] : m) out[k]=v; return out;
}
void panel(const j::object& o, const std::string& prefix, PanelSettings& p) {
  string_field(o,prefix+"_path",p.path);
  bool_field(o,prefix+"_show_permissions",p.permissions);
  bool_field(o,prefix+"_show_owner_group",p.owner_group);
  if (auto v=o.if_contains(prefix+"_sort")) {
    auto name=str(*v); int i=0; for (;i<6 && name != sorts[i];++i) {}
    if (i==6) throw std::runtime_error("invalid sort order: " + name);
    p.sort=static_cast<Orderby>(i);
  }
}
void panel(j::object& o, const std::string& prefix, const PanelSettings& p) {
  o[prefix+"_path"]=p.path; o[prefix+"_sort"]=sorts[static_cast<int>(p.sort)];
  o[prefix+"_show_permissions"]=p.permissions; o[prefix+"_show_owner_group"]=p.owner_group;
}
}
Filepath SettingsStore::path(const std::string& name) {
  if (const char* xdg=std::getenv("XDG_CONFIG_HOME"); xdg && *xdg) return Filepath(xdg)/"file_commander"/name;
  if (const char* home=std::getenv("HOME"); home && *home) return Filepath(home)/".config"/"file_commander"/name;
  throw std::runtime_error("no configuration directory");
}
std::optional<AppSettings> SettingsStore::load(const Filepath& path) {
  auto json=read(path); if (!json) return {};
  AppSettings s; const auto& o=*json;
  panel(o,"left",s.left); panel(o,"right",s.right);
  bool_field(o,"single_panel_mode",s.single_panel); string_field(o,"focused_panel",s.focused_panel);
  if (s.focused_panel!="left" && s.focused_panel!="right") throw std::runtime_error("invalid focused panel");
  string_field(o,"fresh_binary_path",s.fresh_binary_path); string_field(o,"last_editor_session_id",s.last_editor_session_id);
  if (auto v=o.if_contains("bookmarks")) for (const auto& p:v->as_array()) s.bookmarks.push_back(str(p));
  if (auto v=o.if_contains("key_bindings")) s.key_bindings=string_map(*v);
  if (auto v=o.if_contains("command_use_count")) for (const auto& kv:v->as_object()) {
    auto n=kv.value().as_int64(); if (n<0 || n>std::numeric_limits<int>::max()) throw std::runtime_error("invalid command use count");
    s.command_use_count[std::string(kv.key())]=static_cast<int>(n);
  }
  return s;
}
void SettingsStore::save(const Filepath& path, const AppSettings& s) {
  j::object o; o["version"]=1; panel(o,"left",s.left); panel(o,"right",s.right);
  o["single_panel_mode"]=s.single_panel; o["focused_panel"]=s.focused_panel;
  o["fresh_binary_path"]=s.fresh_binary_path; o["last_editor_session_id"]=s.last_editor_session_id;
  j::array bookmarks; for (const auto& p:s.bookmarks) bookmarks.emplace_back(p); o["bookmarks"]=std::move(bookmarks);
  o["key_bindings"]=object(s.key_bindings);
  j::object counts; for (const auto& [k,v]:s.command_use_count) counts[k]=v; o["command_use_count"]=std::move(counts);
  atomic_write(path,j::serialize(o)+"\n");
}
void SettingsStore::atomic_write(const Filepath& path, const std::string& data, Replace replace) {
  boost::filesystem::create_directories(path.parent_path());
  auto pattern=path.string()+".XXXXXX";
  int fd=::mkstemp(pattern.data()); if (fd<0) throw std::runtime_error("cannot create settings temporary file");
  Filepath temp(pattern);
  try {
    size_t at=0; while (at<data.size()) {
      auto n=::write(fd,data.data()+at,data.size()-at);
      if (n<0 && errno==EINTR) continue;
      if (n<=0) throw std::runtime_error("cannot write settings"); at+=n;
    }
    if (::fsync(fd)!=0) throw std::runtime_error("cannot flush settings");
    auto rc=::close(fd); fd=-1; if (rc!=0) throw std::runtime_error("cannot close settings");
    if (replace) replace(temp,path); else boost::filesystem::rename(temp,path);
  } catch (...) {
    if (fd>=0) ::close(fd);
    boost::system::error_code ec; boost::filesystem::remove(temp,ec); throw;
  }
}
std::map<std::string,std::string> SettingsStore::load_colors() {
  auto o=read(path("theme_colors.json"));
  if (!o || !o->contains("colors")) return {};
  return string_map(o->at("colors"));
}
void SettingsStore::save_colors(const std::map<std::string,std::string>& colors) {
  atomic_write(path("theme_colors.json"),j::serialize(j::object{{"version",1},{"colors",object(colors)}})+"\n");
}
