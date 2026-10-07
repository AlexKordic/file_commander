
#include "commander.hpp"
#include "log.hpp"
#include "remote_fs.hpp"

#include <boost/filesystem/file_status.hpp>
#include <boost/system/detail/error_code.hpp>

#include <algorithm>
#include <boost/filesystem.hpp>
#include <functional>
#include <memory>
#include <optional>
#include <sstream>
#include <vector>
#include <unordered_map>
#if defined(__unix__) || defined(__APPLE__)
#include <grp.h>
#include <pwd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <pthread.h>
#include <fcntl.h>
#include <signal.h>
#include <cerrno>
#include <cstring>
#endif

using namespace boost::filesystem;
using namespace boost::system;

inline std::tm localtime__(std::time_t timer) {
  std::tm bt{};
#if defined(__unix__)
  localtime_r(&timer, &bt);
#elif defined(_MSC_VER)
  localtime_s(&bt, &timer);
#else
  static std::mutex           mtx;
  std::lock_guard<std::mutex> lock(mtx);
  bt = *std::localtime(&timer);
#endif
  return bt;
}

std::string to_lower(const std::string& str) {
  std::string result = str;
  std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c) { return std::tolower(c); });
  return result;
}
size_t filter_match(const std::string& str, const std::string& substr) {
  std::string lower_str = to_lower(str);
  return lower_str.find(substr) != std::string::npos;
}

bool DirItem::is_exe() const { return (_perms & (perms::owner_exe | perms::group_exe | perms::others_exe)) > 0; }

std::string time_to_string(double _w_time) {
  static std::time_t program_start_time = std::time(nullptr);
  static std::time_t nine_months_ago    = program_start_time - (60 * 60 * 24 * 30 * 9);
  static std::time_t three_months_after = program_start_time + (60 * 60 * 24 * 30 * 3);

  std::tm ltm = localtime__(_w_time);
  char    buffer[64];
  if (_w_time < nine_months_ago) {
    return std::string(buffer, std::strftime(buffer, 64, "  %Y/%m/%d", &ltm));
  } else if (_w_time > three_months_after) {
    return std::string(buffer, std::strftime(buffer, 64, "+ %Y/%m/%d", &ltm));
  } else {
    return std::string(buffer, std::strftime(buffer, 64, "%b %e %H:%M", &ltm));
  }
}

std::string DirItem::get_time() const { return time_to_string(_w_time); }

std::string DirItem::perms_string() const {
  auto has = [this](DirItem::Perms p) -> bool { return (_perms & p) != DirItem::Perms::no_perms; };
  std::string out = "---------";
  out[0] = has(DirItem::Perms::owner_read) ? 'r' : '-';
  out[1] = has(DirItem::Perms::owner_write) ? 'w' : '-';
  out[2] = has(DirItem::Perms::owner_exe) ? 'x' : '-';
  out[3] = has(DirItem::Perms::group_read) ? 'r' : '-';
  out[4] = has(DirItem::Perms::group_write) ? 'w' : '-';
  out[5] = has(DirItem::Perms::group_exe) ? 'x' : '-';
  out[6] = has(DirItem::Perms::others_read) ? 'r' : '-';
  out[7] = has(DirItem::Perms::others_write) ? 'w' : '-';
  out[8] = has(DirItem::Perms::others_exe) ? 'x' : '-';
  return out;
}

std::string DirItem::to_string() const {
  if (_type == Type::directory_file) return _filename;
  std::ostringstream ss;
  ss << std::oct << (int)_perms;
  return _filename + " | " + std::to_string(_size) + " | " + ss.str();
}

