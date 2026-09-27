#include "traversal.hpp"

#include "dialogs.hpp"
#include "dialog_support.hpp"
#include "archive.hpp"
#include "bfs.hpp"
#include "commander.hpp"
#include "file_io_jobs.hpp"
#include "custom_controls.hpp"
#include "log.hpp"
#include "shared_state.hpp"
#include "theme.hpp"

#include <boost/filesystem/file_status.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/system/detail/error_code.hpp>

#include <cstdint>
#include <ftxui/component/component.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color_info.hpp>

#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <deque>
#include <format>
#include <mutex>
#include <memory>
#include <string>
#include <thread>

using boost::filesystem::directory_entry;
using boost::filesystem::directory_iterator;
using boost::filesystem::file_status;
using boost::system::error_code;

using Perun::file_operations;
using Perun::CopyConflictMode;
using Perun::JobInstructions;
using Perun::JobSpec;
using Perun::JobState;
using Perun::JobSnapshot;
using Perun::Operation;
using Perun::OperationPlan;
using Perun::OperationType;
using Perun::selection_plan;

std::string time_to_string(double time);

namespace ftxui {
namespace {std::atomic<uint64_t> g_find_sequence{1};}

namespace {

bool wildcard_match_casefold(const std::string& pattern, const std::string& value) {
  auto fold = [](char c) { return static_cast<char>(std::tolower(static_cast<unsigned char>(c))); };
  size_t p = 0, v = 0;
  size_t star = std::string::npos;
  size_t match = 0;
  while (v < value.size()) {
    if (p < pattern.size() && (pattern[p] == '?' || fold(pattern[p]) == fold(value[v]))) {
      ++p;
      ++v;
      continue;
    }
    if (p < pattern.size() && pattern[p] == '*') {
      star = p++;
      match = v;
      continue;
    }
    if (star != std::string::npos) {
      p = star + 1;
      v = ++match;
      continue;
    }
    return false;
  }
  while (p < pattern.size() && pattern[p] == '*') ++p;
  return p == pattern.size();
}

}  // namespace

//
// FindDialog
//

FindDialog::FindDialog(PanelSharedState::P s) : Dialog(std::move(s)) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();

  InputOption root_opt;
  root_opt.multiline       = false;
  root_opt.cursor_position = &root_cursor_pos;

  InputOption pattern_opt;
  pattern_opt.multiline       = false;
  pattern_opt.cursor_position = &pattern_cursor_pos;
  pattern_opt.on_enter        = [this]() { start_search(); };

  input_root    = Input(&root_path, "Search path", root_opt) | showInputCursor(&root_cursor_pos);
  input_pattern = Input(&pattern, "Pattern (*, ?)", pattern_opt) | showInputCursor(&pattern_cursor_pos);
  button_find   = Button(" Find ", [this] { start_search(); }, ascii_button);
  button_open   = Button(" Open ", [this] { open_selected(); }, ascii_button);
  button_close  = Button(" Close ", [this] { cancel(); }, ascii_button);

  _data_source.dataset_size = [this]() -> DataSize {
    std::lock_guard lock(_results_mutex);
    int64_t         total = static_cast<int64_t>(_results.size());
    return {total, 0, std::max(int64_t{0}, total - 1)};
  };
  _data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    std::lock_guard lock(_results_mutex);
    const int64_t   old = id;
    const int64_t   max = std::max(int64_t{0}, static_cast<int64_t>(_results.size()) - 1);
    id = std::clamp(id + delta, int64_t{0}, max);
    return id != old;
  };
  _data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _data_source.on_event = [this](DSEventContext c) -> bool {
    if (c.event == Event::Return) {
      open_selected();
      return true;
    }
    return c.handled;
  };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    std::lock_guard lock(_results_mutex);
    if (c.id < 0 || c.id >= static_cast<int64_t>(_results.size())) return text("<invalid>");
    Element row = text(" " + _results.at(c.id).native());
    if (c.focused) {
      row |= c.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _data_source.min_y = 12;
  results_menu       = clipped_menu(&_data_source);

  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_find, button_open, button_close}),
                            input_root,
                            input_pattern,
                            results_menu,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element {
    const std::string title_txt = _running.load(std::memory_order_relaxed)
      ? " Find (running) "
      : " Find ";
    auto title = text(title_txt) | bold | hcenter;
    int64_t matches = 0;
    {
      std::lock_guard lock(_results_mutex);
      matches = static_cast<int64_t>(_results.size());
    }
    std::string info = std::format(" Dirs:{}  Files:{}  Matches:{}  Errors:{} ",
      _dirs_scanned.load(std::memory_order_relaxed),
      _files_scanned.load(std::memory_order_relaxed),
      matches,
      _errors.load(std::memory_order_relaxed));
    if (_truncated.load()) info += " | Search limit reached (100,000 entries / 1,024 levels)";
    if (!status.empty()) info += " | " + status;
    auto content = vbox({
      hbox({
        button_find->Render() | hcenter | xflex_grow,
        separator(),
        button_open->Render() | hcenter | xflex_grow,
        separator(),
        button_close->Render() | hcenter | xflex_grow,
      }),
      separator(),
      hbox({text("Root: "), input_root->Render() | xflex}),
      hbox({text("Mask: "), input_pattern->Render() | xflex}),
      separator(),
      text(info) | dim,
      separator(),
      results_menu->Render() | yflex,
    });
    return window(title, content, BorderStyle::DOUBLE);
  });
}

