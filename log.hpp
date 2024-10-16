//
// Copyright 2019 (c) Perun Software Ltd.
// This unpublished material is proprietary to Perun Software Ltd. All rights reserved.
// The methods and techniques described herein are considered trade secrets and/or confidential.
// Reproduction or distribution, in whole or in part, is forbidden except by express written permission of Perun Software Ltd.
//

#ifndef _PERUN_LOG_HPP_
#define _PERUN_LOG_HPP_

#include <condition_variable>
#include <functional>
#include <mutex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace Perun {

// Same as go's defer statement
// https://go.dev/tour/flowcontrol/12
// int main() {
//   Defer later([&]{ std::cout << " world"; });
//   std::cout << "hello";
// }
template <typename Functor>
struct Defer {
  Functor       _func;
  volatile bool _invoke_func = true;

  Defer(Functor&& f)
      : _func(std::forward<Functor>(f)) { }
  ~Defer() {
    try {
      if(_invoke_func) _func();
    } catch(...) {
      // How to report this situation?
    }
  }
  void cancel() { _invoke_func = false; }
};

double now();
double now_ms();

std::string _trace(char const* function, char const* file, long line, char const* message);

#define trace(message) Perun::_trace(__FUNCTION__, __FILE__, __LINE__, (message))

template <typename Functor>
Defer(Functor&& frv) -> Defer<Functor>;

template <typename ValueType>
std::string encodeValue(std::string& name, ValueType& value) {
  std::stringstream ss(std::ios_base::out);
  ss << name << '=' << std::fixed << value;
  return ss.str();
}

struct LogPair {
  std::string encoded;
  template <typename ValueType>
  LogPair(std::string name, ValueType value)
      : encoded(std::move(encodeValue(name, value))) { }
};

using LogParams       = const std::initializer_list<const LogPair>;
using LogParamsVector = std::vector<LogPair>;

class Logger {
private:
  bool _use_time_prefix = false;
  void record(const char* level, const char* TAG, std::string& event, LogParams& params);

public:
  void record_vector(const char* level, const char* TAG, std::string& event, const LogParamsVector& params);
  void output(const std::string& event, LogParams& params);

  std::function<void(std::string const& txt, const char level)> produce;

  Logger();

public:
  void e(const char* TAG, std::string event, LogParams params) { record("E", TAG, event, params); }
  void w(const char* TAG, std::string event, LogParams params) { record("W", TAG, event, params); }
  void i(const char* TAG, std::string event, LogParams params) { record("I", TAG, event, params); }
  void d(const char* TAG, std::string event, LogParams params) { record("D", TAG, event, params); }
  // just event string, without params:
  void e(const char* TAG, std::string event) { record("E", TAG, event, {}); }
  void w(const char* TAG, std::string event) { record("W", TAG, event, {}); }
  void i(const char* TAG, std::string event) { record("I", TAG, event, {}); }
  void d(const char* TAG, std::string event) { record("D", TAG, event, {}); }

  void use_time_prefix(bool use_it) { _use_time_prefix = use_it; }
};

// extern Logger Log;
Logger& Log();

extern Logger& l;

} // namespace Perun

#endif // _PERUN_LOG_HPP_