void DirItem::update(Type type, Perms perms) {
  _type  = type;
  _perms = perms;
  // Allow files we cant access to exist in our lists
  if (_type == boost::filesystem::status_error) return;
  if (is_remote(_path)) {
    auto m = RemoteFS::inspect(_path);
    _size = m.size;
    _w_time = m.mtime_ns / 1000000000;
    _owner = m.owner;
    _group = m.group;
    _symlink = m.symlink() ? std::optional<Filepath>(m.link) : std::nullopt;
    return;
  }

  error_code ec;
  _symlink.reset();
  const bool is_link = boost::filesystem::is_symlink(_path, ec);
  if (!ec.failed() && is_link) {
    _symlink = boost::filesystem::read_symlink(_path, ec);
    if (ec.failed()) _symlink = std::nullopt;
  }

#if defined(__unix__) || defined(__APPLE__)
  struct stat st;
  if (lstat(_path.native().c_str(), &st) == 0) {
    if (is_link) _w_time = st.st_mtime;
    // Directory and discovery workers must not share libc's static buffers.
    char user_buffer[16384], group_buffer[16384];
    struct passwd user_record{}, *user = nullptr;
    struct group group_record{}, *group = nullptr;
    if (getpwuid_r(st.st_uid, &user_record, user_buffer, sizeof(user_buffer), &user) == 0 && user) _owner = user->pw_name;
    else _owner = std::to_string(static_cast<unsigned long>(st.st_uid));
    if (getgrgid_r(st.st_gid, &group_record, group_buffer, sizeof(group_buffer), &group) == 0 && group) _group = group->gr_name;
    else _group = std::to_string(static_cast<unsigned long>(st.st_gid));
  } else {
    _owner.clear();
    _group.clear();
  }
#endif

  if (!is_link) {
    _w_time = last_write_time(_path, ec);
    if (ec.failed()) _w_time = 0;
  }
  if (_type == boost::filesystem::directory_file) return;
  _size = file_size(_path, ec);
  if (ec.failed()) _size = -1;
}

DirItem::DirItem(Filepath p) : _path(std::move(p)) {
  _filename = _path.filename().native();
  if (is_remote(_path)) {
    auto m = RemoteFS::inspect(_path);
    auto status = m.status();
    if (m.symlink() && RemoteFS::inspect(_path, true).directory())
      status = boost::filesystem::file_status(directory_file, status.permissions());
    update(status.type(), status.permissions());
    return;
  }
  error_code  ec;
  file_status fs = symlink_status(_path, ec);
  if (ec.failed()) {
    update(boost::filesystem::status_error, boost::filesystem::no_perms);
    return;
  }
  // Follow metadata only for real entries, not synthetic operation records.
  if (is_symlink(fs)) {
    const auto target = status(_path, ec);
    if (!ec.failed()) fs = file_status(target.type(), fs.permissions());
  }
  update(fs.type(), fs.permissions());
}

DirItem::DirItem(Filepath p, DirItem::Type type, DirItem::Perms perms) : _path(std::move(p)) {
  _filename = _path.filename().native();
  update(type, perms);
}

DirItem::DirItem(Filepath p, std::string name, Type type, Perms perms, std::time_t t, int64_t size) : _path(std::move(p)), _filename(std::move(name)), _type(type), _perms(perms), _w_time(t), _size(size) {}

void Dir::publish(DirectorySnapshot snapshot) {
  path = std::move(snapshot.path); path_txt = path.native(); items = std::move(snapshot.items);
  _sort(); apply_filter(filter.phrase, true); _calculate();
}

void Dir::restore_selection(const std::unordered_set<std::string>& selected) {
  for (auto& item:items) item._selected = selected.contains(item.path_ref().native());
  _calculate();
}
void Dir::publish_delta(std::vector<DirectoryDelta> delta) {
  std::unordered_map<std::string,DirectoryDelta*> changes;
  for (auto& change:delta) changes[change.path.native()]=&change;
  items.erase(std::remove_if(items.begin(),items.end(),[&](DirItem& item) {
    auto found=changes.find(item.path_ref().native()); if(found==changes.end()) return false;
    auto& replacement=found->second->item;
    if(!replacement) {changes.erase(found); return true;}
    replacement->_selected=item._selected; item=std::move(*replacement); changes.erase(found); return false;
  }),items.end());
  for(auto& [key,change]:changes) if(change->item) items.push_back(std::move(*change->item));
  _sort(); apply_filter(filter.phrase,true); _calculate();
}

Err Dir::leave_dir() {
  auto parent_dir = location_parent(path);
  if (parent_dir == path) { return Err("leave_dir() on root"); }
  return move_to(parent_dir);
}

Err Dir::refresh() { return move_to(path); }

