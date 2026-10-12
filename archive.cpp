#include "archive.hpp"
#include "sevenzip.hpp"

#include <boost/filesystem.hpp>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <unordered_map>

#include <sys/stat.h>

namespace {

std::string to_lower_ascii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    if (c >= 'A' && c <= 'Z') return static_cast<char>(c - 'A' + 'a');
    return static_cast<char>(c);
  });
  return value;
}

Filepath absolute_path_safe(const Filepath& path) {
  if (path.is_absolute()) return path.lexically_normal();
  boost::system::error_code ec;
  const Filepath cwd = boost::filesystem::current_path(ec);
  if (!ec.failed()) return (cwd / path).lexically_normal();
  return path.lexically_normal();
}

Filepath common_prefix_path(const std::vector<Filepath>& paths) {
  if (paths.empty()) return Filepath();
  std::vector<std::vector<Filepath>> components;
  components.reserve(paths.size());
  for (const auto& p : paths) {
    std::vector<Filepath> c;
    for (const auto& part : p) c.push_back(part);
    components.push_back(std::move(c));
  }
  size_t max_prefix = components.front().size();
  for (size_t i = 1; i < components.size(); ++i) max_prefix = std::min(max_prefix, components[i].size());
  size_t prefix = 0;
  for (; prefix < max_prefix; ++prefix) {
    const auto& ref = components.front()[prefix];
    bool all_match = true;
    for (size_t i = 1; i < components.size(); ++i)
      if (components[i][prefix] != ref) {
        all_match = false;
        break;
      }
    if (!all_match) break;
  }
  Filepath out;
  for (size_t i = 0; i < prefix; ++i) out /= components.front()[i];
  return out;
}

bool dir_exists(const Filepath& path) {
  boost::system::error_code ec;
  return boost::filesystem::is_directory(path, ec) && !ec.failed();
}

int64_t ns_of(const struct timespec& t) { return int64_t(t.tv_sec) * 1000000000 + t.tv_nsec; }

// What identifies a version of an archive file: a replaced or rewritten file is opened again.
struct SourceIdentity {
  uintmax_t device = 0, inode = 0, size = 0;
  int64_t modified_ns = 0, changed_ns = 0;
  bool operator==(const SourceIdentity&) const = default;
};

SourceIdentity identity_of(const Filepath& path) {
  struct stat info{};
  if (::stat(path.c_str(), &info) != 0)
    throw std::runtime_error("cannot inspect archive " + path.native() + ": " + std::strerror(errno));
  if (!S_ISREG(info.st_mode)) throw std::runtime_error("archive must be a file: " + path.native());
  SourceIdentity id;
  id.device = info.st_dev;
  id.inode = info.st_ino;
  id.size = uintmax_t(info.st_size);
#if defined(__APPLE__)
  id.modified_ns = ns_of(info.st_mtimespec);
  id.changed_ns = ns_of(info.st_ctimespec);
#else
  id.modified_ns = ns_of(info.st_mtim);
  id.changed_ns = ns_of(info.st_ctim);
#endif
  return id;
}

// Private files for nested archives, removed with the process's last use of them.
Filepath private_directory() {
  boost::system::error_code ec;
  Filepath base = boost::filesystem::temp_directory_path(ec);
  if (ec) base = "/tmp";
  base = boost::filesystem::weakly_canonical(base, ec) / "file_commander_archive_cache";
  boost::filesystem::create_directories(base, ec);
  if (ec) throw std::runtime_error("cannot create archive cache dir: " + base.native());
  const Filepath dir = base / boost::filesystem::unique_path("nested-%%%%-%%%%-%%%%-%%%%");
  // Exclusive creation: a collision is an error, never permission to reuse another instance's folder.
  if (!boost::filesystem::create_directory(dir, ec) || ec) throw std::runtime_error("cannot create private archive dir: " + dir.native());
  boost::filesystem::permissions(dir, boost::filesystem::owner_all, ec);
  return dir;
}

struct Folder {
  uint32_t entry = UINT32_MAX;  // Set when the archive lists the folder itself.
  std::vector<std::string> children;
  std::set<std::string> names;
};

