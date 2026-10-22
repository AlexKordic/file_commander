#include "remote_copy.hpp"
#include "remote_stream.hpp"
#include "transfer_journal.hpp"
#include <deque>
#include <map>
#include <thread>
#include <sys/stat.h>

namespace Perun {
namespace {
struct Pending {
  size_t index;
  Operation op;
  RemoteFS::Metadata source, destination;
  Filepath root, stage;
  std::shared_ptr<RemoteFS::StreamFile> stream;
  bool skipped = false;
};
struct Pipeline {
  std::mutex mutex;
  std::condition_variable cv;
  std::deque<std::shared_ptr<Pending>> send, commit;
  std::map<size_t, std::shared_ptr<Pending>> active;
  bool prepared = false, sent = false;
  size_t end = 0;
  uint64_t written = 0, verified = 0, durable = 0;
  std::exception_ptr failure;
  void poll(JobSpec &job) { // job mutex held; never hold this mutex while taking it.
    std::lock_guard lock(mutex);
    uint64_t w = written, v = verified, d = durable;
    for (auto &[index, pending] : active) if (pending->stream) {
      auto p = pending->stream->progress(); w += p.written; v += p.verified; d += p.durable;
    }
    job._streaming = true;
    job._transfer_written = w; job._transfer_verified = v; job._transfer_durable = d;
    job._total.update(w, int64_t(job._bytes_total));
    if (!active.empty() && active.begin()->second->stream) {
      const auto &file = active.begin()->second;
      job._current_item.update(file->stream->progress().written, std::max<int64_t>(1, file->source.size));
    }
  }
};
}
size_t copy_remote_pipeline(JobSpec &job, size_t begin, const RemoteCopyCallbacks &callbacks) {
  using namespace RemoteFS;
  auto state = std::make_shared<Pipeline>();
  state->end = begin;
  state->written = state->verified = state->durable = uint64_t(job._bytes_processed);
  StreamSession session([&] { return StreamControl{job._pause_requested, job._cancel_requested, callbacks.rate()}; });
  auto failure = [&](std::exception_ptr e) {
    { std::lock_guard lock(state->mutex); if (!state->failure) state->failure = e; state->cv.notify_all(); }
    // Wake explicit-pause waiters too. A recovery error remains PAUSED; it is
    // not a user cancellation, and Resume clears this transport interruption.
    { std::lock_guard lock(job._m); job._cancel_requested = true; job._pause_cv.notify_all(); }
    session.cancel();
  };
  {
    std::lock_guard lock(job._m);
    job._poll_transfer = [state](JobSpec &job) { state->poll(job); };
    state->poll(job);
  }
  std::thread preparer, committer;
  try {
    preparer = std::thread([&] {
      try {
        size_t n = begin;
        for (; n < job._plan->steps.size(); ++n) {
          const auto &op = job._plan->steps[n];
          const bool cross_location_move = op.kind == Operation::Kind::MoveEntry &&
              Location::decode(op.source.native()).ssh != Location::decode(op.destination.native()).ssh;
          if (n != begin && op.kind != Operation::Kind::CopyFile && !cross_location_move) break;
          { std::unique_lock lock(state->mutex);
            state->cv.wait(lock, [&] { return state->failure || state->active.size() < 16; });
            if (state->failure) return;
          }
          callbacks.checkpoint();
          auto source = inspect(op.source);
          if (!source.exists || !S_ISREG(source.mode)) {
            if (n == begin) throw std::runtime_error("Streaming source is no longer a regular file");
            break;
          }
          if (op.source == op.destination) throw std::runtime_error("Source and destination are the same entry");
          auto pending = std::make_shared<Pending>();
          pending->index = n; pending->op = op; pending->source = source; pending->destination = inspect(op.destination);
          const bool exists = pending->destination.exists;
          if (op.kind == Operation::Kind::MoveEntry && exists) throw std::runtime_error("Move destination already exists");
          pending->skipped = op.kind != Operation::Kind::MoveEntry && exists &&
              (job._copy_conflict == CopyConflictMode::Skip ||
               (job._copy_conflict == CopyConflictMode::Update && source.mtime_ns <= pending->destination.mtime_ns));
          if (!pending->skipped) {
            if (pending->destination.directory()) throw std::runtime_error("Cannot replace a directory with a file");
            if (op.kind == Operation::Kind::MoveEntry && !job._journal)
              throw std::runtime_error("Cross-filesystem move requires a transfer journal; source retained");
            pending->root = location_parent(op.destination) / boost::filesystem::unique_path(
                op.kind == Operation::Kind::MoveEntry ? ".fc-move-%%%%%%%%-%%%%%%%%" : ".fc-copy-%%%%%%%%-%%%%%%%%");
            pending->stage = pending->root / (op.kind == Operation::Kind::MoveEntry ? "entry" : "data");
            mkdir(pending->root);
            try { if (job._journal) job._journal->stage_pending(n, pending->stage); }
            catch (...) { try { RemoteFS::remove(pending->root, true); } catch (...) {} throw; }
          }
          { std::lock_guard lock(state->mutex); state->active.emplace(n, pending); }
          auto stream = pending->skipped ? std::shared_ptr<StreamFile>{} : session.prepare(op.source, pending->stage, source);
          { std::lock_guard lock(state->mutex);
            pending->stream = std::move(stream); state->send.push_back(pending); state->end = n + 1; state->cv.notify_all();
          }
        }
        std::lock_guard lock(state->mutex); state->end = n; state->prepared = true; state->cv.notify_all();
      } catch (...) { failure(std::current_exception()); }
    });
    committer = std::thread([&] {
      try {
        for (;;) {
          std::shared_ptr<Pending> pending;
          { std::unique_lock lock(state->mutex);
            state->cv.wait(lock, [&] { return state->failure || !state->commit.empty() || state->sent; });
            if (state->failure) return;
            if (state->commit.empty()) return;
            pending = state->commit.front(); state->commit.pop_front();
          }
          const auto &op = pending->op;
          if (pending->stream) {
            if (job._journal) job._journal->pending_phase(pending->index, "written");
            pending->stream->wait();
            if (job._journal) job._journal->pending_phase(pending->index, "verified");
          }
          callbacks.checkpoint();
          if (job._journal) job._journal->begin_step(pending->index);
          if (!pending->skipped) {
            if (inspect(op.source).stamp() != pending->source.stamp())
              throw std::runtime_error("Source changed before commit; destination was not published");
            callbacks.attributes(op.source, pending->stage);
            metadata(pending->stage, pending->source);
            sync(pending->stage);
            callbacks.checkpoint();
            if (inspect(op.destination).stamp() != pending->destination.stamp())
              throw std::runtime_error("Destination changed before commit; source retained");
            if (job._journal) job._journal->transaction("commit_ready", pending->stage, op.destination);
            rename(pending->stage, op.destination, pending->destination.exists, &pending->destination);
            if (job._journal) job._journal->transaction("committed", pending->stage, op.destination);
            if (op.kind == Operation::Kind::MoveEntry) job._journal->remove_source(op.source, op.destination);
            RemoteFS::remove(pending->root);
          }
          { std::lock_guard lock(job._m);
            ++job._items_done; job._items_skipped += pending->skipped;
            job._bytes_processed += pending->skipped ? 0 : std::max<int64_t>(0, op.bytes);
            job._current_item_index = int(pending->index + 1); job._current_item.current_size = 0;
            if (job._journal) job._journal->finish_step(job);
          }
          { std::lock_guard lock(state->mutex);
            if (pending->stream) {
              auto p = pending->stream->progress(); state->written += p.written; state->verified += p.verified; state->durable += p.durable;
            }
            state->active.erase(pending->index); state->cv.notify_all();
          }
          job.updated(); // All journal and observer work stays off the data sender.
        }
      } catch (...) { failure(std::current_exception()); }
    });
    uint64_t sent_total = 0, window_base = 0, window_rate = callbacks.rate();
    auto started = std::chrono::steady_clock::now();
    for (;;) {
      std::shared_ptr<Pending> pending;
      { std::unique_lock lock(state->mutex);
        state->cv.wait(lock, [&] { return state->failure || !state->send.empty() || state->prepared; });
        if (state->failure) break;
        if (state->send.empty()) break;
        pending = state->send.front(); state->send.pop_front();
      }
      callbacks.checkpoint();
      if (pending->stream) {
        const auto left = Location::decode(pending->op.source.native()), right = Location::decode(pending->op.destination.native());
        const bool server_copy = left.remote() && right.remote() && left.ssh == right.ssh;
        uint64_t previous = 0;
        session.transfer(pending->stream, [&](uint64_t sent) {
          callbacks.checkpoint();
          if (server_copy) return; // The remote copy worker applies the live limit.
          sent_total += sent - previous; previous = sent;
          auto rate = callbacks.rate();
          if (rate != window_rate) { window_rate = rate; window_base = sent_total; started = std::chrono::steady_clock::now(); }
          if (rate) {
            auto deadline = started + std::chrono::duration<double>(double(sent_total - window_base) / rate);
            // This wait exists only for an explicit user bandwidth limit.
            while (std::chrono::steady_clock::now() < deadline) {
              callbacks.checkpoint();
              std::unique_lock lock(job._m);
              job._pause_cv.wait_for(lock, std::chrono::milliseconds(10));
              if (callbacks.rate() != rate) break;
            }
          }
        });
      }
      { std::lock_guard lock(state->mutex); state->commit.push_back(pending); state->cv.notify_all(); }
    }
  } catch (...) { failure(std::current_exception()); }
  { std::lock_guard lock(state->mutex); state->sent = true; state->cv.notify_all(); }
  if (preparer.joinable()) preparer.join();
  if (committer.joinable()) committer.join();
  { std::lock_guard lock(job._m); state->poll(job); job._poll_transfer = {}; }
  if (state->failure) std::rethrow_exception(state->failure);
  return state->end;
}
} // namespace Perun