Err Dir::move_to(const Filepath p, const std::atomic<bool>* cancelled) {
  if (is_remote(p)) {
    try {
      auto where = normalize_location(p);
      std::vector<DirItem> loaded;
      for (auto &e : RemoteFS::list(where, cancelled)) {
        auto &m = e.metadata;
        auto type = m.target_directory ? directory_file : m.status().type();
        DirItem item(e.path, e.path.filename().native(), type, m.status().permissions(),
                     m.mtime_ns / 1000000000, m.size);
        item._set_ownership(m.owner, m.group);
        if (m.symlink())
          item._set_symlink_target(m.link);
        loaded.push_back(std::move(item));
      }
      if (cancelled && cancelled->load())
        return Err("Directory loading cancelled");
      publish({where, std::move(loaded)});
      path_txt = Location::decode(where.native()).display();
      return {};
    } catch (const std::exception &e) {
      return Err(e.what());
    }
  }
  error_code ec;
  if (!is_directory(p, ec) || ec) return Err("cannot open directory " + p.native() + (ec ? ": " + ec.message() : ""));
  std::vector<DirItem> loaded;
  directory_iterator it(p, ec), end;
  if (ec) return Err("dir iterate: " + p.native() + "; " + ec.message());
  while (it != end) {
    if (cancelled && cancelled->load()) return Err("directory loading cancelled");
    const auto entry = it->path();
    const auto status = boost::filesystem::symlink_status(entry, ec);
    if (!ec) loaded.emplace_back(entry);
    else return Err(ec.message() + " : stat() error on " + entry.native());
    it.increment(ec);
    if (ec) return Err("dir iterate: " + p.native() + "; " + ec.message());
  }
  if (cancelled && cancelled->load()) return Err("directory loading cancelled");
  items = std::move(loaded);
  path = p;
  path_txt = path.native();
  _sort();
  apply_filter(filter.phrase, true);
  _calculate();
  return Err();
}

// Only items in the same directory are listed in changes
void Dir::partial_refresh(UpdatedFiles changes) {
  // We don't care what is the type of change
  // - if path doesn't exist we should remove it from the list
  // - if path exists update size and date
  auto find = [&](Filepath& p) {
    std::string p_filename = p.filename().native();
    for (auto it = items.begin(); it != items.end(); ++it) {
      if (it->_filename == p_filename) {
        // equivalent does not work when file was deleted as it checks now for existance
        // error_code ec;
        // if (boost::filesystem::equivalent(it->_path, p, ec)) {
        //   if (false == ec.failed()) return it;
        // }
        return it;
      }
    }
    return items.end();
  };
  for (DirItemUpdated& updated : *changes) {
    error_code ec;
    if (!boost::filesystem::equivalent(updated.path.parent_path(), path, ec) || ec) continue;
    file_status fs     = symlink_status(updated.path, ec);
    auto        listed = find(updated.path);
    const bool  found  = listed != items.end();
    if (ec || !exists(fs)) {
      // find it and remove from the list
      if (found) items.erase(listed);
      continue;
    }
    if (found) {
      DirItem refreshed(updated.path);
      listed->update(refreshed.type(), refreshed.perms());
    } else {
      DirItem& inserted = items.emplace_back(updated.path);
      if (filter_match(inserted._filename, filter.phrase)) {
        inserted._visible = true;
      } else {
        inserted._visible = false;
      }
    }
  }
  if (!changes->empty()) {
    _sort();
    _calculate();
  }
}

void Dir::_sort() {
  std::sort(items.begin(), items.end(), [&](DirItem const& a, DirItem const& b) -> bool {
    const bool a_is_dir = a._type == DirItem::Type::directory_file;
    const bool b_is_dir = b._type == DirItem::Type::directory_file;
    if (a_is_dir != b_is_dir) return a_is_dir;
    // file to file
    switch (order_by) {
    case Orderby::NAME_ASC: return a._filename < b._filename;
    case Orderby::NAME_DESC: return b._filename < a._filename;
    case Orderby::SIZE_ASC: return a._size < b._size;
    case Orderby::SIZE_DESC: return b._size < a._size;
    case Orderby::TIME_ASC: return a._w_time < b._w_time;
    case Orderby::TIME_DESC: return b._w_time < a._w_time;
    }
  });
}

