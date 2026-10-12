#ifndef FC_SEVENZIP_HPP_
#define FC_SEVENZIP_HPP_

// 7-Zip's archive library, 7z.so, loaded at run time and used in-process: list an archive without extracting it, extract the entries asked for to files FC chooses, and write new archives. Nothing here includes 7-Zip's headers; sevenzip.cpp keeps its COM-style types to itself.

#include "bfs.hpp"
#include "err.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace SevenZip {

struct Format {
  std::string name;                     // 7-Zip's name for it: "7z", "zip", "gzip", "tar", ...
  std::vector<std::string> extensions;  // lower case, without dots, as the library lists them
  bool writable = false;
};

struct Entry {
  uint32_t index = 0;
  std::string path;  // '/'-separated UTF-8, as the archive stores it
  bool directory = false;
  bool encrypted = false;
  std::optional<uint64_t> size;
  std::optional<int64_t> modified_ns;  // since the Unix epoch
  std::optional<uint32_t> posix_mode;  // st_mode bits, when the archive keeps them
  std::string symlink;                 // the target, when the entry is a symbolic link
  std::string hardlink;                // the entry it is a hard link to (tar), whose data it shares
};

// What a long operation reports, and how it is stopped.
struct Progress {
  std::function<void(uint64_t done, uint64_t total)> report;
  const std::atomic<bool>* cancelled = nullptr;
};

// Asked for an encrypted archive's password: `wrong` says the archive refused the one it gave last time. nullopt gives up.
using PasswordSource = std::function<std::optional<std::string>(bool wrong)>;

// The most entries FC lists in one archive (1,000,000); an archive claiming more is refused, so its index can't exhaust memory. Tests lower it.
size_t entry_limit();
void set_entry_limit(size_t limit);

// The library is loaded on first use. When it can't be found, or isn't the 7-Zip version FC was built against, `available()` is false and `error()` says why.
bool available();
std::string error();
const std::vector<Format>& formats();
const Format* find_format(const std::string& name);
// Load the library from here instead of the default places: next to fc, the package's lib/file-commander, then the build tree. Only takes effect before first use.
void set_library_path(const Filepath&);

class Archive {
 public:
  ~Archive();
  Archive(const Archive&) = delete;
  Archive& operator=(const Archive&) = delete;

  // Opens `file` as `format` (a Format::name) when one is given, and otherwise, or when that fails, as the formats its extension and its first bytes suggest.
  static Err open(const Filepath& file, const std::string& format, std::unique_ptr<Archive>& out,
                  const PasswordSource& password = {}, const Progress& progress = {});

  const std::string& format() const;
  const std::vector<Entry>& entries() const;

  // Extracts the entries at `indices` in one pass. `output` is asked about each of them, folders and links included, and names the file a file's data is written to, created new; an empty path skips it. Folders and links have no data, so what it answers for them is ignored. `finished` hears how each written entry went; a failed entry's file is left for the caller to remove. When some are encrypted, a test pass over the first of them checks the password first, asking again while it is wrong.
  Err extract(const std::vector<uint32_t>& indices, const std::function<Filepath(const Entry&)>& output,
              const std::function<void(const Entry&, Err)>& finished, const PasswordSource& password = {},
              const Progress& progress = {});

  struct State;

 private:
  void read_link_targets(const PasswordSource& password, const Progress& progress);
  friend Err read_compressed_tar(const Filepath&, const std::string&, const std::function<Filepath(const Entry&)>&,
                                 const std::function<void(const Entry&, Err)>&, const Progress&);
  explicit Archive(std::unique_ptr<State>);
  std::unique_ptr<State> _state;
};

// A tar inside a compressed stream (tar.gz, tar.xz, ...) read in one sequential pass: the compression handler decodes into the tar reader through memory, so no part of the tar is written anywhere. `output` is asked about every entry in order; its `index` counts entries from 0 and is the same on every pass over the same file. A path extracts the entry there, created new; empty skips it. Listing is a pass whose `output` always answers empty. `compression` is a Format::name, or empty to detect it.
Err read_compressed_tar(const Filepath& file, const std::string& compression, const std::function<Filepath(const Entry&)>& output,
                        const std::function<void(const Entry&, Err)>& finished = {}, const Progress& progress = {});

struct NewItem {
  Filepath source;   // a file or folder on disk; folders are added with everything in them
  std::string name;  // its '/'-separated path inside the archive
};

struct Encryption {
  std::string password;        // empty: not encrypted
  bool encrypt_names = false;  // 7z: the list of entries is encrypted too, so opening asks for the password
};

// Writes a new `format` archive holding `items` to `destination`, which must not exist yet. Symbolic links are stored as links; a single-stream format (gzip, bzip2, xz) takes exactly one file.
Err create(const std::string& format, const std::vector<NewItem>& items, const Filepath& destination,
           const Progress& progress = {}, const Encryption& encryption = {});

// Writes a tar of `items`, compressed as `compression` (gzip, bzip2 or xz), to `destination` in one pass: tar writes into memory that the compressor reads on another thread, so no .tar is stored anywhere.
Err create_compressed_tar(const std::string& compression, const std::vector<NewItem>& items, const Filepath& destination,
                          const Progress& progress = {});

}  // namespace SevenZip

#endif  // FC_SEVENZIP_HPP_
