
#include "commander.h"
#include "boost/filesystem/file_status.hpp"

#include <algorithm>
#include <boost/filesystem.hpp>
using namespace boost::filesystem;
using namespace boost::system;

std::string DirItem::get_time() const {
  std::tm * ptm = std::localtime(&w_time);
  char buffer[32];
  size_t len = std::strftime(buffer, 32, "%b %e %H:%M", ptm);
  return std::string(buffer, len);
}

std::string DirItem::to_string() const {
  if(type == Type::directory_file) return path.filename().native();
  std::ostringstream ss;
  ss << std::oct << (int)perms;
  return path.filename().native() + " | " + std::to_string(size) + " | " + ss.str();
}

DirItem::DirItem(DirItem::P p, DirItem::Type type, DirItem::Perms perms) : path(std::move(p)), type(type), perms(perms) {
  error_code ec;
  w_time = last_write_time(path, ec);
  if(ec.failed()) w_time = 0;
  if(type == boost::filesystem::directory_file) return;
  size = file_size(path, ec);
  if(ec.failed()) size = -1;
}

Err Dir::refresh(DirItem::P& p) {
  if(false == exists(p)) return Err("don't exists path=" + p.native());
  if(false == is_directory(p)) return Err("must be dir path=" + p.native());
  items.clear();
  error_code dir_ec;
  for(directory_entry& item: directory_iterator(p, dir_ec)) {
    error_code ec;
    file_status fs = status(item.path(), ec);
    if(ec) {
      Problems::report(ec.message() + " : stat() error on " + item.path().native());
      continue;
    }
    items.emplace_back(item.path(), fs.type(), fs.permissions());
  }
  if(dir_ec) return Err("dir iterate: " + dir_ec.message());
  this->path = p;
  // Sort
  _sort();
  return Err();
}

void Dir::_sort() {
  std::sort(items.begin(), items.end(), [&](DirItem const& a, DirItem const& b) -> int {
    const bool a_is_dir = a.type == DirItem::Type::directory_file;
    const bool b_is_dir = b.type == DirItem::Type::directory_file;
    if(a_is_dir != b_is_dir) return a_is_dir;
    // file to file
    switch(order_by) {
      case Orderby::NAME_ASC: return a.path.filename() < b.path.filename();
      case Orderby::NAME_DESC: return b.path.filename() < a.path.filename();
      case Orderby::SIZE_ASC: return a.size < b.size;
      case Orderby::SIZE_DESC: return b.size < a.size;
      case Orderby::TIME_ASC: return a.w_time < b.w_time;
      case Orderby::TIME_DESC: return b.w_time < a.w_time;
    }
  });
}

Dir::Stats Dir::calculate() {
  Dir::Stats s;
  s.items_total = items.size();
  for(DirItem& item : items) {
    if(item.selected) {
      s.items_selected += 1;
      s.bytes_selected += item.size;
    }
    s.bytes_total += item.size;
    s.largest_item_bytes = std::max(s.largest_item_bytes, item.size);
  }
  return s;
}

void Dir::sort_toggle_name_direction() {
  switch(order_by) {
    case Orderby::NAME_ASC:
      order_by = Orderby::NAME_DESC;
      break;
    case Orderby::NAME_DESC:
      order_by = Orderby::NAME_ASC;
      break;
    case Orderby::SIZE_ASC:
    case Orderby::SIZE_DESC:
    case Orderby::TIME_ASC:
    case Orderby::TIME_DESC:
      order_by = Orderby::NAME_ASC;
      break;
  }
  _sort();
}
void Dir::sort_toggle_size_direction() {
  switch(order_by) {
    case Orderby::SIZE_ASC:
      order_by = Orderby::SIZE_DESC;
      break;
    case Orderby::SIZE_DESC:
      order_by = Orderby::SIZE_ASC;
      break;
    case Orderby::NAME_ASC:
    case Orderby::NAME_DESC:
    case Orderby::TIME_ASC:
    case Orderby::TIME_DESC:
      order_by = Orderby::SIZE_DESC;
      break;
  }
  _sort();
}
void Dir::sort_toggle_time_direction() {
  switch(order_by) {
    case Orderby::TIME_ASC:
      order_by = Orderby::TIME_DESC;
      break;
    case Orderby::TIME_DESC:
      order_by = Orderby::TIME_ASC;
      break;
    case Orderby::SIZE_ASC:
    case Orderby::SIZE_DESC:
    case Orderby::NAME_ASC:
    case Orderby::NAME_DESC:
      order_by = Orderby::TIME_DESC;
      break;
  }
  _sort();
}