void Dir::_calculate() {
  _calculated             = Dir::Stats();
  _calculated.items_total = items.size();
  for (DirItem& item : items) {
    if (item._selected) {
      _calculated.items_selected += 1;
      _calculated.bytes_selected += item._size;
    }
    if (item._visible) { _calculated.items_visible += 1; }
    _calculated.bytes_total += item._size;
    _calculated.largest_item_bytes = std::max(_calculated.largest_item_bytes, item._size);
  }
}

void Dir::item_toggle_select(int index) {
  auto& item = items.at(index);
  if (item._selected) {
    item._selected = false;
    _calculated.items_selected -= 1;
    _calculated.bytes_selected -= item._size;
  } else {
    item._selected = true;
    _calculated.items_selected += 1;
    _calculated.bytes_selected += item._size;
  }
}

void Dir::select_all() {
  for (DirItem& x : items) {
    if (x._visible && x._selected == false) {
      x._selected = true;
      _calculated.bytes_selected += x.size();
      _calculated.items_selected += 1;
    }
  }
}
void Dir::clear_selection() {
  for (DirItem& x : items) { x._selected = false; }
  _calculated.items_selected = 0;
  _calculated.bytes_selected = 0;
}

CommandArgs::P Dir::take_selected() {
  CommandArgs::P s = std::make_shared<CommandArgs>();
  s->selected.reserve(_calculated.items_selected);
  for (DirItem& x : items) {
    if (x._selected) s->selected.push_back(x._path);
  }
  return s;
}

void Dir::apply_filter(std::string must_contain, bool force) {
  must_contain = to_lower(must_contain);
  if (!force && must_contain == filter.phrase) return;
  _calculated.items_visible = 0;
  filter.phrase             = must_contain;
  if (must_contain.empty()) {
    for (DirItem& item : items) { item._visible = true; }
    _calculated.items_visible = items.size();
    return;
  }
  for (DirItem& item : items) {
    if (filter_match(item._filename, must_contain)) {
      item._visible = true;
      _calculated.items_visible += 1;
    } else {
      item._visible = false;
    }
  }
}

int Dir::next_visible(int index) { return offset_vissible(index, 1); }
int Dir::prev_visible(int index) { return offset_vissible(index, -1); }
int Dir::offset_vissible(int curr, int offset) {
  using Cont         = std::function<bool(int)>;
  int  increment     = 1;
  auto f_inc         = [&](int i) -> bool { return i < items.size(); };
  auto f_dec         = [&](int i) -> bool { return items.size() && i >= 0; };
  Cont there_is_more = f_inc;
  auto reverse       = [&]() {
    if (increment > 0) {
      increment     = -1;
      there_is_more = f_dec;
      return;
    }
    increment     = 1;
    there_is_more = f_inc;
  };
  auto find_visible = [&](int start) -> int {
    for (int i = start; there_is_more(i); i += increment) {
      if (items[i].visible()) return i;
    }
    return -1;
  };

  curr = std::max(0, std::min(int(items.size() - 1), curr));
  if (offset < 0) reverse();
  // find starting visible item
  int start = find_visible(curr);
  if (-1 == start) {
    // No more items in this direction
    reverse();
    start = find_visible(curr);
    if (-1 == start) return 0;  // no item is visible !
    return start;
  }
  for (;;) {
    if (offset == 0) return start;
    int next = find_visible(start + increment);
    if (next == -1) return start;
    start = next;
    offset -= increment;
  }
}

void Dir::sort_toggle_name_direction() {
  switch (order_by) {
  case Orderby::NAME_ASC: order_by = Orderby::NAME_DESC; break;
  case Orderby::NAME_DESC: order_by = Orderby::NAME_ASC; break;
  case Orderby::SIZE_ASC:
  case Orderby::SIZE_DESC:
  case Orderby::TIME_ASC:
  case Orderby::TIME_DESC: order_by = Orderby::NAME_ASC; break;
  }
  _sort();
}
void Dir::sort_toggle_size_direction() {
  switch (order_by) {
  case Orderby::SIZE_ASC: order_by = Orderby::SIZE_DESC; break;
  case Orderby::SIZE_DESC: order_by = Orderby::SIZE_ASC; break;
  case Orderby::NAME_ASC:
  case Orderby::NAME_DESC:
  case Orderby::TIME_ASC:
  case Orderby::TIME_DESC: order_by = Orderby::SIZE_DESC; break;
  }
  _sort();
}
void Dir::sort_toggle_time_direction() {
  switch (order_by) {
  case Orderby::TIME_ASC: order_by = Orderby::TIME_DESC; break;
  case Orderby::TIME_DESC: order_by = Orderby::TIME_ASC; break;
  case Orderby::SIZE_ASC:
  case Orderby::SIZE_DESC:
  case Orderby::NAME_ASC:
  case Orderby::NAME_DESC: order_by = Orderby::TIME_DESC; break;
  }
  _sort();
}

