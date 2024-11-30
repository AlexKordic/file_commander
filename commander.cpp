
#include "commander.hpp"
#include "file_io_jobs.hpp"

#include <boost/filesystem/file_status.hpp>
#include <boost/system/detail/error_code.hpp>

#include <algorithm>
#include <boost/filesystem.hpp>
#include <functional>
#include <memory>
#include <optional>
#include <vector>
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

std::string DirItem::get_time() const {
  return time_to_string(_w_time);
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

  error_code ec;
  const bool is_link = boost::filesystem::is_symlink(_path, ec);
  if (!ec.failed() && is_link) {
    _symlink = boost::filesystem::read_symlink(_path, ec);
    if (ec.failed()) _symlink = std::nullopt;
  }
  _w_time = last_write_time(_path, ec);
  if (ec.failed()) _w_time = 0;
  if (type == boost::filesystem::directory_file) return;
  _size = file_size(_path, ec);
  if (ec.failed()) _size = -1;
}

DirItem::DirItem(Filepath p) : _path(std::move(p)) {
  _filename = _path.filename().native();
  error_code  ec;
  file_status fs = status(_path, ec);
  if (ec.failed()) {
    update(boost::filesystem::status_error, boost::filesystem::no_perms);
    return;
  }
  update(fs.type(), fs.permissions());
}

DirItem::DirItem(Filepath p, DirItem::Type type, DirItem::Perms perms) : _path(std::move(p)) {
  _filename = _path.filename().native();
  update(type, perms);
}

DirItem::DirItem(Filepath p, std::string name, Type type, Perms perms, std::time_t t, int64_t size) : _path(std::move(p)), _filename(std::move(name)), _w_time(t), _size(size) {}

Err Dir::leave_dir() {
  auto parent_dir = path.parent_path();
  if (parent_dir == path) { return Err("leave_dir() on root"); }
  return move_to(parent_dir);
}

Err Dir::refresh() { return move_to(path); }

Err Dir::move_to(const Filepath p) {
  if (false == exists(p)) return Err("don't exists path=" + p.native());
  if (false == is_directory(p)) return Err("must be dir path=" + p.native());
  items.clear();
  error_code dir_ec;
  for (directory_entry& item : directory_iterator(p, dir_ec)) {
    error_code  ec;
    // file_status fs = status(item.path(), ec);
    file_status fs = item.status(ec);
    if (ec) {
      Perun::file_operations().report_error(ec.message() + " : stat() error on " + item.path().native());
      continue;
    }
    items.emplace_back(item.path(), fs.type(), fs.permissions());
  }
  if (dir_ec) return Err("dir iterate: " + p.native() + "; " + dir_ec.message());
  this->path     = p;
  this->path_txt = this->path.native();
  _sort();
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
    error_code  ec;
    file_status fs     = status(updated.path, ec);
    auto        listed = find(updated.path);
    const bool  found  = listed != items.end();
    if (ec) {
      // find it and remove from the list
      if (found) items.erase(listed);
      continue;
    }
    if (found) {
      listed->update(fs.type(), fs.permissions());
    } else {
      const bool sanity_check = boost::filesystem::equivalent(updated.path.parent_path(), this->path);
      if (!sanity_check) {
        Perun::l.e("FS change event sanity check failed", updated.path.native(), {{"root", this->path.native()}});
        continue;
      }
      DirItem& inserted = items.emplace_back(updated.path, fs.type(), fs.permissions());
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
  std::sort(items.begin(), items.end(), [&](DirItem const& a, DirItem const& b) -> int {
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

void Dir::apply_filter(std::string must_contain) {
  must_contain = to_lower(must_contain);
  if (must_contain == filter.phrase) return;
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
  FILE* pipe = popen("pbcopy", "w");
  if (pipe == nullptr) return Err("pbcopy not found");
  int count = fwrite(txt.c_str(), txt.size(), 1, pipe);
  fflush(pipe);
  if (-1 == pclose(pipe)) return Err("pbcopy pclose() err");
  if (count != 1) return Err("pbcopy write count mismatch");
  return Err();
}
