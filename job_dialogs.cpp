#include "traversal.hpp"

#include "dialogs.hpp"
#include "dialog_support.hpp"
#include "archive.hpp"
#include "bfs.hpp"
#include "commander.hpp"
#include "file_io_jobs.hpp"
#include "custom_controls.hpp"
#include "log.hpp"
#include "shared_state.hpp"
#include "theme.hpp"

#include <boost/filesystem/file_status.hpp>
#include <boost/filesystem/operations.hpp>
#include <boost/system/detail/error_code.hpp>

#include <cstdint>
#include <ftxui/component/component.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/color_info.hpp>

#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <deque>
#include <format>
#include <mutex>
#include <memory>
#include <string>
#include <thread>

using boost::filesystem::directory_entry;
using boost::filesystem::directory_iterator;
using boost::filesystem::file_status;
using boost::system::error_code;

using Perun::file_operations;
using Perun::CopyConflictMode;
using Perun::JobInstructions;
using Perun::JobSpec;
using Perun::JobState;
using Perun::JobSnapshot;
using Perun::Operation;
using Perun::OperationPlan;
using Perun::OperationType;
using Perun::selection_plan;

std::string time_to_string(double time);

namespace ftxui {
ErrorListDialog::ErrorListDialog(std::function<void()> close_dialog) : Dialog(nullptr), close_dialog(close_dialog) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();

  button_hide                     = Button(" Hide ", close_dialog, ascii_button);
  button_clear                    = Button(" Clear ", [this] { this->clear(); }, ascii_button);
  _data_source.dataset_size       = []() -> DataSize { auto n=file_operations().error_count(); return {n,0,std::max(int64_t{0},n-1)}; };
  _data_source.count_items_before = [this](int64_t id) -> int64_t { return id; };
  _data_source.move_id_by         = [this](int64_t& id, int64_t delta) -> bool { auto old=id; id=std::clamp(id+delta,int64_t{0},std::max(int64_t{0},file_operations().error_count()-1));return old!=id; };
  _data_source.on_event           = [this](DSEventContext c) -> bool {
    if (c.event == Event::Return) {
      this->button_hide->TakeFocus();
      return true;
    }
    return c.handled;
  };
  _data_source.transform = [this](DSRenderContext& c) -> Element {
    auto item = file_operations().get_error(c.id);
    auto row  = hbox({text(time_to_string(item.time)), separator(), text(item.message)});
    if (c.focused) {
      if (c.component_focused) {
        row |= color(theme().files_focused_empty) | ftxui::focus;
      } else {
        row |= color(theme().files_unfocused_empty) | ftxui::focus;
      }
    }
    return std::move(row);
  };
  _errors    = clipped_menu(&_data_source);
  navigation = CatchEvent(Container::Vertical({
                            Container::Horizontal({button_hide, button_clear}),
                            // Following are path items to delete
                            _errors,
                          }),
                          close_on_esc(this));
  renderer   = Renderer(navigation, [this]() -> Element {
    // add items in render method
    auto n=file_operations().error_count(); DataSize s{n,0,std::max(int64_t{0},n-1)};
    return window(hbox({text(" Error History [" + std::to_string(s.total) + "]"), screen_render_time()}) | bold | hcenter,
                    vbox({
                    hbox({
                      button_hide->Render() | hcenter | xflex_grow,
                      separator(),
                      button_clear->Render() | hcenter | xflex_grow,
                    }),
                    separator(),
                    _errors->Render() | theme().files_border,
                  }),
                    BorderStyle::DOUBLE);
  });
}

void ErrorListDialog::clear() {
  file_operations().clear_errors();
  this->close_dialog();
}

void ErrorListDialog::cancel() { this->close_dialog(); }

void ErrorListDialog::OnShow() {
  int  dimy   = 50;
  auto screen = ScreenInteractive::Active();
  if (screen) dimy = screen->dimy();
  _data_source.min_y      = std::round(theme().errorlist_height_screen_portion * dimy);
  const bool initial_show = _data_source.focused_id == 0;
  if (initial_show) { _data_source.focused_id = _data_source.dataset_size().starting_id; }
}

