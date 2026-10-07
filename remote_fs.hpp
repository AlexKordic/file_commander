#pragma once
#include "location.hpp"
#include <atomic>
#include <boost/json.hpp>
#include <functional>
#include <span>
#include <stdexcept>

// All paths crossing this boundary retain their filesystem identity.
namespace RemoteFS {
struct Metadata {
  bool exists = false;
  bool target_directory = false;
  uint64_t mode = 0, dev = 0, ino = 0, uid = 0, gid = 0;
  int64_t size = 0, mtime_ns = 0, ctime_ns = 0;
  std::string link, owner, group;
  bool directory() const;
  bool symlink() const;
  boost::filesystem::file_status status() const;
  boost::json::object stamp() const;
};
struct Entry {
  Filepath path;
  Metadata metadata;
};
class ConnectionError : public std::runtime_error {
  using std::runtime_error::runtime_error;
};
boost::json::value request(const std::string &host, const std::string &method, boost::json::object params,
                           const std::atomic<bool> *cancelled = nullptr, bool bulk = false,
                           std::function<void(int64_t)> progress = {});
Metadata inspect(const Filepath &, bool follow = false);
std::vector<Entry> list(const Filepath &, const std::atomic<bool> *cancelled = nullptr);
Filepath canonical(const Filepath &);
std::string read(const Filepath &, uint64_t offset, size_t length);
void write(const Filepath &, uint64_t offset, std::string_view data, bool exclusive = false);
void mkdir(const Filepath &);
void remove(const Filepath &, bool recursive = false);
void rename(const Filepath &, const Filepath &, bool replace = false, const Metadata *expected = nullptr);
void symlink(std::string_view target, const Filepath &);
void metadata(const Filepath &, const Metadata &);
void sync(const Filepath &);
bool access(const Filepath &, int mode);
std::string digest(const Filepath &, const std::atomic<bool> *cancelled = nullptr);
boost::json::object attributes(const Filepath &);
void attributes(const Filepath &, const boost::json::object &);
boost::json::object params(const Filepath &);
std::string base64(std::string_view);
std::string unbase64(std::string_view);
void close_connections();
std::string control_path(const std::string &host);
int authenticate(const std::string &host); // foreground terminal owns prompts
} // namespace RemoteFS
