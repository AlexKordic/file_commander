
#ifndef FC_COMMANDER_H_
#define FC_COMMANDER_H_

#include <boost/filesystem.hpp>
#include <boost/filesystem/file_status.hpp>
#include <boost/filesystem/path.hpp>

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

class Dir;

class DirItem {
 public:
  using P     = boost::filesystem::path;
  using Type  = boost::filesystem::file_type;
  using Perms = boost::filesystem::perms;

  DirItem(P p, Type type, Perms perms);
  std::string to_string() const;
  std::string get_time() const;

  const std::string& filename_ref() const { return _filename; }
  const P&           path_ref() const { return _path; }

  bool    is_dir() const { return _type == Type::directory_file; }
  bool    visible() const { return _visible; }
  bool    selected() const { return _selected; }
  Type    type() const { return _type; }
  int64_t size() const { return _size; }

 private:
  P           _path;
  Type        _type     = Type::type_unknown;
  Perms       _perms    = Perms::no_perms;
  int64_t     _size     = 0;
  std::time_t _w_time   = 0;
  bool        _selected = false;

  bool _visible = true;

  std::string _filename;

  friend class Dir;
};

struct CommandArgs {
  using P = std::shared_ptr<CommandArgs>;
  std::vector<DirItem::P> selected;
  DirItem::P              focused;
  DirItem::P              origin, target;

  void use_focused_as_alternative() {
    if (selected.size() == 0 && focused.empty() == false) { selected.push_back(focused); }
  }
  bool selected_share_same_dir();
};

class Dir {
 public:
  // selection
  DirItem::P           path;
  std::string          path_txt;
  std::vector<DirItem> items;
  Orderby              order_by   = Orderby::NAME_ASC;
  int                  cursor_pos = 0;

  struct Stats {
    int64_t items_selected     = 0;
    int64_t items_visible      = 0;
    int64_t items_total        = 0;
    int64_t bytes_selected     = 0;
    int64_t bytes_total        = 0;
    int64_t largest_item_bytes = 0;
  };

  Err   move_to(const DirItem::P path);
  Err   refresh(); // TODO: add system notifications for current dir
  Err   leave_dir();
  void  sort_toggle_name_direction();
  void  sort_toggle_size_direction();
  void  sort_toggle_time_direction();
  void  apply_filter(std::string must_contain);
  void  clear_selection();
  void  select_all();
  void  item_toggle_select(int index);
  Stats stats() { return _calculated; }

  CommandArgs::P take_selected();

  struct Filter {
    int         cursor_position = 0;
    std::string phrase;
  };
  int next_visible(int index);
  int prev_visible(int index);
  int offset_vissible(int curr, int offset);

  Filter filter;
  Stats  _calculated;
  void   _calculate();

  void _sort();
};

struct DirCollection {
  std::vector<Dir> tabs;
  int              selected_tab = 0;
};

struct Commander {
  std::vector<DirCollection> panels;
};

Err push_to_clipboard(std::string const& txt);

#endif  // FC_COMMANDER_H_
