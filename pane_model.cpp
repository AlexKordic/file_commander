#include "pane_model.hpp"

#include "file_io_jobs.hpp"
#include "location.hpp"

#include <algorithm>
#include <chrono>
#include <unordered_set>

using Perun::file_operations;

bool glob_match_casefold(const std::string& pattern, const std::string& text) {
  const auto lower = [](char c) { return static_cast<char>(std::tolower(static_cast<unsigned char>(c))); };
  size_t p = 0, t = 0, star = std::string::npos, match = 0;
  while (t < text.size()) {
    if (p < pattern.size() && (pattern[p] == '?' || lower(pattern[p]) == lower(text[t]))) {
      ++p;
      ++t;
    } else if (p < pattern.size() && pattern[p] == '*') {
      star  = p++;
      match = t;
    } else if (star != std::string::npos) {
      p = star + 1;
      t = ++match;
    } else {
      return false;
    }
  }
  while (p < pattern.size() && pattern[p] == '*') ++p;
  return p == pattern.size();
}

PaneModel::PaneModel(Filepath initial, Post post, Emit emit, DirectoryReader reader)
    : _post(std::move(post)), _emit(std::move(emit)), _read_directory(std::move(reader)) {
  if (!_read_directory)
    _read_directory = [](Dir& result, const Filepath& path, const std::atomic<bool>* cancelled) { return result.move_to(path, cancelled); };
  if (!_emit) _emit = [](const std::string&, const std::string&) {};
  Tab tab;
  tab.dir.path     = initial;
  tab.dir.path_txt = initial.native();
  _tabs.push_back(std::move(tab));
}

PaneModel::~PaneModel() {
  _alive->store(false);
  _loader.shutdown();
  _funnel.reset();  // Join watcher callbacks while the queue still exists.
  _pending_changes.close();
}

Location PaneModel::location() const { return archive_service().logical_location(dir().path); }

Location PaneModel::tab_location(int index) const {
  const auto& path = _tabs.at(index).dir.path;
  if (is_remote(path) || path.native().rfind("fc-archive:", 0) == 0) return Location::decode(path.native());
  return archive_service().logical_location(path);
}

bool PaneModel::in_archive_view() const {
  const auto& stack = active().archive_stack;
  return !stack.empty() && path_is_under(stack.back().extracted_root, dir().path.lexically_normal());
}

void PaneModel::cancel_loading() {
  ++_load_generation;
  _loader.cancel();
  _loading            = false;
  _refresh_after_load = false;
  if (!dir().path.empty()) start_watcher(dir().path);
  changed();
}

void PaneModel::move_to(const Filepath& where, Filepath focus) {
  active().restore.reset();
  load_directory(where, false, false, std::move(focus));
}

void PaneModel::refresh() { move_to(dir().path); }

void PaneModel::restart_initial_load() {
  if (!_loading) move_to(dir().path);
}