struct Opened {
  std::unique_ptr<SevenZip::Archive> archive;
  Filepath owned;               // A nested archive's private folder, removed on close.
  SourceIdentity identity;      // Of the outermost archive file.
  ArchiveFS::Metadata root;     // The archive file's own metadata stands in for its root folder.
  std::unordered_map<std::string, uint32_t> files;
  std::unordered_map<std::string, Folder> folders;  // "" is the root.
  std::chrono::steady_clock::time_point used;
  ~Opened() {
    archive.reset();
    if (!owned.empty()) {
      boost::system::error_code ec;
      boost::filesystem::remove_all(owned, ec);
    }
  }
};

constexpr size_t kMaxOpen = 16;
std::mutex g_mutex;
std::map<std::string, std::shared_ptr<Opened>> g_open;  // By the archive root's path.

// An entry's path as FC addresses it: '/'-separated, without "." or empty elements; empty when the archive gives a path that leaves its root.
std::string normal_entry_path(const std::string& path) {
  std::string out;
  size_t start = 0;
  while (start <= path.size()) {
    auto end = path.find('/', start);
    if (end == std::string::npos) end = path.size();
    const auto part = path.substr(start, end - start);
    if (part == "..") return {};
    if (!part.empty() && part != ".") {
      if (!out.empty()) out += '/';
      out += part;
    }
    start = end + 1;
  }
  return out;
}

void index_entries(Opened& opened) {
  opened.folders[""];
  const auto& entries = opened.archive->entries();
  for (const auto& e : entries) {
    const auto path = normal_entry_path(e.path);
    if (path.empty()) continue;
    // Every folder on the way exists, whether or not the archive lists it.
    std::string parent;
    size_t at = 0;
    for (;;) {
      const auto slash = path.find('/', at);
      const auto name = path.substr(at, slash == std::string::npos ? std::string::npos : slash - at);
      auto& folder = opened.folders[parent];
      if (folder.names.insert(name).second) folder.children.push_back(name);
      if (slash == std::string::npos) break;
      parent = path.substr(0, slash);
      opened.folders[parent];
      at = slash + 1;
    }
    if (e.directory) opened.folders[path].entry = e.index;
    else opened.files[path] = e.index;  // A later entry of the same name wins, as when a tar is extracted.
  }
}

ArchiveFS::Metadata metadata_of(const Opened& opened, const SevenZip::Entry& e) {
  ArchiveFS::Metadata m;
  m.exists = true;
  m.directory = e.directory;
  m.size = e.size.value_or(0);
  m.mtime_ns = e.modified_ns.value_or(opened.root.mtime_ns);
  const uint32_t permissions = e.posix_mode ? (*e.posix_mode & 07777) : (e.directory ? 0755 : 0644);
  if (!e.symlink.empty()) {
    m.mode = S_IFLNK | 0777;
    m.link = e.symlink;
  } else
    m.mode = (e.directory ? S_IFDIR : S_IFREG) | permissions;
  return m;
}

ArchiveFS::Metadata folder_metadata(const Opened& opened, const Folder& folder) {
  if (folder.entry != UINT32_MAX) return metadata_of(opened, opened.archive->entries()[folder.entry]);
  ArchiveFS::Metadata m;
  m.exists = true;
  m.directory = true;
  m.mtime_ns = opened.root.mtime_ns;
  m.mode = S_IFDIR | 0755;
  return m;
}

std::shared_ptr<Opened> open_chain(const std::vector<Filepath>& chain);

