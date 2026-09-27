#ifndef FC_ARCHIVE_HPP_
#define FC_ARCHIVE_HPP_

#include "bfs.hpp"
#include "err.hpp"
#include "location.hpp"
#include <memory>

#include <ctime>
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

bool is_archive_file_path(const Filepath& path);
bool path_is_under(const Filepath& parent, const Filepath& child);

enum class ArchiveConflict { Replace, Update, Skip };

struct ArchiveRoot {
  Filepath root;
  explicit ArchiveRoot(Filepath p) : root(std::move(p)) {}
  ~ArchiveRoot();
};
using ArchiveLease = std::shared_ptr<const ArchiveRoot>;
struct ResolvedArchive { Filepath archive_file, extracted_root; ArchiveLease lease; };
struct ResolvedLocation { Filepath path; std::vector<ResolvedArchive> archives; };

class ArchiveService {
 public:
  ~ArchiveService();
  void        set_tool_path(std::string tool_path);
  std::string tool_path() const;
  bool is_cached_path(const Filepath& path) const;

  Location logical_location(const Filepath&) const;
  ArchiveLease lease_for_path(const Filepath&) const;
  Err resolve(const Location&, ResolvedLocation&, std::atomic<bool>* cancelled = nullptr);
  Err extract_to_cache(const Filepath& archive_path, Filepath& extracted_root, std::atomic<bool>* cancelled = nullptr, ArchiveLease* lease = nullptr);
  Err create_archive(const Filepath& archive_path, const std::vector<Filepath>& sources, const Filepath& preferred_cwd = Filepath(), ArchiveConflict conflict = ArchiveConflict::Replace, std::atomic<bool>* cancelled = nullptr, bool* skipped = nullptr);

 private:
  struct CacheEntry {
    ArchiveLease lease;
    Filepath root;
    Filepath canonical_archive;
    uintmax_t size  = 0;
    std::time_t mtime = 0;
  };

  mutable std::mutex    _mutex;
  std::string           _tool_path;
  std::vector<CacheEntry> _cache;
};

ArchiveService& archive_service();
// Empty for writable paths; archive cache entries are copy-out only.
std::string archive_mutation_error(const Filepath& path);

#endif  // FC_ARCHIVE_HPP_