//
// JobListDialog
//

std::string JobListDialog::state_icon(JobState state) {
  switch (state) {
  case JobState::QUEUED:               return "..";
  case JobState::RUNNING:              return ">>";
  case JobState::PAUSED:               return "||";
  case JobState::CANCELLED:            return "XX";
  case JobState::COMPLETED:            return "OK";
  case JobState::COMPLETED_WITH_ERRORS: return "!!";
  }
  return "??";
}

std::string JobListDialog::format_duration(double seconds) {
  if (seconds < 0) return "-";
  if (seconds < 1.0) return std::format("{:.0f}ms", seconds * 1000);
  if (seconds < 60.0) return std::format("{:.1f}s", seconds);
  return std::format("{:.0f}m {:.0f}s", std::floor(seconds / 60), std::fmod(seconds, 60));
}

std::string JobListDialog::format_bytes(double bytes) {
  if (bytes < 1024) return std::format("{:.0f} B", bytes);
  if (bytes < 1024 * 1024) return std::format("{:.1f} KB", bytes / 1024);
  if (bytes < 1024 * 1024 * 1024) return std::format("{:.1f} MB", bytes / (1024 * 1024));
  return std::format("{:.1f} GB", bytes / (1024 * 1024 * 1024));
}

void JobListDialog::rebuild_list() {
  jobs.clear();

  auto jobinfo = file_operations().get_running_job();
  if (jobinfo.job && !jobinfo.job->is_stopped()) {
    jobs.push_back(jobinfo.job->snapshot(false));
  }

  auto history = file_operations().get_job_history();
  // Show most recent first
  for (auto it = history.rbegin(); it != history.rend(); ++it) {
    const auto id = (*it)->_job_id;
    if (std::none_of(jobs.begin(), jobs.end(), [id](const auto& j) { return j->_job_id == id; }))
      jobs.push_back((*it)->snapshot(false));
  }

  if (detail_job) {
    auto id=detail_job->_job_id;
    auto refresh=[&](const auto& job) {
      if(job && job->_job_id==id) {
        auto summary=job->snapshot(false);
        if(summary->_items_done!=detail_job->_items_done || summary->_state!=detail_job->_state || summary->_error_count!=detail_job->_error_count)
          detail_job=job->snapshot();
      }
    };
    refresh(jobinfo.job); for(auto& job:history) refresh(job);
  }
  // Clamp focused_id to valid range
  if (!jobs.empty()) {
    _job_data_source.focused_id = std::clamp(_job_data_source.focused_id, int64_t{0}, (int64_t)jobs.size() - 1);
  } else {
    _job_data_source.focused_id = 0;
  }
}

void JobListDialog::open_detail() {
  auto focused = _job_data_source.focused_id;
  if (jobs.empty() || focused < 0 || focused >= (int64_t)jobs.size()) return;
  auto id=jobs[focused]->_job_id;
  auto current=file_operations().get_running_job().job;
  if(current && current->_job_id==id) detail_job=current->snapshot();
  else for(auto& job:file_operations().get_job_history()) if(job->_job_id==id) {detail_job=job->snapshot();break;}
  in_detail  = true;
  view_mode  = 1;

  if (!detail_job) { detail_back_button->TakeFocus(); return; }

  // Start detail items view at current processing point
  _detail_items_data_source.focused_id  = std::max(0, detail_job->_current_item_index);
  _detail_errors_data_source.focused_id = 0;
  detail_back_button->TakeFocus();
}

void JobListDialog::close_detail() {
  in_detail = false;
  view_mode = 0;
  detail_job.reset();
  rebuild_list();
  _job_list->TakeFocus();
}

void JobListDialog::dismiss_selected() {
  auto focused = _job_data_source.focused_id;
  if (jobs.empty() || focused < 0 || focused >= (int64_t)jobs.size()) return;
  auto& job = jobs[focused];
  // Only dismiss stopped jobs
  if (job->is_stopped()) {
    file_operations().dismiss_job(job->_job_id);
    rebuild_list();
  }
}

