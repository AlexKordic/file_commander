
#include "commander.hpp"

#include <functional>
#include <memory>
#include <mutex>
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
  // TODO: IS release required for each element in string_refs here?
  return CFArrayCreate(kCFAllocatorDefault, reinterpret_cast<const void**>(string_refs.data()), string_refs.size(), nullptr);
}

DirItemUpdated::Event What(FSEventStreamEventFlags f) {
  const bool removed = (f & kFSEventStreamEventFlagItemRemoved) != 0;
  if (!removed && (f & kFSEventStreamEventFlagItemCreated) != 0) return DirItemUpdated::Event::Created;
  if (removed) return DirItemUpdated::Event::Removed;
  if ((f & kFSEventStreamEventFlagItemRenamed) != 0) return DirItemUpdated::Event::Renamed;
  // if((f & kFSEventStreamEventFlagItemModified) != 0) return DirItemUpdated::Event::Modified;
  return DirItemUpdated::Event::Modified;
}

void DirEvents_callback(ConstFSEventStreamRef sr, void* callback_info, size_t num_events, void* event_paths_, const FSEventStreamEventFlags event_flags[], const FSEventStreamEventId event_ids[]);

class DirEvents : public FileChangeFunnel {
 public:
  DirEvents(Filepath where, FileChangeFunnel::Callback cb) : _callback(cb) {
    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagFileEvents;  // | kFSEventStreamCreateFlagNoDefer;

    _root = boost::filesystem::canonical(where);
    _paths_to_watch.push_back(_root.native());
    _context.reset(new FSEventStreamContext{0, this, nullptr, nullptr, nullptr});
    _stream = FSEventStreamCreate(kCFAllocatorDefault, DirEvents_callback, _context.get(), getArrayRef(_paths_to_watch), kFSEventStreamEventIdSinceNow, 0.2, flags);
    if (!_stream) throw std::runtime_error("FSEventStreamCreate failed");
    _runloop_thread = std::thread([this]() {
      // TODO: https://lore.kernel.org/git/de558eb7-8931-a5b5-d711-459ae3f52216@jeffhostetler.com/T/
      _runloop_ref = CFRunLoopGetCurrent();
      FSEventStreamScheduleWithRunLoop(this->_stream, _runloop_ref, kCFRunLoopDefaultMode);
      FSEventStreamStart(this->_stream);
      CFRunLoopRun();
    });
  }
  virtual ~DirEvents() {
    stop();
    if (_runloop_thread.joinable()) _runloop_thread.join();
  }

  void events_received(ConstFSEventStreamRef sr, size_t num_events, const char** event_paths, const FSEventStreamEventFlags* event_flags, const FSEventStreamEventId* event_ids) {
    UpdatedFiles filtered_events = std::make_unique<std::vector<DirItemUpdated>>();
    filtered_events->reserve(num_events);
    std::string const& our_path     = _root.native();
    auto               on_same_path = [&](const char* filename, int& i) {
      const int our_path_len = our_path.size();
      for (; i < our_path_len; i += 1) {
        if (filename[i] == '\0' || filename[i] != our_path[i]) {
          // found end of string or char differs from our path
          return false;
        }
      }
      return true;
    };
    for (int event_index = 0; event_index < num_events; event_index++) {
      const char* filename = event_paths[event_index];
      int         i        = 0;
      if (!on_same_path(filename, i)) { continue; }
      // next char should be /
      if (filename[i++] != '/') { continue; }
      for (;; i += 1) {
        if (filename[i] == '\0') {
          // found end of string before filtering out this item
          filtered_events->emplace_back(filename, What(event_flags[event_index]));
          break;
        }
        if (filename[i] == '/') {
          // found dir separator, filter out this item
          break;
        }
      }
    }
    _callback(std::move(filtered_events));
  }

  void stop() {
    std::lock_guard g(_m);
    if (_stream) {
      FSEventStreamUnscheduleFromRunLoop(_stream, _runloop_ref, kCFRunLoopDefaultMode);
      FSEventStreamStop(_stream);
      FSEventStreamInvalidate(_stream);
      FSEventStreamRelease(_stream);
      CFRunLoopStop(_runloop_ref);
      _stream = nullptr;
    }
  }

  bool valid() { return !!_stream; }

 private:
  Filepath                              _root;
  FileChangeFunnel::Callback            _callback;
  std::vector<std::string>              _paths_to_watch;
  std::unique_ptr<FSEventStreamContext> _context;
  FSEventStreamRef                      _stream;

  std::thread  _runloop_thread;
  CFRunLoopRef _runloop_ref;
  std::mutex   _m;
};

// route events to DirEvents method:
void DirEvents_callback(ConstFSEventStreamRef sr, void* callback_info, size_t num_events, void* event_paths_, const FSEventStreamEventFlags event_flags[], const FSEventStreamEventId event_ids[]) {
  const char** event_paths = reinterpret_cast<const char**>(event_paths_);
  DirEvents*   self        = reinterpret_cast<DirEvents*>(callback_info);
  self->events_received(sr, num_events, event_paths, event_flags, event_ids);
}

std::unique_ptr<FileChangeFunnel> FileChangeFunnel::create(Filepath root, Callback cb) { return std::make_unique<DirEvents>(root, cb); }
