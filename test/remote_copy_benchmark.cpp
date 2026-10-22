// Explicit performance qualification tool; never part of an automatic test lane.
#include "file_io_jobs.hpp"
#include "remote_fs.hpp"
#include <boost/json.hpp>
#include <chrono>
#include <format>
#include <iostream>
#include <sys/resource.h>
#include <sys/stat.h>
#include <thread>
using namespace Perun;
int main(int argc, char **argv) {
  try {
    if (argc != 5) throw std::runtime_error("usage: fc_remote_copy_benchmark SOURCE_DIR TARGET_DIR FILE_COUNT JOURNAL_DIR");
    const auto source = Location::decode(argv[1]).resource(), target = Location::decode(argv[2]).resource();
    const auto count = std::stoul(argv[3]);
    if (count == 0 || count > 10000) throw std::runtime_error("FILE_COUNT must be between 1 and 10000");
    auto plan = std::make_shared<OperationPlan>();
    uint64_t bytes = 0;
    for (size_t n = 0; n < count; ++n) {
      const auto name = std::format("payload-{:04}.bin", n);
      const auto metadata = RemoteFS::inspect(source / name);
      if (!metadata.exists || !S_ISREG(metadata.mode)) throw std::runtime_error("Benchmark source is not a regular file");
      bytes += metadata.size;
      plan->steps.push_back({Operation::Kind::CopyFile, source / name, target / name, {}, "", metadata.size});
    }
    auto jobs = make_file_jobs(); jobs->enable_recovery(argv[4]);
    auto job = std::make_shared<JobSpec>(plan);
    const auto protocol_before = RemoteFS::protocol_stats();
    const auto started = std::chrono::steady_clock::now();
    if (!jobs->add_job(job)) throw std::runtime_error("Benchmark job was rejected");
    while (!jobs->idle()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    const auto protocol_after = RemoteFS::protocol_stats();
    auto final = job->snapshot();
    jobs->shutdown(); RemoteFS::close_connections();
    rusage usage{}; getrusage(RUSAGE_SELF, &usage);
    const auto cpu = usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
        (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000000.0;
    uint64_t rss = usage.ru_maxrss;
#if !defined(__APPLE__)
    rss *= 1024;
#endif
    const bool passed = final->_state == JobState::COMPLETED && final->_transfer_written == bytes &&
        final->_transfer_verified == bytes && final->_transfer_durable == bytes;
    boost::json::object result{{"passed", passed}, {"bytes", bytes}, {"seconds", seconds},
        {"mib_per_second", bytes / seconds / (1024 * 1024)}, {"local_cpu_seconds", cpu}, {"peak_rss_bytes", rss},
        {"written", final->_transfer_written}, {"verified", final->_transfer_verified}, {"durable", final->_transfer_durable},
        {"data_fsync_count", final->_transfer_data_flushes}, {"files", count},
        {"fc_protocol_sent", protocol_after.sent - protocol_before.sent},
        {"fc_protocol_received", protocol_after.received - protocol_before.received}, {"error", final->_recovery_note}};
    std::cout << boost::json::serialize(result) << '\n';
    return passed ? 0 : 1;
  } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
