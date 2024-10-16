
#ifndef FC_COMMANDER_H_
#define FC_COMMANDER_H_

#include <boost/filesystem.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/filesystem/file_status.hpp>

#include "err.hpp"
#include "log.hpp"

#include <cstdint>
#include <ctime>

enum class Orderby {
  NAME_ASC,
  NAME_DESC,
  SIZE_ASC,
  SIZE_DESC,
  TIME_ASC,
  TIME_DESC,
};

struct DirItem {
  using P = boost::filesystem::path;
  using Type = boost::filesystem::file_type;
  using Perms = boost::filesystem::perms;

  P path;
  Type type = Type::type_unknown;
  Perms perms = Perms::no_perms;
  int64_t size = 0;
  std::time_t w_time = 0;
  bool selected = false;

  DirItem(P p, Type type, Perms perms);
  std::string to_string() const;
  std::string get_time() const;
  bool is_dir() const { return type == Type::directory_file; }
};

struct Dir {
  // selection
  DirItem::P path;
  std::vector<DirItem> items;
  Orderby order_by = Orderby::NAME_ASC;
  int cursor_pos = 0;

  struct Stats {
    int64_t items_selected=0, items_total=0, bytes_selected=0, bytes_total=0, largest_item_bytes=0;
  };
  Stats calculate();
  void sort_toggle_name_direction();
  void sort_toggle_size_direction();
  void sort_toggle_time_direction();

  Err refresh(DirItem::P& path);

  void _sort();
};

struct DirCollection {
  std::vector<Dir> tabs;
  int selected_tab = 0;
};

struct Commander {
  std::vector<DirCollection> panels;
};

#endif  // FC_COMMANDER_H_
