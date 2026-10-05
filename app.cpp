#include "app.hpp"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <format>
#include <fstream>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/table.hpp>
#include <regex>
#include <sstream>
#include "settings.hpp"

ftxui::Dialog::P DialogOverlay::get_overlay_dialog(const std::string& name) {
  auto it = _overlay_dialogs.find(name);
  if (it != _overlay_dialogs.end()) return it->second;
  return nullptr;
}

bool DialogOverlay::dialog_active() { return _active_dialog > 0; }

void DialogOverlay::close_dialog() {
  std::string closed_dialog_name = _active_dialog_name;
  // Move navigation to main document
  _active_dialog                 = 0;
  _active_dialog_name.clear();
  _overlay_renderer.reset();
  // Remove all dialogs, child index > 0
  while (navigation->ChildCount() > 1) { navigation->ChildAt(navigation->ChildCount() - 1)->Detach(); }
  if (on_event) on_event("dialog_closed", closed_dialog_name);
}

void DialogOverlay::show_dialog(std::string name) {
  if (!_overlay_dialogs.contains(name)) {
    Perun::l.e("show_dialog() name not registered", name);
    return;
  }
  _active_dialog      = 1;
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

bool Panel::loading() const { return _loading; }

void Panel::cancel_loading() {
  ++_load_generation;
  _loader.cancel();
  _loading            = false;
  _refresh_after_load = false;
  if (!dir.path.empty()) start_watcher(dir.path);
}

Panel::~Panel() {
  _callback_alive->store(false);
  _loader.shutdown();
  update_funnel.reset();  // Join callbacks while their queue/state still exist.
  pending_changes.close();
}

Panel::Panel(Filepath location, TargetFunc get_target, ExecuteOnUiThread e, DirectoryReader reader, bool defer_load) : get_target(get_target), run_on_ui(e), _read_directory(std::move(reader)) {
  if (!_read_directory) _read_directory = [](Dir& result, const Filepath& path, const std::atomic<bool>* cancelled) { return result.move_to(path, cancelled); };
  dir.path                    = location;
  dir.path_txt                = location.native();
  _state                      = std::make_shared<PanelSharedState>(&dir);
  _state->notify              = [post = e] { post([] {}); };
  _state->post                = e;
  _state->jobs                = &file_operations();
  navigation                  = Container::Tab({}, &_active_dialog);
  _state->move_to             = [this](Filepath where, Filepath focus) { this->move_to(where, focus); };
  _state->enter_archive       = [this](const Filepath& where) { return this->enter_archive(where); };
  _state->leave_virtual_dir   = [this](int64_t& focused_id) { return this->leave_virtual_dir(focused_id); };
  _state->action.close_dialog = [this]() { close_dialog(); };
  _state->action.show_dialog  = [this]() {
    const auto& name = _state->action.dialog;
    if (name == "Mkdir" || name == "Rename" || name == "Move" || name == "Delete") {
      auto error = archive_mutation_error(dir.path);
      if (!error.empty()) {
        file_operations().report_error(error);
        return;
      }
    }
    _state->action.arguments->target = this->get_target(this);
    show_dialog(_state->action.dialog);
  };
  _files         = std::make_shared<ftxui::Files>(_state);
  _main_document = std::dynamic_pointer_cast<ftxui::Dialog>(_files);
  navigation->Add(CatchEvent(_main_document->navigation, [this](Event event) {
    if (event == Event::Escape && _loading) {
      cancel_loading();
      return true;
    }
    return false;
  }));
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
  if (!defer_load) move_to(location);
}

int Panel::tab_count() const { return static_cast<int>(_tabs.size()); }

int Panel::active_tab_index() const { return _active_tab; }

std::vector<Filepath> Panel::tab_paths() const {
  std::vector<Filepath> out;
  out.reserve(_tabs.size());
  for (int i = 0; i < static_cast<int>(_tabs.size()); ++i) {
    if (i == _active_tab) out.push_back(dir.path);
    else out.push_back(_tabs[i].dir.path);
  }
  return out;
}

void Panel::new_tab() {
  sync_active_tab_state();
  TabState clone = _tabs.at(_active_tab);
  clone.dir      = dir;  // Explicit new-tab cloning is the only full directory copy.
  _tabs.insert(_tabs.begin() + _active_tab + 1, std::move(clone));
  switch_to_tab(_active_tab + 1);
  if (on_event) on_event("tab_created", std::to_string(_active_tab));
}

void Panel::close_tab() {
  if (_tabs.size() <= 1) return;
  sync_active_tab_state();
  _tabs.erase(_tabs.begin() + _active_tab);
  if (_active_tab >= static_cast<int>(_tabs.size())) { _active_tab = static_cast<int>(_tabs.size()) - 1; }
  load_active_tab();
  if (on_event) on_event("tab_closed", std::to_string(_active_tab));
}

void Panel::cycle_tab(int delta) {
  if (_tabs.size() <= 1 || delta == 0) return;
  const int n    = static_cast<int>(_tabs.size());
  int       next = (_active_tab + delta) % n;
  if (next < 0) next += n;
  switch_to_tab(next);
}

int Panel::tab_index_at_mouse(Event event) const {
  if (!event.is_mouse()) return -1;
  const auto m = event.mouse();
  if (m.button != Mouse::Left || m.motion != Mouse::Pressed) return -1;
  for (int i = 0; i < static_cast<int>(_tab_boxes.size()); ++i) {
    const auto& box = _tab_boxes[i];
    if (m.x >= box.x_min && m.x <= box.x_max && m.y >= box.y_min && m.y <= box.y_max) { return i; }
  }
  return -1;
}

void Panel::switch_to_tab(int index) {
  if (index < 0 || index >= static_cast<int>(_tabs.size())) return;
  if (index == _active_tab) return;
  sync_active_tab_state();
  _tabs[_active_tab].dir = std::move(dir);
  _active_tab            = index;
  load_active_tab();
  if (on_event) on_event("tab_switched", std::to_string(_active_tab));
}

Location Panel::location() const { return archive_service().logical_location(dir.path); }

void Panel::move_to(const Filepath& where, Filepath focus) { load_directory(where, false, false, std::move(focus)); }

void Panel::load_directory(Filepath where, bool archive, bool recover, Filepath focus, bool background_refresh) {
  const auto generation = ++_load_generation;
  if (!background_refresh) _refresh_after_load = false;
  if (archive || where != dir.path) {
    ++_watch_generation;
    update_funnel.reset();
    pending_changes.erase_if([](const UpdatedFiles&) { return true; });
  }
  _loading      = true;
  _loading_path = where;
  auto result   = std::make_shared<Dir>();
  auto stack    = _archive_stack;
  _loader.submit([this, alive = _callback_alive, post = run_on_ui, reader = _read_directory, generation, result, where, archive, recover, stack, focus, background_refresh](const LatestWork::Token& cancelled) mutable {
    Err error;
    try {
      if (where.native().rfind("fc-archive:", 0) == 0) {
        ResolvedLocation resolved;
        error = archive_service().resolve(Location::decode(where.native()), resolved, cancelled.get());
        if (error.ok()) {
          where = resolved.path;
          stack = std::move(resolved.archives);
        }
      }
      if (archive) {
        Filepath     extracted;
        ArchiveLease lease;
        error = archive_service().extract_to_cache(where, extracted, cancelled.get(), &lease);
        if (error.ok()) {
          stack.push_back(ArchiveView{where.lexically_normal(), extracted.lexically_normal(), std::move(lease)});
          where = extracted;
        }
      }
      if (recover) {
        for (;;) {
          boost::system::error_code ec;
          if (boost::filesystem::is_directory(where, ec) && !ec) break;
          auto parent = where.parent_path();
          if (parent.empty() || parent == where || cancelled->load()) break;
          where = parent;
        }
      }
      if (error.ok() && !cancelled->load()) error = reader(*result, where, cancelled.get());
    } catch (const std::exception& e) { error = Err(e.what()); }
    if (cancelled->load() || !alive->load()) return;
    post([this, alive, cancelled, generation, result, where, stack, focus, error, recover, background_refresh]() mutable {
      if (!alive->load() || cancelled->load() || generation != _load_generation) return;
      _loading = false;
      if (!error.ok()) {
        file_operations().report_error("[Panel load] " + error.steps.front());
        return;
      }
      const bool same = dir.path == where;
      if (recover && !same) file_operations().report_error("Watched directory is unavailable; moved to " + where.native());
      int                             old_index = same && _state->get_focused_index ? _state->get_focused_index() : 0;
      Filepath                        old_focus = focus;
      std::unordered_set<std::string> selected;
      if (same) {
        for (const auto& item : dir.items)
          if (item.selected()) selected.insert(item.path_ref().native());
        if (old_focus.empty() && _state->get_focused_item) {
          if (auto item = _state->get_focused_item()) old_focus = *item;
        }
      }
      dir.publish(DirectorySnapshot{std::move(result->path), std::move(result->items)});
      ++items_revision;
      dir.apply_filter(_state->filter_txt, true);
      dir.restore_selection(selected);
      _archive_stack = stack;
      _prune_archive_stack(where);
      dir.path_txt = location().display();
      _restore_focus_after_update(old_focus, old_index);
      start_watcher(where);
      sync_active_tab_state();
      if (on_event && (!background_refresh || !same)) on_event("dir_changed", where.native());
      if (std::exchange(_refresh_after_load, false)) load_directory(dir.path, false, true, {}, true);
    });
  });
}

Element Panel::render() {
  // Panel is always shown
  Element document = vbox({
    render_tabs(),
    _loading ? hbox({text(" Loading "), text(_loading_path.native()) | xflex, text(" Esc: cancel ")}) | dim : text(""),
    _main_document->renderer->Render() | yflex,
  });
  // Overwrite with active dialog
  if (!_overlay_renderer) return document;
  return dbox({
    document,
    _overlay_renderer->Render() | yflex | clear_under_colors | center,
  });
}

Filepath Panel::focused_dir() {
  // get focused item, if its dir return item's path
  auto focused = _state->get_focused_item();
  if (!focused) return dir.path;
  boost::system::error_code ec;
  const bool                isdir = boost::filesystem::is_directory(*focused, ec);
  if (!ec.failed() && isdir) return *focused;
  // dir.path would be root of the shown dir, but we want to support list of files all from different dirs, for ex. search result.
  return focused->parent_path();
}

bool Panel::enter_archive(const Filepath& archive_candidate) {
  if (!is_archive_file_path(archive_candidate)) return false;
  load_directory(archive_candidate, true, false);
  return true;
}

bool Panel::leave_virtual_dir(int64_t& focused_id) {
  if (_archive_stack.empty()) return false;
  const auto top = _archive_stack.back();
  if (dir.path.lexically_normal() != top.extracted_root.lexically_normal()) return false;
  move_to(top.archive_file.parent_path(), top.archive_file);
  return true;
}

bool Panel::execute_file_command(const std::string& id) { return _files->execute_command(id); }

void Panel::execute_dialog_command(const std::string& dialog_name) {
  _state->action.dialog            = dialog_name;
  _state->action.arguments         = dir.take_selected();
  _state->action.arguments->origin = dir.path;

  if (dir.items.empty()) {
    _state->action.arguments->focused = Filepath();
  } else {
    int focused_index                 = _state->get_focused_index ? _state->get_focused_index() : 0;
    focused_index                     = dir.offset_vissible(focused_index, 0);
    _state->action.arguments->focused = dir.items.at(focused_index).path_ref();
  }
  _state->action.show_dialog();
}

void Panel::set_debug_info(std::function<Element()> info) { _files->debug_info = info; }

PanelSharedState::P Panel::get_shared_state() const { return _state; }

Element Panel::render_tabs() const {
  _tab_boxes.clear();
  _tab_boxes.resize(_tabs.size());

  Elements tabs;
  tabs.reserve(_tabs.size() * 2 + 1);
  tabs.push_back(text(in_archive_view(dir.path) ? " Archive [read-only] " : " Tabs "));
  for (int i = 0; i < static_cast<int>(_tabs.size()); ++i) {
    if (i > 0) tabs.push_back(separatorLight());
    Filepath    path  = (i == _active_tab) ? dir.path : _tabs[i].dir.path;
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

void Panel::sync_active_tab_state() {
  if (_tabs.empty() || _active_tab < 0 || _active_tab >= static_cast<int>(_tabs.size())) return;
  TabState& tab                         = _tabs[_active_tab];
  tab.dir.path                          = dir.path;
  tab.dir.path_txt                      = dir.path_txt;
  static_cast<PanelViewState&>(tab.dir) = static_cast<const PanelViewState&>(dir);
  if (_state) {
    tab.filter_txt = _state->filter_txt;
    if (_state->get_focused_index) tab.focused_index = _state->get_focused_index();
    tab.show_permissions_column = _state->show_permissions_column;
    tab.show_owner_group_column = _state->show_owner_group_column;
  }
  tab.archive_stack = _archive_stack;
}

void Panel::start_watcher(const Filepath& where) {
  const auto generation = ++_watch_generation;
  update_funnel.reset();  // Stop the previous producer before draining its queue.
  pending_changes.erase_if([](const UpdatedFiles&) { return true; });
  if (in_archive_view(where)) return;
  try {
    update_funnel = FileChangeFunnel::create(where, [this, alive = _callback_alive, generation](UpdatedFiles changes) {
      if (!alive->load()) return;
      pending_changes.push(std::move(changes));
      this->run_on_ui([this, alive, generation]() {
        if (!alive->load() || generation != _watch_generation) return;
        auto         merged = std::make_unique<std::vector<DirItemUpdated>>();
        UpdatedFiles batch;
        while (pending_changes.try_pop(batch) == FifoError::OK) { merged->insert(merged->end(), std::make_move_iterator(batch->begin()), std::make_move_iterator(batch->end())); }
        apply_changes(std::move(merged));
      });
    });
  } catch (const std::exception& error) { file_operations().report_error("[Panel watch] " + std::string(error.what())); }
}

void Panel::apply_changes(UpdatedFiles batch) {
  if (!batch || batch->empty()) return;
  // Ordinary metadata reads also belong on the worker. A rescan is naturally
  // coalesced with other notifications by the single pending request slot.
  bool relevant = false;
  bool recover  = false;
  for (const auto& change : *batch) {
    const bool special = change.what == DirItemUpdated::Event::Rescan || change.what == DirItemUpdated::Event::WatchInvalidated;
    relevant |= special || change.path.parent_path().lexically_normal() == dir.path.lexically_normal();
    recover |= special;
  }
  if (relevant) {
    if (_loading) _refresh_after_load = true;
    else if (recover || batch->size() > 512) load_directory(dir.path, false, recover, {}, true);
    else load_delta(std::move(batch));
  }
}

void Panel::load_delta(UpdatedFiles batch) {
  std::unordered_set<std::string> paths;
  for (const auto& change : *batch)
    if (change.path.parent_path().lexically_normal() == dir.path.lexically_normal()) paths.insert(change.path.native());
  const auto generation = ++_load_generation;
  _loading              = true;
  _loading_path         = dir.path;
  _loader.submit([this, alive = _callback_alive, post = run_on_ui, generation, paths = std::move(paths)](const LatestWork::Token& cancelled) {
    auto delta = std::make_shared<std::vector<DirectoryDelta>>();
    for (const auto& path : paths) {
      if (cancelled->load()) return;
      boost::system::error_code ec;
      auto                      status = boost::filesystem::symlink_status(path, ec);
      if (!ec && boost::filesystem::exists(status)) delta->push_back({path, DirItem(path)});
      else if (!ec || ec == boost::system::errc::no_such_file_or_directory) delta->push_back({path, {}});
      else {  // A failed observation must not erase an existing entry.
        post([alive, message = ec.message()] {
          if (alive->load()) file_operations().report_error("[Panel update] " + message);
        });
      }
    }
    post([this, alive, cancelled, generation, delta] {
      if (!alive->load() || cancelled->load() || generation != _load_generation) return;
      Filepath focus;
      int      index = _state->get_focused_index ? _state->get_focused_index() : 0;
      if (_state->get_focused_item)
        if (auto item = _state->get_focused_item()) focus = *item;
      dir.publish_delta(std::move(*delta));
      ++items_revision;
      _loading = false;
      _restore_focus_after_update(focus, index);
      if (std::exchange(_refresh_after_load, false)) load_directory(dir.path, false, true, {}, true);
    });
  });
}

void Panel::load_active_tab() {
  if (_tabs.empty() || _active_tab < 0 || _active_tab >= static_cast<int>(_tabs.size())) return;
  TabState& tab  = _tabs[_active_tab];
  dir            = std::move(tab.dir);
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
    auto where = dir.path;
    move_to(where);  // Reconcile changes made while this tab had no watcher.
  } else {
    update_funnel.reset();
  }
}

void Panel::_restore_focus_after_update(const Filepath& focused_path_before, int focused_index_before) {
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

bool Panel::in_archive_view(const Filepath& path) const {
  if (_archive_stack.empty()) return false;
  return path_is_under(_archive_stack.back().extracted_root, path.lexically_normal());
}

void Panel::_prune_archive_stack(const Filepath& path) {
  const Filepath normalized = path.lexically_normal();
  while (!_archive_stack.empty() && !path_is_under(_archive_stack.back().extracted_root, normalized)) { _archive_stack.pop_back(); }
}

JobProgressBar::JobProgressBar() {
  cancel_button = Button(" Cancel ", [] {
    auto jobinfo = file_operations().get_running_job();
    if (jobinfo.job && !jobinfo.job->is_stopped()) { file_operations().cancel(jobinfo.job->_job_id); }
  });
  pause_button  = Button(" Pause/Resume ", [] {
    auto jobinfo = file_operations().get_running_job();
    if (jobinfo.job && !jobinfo.job->is_stopped()) { file_operations().pause(jobinfo.job->_job_id); }
  });
}

Element JobProgressBar::render() {
  auto jobinfo = file_operations().get_running_job();
  auto job     = jobinfo.job ? jobinfo.job->snapshot(false) : nullptr;
  if (!job) return text("[Empty]") | theme().progress_operation;
  std::string task_info = std::format(" [{}] [{}] ", jobinfo.queued_jobs, job_type_to_string(job->_type));
  if (job->is_stopped()) return text(task_info + " [Stopped]") | theme().progress_operation;
  if (!job->_focused_item) return text(task_info + " [task index invalid]") | theme().progress_operation;
  const DirItem& item        = *job->_focused_item;
  const int64_t  items_total = job->item_count();

  auto cancel_el = cancel_button->Render();
  auto pause_el  = pause_button->Render();

  switch (job->_type) {
  case JobInstructions::Type::COPY: {
    std::string total_info = std::format(" [{:3}] {:5}[{:5}] Mbps {}/{} items ", std::lround(job->_total.percentage), std::lround(job->_total.Mbps), std::lround(job->_total.average_Mbps), job->_items_done, items_total);
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
  case JobInstructions::Type::MKDIR:
  case JobInstructions::Type::RENAME:
  case JobInstructions::Type::CLIPBOARD:
  case JobInstructions::Type::MOVE: {
    // just _current_item_index is being updated
    float       item_percentage = std::max(0.0, std::min(100.0, job->_items_done * 100.0 / items_total));
    std::string count_info      = std::format(" [{:3}] {}/{} items ", std::lround(item_percentage), job->_items_done, items_total);
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
    float       item_percentage = std::max(0.0, std::min(100.0, job->_items_done * 100.0 / items_total));
    std::string byte_info       = std::format(" [{:3}] {}/{} bytes ", std::lround(byte_percentage), std::lround(job->_bytes_processed), std::lround(job->_bytes_total));
    std::string count_info      = std::format(" [{:3}] {}/{} items ", std::lround(item_percentage), job->_items_done, items_total);
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
    float       item_percentage = std::max(0.0, std::min(100.0, items_total > 0 ? job->_items_done * 100.0 / items_total : 100.0));
    std::string count_info      = std::format(" [{:3}] indexing {}/{} items ", std::lround(item_percentage), job->_items_done, items_total);
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

Panel& FileCommander::get_left() { return left; }

Panel& FileCommander::get_right() { return right; }

bool FileCommander::single_panel_mode() const { return _single_panel_mode; }

Panel& FileCommander::focused_panel() {
  if (_single_panel_mode) { return _last_main_focus_left ? left : right; }
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

std::vector<Filepath> FileCommander::focused_selection_for_editor() {
  Panel&                panel    = focused_panel();
  auto                  args     = panel.dir.take_selected();
  std::vector<Filepath> selected = args ? args->selected : std::vector<Filepath>();
  if (selected.empty()) {
    Filepath focused;
    auto*    focused_ptr = panel.get_shared_state()->get_focused_item();
    if (focused_ptr) focused = *focused_ptr;
    if (!focused.empty()) selected.push_back(focused);
  }
  return selected;
}

bool FileCommander::open_in_editor(std::string& error) {
  Panel& panel = focused_panel();
  error        = archive_mutation_error(panel.dir.path);
  if (!error.empty()) return false;
  auto selected = focused_selection_for_editor();
  for (const auto& path : selected) {
    error = archive_mutation_error(path);
    if (!error.empty()) return false;
  }
  if (selected.empty()) {
    error = "No focused item to open in editor";
    return false;
  }

  auto is_directory = [](const Filepath& p) -> bool {
    boost::system::error_code ec;
    const bool                isdir = boost::filesystem::is_directory(p, ec);
    return !ec.failed() && isdir;
  };

  if (selected.size() == 1 && is_directory(selected.front())) { return _editor_manager.open_directory(selected.front(), error); }

  std::vector<Filepath> files;
  files.reserve(selected.size());
  for (const auto& p : selected) {
    if (!is_directory(p)) files.push_back(p);
  }
  if (!files.empty()) return _editor_manager.open_files_in_last_session(files, error);

  return _editor_manager.open_directory(panel.focused_dir(), error);
}

std::vector<Command> FileCommander::list_palette_commands() { return commands().list_all(); }

std::vector<ThemeColorEntry> FileCommander::list_theme_colors() const {
  std::vector<ThemeColorEntry> out;
  const auto                   defs = theme().editable_colors();
  out.reserve(defs.size());
  for (const auto& [id, label] : defs) { out.push_back({id, label, theme().color_token(id)}); }
  return out;
}

bool FileCommander::set_theme_color(const std::string& id, const std::string& token, std::string& error) { return theme().set_color_token(id, token, &error); }

void FileCommander::reset_theme_colors() { theme().reset_color_defaults(); }

bool FileCommander::apply_key_bindings(const std::map<std::string, std::string>& bindings, std::string& error) {
  error.clear();
  auto proposed = commands().list_all();
  for (const auto& [id, token] : bindings) {
    auto item = std::find_if(proposed.begin(), proposed.end(), [&](const Command& command) { return command.id == id; });
    if (item == proposed.end() || !item->binding) {
      error = "Unknown command id: " + id;
      return false;
    }
    auto key = event_from_string(token);
    if (key == Event::Custom || event_to_token(key).empty()) {
      error = "Unsupported key for " + id + ": " + token;
      return false;
    }
    if (key == keys().key_command_palette) {
      error = "Key is reserved for the command palette";
      return false;
    }
    item->key = key;
  }
  for (size_t i = 0; i < proposed.size(); ++i) {
    for (size_t j = 0; j < i; ++j) {
      if (proposed[i].key == proposed[j].key) {
        error = "Key conflict between " + proposed[i].id + " and " + proposed[j].id;
        return false;
      }
    }
  }
  // Validation is complete before either the catalog or Theme is changed.
  for (const auto& command : proposed) { commands().set_key(command.id, command.key); }
  _editor_manager.set_switch_key(event_to_token(keys().key_switch_to_file_commander));
  return true;
}

bool FileCommander::rebind_palette_command(const std::string& id, const Event& key, std::string& error) { return apply_key_bindings({{id, event_to_token(key)}}, error); }

void FileCommander::start_initial_navigation() {
  if (!left.loading()) left.move_to(left.dir.path);
  if (!right.loading()) right.move_to(right.dir.path);
}

void FileCommander::load_settings(bool restore_paths) {
  try {
    auto settings = SettingsStore::load(SettingsStore::path());
    auto colors   = SettingsStore::load_colors();
    if (!settings) {
      theme().import_color_tokens(colors);
      return;
    }
    const auto& s = *settings;
    std::string error;
    if (!apply_key_bindings(s.key_bindings, error)) throw std::runtime_error(error);
    auto apply = [](Panel& panel, const PanelSettings& p) {
      panel.dir.order_by = p.sort;
      panel.dir._sort();
      panel.dir._calculate();
      panel.get_shared_state()->show_permissions_column = p.permissions;
      panel.get_shared_state()->show_owner_group_column = p.owner_group;
    };
    apply(left, s.left);
    apply(right, s.right);
    set_single_panel_mode(s.single_panel);
    _last_main_focus_left = s.focused_panel == "left";
    (_last_main_focus_left ? left : right).navigation->TakeFocus();
    _bookmarks.clear();
    for (const auto& p : s.bookmarks)
      if (!p.empty()) add_bookmark(p);
    for (const auto& [id, count] : s.command_use_count) commands().set_use_count(id, count);
    _editor_manager.set_binary_override(s.fresh_binary_path);
    if (_editor_manager.last_session_id().empty()) _editor_manager.set_last_session_id(s.last_editor_session_id);
    theme().import_color_tokens(colors);
    if (restore_paths) {
      auto navigate = [](Panel& panel, const std::string& path) {
        boost::system::error_code ec;
        if (!path.empty() && (Location::decode(path).read_only() || (boost::filesystem::is_directory(path, ec) && !ec))) panel.move_to(path);
      };
      navigate(left, s.left.path);
      navigate(right, s.right.path);
    }
  } catch (const std::exception& e) { file_operations().report_error("[Settings] " + std::string(e.what())); }
}

void FileCommander::save_settings() const {
  try {
    AppSettings s;
    auto        capture = [](const Panel& panel) {
      auto state = panel.get_shared_state();
      return PanelSettings{panel.location().encode(), panel.dir.order_by, state->show_permissions_column, state->show_owner_group_column};
    };
    s.left          = capture(left);
    s.right         = capture(right);
    s.single_panel  = _single_panel_mode;
    s.focused_panel = _last_main_focus_left ? "left" : "right";
    for (const auto& p : _bookmarks) s.bookmarks.push_back(p.encode());
    for (const auto& command : commands().list_all()) {
      s.command_use_count[command.id] = std::max(0, command.use_count);
      s.key_bindings[command.id]      = event_to_token(command.key);
    }
    s.fresh_binary_path      = _editor_manager.binary_override();
    s.last_editor_session_id = _editor_manager.last_session_id();
    SettingsStore::save(SettingsStore::path(), s);
    save_theme_colors();
  } catch (const std::exception& e) { file_operations().report_error("[Settings] " + std::string(e.what())); }
}

std::vector<Filepath> FileCommander::list_bookmarks() const {
  std::vector<Filepath> paths;
  for (const auto& p : _bookmarks) paths.emplace_back(p.encode());
  return paths;
}

void FileCommander::add_bookmark(const Filepath& path) {
  auto location = Location::decode(path.native());
  if (!location.read_only()) location = archive_service().logical_location(location.local);
  if (std::find(_bookmarks.begin(), _bookmarks.end(), location) == _bookmarks.end()) {
    _bookmarks.push_back(std::move(location));
    std::sort(_bookmarks.begin(), _bookmarks.end(), [](const auto& a, const auto& b) { return a.display() < b.display(); });
  }
}

void FileCommander::remove_bookmark(const Filepath& path) {
  auto location = Location::decode(path.native());
  _bookmarks.erase(std::remove(_bookmarks.begin(), _bookmarks.end(), location), _bookmarks.end());
}

void FileCommander::open_bookmark(const Filepath& path) {
  Panel& panel = focused_panel();
  auto   where = path;
  panel.move_to(where);
}

void FileCommander::add_current_focused_dir_bookmark() { add_bookmark(focused_panel().dir.path); }

void FileCommander::set_single_panel_mode(bool enabled) {
  if (enabled && !_single_panel_mode) {
    if (left.navigation->Focused()) _last_main_focus_left = true;
    else if (right.navigation->Focused()) _last_main_focus_left = false;
  }
  _single_panel_mode = enabled;
  if (_last_main_focus_left) left.navigation->TakeFocus();
  else right.navigation->TakeFocus();
}

void FileCommander::register_commands() {
  auto ready       = [this] { return !dialog_active() || _active_dialog_name == "CommandPalette"; };
  auto panel_ready = [this, ready] { return ready() && focused_panel()._active_dialog == 0; };
  auto add         = [&](std::string id, std::function<void()> run, std::function<bool()> available) {
    handlers[std::move(id)] = {[run = std::move(run)] {
                                 run();
                                 return true;
                               },
                               std::move(available)};
  };
  for (const auto& command : commands().list_all()) {
    if (command.kind == CommandKind::SHOW_DIALOG) {
      add(
        command.id,
        [this, command] {
          if (command.scope == CommandScope::PANEL) focused_panel().execute_dialog_command(command.dialog);
          else show_dialog(command.dialog);
        },
        command.scope == CommandScope::PANEL ? std::function<bool()>(panel_ready) : std::function<bool()>(ready));
    } else if (command.scope == CommandScope::PANEL) {
      handlers[command.id] = {[this, id = command.id] { return focused_panel().execute_file_command(id); }, panel_ready};
    }
  }
  add(
    "switch_panel",
    [this] {
      auto& current         = focused_panel();
      _last_main_focus_left = &current != &left;
      (_last_main_focus_left ? left : right).navigation->TakeFocus();
    },
    ready);
  add("tab_new", [this] { focused_panel().new_tab(); }, panel_ready);
  add("tab_close", [this] { focused_panel().close_tab(); }, panel_ready);
  add("tab_next", [this] { focused_panel().cycle_tab(1); }, panel_ready);
  add("tab_prev", [this] { focused_panel().cycle_tab(-1); }, panel_ready);
  add(
    "refresh_dir",
    [this] {
      auto& panel = focused_panel();
      panel.move_to(panel.dir.path);
    },
    panel_ready);
  add("toggle_single_panel_mode", [this] { set_single_panel_mode(!_single_panel_mode); }, ready);
  add("target_right", [this] { right.move_to(focused_panel().focused_dir()); }, panel_ready);
  add("target_left", [this] { left.move_to(focused_panel().focused_dir()); }, panel_ready);
  add(
    "open_in_editor",
    [this] {
      std::string error;
      if (!open_in_editor(error) && !error.empty()) file_operations().report_error(error);
    },
    panel_ready);
  // Retain the old command ID for saved key bindings and Lua callers.
  add("switch_to_file_commander", [this] {
    std::string error;
    if (!_editor_manager.switch_to_editor(focused_panel().dir.path, error) && !error.empty())
      file_operations().report_error(error);
  }, ready);
  add(
    "switch_editor_prev",
    [this] {
      std::string error;
      if (!_editor_manager.switch_prev(error) && !error.empty()) file_operations().report_error(error);
    },
    ready);
  add(
    "switch_editor_next",
    [this] {
      std::string error;
      if (!_editor_manager.switch_next(error) && !error.empty()) file_operations().report_error(error);
    },
    ready);
}

bool FileCommander::command_available(const std::string& id) {
  auto at = handlers.find(id);
  return at != handlers.end() && at->second.available();
}

bool FileCommander::execute_command(const std::string& id) {
  auto at = handlers.find(id);
  if (at == handlers.end() || !at->second.available()) return false;
  if (_active_dialog_name == "CommandPalette") close_dialog();
  if (!at->second.run()) return false;
  commands().increment_use_count(id);
  events->publish("command_executed", id, ++command_sequence);
  observe_state();
  return true;
}

void FileCommander::execute_palette_command(const std::string& id) { execute_command(id); }

void FileCommander::observe_state() {
  ViewObservation current{left.items_revision, right.items_revision, left.dir.stats().items_selected, right.dir.stats().items_selected, &focused_panel() == &left, _single_panel_mode};
  if (last_view) {
    if (current.left_revision != last_view->left_revision || current.right_revision != last_view->right_revision) events->publish("items_updated", current.left_revision != last_view->left_revision ? (current.right_revision != last_view->right_revision ? "both" : "left") : "right");
    if (current.left_selected != last_view->left_selected) events->publish("selection_changed", "left:" + std::to_string(current.left_selected));
    if (current.right_selected != last_view->right_selected) events->publish("selection_changed", "right:" + std::to_string(current.right_selected));
    if (current.focus_left != last_view->focus_left) events->publish("focus_changed", current.focus_left ? "left" : "right");
    if (current.single != last_view->single) events->publish("single_panel_mode_changed", current.single ? "on" : "off");
  }
  last_view = current;
}

FileCommander::FileCommander(Filepath l, Filepath r, ExecuteOnUiThread exec, std::function<int()> dimx, RunWithRestoredIO run_with_restored_io, bool defer_load) : left(l, get_target(), exec, {}, defer_load), right(r, get_target(), exec, {}, defer_load), _get_dimx(dimx), _run_with_restored_io(std::move(run_with_restored_io)) {
  _close_dialog = [this]() { close_dialog(); };
  auto emit     = [weak = std::weak_ptr<ApplicationEvents>(events)](std::string name, std::string detail, uint64_t request = 0) {
    if (auto bus = weak.lock()) bus->publish(std::move(name), std::move(detail), request);
  };
  on_event       = [emit](const auto& name, const auto& detail) { emit(name, detail, 0); };
  left.on_event  = on_event;
  right.on_event = on_event;
  for (auto* panel : {&left, &right}) {
    panel->get_shared_state()->emit             = emit;
    panel->get_shared_state()->dispatch_command = [this](const auto& id) { return execute_command(id); };
  }
  file_operations().set_event_sink(emit);
  register_commands();
  _editor_manager.set_run_foreground([this](const std::function<int()>& run) -> int {
    if (_run_with_restored_io) return _run_with_restored_io(run);
    return run();
  });
  _editor_manager.set_status_sink([this](const std::string& text) {
    if (!text.empty()) file_operations().report_error(text);
  });
  try { _editor_manager.set_session_store(SettingsStore::path("editor_session.json")); }
  catch (const std::exception& e) { file_operations().report_error(e.what()); }
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
  // Both layouts share one focus tree. TakeFocus must not select a separate
  // split-view ancestor when the single-panel presentation is active.
  Component main_panels = CatchEvent(Renderer(both_panels,
                                              [this, both_panels]() -> Element {
                                                if (!_single_panel_mode) return both_panels->Render();
                                                Panel&            focused      = focused_panel();
                                                Panel&            hidden       = (&focused == &left) ? right : left;
                                                const std::string hidden_label = (&focused == &left) ? "Right" : "Left";
                                                return vbox({
                                                  text(" Hidden " + hidden_label + ": " + hidden.dir.path.native() + " ") | dim,
                                                  separatorDouble(),
                                                  focused.render() | yflex,
                                                });
                                              }),
                                     [this](Event event) -> bool {
                                       if (!_single_panel_mode) return false;
                                       if (handle_global_shortcuts(event)) return true;
                                       focused_panel().navigation->OnEvent(event);
                                       return true;  // Never route input to the hidden panel through the split.
                                     });

  // Pause/Cancel buttons are focusable only when a job is running
  auto maybe_pause        = Maybe(progress_bar.pause_button, &progress_bar._has_running_job);
  auto maybe_cancel       = Maybe(progress_bar.cancel_button, &progress_bar._has_running_job);
  auto panels_with_cancel = CatchEvent(Container::Vertical({main_panels, maybe_pause, maybe_cancel}), global_shortcuts);

  navigation->Add(panels_with_cancel);
  _overlay_dialogs["ErrorList"]      = std::make_shared<ErrorListDialog>(_close_dialog);
  _overlay_dialogs["JobList"]        = std::make_shared<JobListDialog>(_close_dialog);
  _overlay_dialogs["Bookmarks"]      = std::make_shared<BookmarksDialog>(_close_dialog, [this]() { return this->list_bookmarks(); }, [this]() { this->add_current_focused_dir_bookmark(); }, [this](const Filepath& path) { this->remove_bookmark(path); }, [this](const Filepath& path) { this->open_bookmark(path); });
  _overlay_dialogs["ThemeColors"]    = std::make_shared<ThemeColorsDialog>(_close_dialog, [this]() { return this->list_theme_colors(); }, []() { return theme().available_color_tokens(); }, [this](const std::string& id, const std::string& token, std::string& error) { return this->set_theme_color(id, token, error); }, [this]() { this->reset_theme_colors(); }, [this]() { this->save_theme_colors(); });
  _overlay_dialogs["CommandPalette"] = std::make_shared<CommandPaletteDialog>(_close_dialog, [this]() { return this->list_palette_commands(); }, [this](const std::string& id) { this->execute_palette_command(id); }, [this](const std::string& id, const Event& key, std::string& error) { return this->rebind_palette_command(id, key, error); });
  renderer                           = Renderer(navigation, [=, this]() -> Element {
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

TargetFunc FileCommander::get_target() {
  return [this](Panel* self) -> Filepath {
    // self is origin pannel, return target panel's path
    if (self == &left) return right.dir.path;
    if (self == &right) return left.dir.path;
    l.e("FileCommander::get_target", "unknown self");
    return left.dir.path;
  };
}

void FileCommander::save_theme_colors() {
  try {
    SettingsStore::save_colors(theme().export_color_tokens());
  } catch (const std::exception& e) { file_operations().report_error("[Theme settings] " + std::string(e.what())); }
}

bool FileCommander::handle_global_shortcuts(Event event) {
  // Update progress bar visibility on Custom events
  // (worker thread posts Event::Custom on job progress/completion)
  if (event == Event::Custom) {
    auto jobinfo                  = file_operations().get_running_job();
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

  if (event == keys().key_command_palette) {
    if (!dialog_active() || _active_dialog_name == "CommandPalette") {
      show_dialog("CommandPalette");
      return true;
    }
    return false;
  }
  if (event == keys().key_clear_errors) {
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

  for (const auto& command : commands().list_all())
    if (command.key == event) return execute_command(command.id);

  return false;
}
