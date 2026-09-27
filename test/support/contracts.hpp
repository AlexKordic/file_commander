#pragma once
#include "commander.hpp"
#include <chrono>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <stdexcept>
#include <thread>
namespace test {
namespace fs = boost::filesystem;
inline void require(bool ok, const std::string& message) { if (!ok) throw std::runtime_error(message); }
struct Fixture {
  Filepath root;
  explicit Fixture(Filepath parent=fs::temp_directory_path()) : root(parent/fs::unique_path("fc-contract-%%%%-%%%%-%%%%")) { fs::create_directories(root); }
  ~Fixture() { boost::system::error_code ec; fs::remove_all(root,ec); }
  Filepath operator/(const std::string& name) const { return root/name; }
};
inline void write(const Filepath& path,const std::string& data) {
  std::ofstream stream(path.string(),std::ios::binary);stream.write(data.data(),data.size());
  require(bool(stream),"fixture write failed: "+path.string());
}
inline std::string read(const Filepath& path) { std::ifstream in(path.string(),std::ios::binary); require(bool(in),"fixture read failed: "+path.string());return {std::istreambuf_iterator<char>(in),{}}; }
template<class F> void until(F predicate, const std::string& message) {
  auto end=std::chrono::steady_clock::now()+std::chrono::seconds(5);
  while(!predicate() && std::chrono::steady_clock::now()<end) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  require(predicate(),message);
}
// Worker-side wait never throws across a thread boundary; tests assert reached
// and released states. Release guard must be declared after the worker owner.
class Gate {
  std::mutex mutex;std::condition_variable cv;bool entered=false, released=false;
 public:
  bool arrive() {std::unique_lock lock(mutex);entered=true;cv.notify_all();return cv.wait_for(lock,std::chrono::seconds(5),[&]{return released;});}
  void await() {std::unique_lock lock(mutex);require(cv.wait_for(lock,std::chrono::seconds(5),[&]{return entered;}),"gate was not reached");}
  void open() {std::lock_guard lock(mutex);released=true;cv.notify_all();}
  struct Release {Gate& gate;~Release(){gate.open();}};
};
}