void PaneModel::load_directory(Filepath where, bool archive, bool recover, Filepath focus, bool background_refresh) {
  try {
    where = normalize_location(where);
  } catch (const std::exception& e) {
    file_operations().report_error(e.what());
    return;
  }
  if (is_remote(where) && where != dir().path) {
    dir().publish(DirectorySnapshot{where, {}});
    dir().path_txt         = Location::decode(where.native()).display();
    active().remote_error.clear();
  }
  const auto generation = ++_load_generation;
  if (!background_refresh) _refresh_after_load = false;
  if (archive || where != dir().path) {
    ++_watch_generation;
    _funnel.reset();
    _pending_changes.erase_if([](const UpdatedFiles&) { return true; });
  }
  _loading            = true;
  _loading_unattended = background_refresh;
  changed();
  auto result  = std::make_shared<Dir>();
  auto stack   = active().archive_stack;
  auto started = std::chrono::steady_clock::now();
  _loader.submit([this, alive = _alive, post = _post, reader = _read_directory, generation, result, where, archive, recover, stack, focus,
                  background_refresh, started](const LatestWork::Token& cancelled) mutable {
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
          stack.push_back(ResolvedArchive{where.lexically_normal(), extracted.lexically_normal(), std::move(lease)});
          where = extracted;
        }
      }
      if (recover && !is_remote(where)) {
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
    const double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    post([this, alive, cancelled, generation, result, where, stack, focus, error, recover, background_refresh, elapsed]() mutable {
      if (!alive->load() || cancelled->load() || generation != _load_generation) return;
      _loading = false;
      changed();
      Tab& tab = active();
      if (!error.ok()) {
        if (!is_remote(where) || tab.remote_error != error.steps.front()) file_operations().report_error("[Panel load] " + error.steps.front());
        if (is_remote(where)) {
          tab.remote_error  = error.steps.front();
          tab.dir.path      = where;
          tab.dir.path_txt  = Location::decode(where.native()).display();
          start_watcher(where);
        }
        if (recover && tab.restore && Location::decode(tab.restore->path).read_only())
          load_directory(boost::filesystem::current_path(), false, false);
        return;
      }
      if (!background_refresh) _last_load_ms = elapsed;
      tab.remote_error.clear();
      const bool same = tab.dir.path == where;
      if (recover && !same) file_operations().report_error("Watched directory is unavailable; moved to " + where.native());
      int                             old_index = same ? tab.cursor : 0;
      Filepath                        old_focus = focus;
      std::unordered_set<std::string> selected;
      if (same) {
        for (const auto& item : tab.dir.items)
          if (item.selected()) selected.insert(item.path_ref().native());
        if (old_focus.empty())
          if (auto* item = cursor_item()) old_focus = item->path_ref();
      }
      tab.dir.publish(DirectorySnapshot{std::move(result->path), std::move(result->items)});
      tab.dir.apply_filter(tab.filter, true);
      tab.dir.restore_selection(selected);
      tab.archive_stack = stack;
      prune_archive_stack(where);
      tab.dir.path_txt = location().display();
      if (tab.restore) {
        const auto&                     saved = *tab.restore;
        std::unordered_set<std::string> wanted(saved.selected.begin(), saved.selected.end());
        std::unordered_set<std::string> actual;
        for (const auto& item : tab.dir.items) {
          auto logical = archive_service().logical_location(item.path_ref()).encode();
          if (wanted.contains(logical)) actual.insert(item.path_ref().native());
          if (logical == saved.focused) old_focus = item.path_ref();
        }
        tab.dir.restore_selection(actual);
        if (location().encode() == saved.path) tab.restore.reset();
      }
      restore_cursor(old_focus, old_index);
      start_watcher(where);
      if (!background_refresh || !same) _emit("dir_changed", where.native());
      _emit("items_updated", "");
      if (std::exchange(_refresh_after_load, false)) load_directory(tab.dir.path, false, true, {}, true);
    });
  });
}

void PaneModel::start_watcher(const Filepath& where) {
  const auto generation = ++_watch_generation;
  _funnel.reset();  // Stop the previous producer before draining its queue.
  _pending_changes.erase_if([](const UpdatedFiles&) { return true; });
  if (in_archive_view()) return;
  try {
    _funnel = FileChangeFunnel::create(where, [this, alive = _alive, post = _post, generation](UpdatedFiles changes) {
      if (!alive->load()) return;
      _pending_changes.push(std::move(changes));
      post([this, alive, generation] {
        if (!alive->load() || generation != _watch_generation) return;
        auto         merged = std::make_unique<std::vector<DirItemUpdated>>();
        UpdatedFiles batch;
        while (_pending_changes.try_pop(batch) == Perun::FifoError::OK)
          merged->insert(merged->end(), std::make_move_iterator(batch->begin()), std::make_move_iterator(batch->end()));
        apply_changes(std::move(merged));
      });
    });
  } catch (const std::exception& error) { file_operations().report_error("[Panel watch] " + std::string(error.what())); }
}

void PaneModel::apply_changes(UpdatedFiles batch) {
  if (!batch || batch->empty()) return;
  bool relevant = false, recover = false;
  for (const auto& change : *batch) {
    const bool special = change.what == DirItemUpdated::Event::Rescan || change.what == DirItemUpdated::Event::WatchInvalidated;
    relevant |= special || change.path.parent_path().lexically_normal() == dir().path.lexically_normal();
    recover |= special;
  }
  if (!relevant) return;
  if (_loading) _refresh_after_load = true;
  else if (recover || batch->size() > 512) load_directory(dir().path, false, recover, {}, true);
  else load_delta(std::move(batch));
}