bool CommandArgs::selected_share_same_dir() {
  if (selected.empty()) return false;
  bool share = true;
  auto dir   = selected.at(0).parent_path();
  for (int i = 1; i < selected.size(); i++) {
    if (selected.at(i).parent_path() != dir) {
      share = false;
      break;
    }
  }
  return share;
}

Err push_to_clipboard(std::string const& txt) {
#if defined(__unix__) || defined(__APPLE__)
#ifdef __APPLE__
  const char* command = "pbcopy";
  const char* missing = "Clipboard helper pbcopy is unavailable";
#else
  const char* command = "if command -v wl-copy >/dev/null 2>&1; then exec wl-copy; "
                        "elif command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard; "
                        "elif command -v xsel >/dev/null 2>&1; then exec xsel --clipboard --input; "
                        "else exit 127; fi";
  const char* missing = "Clipboard unavailable: install wl-copy, xclip or xsel";
#endif
  // Block SIGPIPE only on this calling thread. A helper closing stdin must
  // produce an error, not terminate the application or alter other threads.
  sigset_t pipe_signal, previous_mask, pending;
  sigemptyset(&pipe_signal);
  sigaddset(&pipe_signal, SIGPIPE);
  const int mask_error = pthread_sigmask(SIG_BLOCK, &pipe_signal, &previous_mask);
  if (mask_error) return Err("Cannot protect clipboard pipe: " + std::string(std::strerror(mask_error)));
  sigpending(&pending);
  const bool already_pending = sigismember(&pending, SIGPIPE) == 1;
  bool generated_pipe_signal = false;
  struct RestoreSignals {
    sigset_t& previous;
    sigset_t& blocked;
    bool& generated;
    bool already_pending;
    ~RestoreSignals() {
      if (generated && !already_pending) {
        sigset_t current;
        sigpending(&current);
        if (sigismember(&current, SIGPIPE) == 1) { int signal; sigwait(&blocked, &signal); }
      }
      pthread_sigmask(SIG_SETMASK, &previous, nullptr);
    }
  } restore{previous_mask, pipe_signal, generated_pipe_signal, already_pending};
  FILE* pipe = popen(command, "w");
  if (!pipe) return Err("Cannot start clipboard helper: " + std::string(std::strerror(errno)));
#ifdef __APPLE__
  // Darwin may deliver pipe signals process-wide, including to another worker.
  // Suppress generation on this descriptor instead of changing global handlers.
  if (fcntl(fileno(pipe), F_SETNOSIGPIPE, 1) == -1) {
    const auto message = std::string(std::strerror(errno));
    pclose(pipe);
    return Err("Cannot protect clipboard descriptor: " + message);
  }
#endif
  const auto written = fwrite(txt.data(), 1, txt.size(), pipe);
  const int write_error = written == txt.size() ? 0 : errno;
  const bool flushed = fflush(pipe) == 0;
  const int flush_error = flushed ? 0 : errno;
  const int status = pclose(pipe);
  generated_pipe_signal = write_error == EPIPE || flush_error == EPIPE;
  if (status == -1) return Err("Cannot wait for clipboard helper: " + std::string(std::strerror(errno)));
  if (WIFEXITED(status) && WEXITSTATUS(status) == 127) return Err(missing);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
    return Err("Clipboard helper failed (status " + std::to_string(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status)) + ")");
  if (written != txt.size() || !flushed) return Err("Clipboard helper did not accept all input");
  return Err();
#else
  return Err("Clipboard is unsupported on this platform");
#endif
}
