#ifndef FC_APP_HPP_
#define FC_APP_HPP_

// Application-level classes: DialogOverlay, Panel, FileCommander
// Extracted from main.cpp so that scripting.cpp can access Panel & FileCommander members.

#include "bfs.hpp"
#include "archive.hpp"
#include "commander.hpp"
#include "dialogs.hpp"
#include "editor_manager.hpp"
#include "file_io_jobs.hpp"
#include "custom_controls.hpp"
#include "log.hpp"
#include "theme.hpp"

#include <deque>
#include <ftxui/component/component.hpp>
#include <ftxui/component/component_base.hpp>
#include <ftxui/component/component_options.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/dom/table.hpp>

#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <format>
#include <functional>
#include <map>
#include <memory>
#include <regex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include <boost/filesystem.hpp>

using namespace ftxui;
using namespace Perun;

namespace fc_settings_detail {

inline std::string json_escape(const std::string& input) {
  std::string out;
  out.reserve(input.size() + 16);
  for (char c : input) {
    switch (c) {
    case '\\': out += "\\\\"; break;
    case '"': out += "\\\""; break;
    case '\n': out += "\\n"; break;
    case '\r': out += "\\r"; break;
    case '\t': out += "\\t"; break;
    default: out += c; break;
    }
  }
  return out;
}

inline std::string json_unescape(const std::string& input) {
  std::string out;
  out.reserve(input.size());
  bool escaped = false;
  for (char c : input) {
    if (escaped) {
      switch (c) {
      case 'n': out += '\n'; break;
      case 'r': out += '\r'; break;
      case 't': out += '\t'; break;
      case '\\': out += '\\'; break;
      case '"': out += '"'; break;
      default: out += c; break;
      }
      escaped = false;
      continue;
    }
    if (c == '\\') {
      escaped = true;
      continue;
    }
    out += c;
  }
  return out;
}

inline bool extract_json_object(const std::string& json, const std::string& key, std::string& object_out) {
  const std::string quoted_key = "\"" + key + "\"";
  size_t            key_pos    = json.find(quoted_key);
  if (key_pos == std::string::npos) return false;
  size_t brace_pos = json.find('{', key_pos + quoted_key.size());
  if (brace_pos == std::string::npos) return false;
  bool   in_string = false;
  bool   escaped   = false;
  size_t depth     = 0;
  for (size_t i = brace_pos; i < json.size(); ++i) {
    const char c = json[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == '\\') {
      escaped = true;
      continue;
    }
    if (c == '"') {
      in_string = !in_string;
      continue;
    }
    if (in_string) continue;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) {
        object_out = json.substr(brace_pos, i - brace_pos + 1);
        return true;
      }
    }
  }
  return false;
}

inline bool extract_json_array(const std::string& json, const std::string& key, std::string& array_out) {
  const std::string quoted_key = "\"" + key + "\"";
  size_t            key_pos    = json.find(quoted_key);
  if (key_pos == std::string::npos) return false;
  size_t bracket_pos = json.find('[', key_pos + quoted_key.size());
  if (bracket_pos == std::string::npos) return false;
  bool   in_string = false;
  bool   escaped   = false;
  size_t depth     = 0;
  for (size_t i = bracket_pos; i < json.size(); ++i) {
    const char c = json[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == '\\') {
      escaped = true;
      continue;
    }
    if (c == '"') {
      in_string = !in_string;
      continue;
    }
    if (in_string) continue;
    if (c == '[') depth++;
    if (c == ']') {
      depth--;
      if (depth == 0) {
        array_out = json.substr(bracket_pos, i - bracket_pos + 1);
        return true;
      }
    }
  }
  return false;
}

