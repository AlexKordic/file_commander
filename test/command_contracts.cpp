#include <ftxui/component/loop.hpp>
#include <iostream>
#include <set>
#include "app.hpp"
#include "scripting.hpp"
#include "support/contracts.hpp"
#include "ui_dispatcher.hpp"
using namespace test;
using namespace ftxui;
using namespace Perun;
static void ready(FileCommander& app, UiDispatcher& ui) {
  until(
    [&] {
      ui.drain();
      return !app.get_left().loading() && !app.get_right().loading();
    },
    "command panel timeout");
}
static void command(const std::string& id, int route) {
  Fixture f;
  fs::create_directories(f / "left/sub");
  fs::create_directory(f / "right");
  write(f / "left/a", "payload");
  write(f / "left/b", "other");
  setenv("XDG_CONFIG_HOME", (f / "config").c_str(), 1);
  setenv("FC_FRESH_FAKE_LOG", (f / "fresh.log").c_str(), 1);
  setenv("FC_FRESH_BIN", (std::string(FC_TEST_SOURCE_DIR) + "/test/fakes/fresh_fake.sh").c_str(), 1);
  UiDispatcher    ui;
  std::string     clipboard;
  FileJobServices services;
  services.clipboard = [&](const auto& text) {
    clipboard = text;
    return Err();
  };
  auto          jobs = make_file_jobs({}, services);
  FileCommander app(f / "left", f / "right", ui.poster(), [] { return 100; }, [](auto fn) { return fn(); });
  ready(app, ui);
  auto& left  = app.get_left();
  auto& right = app.get_right();
  left.navigation->TakeFocus();
  left.get_shared_state()->jobs  = jobs.get();
  right.get_shared_state()->jobs = jobs.get();
  auto screen                    = ScreenInteractive::FixedSize(100, 30);
  Loop loop(&screen, app.renderer);
  // Verify actual disabled predicate with a real global dialog in front.
  require(app.execute_command("open_bookmarks"), "availability fixture failed");
  require(!app.command_available(id) && !app.execute_command(id), "busy dialog allowed command: " + id);
  app.navigation->OnEvent(Event::Escape);
  require(app._active_dialog == 0, "availability dialog did not close");
  if (id == "clear_selection") left.dir.select_all();
  if (id == "tab_close" || id == "tab_next" || id == "tab_prev") {
    left.new_tab();
    ready(app, ui);
    left.switch_to_tab(0);
    ready(app, ui);
  }
  if (id == "copy" || id == "move" || id == "delete" || id == "rename" || id == "names_to_clipboard" || id == "paths_to_clipboard") {
    left.get_shared_state()->set_focused_index(1);  // Focus fallback chooses a, not the directory.
  }
  const auto* definition = commands().find_by_id(id);
  require(definition, "missing command definition");
  auto     count  = definition->use_count;
  uint64_t cursor = 0;
  app.events->since(cursor);
  require(app.command_available(id), "ready command unavailable: " + id);
  if (route == 0) require(app.handle_global_shortcuts(definition->key), "shortcut rejected: " + id);
  if (route == 1) {
    app.handle_global_shortcuts(keys().key_command_palette);
    app.execute_palette_command(id);
  }
  if (route == 2) {
    auto path = f / "semantic.lua";
    write(path, "fc.cmd('" + id + "')");
    LuaScripting lua(app, app.renderer);
    require(lua.setup(path.string()), "semantic setup");
    until(
      [&] {
        ui.drain();
        lua.tick();
        return lua.finished();
      },
      "semantic timeout");
    require(lua.exit_code() == 0, "semantic command failed");
  }
  ready(app, ui);
  require(commands().find_by_id(id)->use_count == count + 1, "command usage did not increment once: " + id);
  auto events     = app.events->since(cursor);
  int  identities = 0;
  for (const auto& e : events)
    if (e.name == "command_executed" && e.detail == id) {
      ++identities;
      require(e.request_id > 0, "command event missing identity");
    }
  require(identities == 1, "command event count: " + id);
  static const std::map<std::string, std::string> dialogs = {{"copy", "Copy"},
                                                             {"move", "Move"},
                                                             {"delete", "Delete"},
                                                             {"rename", "Rename"},
                                                             {"mkdir", "Mkdir"},
                                                             {"find", "Find"},
                                                             {"glob_select", "GlobSelect"},
                                                             {"glob_deselect", "GlobDeselect"},
                                                             {"toggle_errors", "ErrorList"},
                                                             {"toggle_job_list", "JobList"},
                                                             {"open_bookmarks", "Bookmarks"},
                                                             {"edit_theme_colors", "ThemeColors"}};
  if (dialogs.contains(id)) {
    auto name = dialogs.at(id);
    require(left._active_dialog_name == name || app._active_dialog_name == name, "wrong real dialog: " + id);
  }
  if (id == "copy") {
    auto dialog = std::dynamic_pointer_cast<CopyDialog>(left.get_overlay_dialog("Copy"));
    until(
      [&] {
        ui.drain();
        if (dialog->_discovery_process) dialog->_discovery_process->publish_preview();
        return dialog->_discovery_process && !dialog->_discovery_process->_running;
      },
      "copy discovery timeout");
    dialog->run_copy();
    until(
      [&] {
        ui.drain();
        return jobs->idle();
      },
      "copy operation timeout");
    require(read(f / "right/a") == "payload" && read(f / "left/a") == "payload" && !fs::exists(f / "right/b"), "copy fallback chose wrong source");
  } else if (id == "move") {
    std::dynamic_pointer_cast<MoveDialog>(left.get_overlay_dialog("Move"))->ok();
    until(
      [&] {
        ui.drain();
        return jobs->idle();
      },
      "move timeout");
    require(read(f / "right/a") == "payload" && !fs::exists(f / "left/a") && fs::exists(f / "left/b"), "move side effects");
  } else if (id == "delete") {
    std::dynamic_pointer_cast<DeleteDialog>(left.get_overlay_dialog("Delete"))->ok();
    until(
      [&] {
        ui.drain();
        return jobs->idle();
      },
      "delete timeout");
    require(!fs::exists(f / "left/a") && fs::exists(f / "left/b"), "delete side effects");
  } else if (id == "rename") {
    auto dialog = std::dynamic_pointer_cast<RenameDialog>(left.get_overlay_dialog("Rename"));
    require(dialog->rows.size() == 1, "rename focus fallback");
    dialog->rows[0]->content = "renamed";
    dialog->ok();
    until(
      [&] {
        ui.drain();
        return jobs->idle() && !dialog->_pending;
      },
      "rename timeout");
    require(read(f / "left/renamed") == "payload" && !fs::exists(f / "left/a"), "rename side effects");
  } else if (id == "mkdir") {
    auto dialog          = std::dynamic_pointer_cast<MkdirDialog>(left.get_overlay_dialog("Mkdir"));
    dialog->new_dir_name = "created";
    dialog->ok();
    until(
      [&] {
        ui.drain();
        return jobs->idle() && !dialog->_pending;
      },
      "mkdir timeout");
    require(fs::is_directory(f / "left/created"), "mkdir side effects");
  } else if (id == "names_to_clipboard" || id == "paths_to_clipboard") {
    until(
      [&] {
        ui.drain();
        return jobs->idle();
      },
      "clipboard timeout");
    require(clipboard == (id == "names_to_clipboard" ? "a" : (f / "left/a").string()), "clipboard wrong text");
  } else if (id == "select_toggle") require(left.dir.stats().items_selected == 1, "toggle selection");
  else if (id == "select_all") require(left.dir.stats().items_selected == 3, "select all");
  else if (id == "clear_selection") require(left.dir.stats().items_selected == 0, "clear selection");
  else if (id == "enter_dir") require(left.dir.path == f / "left/sub", "enter directory");
  else if (id == "leave_dir") require(left.dir.path == f.root, "leave directory");
  else if (id == "toggle_permissions_column") require(left.get_shared_state()->show_permissions_column, "permissions column");
  else if (id == "toggle_owner_group_column") require(left.get_shared_state()->show_owner_group_column, "owner column");
  else if (id == "switch_panel") require(&app.focused_panel() == &right, "switch panel");
  else if (id == "tab_new") require(left.tab_count() == 2 && left.active_tab_index() == 1, "new tab");
  else if (id == "tab_close") require(left.tab_count() == 1, "close tab");
  else if (id == "tab_next" || id == "tab_prev") require(left.active_tab_index() == 1, "tab cycle");
  else if (id == "toggle_single_panel_mode") require(app.single_panel_mode(), "single panel");
  else if (id == "refresh_dir") require(left.dir.items.size() == 3, "refresh lost items");
  else if (id == "target_right") require(right.dir.path == f / "left/sub", "right target");
  else if (id == "target_left") require(left.dir.path == f / "left/sub", "left target");
  else if (id == "open_in_editor")
    require(fs::exists(f / "fresh.log") && read(f / "fresh.log").find("[-a]") != std::string::npos, "real editor handler not invoked");
  else if (id == "switch_to_file_commander") require(&app.focused_panel() == &left, "return to commander changed focus");
  else if (id == "switch_editor_prev" || id == "switch_editor_next") require(!fs::exists(f / "fresh.log"), "empty editor switch created a session");
  else require(dialogs.contains(id), "command lacks behavior expectation: " + id);
  jobs->shutdown();
  ui.drain();
}
int main(int argc, char** argv) {
  try {
    require(argc == 2, "command ID required");
    std::set<std::string> catalog = {
#define FC_COMMAND_CASE(id) #id,
#include "command_cases.inc"
#undef FC_COMMAND_CASE
    };
    std::set<std::string> actual;
    for (auto& c : commands().list_all()) actual.insert(c.id);
    require(actual == catalog, "new command requires behavior/availability contract");
    require(catalog.contains(argv[1]), "unknown command case");
    for (int route = 0; route < 3; ++route) command(argv[1], route);
    std::cout << "PASS real command " << argv[1] << " through three routes\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
