
#include "commander.hpp"
#include "file_io_jobs.hpp"

#include <sys/stat.h>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>  // For std::declval
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
  // Use kCFTypeArrayCallBacks to ensure the array retains/releases its elements
  CFArrayRef array = CFArrayCreate(kCFAllocatorDefault, reinterpret_cast<const void**>(string_refs.data()), string_refs.size(), &kCFTypeArrayCallBacks);
  // Release our ownership of the CFStringRefs
  for (CFStringRef cfStr : string_refs) {
    CFRelease(cfStr);
  }
  return array;
}

DirItemUpdated::Event What(FSEventStreamEventFlags f) {
  const bool removed = (f & kFSEventStreamEventFlagItemRemoved) != 0;
  if (!removed && (f & kFSEventStreamEventFlagItemCreated) != 0) return DirItemUpdated::Event::Created;
  if (removed) return DirItemUpdated::Event::Removed;
  if ((f & kFSEventStreamEventFlagItemRenamed) != 0) return DirItemUpdated::Event::Renamed;
  // if((f & kFSEventStreamEventFlagItemModified) != 0) return DirItemUpdated::Event::Modified;
  return DirItemUpdated::Event::Modified;
}

struct FileId {
  // decltype(std::declval<struct stat>().st_dev) device_id;
  // decltype(std::declval<struct stat>().st_ino) inode_number;
  struct stat _stat;

  bool same_dir(const FileId& other) const { return _stat.st_dev == other._stat.st_dev && _stat.st_ino == other._stat.st_ino; }

  static bool from_filename(FileId& out, const char* filename) {
    const bool err = lstat(filename, &out._stat);
    if (err) { return false; }
    return true;
  }
};

void DirEvents_callback(ConstFSEventStreamRef sr, void* callback_info, size_t num_events, void* event_paths_, const FSEventStreamEventFlags event_flags[], const FSEventStreamEventId event_ids[]);

class DirEvents : public FileChangeFunnel {
 public:
  DirEvents(Filepath where, FileChangeFunnel::Callback cb) : _callback(cb) {
    _root = boost::filesystem::canonical(where);

    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagFileEvents;  // | kFSEventStreamCreateFlagNoDefer;
    if (!FileId::from_filename(_root_id, _root.native().c_str())) {
      auto msg = "our dir lstat failed " + std::to_string(errno) + " " + _root.native();
      Perun::file_operations().report_error(msg);
      throw std::runtime_error(msg);
    }
    _paths_to_watch.push_back(_root.native());
    _context.reset(new FSEventStreamContext{0, this, nullptr, nullptr, nullptr});
    CFArrayRef pathsArray = getArrayRef(_paths_to_watch);
    _stream = FSEventStreamCreate(kCFAllocatorDefault, DirEvents_callback, _context.get(), pathsArray, kFSEventStreamEventIdSinceNow, 0.2, flags);
    CFRelease(pathsArray);
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
    for (int event_index = 0; event_index < num_events; event_index++) {
      // Using parent dir to identify items in our watched dir
      Filepath    signaled_path(event_paths[event_index]);
      std::string parent_dir = signaled_path.parent_path().native();
      FileId      parent_dir_id;
      if (!FileId::from_filename(parent_dir_id, parent_dir.c_str())) { continue; }
      const bool same_dir = parent_dir_id.same_dir(_root_id);
      if (!same_dir) { continue; }
      filtered_events->emplace_back(event_paths[event_index], What(event_flags[event_index]));
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
  FileId                                _root_id;
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