inline bool extract_json_string_field(const std::string& json, const std::string& key, std::string& value_out) {
  const std::regex re("\"" + key + "\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"");
  std::smatch      match;
  if (!std::regex_search(json, match, re)) return false;
  if (match.size() < 2) return false;
  value_out = json_unescape(match[1].str());
  return true;
}

inline bool extract_json_bool_field(const std::string& json, const std::string& key, bool& value_out) {
  const std::regex re("\"" + key + "\"\\s*:\\s*(true|false)");
  std::smatch      match;
  if (!std::regex_search(json, match, re)) return false;
  if (match.size() < 2) return false;
  value_out = match[1].str() == "true";
  return true;
}

inline std::map<std::string, std::string> parse_string_map_object(const std::string& obj_json) {
  std::map<std::string, std::string> out;
  const std::regex                   pair_re("\"((?:\\\\.|[^\"\\\\])*)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"");
  for (auto it = std::sregex_iterator(obj_json.begin(), obj_json.end(), pair_re); it != std::sregex_iterator(); ++it) {
    out[json_unescape((*it)[1].str())] = json_unescape((*it)[2].str());
  }
  return out;
}

inline std::map<std::string, int> parse_int_map_object(const std::string& obj_json) {
  std::map<std::string, int> out;
  const std::regex           pair_re("\"((?:\\\\.|[^\"\\\\])*)\"\\s*:\\s*(-?\\d+)");
  for (auto it = std::sregex_iterator(obj_json.begin(), obj_json.end(), pair_re); it != std::sregex_iterator(); ++it) {
    out[json_unescape((*it)[1].str())] = std::stoi((*it)[2].str());
  }
  return out;
}

inline std::vector<std::string> parse_string_array(const std::string& array_json) {
  std::vector<std::string> out;
  const std::regex         str_re("\"((?:\\\\.|[^\"\\\\])*)\"");
  for (auto it = std::sregex_iterator(array_json.begin(), array_json.end(), str_re); it != std::sregex_iterator(); ++it) {
    out.push_back(json_unescape((*it)[1].str()));
  }
  return out;
}

}  // namespace fc_settings_detail

class Panel;

using TargetFunc = std::function<Filepath(Panel*)>;

using ExecuteOnUiThread = std::function<void(std::function<void()>)>;
using RunWithRestoredIO = std::function<int(std::function<int()>)>;

class DialogOverlay {
 public:
  Component   navigation;
  int         _active_dialog = 0;
  std::string _active_dialog_name;

  // Event callback — set by main.cpp when LuaScripting is active, no-op otherwise
  std::function<void(const std::string&, const std::string&)> on_event;

  ftxui::Dialog::P get_overlay_dialog(const std::string& name) {
    auto it = _overlay_dialogs.find(name);
    if (it != _overlay_dialogs.end()) return it->second;
    return nullptr;
  }

 protected:
  ftxui::Dialog::P                        _main_document;     // always rendered, always first child of Panel::container
  Component                               _overlay_renderer;  // selected renderer from _overlay_dialogs, always second child of Panel::container
  std::map<std::string, ftxui::Dialog::P> _overlay_dialogs;

  bool dialog_active() { return _active_dialog > 0; }

  void close_dialog() {
    std::string closed_dialog_name = _active_dialog_name;
    // Move navigation to main document
    _active_dialog = 0;
    _active_dialog_name.clear();
    _overlay_renderer.reset();
    // Remove all dialogs, child index > 0
    while (navigation->ChildCount() > 1) { navigation->ChildAt(navigation->ChildCount() - 1)->Detach(); }
    if (on_event) on_event("dialog_closed", closed_dialog_name);
  }
  void show_dialog(std::string name) {
    if (!_overlay_dialogs.contains(name)) {
      Perun::l.e("show_dialog() name not registered", name);
      return;
    }
    _active_dialog = 1;
    _active_dialog_name = name;
    // Remove all dialogs, child index > 0
    while (navigation->ChildCount() > 1) { navigation->ChildAt(navigation->ChildCount() - 1)->Detach(); }
    // Add proper dialog
    auto dialog = _overlay_dialogs.at(name);
    navigation->Add(dialog->navigation);
    // dialog->container->TakeFocus();
    _overlay_renderer = dialog->renderer;
    // init dialog with input data
    dialog->OnShow();
    if (on_event) on_event("dialog_opened", name);
  }
};

// DialogOverlay supports drawing overlay dialogs on top of this Panel.
class Panel : public DialogOverlay {
 public:
  struct ArchiveView {
    Filepath archive_file;
    Filepath extracted_root;
  };

  struct TabState {
    Dir         dir;
    int         focused_index = 0;
    std::string filter_txt;
    bool        show_permissions_column = false;
    bool        show_owner_group_column = false;
    std::vector<ArchiveView> archive_stack;
  };

  Dir        dir;
  TargetFunc get_target;

  ExecuteOnUiThread                 run_on_ui;
  std::unique_ptr<FileChangeFunnel> update_funnel;
  Perun::FifoQueue<UpdatedFiles>    pending_changes;

  Panel(Filepath location, TargetFunc get_target, ExecuteOnUiThread e) : get_target(get_target), run_on_ui(e) {
    this->move_to(location);
    _state                      = std::make_shared<PanelSharedState>(&dir);
    navigation                  = Container::Tab({}, &_active_dialog);
    _state->move_to             = [this](Filepath where) { this->move_to(where); };
    _state->enter_archive       = [this](const Filepath& where) { return this->enter_archive(where); };
    _state->leave_virtual_dir   = [this](int64_t& focused_id) { return this->leave_virtual_dir(focused_id); };
    _state->action.close_dialog = [this]() { close_dialog(); };
    _state->action.show_dialog  = [this]() {
      _state->action.arguments->target = this->get_target(this);
      show_dialog(_state->action.dialog);
    };
    _files         = std::make_shared<ftxui::Files>(_state);
    _main_document = std::dynamic_pointer_cast<ftxui::Dialog>(_files);
    navigation->Add(_main_document->navigation);
    // register dialogs
    _overlay_dialogs["Mkdir"]           = std::make_shared<MkdirDialog>(_state);
    _overlay_dialogs["Rename"]          = std::make_shared<RenameDialog>(_state);
    _overlay_dialogs["Copy"]            = std::make_shared<CopyDialog>(_state);
    _overlay_dialogs["Move"]            = std::make_shared<MoveDialog>(_state);
    _overlay_dialogs["Delete"]          = std::make_shared<DeleteDialog>(_state);
    _overlay_dialogs["Find"]            = std::make_shared<FindDialog>(_state);
    _overlay_dialogs["GlobSelect"]      = std::make_shared<GlobSelectDialog>(_state, true);
    _overlay_dialogs["GlobDeselect"]    = std::make_shared<GlobSelectDialog>(_state, false);
    _overlay_dialogs["NameToClipboard"] = std::make_shared<ToClipboardDialog>(_state);
    _overlay_dialogs["PathToClipboard"] = std::make_shared<ToClipboardDialog>(_state);

    _tabs.push_back(TabState{});
    _tabs[0].dir = dir;
    sync_active_tab_state();
  }

  int tab_count() const { return static_cast<int>(_tabs.size()); }
  int active_tab_index() const { return _active_tab; }

  std::vector<Filepath> tab_paths() const {
    std::vector<Filepath> out;
    out.reserve(_tabs.size());
    for (int i = 0; i < static_cast<int>(_tabs.size()); ++i) {
      if (i == _active_tab) out.push_back(dir.path);
      else out.push_back(_tabs[i].dir.path);
    }
    return out;
  }

  void new_tab() {
    sync_active_tab_state();
    TabState clone = _tabs.at(_active_tab);
    _tabs.insert(_tabs.begin() + _active_tab + 1, std::move(clone));
    switch_to_tab(_active_tab + 1);
    if (on_event) on_event("tab_created", std::to_string(_active_tab));
  }

  void close_tab() {
    if (_tabs.size() <= 1) return;
    sync_active_tab_state();
    _tabs.erase(_tabs.begin() + _active_tab);
    if (_active_tab >= static_cast<int>(_tabs.size())) {
      _active_tab = static_cast<int>(_tabs.size()) - 1;
    }
    load_active_tab();
    if (on_event) on_event("tab_closed", std::to_string(_active_tab));
  }

  void cycle_tab(int delta) {
    if (_tabs.size() <= 1 || delta == 0) return;
    const int n = static_cast<int>(_tabs.size());
    int       next = (_active_tab + delta) % n;
    if (next < 0) next += n;
    switch_to_tab(next);
  }

  int tab_index_at_mouse(Event event) const {
    if (!event.is_mouse()) return -1;
    const auto m = event.mouse();
    if (m.button != Mouse::Left || m.motion != Mouse::Pressed) return -1;
    for (int i = 0; i < static_cast<int>(_tab_boxes.size()); ++i) {
      const auto& box = _tab_boxes[i];
      if (m.x >= box.x_min && m.x <= box.x_max && m.y >= box.y_min && m.y <= box.y_max) {
        return i;
      }
    }
    return -1;
  }

  void switch_to_tab(int index) {
    if (index < 0 || index >= static_cast<int>(_tabs.size())) return;
    if (index == _active_tab) return;
    sync_active_tab_state();
    _active_tab = index;
    load_active_tab();
    if (on_event) on_event("tab_switched", std::to_string(_active_tab));
  }

  void move_to(Filepath& where) {
    int      focused_index_before = 0;
    Filepath focused_path_before;
    const bool same_directory_refresh = _state && (where == dir.path);
    if (same_directory_refresh) {
      if (_state->get_focused_index) { focused_index_before = _state->get_focused_index(); }
      if (_state->get_focused_item) {
        const Filepath* focused = _state->get_focused_item();
        if (focused) focused_path_before = *focused;
      }
    }
    Err err = dir.move_to(where);
    if (!err.ok()) {
      file_operations().report_error("[Panel move_to] " + err.steps.front());
      return;
    }
    _prune_archive_stack(where);
    if (same_directory_refresh) {
      _restore_focus_after_update(focused_path_before, focused_index_before);
    }
    start_watcher(where);
    sync_active_tab_state();
    if (on_event) on_event("dir_changed", where.native());
  }
  Element render() {
    // Panel is always shown
    Element document = vbox({
      render_tabs(),
      _main_document->renderer->Render() | yflex,
    });
    // Overwrite with active dialog
    if (!_overlay_renderer) return document;
    return dbox({
      document,
      _overlay_renderer->Render() | yflex | clear_under_colors | center,
    });
  }
  Filepath focused_dir() {
    // get focused item, if its dir return item's path
    auto focused = _state->get_focused_item();
    if (!focused) return dir.path;
    boost::system::error_code ec;
    const bool                isdir = boost::filesystem::is_directory(*focused, ec);
    if (!ec.failed() && isdir) return *focused;
    // dir.path would be root of the shown dir, but we want to support list of files all from different dirs, for ex. search result.
    return focused->parent_path();
  }

  bool enter_archive(const Filepath& archive_candidate) {
    if (!is_archive_file_path(archive_candidate)) return false;

    Filepath extracted_root;
    Err      err = archive_service().extract_to_cache(archive_candidate, extracted_root);
    if (!err.ok()) {
      file_operations().report_error("[Archive extract] " + err.steps.front());
      return false;
    }

    Filepath archive_file = archive_candidate.lexically_normal();
    boost::system::error_code canonical_ec;
    Filepath canonical_archive = boost::filesystem::canonical(archive_candidate, canonical_ec);
    if (!canonical_ec.failed()) archive_file = canonical_archive;

    _archive_stack.push_back(ArchiveView{
      .archive_file = archive_file,
      .extracted_root = extracted_root.lexically_normal(),
    });

    Filepath where = extracted_root;
    move_to(where);
    if (dir.path.lexically_normal() != extracted_root.lexically_normal()) {
      _archive_stack.pop_back();
      return false;
    }
    return true;
  }

  bool leave_virtual_dir(int64_t& focused_id) {
    if (_archive_stack.empty()) return false;
    const ArchiveView top = _archive_stack.back();
    if (dir.path.lexically_normal() != top.extracted_root.lexically_normal()) return false;

    _archive_stack.pop_back();
    Filepath parent = top.archive_file.parent_path();
    move_to(parent);

    focused_id = dir.offset_vissible(0, 0);
    for (int i = 0; i < static_cast<int>(dir.items.size()); ++i) {
      if (dir.items[i].path_ref() == top.archive_file) {
        focused_id = i;
        break;
      }
    }
    return true;
  }

  void execute_dialog_command(const std::string& dialog_name) {
    _state->action.dialog            = dialog_name;
    _state->action.arguments         = dir.take_selected();
    _state->action.arguments->origin = dir.path;

    if (dir.items.empty()) {
      _state->action.arguments->focused = Filepath();
    } else {
      int focused_index = _state->get_focused_index ? _state->get_focused_index() : 0;
      focused_index = dir.offset_vissible(focused_index, 0);
      _state->action.arguments->focused = dir.items.at(focused_index).path_ref();
    }
    _state->action.show_dialog();
  }

  void set_debug_info(std::function<Element()> info) { _files->debug_info = info; }

  PanelSharedState::P get_shared_state() const { return _state; }

 private:
  Element render_tabs() const {
    _tab_boxes.clear();
    _tab_boxes.resize(_tabs.size());

    Elements tabs;
    tabs.reserve(_tabs.size() * 2 + 1);
    tabs.push_back(text(" Tabs "));
    for (int i = 0; i < static_cast<int>(_tabs.size()); ++i) {
      if (i > 0) tabs.push_back(separatorLight());
      Filepath path = (i == _active_tab) ? dir.path : _tabs[i].dir.path;
      std::string label = path.filename().native();
      if (label.empty()) label = path.native();
      if (label.empty()) label = "/";
      Element cell = text(" " + std::to_string(i + 1) + ":" + label + " ");
      if (i == _active_tab) {
        cell |= bold;
        cell |= inverted;
      } else {
        cell |= dim;
      }
      cell |= reflect(_tab_boxes[i]);
      tabs.push_back(std::move(cell));
    }
    tabs.push_back(filler());
    tabs.push_back(text(" cT:new cW:close f11/f12:switch ") | dim);
    return hbox(std::move(tabs));
  }

  void sync_active_tab_state() {
    if (_tabs.empty() || _active_tab < 0 || _active_tab >= static_cast<int>(_tabs.size())) return;
    TabState& tab = _tabs[_active_tab];
    tab.dir = dir;
    if (_state) {
      tab.filter_txt = _state->filter_txt;
      if (_state->get_focused_index) tab.focused_index = _state->get_focused_index();
      tab.show_permissions_column = _state->show_permissions_column;
      tab.show_owner_group_column = _state->show_owner_group_column;
    }
    tab.archive_stack = _archive_stack;
  }

  void start_watcher(const Filepath& where) {
    if (in_archive_view(where)) {
      pending_changes.erase_if([this](const UpdatedFiles&) -> bool { return true; });
      update_funnel.reset();
      return;
    }
    pending_changes.erase_if([this](const UpdatedFiles&) -> bool { return true; });
    update_funnel = FileChangeFunnel::create(where, [this](UpdatedFiles changes) {
      pending_changes.push(std::move(changes));
      this->run_on_ui([this]() {
        while (true) {
          UpdatedFiles batch;
          FifoError    err = this->pending_changes.try_pop(batch);
          if (FifoError::OK != err) return;
          int      focused_index_before = 0;
          Filepath focused_path_before;
          if (_state) {
            if (_state->get_focused_index) { focused_index_before = _state->get_focused_index(); }
            if (_state->get_focused_item) {
              const Filepath* focused = _state->get_focused_item();
              if (focused) focused_path_before = *focused;
            }
          }
          this->dir.partial_refresh(std::move(batch));
          _restore_focus_after_update(focused_path_before, focused_index_before);
          sync_active_tab_state();
        }
      });
    });
  }

  void load_active_tab() {
    if (_tabs.empty() || _active_tab < 0 || _active_tab >= static_cast<int>(_tabs.size())) return;
    const TabState& tab = _tabs[_active_tab];
    dir = tab.dir;
    _archive_stack = tab.archive_stack;
    _prune_archive_stack(dir.path);
    if (_state) {
      _state->filter_txt = tab.filter_txt.empty() ? dir.filter.phrase : tab.filter_txt;
      dir.apply_filter(_state->filter_txt);
      if (_state->set_focused_index) _state->set_focused_index(tab.focused_index);
      _state->show_permissions_column = tab.show_permissions_column;
      _state->show_owner_group_column = tab.show_owner_group_column;
    }
    if (!dir.path.empty()) {
      start_watcher(dir.path);
    } else {
      update_funnel.reset();
    }
    if (on_event) on_event("dir_changed", dir.path.native());
  }

  void _restore_focus_after_update(const Filepath& focused_path_before, int focused_index_before) {
    if (!_state || this->dir.items.empty() || !_state->set_focused_index) return;
    int restore_index = -1;
    if (!focused_path_before.empty()) {
      for (int i = 0; i < this->dir.items.size(); ++i) {
        if (this->dir.items[i].path_ref() == focused_path_before) {
          restore_index = i;
          break;
        }
      }
      if (restore_index == -1) {
        const std::string focused_name = focused_path_before.filename().native();
        for (int i = 0; i < this->dir.items.size(); ++i) {
          if (this->dir.items[i].filename_ref() == focused_name) {
            restore_index = i;
            break;
          }
        }
      }
    }
    if (restore_index == -1) {
      int max_index = static_cast<int>(this->dir.items.size()) - 1;
      restore_index = std::clamp(focused_index_before, 0, max_index);
    }
    restore_index = this->dir.offset_vissible(restore_index, 0);
    _state->set_focused_index(restore_index);
  }

  bool in_archive_view(const Filepath& path) const {
    if (_archive_stack.empty()) return false;
    return path_is_under(_archive_stack.back().extracted_root, path.lexically_normal());
  }

  void _prune_archive_stack(const Filepath& path) {
    const Filepath normalized = path.lexically_normal();
    while (!_archive_stack.empty() && !path_is_under(_archive_stack.back().extracted_root, normalized)) {
      _archive_stack.pop_back();
    }
  }

  PanelSharedState::P    _state;
  std::shared_ptr<Files> _files;
  std::vector<TabState>  _tabs;
  std::vector<ArchiveView> _archive_stack;
  mutable std::vector<Box> _tab_boxes;
  int                    _active_tab = 0;
};

inline std::string job_type_to_string(JobInstructions::Type type) {
  switch (type) {
  case JobInstructions::Type::COPY: return "COPY";
  case JobInstructions::Type::MOVE: return "MOVE";
  case JobInstructions::Type::DELETE: return "DELETE";
  case JobInstructions::Type::ARCHIVE_CREATE: return "ARCHIVE";
  default: return "?";
  }
}

struct JobProgressBar {
  bool      _has_running_job = false;
  Component cancel_button;
  Component pause_button;

  JobProgressBar() {
    cancel_button = Button(" Cancel ", [] {
      auto jobinfo = file_operations().get_running_job();
      if (jobinfo.job && !jobinfo.job->is_stopped()) {
        file_operations().cancel_job(jobinfo.job.get());
      }
    });
    pause_button = Button(" Pause/Resume ", [] {
      auto jobinfo = file_operations().get_running_job();
      if (jobinfo.job && !jobinfo.job->is_stopped()) {
        file_operations().pause_job(jobinfo.job.get());
      }
    });
  }

  Element render() {
    auto  jobinfo = file_operations().get_running_job();
    auto& job     = jobinfo.job;
    if (!job) return text("[Empty]") | theme().progress_operation;
    std::string task_info = std::format(" [{}] [{}] ", jobinfo.queued_jobs, job_type_to_string(job->_type));
    if (job->is_stopped()) return text(task_info + " [Stopped]") | theme().progress_operation;
    std::lock_guard lock(job->_m);
    const bool      current_index_valid = job->_current_item_index >= 0 && job->_current_item_index < job->_items.size();
    if (!current_index_valid) return text(task_info + " [task index invalid]") | theme().progress_operation;
    const DirItem& item        = job->_items.at(job->_current_item_index);
    const int64_t  items_total = job->item_count();

    auto cancel_el = cancel_button->Render();
    auto pause_el  = pause_button->Render();

    switch (job->_type) {
    case JobInstructions::Type::COPY: {
      if (!item.symlink_ref()) return text(task_info + " [item target missing]") | theme().progress_operation;
      std::string total_info = std::format(" [{:3}] {:5}[{:5}] Mbps {}/{} items ", std::lround(job->_total.percentage), std::lround(job->_total.Mbps), std::lround(job->_total.average_Mbps), job->_current_item_index + 1, items_total);
      std::string curr_info  = std::format(" [{:3}] {:5}Mbps {} ", std::lround(job->_current_item.percentage), std::lround(job->_current_item.Mbps), item.path_ref().native());
      return hbox({
        text(task_info) | theme().progress_operation,
        text("|"),
        bgGaugeLeft(job->_total.percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(total_info)) | theme().progress_total,
        text("|"),
        bgGaugeLeft(job->_current_item.percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(curr_info)) | xflex_grow | theme().progress_current,
        text("|"),
        pause_el,
        cancel_el,
      });
    } break;
    case JobInstructions::Type::MOVE: {
      // just _current_item_index is being updated
      float       item_percentage = std::max(0.0, std::min(100.0, job->_current_item_index * 100.0 / items_total));
      std::string count_info      = std::format(" [{:3}] {}/{} items ", std::lround(item_percentage), std::lround(job->_current_item_index), items_total);
      return hbox({
        text(task_info) | theme().progress_operation,
        text("|"),
        bgGaugeLeft(item_percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(count_info)) | xflex_grow | theme().progress_current,
        text("|"),
        pause_el,
        cancel_el,
      });
    } break;
    case JobInstructions::Type::DELETE: {
      float       byte_percentage = std::max(0.0, std::min(100.0, 100.0 * job->_bytes_processed / job->_bytes_total));
      float       item_percentage = std::max(0.0, std::min(100.0, job->_current_item_index * 100.0 / items_total));
      std::string byte_info       = std::format(" [{:3}] {}/{} bytes ", std::lround(byte_percentage), std::lround(job->_bytes_processed), std::lround(job->_bytes_total));
      std::string count_info      = std::format(" [{:3}] {}/{} items ", std::lround(item_percentage), std::lround(job->_current_item_index), items_total);
      return hbox({
        text(task_info) | theme().progress_operation,
        text("|"),
        bgGaugeLeft(item_percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(byte_info)) | theme().progress_total,
        text("|"),
        bgGaugeLeft(byte_percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(count_info)) | xflex_grow | theme().progress_current,
        text("|"),
        pause_el,
        cancel_el,
      });
    } break;
    case JobInstructions::Type::ARCHIVE_CREATE: {
      float       item_percentage = std::max(0.0, std::min(100.0, items_total > 0 ? job->_current_item_index * 100.0 / items_total : 100.0));
      std::string count_info      = std::format(" [{:3}] indexing {}/{} items ", std::lround(item_percentage), std::lround(job->_current_item_index), items_total);
      return hbox({
        text(task_info) | theme().progress_operation,
        text("|"),
        bgGaugeLeft(item_percentage / 100, theme().size_gauge_full, theme().size_gauge_empty, text(count_info)) | xflex_grow | theme().progress_current,
        text("|"),
        pause_el,
        cancel_el,
      });
    } break;
    }
    return text(task_info) | theme().progress_operation;
  }
};

class FileCommander : public DialogOverlay {
 protected:
  Panel              left, right;
  JobProgressBar     progress_bar;
  std::deque<double> clear_errors_sequence;
  std::vector<Filepath> _bookmarks;
  bool _last_main_focus_left = true;
  bool _single_panel_mode = false;
  int  _main_panels_mode  = 0;  // 0=split, 1=single
  EditorManager _editor_manager;
  RunWithRestoredIO _run_with_restored_io;

  std::function<void()> _close_dialog;
  std::function<int()>  _get_dimx;

 public:
  int       _left_size   = 20;
  int       _screen_dimx = 0;
  Component renderer;

  Panel& get_left() { return left; }
  Panel& get_right() { return right; }
  bool single_panel_mode() const { return _single_panel_mode; }
  Panel& focused_panel() {
    if (_single_panel_mode) {
      return _last_main_focus_left ? left : right;
    }
    if (left.navigation->Focused()) {
      _last_main_focus_left = true;
      return left;
    }
    if (right.navigation->Focused()) {
      _last_main_focus_left = false;
      return right;
    }
    return _last_main_focus_left ? left : right;
  }

  std::vector<Filepath> focused_selection_for_editor() {
    Panel& panel = focused_panel();
    auto   args  = panel.dir.take_selected();
    std::vector<Filepath> selected = args ? args->selected : std::vector<Filepath>();
    if (selected.empty()) {
      Filepath focused;
      auto*    focused_ptr = panel.get_shared_state()->get_focused_item();
      if (focused_ptr) focused = *focused_ptr;
      if (!focused.empty()) selected.push_back(focused);
    }
    return selected;
  }

  bool open_in_editor(std::string& error) {
    Panel& panel = focused_panel();
    auto   selected = focused_selection_for_editor();
    if (selected.empty()) {
      error = "No focused item to open in editor";
      return false;
    }

    auto is_directory = [](const Filepath& p) -> bool {
      boost::system::error_code ec;
      const bool isdir = boost::filesystem::is_directory(p, ec);
      return !ec.failed() && isdir;
    };

    if (selected.size() == 1 && is_directory(selected.front())) {
      return _editor_manager.open_directory_new_session(selected.front(), error);
    }

    std::vector<Filepath> files;
    files.reserve(selected.size());
    for (const auto& p : selected) {
      if (!is_directory(p)) files.push_back(p);
    }
    if (!files.empty()) return _editor_manager.open_files_in_last_session(files, error);

    return _editor_manager.open_directory_new_session(panel.focused_dir(), error);
  }

  std::vector<Command> list_palette_commands() { return commands().list_all(); }

  std::vector<ThemeColorEntry> list_theme_colors() const {
    std::vector<ThemeColorEntry> out;
    const auto defs = theme().editable_colors();
    out.reserve(defs.size());
    for (const auto& [id, label] : defs) {
      out.push_back({id, label, theme().color_token(id)});
    }
    return out;
  }

  bool set_theme_color(const std::string& id, const std::string& token, std::string& error) {
    return theme().set_color_token(id, token, &error);
  }

  void reset_theme_colors() { theme().reset_color_defaults(); }

  bool rebind_palette_command(const std::string& id, const Event& key, std::string& error) {
    const std::string token = event_to_token(key);
    if (token.empty()) {
      error = "Unsupported key for binding";
      return false;
    }

    auto available = commands().list_all();
    for (const auto& c : available) {
      if (c.id != id && c.key == key) {
        error = "Key is already bound to '" + c.description + "'";
        return false;
      }
    }

    Event* theme_key = theme_key_for_command(id);
    if (!theme_key) {
      error = "Unknown command id: " + id;
      return false;
    }
    *theme_key = key;
    if (!commands().set_key(id, key)) {
      error = "Failed to update command binding";
      return false;
    }
    return true;
  }

  void load_settings(bool restore_paths) {
    load_theme_colors();

    std::ifstream in(settings_file_path());
    if (!in.good()) return;
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string json = ss.str();
    if (json.empty()) return;

    std::string left_path_txt;
    std::string right_path_txt;
    if (restore_paths && fc_settings_detail::extract_json_string_field(json, "left_path", left_path_txt)) {
      Filepath p(left_path_txt);
      boost::system::error_code ec;
      if (boost::filesystem::is_directory(p, ec) && !ec.failed()) left.move_to(p);
    }
    if (restore_paths && fc_settings_detail::extract_json_string_field(json, "right_path", right_path_txt)) {
      Filepath p(right_path_txt);
      boost::system::error_code ec;
      if (boost::filesystem::is_directory(p, ec) && !ec.failed()) right.move_to(p);
    }

    std::string left_sort_txt;
    if (fc_settings_detail::extract_json_string_field(json, "left_sort", left_sort_txt)) {
      if (Orderby parsed; parse_sort_order(left_sort_txt, parsed)) {
        left.dir.order_by = parsed;
        left.dir._sort();
        left.dir._calculate();
      }
    }
    std::string right_sort_txt;
    if (fc_settings_detail::extract_json_string_field(json, "right_sort", right_sort_txt)) {
      if (Orderby parsed; parse_sort_order(right_sort_txt, parsed)) {
        right.dir.order_by = parsed;
        right.dir._sort();
        right.dir._calculate();
      }
    }

    bool left_show_perm = false;
    if (fc_settings_detail::extract_json_bool_field(json, "left_show_permissions", left_show_perm)) {
      left.get_shared_state()->show_permissions_column = left_show_perm;
    }
    bool right_show_perm = false;
    if (fc_settings_detail::extract_json_bool_field(json, "right_show_permissions", right_show_perm)) {
      right.get_shared_state()->show_permissions_column = right_show_perm;
    }
    bool left_show_owner_group = false;
    if (fc_settings_detail::extract_json_bool_field(json, "left_show_owner_group", left_show_owner_group)) {
      left.get_shared_state()->show_owner_group_column = left_show_owner_group;
    }
    bool right_show_owner_group = false;
    if (fc_settings_detail::extract_json_bool_field(json, "right_show_owner_group", right_show_owner_group)) {
      right.get_shared_state()->show_owner_group_column = right_show_owner_group;
    }

    bool single_mode = false;
    if (fc_settings_detail::extract_json_bool_field(json, "single_panel_mode", single_mode)) {
      set_single_panel_mode(single_mode);
    }
    std::string focused_side;
    if (fc_settings_detail::extract_json_string_field(json, "focused_panel", focused_side)) {
      if (focused_side == "left") {
        _last_main_focus_left = true;
        left.navigation->TakeFocus();
      } else if (focused_side == "right") {
        _last_main_focus_left = false;
        right.navigation->TakeFocus();
      }
    }

    std::string bookmarks_array_json;
    if (fc_settings_detail::extract_json_array(json, "bookmarks", bookmarks_array_json)) {
      _bookmarks.clear();
      for (const auto& p : fc_settings_detail::parse_string_array(bookmarks_array_json)) {
        if (p.empty()) continue;
        Filepath fp(p);
        boost::system::error_code ec;
        if (boost::filesystem::exists(fp, ec) && !ec.failed()) add_bookmark(fp);
      }
    }

    std::string use_count_obj;
    if (fc_settings_detail::extract_json_object(json, "command_use_count", use_count_obj)) {
      const auto counts = fc_settings_detail::parse_int_map_object(use_count_obj);
      for (const auto& [id, count] : counts) {
        commands().set_use_count(id, count);
      }
    }

    std::string key_bindings_obj;
    if (fc_settings_detail::extract_json_object(json, "key_bindings", key_bindings_obj)) {
      const auto bindings = fc_settings_detail::parse_string_map_object(key_bindings_obj);
      for (const auto& [id, token] : bindings) {
        Event       e = event_from_string(token);
        std::string err;
        if (e == Event::Custom) continue;
        rebind_palette_command(id, e, err);
      }
    }

    std::string fresh_binary_path;
    if (fc_settings_detail::extract_json_string_field(json, "fresh_binary_path", fresh_binary_path)) {
      _editor_manager.set_binary_override(fresh_binary_path);
    }
    std::string last_editor_session_id;
    if (fc_settings_detail::extract_json_string_field(json, "last_editor_session_id", last_editor_session_id)) {
      _editor_manager.set_last_session_id(last_editor_session_id);
    }
  }

  void save_settings() const {
    save_theme_colors();

    const std::string settings = settings_file_path();
    if (settings.empty()) return;

    const Filepath settings_path(settings);
    const Filepath settings_dir = settings_path.parent_path();
    boost::system::error_code mk_ec;
    boost::filesystem::create_directories(settings_dir, mk_ec);

    std::ofstream out(settings, std::ios::trunc);
    if (!out.good()) return;

    auto write_quoted = [&out](const std::string& value) {
      out << "\"" << fc_settings_detail::json_escape(value) << "\"";
    };

    out << "{\n";
    out << "  \"version\": 1,\n";
    out << "  \"left_path\": ";
    write_quoted(left.dir.path.native());
    out << ",\n";
    out << "  \"right_path\": ";
    write_quoted(right.dir.path.native());
    out << ",\n";
    out << "  \"left_sort\": ";
    write_quoted(sort_order_to_string(left.dir.order_by));
    out << ",\n";
    out << "  \"right_sort\": ";
    write_quoted(sort_order_to_string(right.dir.order_by));
    out << ",\n";
    out << "  \"left_show_permissions\": " << (left.get_shared_state()->show_permissions_column ? "true" : "false") << ",\n";
    out << "  \"right_show_permissions\": " << (right.get_shared_state()->show_permissions_column ? "true" : "false") << ",\n";
    out << "  \"left_show_owner_group\": " << (left.get_shared_state()->show_owner_group_column ? "true" : "false") << ",\n";
    out << "  \"right_show_owner_group\": " << (right.get_shared_state()->show_owner_group_column ? "true" : "false") << ",\n";
    out << "  \"single_panel_mode\": " << (_single_panel_mode ? "true" : "false") << ",\n";
    out << "  \"focused_panel\": ";
    write_quoted(_last_main_focus_left ? "left" : "right");
    out << ",\n";

    out << "  \"bookmarks\": [";
    for (size_t i = 0; i < _bookmarks.size(); ++i) {
      if (i > 0) out << ", ";
      write_quoted(_bookmarks[i].native());
    }
    out << "],\n";

    const auto all_commands = commands().list_all();
    out << "  \"command_use_count\": {\n";
    for (size_t i = 0; i < all_commands.size(); ++i) {
      out << "    ";
      write_quoted(all_commands[i].id);
      out << ": " << std::max(0, all_commands[i].use_count);
      out << (i + 1 < all_commands.size() ? ",\n" : "\n");
    }
    out << "  },\n";

    out << "  \"key_bindings\": {\n";
    for (size_t i = 0; i < all_commands.size(); ++i) {
      out << "    ";
      write_quoted(all_commands[i].id);
      out << ": ";
      write_quoted(event_to_token(all_commands[i].key));
      out << (i + 1 < all_commands.size() ? ",\n" : "\n");
    }
    out << "  },\n";

    out << "  \"fresh_binary_path\": ";
    write_quoted(_editor_manager.binary_override());
    out << ",\n";
    out << "  \"last_editor_session_id\": ";
    write_quoted(_editor_manager.last_session_id());
    out << "\n";
    out << "}\n";
  }

  std::vector<Filepath> list_bookmarks() const {
    return _bookmarks;
  }

  void add_bookmark(const Filepath& path) {
    Filepath normalized = path.lexically_normal();
    auto it = std::find(_bookmarks.begin(), _bookmarks.end(), normalized);
    if (it == _bookmarks.end()) {
      _bookmarks.push_back(normalized);
      std::sort(_bookmarks.begin(), _bookmarks.end(), [](const Filepath& a, const Filepath& b) { return a.native() < b.native(); });
    }
  }

  void remove_bookmark(const Filepath& path) {
    Filepath normalized = path.lexically_normal();
    _bookmarks.erase(std::remove(_bookmarks.begin(), _bookmarks.end(), normalized), _bookmarks.end());
  }

  void open_bookmark(const Filepath& path) {
    Panel& panel = focused_panel();
    auto   where = path;
    panel.move_to(where);
  }

  void add_current_focused_dir_bookmark() {
    add_bookmark(focused_panel().dir.path);
  }

  void set_single_panel_mode(bool enabled) {
    if (enabled && !_single_panel_mode) {
      if (left.navigation->Focused()) _last_main_focus_left = true;
      else if (right.navigation->Focused()) _last_main_focus_left = false;
    }
    _single_panel_mode = enabled;
    _main_panels_mode  = _single_panel_mode ? 1 : 0;
    if (!_single_panel_mode) {
      if (_last_main_focus_left) left.navigation->TakeFocus();
      else right.navigation->TakeFocus();
    }
  }

  void execute_palette_command(const std::string& id) {
    Command* command = commands().find_by_id(id);
    if (!command) return;
    command->use_count++;

    // If palette triggered this action, close it first.
    if (_active_dialog_name == "CommandPalette") { close_dialog(); }

    if (command->scope == CommandScope::PANEL) {
      if (command->kind == CommandKind::SHOW_DIALOG) {
        focused_panel().execute_dialog_command(command->dialog);
      } else if (command->kind == CommandKind::EXECUTE_CALLBACK) {
        focused_panel().navigation->OnEvent(command->key);
      }
      return;
    }

    if (command->scope == CommandScope::GLOBAL && command->kind == CommandKind::SHOW_DIALOG) {
      show_dialog(command->dialog);
      return;
    }

    if (id == "switch_panel") {
      Panel& current = focused_panel();
      if (&current == &left) {
        right.navigation->TakeFocus();
        _last_main_focus_left = false;
      } else {
        left.navigation->TakeFocus();
        _last_main_focus_left = true;
      }
      return;
    }
    if (id == "tab_new") {
      focused_panel().new_tab();
      return;
    }
    if (id == "tab_close") {
      focused_panel().close_tab();
      return;
    }
    if (id == "tab_next") {
      focused_panel().cycle_tab(+1);
      return;
    }
    if (id == "tab_prev") {
      focused_panel().cycle_tab(-1);
      return;
    }
    if (id == "refresh_dir") {
      Panel& panel = focused_panel();
      auto   where = panel.dir.path;
      panel.move_to(where);
      return;
    }
    if (id == "toggle_single_panel_mode") {
      set_single_panel_mode(!_single_panel_mode);
      return;
    }
    if (id == "target_right") {
      Filepath where = focused_panel().focused_dir();
      right.move_to(where);
      return;
    }
    if (id == "target_left") {
      Filepath where = focused_panel().focused_dir();
      left.move_to(where);
      return;
    }
    if (id == "open_in_editor") {
      std::string error;
      if (!open_in_editor(error) && !error.empty()) {
        file_operations().report_error(error);
      }
      return;
    }
    if (id == "switch_to_file_commander") {
      // File Commander is already active when this handler runs.
      return;
    }
    if (id == "switch_editor_prev") {
      std::string error;
      if (!_editor_manager.switch_prev(error) && !error.empty()) {
        file_operations().report_error(error);
      }
      return;
    }
    if (id == "switch_editor_next") {
      std::string error;
      if (!_editor_manager.switch_next(error) && !error.empty()) {
        file_operations().report_error(error);
      }
      return;
    }
  }

  FileCommander(Filepath l, Filepath r, ExecuteOnUiThread exec, std::function<int()> dimx, RunWithRestoredIO run_with_restored_io = {})
      : left(l, get_target(), exec), right(r, get_target(), exec), _get_dimx(dimx), _run_with_restored_io(std::move(run_with_restored_io)) {
    _close_dialog         = [this]() { close_dialog(); };
    _editor_manager.set_run_foreground([this](const std::function<int()>& run) -> int {
      if (_run_with_restored_io) return _run_with_restored_io(run);
      return run();
    });
    _editor_manager.set_status_sink([this](const std::string& text) {
      if (!text.empty()) file_operations().report_error(text);
    });
    auto global_shortcuts = [this](Event event) -> bool { return this->handle_global_shortcuts(event); };
    // Overlay dialogs on top of main document:
    // + errors - fullscreen
    // - commands - top, expands as needed
    // - tasks - fullscreen

    left.set_debug_info([]() -> Element { return screen_render_time(); });

    navigation = Container::Tab({}, &_active_dialog);

    // NOTE: When ResizableSplitRight, which is a Component, is used it expects components having .Render() as children.
    //       So we need to combine navigation with its render, like so:
    Component            left_combined  = Renderer(left.navigation, [this]() -> Element { return left.render(); });
    Component            right_combined = Renderer(right.navigation, [this]() -> Element { return right.render(); });
    ResizableSplitOption split;
    split.back            = left_combined;
    split.main            = right_combined;
    split.main_size       = &(this->_left_size);
    split.direction       = ftxui::Direction::Right;
    split.separator_func  = [this]() -> Element { return ::ftxui::separatorDouble(); };
    Component both_panels = ResizableSplit(split);
    Component single_panel = CatchEvent(Renderer([this]() -> Element {
      Panel& focused = focused_panel();
      Panel& hidden  = (&focused == &left) ? right : left;
      const std::string hidden_label = (&focused == &left) ? "Right" : "Left";
      return vbox({
        text(" Hidden " + hidden_label + ": " + hidden.dir.path.native() + " ") | dim,
        separatorDouble(),
        focused.render() | yflex,
      });
    }),
                                        [this](Event event) -> bool {
                                          if (this->handle_global_shortcuts(event)) return true;
                                          return this->focused_panel().navigation->OnEvent(event);
                                        });
    Component main_panels = Container::Tab({both_panels, single_panel}, &_main_panels_mode);

    // Pause/Cancel buttons are focusable only when a job is running
    auto maybe_pause  = Maybe(progress_bar.pause_button, &progress_bar._has_running_job);
    auto maybe_cancel = Maybe(progress_bar.cancel_button, &progress_bar._has_running_job);
    auto panels_with_cancel = CatchEvent(Container::Vertical({main_panels, maybe_pause, maybe_cancel}), global_shortcuts);

    navigation->Add(panels_with_cancel);
    _overlay_dialogs["ErrorList"] = std::make_shared<ErrorListDialog>(_close_dialog);
    _overlay_dialogs["JobList"]   = std::make_shared<JobListDialog>(_close_dialog);
    _overlay_dialogs["Bookmarks"] = std::make_shared<BookmarksDialog>(
      _close_dialog,
      [this]() { return this->list_bookmarks(); },
      [this]() { this->add_current_focused_dir_bookmark(); },
      [this](const Filepath& path) { this->remove_bookmark(path); },
      [this](const Filepath& path) { this->open_bookmark(path); }
    );
    _overlay_dialogs["ThemeColors"] = std::make_shared<ThemeColorsDialog>(
      _close_dialog,
      [this]() { return this->list_theme_colors(); },
      []() { return theme().available_color_tokens(); },
      [this](const std::string& id, const std::string& token, std::string& error) { return this->set_theme_color(id, token, error); },
      [this]() { this->reset_theme_colors(); },
      [this]() { this->save_theme_colors(); }
    );
    _overlay_dialogs["CommandPalette"] = std::make_shared<CommandPaletteDialog>(
      _close_dialog,
      [this]() { return this->list_palette_commands(); },
      [this](const std::string& id) { this->execute_palette_command(id); },
      [this](const std::string& id, const Event& key, std::string& error) { return this->rebind_palette_command(id, key, error); }
    );
    renderer = Renderer(navigation, [=, this]() -> Element {
      // check for resize:
      int screen_w = _get_dimx();
      if (screen_w != _screen_dimx) {
        _screen_dimx = screen_w;
        _left_size   = screen_w / 2;
      }

      Elements el;
      auto     jobinfo = file_operations().get_running_job();
      el.push_back(main_panels->Render() | yflex | bgcolor(theme().default_bg) | color(theme().default_fg));
      // Progress bar if there is a job running
      if (jobinfo.job && false == jobinfo.job->is_stopped()) { el.push_back(progress_bar.render()); }
      // Quick preview of latest errors
      auto errors = file_operations().get_errors(theme().max_errors_to_show);
      for (auto& x : errors) { el.push_back(text(" 咎 " + x.message) | theme().recent_error); }
      Element document = vbox(std::move(el));
      if (!_overlay_renderer) return document;
      return dbox({document, _overlay_renderer->Render() | yflex | clear_under_colors | hcenter});
    });
  }
  // returns
  TargetFunc get_target() {
    return [this](Panel* self) -> Filepath {
      // self is origin pannel, return target panel's path
      if (self == &left) return right.dir.path;
      if (self == &right) return left.dir.path;
      l.e("FileCommander::get_target", "unknown self");
      return left.dir.path;
    };
  }

 private:
  static std::string sort_order_to_string(Orderby o) {
    switch (o) {
    case Orderby::NAME_ASC: return "NAME_ASC";
    case Orderby::NAME_DESC: return "NAME_DESC";
    case Orderby::SIZE_ASC: return "SIZE_ASC";
    case Orderby::SIZE_DESC: return "SIZE_DESC";
    case Orderby::TIME_ASC: return "TIME_ASC";
    case Orderby::TIME_DESC: return "TIME_DESC";
    }
    return "NAME_ASC";
  }

  static bool parse_sort_order(const std::string& txt, Orderby& out) {
    if (txt == "NAME_ASC") {
      out = Orderby::NAME_ASC;
      return true;
    }
    if (txt == "NAME_DESC") {
      out = Orderby::NAME_DESC;
      return true;
    }
    if (txt == "SIZE_ASC") {
      out = Orderby::SIZE_ASC;
      return true;
    }
    if (txt == "SIZE_DESC") {
      out = Orderby::SIZE_DESC;
      return true;
    }
    if (txt == "TIME_ASC") {
      out = Orderby::TIME_ASC;
      return true;
    }
    if (txt == "TIME_DESC") {
      out = Orderby::TIME_DESC;
      return true;
    }
    return false;
  }

  static std::string settings_file_path() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg) {
      return (Filepath(xdg) / "file_commander" / "settings.json").native();
    }
    const char* home = std::getenv("HOME");
    if (!home || !*home) return "";
    return (Filepath(home) / ".config" / "file_commander" / "settings.json").native();
  }

  static std::string theme_colors_file_path() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg) {
      return (Filepath(xdg) / "file_commander" / "theme_colors.json").native();
    }
    const char* home = std::getenv("HOME");
    if (!home || !*home) return "";
    return (Filepath(home) / ".config" / "file_commander" / "theme_colors.json").native();
  }

  static void save_theme_colors() {
    const std::string settings = theme_colors_file_path();
    if (settings.empty()) return;

    const Filepath settings_path(settings);
    const Filepath settings_dir = settings_path.parent_path();
    boost::system::error_code mk_ec;
    boost::filesystem::create_directories(settings_dir, mk_ec);

    std::ofstream out(settings, std::ios::trunc);
    if (!out.good()) return;

    auto write_quoted = [&out](const std::string& value) {
      out << "\"" << fc_settings_detail::json_escape(value) << "\"";
    };

    const auto colors = theme().export_color_tokens();
    out << "{\n";
    out << "  \"version\": 1,\n";
    out << "  \"colors\": {\n";
    size_t i = 0;
    for (const auto& [id, token] : colors) {
      out << "    ";
      write_quoted(id);
      out << ": ";
      write_quoted(token);
      out << (i + 1 < colors.size() ? ",\n" : "\n");
      i++;
    }
    out << "  }\n";
    out << "}\n";
  }

  static void load_theme_colors() {
    theme().reset_color_defaults();

    std::ifstream in(theme_colors_file_path());
    if (!in.good()) return;
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string json = ss.str();
    if (json.empty()) return;

    std::string colors_obj;
    if (!fc_settings_detail::extract_json_object(json, "colors", colors_obj)) return;
    theme().import_color_tokens(fc_settings_detail::parse_string_map_object(colors_obj));
  }

  static Event* theme_key_for_command(const std::string& id) {
    Theme& t = theme();
    if (id == "select_toggle") return &t.key_files_select;
    if (id == "clear_selection") return &t.key_clear_selection;
    if (id == "select_all") return &t.key_select_all;
    if (id == "enter_dir") return &t.key_enter_dir;
    if (id == "leave_dir") return &t.key_leave_dir;
    if (id == "toggle_permissions_column") return &t.key_toggle_permissions_column;
    if (id == "toggle_owner_group_column") return &t.key_toggle_owner_group_column;
    if (id == "copy") return &t.key_copy;
    if (id == "move") return &t.key_move;
    if (id == "delete") return &t.key_delete;
    if (id == "rename") return &t.key_rename;
    if (id == "mkdir") return &t.key_mkdir;
    if (id == "find") return &t.key_find;
    if (id == "glob_select") return &t.key_glob_select;
    if (id == "glob_deselect") return &t.key_glob_deselect;
    if (id == "names_to_clipboard") return &t.key_names_to_clipboard;
    if (id == "paths_to_clipboard") return &t.key_paths_to_clipboard;
    if (id == "switch_panel") return &t.key_switch_focused_panel;
    if (id == "tab_new") return &t.key_new_tab;
    if (id == "tab_close") return &t.key_close_tab;
    if (id == "tab_next") return &t.key_next_tab;
    if (id == "tab_prev") return &t.key_prev_tab;
    if (id == "toggle_single_panel_mode") return &t.key_toggle_single_panel_mode;
    if (id == "refresh_dir") return &t.key_refresh_dir;
    if (id == "target_right") return &t.key_target_dir_to_focused_item_right;
    if (id == "target_left") return &t.key_target_dir_to_focused_item_left;
    if (id == "toggle_errors") return &t.key_toggle_error_details;
    if (id == "toggle_job_list") return &t.key_toggle_job_list;
    if (id == "open_bookmarks") return &t.key_bookmarks_dialog;
    if (id == "edit_theme_colors") return &t.key_theme_colors;
    if (id == "open_in_editor") return &t.key_open_in_editor;
    if (id == "switch_to_file_commander") return &t.key_switch_to_file_commander;
    if (id == "switch_editor_prev") return &t.key_switch_editor_prev;
    if (id == "switch_editor_next") return &t.key_switch_editor_next;
    return nullptr;
  }

 public:

  bool handle_global_shortcuts(Event event) {
    // Update progress bar visibility on Custom events
    // (worker thread posts Event::Custom on job progress/completion)
    if (event == Event::Custom) {
      auto jobinfo = file_operations().get_running_job();
      progress_bar._has_running_job = jobinfo.job && !jobinfo.job->is_stopped();
      return false;  // don't consume — Custom events also trigger re-render
    }

    if (!dialog_active() && event.is_mouse()) {
      auto click_in_panel_tabs = [&](Panel& panel, bool left_side) -> bool {
        const int idx = panel.tab_index_at_mouse(event);
        if (idx < 0) return false;
        panel.switch_to_tab(idx);
        panel.navigation->TakeFocus();
        _last_main_focus_left = left_side;
        return true;
      };

      if (_single_panel_mode) {
        Panel& shown = _last_main_focus_left ? left : right;
        if (click_in_panel_tabs(shown, _last_main_focus_left)) return true;
      } else {
        if (click_in_panel_tabs(left, true)) return true;
        if (click_in_panel_tabs(right, false)) return true;
      }
    }

    if (event == theme().key_command_palette) {
      if (!dialog_active() || _active_dialog_name == "CommandPalette") {
        show_dialog("CommandPalette");
        return true;
      }
      return false;
    }
    if (event == theme().key_theme_colors && !dialog_active()) {
      show_dialog("ThemeColors");
      return true;
    }
    if (!dialog_active() && event == theme().key_open_in_editor) {
      std::string error;
      if (!open_in_editor(error) && !error.empty()) {
        file_operations().report_error(error);
      }
      return true;
    }
    if (!dialog_active() && event == theme().key_switch_editor_prev) {
      std::string error;
      if (!_editor_manager.switch_prev(error) && !error.empty()) {
        file_operations().report_error(error);
      }
      return true;
    }
    if (!dialog_active() && event == theme().key_switch_editor_next) {
      std::string error;
      if (!_editor_manager.switch_next(error) && !error.empty()) {
        file_operations().report_error(error);
      }
      return true;
    }
    if (!dialog_active() && event == theme().key_switch_to_file_commander) {
      // File Commander is already active.
      return true;
    }
    if (event == theme().key_toggle_single_panel_mode && !dialog_active()) {
      set_single_panel_mode(!_single_panel_mode);
      return true;
    }

    if (event == theme().key_toggle_error_details && !dialog_active()) {
      show_dialog("ErrorList");
      return true;
    }
    if (event == theme().key_toggle_job_list && !dialog_active()) {
      show_dialog("JobList");
      return true;
    }
    if (event == theme().key_bookmarks_dialog && !dialog_active()) {
      show_dialog("Bookmarks");
      return true;
    }

    if (event == theme().key_clear_errors) {
      clear_errors_sequence.emplace_front(now());
      while (clear_errors_sequence.size() > theme().clear_errors_command_repeat_count) { clear_errors_sequence.pop_back(); }
      const double sequence_interval = clear_errors_sequence.front() - clear_errors_sequence.back();
      const bool   full_sequence     = clear_errors_sequence.size() >= theme().clear_errors_command_repeat_count;
      const bool   in_time_window    = sequence_interval < theme().clear_errors_command_sequence;
      if (full_sequence && in_time_window) {
        auto seq = clear_errors_sequence;
        file_operations().clear_errors();
        clear_errors_sequence.clear();
        return true;
      }
      // we let this event through when it's not a full sequence or it's not in time window
    } else {
      clear_errors_sequence.clear();
    }

    // Tab between panels
    if (event == theme().key_switch_focused_panel) {
      Panel& current = focused_panel();
      if (&current == &left) {
        right.navigation->TakeFocus();
        _last_main_focus_left = false;
      } else {
        left.navigation->TakeFocus();
        _last_main_focus_left = true;
      }
      return true;
    }
    if (!dialog_active() && event == theme().key_new_tab) {
      focused_panel().new_tab();
      return true;
    }
    if (!dialog_active() && event == theme().key_close_tab) {
      focused_panel().close_tab();
      return true;
    }
    if (!dialog_active() && event == theme().key_next_tab) {
      focused_panel().cycle_tab(+1);
      return true;
    }
    if (!dialog_active() && event == theme().key_prev_tab) {
      focused_panel().cycle_tab(-1);
      return true;
    }
    if (event == theme().key_refresh_dir) {
      Panel& panel = focused_panel();
      auto where = panel.dir.path;
      panel.move_to(where);
      return true;
    }
    // Move target to selected dir.
    // Do not apply if dialog is active on the source panel. When rename is open we want ctrl+right/left to move cursor by entire word.
    Panel& source = focused_panel();
    const bool change_right = event == theme().key_target_dir_to_focused_item_right && (&source == &left);
    const bool change_left  = event == theme().key_target_dir_to_focused_item_left && (&source == &right);
    if (change_right) {
      const bool dialog_active = source._active_dialog > 0;
      if (dialog_active) return false;
      Filepath where = source.focused_dir();
      right.move_to(where);
      return true;
    } else if (change_left) {
      const bool dialog_active = source._active_dialog > 0;
      if (dialog_active) return false;
      Filepath where = source.focused_dir();
      left.move_to(where);
      return true;
    }
    return false;
  }
};

#endif  // FC_APP_HPP_
