#pragma once
// Internal SSH pipe transport, shared by RPC and continuous stream channels.
#include "remote_fs.hpp"
#include "remote_protocol.hpp"
#include "remote_agent_source.hpp"
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
namespace RemoteFS::detail {
inline std::atomic<uint64_t> protocol_sent{0}, protocol_received{0};
struct Transport {
  std::mutex mutex;
  pid_t pid = -1;
  int input = -1, output = -1, diagnostic = -1;
  uint64_t sequence = 0;
  bool unlimited_idle = false; // Streaming channels may be explicitly paused indefinitely.
  ~Transport() { stop(); }
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
  }
  std::string exact(size_t size, const std::atomic<bool> *cancelled) {
    std::string bytes(size, '\0');
    size_t offset = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (offset < size) {
      if (cancelled && cancelled->load())
        throw ConnectionError("SSH operation interrupted");
      if (!unlimited_idle && std::chrono::steady_clock::now() >= deadline)
        throw ConnectionError("SSH response timed out; operation outcome needs reconciliation");
      pollfd p{output, POLLIN, 0};
      int rc = poll(&p, 1, 100);
      if (rc < 0 && errno == EINTR)
        continue;
      if (rc < 0)
        throw ConnectionError("SSH transport failed");
      if (!rc)
        continue;
      auto n = ::read(output, bytes.data() + offset, size - offset);
      if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (n <= 0) {
        char detail[4096]{};
        auto len = ::read(diagnostic, detail, sizeof(detail) - 1);
        throw ConnectionError(len > 0 ? std::string(detail, size_t(len)) : "SSH connection closed");
      }
      offset += size_t(n);
      protocol_received.fetch_add(size_t(n), std::memory_order_relaxed);
      deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    }
    return bytes;
  }
  Wire::Frame receive(const std::atomic<bool> *cancelled) {
    try {
      uint32_t size;
      auto frame = Wire::header(exact(16, cancelled), size);
      frame.payload = exact(size, cancelled);
      return frame;
    } catch (const ConnectionError &) { throw; }
    catch (const std::exception &e) { throw ConnectionError(e.what()); }
  }
  void frame(uint8_t kind, uint16_t operation, uint64_t id, std::string_view payload,
             const std::atomic<bool> *cancelled = nullptr) {
    send(Wire::header(kind, operation, id, payload.size()), cancelled);
    send(payload, cancelled);
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
      if (!unlimited_idle && std::chrono::steady_clock::now() >= deadline) {
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
      protocol_sent.fetch_add(size_t(n), std::memory_order_relaxed);
      deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
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
    args[0] = ssh_command(host);
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
    if (exact(Wire::hello.size(), cancelled) != Wire::hello)
      throw ConnectionError("Incompatible SSH filesystem helper");
  }
};
} // namespace RemoteFS::detail
