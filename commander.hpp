
#ifndef FC_COMMANDER_H_
#define FC_COMMANDER_H_

#include "bfs.hpp"
#include "err.hpp"

#include <cstdint>
#include <ctime>
#include <memory>
#include <optional>

std::string time_to_string(double time);

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
  using Type  = boost::filesystem::file_type;
  using Perms = boost::filesystem::perms;

  // Collect all info from given path
  explicit DirItem(Filepath p);
  // Collect all info from given path, type and perms
  DirItem(Filepath p, Type type, Perms perms);
  // Set all attributes from given values; offten used to store non-file data
  DirItem(Filepath p, std::string name, Type type, Perms perms, std::time_t t, int64_t size);
  void        update(Type type, Perms perms);
  std::string to_string() const;
  std::string get_time() const;
  std::string perms_string() const;
  const std::string& owner_string() const { return _owner; }
  const std::string& group_string() const { return _group; }

  const std::string& filename_ref() const { return _filename; }
  const Filepath&    path_ref() const { return _path; }

  const std::optional<Filepath>    symlink_ref() const { return _symlink; }
  const std::optional<std::string> warning_ref() const { return _warning; }

  bool    is_dir() const { return _type == Type::directory_file; }
  bool    is_exe() const;
  bool    visible() const { return _visible; }
  bool    selected() const { return _selected; }
  Type    type() const { return _type; }
  Perms   perms() const { return _perms; }
  int64_t size() const { return _size; }

  void _set_symlink_target(Filepath p) { _symlink = std::move(p); }
  void _set_warning(std::string w) { _warning = std::move(w); }

 private:
  Filepath    _path;
  Type        _type     = Type::type_unknown;
  Perms       _perms    = Perms::no_perms;
  int64_t     _size     = 0;
  std::time_t _w_time   = 0;
  bool        _selected = false;

  bool _visible = true;

  std::string                _filename;
  std::optional<Filepath>    _symlink;
  std::optional<std::string> _warning;
  std::string                _owner;
  std::string                _group;

  friend class Dir;
};

struct DirItemUpdated {
  Filepath path;
  enum class Event {
    Created,
    Removed,
    Renamed,
    Modified,
  } what;

  DirItemUpdated(const char* p, Event e) : path(p), what(e) {}
};

using UpdatedFiles = std::unique_ptr<std::vector<DirItemUpdated>>;

struct FileChangeFunnel {
  using Callback = std::function<void(UpdatedFiles changes)>;
  static std::unique_ptr<FileChangeFunnel> create(Filepath root, Callback cb);
  virtual ~FileChangeFunnel() = default;
};

struct CommandArgs {
  using P = std::shared_ptr<CommandArgs>;
  std::vector<Filepath> selected;
  Filepath              focused;
  Filepath              origin, target;

  void use_focused_as_alternative() {
    if (selected.size() == 0 && focused.empty() == false) { selected.push_back(focused); }
  }
  bool selected_share_same_dir();
};

class Dir {
 public:
  // selection
  Filepath             path;
  std::string          path_txt;
  std::vector<DirItem> items;
  Orderby              order_by   = Orderby::NAME_ASC;
  int                  cursor_pos = 0;

  // TODO: use boost accumulators
  struct Stats {
    int64_t items_selected     = 0;
    int64_t items_visible      = 0;
    int64_t items_total        = 0;
    int64_t bytes_selected     = 0;
    int64_t bytes_total        = 0;
    int64_t largest_item_bytes = 0;
  };

  Err   move_to(const Filepath path);
  void  partial_refresh(UpdatedFiles changes);
  Err   refresh();  // TODO: add system notifications for current dir
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
  void   _sort();
};

// struct DirCollection {
//   std::vector<Dir> tabs;
//   int              selected_tab = 0;
// };
// struct Commander {
//   std::vector<DirCollection> panels;
// };

Err push_to_clipboard(std::string const& txt);

#endif  // FC_COMMANDER_H_
