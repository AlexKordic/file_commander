
#include "err.hpp"
#include "log.hpp"

#include <mutex>
#include <string>
#include <vector>

namespace {

struct Issue {
  std::string msg;
  double      ts;

  Issue(std::string message)
      : msg(std::move(message))
      , ts(Perun::now()) { }
};

struct Issues {
  std::vector<Issue> items;
  std::mutex         _m;
};

Issues& Global() {
  static Issues _issues;
  return _issues;
}

} // namespace

double Problems::report(std::string message) {
  Issues&         i = Global();
  std::lock_guard l(i._m);
  return i.items.emplace_back(std::move(message)).ts;
}

void Problems::clear(double up_to) {
  Issues&         i = Global();
  std::lock_guard l(i._m);

  std::erase_if(i.items, [up_to=up_to](Issue& i) -> bool { return i.ts <= up_to; });
}
