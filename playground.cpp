
#include <cstdint>
#include <ftxui/dom/linear_gradient.hpp>
#include <ftxui/screen/color.hpp>

#include <boost/filesystem.hpp>
// #include "boost/filesystem/directory.hpp"
// #include "boost/filesystem/path.hpp"

#include "boost/filesystem/operations.hpp"
#include "ftxui/component/component.hpp"
#include "ftxui/component/component_base.hpp"
#include "ftxui/component/component_options.hpp"
#include "ftxui/component/screen_interactive.hpp"
#include "ftxui/dom/elements.hpp"

#include <functional>
#include <iostream>
#include <string>
#include <thread>
#include <utility>

namespace ftxui {

// Helper class.
class NodeDecorator : public Node {
 public:
  explicit NodeDecorator(Element child) : Node({std::move(child)}) {}
  void ComputeRequirement() override {
    Node::ComputeRequirement();
    requirement_ = children_[0]->requirement();
  }
  void SetBox(Box box) override {
    Node::SetBox(box);
    children_[0]->SetBox(box);
  }
};

class ShowInputCursor : public NodeDecorator {
 public:
  ShowInputCursor(Element child, Ref<int> cursor_position) : NodeDecorator(std::move(child)), _cursor_position(cursor_position) {}

  void Render(Screen& screen) override {
    const bool draw_cursor = true;
    // TODO: animate blinking by toggling draw_cursor
    if (draw_cursor) {
      int x = std::max(box_.x_min, std::min(box_.x_max, box_.x_min + _cursor_position()));
      for (int y = box_.y_min; y <= box_.y_max; ++y) { screen.PixelAt(x, y).inverted = !screen.PixelAt(x, y).inverted; }
    }
    NodeDecorator::Render(screen);
  }

  Ref<int> _cursor_position;
};

Element   showInputCursor(Element child, Ref<int> cursor_position) { return std::make_shared<ShowInputCursor>(std::move(child), cursor_position); }
Decorator showInputCursor(Ref<int> cursor_position) {
  return [cursor_position](Element child) -> Element { return showInputCursor(std::move(child), cursor_position); };
}

}  // namespace ftxui

using namespace ftxui;

struct Item {
  std::string content;
  int         cursor_position = 0;

  Item(const char* s) : content(s) {}
};

int main_multicursor() {
  // Lines we want to display, each in its own Input
  // clang-format off
  std::vector<Item> lines = {
    R"(#include ftxui/component/captured_mouse.hpp"  // for ftxui)",
    R"(#include ftxui/component/component.hpp"  // for Radiobox, Vertical, Checkbox, Horizontal, Renderer, ResizableSplitBottom, ResizableSplitRight)",
    R"(#include ftxui/component/component_base.hpp"      // for ComponentBase)",
    R"(#include ftxui/component/screen_interactive.hpp"  // for ScreenInteractive)",
    R"(#include ftxui/dom/elements.hpp"  // for text, window, operator|, vbox, hbox, Element, flexbox, bgcolor, filler, flex, size, border, hcenter, color, EQUAL, bold, dim, notflex, xflex_grow, yflex_grow, HEIGHT, WIDTH)",
    R"(#include ftxui/dom/flexbox_config.hpp"  // for FlexboxConfig, FlexboxConfig::AlignContent, FlexboxConfig::JustifyContent, FlexboxConfig::AlignContent::Center, FlexboxConfig::AlignItems, FlexboxConfig::Direction, FlexboxConfig::JustifyContent::Center, FlexboxConfig::Wrap)",
    R"(#include ftxui/screen/color.hpp"        // for Color, Color::Black)",
  };
  // clang-format on
  int  selected          = 0;
  auto menu              = Container::Vertical({}, &selected);
  auto menu_event_filter = [&selected, menu](Event event) -> bool {
    if (event == Event::ArrowUp || (event.is_mouse() && event.mouse().button == Mouse::WheelUp)) {
      selected = std::max(0, selected - 1);
      return true;
    }
    if (event == Event::ArrowDown || (event.is_mouse() && event.mouse().button == Mouse::WheelDown)) {
      selected = std::min((int)menu->ChildCount() - 1, selected + 1);
      return true;
    }
    bool any = false;
    int  c   = menu->ChildCount();
    for (int i = 0; i < c; i++) { any |= menu->ChildAt(i)->OnEvent(event); }
    return any;
  };
  for (int i = 0; i < lines.size(); i++) {
    InputOption style;
    style.content         = &(lines.at(i).content);
    style.multiline       = false;
    style.placeholder     = "";
    style.cursor_position = &(lines.at(i).cursor_position);
    Component txt         = Input(style) | showInputCursor(&(lines.at(i).cursor_position));
    menu->Add(txt);
  }
  auto renderer = Renderer(CatchEvent(menu, menu_event_filter), [&] {
    return vbox({
             menu->Render() | frame | size(HEIGHT, LESS_THAN, 5),
           })
      | border;
  });
  auto screen   = ScreenInteractive::TerminalOutput();
  screen.Loop(renderer);
  return 0;
}