std::shared_ptr<Opened> open_new(const std::vector<Filepath>& chain, const SourceIdentity& identity) {
  auto opened = std::make_shared<Opened>();
  opened->identity = identity;
  Filepath file = chain.front();
  struct stat info{};
  if (::stat(file.c_str(), &info) == 0) {
#if defined(__APPLE__)
    opened->root.mtime_ns = ns_of(info.st_mtimespec);
#else
    opened->root.mtime_ns = ns_of(info.st_mtim);
#endif
  }
  if (chain.size() > 1) {
    // A nested archive is read from a private copy of its entry in the archive around it.
    auto outer = open_chain({chain.begin(), chain.end() - 1});
    const auto inner = normal_entry_path(chain.back().generic_string());
    auto found = outer->files.find(inner);
    if (found == outer->files.end()) throw std::runtime_error("Nested archive is missing: " + chain.back().native());
    opened->owned = private_directory();
    file = opened->owned / Filepath(inner).filename();
    Err failure;
    auto error = outer->archive->extract({found->second}, [&](const SevenZip::Entry&) { return file; },
                                         [&](const SevenZip::Entry&, Err err) { if (!err.ok()) failure = err; });
    if (!error.ok()) throw std::runtime_error(error.steps.front());
    if (!failure.ok()) throw std::runtime_error(failure.steps.front());
    opened->root.mtime_ns = metadata_of(*outer, outer->archive->entries()[found->second]).mtime_ns;
  }
  opened->root.exists = opened->root.directory = true;
  opened->root.mode = S_IFDIR | 0755;
  auto error = SevenZip::Archive::open(file, is_archive_file_path(file) ? "7z" : "", opened->archive);
  if (!error.ok()) throw std::runtime_error(error.steps.front());
  index_entries(*opened);
  return opened;
}

std::string key_of(const std::vector<Filepath>& chain) {
  Location root;
  root.archives = chain;
  return root.encode();
}

std::shared_ptr<Opened> open_chain(const std::vector<Filepath>& chain) {
  const auto identity = identity_of(chain.front());
  const auto key = key_of(chain);
  {
    std::lock_guard lock(g_mutex);
    auto found = g_open.find(key);
    if (found != g_open.end() && found->second->identity == identity) {
      found->second->used = std::chrono::steady_clock::now();
      return found->second;
    }
  }
  auto opened = open_new(chain, identity);
  std::lock_guard lock(g_mutex);
  opened->used = std::chrono::steady_clock::now();
  g_open[key] = opened;
  while (g_open.size() > kMaxOpen) {
    auto oldest = g_open.end();
    for (auto it = g_open.begin(); it != g_open.end(); ++it)
      if (it->second.use_count() == 1 && (oldest == g_open.end() || it->second->used < oldest->second->used)) oldest = it;
    if (oldest == g_open.end()) break;
    g_open.erase(oldest);
  }
  return opened;
}

std::pair<std::shared_ptr<Opened>, std::string> open_path(const Filepath& path) {
  const auto location = Location::decode(path.native());
  if (!location.read_only()) throw std::runtime_error("not an archive path: " + path.native());
  return {open_chain(location.archives), location.internal.generic_string()};
}

}  // namespace

bool is_archive_file_path(const Filepath& path) {
  const std::string ext = to_lower_ascii(path.extension().native());
  return ext == ".7z";
}

bool path_is_under(const Filepath& parent, const Filepath& child) {
  const Filepath parent_norm = parent.lexically_normal();
  const Filepath child_norm = child.lexically_normal();
  const std::string parent_text = parent_norm.native();
  const std::string child_text = child_norm.native();
  if (parent_text.empty()) return false;
  if (child_text == parent_text) return true;
  std::string prefix = parent_text;
  if (prefix.back() != boost::filesystem::path::preferred_separator) prefix.push_back(boost::filesystem::path::preferred_separator);
  return child_text.rfind(prefix, 0) == 0;
}

Filepath archive_root(const Filepath& archive) {
  Location root;
  if (is_archive_path(archive)) {
    root = Location::decode(archive.native());
    root.archives.push_back(root.internal);
    root.internal.clear();
  } else
    root.archives.push_back(absolute_path_safe(archive));
  return root.resource();
}

Filepath archive_file_of(const Filepath& path) {
  if (!is_archive_path(path)) return {};
  auto location = Location::decode(path.native());
  if (!location.internal.empty()) return {};
  auto file = location.archives.back();
  location.archives.pop_back();
  if (location.archives.empty()) return file;
  location.internal = file;
  return location.resource();
}

std::string archive_mutation_error(const Filepath& path) {
  if (is_archive_path(path)) return "Archive contents are read-only; copy files out before editing: " + Location::decode(path.native()).display();
  return {};
}

