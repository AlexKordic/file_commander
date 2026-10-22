#include "remote_stream.hpp"
#include "support/contracts.hpp"
#include <iostream>
#include <random>
#include <cstring>
using test::require;
static void download_without_waiting_for_fsync(const test::Fixture &local, const Filepath &remote) {
  struct Context { test::Gate gate; std::atomic<int> calls{0}; } context;
  boost::filesystem::copy_file_io_hooks io{};
  io.context = &context;
  io.fault = [](void *value, const char *phase) {
    auto &c = *static_cast<Context *>(value);
    return std::strcmp(phase, "stream_fsync") == 0 && c.calls.fetch_add(1) == 0 && !c.gate.arrive() ? ETIMEDOUT : 0;
  };
  RemoteFS::StreamSession session({}, &io);
  auto first = session.prepare(remote / "one", local / "gated-first", RemoteFS::inspect(remote / "one"));
  auto second = session.prepare(remote / "two", local / "gated-second", RemoteFS::inspect(remote / "two"));
  test::Gate::Release release{context.gate};
  session.transfer(first); context.gate.await();
  session.transfer(second);
  test::until([&] { return second->ready(); }, "Second download waited for the first fsync");
  second->wait(); require(!first->ready(), "Blocked destination completed before its fsync");
  context.gate.open(); first->wait();
}
static void remote_controls(const test::Fixture &local, const Filepath &remote, bool onhost) {
  std::atomic<bool> paused{true};
  std::atomic<uint64_t> rate{512 * 1024};
  RemoteFS::StreamSession session([&] { return RemoteFS::StreamControl{paused, false, rate}; });
  const auto target = onhost ? remote / "controlled-copy" : local / "controlled-download";
  auto file = session.prepare(remote / "one", target, RemoteFS::inspect(remote / "one"));
  std::atomic<bool> finished{false};
  std::exception_ptr error;
  std::thread sender([&] { try { session.transfer(file); } catch (...) { error = std::current_exception(); } finished = true; });
  try {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    require(file->progress().written == 0, "Initially paused remote stream wrote data");
    rate = 0; paused = false;
    test::until([&] { return finished.load(); }, "Remote stream could not receive Resume/rate changes during a file");
    sender.join(); if (error) std::rethrow_exception(error);
    file->wait();
  } catch (...) { session.cancel(); if (sender.joinable()) sender.join(); throw; }
  require(RemoteFS::digest(target) == RemoteFS::digest(remote / "one"), "Controlled stream changed content");
}
static void batch(const std::vector<std::pair<Filepath, Filepath>> &paths) {
  RemoteFS::StreamSession session;
  std::vector<std::shared_ptr<RemoteFS::StreamFile>> files;
  for (const auto &[source, target] : paths) files.push_back(session.prepare(source, target, RemoteFS::inspect(source)));
  for (auto &file : files) session.transfer(file);
  for (size_t i = 0; i < files.size(); ++i) {
    files[i]->wait();
    auto p = files[i]->progress();
    require(p.written == p.verified && p.written == p.durable && p.flushes == 1,
            "Stream did not verify or coalesce data flushes");
    require(RemoteFS::digest(paths[i].first) == RemoteFS::digest(paths[i].second), "Stream changed content");
  }
}
int main(int argc, char **argv) {
  const std::string host = argc > 1 ? argv[1] : "fixture";
  auto remote = Location::decode("ssh://" + host + "/tmp/" + boost::filesystem::unique_path("fc-stream-%%%%%%%%-%%%%%%%%").native()).resource();
  test::Fixture local;
  try {
    std::mt19937_64 random(1234567);
    std::string data(8 * 1024 * 1024 + 17, '\0');
    for (size_t i = 0; i < data.size(); ++i) data[i] = char(random());
    test::write(local / "one", data); test::write(local / "two", "second\nfile"); test::write(local / "empty", "");
    RemoteFS::mkdir(remote);
    batch({{local / "one", remote / "one"}, {local / "two", remote / "two"}, {local / "empty", remote / "empty"}});
    batch({{remote / "one", local / "download"}, {remote / "two", local / "download-two"}, {remote / "empty", local / "download-empty"}});
    batch({{remote / "one", remote / "onhost"}, {remote / "two", remote / "onhost-two"}, {remote / "empty", remote / "onhost-empty"}});
    download_without_waiting_for_fsync(local, remote);
    remote_controls(local, remote, false);
    remote_controls(local, remote, true);
    if (host == "fixture") {
      auto other = Location::decode("ssh://fixture-other" + Location::decode(remote.native()).local.native()).resource();
      batch({{remote / "one", other / "relay"}, {remote / "two", other / "relay-two"}});
    }
    RemoteFS::remove(remote, true); RemoteFS::close_connections();
    std::cout << "PASS continuous upload, download, same-host copy, relay, empty files and readback on " << host << '\n';
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    try { RemoteFS::remove(remote, true); } catch (...) {}
    return 1;
  }
}