using namespace boost::filesystem;
using boost::system::error_code;

double now() {
  const std::chrono::time_point<std::chrono::system_clock> now = std::chrono::system_clock::now();
  return now.time_since_epoch().count() / 1000000.0;
}

// 
// Calculate progress and throughput
//
struct ProgressTimer {
  int64_t current_size = 0;
  double  start_ts     = now();
  double  last_ts      = now();

  float Mbps       = 0;
  float final_Mbps = 0;
  float percentage = 0;

  bool update(int64_t new_size, int64_t source_size) {
    if (new_size == current_size) return false;
    double ts    = now();
    Mbps         = ((current_size - new_size) * 8 / 1000000.0) / (last_ts - ts);
    current_size = new_size;
    last_ts      = ts;
    percentage   = 100 * float(current_size) / source_size;
    final_Mbps   = (current_size * 8 / 1000000.0) / (last_ts - start_ts);
    return true;
  }
};

//
// Run periodic check for file size while copy operation is ongoing
//
class SizeMonitor {
 public:
  SizeMonitor(int64_t source_size, boost::filesystem::path destination) {
    this->source_size = source_size;
    this->destination = destination;
    thread = std::thread([this]() { this->run(); });
  }
  void stop() {
    running = false;
    this->thread.join();
  }

 protected:
  std::thread   thread;
  volatile bool running = true;
  int64_t       source_size;

  boost::filesystem::path destination;

  void run() {
    auto          sleep = [&]() { std::this_thread::sleep_for(std::chrono::milliseconds(16)); };
    error_code    ec;
    ProgressTimer progress;
    while (running) {
      int64_t latest_size = file_size(destination, ec);
      if (ec.failed()) {
        // Expect `system:2` error on first call to file_size as this thread is started before copy operation
        std::cout << "Thread Error: file_size(" << destination.native() << ") " << ec.to_string() << std::endl;
        sleep();
        continue;
      }
      if (!progress.update(latest_size, source_size)) {
        // Expect same size on second call to file_size as data is about to be flushed to disk
        std::cout << "Thread: same size " << progress.current_size << std::endl;
        sleep();
        continue;
      }
      std::cout << "Thread: size " << progress.current_size << " progress: " << progress.percentage << " Mbps=" << progress.Mbps << std::endl;
      sleep();
    }
    progress.update(source_size, source_size);
    // Expect slight calculation error for final_Mbps as sleep() above was not interrupted
    std::cout << "Final Mbps=" << progress.final_Mbps << " time=" << (progress.last_ts - progress.start_ts) << std::endl;
  }
};

//
// Create file copy monitor then run copy operation
// In an UI application this thread shouldn't be main thread and SizeMonitor::run should post updates on main thread
//
int main_filecopy_progress() {
  boost::filesystem::path source("/Users/alexkordic/Downloads/Jerry.and.Marge.Go.Large.2022.1080p.AMZN.WEB-DL.DDP5.1.H264-CM.mkv");
  boost::filesystem::path destination("_test_large_file.mkv");
  // stat source file
  error_code              ec;
  if (false == exists(source, ec) || ec.failed()) {
    std::cout << "Error: source file missing, " << source.native() << std::endl;
    return -1;
  }
  int64_t source_size = file_size(source, ec);
  if (ec.failed()) {
    std::cout << "Error: file_size(" << source.native() << ") " << ec.to_string() << std::endl;
    return -1;
  }
  // delete leftover dest file from previous run, ignore if it fails
  remove(destination, ec);
  // start monitor thread
  SizeMonitor  print_progress(source_size, destination);
  // copy file
  copy_options op     = copy_options::overwrite_existing;
  const bool   status = copy_file(source, destination, op, ec);
  std::cout << "status=" << status << " ec=" << ec.to_string() << std::endl;
  // join monitor thread
  print_progress.stop();
  // delete leftover dest file
  remove(destination, ec);
  return 0;
}

int main() {
  // return main_multicursor();
  return main_filecopy_progress();
}