FindDialog::~FindDialog() {
  stop_search();
}

void FindDialog::OnShow() {
  stop_search();
  root_path = app->dir ? app->dir->path.native() : "";
  pattern.clear();
  status.clear();
  {
    std::lock_guard lock(_results_mutex);
    _results.clear();
  }
  _dirs_scanned.store(0, std::memory_order_relaxed);
  _files_scanned.store(0, std::memory_order_relaxed);
  _errors.store(0, std::memory_order_relaxed);
  _data_source.focused_id = 0;
  input_pattern->TakeFocus();
}

void FindDialog::stop_search() {
  _running.store(false, std::memory_order_relaxed);
  if (_worker.joinable()) _worker.join();
}

void FindDialog::start_search() {
  stop_search();

  Filepath root(root_path);
  if (root.empty()) {
    status = "Root path is empty";
    return;
  }
  boost::system::error_code ec;
  const bool root_exists = boost::filesystem::exists(root, ec);
  const bool root_is_dir = root_exists && !ec.failed() && boost::filesystem::is_directory(root, ec);
  if (ec.failed() || !root_exists || !root_is_dir) {
    status = "Root path must be an existing directory";
    return;
  }

  const std::string local_pattern = pattern.empty() ? "*" : pattern;
  {
    std::lock_guard lock(_results_mutex);
    _results.clear();
  }
  _data_source.focused_id = 0;
  _dirs_scanned.store(0, std::memory_order_relaxed);
  _files_scanned.store(0, std::memory_order_relaxed);
  _errors.store(0, std::memory_order_relaxed);
  status.clear();
  _truncated = false;
  _sequence_id = g_find_sequence.fetch_add(1);
  _completed.store(false, std::memory_order_relaxed);
  _running.store(true, std::memory_order_relaxed);

  _worker = std::thread([this, root, local_pattern]() {
    TraversalCallbacks cb;
    cb.cancelled = [this] { return !_running.load(); };
    cb.enter = [&](const TraversalEntry& e) {
      if (boost::filesystem::is_directory(e.status)) ++_dirs_scanned;
      else ++_files_scanned;
      if (e.path != root && wildcard_match_casefold(local_pattern,e.path.filename().native())) {
        std::lock_guard lock(_results_mutex); _results.push_back(e.path);
      }
      return true;
    };
    cb.leave = [this](const auto&) { app->notify(); };
    cb.error = [this](const auto&,const auto&) { ++_errors; };
    auto result = traverse({root}, TraversalPolicy{false,100000,1024}, cb);
    _truncated.store(result.truncated);

    _running.store(false, std::memory_order_relaxed);
    _completed.store(true, std::memory_order_relaxed);
    app->emit(result.cancelled?"find_cancelled":"find_completed",std::to_string(_sequence_id),_sequence_id);
    app->notify();
  });
}

void FindDialog::open_selected() {
  Filepath selected;
  {
    std::lock_guard lock(_results_mutex);
    if (_results.empty()) return;
    const int64_t focused = std::clamp(_data_source.focused_id, int64_t{0}, static_cast<int64_t>(_results.size()) - 1);
    selected = _results.at(focused);
  }

  Filepath parent = selected.parent_path();
  app->filter_txt.clear();
  app->move_to(parent, selected);
  app->action.close_dialog();
}

void FindDialog::cancel() {
  stop_search();
  app->action.close_dialog();
}

}
