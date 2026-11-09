#pragma once
#include "file_io_jobs.hpp"
#include "remote_fs.hpp"
#include <functional>
namespace Perun {
struct RemoteCopyCallbacks {
  std::function<void()> checkpoint;
  std::function<uint64_t()> rate;
  std::function<void(const Filepath &, const Filepath &)> attributes;
  std::function<void(const Filepath &, const Filepath &, const RemoteFS::Metadata &)> directory;
};
// Streams independent copy/move operations, including whole directory trees,
// while separate workers verify metadata and publish the completed prefix.
size_t copy_remote_pipeline(JobSpec &, size_t begin, const RemoteCopyCallbacks &);
}
