#ifndef FC_EDITOR_MANAGER_HPP_
#define FC_EDITOR_MANAGER_HPP_

#include "bfs.hpp"

#include <functional>
#include <string>
#include <vector>

struct EditorSessionInfo {
  std::string id;
  std::string display_name;
  Filepath    cwd;
  double      last_used_ts = 0;
  bool        alive        = false;
};

class EditorManager {
 public:
  using RunForeground = std::function<int(const std::function<int()>&)>;
  using StatusSink    = std::function<void(const std::string&)>;

  EditorManager() = default;
  EditorManager(RunForeground run_foreground, StatusSink status_sink);

  void set_run_foreground(RunForeground run_foreground);
  void set_status_sink(StatusSink status_sink);

  void               set_binary_override(std::string path);
  const std::string& binary_override() const;
  std::string        resolved_binary() const;

  void               set_session_store(Filepath path);
  void               set_last_session_id(std::string id);
  const std::string& last_session_id() const;
  std::vector<EditorSessionInfo> sessions() const;

  bool open_directory_new_session(const Filepath& directory, std::string& error);
  bool open_files_in_last_session(const std::vector<Filepath>& files, std::string& error);
  bool switch_next(std::string& error);
  bool switch_prev(std::string& error);

 private:
  RunForeground _run_foreground;
  StatusSink    _status_sink;

  std::string _binary_override;
  std::string _last_session_id;
  Filepath _session_store;
  std::string _session_store_error;
  bool persist_session(std::string& error) const;

  std::vector<EditorSessionInfo> _sessions;
  uint64_t                       _session_counter = 0;

  void report_status(const std::string& text) const;

  EditorSessionInfo*       find_session(const std::string& id);
  const EditorSessionInfo* find_session(const std::string& id) const;

  std::string create_session_id(const Filepath& directory);
  std::string pretty_name_for_dir(const Filepath& directory) const;

  int run_command(const Filepath& cwd, const std::vector<std::string>& args, bool interactive) const;

  bool attach_session(const std::string& id, std::string& error);

  std::vector<std::string> session_order() const;
  std::string              first_existing_session_id() const;
  void                     touch_session(const std::string& id, bool alive);
};

#endif  // FC_EDITOR_MANAGER_HPP_
