#include "remote_stream.hpp"
#include "remote_transport.hpp"
#include "sha256.hpp"
#include <condition_variable>
#include <deque>
#include <map>
#include <thread>
#include <sys/stat.h>

namespace RemoteFS {
namespace j = boost::json;
namespace {
uint64_t number(const j::object &o, const char *key) {
  auto at = o.find(key); return at == o.end() ? 0 : at->value().to_number<uint64_t>();
}
struct Budget {
  std::mutex mutex;
  std::condition_variable cv;
  size_t used = 0;
  std::atomic<bool> stopped{false};
  bool reserve(size_t n) {
    std::unique_lock lock(mutex);
    cv.wait(lock, [&] { return stopped || used + n <= 32 * Wire::block_size; });
    if (stopped) return false;
    used += n; return true;
  }
  void release(size_t n) { std::lock_guard lock(mutex); used -= n; cv.notify_all(); }
};
struct LocalSink;
struct Peer;
struct Descriptor {
  int fd = -1;
  explicit Descriptor(int fd) : fd(fd) {
    if (fd < 0) throw std::system_error(errno, std::generic_category());
  }
  ~Descriptor() { if (fd >= 0) ::close(fd); }
};
j::object descriptor_stamp(int fd) {
  struct stat s{};
  if (fstat(fd, &s)) throw std::system_error(errno, std::generic_category());
  Metadata m;
  m.exists = true; m.dev = s.st_dev; m.ino = s.st_ino; m.mode = s.st_mode;
  m.uid = s.st_uid; m.gid = s.st_gid; m.size = s.st_size;
#if defined(__APPLE__)
  m.mtime_ns = int64_t(s.st_mtimespec.tv_sec) * 1000000000 + s.st_mtimespec.tv_nsec;
  m.ctime_ns = int64_t(s.st_ctimespec.tv_sec) * 1000000000 + s.st_ctimespec.tv_nsec;
#else
  m.mtime_ns = int64_t(s.st_mtim.tv_sec) * 1000000000 + s.st_mtim.tv_nsec;
  m.ctime_ns = int64_t(s.st_ctim.tv_sec) * 1000000000 + s.st_ctim.tv_nsec;
#endif
  return m.stamp();
}
} // namespace
struct StreamFile::Impl {
  Filepath source, stage;
  Metadata expected;
  std::shared_ptr<Budget> budget;
  std::mutex mutex;
  std::condition_variable cv;
  std::deque<std::string> blocks;
  std::string source_digest;
  bool source_done = false, sink_done = false, server_copy = false;
  std::exception_ptr failure;
  std::atomic<uint64_t> sent{0}, written{0}, verified{0}, durable{0}, flushes{0};
  Peer *sink_peer = nullptr;
  uint64_t sink_id = 0;
  std::unique_ptr<LocalSink> local_sink;
  ~Impl();
  void fail(std::exception_ptr e) {
    std::lock_guard lock(mutex); if (!failure) failure = e; cv.notify_all();
  }
  void check() const {
    if (failure) std::rethrow_exception(failure); // mutex held
    if (budget->stopped) throw ConnectionError("Transfer interrupted; Resume requires validation");
  }
  void push(std::string block) {
    if (!budget->reserve(block.size())) return;
    std::lock_guard lock(mutex); blocks.push_back(std::move(block)); cv.notify_all();
  }
};
namespace {
struct LocalSink {
  StreamFile::Impl &file;
  Descriptor descriptor;
  std::mutex io_mutex;
  std::condition_variable cv;
  std::mutex mutex;
  bool ended = false, stopped = false;
  std::string expected_digest;
  j::object end_stamp;
  std::thread worker;
  explicit LocalSink(StreamFile::Impl &file)
      : file(file), descriptor(::open(file.stage.c_str(), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)),
        worker([this] { verify(); }) {}
  ~LocalSink() { stop(); if (worker.joinable()) worker.join(); }
  void stop() { std::lock_guard lock(mutex); stopped = true; cv.notify_all(); }
  void write(std::string_view bytes) {
    std::lock_guard io(io_mutex);
    { std::lock_guard lock(file.mutex); file.check(); }
    auto offset = file.written.load();
    if (bytes.size() > uint64_t(file.expected.size) - offset)
      throw std::runtime_error("Stream exceeds expected file length");
    while (!bytes.empty()) {
      auto n = ::pwrite(descriptor.fd, bytes.data(), bytes.size(), off_t(offset));
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) throw std::system_error(n < 0 ? errno : EIO, std::generic_category());
      offset += n; bytes.remove_prefix(n);
    }
    { std::lock_guard lock(mutex); file.written = offset; cv.notify_all(); }
  }
  void end(std::string hash) {
    std::lock_guard lock(mutex);
    expected_digest = std::move(hash); end_stamp = descriptor_stamp(descriptor.fd); ended = true; cv.notify_all();
  }
  void verify() {
    try {
      Sha256 hash;
      std::string buffer(Wire::block_size, '\0');
      for (;;) {
        std::unique_lock lock(mutex);
        cv.wait(lock, [&] { return stopped || file.budget->stopped || ended || file.written > file.verified; });
        if (stopped || file.budget->stopped) return;
        auto written = file.written.load(); auto finished = ended;
        lock.unlock();
        while (file.verified < written) {
          auto offset = file.verified.load();
          auto n = ::pread(descriptor.fd, buffer.data(), std::min<uint64_t>(buffer.size(), written - offset), off_t(offset));
          if (n < 0 && errno == EINTR) continue;
          if (n <= 0) throw std::system_error(n < 0 ? errno : EIO, std::generic_category(), "Destination readback failed");
          hash.update(std::string_view(buffer.data(), n)); file.verified += n;
        }
        if (finished) {
          if (written != uint64_t(file.expected.size) || hash.finish_raw() != expected_digest)
            throw std::runtime_error("Transfer digest mismatch; destination was not published");
          if (!file.flushes || file.durable != written) {
            if (::fsync(descriptor.fd)) throw std::system_error(errno, std::generic_category());
            ++file.flushes;
          }
          file.durable = written;
          if (descriptor_stamp(descriptor.fd) != end_stamp || inspect(file.stage).stamp() != end_stamp)
            throw std::runtime_error("Staging file changed during verification");
          std::lock_guard done(file.mutex); file.sink_done = true; file.cv.notify_all(); return;
        }
        if (written - file.durable >= uint64_t(1024) * 1024 * 1024) {
          if (::fsync(descriptor.fd)) throw std::system_error(errno, std::generic_category());
          ++file.flushes; file.durable = written;
        }
      }
    } catch (...) { file.fail(std::current_exception()); }
  }
};
struct Peer {
  detail::Transport transport;
  std::shared_ptr<Budget> budget;
  std::mutex send_mutex, mutex;
  std::map<uint64_t, std::shared_ptr<StreamFile::Impl>> files;
  std::thread receiver;
  std::exception_ptr failure;
  uint64_t sequence = 0;
  uint16_t operation;
  Peer(const std::string &host, uint16_t operation, std::shared_ptr<Budget> budget)
      : budget(std::move(budget)), operation(operation) {
    transport.unlimited_idle = true;
    transport.start(host, &this->budget->stopped);
    receiver = std::thread([this] { receive(); });
  }
  ~Peer() { if (receiver.joinable()) receiver.join(); }
  void send(uint8_t kind, uint16_t operation, uint64_t id, std::string_view payload) {
    std::lock_guard lock(send_mutex);
    transport.frame(kind, operation, id, payload, &budget->stopped);
  }
  uint64_t add(const std::shared_ptr<StreamFile::Impl> &file, j::object parameters) {
    uint64_t id;
    { std::lock_guard lock(mutex);
      if (failure) std::rethrow_exception(failure);
      id = ++sequence; files.emplace(id, file);
    }
    send(Wire::Request, operation, id, Wire::encode(parameters)); return id;
  }
  void control(const StreamControl &state) {
    send(Wire::Request, Wire::opcode("stream_control"), 0,
         Wire::encode(j::object{{"rate", state.rate}, {"paused", state.paused}, {"cancelled", state.cancelled}}));
  }
  void receive() {
    try {
      while (!budget->stopped) {
        auto frame = transport.receive(&budget->stopped);
        std::shared_ptr<StreamFile::Impl> file;
        { std::lock_guard lock(mutex);
          auto at = files.find(frame.id);
          if (at == files.end() || frame.operation != operation) throw ConnectionError("Unknown SSH stream response");
          file = at->second;
        }
        if (frame.kind == Wire::Data && operation == Wire::opcode("stream_read")) {
          if (frame.payload.empty()) throw ConnectionError("Empty SSH data frame");
          file->push(std::move(frame.payload)); continue;
        }
        auto value = Wire::decode(frame.payload).as_object();
        if (frame.kind == Wire::Error) {
          file->fail(std::make_exception_ptr(std::system_error(int(number(value, "errno")),
                     std::generic_category(), std::string(value.at("message").as_string()))));
        } else if (operation == Wire::opcode("stream_read") && frame.kind == Wire::Result) {
          std::lock_guard lock(file->mutex);
          file->source_digest = value.at("sha256").as_string();
          if (file->source_digest.size() != 32 || number(value, "bytes") != uint64_t(file->expected.size))
            throw ConnectionError("Invalid SSH source digest or length");
          file->source_done = true; file->cv.notify_all();
        } else if (frame.kind == Wire::Event || frame.kind == Wire::Result) {
          auto written = number(value, "bytes"), verified = number(value, "verified"), durable = number(value, "durable");
          if (written > uint64_t(file->expected.size) || verified > written || durable > written)
            throw ConnectionError("Invalid SSH stream progress");
          file->written = std::max(file->written.load(), written);
          file->verified = std::max(file->verified.load(), verified);
          file->durable = std::max(file->durable.load(), durable); file->flushes = number(value, "flushes");
          if (file->server_copy) file->sent = file->written.load();
          { std::lock_guard lock(file->mutex);
            if (file->server_copy && value.contains("phase") && value.at("phase") == "written") file->source_done = true;
            file->cv.notify_all();
          }
          if (frame.kind == Wire::Result) {
            if (written != uint64_t(file->expected.size) || verified != written || durable != written)
              throw ConnectionError("Incomplete SSH verification result");
            std::lock_guard lock(file->mutex); file->sink_done = true; file->cv.notify_all();
          }
        } else throw ConnectionError("Unexpected SSH stream frame");
        if (frame.kind == Wire::Result || frame.kind == Wire::Error) {
          std::lock_guard lock(mutex); files.erase(frame.id);
        }
      }
    } catch (...) {
      std::lock_guard lock(mutex);
      failure = std::current_exception();
      for (auto &[id, file] : files) file->fail(failure);
    }
  }
};
} // namespace
StreamFile::Impl::~Impl() { local_sink.reset(); }
StreamFile::StreamFile(std::shared_ptr<Impl> value) : impl(std::move(value)) {}
StreamProgress StreamFile::progress() const {
  return {impl->sent, impl->written, impl->verified, impl->durable, impl->flushes};
}
bool StreamFile::ready() const { std::lock_guard lock(impl->mutex); return impl->sink_done || bool(impl->failure); }
void StreamFile::wait() const {
  std::unique_lock lock(impl->mutex);
  impl->cv.wait(lock, [&] { return impl->sink_done || impl->failure || impl->budget->stopped; });
  impl->check();
}
struct StreamSession::Impl {
  std::shared_ptr<Budget> budget = std::make_shared<Budget>();
  std::function<StreamControl()> control;
  std::mutex peers_mutex, files_mutex, source_mutex, control_mutex;
  std::condition_variable source_cv, control_cv;
  std::map<std::pair<std::string, uint16_t>, std::unique_ptr<Peer>> peers;
  std::vector<std::weak_ptr<StreamFile::Impl>> files;
  std::deque<std::shared_ptr<StreamFile::Impl>> sources;
  std::thread source_worker, control_worker;
  explicit Impl(std::function<StreamControl()> c) : control(std::move(c)),
      source_worker([this] { read_local(); }), control_worker([this] { monitor(); }) {}
  ~Impl() { cancel(); source_worker.join(); control_worker.join(); peers.clear(); }
  void cancel() {
    { std::lock_guard lock(budget->mutex); budget->stopped = true; budget->cv.notify_all(); }
    { std::lock_guard lock(source_mutex); source_cv.notify_all(); }
    { std::lock_guard lock(control_mutex); control_cv.notify_all(); }
    std::lock_guard lock(files_mutex);
    for (auto &weak : files) if (auto f = weak.lock()) {
      { std::lock_guard guard(f->mutex); f->cv.notify_all(); }
      if (f->local_sink) f->local_sink->stop();
    }
  }
  Peer &peer(const std::string &host, uint16_t operation) {
    std::lock_guard lock(peers_mutex);
    auto &p = peers[{host, operation}];
    if (!p) {
      p = std::make_unique<Peer>(host, operation, budget);
      if (control && operation == Wire::opcode("stream_copy")) p->control(control());
    }
    return *p;
  }
  void monitor() {
    StreamControl previous;
    try {
      while (!budget->stopped) {
        if (control) {
          auto state = control();
          if (state.cancelled) { cancel(); return; }
          if (state != previous) {
            std::lock_guard lock(peers_mutex);
            for (auto &[key, p] : peers) if (key.second == Wire::opcode("stream_copy")) p->control(state);
            previous = state;
          }
        }
        std::unique_lock lock(control_mutex);
        control_cv.wait_for(lock, std::chrono::milliseconds(50), [&] { return budget->stopped.load(); });
      }
    } catch (...) {
      std::lock_guard lock(files_mutex);
      for (auto &weak : files) if (auto f = weak.lock()) f->fail(std::current_exception());
    }
  }
  void read_local() {
    while (!budget->stopped) {
      std::shared_ptr<StreamFile::Impl> file;
      { std::unique_lock lock(source_mutex);
        source_cv.wait(lock, [&] { return budget->stopped || !sources.empty(); });
        if (budget->stopped) return;
        file = sources.front(); sources.pop_front();
      }
      try {
        Descriptor fd(::open(file->source.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
        const auto expected = file->expected.stamp();
        if (descriptor_stamp(fd.fd) != expected || inspect(file->source).stamp() != expected)
          throw std::runtime_error("Source changed before streaming");
        Sha256 hash;
        uint64_t offset = 0;
        while (offset < uint64_t(file->expected.size) && !budget->stopped) {
          std::string bytes(std::min<uint64_t>(Wire::block_size, file->expected.size - offset), '\0');
          auto n = ::read(fd.fd, bytes.data(), bytes.size());
          if (n < 0 && errno == EINTR) continue;
          if (n <= 0) throw std::system_error(n < 0 ? errno : EIO, std::generic_category(), "Source read failed");
          bytes.resize(n); hash.update(bytes); offset += n; file->push(std::move(bytes));
        }
        if (descriptor_stamp(fd.fd) != expected || inspect(file->source).stamp() != expected)
          throw std::runtime_error("Source changed while streaming");
        std::lock_guard lock(file->mutex);
        file->source_digest = hash.finish_raw(); file->source_done = true; file->cv.notify_all();
      } catch (...) { file->fail(std::current_exception()); }
    }
  }
};
StreamSession::StreamSession(std::function<StreamControl()> c) : impl(std::make_unique<Impl>(std::move(c))) {}
StreamSession::~StreamSession() = default;
void StreamSession::cancel() { impl->cancel(); }
std::shared_ptr<StreamFile> StreamSession::prepare(const Filepath &source, const Filepath &stage, const Metadata &expected) {
  if (!expected.exists || !S_ISREG(expected.mode) || expected.size < 0) throw std::runtime_error("Expected a regular source file");
  auto file = std::make_shared<StreamFile::Impl>();
  file->source = source; file->stage = stage; file->expected = expected; file->budget = impl->budget;
  auto left = Location::decode(source.native()), right = Location::decode(stage.native());
  if (left.remote() && right.remote() && left.ssh == right.ssh) {
    file->server_copy = true;
    auto p = params(stage); p["source"] = left.local.native(); p["expected"] = expected.stamp(); p["size"] = expected.size;
    file->sink_peer = &impl->peer(right.ssh, Wire::opcode("stream_copy"));
    file->sink_id = file->sink_peer->add(file, std::move(p));
  } else {
    if (right.remote()) {
      auto p = params(stage); p["size"] = expected.size;
      file->sink_peer = &impl->peer(right.ssh, Wire::opcode("stream_write"));
      file->sink_id = file->sink_peer->add(file, std::move(p));
    } else file->local_sink = std::make_unique<LocalSink>(*file);
    if (left.remote()) {
      auto p = params(source); p["expected"] = expected.stamp();
      impl->peer(left.ssh, Wire::opcode("stream_read")).add(file, std::move(p));
    } else {
      std::lock_guard lock(impl->source_mutex); impl->sources.push_back(file); impl->source_cv.notify_all();
    }
  }
  { std::lock_guard lock(impl->files_mutex);
    if (impl->files.size() > 1024) std::erase_if(impl->files, [](const auto &p) { return p.expired(); });
    impl->files.push_back(file);
  }
  return std::shared_ptr<StreamFile>(new StreamFile(std::move(file)));
}
void StreamSession::transfer(const std::shared_ptr<StreamFile> &handle, const std::function<void(uint64_t)> &progress) {
  auto &file = *handle->impl;
  if (file.server_copy) {
    // The copy worker on the host consumes its queued files continuously. Its
    // data stream does not wait for this coordinator or a verification result.
    std::unique_lock lock(file.mutex);
    while (!file.source_done && !file.sink_done && !file.failure && !file.budget->stopped) {
      auto sent = file.sent.load();
      lock.unlock(); if (progress) progress(sent); lock.lock();
      file.cv.wait(lock, [&] { return file.sent != sent || file.source_done || file.sink_done || file.failure || file.budget->stopped; });
    }
    file.check(); return;
  }
  for (;;) {
    std::string bytes, digest;
    { std::unique_lock lock(file.mutex);
      file.cv.wait(lock, [&] { return !file.blocks.empty() || file.source_done || file.failure || file.budget->stopped; });
      file.check();
      if (!file.blocks.empty()) { bytes = std::move(file.blocks.front()); file.blocks.pop_front(); }
      else { digest = file.source_digest; }
    }
    if (bytes.empty()) {
      if (file.sent != uint64_t(file.expected.size) || digest.size() != 32) throw ConnectionError("Incomplete source stream");
      if (file.local_sink) file.local_sink->end(std::move(digest));
      else file.sink_peer->send(Wire::End, Wire::opcode("stream_write"), file.sink_id, digest);
      return; // Deliberately no destination ACK, hash, or fsync wait at EOF.
    }
    file.budget->release(bytes.size());
    if (file.local_sink) file.local_sink->write(bytes);
    else file.sink_peer->send(Wire::Data, Wire::opcode("stream_write"), file.sink_id, bytes);
    file.sent += bytes.size();
    if (progress) progress(file.sent);
  }
}
} // namespace RemoteFS