void JobListDialog::dismiss_all_clean() {
  auto history = file_operations().get_job_history();
  for (auto& j : history) {
    auto s = j->_state.load();
    if (s == JobState::COMPLETED) {
      file_operations().dismiss_job(j->_job_id);
    }
  }
  rebuild_list();
}

JobListDialog::JobListDialog(std::function<void()> close_dialog) : Dialog(nullptr), close_dialog(close_dialog) {
  ButtonOption ascii_button;
  ascii_button.transform = ascii_button_transform();

  // ── Job list view ──────────────────────────────────────────────────
  button_close       = Button(" Close ", close_dialog, ascii_button);
  button_dismiss_all = Button(" Dismiss All Clean ", [this] { this->dismiss_all_clean(); }, ascii_button);

  _job_data_source.dataset_size = [this]() -> DataSize {
    auto sz = (int64_t)jobs.size();
    return {sz, 0, std::max(int64_t{0}, sz - 1)};
  };
  _job_data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    int64_t old_id = id;
    int64_t max_id = std::max(int64_t{0}, (int64_t)jobs.size() - 1);
    id = std::clamp(id + delta, int64_t{0}, max_id);
    return id != old_id;
  };
  _job_data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _job_data_source.on_event = [this](DSEventContext ctx) -> bool {
    if (ctx.event == Event::Return) {
      open_detail();
      return true;
    }
    return ctx.handled;
  };
  _job_data_source.transform = [this](DSRenderContext& ctx) -> Element {
    if (ctx.id < 0 || ctx.id >= (int64_t)jobs.size()) return text("<invalid>");
    auto& job   = jobs[ctx.id];
    auto  state = job->_state.load();

    const char* type_str = "?";
    switch (job->_type) {
    case JobInstructions::Type::COPY:   type_str = "COPY"; break;
    case JobInstructions::Type::MOVE:   type_str = "MOVE"; break;
    case JobInstructions::Type::DELETE: type_str = "DEL "; break;
    case JobInstructions::Type::ARCHIVE_CREATE: type_str = "ARCH"; break;
    case JobInstructions::Type::MKDIR: type_str = "MKDIR"; break;
    case JobInstructions::Type::RENAME: type_str = "RENAME"; break;
    case JobInstructions::Type::CLIPBOARD: type_str = "CLIP"; break;
    }

    std::string icon    = state_icon(state);
    int items_done      = static_cast<int>(job->_items_done);
    int items_total     = static_cast<int>(job->item_count());
    int errors          = static_cast<int>(job->_error_count);

    std::string duration = "-";
    if (job->_started_time > 0) {
      double end = job->_finished_time > 0 ? job->_finished_time : Perun::now();
      duration   = format_duration(end - job->_started_time);
    }
    std::string size_str = format_bytes(job->_bytes_total);

    std::string detail;
    if (state == JobState::COMPLETED)            detail = std::format("{} files  {}  {}", items_total, size_str, duration);
    else if (state == JobState::COMPLETED_WITH_ERRORS) detail = std::format("{}/{} files  {} errors", items_done, items_total, errors);
    else if (state == JobState::PAUSED)          detail = std::format("{}/{} files  paused", items_done, items_total);
    else if (state == JobState::CANCELLED)       detail = std::format("{}/{} files  cancelled", items_done, items_total);
    else if (state == JobState::RUNNING)         detail = std::format("{}/{} files  running", items_done, items_total);
    else                                         detail = "queued";

    auto row = hbox({
      text(std::format("[#{}] ", job->_job_id)),
      text(std::string(type_str) + "  " + icon + "  "),
      text(detail) | xflex_grow,
    });

    if (ctx.focused) {
      row |= ctx.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _job_data_source.min_y = 5;
  _job_list = clipped_menu(&_job_data_source);

  auto list_view = Container::Vertical({
    Container::Horizontal({button_dismiss_all, button_close}),
    _job_list,
  });

  // ── Detail view ────────────────────────────────────────────────────
  detail_back_button  = Button(" Back ", [this] { this->close_detail(); }, ascii_button);
  detail_close_button = Button(" Close ", close_dialog, ascii_button);

  // Detail items DataSource — shows ALL items; done items are dimmed
  _detail_items_data_source.dataset_size = [this]() -> DataSize {
    if (!detail_job) return {0, 0, 0};
    auto sz = (int64_t)detail_job->_items.size();
    return {sz, 0, std::max(int64_t{0}, sz - 1)};
  };
  _detail_items_data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    if (!detail_job) return false;
    int64_t old_id = id;
    int64_t max_id = std::max(int64_t{0}, (int64_t)detail_job->_items.size() - 1);
    id = std::clamp(id + delta, int64_t{0}, max_id);
    return id != old_id;
  };
  _detail_items_data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _detail_items_data_source.transform = [this](DSRenderContext& ctx) -> Element {
    if (!detail_job || ctx.id < 0 || ctx.id >= (int64_t)detail_job->_items.size()) return text("<invalid>");
    auto& item   = detail_job->_items[ctx.id];
    bool is_done = ctx.id < detail_job->_items_done;

    Element name;
    if (item.type() == boost::filesystem::directory_file) {
      name = text("  / " + item.path_ref().native());
    } else {
      std::string line = "  . " + item.path_ref().native() + "  " + format_bytes(std::max(int64_t{0}, item.size()));
      if (item.symlink_ref()) line += "  -> " + item.symlink_ref()->native();
      name = text(line);
    }
    if (is_done) name |= dim;

    if (ctx.focused) {
      name |= ctx.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      name |= ftxui::focus;
    }
    return name;
  };
  _detail_items_data_source.min_y = 5;
  _detail_items = clipped_menu(&_detail_items_data_source);

  // Detail errors DataSource
  _detail_errors_data_source.dataset_size = [this]() -> DataSize {
    if (!detail_job) return {0, 0, 0};
    auto sz = (int64_t)detail_job->_errors.size();
    return {sz, 0, std::max(int64_t{0}, sz - 1)};
  };
  _detail_errors_data_source.move_id_by = [this](int64_t& id, int64_t delta) -> bool {
    if (!detail_job) return false;
    int64_t old_id = id;
    int64_t max_id = std::max(int64_t{0}, (int64_t)detail_job->_errors.size() - 1);
    id = std::clamp(id + delta, int64_t{0}, max_id);
    return id != old_id;
  };
  _detail_errors_data_source.count_items_before = [](int64_t id) -> int64_t { return id; };
  _detail_errors_data_source.transform = [this](DSRenderContext& ctx) -> Element {
    if (!detail_job || ctx.id < 0 || ctx.id >= (int64_t)detail_job->_errors.size()) return text("<invalid>");
    auto& err = detail_job->_errors[ctx.id];
    std::string warning = err.warning_ref().value_or("unknown error");
    auto row = vbox({
      text("  X " + err.path_ref().native()),
      text("    " + warning) | dim,
    });
    if (ctx.focused) {
      row |= ctx.component_focused ? bgcolor(Color::DarkBlue) : bgcolor(Color::GrayDark);
      row |= ftxui::focus;
    }
    return row;
  };
  _detail_errors_data_source.min_y = 3;
  _detail_errors = clipped_menu(&_detail_errors_data_source);

  auto detail_view = Container::Vertical({
    Container::Horizontal({detail_back_button, detail_close_button}),
    _detail_items,
    _detail_errors,
  });

  // ── Tab to switch views ────────────────────────────────────────────
  tab = Container::Tab({list_view, detail_view}, &view_mode);

  navigation = CatchEvent(tab, [this](Event e) -> bool {
    if (e == keys().key_cancel_dialog) {
      if (in_detail) {
        close_detail();
      } else {
        this->cancel();
      }
      return true;
    }
    // 'd' to dismiss selected job in list view
    if (!in_detail && e == Event::Character('d')) {
      dismiss_selected();
      return true;
    }
    return false;
  });

  renderer = Renderer(navigation, [this]() -> Element {
    rebuild_list();
    if (in_detail && detail_job) {
      return render_detail();
    }
    return render_list();
  });
}

