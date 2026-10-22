#include "remote_protocol.hpp"
#include "support/contracts.hpp"
#include <iostream>
using namespace RemoteFS;
using test::require;
static boost::json::object sample() {
  return {{"path", std::string("/tmp/raw-\xff", 10)}, {"data", std::string("\0\xff\r\n", 4)},
          {"sha256", std::string(32, char(0xa5))}, {"offset", UINT64_MAX}, {"mtime_ns", INT64_MIN},
          {"attributes", boost::json::object{{std::string("user.\xff", 6), std::string("\0\1", 2)}}},
          {"entries", boost::json::array{nullptr, true, false, boost::json::object{}}}};
}
int main(int argc, char **argv) {
  try {
    auto original = sample();
    auto encoded = Wire::encode(original);
    if (argc > 1 && std::string(argv[1]) == "--emit") {
      std::cout.write(encoded.data(), encoded.size()); return 0;
    }
    if (argc > 1 && std::string(argv[1]) == "--accept") {
      std::string input(std::istreambuf_iterator<char>(std::cin), {});
      require(Wire::decode(input) == original, "Python/C++ binary values differ"); return 0;
    }
    require(Wire::decode(encoded) == original, "Binary roundtrip changed bytes or integers");
    for (size_t n = 0; n < encoded.size(); ++n) {
      bool rejected = false;
      try { Wire::decode(std::string_view(encoded).substr(0, n)); }
      catch (const std::exception &) { rejected = true; }
      require(rejected, "Truncated binary value was accepted");
    }
    for (const auto &bad : {encoded + "x", std::string("\6\xff\xff\xff\xff", 5),
                           std::string("\7\xff\xff\xff\xff", 5), std::string(1, char(255))}) {
      bool rejected = false;
      try { Wire::decode(bad); } catch (const std::exception &) { rejected = true; }
      require(rejected, "Invalid binary value was accepted");
    }
    auto header = Wire::header(Wire::Data, Wire::opcode("stream_write"), UINT64_MAX, Wire::block_size);
    uint32_t length;
    auto frame = Wire::header(header, length);
    require(frame.kind == Wire::Data && frame.id == UINT64_MAX && length == Wire::block_size,
            "Binary frame header changed");
    header[1] = 1;
    bool rejected = false;
    try { Wire::header(header, length); } catch (const std::exception &) { rejected = true; }
    require(rejected, "Unknown frame flags were accepted");
    std::cout << "PASS binary codec bounds, raw bytes and integer extremes\n";
    return 0;
  } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
