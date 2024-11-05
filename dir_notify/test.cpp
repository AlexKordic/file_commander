
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <ostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <CoreServices/CoreServices.h>

#include <boost/filesystem.hpp>

static CFArrayRef getArrayRef(const std::vector<std::string>& strings) {
  std::vector<CFStringRef> string_refs;
  string_refs.reserve(strings.size());
  for (const auto& string : strings) {
    CFStringRef cfStr = CFStringCreateWithCString(kCFAllocatorDefault, string.c_str(), kCFStringEncodingUTF8);
    string_refs.push_back(cfStr);
  }
  return CFArrayCreate(kCFAllocatorDefault, reinterpret_cast<const void**>(string_refs.data()), string_refs.size(), nullptr);
}

struct FSEvent {
  boost::filesystem::path path;
  FSEventStreamEventFlags flag;
  FSEventStreamEventId    id;

  FSEvent(const char* p, int len, FSEventStreamEventFlags f, FSEventStreamEventId i) : path(std::string(p, len)), flag(f), id(i) {}
};

void DirEvents_callback(ConstFSEventStreamRef sr, void* callback_info, size_t num_events, void* event_paths_, const FSEventStreamEventFlags event_flags[], const FSEventStreamEventId event_ids[]);

class DirEvents {
 public:
  using Callback = std::function<void(const std::vector<FSEvent>& e)>;

  DirEvents(boost::filesystem::path where, Callback cb) : _callback(cb) {
    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagFileEvents;  // | kFSEventStreamCreateFlagNoDefer;

    _root = boost::filesystem::canonical(where);
    _paths_to_watch.push_back(_root.native());
    _context.reset(new FSEventStreamContext{0, this, nullptr, nullptr, nullptr});
    _stream = FSEventStreamCreate(kCFAllocatorDefault, DirEvents_callback, _context.get(), getArrayRef(_paths_to_watch), kFSEventStreamEventIdSinceNow, 0.2, flags);
    if(!_stream) throw std::runtime_error("FSEventStreamCreate failed");
    _runloop_thread = std::thread([this](){
      // https://lore.kernel.org/git/de558eb7-8931-a5b5-d711-459ae3f52216@jeffhostetler.com/T/
      FSEventStreamScheduleWithRunLoop(this->_stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
      FSEventStreamStart(this->_stream);
      CFRunLoopRun();
    });
  }
  ~DirEvents() {
    stop();
    if(_runloop_thread.joinable()) _runloop_thread.join();
    // dispatch_release(_queue);
  }

  void events_received(ConstFSEventStreamRef sr, size_t num_events, const char** event_paths, const FSEventStreamEventFlags* event_flags, const FSEventStreamEventId* event_ids) {
    std::vector<FSEvent> filtered_events;
    filtered_events.reserve(num_events);
    std::string const & our_path = _root.native();
    auto on_same_path = [&](const char * filename, int& i){
      const int our_path_len = our_path.size();
      for(; i < our_path_len ; i += 1) {
        if(filename[i] == '\0' || filename[i] != our_path[i]) {
          // found end of string or char differs from our path
          return false;
        }
      }
      return true;
    };
    for (int event_index = 0; event_index < num_events; event_index++) {
      const char * filename = event_paths[event_index];
      int i = 0;
      if(!on_same_path(filename, i)) {
        std::cout << "[filtered] NOT on same path at " << i << " item=" << filename << std::endl;
        continue;
      }
      // next char should be /
      if(filename[i++] != '/') {
        std::cout << "[filtered] expected / to follow at " << i -1 << " item=" << filename << std::endl;
        continue;
      }
      for(; ; i += 1) {
        if(filename[i] == '\0') {
          // found end of string before filtering out this item
          std::cout << "[accepted] item=" << filename << std::endl;
          filtered_events.emplace_back(filename, i, event_flags[event_index], event_ids[event_index]);
          break;
        }
        if(filename[i] == '/') {
          // found dir separator, filter out this item
          std::cout << "[filtered] item is in subdir, / found at " << i << " item=" << filename << std::endl;
          break;
        }
      }
    }
    _callback(filtered_events);
  }

  void run() {
    // FSEventStreamScheduleWithRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    // FSEventStreamStart(_stream);
    // CFRunLoopRun();
    // // // dispatch_main();
    // FSEventStreamFlushSync https://developer.apple.com/documentation/coreservices/1445629-fseventstreamflushsync
    _runloop_thread.join();
  }

  void stop() {
    std::lock_guard g(_m);
    if (_stream) {
      FSEventStreamUnscheduleFromRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
      FSEventStreamStop(_stream);
      FSEventStreamInvalidate(_stream);
      FSEventStreamRelease(_stream);
      _stream = nullptr;
    }
  }

  bool valid() { return !!_stream; }

 private:
  boost::filesystem::path               _root;
  Callback _callback;
  std::vector<std::string>              _paths_to_watch;
  std::unique_ptr<FSEventStreamContext> _context;
  FSEventStreamRef                      _stream;

  std::thread _runloop_thread;
  std::mutex _m;
  // dispatch_queue_t _queue;
};

// route events to DirEvents method:
void DirEvents_callback(ConstFSEventStreamRef sr, void* callback_info, size_t num_events, void* event_paths_, const FSEventStreamEventFlags event_flags[], const FSEventStreamEventId event_ids[]) {
  const char** event_paths = reinterpret_cast<const char**>(event_paths_);
  DirEvents* self = reinterpret_cast<DirEvents*>(callback_info);
  self->events_received(sr, num_events, event_paths, event_flags, event_ids);
}

int main() {
  std::unique_ptr<std::function<void()>> do_exit;
  auto callback = [&](const std::vector<FSEvent>& batch) {
    const size_t count = batch.size();
    for (size_t i = 0; i < count; ++i) {
      FSEvent const &    ev      = batch.at(i);
      if(ev.path.native().find("exit") != std::string::npos) {
        (*do_exit)();
      }
      // const auto flags   = event_flags[i];
      const bool removed = (ev.flag & kFSEventStreamEventFlagItemRemoved) != 0;
      if (!removed && (ev.flag & kFSEventStreamEventFlagItemCreated) != 0) {
        std::cout << " created: " << ev.path.native() << std::endl;
        continue;  // we dont care for modified and attribute change for same item
      }
      if (removed) {
        std::cout << " removed: " << ev.path.native() << std::endl;
        continue;
      }
      if ((ev.flag & kFSEventStreamEventFlagItemRenamed) != 0) {
        std::cout << " renamed: " << ev.path.native() << std::endl;
        continue;
      }
      if ((ev.flag & kFSEventStreamEventFlagItemModified) != 0) {
        std::cout << " modified: " << ev.path.native() << std::endl;
        continue;
      }
      if ((ev.flag & kFSEventStreamEventFlagItemChangeOwner) != 0) {
        std::cout << " attributes: " << ev.path.native() << std::endl;
        continue;
      }
      if ((ev.flag & kFSEventStreamEventFlagItemCloned) != 0) {
        std::cout << " cloned: " << ev.path.native() << std::endl;
        continue;
      }
      std::cout << " ????: " << ev.path.native() << std::endl;
    }
  };
  DirEvents ev(boost::filesystem::current_path(), callback);
  DirEvents ev2(boost::filesystem::current_path() / "fcfcfc", callback);
  do_exit = std::make_unique<std::function<void()>>([&](){
    ev.stop();
  });
  ev.run();
}
