#include "remote_stream.hpp"
#include "support/contracts.hpp"
#include <iostream>
#include <random>
using test::require;
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
