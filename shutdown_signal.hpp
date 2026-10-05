#pragma once
#include <csignal>

// The handler only records a signal. UI/child wait loops perform the shutdown.
inline volatile std::sig_atomic_t fc_shutdown_signal = 0;
inline bool shutdown_requested() { return fc_shutdown_signal != 0; }
class ShutdownSignals {
  struct sigaction old_hup{}, old_term{};
  static void record(int signal) { fc_shutdown_signal = signal; }
 public:
  ShutdownSignals() {
    struct sigaction action{};
    action.sa_handler = record;
    sigemptyset(&action.sa_mask);
    sigaction(SIGHUP, &action, &old_hup);
    sigaction(SIGTERM, &action, &old_term);
  }
  ~ShutdownSignals() {
    sigaction(SIGHUP, &old_hup, nullptr);
    sigaction(SIGTERM, &old_term, nullptr);
  }
};