void PaneModel::load_delta(UpdatedFiles batch) {
  std::unordered_set<std::string> paths;
  for (const auto& change : *batch)
    if (change.path.parent_path().lexically_normal() == dir().path.lexically_normal()) paths.insert(change.path.native());
  const auto generation = ++_load_generation;
  _loading              = true;
  _loading_unattended   = true;
  _loader.submit([this, alive = _alive, post = _post, generation, paths = std::move(paths)](const LatestWork::Token& cancelled) {
    auto delta = std::make_shared<std::vector<DirectoryDelta>>();
    for (const auto& path : paths) {
      if (cancelled->load()) return;
      boost::system::error_code ec;
      auto                      status = boost::filesystem::symlink_status(path, ec);
      if (!ec && boost::filesystem::exists(status)) delta->push_back({path, DirItem(path)});
      else if (!ec || ec == boost::system::errc::no_such_file_or_directory) delta->push_back({path, {}});
      else post([alive, message = ec.message()] {  // A failed observation must not erase an existing entry.
        if (alive->load()) file_operations().report_error("[Panel update] " + message);
      });
    }
    post([this, alive, cancelled, generation, delta] {
      if (!alive->load() || cancelled->load() || generation != _load_generation) return;
      Filepath focus;
      int      index = active().cursor;
      if (auto* item = cursor_item()) focus = item->path_ref();
      dir().publish_delta(std::move(*delta));
      _loading = false;
      changed();
      restore_cursor(focus, index);
      _emit("items_updated", "");
      if (std::exchange(_refresh_after_load, false)) load_directory(dir().path, false, true, {}, true);
    });
  });
}

void PaneModel::restore_cursor(const Filepath& focused_before, int index_before) {
  auto& items = dir().items;
  if (items.empty()) {
    active().cursor = 0;
    return;
  }
  int found = -1;
  if (!focused_before.empty()) {
    for (int i = 0; i < int(items.size()); ++i)
      if (items[i].path_ref() == focused_before) {
        found = i;
        break;
      }
    if (found < 0) {
      const auto name = focused_before.filename().native();
      for (int i = 0; i < int(items.size()); ++i)
        if (items[i].filename_ref() == name) {
          found = i;
          break;
        }
    }
  }
  if (found < 0) found = std::clamp(index_before, 0, int(items.size()) - 1);
  active().cursor = dir().offset_vissible(found, 0);
  changed();
}

void PaneModel::prune_archive_stack(const Filepath& path) {
  const Filepath normalized = path.lexically_normal();
  auto&          stack      = active().archive_stack;
  while (!stack.empty() && !path_is_under(stack.back().extracted_root, normalized)) stack.pop_back();
}

bool PaneModel::enter(int item_index) {
  auto& items = dir().items;
  if (item_index < 0 || item_index >= int(items.size())) return false;
  const DirItem where = items[item_index];
  if (where.is_dir()) {
    active().filter.clear();
    dir().apply_filter("", true);
    move_to(where.path_ref());
    active().cursor = 0;
    return true;
  }
  if (is_remote(where.path_ref())) {
    if (is_archive_file_path(where.path_ref())) {
      file_operations().report_error("Copy remote archives to a local tab before opening them");
      return true;
    }
    return false;
  }
  if (!is_archive_file_path(where.path_ref())) return false;
  active().filter.clear();
  dir().apply_filter("", true);
  active().restore.reset();
  load_directory(where.path_ref(), true, false);
  return true;
}

bool PaneModel::leave_virtual_dir() {
  auto& stack = active().archive_stack;
  if (stack.empty()) return false;
  const auto top = stack.back();
  if (dir().path.lexically_normal() != top.extracted_root.lexically_normal()) return false;
  move_to(top.archive_file.parent_path(), top.archive_file);
  return true;
}

void PaneModel::leave() {
  active().filter.clear();
  dir().apply_filter("", true);
  changed();
  if (leave_virtual_dir()) return;
  const Filepath old_path = dir().path;
  move_to(location_parent(old_path), old_path);
}

Filepath PaneModel::focused_dir() const {
  const DirItem* focused = cursor_item();
  if (!focused) return dir().path;
  if (is_remote(focused->path_ref())) return focused->is_dir() ? focused->path_ref() : location_parent(focused->path_ref());
  boost::system::error_code ec;
  if (boost::filesystem::is_directory(focused->path_ref(), ec) && !ec) return focused->path_ref();
  return focused->path_ref().parent_path();
}

