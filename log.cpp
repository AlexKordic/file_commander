#pragma GCC target("avx2")
#pragma GCC optimize("O3")

#include "log.hpp"

#include <iomanip>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <thread>

#include <sys/time.h>
#include <time.h>

namespace Perun {

double now() {
  struct timeval tv;
  int            zero = gettimeofday(&tv, nullptr);
  return static_cast<double>(tv.tv_sec) + (tv.tv_usec / 1000000.0);
}
double now_ms() {
  struct timeval tv;
  int            zero = gettimeofday(&tv, nullptr);
  return static_cast<double>(tv.tv_sec * 1000.0) + (static_cast<double>(tv.tv_usec) / 1000.0);
}

static void _record(std::stringstream& ss, bool use_time_prefix, const char* level, const char* TAG, std::string& event) {
  if(use_time_prefix) {
    const double ts                 = Perun::now();
    const int    millis             = (int)((ts - ((int64_t)ts)) * 1000);
    std::time_t  seconds_from_epoch = (time_t)ts;

    struct tm gmtime_result;
#ifdef _WIN32
    auto gmtime_status = gmtime_s(&gmtime_result, &seconds_from_epoch);
    if(gmtime_status == 0) {
#else  // ^ _WIN32, >> linux
    auto gmtime_status = gmtime_r(&seconds_from_epoch, &gmtime_result);
    if(gmtime_status != nullptr) {
#endif // _WIN32
      ss << std::put_time(&gmtime_result, "%y/%m/%d %H:%M:%S.") << std::setw(3) << std::setfill('0') << millis << std::setw(0) << std::setfill(' ') << " ";
    } else {
      ss << "e/r/r o:r:!." << millis << " ";
    }
  }
  ss << level << " " << TAG << " " << event;
}

void Logger::record(const char* level, const char* TAG, std::string& event, LogParams& params) {
  std::stringstream ss(std::ios_base::out);
  _record(ss, _use_time_prefix, level, TAG, event);
  for(LogPair const& pair: params) {
    ss << " " << pair.encoded;
  }
  ss << "  \n";
  printLogRecord(ss.str(), level[0]);
}

void Logger::record_vector(const char* level, const char* TAG, std::string& event, const LogParamsVector& params) {
  std::stringstream ss(std::ios_base::out);
  _record(ss, _use_time_prefix, level, TAG, event);
  for(LogPair const& pair: params) {
    ss << " " << pair.encoded;
  }
  ss << "\n";
  printLogRecord(ss.str(), level[0]);
}

void Logger::output(const std::string& event, LogParams& params) {
  std::stringstream ss(std::ios_base::out);
  ss << event;
  for(LogPair const& pair: params) {
    ss << " " << pair.encoded;
  }
  // ss << "\n";
  // printLogRecord(ss.str(), 'D');
  std::cout << ss.str();
}

// define global object
Logger& Log() {
  static Logger log_singleton;
  return log_singleton;
}

Logger& l = Log();

std::string _trace(char const* function, char const* file, long line, char const* message) {
  char buf[251];
  snprintf(buf, 250, "%s[%s:%ld], %s\n", function, file, line, message);
  buf[250] = 0;
  return buf;
}

} // namespace Perun

#ifdef _WIN32
#include <Windows.h>
#else
#include <iostream>
#include <unistd.h>
#endif

extern void printLogRecord(std::string const& txt, const char level) {
  // the following are UBUNTU/LINUX, and MacOS ONLY terminal color codes.
  //  RESET   "\033[0m"
  //  BLACK   "\033[30m"      /* Black */
  //  RED     "\033[31m"      /* Red */
  //  GREEN   "\033[32m"      /* Green */
  //  YELLOW  "\033[33m"      /* Yellow */
  //  BLUE    "\033[34m"      /* Blue */
  //  MAGENTA "\033[35m"      /* Magenta */
  //  CYAN    "\033[36m"      /* Cyan */
  //  WHITE   "\033[37m"      /* White */
  //  BOLDBLACK   "\033[1m\033[30m"      /* Bold Black */
  //  BOLDRED     "\033[1m\033[31m"      /* Bold Red */
  //  BOLDGREEN   "\033[1m\033[32m"      /* Bold Green */
  //  BOLDYELLOW  "\033[1m\033[33m"      /* Bold Yellow */
  //  BOLDBLUE    "\033[1m\033[34m"      /* Bold Blue */
  //  BOLDMAGENTA "\033[1m\033[35m"      /* Bold Magenta */
  //  BOLDCYAN    "\033[1m\033[36m"      /* Bold Cyan */
  //  BOLDWHITE   "\033[1m\033[37m"      /* Bold White */
  static std::map<char, std::string> _colors = {
    {'E', "\033[1m\033[31m"},
    {'W', "\033[1m\033[33m"},
    {'I', "\033[1m\033[32m"},
    // {'D', "\033[36m"},
    {'D', ""},
  };
  static std::string _reset("\033[0m");
  static bool        is_tty = isatty(fileno(stdout)) == 1;

  if(is_tty) std::cout << _colors[level];
  std::cout << txt;
  if(is_tty) std::cout << _reset;
}