namespace ArchiveFS {

bool Metadata::symlink() const { return S_ISLNK(mode); }

boost::filesystem::file_status Metadata::status() const {
  using namespace boost::filesystem;
  if (!exists) return file_status(file_not_found);
  const auto permissions = perms(mode & 07777);
  if (directory) return file_status(directory_file, permissions);
  if (symlink()) return file_status(symlink_file, permissions);
  return file_status(regular_file, permissions);
}

Metadata inspect(const Filepath& path) {
  auto [opened, inside] = open_path(path);
  if (inside.empty()) return opened->root;
  if (auto folder = opened->folders.find(inside); folder != opened->folders.end()) return folder_metadata(*opened, folder->second);
  if (auto file = opened->files.find(inside); file != opened->files.end()) return metadata_of(*opened, opened->archive->entries()[file->second]);
  return {};
}

std::vector<Entry> list(const Filepath& folder_path, const std::atomic<bool>* cancelled) {
  auto [opened, inside] = open_path(folder_path);
  auto folder = opened->folders.find(inside);
  if (folder == opened->folders.end()) throw std::runtime_error("No such folder in the archive: " + Location::decode(folder_path.native()).display());
  const auto base = Filepath(Location::decode(folder_path.native()).encode());
  std::vector<Entry> out;
  out.reserve(folder->second.children.size());
  for (const auto& name : folder->second.children) {
    if (cancelled && cancelled->load()) break;
    const auto child = inside.empty() ? name : inside + "/" + name;
    Entry e{base / name, {}};
    if (auto sub = opened->folders.find(child); sub != opened->folders.end()) e.metadata = folder_metadata(*opened, sub->second);
    else e.metadata = metadata_of(*opened, opened->archive->entries()[opened->files.at(child)]);
    out.push_back(std::move(e));
  }
  return out;
}

Err extract(const std::vector<Item>& items, const std::function<void(const Item&, Err)>& finished, const std::atomic<bool>* cancelled,
            const std::function<void(uint64_t)>& progress) {
  // One pass per archive, in the order the items first name them.
  std::vector<std::string> order;
  std::map<std::string, std::vector<const Item*>> groups;
  for (const auto& item : items) {
    const auto location = Location::decode(item.source.native());
    const auto key = key_of(location.archives);
    if (!groups.count(key)) order.push_back(key);
    groups[key].push_back(&item);
  }
  uint64_t written_before = 0;
  for (const auto& key : order) {
    if (cancelled && cancelled->load()) return Err("cancelled");
    const auto& group = groups[key];
    std::shared_ptr<Opened> opened;
    try {
      opened = open_chain(Location::decode(group.front()->source.native()).archives);
    } catch (const std::exception& e) {
      return Err(e.what());
    }
    std::vector<uint32_t> indices;
    std::unordered_map<uint32_t, const Item*> by_index;
    for (const auto* item : group) {
      const auto inside = Location::decode(item->source.native()).internal.generic_string();
      auto file = opened->files.find(inside);
      if (file == opened->files.end()) {
        finished(*item, Err("No such file in the archive: " + Location::decode(item->source.native()).display()));
        continue;
      }
      if (by_index.emplace(file->second, item).second) indices.push_back(file->second);
      else finished(*item, Err("The same archive entry is copied twice: " + item->source.native()));
    }
    SevenZip::Progress report;
    report.cancelled = cancelled;
    uint64_t group_bytes = 0;
    if (progress)
      report.report = [&](uint64_t done, uint64_t) {
        group_bytes = done;
        progress(written_before + done);
      };
    auto error = opened->archive->extract(
        indices, [&](const SevenZip::Entry& e) { return by_index.at(e.index)->output; },
        [&](const SevenZip::Entry& e, Err err) { finished(*by_index.at(e.index), err); }, {}, report);
    written_before += group_bytes;
    if (!error.ok()) return error;
  }
  return Err();
}

void close_unused() {
  std::lock_guard lock(g_mutex);
  for (auto it = g_open.begin(); it != g_open.end();)
    if (it->second.use_count() == 1) it = g_open.erase(it);
    else ++it;
}

size_t open_count() {
  std::lock_guard lock(g_mutex);
  return g_open.size();
}

}  // namespace ArchiveFS