void PaneModel::new_tab(std::optional<Filepath> where, bool tutorial) {
  Tab clone        = active();
  clone.tutorial   = tutorial || active().tutorial;  // A tab opened from a tutorial tab closes with it.
  clone.restore.reset();
  if (where) {
    clone.filter.clear();
    clone.dir.filter.phrase.clear();
    clone.cursor = 0;
  }
  _tabs.insert(_tabs.begin() + _active + 1, std::move(clone));
  _active = _active + 1;
  changed();
  _emit("tab_created", std::to_string(_active));
  if (where) move_to(*where);
  else load_active_tab();
}

void PaneModel::close_tab(int index) {
  if (_tabs.size() <= 1 || index < 0 || index >= int(_tabs.size())) return;
  const bool was_active = index == _active;
  _tabs.erase(_tabs.begin() + index);
  if (index < _active || _active >= int(_tabs.size())) _active = std::max(0, _active - 1);
  changed();
  if (was_active) load_active_tab();
  _emit("tab_closed", std::to_string(_active));
}

void PaneModel::close_tutorial_tabs() {
  bool active_closed = false;
  for (int i = int(_tabs.size()) - 1; i >= 0 && _tabs.size() > 1; --i) {
    if (!_tabs[i].tutorial) continue;
    active_closed |= i == _active;
    _tabs.erase(_tabs.begin() + i);
    if (i < _active) --_active;
  }
  if (_tabs.size() == 1 && _tabs[0].tutorial) {
    // The last tab can't go; send it home instead of leaving it in the demo folder.
    _tabs[0].tutorial = false;
    _tabs[0].filter.clear();
    _tabs[0].dir.filter.phrase.clear();
    _active = 0;
    changed();
    move_to(Filepath(std::getenv("HOME") ? std::getenv("HOME") : "/"));
    return;
  }
  _active = std::clamp(_active, 0, int(_tabs.size()) - 1);
  changed();
  if (active_closed) load_active_tab();
}

void PaneModel::cycle_tab(int delta) {
  if (_tabs.size() <= 1 || delta == 0) return;
  const int n    = int(_tabs.size());
  int       next = (_active + delta) % n;
  if (next < 0) next += n;
  switch_to_tab(next);
}

void PaneModel::switch_to_tab(int index) {
  if (index < 0 || index >= int(_tabs.size()) || index == _active) return;
  _active = index;
  changed();
  load_active_tab();
  _emit("tab_switched", std::to_string(_active));
}

void PaneModel::move_tab(int from, int to) {
  if (from < 0 || to < 0 || from >= int(_tabs.size()) || to >= int(_tabs.size()) || from == to) return;
  auto tab = std::move(_tabs[from]);
  _tabs.erase(_tabs.begin() + from);
  _tabs.insert(_tabs.begin() + to, std::move(tab));
  if (_active == from) _active = to;
  else if (from < _active && to >= _active) --_active;
  else if (from > _active && to <= _active) ++_active;
  changed();
}

void PaneModel::load_active_tab() {
  Tab& tab = active();
  prune_archive_stack(tab.dir.path);
  tab.dir.apply_filter(tab.filter, true);
  changed();
  if (!tab.dir.path.empty()) load_directory(tab.dir.path, false, tab.restore.has_value());  // Reconcile inactive or restored tabs.
  else _funnel.reset();
}

const std::vector<int>& PaneModel::visible_rows() {
  if (_visible_dirty) {
    _visible.clear();
    const auto& items = dir().items;
    _visible.reserve(items.size());
    for (int i = 0; i < int(items.size()); ++i)
      if (items[i].visible()) _visible.push_back(i);
    _visible_dirty = false;
  }
  return _visible;
}

int PaneModel::row_of_item(int item_index) {
  const auto& rows = visible_rows();
  auto        at   = std::lower_bound(rows.begin(), rows.end(), item_index);
  return at != rows.end() && *at == item_index ? int(at - rows.begin()) : -1;
}

const DirItem* PaneModel::cursor_item() const {
  const auto& items = dir().items;
  if (items.empty()) return nullptr;
  int index = const_cast<Dir&>(dir()).offset_vissible(active().cursor, 0);
  if (index < 0 || index >= int(items.size()) || !items[index].visible()) return nullptr;
  return &items[index];
}

void PaneModel::set_cursor(int item_index) {
  if (dir().items.empty()) return;
  active().cursor = dir().offset_vissible(std::clamp(item_index, 0, int(dir().items.size()) - 1), 0);
  ++_revision;
}

