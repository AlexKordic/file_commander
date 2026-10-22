#include "remote_fs.hpp"
#include "remote_transport.hpp"
#include "remote_protocol.hpp"
#include <boost/filesystem.hpp>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <memory>
#include <mutex>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <system_error>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/acl.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#include "file_metadata.hpp"
#include "sha256.hpp"
extern char **environ;
namespace RemoteFS {
namespace j = boost::json;
namespace {
std::mutex endpoint_commands_mutex;
std::map<std::string, std::string> endpoint_commands;
}  // namespace
void set_endpoint_command(const std::string &host, std::string command) {
  std::lock_guard lock(endpoint_commands_mutex);
  if (command.empty())
    endpoint_commands.erase(host);
  else
    endpoint_commands[host] = std::move(command);
}
std::string ssh_command(const std::string &host) {
  {
    std::lock_guard lock(endpoint_commands_mutex);
    if (auto at = endpoint_commands.find(host); at != endpoint_commands.end())
      return at->second;
  }
  if (const char *binary = std::getenv("FC_SSH_BIN"))
    return binary;
  return "ssh";
}
namespace {
using Client = detail::Transport;
std::mutex registry_mutex;
std::map<std::pair<std::string, bool>, std::shared_ptr<Client>> clients;
uint64_t number(const j::object &o, const char *key) {
  auto at = o.find(key);
  if (at == o.end())
    return 0;
  return at->value().is_uint64() ? at->value().as_uint64() : uint64_t(at->value().as_int64());
}
Metadata decode(const j::object &o) {
  Metadata m;
  m.exists = o.at("exists").as_bool();
  if (!m.exists)
    return m;
  if (auto at = o.find("target_dir"); at != o.end())
    m.target_directory = at->value().as_bool();
  m.mode = number(o, "mode");
  m.dev = number(o, "dev");
  m.ino = number(o, "ino");
  m.uid = number(o, "uid");
  m.gid = number(o, "gid");
  m.size = number(o, "size");
  m.mtime_ns = number(o, "mtime_ns");
  m.ctime_ns = number(o, "ctime_ns");
  if (auto at = o.find("link"); at != o.end())
    m.link = at->value().as_string();
  if (auto at = o.find("owner"); at != o.end())
    m.owner = at->value().as_string();
  if (auto at = o.find("group"); at != o.end())
    m.group = at->value().as_string();
  return m;
}
} // namespace
j::value request(const std::string &host, const std::string &method, j::object p,
                 const std::atomic<bool> *cancelled, bool bulk, std::function<void(int64_t)> progress) {
  std::shared_ptr<Client> client;
  {
    std::lock_guard guard(registry_mutex);
    auto &slot = clients[{host, bulk}];
    if (!slot)
      slot = std::make_shared<Client>();
    client = slot;
  }
  std::lock_guard guard(client->mutex);
  try {
    if (client->pid < 0)
      client->start(host, cancelled);
    auto id = ++client->sequence;
    auto operation = Wire::opcode(method);
    client->frame(Wire::Request, operation, id, Wire::encode(p), cancelled);
    j::array entries;
    for (;;) {
      auto frame = client->receive(cancelled);
      if (frame.id != id || frame.operation != operation)
        throw ConnectionError("SSH response identity mismatch");
      auto reply = Wire::decode(frame.payload).as_object();
      if (frame.kind == Wire::Error) {
        auto code = number(reply, "errno");
        throw std::system_error(int(code ? code : EIO), std::generic_category(),
                                std::string(reply.at("message").as_string()));
      }
      if (frame.kind == Wire::Event) {
        auto &data = reply;
        if (data.contains("bytes")) {
          if (progress)
            progress(number(data, "bytes"));
        }
        if (data.contains("entries"))
          for (auto &entry : data.at("entries").as_array()) {
            if (entries.size() >= 1000000)
              throw ConnectionError("SSH listing exceeded its entry limit");
            entries.push_back(std::move(entry));
          }
        continue;
      }
      if (frame.kind != Wire::Result) throw ConnectionError("Unexpected SSH frame");
      j::value result(std::move(reply));
      if (!entries.empty()) {
        for (auto &entry : result.as_object().at("entries").as_array())
          entries.push_back(std::move(entry));
        result.as_object()["entries"] = std::move(entries);
      }
      return result;
    }
  } catch (const ConnectionError &) {
    client->stop();
    throw;
  } catch (const boost::system::system_error &e) {
    client->stop();
    throw ConnectionError(std::string("Invalid SSH helper response: ") + e.what());
  } catch (...) {
    // A malformed value or an interrupted progress callback leaves framing
    // ownership uncertain. Never lend that connection to another operation.
    client->stop();
    throw;
  }
}
void close_connections() {
  std::lock_guard guard(registry_mutex);
  clients.clear();
}
ProtocolStats protocol_stats() { return {detail::protocol_sent.load(), detail::protocol_received.load()}; }
std::string control_path(const std::string &host) {
  auto dir = std::string("/tmp/fcmd-ssh-") + std::to_string(getuid());
  if (::mkdir(dir.c_str(), 0700) && errno != EEXIST)
    throw ConnectionError("Cannot create SSH control directory");
  struct stat s{};
  if (lstat(dir.c_str(), &s) || !S_ISDIR(s.st_mode) || s.st_uid != getuid() || (s.st_mode & 077) != 0)
    throw ConnectionError("SSH control directory is not private");
  Sha256 hash;
  hash.update(host);
  return dir + "/" + hash.finish().substr(0, 24);
}
int authenticate(const std::string &host) {
  Location::decode("ssh://" + host + "/");
  std::vector<std::string> args{"ssh",
                                "-o",
                                "ControlMaster=auto",
                                "-o",
                                "ControlPersist=600",
                                "-o",
                                "ControlPath=" + control_path(host),
                                "-o",
                                "ConnectTimeout=10",
                                host,
                                "true"};
  args[0] = ssh_command(host);
  std::vector<char *> argv;
  for (auto &a : args)
    argv.push_back(a.data());
  argv.push_back(nullptr);
  pid_t pid;
  int rc = posix_spawnp(&pid, argv[0], nullptr, nullptr, argv.data(), environ);
  if (rc)
    return rc;
  int status;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR)
      return errno;
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
bool Metadata::directory() const { return S_ISDIR(mode); }
bool Metadata::symlink() const { return S_ISLNK(mode); }
boost::filesystem::file_status Metadata::status() const {
  using namespace boost::filesystem;
  return file_status(!exists         ? file_not_found
                     : directory()   ? directory_file
                     : symlink()     ? symlink_file
                     : S_ISREG(mode) ? regular_file
                                     : type_unknown,
                     perms(mode & 07777));
}
j::object Metadata::stamp() const {
  return {{"exists", exists},     {"mode", mode},
          {"dev", dev},           {"ino", ino},
          {"uid", uid},           {"gid", gid},
          {"size", size},         {"mtime_ns", mtime_ns},
          {"ctime_ns", ctime_ns}, {"link", link}};
}
j::object params(const Filepath &p) {
  auto l = Location::decode(p.native());
  return {{"path", l.local.native()}};
}
Metadata inspect(const Filepath &p, bool follow) {
  if (is_remote(p)) {
    auto l = Location::decode(p.native());
    auto a = params(p);
    a["follow"] = follow;
    return decode(request(l.ssh, "stat", std::move(a)).as_object());
  }
  struct stat s{};
  if ((follow ? ::stat(p.c_str(), &s) : ::lstat(p.c_str(), &s)) < 0) {
    if (errno == ENOENT || errno == ENOTDIR)
      return {};
    throw std::system_error(errno, std::generic_category(), p.native());
  }
  Metadata m;
  m.exists = true;
  m.mode = s.st_mode;
  m.dev = s.st_dev;
  m.ino = s.st_ino;
  m.uid = s.st_uid;
  m.gid = s.st_gid;
  m.size = s.st_size;
#if defined(__APPLE__)
  m.mtime_ns = int64_t(s.st_mtimespec.tv_sec) * 1000000000 + s.st_mtimespec.tv_nsec;
  m.ctime_ns = int64_t(s.st_ctimespec.tv_sec) * 1000000000 + s.st_ctimespec.tv_nsec;
#else
  m.mtime_ns = int64_t(s.st_mtim.tv_sec) * 1000000000 + s.st_mtim.tv_nsec;
  m.ctime_ns = int64_t(s.st_ctim.tv_sec) * 1000000000 + s.st_ctim.tv_nsec;
#endif
  if (m.symlink())
    m.link = boost::filesystem::read_symlink(p).native();
  return m;
}
std::vector<Entry> list(const Filepath &p, const std::atomic<bool> *cancelled) {
  std::vector<Entry> out;
  if (is_remote(p)) {
    auto l = Location::decode(p.native());
    auto result = request(l.ssh, "list", params(p), cancelled);
    for (auto &v : result.as_object().at("entries").as_array()) {
      auto &o = v.as_object();
      auto m = decode(o);
      out.push_back({p / std::string(o.at("name").as_string()), std::move(m)});
    }
  } else {
    for (auto &entry : boost::filesystem::directory_iterator(p)) {
      if (cancelled && cancelled->load())
        break;
      out.push_back({entry.path(), inspect(entry.path())});
    }
  }
  return out;
}
Filepath canonical(const Filepath &p) {
  if (!is_remote(p))
    return boost::filesystem::canonical(p);
  auto l = Location::decode(p.native());
  l.local = std::string(request(l.ssh, "realpath", params(p)).as_object().at("path").as_string());
  return l.resource();
}
std::string read(const Filepath &p, uint64_t offset, size_t length) {
  if (is_remote(p)) {
    auto a = params(p);
    a["offset"] = offset;
    a["length"] = length;
    return std::string(request(Location::decode(p.native()).ssh, "read", std::move(a), nullptr, true)
                        .as_object()
                        .at("data")
                        .as_string());
  }
  int fd = open(p.c_str(), O_RDONLY | O_NOFOLLOW);
  if (fd < 0)
    throw std::system_error(errno, std::generic_category(), p.native());
  std::string data(length, '\0');
  auto n = pread(fd, data.data(), length, off_t(offset));
  int error = errno;
  close(fd);
  if (n < 0)
    throw std::system_error(error, std::generic_category());
  data.resize(size_t(n));
  return data;
}
void write(const Filepath &p, uint64_t offset, std::string_view data, bool exclusive) {
  if (is_remote(p)) {
    auto a = params(p);
    a["offset"] = offset;
    a["data"] = data;
    a["exclusive"] = exclusive;
    request(Location::decode(p.native()).ssh, "write", std::move(a), nullptr, true);
    return;
  }
  int fd = open(p.c_str(), O_WRONLY | O_NOFOLLOW | (exclusive ? O_CREAT | O_EXCL : 0), 0600);
  if (fd < 0)
    throw std::system_error(errno, std::generic_category(), p.native());
  int error = 0;
  while (!data.empty()) {
    auto n = pwrite(fd, data.data(), data.size(), off_t(offset));
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0) {
      error = errno;
      break;
    }
    offset += n;
    data.remove_prefix(size_t(n));
  }
  if (!error && fsync(fd))
    error = errno;
  close(fd);
  if (error)
    throw std::system_error(error, std::generic_category());
}
void mkdir(const Filepath &p) {
  if (is_remote(p))
    request(Location::decode(p.native()).ssh, "mkdir", params(p));
  else {
    boost::system::error_code ec;
    if (!Perun::create_private_directory(p, ec))
      throw std::system_error(ec ? ec.value() : EEXIST, std::generic_category());
  }
}
void remove(const Filepath &p, bool recursive) {
  if (is_remote(p)) {
    auto a = params(p);
    a["recursive"] = recursive;
    request(Location::decode(p.native()).ssh, "remove", std::move(a));
  } else if (recursive)
    boost::filesystem::remove_all(p);
  else
    boost::filesystem::remove(p);
}
void rename(const Filepath &p, const Filepath &dst, bool replace, const Metadata *expected) {
  if (is_remote(p) || is_remote(dst)) {
    auto l = Location::decode(p.native()), r = Location::decode(dst.native());
    if (l.ssh != r.ssh)
      throw std::system_error(EXDEV, std::generic_category());
    auto a = params(p);
    a["destination"] = r.local.native();
    a["replace"] = replace;
    if (expected)
      a["expected"] = expected->exists ? expected->stamp() : j::object{{"exists", false}};
    request(l.ssh, "rename", std::move(a));
  } else {
    if (expected && inspect(dst).stamp() != expected->stamp())
      throw std::system_error(ESTALE, std::generic_category());
    int rc;
#if defined(__APPLE__)
    rc = replace ? ::rename(p.c_str(), dst.c_str()) : ::renamex_np(p.c_str(), dst.c_str(), RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
    rc = replace ? ::rename(p.c_str(), dst.c_str())
                 : int(::syscall(SYS_renameat2, AT_FDCWD, p.c_str(), AT_FDCWD, dst.c_str(), 1));
#else
    if (!replace)
      throw std::system_error(ENOTSUP, std::generic_category());
    rc = ::rename(p.c_str(), dst.c_str());
#endif
    if (rc)
      throw std::system_error(errno, std::generic_category());
  }
}
void symlink(std::string_view target, const Filepath &p) {
  if (is_remote(p)) {
    auto a = params(p);
    a["target"] = target;
    request(Location::decode(p.native()).ssh, "symlink", std::move(a));
  } else
    boost::filesystem::create_symlink(Filepath(target), p);
}
void metadata(const Filepath &p, const Metadata &m) {
  if (is_remote(p)) {
    auto a = params(p);
    a["mode"] = m.mode;
    a["mtime_ns"] = m.mtime_ns;
    request(Location::decode(p.native()).ssh, "metadata", std::move(a));
  } else {
    if (!m.symlink() && chmod(p.c_str(), m.mode & 07777))
      throw std::system_error(errno, std::generic_category());
    timespec t[2]{{time_t(m.mtime_ns / 1000000000), long(m.mtime_ns % 1000000000)},
                  {time_t(m.mtime_ns / 1000000000), long(m.mtime_ns % 1000000000)}};
    if (utimensat(AT_FDCWD, p.c_str(), t, AT_SYMLINK_NOFOLLOW))
      throw std::system_error(errno, std::generic_category());
  }
}
void sync(const Filepath &p) {
  if (is_remote(p)) {
    request(Location::decode(p.native()).ssh, "fsync", params(p));
    return;
  }
  if (inspect(p).symlink())
    return;
  int fd = ::open(p.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    throw std::system_error(errno, std::generic_category());
  auto rc = ::fsync(fd), error = errno;
  ::close(fd);
  if (rc)
    throw std::system_error(error, std::generic_category());
}
bool access(const Filepath &p, int mode) {
  if (!is_remote(p))
    return ::access(p.c_str(), mode) == 0;
  auto a = params(p);
  a["mode"] = mode;
  return request(Location::decode(p.native()).ssh, "access", std::move(a))
      .as_object()
      .at("allowed")
      .as_bool();
}
std::string digest(const Filepath &p, const std::atomic<bool> *cancelled) {
  if (is_remote(p)) {
    auto raw = std::string(request(Location::decode(p.native()).ssh, "digest", params(p), cancelled, true)
                           .as_object()
                           .at("sha256")
                           .as_string());
    constexpr char hex[] = "0123456789abcdef";
    if (raw.size() != 32) throw ConnectionError("Invalid SSH SHA-256 digest size");
    std::string out;
    for (uint8_t c : raw) { out += hex[c >> 4]; out += hex[c & 15]; }
    return out;
  }
  Sha256 hash;
  uint64_t offset = 0;
  for (;;) {
    if (cancelled && cancelled->load())
      throw ConnectionError("Transfer interrupted");
    auto data = read(p, offset, 1024 * 1024);
    if (data.empty())
      break;
    hash.update(data);
    offset += data.size();
  }
  return hash.finish();
}
j::object attributes(const Filepath &p) {
  if (is_remote(p))
    return request(Location::decode(p.native()).ssh, "attributes", params(p)).as_object();
  j::object out;
#if defined(__APPLE__)
  auto size = ::listxattr(p.c_str(), nullptr, 0, XATTR_NOFOLLOW);
#else
  auto size = ::llistxattr(p.c_str(), nullptr, 0);
#endif
  if (size < 0) {
    if (errno != ENOTSUP)
      throw std::system_error(errno, std::generic_category());
    size = 0;
  }
  std::string names(size, '\0');
  if (size) {
#if defined(__APPLE__)
    size = ::listxattr(p.c_str(), names.data(), names.size(), XATTR_NOFOLLOW);
#else
    size = ::llistxattr(p.c_str(), names.data(), names.size());
#endif
    if (size < 0)
      throw std::system_error(errno, std::generic_category());
    names.resize(size);
  }
  for (size_t i = 0; i < names.size();) {
    auto name = names.c_str() + i;
    i += strlen(name) + 1;
#if defined(__APPLE__)
    auto n = ::getxattr(p.c_str(), name, nullptr, 0, 0, XATTR_NOFOLLOW);
    std::string data(n < 0 ? 0 : n, '\0');
    if (n >= 0)
      n = ::getxattr(p.c_str(), name, data.data(), data.size(), 0, XATTR_NOFOLLOW);
#else
    auto n = ::lgetxattr(p.c_str(), name, nullptr, 0);
    std::string data(n < 0 ? 0 : n, '\0');
    if (n >= 0)
      n = ::lgetxattr(p.c_str(), name, data.data(), data.size());
#endif
    if (n < 0)
      throw std::system_error(errno, std::generic_category());
    data.resize(n);
    out[name] = data;
  }
#if defined(__APPLE__)
  bool has_acl = false;
  auto acl = acl_get_link_np(p.c_str(), ACL_TYPE_EXTENDED);
  if (acl) {
    acl_entry_t entry;
    has_acl = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) == 0;
    acl_free(acl);
  } else if (errno != ENOENT && errno != ENOTSUP)
    throw std::system_error(errno, std::generic_category());
  return {{"attributes", std::move(out)}, {"platform", "darwin"}, {"acl", has_acl}};
#else
  bool has_acl = false;
  for (auto &item : out)
    has_acl |= item.key().starts_with("system.posix_acl_");
  return {{"attributes", std::move(out)}, {"platform", "linux"}, {"acl", has_acl}};
#endif
}
void attributes(const Filepath &p, const j::object &attrs) {
  if (is_remote(p)) {
    auto a = params(p);
    a["attributes"] = attrs;
    request(Location::decode(p.native()).ssh, "set_attributes", std::move(a));
    return;
  }
  for (auto &item : attrs) {
    auto name = std::string(item.key()), data = std::string(item.value().as_string());
#if defined(__APPLE__)
    auto rc = ::setxattr(p.c_str(), name.c_str(), data.data(), data.size(), 0, XATTR_NOFOLLOW);
#else
    auto rc = ::lsetxattr(p.c_str(), name.c_str(), data.data(), data.size(), 0);
#endif
    if (rc)
      throw std::system_error(errno, std::generic_category());
  }
}
} // namespace RemoteFS
