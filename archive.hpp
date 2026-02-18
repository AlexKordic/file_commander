#ifndef FC_ARCHIVE_HPP_
#define FC_ARCHIVE_HPP_

#include "bfs.hpp"
#include "err.hpp"

#include <ctime>
#include <mutex>
#include <string>
#include <vector>

bool is_archive_file_path(const Filepath& path);
bool path_is_under(const Filepath& parent, const Filepath& child);

class ArchiveService {
 public:
  void        set_tool_path(std::string tool_path);
  std::string tool_path() const;

  Err extract_to_cache(const Filepath& archive_path, Filepath& extracted_root);
  Err create_archive(const Filepath& archive_path, const std::vector<Filepath>& sources, const Filepath& preferred_cwd = Filepath());

 private:
  struct CacheEntry {
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

#endif  // FC_ARCHIVE_HPP_
