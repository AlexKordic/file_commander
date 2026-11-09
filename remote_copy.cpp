#include "remote_copy.hpp"
#include "remote_stream.hpp"
#include "transfer_journal.hpp"
#include <deque>
#include <map>
#include <set>
#include <thread>
#include <sys/stat.h>

namespace Perun {
namespace {
using namespace RemoteFS;
struct Node {
  Filepath source, target;
  Metadata expected, initial, proof;
};
struct Group {
  size_t index = 0;
  Operation op;
  Metadata source, destination, root_identity;
  Filepath root, stage;
  std::vector<Node> nodes;
  uint64_t bytes = 0, written = 0, verified = 0, durable = 0, flushes = 0;
  bool skipped = false, directory = false, owned_directory = false, rename = false;
};
struct Item {
  size_t id = 0, node = 0;
  std::shared_ptr<Group> group;
  std::shared_ptr<StreamFile> stream;
  bool boundary = false;
};
struct Pipeline {
  // Observers take the job mutex before mutex. Workers never take them in reverse.
  std::mutex mutex, preparation;
  std::condition_variable cv;
  std::deque<std::shared_ptr<Item>> send, verify;
  std::map<size_t, std::shared_ptr<Group>> groups, ready;
  std::map<size_t, std::shared_ptr<Item>> items;
  std::deque<std::pair<size_t, const char *>> journal_events;
  bool prepared = false, published = false;
  size_t end = 0, committed = 0, next_item = 0;
  uint64_t written = 0, verified = 0, durable = 0, flushes = 0, renamed = 0;
  std::exception_ptr failure;
  void poll(JobSpec &job) {
    std::lock_guard lock(mutex);
    uint64_t w = written, v = verified, d = durable, f = flushes;
    for (const auto &[index, g] : groups) { w += g->written; v += g->verified; d += g->durable; f += g->flushes; }
    uint64_t current = groups.empty() ? 0 : groups.begin()->second->written;
    for (const auto &[id, item] : items) if (item->stream) {
      const auto p = item->stream->progress(); w += p.written; v += p.verified; d += p.durable; f += p.flushes;
      if (!groups.empty() && item->group == groups.begin()->second) current += p.written;
    }
    job._streaming = true;
    job._transfer_written = w; job._transfer_verified = v; job._transfer_durable = d;
    job._transfer_data_flushes = f; job._transfer_renamed = renamed;
    job._total.update(w + renamed, int64_t(job._bytes_total));
    if (!groups.empty()) job._current_item.update(current, std::max<uint64_t>(1, groups.begin()->second->bytes));
  }
};
bool contains(const Filepath &root, const Filepath &path) {
  if (root == path) return true;
  auto prefix = root.native(); if (!prefix.ends_with('/')) prefix += '/';
  return path.native().starts_with(prefix);
}
bool overlaps(const std::set<Filepath> &paths, const Filepath &path) {
  if (path.empty()) return false;
  for (auto parent = path; !parent.empty();) {
    if (paths.contains(parent)) return true;
    auto next = location_parent(parent); if (next == parent) break; parent = next;
  }
  auto i = paths.lower_bound(path);
  return i != paths.end() && contains(path, *i);
}
bool eligible(const Operation &op) {
  return op.kind == Operation::Kind::CopyFile || op.kind == Operation::Kind::MoveEntry ||
      op.kind == Operation::Kind::CreateDirectory || op.kind == Operation::Kind::CreateSymlink;
}
void injected(JobSpec &job, const char *point) {
  if (job._journal_io && job._journal_io->fault) {
    const int error = job._journal_io->fault(job._journal_io->context, point);
    if (error) throw std::system_error(error, std::generic_category(), point);
  }
}
void check_identity(const Metadata &actual, const Metadata &expected, const char *message) {
  if (!actual.exists || actual.dev != expected.dev || actual.ino != expected.ino ||
      (actual.mode & S_IFMT) != (expected.mode & S_IFMT)) throw std::runtime_error(message);
}
}

size_t copy_remote_pipeline(JobSpec &job, size_t begin, const RemoteCopyCallbacks &callbacks) {
  using namespace RemoteFS;
  auto state = std::make_shared<Pipeline>(); state->end = state->committed = begin;
  state->renamed = job._transfer_renamed;
  state->written = state->verified = state->durable = uint64_t(job._bytes_processed) -
      std::min<uint64_t>(uint64_t(job._bytes_processed), state->renamed);
  state->flushes = job._transfer_data_flushes;
  StreamSession session([&] { return StreamControl{job._pause_requested, job._cancel_requested, callbacks.rate()}; }, job._journal_io);
  auto fail = [&](std::exception_ptr error) {
    { std::lock_guard lock(state->mutex); if (!state->failure) state->failure = error; state->cv.notify_all(); }
    { std::lock_guard lock(job._m); job._cancel_requested = true; job._pause_cv.notify_all(); }
    session.cancel();
  };
  { std::lock_guard lock(job._m); job._poll_transfer = [state](JobSpec &job) { state->poll(job); }; }

  // Preserve source request/send order even if the publisher has to queue an
  // EXDEV fallback concurrently with ordinary preparation.
  auto queue = [&](const std::shared_ptr<Group> &g, size_t node, bool boundary) {
    std::unique_lock preparation(state->preparation);
    auto item = std::make_shared<Item>(); item->group = g; item->node = node; item->boundary = boundary;
    if (!boundary) {
      { std::unique_lock lock(state->mutex);
        state->cv.wait(lock, [&] { return state->failure || state->items.size() < 16; });
        if (state->failure) std::rethrow_exception(state->failure);
        item->id = state->next_item++; state->items.emplace(item->id, item);
      }
      auto &entry = g->nodes.at(node);
      std::shared_ptr<StreamFile> stream;
      if (S_ISREG(entry.expected.mode)) stream = session.prepare(entry.source, entry.target, entry.expected);
      { std::lock_guard lock(state->mutex); item->stream = std::move(stream); }
    }
    { std::lock_guard lock(state->mutex); state->send.push_back(item); state->cv.notify_all(); }
  };
  auto prepare_copy = [&](const std::shared_ptr<Group> &g) {
    if (g->op.kind == Operation::Kind::MoveEntry && !job._journal)
      throw std::runtime_error("Cross-filesystem move requires a transfer journal; source retained");
    g->root = location_parent(g->op.destination) / boost::filesystem::unique_path(
        g->op.kind == Operation::Kind::MoveEntry ? ".fc-move-%%%%%%%%-%%%%%%%%" : ".fc-copy-%%%%%%%%-%%%%%%%%");
    g->stage = g->root / (g->op.kind == Operation::Kind::MoveEntry ? "entry" : "data");
    mkdir(g->root);
    try { if (job._journal) job._journal->stage_pending(g->index, g->stage); }
    catch (...) { try { RemoteFS::remove(g->root, true); } catch (...) {} throw; }
    g->root_identity = inspect(g->root);
    auto base = g->op.source;
    if (g->op.kind == Operation::Kind::CopyFile && inspect(base).symlink())
      base = RemoteFS::canonical(base);
    for (size_t n = 0; n < g->nodes.size(); ++n) {
      callbacks.checkpoint();
      auto &node = g->nodes[n];
      const auto relative = node.source == g->op.source ? Filepath{} : node.source.lexically_relative(g->op.source);
      node.source = g->op.source.empty() ? Filepath{} : relative.empty() ? base : base / relative;
      node.target = relative.empty() ? g->stage : g->stage / relative;
      if (!node.expected.exists) throw std::runtime_error("Source is unavailable: " + node.source.native());
      if (!node.source.empty() && inspect(node.source).stamp() != node.expected.stamp())
        throw std::runtime_error("Source changed before streaming; source retained: " + node.source.native());
      if (node.expected.directory()) { mkdir(node.target); node.initial = inspect(node.target); }
      else if (node.expected.symlink()) {
        symlink(node.expected.link, node.target); node.initial = inspect(node.target); queue(g, n, false);
      } else if (S_ISREG(node.expected.mode)) queue(g, n, false);
      else throw std::runtime_error("SSH transfers support regular files, directories and symbolic links");
    }
    queue(g, 0, true);
  };
  std::thread preparer, verifier, publisher;
  try {
    verifier = std::thread([&] {
      try {
        for (;;) {
          std::shared_ptr<Item> item;
          { std::unique_lock lock(state->mutex);
            state->cv.wait(lock, [&] { return state->failure || !state->verify.empty() || state->published; });
            if (state->failure || state->verify.empty()) return;
            item = state->verify.front(); state->verify.pop_front();
          }
          const auto &g = item->group;
          if (item->boundary) {
            if (!g->directory && !g->skipped && !g->rename) {
              for (auto i = g->nodes.rbegin(); i != g->nodes.rend(); ++i) if (i->expected.directory()) {
                callbacks.checkpoint();
                if (inspect(i->source).stamp() != i->expected.stamp()) throw std::runtime_error("Source directory changed while copying");
                check_identity(inspect(i->target), i->initial, "Staging directory was replaced before verification");
                callbacks.attributes(i->source, i->target); metadata(i->target, i->expected);
                if (!job._journal) sync(i->target);
                i->proof = inspect(i->target);
              }
            }
            { std::lock_guard lock(state->mutex);
              if (job._journal && !g->stage.empty()) state->journal_events.emplace_back(g->index, "verified");
              state->ready[g->index] = g; state->cv.notify_all();
            }
            continue;
          }
          auto &node = g->nodes[item->node];
          if (item->stream) item->stream->wait();
          callbacks.checkpoint();
          if (!node.source.empty() && inspect(node.source).stamp() != node.expected.stamp())
            throw std::runtime_error("Source changed during verification; source retained");
          const auto before = item->stream ? item->stream->verified_stamp() : node.initial.stamp();
          if (inspect(node.target).stamp() != before) throw std::runtime_error("Verified staging file changed before metadata");
          if (!node.source.empty()) callbacks.attributes(node.source, node.target);
          metadata(node.target, node.expected); if (!job._journal) sync(node.target);
          node.proof = inspect(node.target);
          const auto after = node.proof.stamp();
          for (auto key : {"dev", "ino", "size"})
            if (after.at(key) != before.at(key)) throw std::runtime_error("Staging identity changed while applying metadata");
          { std::lock_guard lock(state->mutex);
            if (item->stream) {
              auto p = item->stream->progress(); g->written += p.written; g->verified += p.verified;
              g->durable += p.durable; g->flushes += p.flushes;
            }
            state->items.erase(item->id); state->cv.notify_all();
          }
        }
      } catch (...) { fail(std::current_exception()); }
    });
    publisher = std::thread([&] {
      try {
        size_t next = begin;
        for (;;) {
          std::shared_ptr<Group> g;
          std::map<size_t, const char *> events;
          { std::unique_lock lock(state->mutex);
            state->cv.wait(lock, [&] { return state->failure || !state->journal_events.empty() || state->ready.contains(next) || (state->prepared && next == state->end); });
            if (state->failure) return;
            while (!state->journal_events.empty()) {
              const auto [index, phase] = state->journal_events.front(); state->journal_events.pop_front();
              if (!events.contains(index) || std::string_view(phase) == "verified") events[index] = phase;
            }
            if (state->ready.contains(next)) { g = state->ready.at(next); state->ready.erase(next); }
            else if (state->prepared && next == state->end && events.empty()) { state->published = true; state->cv.notify_all(); return; }
          }
          for (const auto &[index, phase] : events) job._journal->pending_phase(index, phase);
          if (!g) continue;
          callbacks.checkpoint();
          if (job._journal) job._journal->begin_step(next);
          if (!g->skipped && !g->directory) {
            if (job._journal) job._journal->validate_source(next);
            else for (const auto &node : g->nodes)
              if (!node.source.empty() && inspect(node.source).stamp() != node.expected.stamp()) throw std::runtime_error("Source changed before publication");
            injected(job, "remote_before_publish");
            if (inspect(g->op.destination).stamp() != g->destination.stamp())
              throw std::runtime_error("Destination changed before commit; source retained");
            if (g->rename) {
              try { rename(g->op.source, g->op.destination, false, &g->destination); }
              catch (const std::system_error &error) {
                if (error.code().value() != EXDEV) throw;
                g->rename = false; prepare_copy(g); continue;
              }
            } else {
              check_identity(inspect(g->root), g->root_identity, "Transfer staging ownership changed before commit");
              std::vector<Entry> proof;
              for (const auto &node : g->nodes) proof.push_back({node.target, node.proof});
              if (job._journal) job._journal->transaction("commit_ready", g->stage, g->op.destination, &proof);
              else for (const auto &node : g->nodes)
                if (inspect(node.target).stamp() != node.proof.stamp()) throw std::runtime_error("Verified staging tree changed before publication");
              if (inspect(g->stage).stamp() != g->nodes.front().proof.stamp())
                throw std::runtime_error("Verified staging root changed before publication");
              callbacks.checkpoint();
              rename(g->stage, g->op.destination, g->destination.exists, &g->destination);
              if (job._journal) job._journal->transaction("committed", g->stage, g->op.destination);
              if (g->op.kind == Operation::Kind::MoveEntry) {
                const int error = job._journal->remove_source(g->op.source, g->op.destination, job._journal_io);
                if (error) throw std::system_error(error, std::generic_category(), "Move source cleanup interrupted; Resume required");
              }
              RemoteFS::remove(g->root);
            }
          }
          if (g->directory && g->owned_directory && job._journal && !job._journal->owns_pending_directory(next))
            throw std::runtime_error("Created destination directory was replaced; commit blocked");
          { std::lock_guard lock(job._m);
            ++job._items_done; job._items_skipped += g->skipped;
            job._bytes_processed += g->skipped ? 0 : g->bytes;
            if (g->rename) job._transfer_renamed += g->bytes;
            job._current_item_index = int(next + 1); job._current_item.current_size = 0;
            if (job._journal) job._journal->finish_step(job);
          }
          { std::lock_guard lock(state->mutex);
            state->written += g->written; state->verified += g->verified; state->durable += g->durable;
            state->flushes += g->flushes; if (g->rename) state->renamed += g->bytes;
            state->groups.erase(next); state->committed = ++next; state->cv.notify_all();
          }
          job.updated();
        }
      } catch (...) { fail(std::current_exception()); }
    });
    preparer = std::thread([&] {
      try {
        std::set<Filepath> writes, moves, directories;
        size_t n = begin;
        for (; n < job._plan->steps.size() && eligible(job._plan->steps[n]); ++n) {
          const auto &op = job._plan->steps[n];
          const bool dependency = overlaps(writes, op.source) || overlaps(writes, op.destination) || overlaps(moves, op.source);
          { std::unique_lock lock(state->mutex);
            state->cv.wait(lock, [&] { return state->failure || (state->groups.size() < 16 && (!dependency || state->committed >= n)); });
            if (state->failure) return;
          }
          callbacks.checkpoint();
          const bool refresh = dependency || overlaps(directories, op.source);
          if (refresh && job._journal) {
            job._journal->refresh_inputs(n);
            const auto total = job._journal->total_bytes();
            std::lock_guard lock(job._m); job._bytes_total = total;
          }
          auto entries = job._journal ? job._journal->source_entries(n) : TransferJournal::snapshot_source(op);
          auto g = std::make_shared<Group>(); g->index = n; g->op = op;
          g->directory = op.kind == Operation::Kind::CreateDirectory;
          if (!entries.empty()) g->source = entries.front().metadata;
          if (!op.source.empty() && !g->source.exists) throw std::runtime_error("Source is unavailable: " + op.source.native());
          if (!op.source.empty() && op.source == op.destination) throw std::runtime_error("Source and destination are the same entry");
          g->destination = inspect(op.destination);
          if (g->directory) {
            if (!op.source.empty() && !g->source.directory()) throw std::runtime_error("Source directory changed after discovery");
            if (g->destination.exists && !g->destination.directory()) throw std::runtime_error("Directory destination is occupied");
            g->owned_directory = job._journal && job._journal->owns_pending_directory(n);
            if (!g->destination.exists) {
              mkdir(op.destination); if (job._journal) job._journal->directory_pending(n, op.destination);
              g->owned_directory = true;
            }
            if (g->owned_directory && !op.source.empty() && callbacks.directory) callbacks.directory(op.source, op.destination, g->source);
            directories.insert(op.destination);
          } else {
            if (op.kind == Operation::Kind::MoveEntry && g->destination.exists) throw std::runtime_error("Move destination already exists");
            g->skipped = op.kind != Operation::Kind::MoveEntry && g->destination.exists &&
                (job._copy_conflict == CopyConflictMode::Skip ||
                 (job._copy_conflict == CopyConflictMode::Update && g->source.mtime_ns <= g->destination.mtime_ns));
            if (!g->skipped && g->destination.directory()) throw std::runtime_error("Cannot replace a directory with a file");
            const auto left = Location::decode(op.source.native()), right = Location::decode(op.destination.native());
            if (g->source.directory() && left.ssh == right.ssh) {
              const auto from = RemoteFS::canonical(op.source), parent = RemoteFS::canonical(location_parent(op.destination));
              if (contains(from, parent)) throw std::runtime_error("Cannot copy or move a directory into itself");
            }
            if (op.kind == Operation::Kind::MoveEntry && left.ssh == right.ssh) {
              const auto parent = inspect(location_parent(op.destination), true);
              g->rename = parent.exists && parent.dev == g->source.dev;
            }
            for (auto &entry : entries) {
              if (S_ISREG(entry.metadata.mode)) g->bytes += std::max<int64_t>(0, entry.metadata.size);
              g->nodes.push_back({entry.path, {}, entry.metadata, {}, {}});
            }
            if (op.kind == Operation::Kind::CreateSymlink && op.source.empty()) {
              Metadata link; link.exists = true; link.mode = S_IFLNK | 0777;
              link.link = op.link_text.native(); link.mtime_ns = int64_t(op.modified) * 1000000000;
              g->nodes.push_back({{}, {}, link, {}, {}});
            }
            if (g->nodes.empty()) throw std::runtime_error("Streaming source has no filesystem snapshot");
            if (op.kind == Operation::Kind::CreateSymlink && !op.source.empty() &&
                (!g->source.symlink() || g->source.link != op.link_text.native()))
              throw std::runtime_error("Source symbolic link changed after discovery");
            if (!job._journal) { std::lock_guard lock(job._m); job._bytes_total += double(g->bytes) - std::max<int64_t>(0, op.bytes); }
          }
          { std::lock_guard lock(state->mutex); state->groups.emplace(n, g); state->end = n + 1; }
          if (g->directory || g->skipped || g->rename) queue(g, 0, true);
          else prepare_copy(g);
          if (!g->directory) { writes.insert(op.destination); if (op.kind == Operation::Kind::MoveEntry) moves.insert(op.source); }
        }
        { std::lock_guard lock(state->mutex); state->end = n; state->prepared = true; state->cv.notify_all(); }
      } catch (...) { fail(std::current_exception()); }
    });

    uint64_t sent_total = 0, window_base = 0, window_rate = callbacks.rate();
    auto started = std::chrono::steady_clock::now();
    auto checkpoint = [&] {
      const bool paused = job._pause_requested; callbacks.checkpoint();
      if (paused) { window_base = sent_total; started = std::chrono::steady_clock::now(); }
    };
    for (;;) {
      std::shared_ptr<Item> item;
      { std::unique_lock lock(state->mutex);
        state->cv.wait(lock, [&] { return state->failure || !state->send.empty() || state->published; });
        if (state->failure || state->send.empty()) break;
        item = state->send.front(); state->send.pop_front();
      }
      checkpoint();
      if (item->stream) {
        const auto &node = item->group->nodes[item->node];
        const auto left = Location::decode(node.source.native()), right = Location::decode(node.target.native());
        const bool server_copy = left.remote() && right.remote() && left.ssh == right.ssh;
        uint64_t previous = 0;
        session.transfer(item->stream, [&](uint64_t sent) {
          checkpoint(); if (server_copy) return;
          sent_total += sent - previous; previous = sent;
          const auto rate = callbacks.rate();
          if (rate != window_rate) { window_rate = rate; window_base = sent_total; started = std::chrono::steady_clock::now(); }
          if (rate) {
            const auto deadline = started + std::chrono::duration<double>(double(sent_total - window_base) / rate);
            while (std::chrono::steady_clock::now() < deadline) {
              checkpoint(); std::unique_lock lock(job._m); job._pause_cv.wait_for(lock, std::chrono::milliseconds(10));
              if (callbacks.rate() != rate) break;
            }
          }
        });
      }
      { std::lock_guard lock(state->mutex);
        if (item->boundary && job._journal && !item->group->stage.empty())
          state->journal_events.emplace_back(item->group->index, "written");
        state->verify.push_back(item); state->cv.notify_all();
      }
    }
  } catch (...) { fail(std::current_exception()); }
  if (preparer.joinable()) preparer.join();
  if (verifier.joinable()) verifier.join();
  if (publisher.joinable()) publisher.join();
  { std::lock_guard lock(job._m); state->poll(job); job._poll_transfer = {}; }
  if (state->failure) std::rethrow_exception(state->failure);
  return state->end;
}
} // namespace Perun
