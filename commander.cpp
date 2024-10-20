
#include "commander.h"
#include "boost/filesystem/file_status.hpp"

#include <algorithm>
#include <boost/filesystem.hpp>
#include <functional>
using namespace boost::filesystem;
using namespace boost::system;

std::string DirItem::get_time() const {
  std::tm* ptm = std::localtime(&_w_time);
  char     buffer[32];
  size_t   len = std::strftime(buffer, 32, "%b %e %H:%M", ptm);
  return std::string(buffer, len);
}

std::string DirItem::to_string() const {
  if (_type == Type::directory_file) return _filename;
  std::ostringstream ss;
  ss << std::oct << (int)_perms;
  return _filename + " | " + std::to_string(_size) + " | " + ss.str();
}

DirItem::DirItem(DirItem::P p, DirItem::Type type, DirItem::Perms perms) : _path(std::move(p)), _type(type), _perms(perms) {
  _filename = _path.filename().native();
  error_code ec;
  _w_time = last_write_time(_path, ec);
  if (ec.failed()) _w_time = 0;
  if (type == boost::filesystem::directory_file) return;
  _size = file_size(_path, ec);
  if (ec.failed()) _size = -1;
}

Err Dir::leave_dir() {
  auto parent_dir = path.parent_path();
  if (parent_dir == path) { return Err("leave_dir() on root"); }
  return move_to(parent_dir);
}

Err Dir::move_to(const DirItem::P p) {
  if (false == exists(p)) return Err("don't exists path=" + p.native());
  if (false == is_directory(p)) return Err("must be dir path=" + p.native());
  items.clear();
  error_code dir_ec;
  for (directory_entry& item : directory_iterator(p, dir_ec)) {
    error_code  ec;
    file_status fs = status(item.path(), ec);
    if (ec) {
      Problems::report(ec.message() + " : stat() error on " + item.path().native());
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

void Dir::clear_selection() {
  for (DirItem& x : items) { x._selected = false; }
  _calculated.items_selected = 0;
  _calculated.bytes_selected = 0;
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
  auto f_dec         = [&](int i) -> bool { return i >= 0; };
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

  curr = std::max(0, std::min(int(items.size()), curr));
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
