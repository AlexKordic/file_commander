
#ifndef FC_ERR_H_
#define FC_ERR_H_

#include <string>
#include <vector>

//
// Err halts curent operation and propagates up, Use Chk(err).
// 
// Problems is global cache holding reported issues to show to humans via error funnel.
//

struct Err {
  std::vector<std::string> steps;

  Err() { }
  Err(std::string where) {
    steps.push_back(std::move(where));
  }

  bool ok() { return steps.empty(); }
  // void print();
};

#define Chk(...)                   \
  {                                \
    Err e_ = __VA_ARGS__;          \
    if(e_.ok() == false) {         \
      e_.steps.push_back(trace()); \
      return e_;                   \
    }                              \
  }

#define PrintErr(...)     \
  {                       \
    Err e_ = __VA_ARGS__; \
    e_.print();           \
  }

struct Problems {
  struct Messages {
    double                   latest_item;
    std::vector<std::string> messages;
  };
  static double   report(std::string message);
  static Messages get();
  static void     clear(double up_to);
};

#endif // FC_ERR_H_