void JobListDialog::cancel() { this->close_dialog(); }

void JobListDialog::OnShow() {
  view_mode = 0;
  in_detail = false;
  detail_job.reset();
  rebuild_list();
}

Element JobListDialog::render_list() {
  auto title = text(" Job History [" + std::to_string(jobs.size()) + "] ") | bold | hcenter;

  auto content = vbox({
    hbox({
      button_dismiss_all->Render() | hcenter | xflex_grow,
      separator(),
      button_close->Render() | hcenter | xflex_grow,
    }),
    separator(),
    jobs.empty() ? (text("  No jobs.") | dim) : _job_list->Render(),
  });

  return window(title, content, BorderStyle::DOUBLE);
}

Element JobListDialog::render_detail() {
  if (!detail_job) return text("No job selected");

  auto  state    = detail_job->_state.load();
  auto  icon     = state_icon(state);
  const char* type_str = "?";
  switch (detail_job->_type) {
  case JobInstructions::Type::COPY:   type_str = "COPY"; break;
  case JobInstructions::Type::MOVE:   type_str = "MOVE"; break;
  case JobInstructions::Type::DELETE: type_str = "DELETE"; break;
  case JobInstructions::Type::ARCHIVE_CREATE: type_str = "ARCHIVE"; break;
  case JobInstructions::Type::MKDIR: type_str = "MKDIR"; break;
  case JobInstructions::Type::RENAME: type_str = "RENAME"; break;
  case JobInstructions::Type::CLIPBOARD: type_str = "CLIPBOARD"; break;
  }

  int items_done  = static_cast<int>(detail_job->_items_done);
  int items_total = static_cast<int>(detail_job->item_count());
  int errors      = static_cast<int>(detail_job->_errors.size());
  int remaining   = items_total - items_done;

  std::string duration = "-";
  if (detail_job->_started_time > 0) {
    double end = detail_job->_finished_time > 0 ? detail_job->_finished_time : Perun::now();
    duration = format_duration(end - detail_job->_started_time);
  }

  auto title_text = std::format(" Job #{} -- {} {} ", detail_job->_job_id, type_str, icon);
  if (errors > 0) title_text += std::format("{} errors ", errors);

  Elements info;
  info.push_back(text(std::format("  Items:   {} total, {} done, {} remaining", items_total, items_done, remaining)));
  info.push_back(text(std::format("  Bytes:   {} / {}", format_bytes(detail_job->_bytes_processed), format_bytes(detail_job->_bytes_total))));
  info.push_back(text(std::format("  Time:    {}", duration)));
  info.push_back(text(std::format("  Errors:  {}", errors)));
  info.push_back(separator());

  // Items section — all items shown; done items are dimmed by transform
  Elements items_section;
  if (detail_job->_details_expired) items_section.push_back(text("Detail expired under history retention limits; summary retained."));
  if (!detail_job->_items.empty()) {
    items_section.push_back(text(std::format("  -- Items ({} total, {} remaining) --", items_total, remaining)) | bold);
    items_section.push_back(_detail_items->Render());
  }

  // Errors section
  Elements error_section;
  if (!detail_job->_errors.empty()) {
    error_section.push_back(text(std::format("  -- Errors ({}) --", errors)) | bold);
    error_section.push_back(_detail_errors->Render());
  }

  auto content = vbox({
    hbox({
      detail_back_button->Render() | hcenter | xflex_grow,
      separator(),
      detail_close_button->Render() | hcenter | xflex_grow,
    }),
    separator(),
    vbox(std::move(info)),
    vbox(std::move(items_section)) | yflex,
    vbox(std::move(error_section)) | yflex,
  });

  return window(text(title_text) | bold | hcenter, content, BorderStyle::DOUBLE);
}

//
// BookmarksDialog
//

}
