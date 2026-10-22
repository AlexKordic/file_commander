#pragma once
#include "file_io_jobs.hpp"
#include <functional>
namespace Perun {
struct RemoteCopyCallbacks {
  std::function<void()> checkpoint;
  std::function<uint64_t()> rate;
  std::function<void(const Filepath &, const Filepath &)> attributes;
};
// Streams a consecutive regular-file run, committing its completed prefix on
// a separate worker. Returns the first operation that belongs to the caller.
size_t copy_remote_pipeline(JobSpec &, size_t begin, const RemoteCopyCallbacks &);
}