Err create_archive(const Filepath& archive_path, const std::vector<Filepath>& sources, const Filepath& preferred_cwd, ArchiveConflict conflict,
                   std::atomic<bool>* cancelled, bool* skipped) {
  if (skipped) *skipped = false;
  if (!is_archive_file_path(archive_path)) return Err("unsupported archive destination: " + archive_path.native());
  if (sources.empty()) return Err("no input files selected for archive creation");

  const Filepath archive_abs = absolute_path_safe(archive_path);
  const Filepath archive_parent = archive_abs.parent_path();

  boost::system::error_code ec;
  if (!archive_parent.empty()) {
    boost::filesystem::create_directories(archive_parent, ec);
    if (ec.failed()) return Err("cannot create destination dir: " + archive_parent.native());
  }

  std::vector<Filepath> source_abs;
  source_abs.reserve(sources.size());
  for (const auto& p : sources) {
    const auto input = absolute_path_safe(p);
    const auto canonical_input = boost::filesystem::canonical(input, ec);
    if (ec.failed()) return Err("cannot read archive input: " + input.native());
    const bool same = input == archive_abs || boost::filesystem::equivalent(input, archive_abs, ec);
    ec.clear();
    if (same || (dir_exists(input) && path_is_under(canonical_input, archive_abs))) return Err("archive output must be outside its selected inputs");
    source_abs.push_back(input);
  }
  const auto destination_status = boost::filesystem::symlink_status(archive_abs, ec);
  if (ec.failed() && ec != boost::system::errc::no_such_file_or_directory) return Err("cannot inspect archive destination: " + ec.message());
  ec.clear();
  if (boost::filesystem::exists(destination_status)) {
    if (conflict == ArchiveConflict::Skip) {
      if (skipped) *skipped = true;
      return Err();
    }
    if (conflict == ArchiveConflict::Update) return Err("Update if newer is unavailable for archives; choose Replace or Skip");
  }
  const Filepath staging_dir = archive_parent / boost::filesystem::unique_path(".fc-archive-%%%%-%%%%-%%%%");
  if (!boost::filesystem::create_directory(staging_dir, ec) || ec.failed())
    return Err("cannot create private archive staging directory: " + ec.message());
  struct Cleanup {
    Filepath root;
    ~Cleanup() {
      boost::system::error_code ignored;
      boost::filesystem::remove_all(root, ignored);
    }
  } cleanup{staging_dir};
  const Filepath staged_archive = staging_dir / "output.7z";

  // Names inside the archive start at `preferred_cwd` when it holds every source, otherwise at the sources' common folder.
  Filepath working_dir;
  if (!preferred_cwd.empty()) {
    const Filepath preferred_abs = absolute_path_safe(preferred_cwd);
    bool all_inside = true;
    for (const auto& src : source_abs)
      if (!path_is_under(preferred_abs, src)) {
        all_inside = false;
        break;
      }
    if (all_inside && dir_exists(preferred_abs)) working_dir = preferred_abs;
  }
  if (working_dir.empty()) {
    working_dir = common_prefix_path(source_abs);
    if (!dir_exists(working_dir)) working_dir = working_dir.parent_path();
  }
  std::vector<SevenZip::NewItem> items;
  for (const auto& src : source_abs) {
    boost::system::error_code rel_ec;
    Filepath rel = src.lexically_relative(working_dir);
    if (rel.empty() || rel == "." || *rel.begin() == "..") rel = src.filename();
    items.push_back({src, rel.generic_string()});
  }
  SevenZip::Progress progress;
  progress.cancelled = cancelled;
  auto created = SevenZip::create("7z", items, staged_archive, progress);
  if (cancelled && cancelled->load()) return Err("archive creation cancelled");
  if (!created.ok()) return Err("archive create failed: " + created.steps.front());

  if (!boost::filesystem::is_regular_file(staged_archive, ec) || ec.failed())
    return Err("archive create reported success but output file is missing: " + archive_abs.native());
  if (conflict == ArchiveConflict::Replace) {
    boost::filesystem::rename(staged_archive, archive_abs, ec);
  } else {
    boost::filesystem::create_hard_link(staged_archive, archive_abs, ec);
    if (conflict == ArchiveConflict::Skip && ec == boost::system::errc::file_exists) {
      if (skipped) *skipped = true;
      return Err();
    }
  }
  if (ec.failed()) return Err("cannot commit archive: " + ec.message());
  return Err();
}