void PaneModel::set_filter(std::string text) {
  if (text == active().filter) return;
  active().filter = std::move(text);
  dir().apply_filter(active().filter);
  dir()._calculate();
  if (!dir().items.empty()) active().cursor = dir().offset_vissible(active().cursor, 0);
  changed();
}

void PaneModel::set_sort(Orderby order) {
  const DirItem* focused = cursor_item();
  Filepath       keep    = focused ? focused->path_ref() : Filepath();
  dir().order_by         = order;
  dir()._sort();
  dir().apply_filter(active().filter, true);
  dir()._calculate();
  changed();
  restore_cursor(keep, active().cursor);
}

void PaneModel::set_columns(bool permissions, bool owner_group) {
  active().permissions = permissions;
  active().owner_group = owner_group;
  ++_revision;
  ++_content_revision;
}

void PaneModel::toggle_select(int item_index) {
  if (item_index < 0 || item_index >= int(dir().items.size())) return;
  dir().item_toggle_select(item_index);
  ++_revision;
  ++_marks_revision;
}

void PaneModel::set_selected(int item_index, bool selected) {
  if (item_index < 0 || item_index >= int(dir().items.size())) return;
  if (dir().items[item_index].selected() != selected) toggle_select(item_index);
}

void PaneModel::select_all() {
  dir().select_all();
  ++_revision;
  ++_marks_revision;
}

void PaneModel::clear_selection() {
  dir().clear_selection();
  ++_revision;
  ++_marks_revision;
}

int PaneModel::glob_select(const std::string& pattern, bool select) {
  int matches = 0;
  for (int i = 0; i < int(dir().items.size()); ++i) {
    if (!glob_match_casefold(pattern, dir().items[i].filename_ref())) continue;
    ++matches;
    set_selected(i, select);
  }
  return matches;
}

CommandArgs::P PaneModel::command_args() const {
  auto args    = const_cast<Dir&>(dir()).take_selected();
  args->origin = dir().path;
  if (auto* item = cursor_item()) args->focused = item->path_ref();
  args->use_focused_as_alternative();
  return args;
}

void PaneModel::adopt_tutorial_tabs(const std::string& prefix) {
  if (prefix.empty()) return;
  for (int i = 0; i < int(_tabs.size()); ++i) {
    const auto location = tab_location(i);
    const auto shown    = location.remote() ? location.local.native() : location.read_only() ? location.archives.front().native() : location.local.native();
    if (shown.rfind(prefix, 0) == 0) _tabs[i].tutorial = true;
  }
  changed();
}

PanelWorkspace PaneModel::capture_workspace(bool with_tutorial) const {
  PanelWorkspace out;
  out.active = _active;
  for (const auto& tab : _tabs) {
    if (tab.tutorial && !with_tutorial) continue;  // Tutorial tabs never outlive the tutorial.
    if (tab.restore) {
      out.tabs.push_back(*tab.restore);
      continue;
    }
    TabWorkspace saved;
    saved.path        = archive_service().logical_location(tab.dir.path).encode();
    saved.sort        = tab.dir.order_by;
    saved.filter      = tab.filter;
    saved.permissions = tab.permissions;
    saved.owner_group = tab.owner_group;
    if (tab.cursor >= 0 && size_t(tab.cursor) < tab.dir.items.size())
      saved.focused = archive_service().logical_location(tab.dir.items[tab.cursor].path_ref()).encode();
    for (const auto& item : tab.dir.items)
      if (item.selected()) saved.selected.push_back(archive_service().logical_location(item.path_ref()).encode());
    out.tabs.push_back(std::move(saved));
  }
  if (out.tabs.empty()) out.active = 0;
  else out.active = std::min(out.active, out.tabs.size() - 1);
  return out;
}

void PaneModel::restore_workspace(const PanelWorkspace& saved) {
  if (saved.tabs.empty()) return;
  ++_load_generation;
  _loader.cancel();
  _tabs.clear();
  for (const auto& entry : saved.tabs) {
    Tab tab;
    tab.dir.path     = entry.path;
    tab.dir.path_txt = entry.path;
    tab.dir.order_by = entry.sort;
    tab.filter       = entry.filter;
    tab.permissions  = entry.permissions;
    tab.owner_group  = entry.owner_group;
    tab.restore      = entry;
    _tabs.push_back(std::move(tab));
  }
  _active = std::min(int(saved.active), int(_tabs.size()) - 1);
  load_active_tab();
}
