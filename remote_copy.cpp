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
  bool owned_directory = false;
};
struct Pipeline {
  std::mutex mutex;
  std::condition_variable cv;
  std::deque<std::shared_ptr<Pending>> send, commit;
  std::map<size_t, std::shared_ptr<Pending>> active;
  bool prepared = false, sent = false;
  size_t end = 0;
  uint64_t written = 0, verified = 0, durable = 0;
  uint64_t flushes = 0;
  std::exception_ptr failure;
  void poll(JobSpec &job) { // job mutex held; never hold this mutex while taking it.
    std::lock_guard lock(mutex);
    uint64_t w = written, v = verified, d = durable, f = flushes;
    for (auto &[index, pending] : active) if (pending->stream) {
      auto p = pending->stream->progress(); w += p.written; v += p.verified; d += p.durable; f += p.flushes;
    }
    job._streaming = true;
    job._transfer_written = w; job._transfer_verified = v; job._transfer_durable = d;
    job._transfer_data_flushes = f;
    job._total.update(w, int64_t(job._bytes_total));
    if (!active.empty() && active.begin()->second->stream) {
      const auto &file = active.begin()->second;
      job._current_item.update(file->stream->progress().written, std::max<int64_t>(1, file->source.size));
    }
  }
};
void send_files(const std::shared_ptr<Pipeline>& state, RemoteFS::StreamSession& session,
                JobSpec& job, const RemoteCopyCallbacks& callbacks) {
  uint64_t sent_total = 0, window_base = 0, window_rate = callbacks.rate();
  auto started = std::chrono::steady_clock::now();
  auto checkpoint = [&] {
    const bool paused = job._pause_requested;
    callbacks.checkpoint();
    if (paused) { window_base = sent_total; started = std::chrono::steady_clock::now(); }
  };
  for (;;) {
    std::shared_ptr<Pending> pending;
    { std::unique_lock lock(state->mutex);
      state->cv.wait(lock, [&] { return state->failure || !state->send.empty() || state->prepared; });
      if (state->failure) break;
      if (state->send.empty()) break;
      pending = state->send.front(); state->send.pop_front();
    }
    checkpoint();
    if (pending->stream) {
      const auto left = Location::decode(pending->op.source.native()), right = Location::decode(pending->op.destination.native());
      const bool server_copy = left.remote() && right.remote() && left.ssh == right.ssh;
      uint64_t previous = 0;
      session.transfer(pending->stream, [&](uint64_t sent) {
        checkpoint();
        if (server_copy) return; // The remote copy worker applies the live limit.
        sent_total += sent - previous; previous = sent;
        auto rate = callbacks.rate();
        if (rate != window_rate) { window_rate = rate; window_base = sent_total; started = std::chrono::steady_clock::now(); }
        if (rate) {
          auto deadline = started + std::chrono::duration<double>(double(sent_total - window_base) / rate);
          // This wait exists only for an explicit user bandwidth limit.
          while (std::chrono::steady_clock::now() < deadline) {
            checkpoint();
            std::unique_lock lock(job._m);
            job._pause_cv.wait_for(lock, std::chrono::milliseconds(10));
            if (callbacks.rate() != rate) break;
          }
        }
      });
    }
    { std::lock_guard lock(state->mutex); state->commit.push_back(pending); state->cv.notify_all(); }
  }
}
}
size_t copy_remote_pipeline(JobSpec &job, size_t begin, const RemoteCopyCallbacks &callbacks) {
  using namespace RemoteFS;
  auto state = std::make_shared<Pipeline>();
  state->end = begin;
  state->written = state->verified = state->durable = uint64_t(job._bytes_processed);
  state->flushes = job._transfer_data_flushes;
  StreamSession session([&] { return StreamControl{job._pause_requested, job._cancel_requested, callbacks.rate()}; }, job._journal_io);
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
          const bool directory = op.kind == Operation::Kind::CreateDirectory;
          const bool link = op.kind == Operation::Kind::CreateSymlink;
          if (n != begin && op.kind != Operation::Kind::CopyFile && !directory && !link && !cross_location_move) break;
          { std::unique_lock lock(state->mutex);
            state->cv.wait(lock, [&] { return state->failure || state->active.size() < 16; });
            if (state->failure) return;
          }
          callbacks.checkpoint();
          auto source = op.source.empty() ? Metadata{} : inspect(op.source, directory);
          if (!directory && !link && (!source.exists || !S_ISREG(source.mode))) {
            if (n == begin) throw std::runtime_error("Streaming source is no longer a regular file");
            break;
          }
          if (op.source == op.destination) throw std::runtime_error("Source and destination are the same entry");
          auto pending = std::make_shared<Pending>();
          pending->index = n; pending->op = op; pending->source = source; pending->destination = inspect(op.destination);
          const bool exists = pending->destination.exists;
          if (directory) {
            if (!op.source.empty() && !source.directory()) throw std::runtime_error("Source directory changed after discovery");
            if (exists && !pending->destination.directory()) throw std::runtime_error("Directory destination is occupied");
            bool owned = job._journal && job._journal->owns_pending_directory(n);
            if (!exists) {
              mkdir(op.destination);
              if (job._journal) job._journal->directory_pending(n, op.destination);
              owned = true;
            }
            if (owned && !op.source.empty() && callbacks.directory) callbacks.directory(op.source, op.destination, source);
            pending->owned_directory = owned;
            { std::lock_guard lock(state->mutex);
              state->active.emplace(n, pending); state->send.push_back(pending); state->end = n + 1; state->cv.notify_all();
            }
            continue;
          }
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
            if (link) {
              if (!op.source.empty() && (!source.symlink() || source.link != op.link_text.native()))
                throw std::runtime_error("Source symbolic link changed after discovery");
              symlink(op.link_text.native(), pending->stage);
              if (op.source.empty()) {
                pending->source.exists = true; pending->source.mode = S_IFLNK | 0777;
                pending->source.mtime_ns = int64_t(op.modified) * 1000000000;
              }
            }
          }
          { std::lock_guard lock(state->mutex); state->active.emplace(n, pending); }
          auto stream = pending->skipped || link ? std::shared_ptr<StreamFile>{} : session.prepare(op.source, pending->stage, source);
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
          if (pending->owned_directory && job._journal &&
              !job._journal->owns_pending_directory(pending->index))
            throw std::runtime_error("Created destination directory was replaced; commit blocked");
          if (job._journal) job._journal->begin_step(pending->index);
          if (!pending->skipped && op.kind != Operation::Kind::CreateDirectory) {
            if (!op.source.empty() && inspect(op.source).stamp() != pending->source.stamp())
              throw std::runtime_error("Source changed before commit; destination was not published");
            if (pending->stream && inspect(pending->stage).stamp() != pending->stream->verified_stamp())
              throw std::runtime_error("Verified staging file changed before commit; source retained");
            if (!op.source.empty()) callbacks.attributes(op.source, pending->stage);
            metadata(pending->stage, pending->source);
            if (!job._journal) sync(pending->stage); // commit_ready syncs metadata when journaled.
            auto final_stage = inspect(pending->stage).stamp();
            if (pending->stream) {
              const auto proof = pending->stream->verified_stamp();
              for (auto key : {"dev", "ino", "size"})
                if (final_stage.at(key) != proof.at(key)) throw std::runtime_error("Staging identity changed while applying metadata");
            }
            callbacks.checkpoint();
            if (inspect(op.destination).stamp() != pending->destination.stamp())
              throw std::runtime_error("Destination changed before commit; source retained");
            if (job._journal) job._journal->transaction("commit_ready", pending->stage, op.destination);
            if (inspect(pending->stage).stamp() != final_stage) throw std::runtime_error("Verified staging file changed before publication");
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
              auto p = pending->stream->progress(); state->written += p.written; state->verified += p.verified; state->durable += p.durable; state->flushes += p.flushes;
            }
            state->active.erase(pending->index); state->cv.notify_all();
          }
          job.updated(); // All journal and observer work stays off the data sender.
        }
      } catch (...) { failure(std::current_exception()); }
    });
    send_files(state, session, job, callbacks);
  } catch (...) { failure(std::current_exception()); }
  { std::lock_guard lock(state->mutex); state->sent = true; state->cv.notify_all(); }
  if (preparer.joinable()) preparer.join();
  if (committer.joinable()) committer.join();
  { std::lock_guard lock(job._m); state->poll(job); job._poll_transfer = {}; }
  if (state->failure) std::rethrow_exception(state->failure);
  return state->end;
}
void copy_remote_tree(JobSpec &job, const Filepath &source, const Filepath &stage, const RemoteCopyCallbacks &callbacks) {
  using namespace RemoteFS;
  // The caller already journaled the private parent of stage. The entire
  // directory remains one uncommitted transaction until every child is proven.
  auto state = std::make_shared<Pipeline>();
  state->written = state->verified = state->durable = uint64_t(job._bytes_processed);
  state->flushes = job._transfer_data_flushes;
  StreamSession session([&] { return StreamControl{job._pause_requested, job._cancel_requested, callbacks.rate()}; }, job._journal_io);
  struct Directory { Filepath source, target; Metadata metadata, identity; };
  std::vector<Directory> directories;
  auto failure = [&](std::exception_ptr e) {
    { std::lock_guard lock(state->mutex); if (!state->failure) state->failure = e; state->cv.notify_all(); }
    { std::lock_guard lock(job._m); job._cancel_requested = true; job._pause_cv.notify_all(); }
    session.cancel();
  };
  { std::lock_guard lock(job._m); job._poll_transfer = [state](JobSpec &job) { state->poll(job); }; }
  std::thread preparer, committer;
  try {
    preparer = std::thread([&] {
      try {
        size_t next = 0;
        std::function<void(const Filepath &, const Filepath &)> discover;
        discover = [&](const Filepath &source, const Filepath &target) {
          callbacks.checkpoint();
          const auto before = inspect(source);
          if (!before.exists) throw std::runtime_error("Source is unavailable: " + source.native());
          if (before.directory()) {
            mkdir(target); directories.push_back({source, target, before, inspect(target)});
            for (auto &entry : list(source, &job._cancel_requested)) discover(entry.path, target / entry.path.filename());
          } else if (before.symlink()) {
            symlink(before.link, target);
            callbacks.attributes(source, target); metadata(target, before); if (!job._journal) sync(target);
            if (inspect(source).stamp() != before.stamp()) throw std::runtime_error("Source symbolic link changed while copying");
          } else if (S_ISREG(before.mode)) {
            { std::unique_lock lock(state->mutex);
              state->cv.wait(lock, [&] { return state->failure || state->active.size() < 16; });
              if (state->failure) std::rethrow_exception(state->failure);
            }
            auto pending = std::make_shared<Pending>(); pending->index = next++;
            pending->source = before; pending->stage = target;
            pending->op = {Operation::Kind::CopyFile, source, target, {}, "", before.size};
            { std::lock_guard lock(state->mutex); state->active.emplace(pending->index, pending); }
            auto stream = session.prepare(source, target, before);
            { std::lock_guard lock(state->mutex);
              pending->stream = std::move(stream); state->send.push_back(pending); state->cv.notify_all();
            }
          } else throw std::runtime_error("SSH transfers support regular files, directories and symbolic links");
        };
        discover(source, stage);
        std::lock_guard lock(state->mutex); state->prepared = true; state->cv.notify_all();
      } catch (...) { failure(std::current_exception()); }
    });
    committer = std::thread([&] {
      try {
        for (;;) {
          std::shared_ptr<Pending> pending;
          { std::unique_lock lock(state->mutex);
            state->cv.wait(lock, [&] { return state->failure || !state->commit.empty() || state->sent; });
            if (state->failure || state->commit.empty()) return;
            pending = state->commit.front(); state->commit.pop_front();
          }
          pending->stream->wait(); callbacks.checkpoint();
          if (inspect(pending->op.source).stamp() != pending->source.stamp())
            throw std::runtime_error("Source changed before tree commit; source retained");
          if (inspect(pending->stage).stamp() != pending->stream->verified_stamp())
            throw std::runtime_error("Verified staging file changed before tree commit");
          callbacks.attributes(pending->op.source, pending->stage);
          metadata(pending->stage, pending->source); if (!job._journal) sync(pending->stage);
          { std::lock_guard lock(state->mutex);
            auto p = pending->stream->progress(); state->written += p.written; state->verified += p.verified; state->durable += p.durable; state->flushes += p.flushes;
            state->active.erase(pending->index); state->cv.notify_all();
          }
          job.updated();
        }
      } catch (...) { failure(std::current_exception()); }
    });
    send_files(state, session, job, callbacks);
  } catch (...) { failure(std::current_exception()); }
  { std::lock_guard lock(state->mutex); state->sent = true; state->cv.notify_all(); }
  if (preparer.joinable()) preparer.join();
  if (committer.joinable()) committer.join();
  { std::lock_guard lock(job._m); state->poll(job); job._poll_transfer = {}; }
  if (state->failure) std::rethrow_exception(state->failure);
  for (auto it = directories.rbegin(); it != directories.rend(); ++it) {
    callbacks.checkpoint();
    if (inspect(it->source).stamp() != it->metadata.stamp()) throw std::runtime_error("Source directory changed while copying");
    const auto current = inspect(it->target);
    if (!current.directory() || current.dev != it->identity.dev || current.ino != it->identity.ino)
      throw std::runtime_error("Staging directory was replaced before tree commit");
    callbacks.attributes(it->source, it->target); metadata(it->target, it->metadata); if (!job._journal) sync(it->target);
  }
}
} // namespace Perun
