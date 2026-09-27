#pragma once
#include <ftxui/component/event.hpp>
#include <string>
#include <vector>

namespace ftxui {
enum class CommandScope {
  PANEL,
  GLOBAL,
};

enum class CommandKind {
  SHOW_DIALOG,
  EXECUTE_CALLBACK,
};

struct Command {
  std::string  id;
  Event        key;
  std::string  dialog;
  std::string  description;
  CommandScope scope     = CommandScope::PANEL;
  CommandKind  kind      = CommandKind::SHOW_DIALOG;
  int          use_count = 0;
  Event*       binding   = nullptr;
  Command(std::string id, Event& key, std::string dialog, std::string description, CommandScope scope, CommandKind kind) : id(std::move(id)), key(key), dialog(std::move(dialog)), description(std::move(description)), scope(scope), kind(kind), binding(&key) {}
};

struct Commands {
  std::vector<Command> available;
  Commands();

  const Command*       find_by_id(const std::string& id) const;
  Command*             find_by_id(const std::string& id);
  bool                 increment_use_count(const std::string& id);
  bool                 set_use_count(const std::string& id, int use_count);
  bool                 set_key(const std::string& id, const Event& key);
  const Command*       find_panel_by_key(const Event& key) const;
  std::vector<Command> list_all() const;
};

Commands& commands();

}  // namespace ftxui
