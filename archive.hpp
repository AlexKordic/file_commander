#ifndef FC_ARCHIVE_HPP_
#define FC_ARCHIVE_HPP_

// Archives as a read-only filesystem. An "fc-archive:" path (location.hpp) names a folder or file inside an archive, which 7-Zip's library (sevenzip.hpp) lists and extracts on demand: browsing reads the archive's index, and only the entries copied out are ever extracted.

#include "bfs.hpp"
#include "err.hpp"
#include "location.hpp"
#include "sevenzip.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

bool is_archive_file_path(const Filepath& path);  // A file Enter opens as an archive, by its name.
bool path_is_under(const Filepath& parent, const Filepath& child);

enum class ArchiveConflict { Replace, Update, Skip };

// The path of the root folder of `archive`, a local file or a file inside another archive.
Filepath archive_root(const Filepath& archive);
// The archive file whose root `path` is, or empty when `path` is not an archive's root.
Filepath archive_file_of(const Filepath& path);
// Empty for paths FC may change; archive contents are copy-out only.
std::string archive_mutation_error(const Filepath& path);

namespace ArchiveFS {

struct Metadata {
  bool exists = false, directory = false;
  uint64_t size = 0;
  int64_t mtime_ns = 0;
  uint32_t mode = 0;  // st_mode, type bits included
  std::string link;   // a symbolic link's target
  bool symlink() const;
  boost::filesystem::file_status status() const;
};
struct Entry {
  Filepath path;
  Metadata metadata;
};

// Both throw std::runtime_error when the archive can't be opened, or for list, when `folder` isn't a folder in it.
Metadata inspect(const Filepath& path);
std::vector<Entry> list(const Filepath& folder, const std::atomic<bool>* cancelled = nullptr);

// Extracts archive files to new local files, in one pass per archive. `finished` hears how each went; an output that failed is left for the caller to remove. `progress` gets the bytes written so far.
struct Item {
  Filepath source, output;
};
Err extract(const std::vector<Item>& items, const std::function<void(const Item&, Err)>& finished, const std::atomic<bool>* cancelled = nullptr,
            const std::function<void(uint64_t)>& progress = {});

// Extracts every entry of `archive` (a local file, or a file inside another archive) in one pass: a compressed tar's entries as they stream past, a compressed file's one file, or every entry of any other archive. `output` is asked about every entry and names the file to write a file's data to, or empty to skip it (folders and links have no data); `finished` hears how each written one went. Progress counts compressed bytes read for a compressed tar. `room`, when the archive says how big its files are (a compressed tar doesn't), hears that total before anything is written; an answer that isn't empty refuses the extraction with that reason.
Err extract_all(const Filepath& archive, const std::function<Filepath(const SevenZip::Entry&)>& output,
                const std::function<void(const SevenZip::Entry&, Err)>& finished, const std::atomic<bool>* cancelled = nullptr,
                const std::function<void(uint64_t done, uint64_t total)>& progress = {},
                const std::function<std::string(uint64_t bytes)>& room = {});

// Archives stay open while browsed; these close the ones nobody is using.
void close_unused();
size_t open_count();

// Shows the person a question for an encrypted archive's password and returns at once; `answer` hears the password, or nullopt when they decline, from any thread (only its first call counts). `archive` is the archive as FC displays it, and `wrong` says the last password given for it was refused. The reading thread waits for the answer, and gives up when its read is cancelled (Stop on a pane, a job's Cancel, shutdown), so a question nobody answers never holds up a quit. Set the prompt on the thread that shows the questions: that thread is never made to wait, and reads there needing a password fail instead. Passwords that work are kept for the session, for the same archive file.
using PasswordAnswer = std::function<void(std::optional<std::string>)>;
using PasswordPrompt = std::function<void(const std::string& archive, bool wrong, PasswordAnswer answer)>;
void set_password_prompt(PasswordPrompt prompt);
void forget_passwords();

// While one is alive on a thread, the long reads ArchiveFS does there (opening an archive, listing a compressed tar) report how far they are, from 0 to 1.
class ReadProgress {
 public:
  explicit ReadProgress(std::function<void(double)> report);
  ~ReadProgress();
  ReadProgress(const ReadProgress&) = delete;
  ReadProgress& operator=(const ReadProgress&) = delete;

 private:
  std::function<void(double)> _report;
  std::function<void(double)>* _outer;
};

}  // namespace ArchiveFS

// Writes a new archive holding `sources` to `archive_path`, in the format its name says (archive_destination: 7z, zip, tar, a compressed tar, or one compressed file), through a private staging folder next to it. `conflict` decides what happens to an existing destination; `preferred_cwd`, when it holds every source, is where the names inside the archive start.
Err create_archive(const Filepath& archive_path, const std::vector<Filepath>& sources, const Filepath& preferred_cwd = Filepath(),
                   ArchiveConflict conflict = ArchiveConflict::Replace, std::atomic<bool>* cancelled = nullptr, bool* skipped = nullptr);

#endif  // FC_ARCHIVE_HPP_
