#include "remote_fs.hpp"
#include "remote_agent_source.hpp"
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
std::string base64(std::string_view in) {
  constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve((in.size() + 2) / 3 * 4);
  for (size_t i = 0; i < in.size(); i += 3) {
    unsigned n = unsigned((unsigned char)in[i]) << 16;
    if (i + 1 < in.size())
      n |= unsigned((unsigned char)in[i + 1]) << 8;
    if (i + 2 < in.size())
      n |= (unsigned char)in[i + 2];
    out += alphabet[n >> 18];
    out += alphabet[(n >> 12) & 63];
    out += i + 1 < in.size() ? alphabet[(n >> 6) & 63] : '=';
    out += i + 2 < in.size() ? alphabet[n & 63] : '=';
  }
  return out;
}
std::string unbase64(std::string_view in) {
  std::string out;
  unsigned value = 0;
  int bits = 0;
  for (unsigned char c : in) {
    if (c == '=')
      break;
    unsigned n;
    if (c >= 'A' && c <= 'Z')
      n = c - 'A';
    else if (c >= 'a' && c <= 'z')
      n = c - 'a' + 26;
    else if (c >= '0' && c <= '9')
      n = c - '0' + 52;
    else if (c == '+')
      n = 62;
    else if (c == '/')
      n = 63;
    else
      throw std::runtime_error("Invalid remote byte encoding");
    value = (value << 6) | n;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += char(value >> bits);
    }
  }
  return out;
}
namespace {
struct Client {
  std::mutex mutex;
  pid_t pid = -1;
  int input = -1, output = -1, diagnostic = -1;
  std::string buffered;
  uint64_t sequence = 0;
  ~Client() { stop(); }
  void stop() {
    if (input >= 0)
      close(input);
    if (output >= 0)
      close(output);
    if (diagnostic >= 0)
      close(diagnostic);
    input = output = diagnostic = -1;
    if (pid > 0) {
      kill(-pid, SIGKILL);
      kill(pid, SIGKILL);
      while (waitpid(pid, nullptr, 0) < 0 && errno == EINTR) {
      }
    }
    pid = -1;
    buffered.clear();
  }
  std::string line(const std::atomic<bool> *cancelled) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    for (;;) {
      auto end = buffered.find('\n');
      if (end != std::string::npos) {
        auto out = buffered.substr(0, end);
        buffered.erase(0, end + 1);
        return out;
      }
      if (cancelled && cancelled->load())
        throw ConnectionError("SSH operation interrupted");
      if (std::chrono::steady_clock::now() >= deadline)
        throw ConnectionError("SSH response timed out; operation outcome needs reconciliation");
      pollfd p{output, POLLIN, 0};
      int rc = poll(&p, 1, 100);
      if (rc < 0 && errno == EINTR)
        continue;
      if (rc < 0)
        throw ConnectionError("SSH transport failed");
      if (!rc)
        continue;
      char bytes[65536];
      auto n = ::read(output, bytes, sizeof bytes);
      if (n <= 0) {
        char detail[4096]{};
        auto len = ::read(diagnostic, detail, sizeof(detail) - 1);
        throw ConnectionError(len > 0 ? std::string(detail, size_t(len)) : "SSH connection closed");
      }
      buffered.append(bytes, size_t(n));
      if (buffered.size() > 64 * 1024 * 1024)
        throw ConnectionError("SSH response exceeded its memory limit");
    }
  }
  void send(std::string_view bytes, const std::atomic<bool> *cancelled = nullptr) {
    // Block SIGPIPE only on this worker, rather than changing process policy.
    sigset_t mask, previous;
    sigemptyset(&mask);
    sigaddset(&mask, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &mask, &previous);
    int error = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!bytes.empty()) {
      if (cancelled && cancelled->load()) {
        error = ECANCELED;
        break;
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        error = ETIMEDOUT;
        break;
      }
      pollfd p{input, POLLOUT, 0};
      auto ready = poll(&p, 1, 100);
      if (ready < 0 && errno == EINTR)
        continue;
      if (!ready)
        continue;
      if (ready < 0) {
        error = errno;
        break;
      }
      auto n = ::write(input, bytes.data(), bytes.size());
      if (n < 0 && (errno == EINTR || errno == EAGAIN))
        continue;
      if (n <= 0) {
        error = errno;
        break;
      }
      bytes.remove_prefix(size_t(n));
    }
    if (error == EPIPE) {
      sigset_t pending;
      sigpending(&pending);
      if (sigismember(&pending, SIGPIPE)) {
        int signal;
        sigwait(&mask, &signal);
      }
    }
    pthread_sigmask(SIG_SETMASK, &previous, nullptr);
    if (error)
      throw ConnectionError("Cannot send to SSH helper");
  }
  void start(const std::string &host, const std::atomic<bool> *cancelled) {
    int in[2]{-1, -1}, out[2]{-1, -1}, err[2]{-1, -1};
    if (pipe(in) || pipe(out) || pipe(err)) {
      for (auto fd : {in[0], in[1], out[0], out[1], err[0], err[1]})
        if (fd >= 0)
          close(fd);
      throw ConnectionError("Cannot create SSH pipes");
    }
    for (auto fd : {in[0], in[1], out[0], out[1], err[0], err[1]})
      fcntl(fd, F_SETFD, FD_CLOEXEC);
    std::string bootstrap = "python3 -u -c 'import sys;exec(sys.stdin.buffer.read(" +
                            std::to_string(remote_agent_source.size()) + ").decode())'";
    std::vector<std::string> args{"ssh", "-T",
                                  "-o",  "BatchMode=yes",
                                  "-o",  "StrictHostKeyChecking=yes",
                                  "-o",  "ControlMaster=auto",
                                  "-o",  "ControlPersist=600",
                                  "-o",  "ControlPath=" + control_path(host),
                                  "-o",  "ConnectTimeout=10",
                                  "-o",  "ServerAliveInterval=10",
                                  "-o",  "ServerAliveCountMax=2",
                                  host,  bootstrap};
    if (const char *binary = std::getenv("FC_SSH_BIN"))
      args[0] = binary;
    std::vector<char *> argv;
    for (auto &a : args)
      argv.push_back(a.data());
    argv.push_back(nullptr);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    int rc = posix_spawnp(&pid, argv[0], &actions, &attr, argv.data(), environ);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    close(in[0]);
    close(out[1]);
    close(err[1]);
    input = in[1];
    output = out[0];
    diagnostic = err[0];
    fcntl(diagnostic, F_SETFL, O_NONBLOCK);
    fcntl(input, F_SETFL, O_NONBLOCK);
    if (rc) {
      pid = -1;
      stop();
      throw ConnectionError("Cannot launch OpenSSH: " + std::string(strerror(rc)));
    }
    send(remote_agent_source, cancelled);
    auto ready = j::parse(line(cancelled)).as_object();
    if (!ready.contains("version") || ready.at("version").as_int64() != 1)
      throw ConnectionError("Incompatible SSH filesystem helper");
  }
};
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
  if (auto at = o.find("link64"); at != o.end())
    m.link = unbase64(at->value().as_string());
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
  const bool credit = method == "copy" && p.contains("checkpoint") && p.at("checkpoint").as_bool();
  try {
    if (client->pid < 0)
      client->start(host, cancelled);
    auto id = ++client->sequence;
    client->send(j::serialize(j::object{{"id", id}, {"method", method}, {"params", std::move(p)}}) + "\n",
                 cancelled);
    j::array entries;
    for (;;) {
      auto reply = j::parse(client->line(cancelled)).as_object();
      if (number(reply, "id") != id)
        throw ConnectionError("SSH response identity mismatch");
      if (auto at = reply.find("error"); at != reply.end()) {
        auto code = number(reply, "errno");
        throw std::system_error(int(code ? code : EIO), std::generic_category(),
                                std::string(at->value().as_string()));
      }
      if (auto at = reply.find("data"); at != reply.end()) {
        auto &data = at->value().as_object();
        if (data.contains("bytes")) {
          if (progress)
            progress(number(data, "bytes"));
          if (credit)
            client->send("continue\n", cancelled);
        }
        if (data.contains("entries"))
          for (auto &entry : data.at("entries").as_array()) {
            if (entries.size() >= 1000000)
              throw ConnectionError("SSH listing exceeded its entry limit");
            entries.push_back(std::move(entry));
          }
        continue;
      }
      auto result = std::move(reply.at("result"));
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
  }
}
void close_connections() {
  std::lock_guard guard(registry_mutex);
  clients.clear();
}
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
  if (const char *binary = getenv("FC_SSH_BIN"))
    args[0] = binary;
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
          {"ctime_ns", ctime_ns}, {"link64", base64(link)}};
}
j::object params(const Filepath &p) {
  auto l = Location::decode(p.native());
  return {{"path64", base64(l.local.native())}};
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
      out.push_back({p / unbase64(o.at("name64").as_string()), std::move(m)});
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
  l.local = unbase64(request(l.ssh, "realpath", params(p)).as_object().at("path64").as_string());
  return l.resource();
}
std::string read(const Filepath &p, uint64_t offset, size_t length) {
  if (is_remote(p)) {
    auto a = params(p);
    a["offset"] = offset;
    a["length"] = length;
    return unbase64(request(Location::decode(p.native()).ssh, "read", std::move(a), nullptr, true)
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
    a["data"] = base64(data);
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
    a["destination64"] = base64(r.local.native());
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
    a["target64"] = base64(target);
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
  if (is_remote(p))
    return std::string(request(Location::decode(p.native()).ssh, "digest", params(p), cancelled, true)
                           .as_object()
                           .at("sha256")
                           .as_string());
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
    out[base64(name)] = base64(data);
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
    has_acl |= unbase64(item.key()).starts_with("system.posix_acl_");
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
    auto name = unbase64(item.key()), data = unbase64(item.value().as_string());
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
