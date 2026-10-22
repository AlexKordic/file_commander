#pragma once
#include "remote_fs.hpp"
#include <memory>

namespace RemoteFS {
struct StreamProgress {
  uint64_t sent = 0, written = 0, verified = 0, durable = 0, flushes = 0;
};
struct StreamControl {
  bool paused = false, cancelled = false;
  uint64_t rate = 0;
  bool operator==(const StreamControl &) const = default;
};
class StreamSession;
class StreamFile {
public:
  struct Impl;
private:
  std::shared_ptr<Impl> impl;
  explicit StreamFile(std::shared_ptr<Impl>);
  friend class StreamSession;
public:
  StreamProgress progress() const;
  boost::json::object verified_stamp() const;
  bool ready() const;
  // Completes only after independent destination readback and durability.
  void wait() const;
};
// One session per job, with independent input/output channels and bounded
// read-ahead. prepare() is called by the look-ahead worker, transfer() by the
// data worker, and wait() by the commit worker. EOF never waits for verification.
class StreamSession {
  struct Impl;
  std::unique_ptr<Impl> impl;
public:
  explicit StreamSession(std::function<StreamControl()> control = {},
                         const boost::filesystem::copy_file_io_hooks *io = nullptr);
  ~StreamSession();
  std::shared_ptr<StreamFile> prepare(const Filepath &source, const Filepath &stage, const Metadata &expected);
  void transfer(const std::shared_ptr<StreamFile> &, const std::function<void(uint64_t)> &progress = {});
  void cancel();
};
} // namespace RemoteFS
