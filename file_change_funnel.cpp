#include "commander.hpp"
#include "file_io_jobs.hpp"

#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <boost/filesystem.hpp>

#ifdef __APPLE__

#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <sys/stat.h>

static CFArrayRef getArrayRef(const std::vector<std::string>& strings) {
  std::vector<CFStringRef> string_refs;
  string_refs.reserve(strings.size());
  for (const auto& string : strings) {
    CFStringRef cfStr = CFStringCreateWithCString(kCFAllocatorDefault, string.c_str(), kCFStringEncodingUTF8);
    string_refs.push_back(cfStr);
  }
  CFArrayRef array = CFArrayCreate(kCFAllocatorDefault, reinterpret_cast<const void**>(string_refs.data()), string_refs.size(), &kCFTypeArrayCallBacks);
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
  return DirItemUpdated::Event::Modified;
}

struct FileId {
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
  DirEvents(Filepath where, FileChangeFunnel::Callback cb) : _callback(std::move(cb)) {
    _root = boost::filesystem::canonical(where);

    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagFileEvents;
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
    _dispatch_queue = dispatch_queue_create("file_commander.fsevents", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(_stream, _dispatch_queue);
    if (!FSEventStreamStart(_stream)) {
      stop();
      throw std::runtime_error("FSEventStreamStart failed");
    }
  }

  ~DirEvents() override { stop(); }

  void events_received(ConstFSEventStreamRef sr, size_t num_events, const char** event_paths, const FSEventStreamEventFlags* event_flags, const FSEventStreamEventId* event_ids) {
    UpdatedFiles filtered_events = std::make_unique<std::vector<DirItemUpdated>>();
    filtered_events->reserve(num_events);
    for (int event_index = 0; event_index < static_cast<int>(num_events); event_index++) {
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
    if (!_stream) return;
    FSEventStreamStop(_stream);
    FSEventStreamInvalidate(_stream);
    // Invalidation stops new delivery; drain callbacks before releasing their
    // context or any state owned by this watcher.
    dispatch_sync_f(_dispatch_queue, nullptr, [](void*) {});
    FSEventStreamRelease(_stream);
    _stream = nullptr;
    dispatch_release(_dispatch_queue);
    _dispatch_queue = nullptr;
  }

 private:
  FileId                                _root_id;
  Filepath                              _root;
  FileChangeFunnel::Callback            _callback;
  std::vector<std::string>              _paths_to_watch;
  std::unique_ptr<FSEventStreamContext> _context;
  FSEventStreamRef                      _stream = nullptr;

  dispatch_queue_t _dispatch_queue = nullptr;
  std::mutex   _m;
};

void DirEvents_callback(ConstFSEventStreamRef sr, void* callback_info, size_t num_events, void* event_paths_, const FSEventStreamEventFlags event_flags[], const FSEventStreamEventId event_ids[]) {
  const char** event_paths = reinterpret_cast<const char**>(event_paths_);
  DirEvents*   self        = reinterpret_cast<DirEvents*>(callback_info);
  self->events_received(sr, num_events, event_paths, event_flags, event_ids);
}

std::unique_ptr<FileChangeFunnel> FileChangeFunnel::create(Filepath root, Callback cb) {
  return std::make_unique<DirEvents>(root, std::move(cb));
}

#elif defined(__linux__)

#include <errno.h>
#include <sys/inotify.h>
#include <unistd.h>

#include <array>
#include <chrono>

namespace {

DirItemUpdated::Event from_inotify_mask(uint32_t mask) {
  if (mask & (IN_CREATE | IN_MOVED_TO)) return DirItemUpdated::Event::Created;
  if (mask & (IN_DELETE | IN_MOVED_FROM | IN_DELETE_SELF | IN_MOVE_SELF)) return DirItemUpdated::Event::Removed;
  if (mask & (IN_ATTRIB | IN_MODIFY)) return DirItemUpdated::Event::Modified;
  return DirItemUpdated::Event::Modified;
}

}  // namespace

class LinuxDirEvents : public FileChangeFunnel {
 public:
  LinuxDirEvents(Filepath where, FileChangeFunnel::Callback cb) : _callback(std::move(cb)) {
    _root = boost::filesystem::canonical(where);

    _inotify_fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    if (_inotify_fd < 0) {
      throw std::runtime_error("inotify_init1 failed");
    }

    constexpr uint32_t mask = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MODIFY | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF;
    _watch_fd = inotify_add_watch(_inotify_fd, _root.native().c_str(), mask);
    if (_watch_fd < 0) {
      ::close(_inotify_fd);
      _inotify_fd = -1;
      throw std::runtime_error("inotify_add_watch failed");
    }

    _running.store(true, std::memory_order_relaxed);
    _thread = std::thread([this]() { run(); });
  }

  ~LinuxDirEvents() override {
    stop();
    if (_thread.joinable()) _thread.join();
  }

  void stop() {
    bool expected = true;
    if (!_running.compare_exchange_strong(expected, false)) return;
    if (_watch_fd >= 0 && _inotify_fd >= 0) {
      inotify_rm_watch(_inotify_fd, _watch_fd);
      _watch_fd = -1;
    }
    if (_inotify_fd >= 0) {
      ::close(_inotify_fd);
      _inotify_fd = -1;
    }
  }

 private:
  void run() {
    std::array<char, 16384> buffer{};
    while (_running.load(std::memory_order_relaxed)) {
      const ssize_t length = ::read(_inotify_fd, buffer.data(), buffer.size());
      if (length < 0) {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
          std::this_thread::sleep_for(std::chrono::milliseconds(30));
          continue;
        }
        return;
      }
      if (length == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        continue;
      }

      UpdatedFiles updates = std::make_unique<std::vector<DirItemUpdated>>();
      for (ssize_t i = 0; i < length;) {
        auto* event = reinterpret_cast<const struct inotify_event*>(buffer.data() + i);
        i += sizeof(struct inotify_event) + event->len;

        if (event->len == 0) continue;
        std::string name(event->name);
        if (name.empty() || name == "." || name == "..") continue;
        Filepath changed = _root / name;
        updates->emplace_back(changed.native().c_str(), from_inotify_mask(event->mask));
      }
      if (!updates->empty()) _callback(std::move(updates));
    }
  }

  Filepath                   _root;
  FileChangeFunnel::Callback _callback;
  int                        _inotify_fd = -1;
  int                        _watch_fd   = -1;
  std::atomic<bool>          _running{false};
  std::thread                _thread;
};

std::unique_ptr<FileChangeFunnel> FileChangeFunnel::create(Filepath root, Callback cb) {
  return std::make_unique<LinuxDirEvents>(root, std::move(cb));
}

#else

class NoopDirEvents : public FileChangeFunnel {
 public:
  NoopDirEvents(Filepath where, FileChangeFunnel::Callback cb) {}
  ~NoopDirEvents() override = default;
};

std::unique_ptr<FileChangeFunnel> FileChangeFunnel::create(Filepath root, Callback cb) {
  return std::make_unique<NoopDirEvents>(root, std::move(cb));
}

#endif
