// Archives as a read-only filesystem (archive.hpp): browsing reads only the index, copying out extracts only what is copied, straight to its destination.
#include <fstream>
#include <iostream>
#include <set>
#include <map>
#include <random>
#include <sys/stat.h>
#include "archive.hpp"
#include "archive_formats.hpp"
#include "copy_planner.hpp"
#include "file_io_jobs.hpp"
#include "support/contracts.hpp"
using namespace test;
using namespace Perun;

namespace {

size_t count_in(const Filepath& dir) {
  boost::system::error_code ec;
  if (!fs::is_directory(dir, ec)) return 0;
  return size_t(std::distance(fs::directory_iterator(dir), fs::directory_iterator()));
}

Filepath nested_cache() { return fs::temp_directory_path() / "file_commander_archive_cache"; }

std::shared_ptr<JobSpec> copy_out(const std::vector<Filepath>& sources, const Filepath& destination, CopyConflictMode conflict = CopyConflictMode::Replace,
                                  const std::function<void(JobSpec&)>& started = {}) {
  CopyPlanner planner({sources, destination, false, true, conflict});
  until([&] { return !planner._running.load(); }, "copy discovery timeout");
  auto job = std::make_shared<JobSpec>(planner.take_plan());
  auto jobs = make_file_jobs();
  jobs->add_job(job);
  if (started) started(*job);
  until([&] { return jobs->idle(); }, "archive copy timeout");
  return job;
}

void staging_free(const Filepath& dir) {
  for (fs::recursive_directory_iterator it(dir), end; it != end; ++it)
    require(it->path().filename().native().rfind(".fc-", 0) != 0, "staging left behind: " + it->path().string());
}

void browse() {
  Fixture f;
  fs::create_directories(f / "tree/docs/deep");
  write(f / "tree/a.txt", "alpha");
  write(f / "tree/docs/deep/c.txt", "gamma");
  require(create_archive(f / "tree.7z", {f / "tree"}, f.root).ok(), "fixture archive failed");
  const auto before = count_in(nested_cache());
  const auto root = archive_root(f / "tree.7z");
  auto top = ArchiveFS::list(root);
  require(top.size() == 1 && top[0].path == root / "tree" && top[0].metadata.directory, "root listing");
  auto inner = ArchiveFS::list(root / "tree" / "docs" / "deep");
  require(inner.size() == 1 && inner[0].path.filename() == "c.txt" && inner[0].metadata.size == 5, "deep listing");
  require(ArchiveFS::inspect(root / "tree" / "a.txt").exists && !ArchiveFS::inspect(root / "tree" / "missing").exists, "inspect");
  require(count_in(nested_cache()) == before, "browsing an archive wrote files");
  // Paths behave like local ones inside the archive.
  require((root / "tree" / "docs").parent_path() == root / "tree" && location_parent(root / "tree") == root, "path arithmetic");
  require(location_parent(root) == f.root && archive_file_of(root) == f / "tree.7z", "leaving the root");
  require(Location::decode((root / "tree" / "a b!%.txt").native()).internal == Filepath("tree/a b!%.txt"), "names are kept as they are");
  require(!archive_mutation_error(root / "tree").empty() && archive_mutation_error(f / "tree").empty(), "read-only rule");
  bool missing = false;
  try { ArchiveFS::list(archive_root(f / "absent.7z")); } catch (const std::exception&) { missing = true; }
  require(missing, "a missing archive listed");
}

void copy() {
  Fixture f;
  fs::create_directories(f / "tree/docs");
  write(f / "tree/a.txt", "alpha");
  write(f / "tree/docs/b.txt", std::string(4000, 'b'));
  write(f / "tree/docs/c.txt", "gamma");
  fs::permissions(f / "tree/a.txt", fs::owner_read | fs::owner_write | fs::owner_exe);
  require(create_archive(f / "tree.7z", {f / "tree"}, f.root).ok(), "fixture archive failed");
  const auto root = archive_root(f / "tree.7z");
  fs::create_directories(f / "out");
  // A folder and a file, copied out: only they are written, with their archived modes.
  auto job = copy_out({root / "tree" / "docs", root / "tree" / "a.txt"}, f / "out");
  require(job->snapshot()->_state == JobState::COMPLETED, "copy out failed");
  require(read(f / "out/a.txt") == "alpha" && read(f / "out/docs/b.txt") == std::string(4000, 'b') && read(f / "out/docs/c.txt") == "gamma", "copied bytes");
  require((fs::status(f / "out/a.txt").permissions() & fs::owner_exe) != 0, "archived mode lost");
  staging_free(f / "out");
  // Skip keeps what is there; Update replaces only older files; Replace replaces.
  write(f / "out/a.txt", "kept");
  job = copy_out({root / "tree" / "a.txt"}, f / "out", CopyConflictMode::Skip);
  require(read(f / "out/a.txt") == "kept" && job->snapshot()->_items_skipped == 1, "Skip replaced");
  fs::last_write_time(f / "out/a.txt", std::time(nullptr) + 3600);
  job = copy_out({root / "tree" / "a.txt"}, f / "out", CopyConflictMode::Update);
  require(read(f / "out/a.txt") == "kept", "Update replaced a newer file");
  fs::last_write_time(f / "out/a.txt", 1000000000);
  job = copy_out({root / "tree" / "a.txt"}, f / "out", CopyConflictMode::Update);
  require(read(f / "out/a.txt") == "alpha", "Update kept an older file");
  write(f / "out/a.txt", "old");
  job = copy_out({root / "tree" / "a.txt"}, f / "out", CopyConflictMode::Replace);
  require(read(f / "out/a.txt") == "alpha", "Replace kept the old file");
  staging_free(f / "out");
  // Writing into an archive is refused.
  auto into = copy_out({f / "tree" / "a.txt"}, root / "tree");
  require(into->snapshot()->_state == JobState::COMPLETED_WITH_ERRORS, "a copy into an archive ran");
}

void cancel() {
  Fixture f;
  fs::create_directories(f / "big");
  std::mt19937 random(0xFC);
  for (int i = 0; i < 4; ++i) {
    std::string noise(16 * 1024 * 1024, '\0');
    for (auto& c : noise) c = char(random());
    write(f / "big" / ("part" + std::to_string(i)), noise);
  }
  require(create_archive(f / "big.7z", {f / "big"}, f.root).ok(), "fixture archive failed");
  fs::create_directories(f / "out");
  // Pausing once data is flowing parks the job inside the extraction; cancelling it there must publish nothing partial.
  auto job = copy_out({archive_root(f / "big.7z") / "big"}, f / "out", CopyConflictMode::Replace, [](JobSpec& job) {
    while (job._copy_bytes.load() == 0 && !job.is_stopped()) std::this_thread::yield();
    job._pause_requested = true;
    until([&] { return job._state.load() == JobState::PAUSED || job.is_stopped(); }, "copy did not pause");
    job._cancel_requested = true;
    job._pause_cv.notify_all();
  });
  require(job->snapshot()->_state == JobState::CANCELLED, "cancelled copy finished");
  staging_free(f / "out");
  for (fs::recursive_directory_iterator it(f / "out"), end; it != end; ++it)
    if (fs::is_regular_file(it->path())) require(fs::file_size(it->path()) == 16 * 1024 * 1024, "a partial file was published: " + it->path().string());
}

void nested() {
  Fixture f;
  fs::create_directories(f / "inputs/sub");
  write(f / "inputs/sub/file.txt", "original");
  require(create_archive(f / "inner.7z", {f / "inputs/sub"}, f / "inputs").ok(), "inner archive failed");
  require(create_archive(f / "outer.7z", {f / "inner.7z"}, f.root).ok(), "outer archive failed");
  const auto inner = archive_root(archive_root(f / "outer.7z") / "inner.7z");
  require(Location::decode(inner.native()).archives.size() == 2, "nested location");
  auto entries = ArchiveFS::list(inner / "sub");
  require(entries.size() == 1 && entries[0].path.filename() == "file.txt", "nested listing");
  fs::create_directories(f / "out");
  auto job = copy_out({inner / "sub" / "file.txt"}, f / "out");
  require(job->snapshot()->_state == JobState::COMPLETED && read(f / "out/file.txt") == "original", "nested copy out");
  require(archive_file_of(inner) == archive_root(f / "outer.7z") / "inner.7z" && location_parent(inner) == archive_root(f / "outer.7z"), "leaving a nested root");
  ArchiveFS::close_unused();
}

// Writes the fixture archives (test/fixtures/archives/make_archives.py) and returns the names it wrote beyond Python's own.
std::set<std::string> make_archives(const Filepath& source, const Filepath& output) {
  const auto listing = output.parent_path() / "made.txt";
  const std::string command = std::string(FC_TEST_PYTHON) + " '" + FC_TEST_SOURCE_DIR + "/test/fixtures/archives/make_archives.py' '" + source.string() + "' '" +
                              output.string() + "' > '" + listing.string() + "'";
  require(std::system(command.c_str()) == 0, "fixture archives could not be written");
  std::set<std::string> extra;
  std::ifstream in(listing.string());
  for (std::string line; std::getline(in, line);)
    if (!line.empty()) extra.insert(line);
  return extra;
}

void formats() {
  require(enter_action("a.TAR.GZ") == EnterAction::OfferExtraction && enter_action("x.tgz") == EnterAction::OfferExtraction, "compressed tar on Enter");
  require(enter_action("log.gz") == EnterAction::OfferExtraction && enter_action("x.7z") == EnterAction::Browse && enter_action("x.zip") == EnterAction::Browse,
          "Enter actions");
  require(enter_action("x.rar") == EnterAction::Refuse && enter_action("report.docx") == EnterAction::None && enter_action("notes.txt") == EnterAction::None,
          "refused and plain files");
  require(archive_format_of("x.tar.gz")->kind == ArchiveKind::CompressedTar && archive_format_of("x.gz")->kind == ArchiveKind::Compressed, "longest suffix");
  require(archive_format_hint("disk.vhdx") == "VHDX" && archive_format_hint("unknown.bin").empty(), "format hints");
  require(archive_icon_kind("a.tar.xz") == "archive" && archive_icon_kind("a.docx").empty(), "icons");

  Fixture f;
  fs::create_directories(f / "tree/docs");
  write(f / "tree/a.txt", "alpha\n");
  write(f / "tree/docs/b.md", std::string(5000, 'b'));
  auto extra = make_archives(f / "tree", f / "made");
  std::vector<std::string> names{"tree.zip", "tree.tar", "tree.tar.gz", "tree.tar.bz2", "tree.tar.xz"};
  names.insert(names.end(), extra.begin(), extra.end());
  for (const auto& name : names) {
    const auto root = archive_root(f / "made" / name);
    std::set<std::string> top;
    for (auto& e : ArchiveFS::list(root)) top.insert(e.path.filename().native());
    require(top.count("a.txt") && top.count("docs"), "listing of " + name);
    const auto out = f / "out" / name;
    fs::create_directories(out);
    auto job = copy_out({root / "docs" / "b.md"}, out);
    require(job->snapshot()->_state == JobState::COMPLETED && read(out / "b.md") == std::string(5000, 'b'), "copy out of " + name);
  }
  // A compressed tar inside another archive.
  require(create_archive(f / "outer.7z", {f / "made/tree.tar.gz"}, f / "made").ok(), "outer archive failed");
  auto nested = archive_root(archive_root(f / "outer.7z") / "tree.tar.gz");
  require(ArchiveFS::list(nested / "docs").size() == 1, "nested compressed tar listing");

  // One pass over a compressed tar writes every file it names.
  std::vector<std::string> written;
  fs::create_directories(f / "all");
  auto error = ArchiveFS::extract_all(f / "made/tree.tar.gz",
      [&](const SevenZip::Entry& e) {
        if (e.directory) return Filepath();
        written.push_back(e.path);
        return f / "all" / Filepath(e.path).filename();
      },
      [](const SevenZip::Entry& e, Err err) { require(err.ok(), "entry failed: " + e.path); });
  require(error.ok() && written.size() == 2 && read(f / "all/b.md") == std::string(5000, 'b'), "one-pass extraction");
  // A compressed file's one file, under the name its header keeps.
  fs::create_directories(f / "one");
  error = ArchiveFS::extract_all(f / "made/one.txt.gz", [&](const SevenZip::Entry& e) { return f / "one" / e.path; }, [](const SevenZip::Entry&, Err) {});
  require(error.ok() && read(f / "one/a.txt") == "alpha\n", "compressed file extraction");
  ArchiveFS::close_unused();
}

std::shared_ptr<JobSpec> run_plan(OperationPlan plan) {
  auto job = std::make_shared<JobSpec>(std::make_shared<const OperationPlan>(std::move(plan)));
  auto jobs = make_file_jobs();
  jobs->add_job(job);
  until([&] { return jobs->idle(); }, "extraction timeout");
  return job;
}

void extract() {
  Fixture f;
  fs::create_directories(f / "tree/docs");
  write(f / "tree/a.txt", "alpha\n");
  write(f / "tree/docs/b.md", std::string(5000, 'b'));
  make_archives(f / "tree", f / "made");
  require(archive_stem("release-1.2.tar.gz") == "release-1.2" && archive_stem("log.GZ") == "log" && archive_stem("x.bin") == "x", "folder names");
  // A compressed tar, into a folder named after it.
  auto job = run_plan(extraction_plan(f / "made/tree.tar.gz", f / "out" / archive_stem("tree.tar.gz"), CopyConflictMode::Replace));
  require(job->snapshot()->_state == JobState::COMPLETED, "extraction failed");
  require(read(f / "out/tree/a.txt") == "alpha\n" && read(f / "out/tree/docs/b.md") == std::string(5000, 'b'), "extracted bytes");
  staging_free(f / "out");
  // Skip keeps what is there; Replace replaces.
  write(f / "out/tree/a.txt", "kept");
  run_plan(extraction_plan(f / "made/tree.tar.gz", f / "out/tree", CopyConflictMode::Skip));
  require(read(f / "out/tree/a.txt") == "kept", "Skip replaced");
  run_plan(extraction_plan(f / "made/tree.tar.gz", f / "out/tree", CopyConflictMode::Replace));
  require(read(f / "out/tree/a.txt") == "alpha\n", "Replace kept the old file");
  // A compressed file's one file.
  job = run_plan(extraction_plan(f / "made/one.txt.gz", f / "out/one", CopyConflictMode::Replace));
  require(job->snapshot()->_state == JobState::COMPLETED && read(f / "out/one/a.txt") == "alpha\n", "compressed file extraction");
  // Nothing lands outside the destination; what can be kept is.
  job = run_plan(extraction_plan(f / "made/hostile.tar.gz", f / "out/h", CopyConflictMode::Replace));
  require(job->snapshot()->_state == JobState::COMPLETED_WITH_ERRORS, "hostile entries were not reported");
  require(read(f / "out/h/ok.txt") == "kept" && fs::is_symlink(f / "out/h/docs/inner"), "safe entries were dropped");
  require(!fs::exists(fs::symlink_status(f / "out/h/up")) && !fs::exists(f / "out/evil.txt") && !fs::exists(f / "evil.txt"), "an entry left the destination");
  require(fs::is_regular_file(f / "out/h/abs.txt") || !fs::exists(f / "out/h/abs.txt"), "absolute entry misplaced");
  staging_free(f / "out");
}

}  // namespace

int main(int argc, char** argv) {
  try {
    require(argc == 2, "one archive contract ID required");
    std::string name = argv[1];
    bool found = false;
#define RUN(n)     \
  if (name == #n) { \
    n();           \
    found = true;  \
  }
    RUN(browse) RUN(copy) RUN(cancel) RUN(nested) RUN(formats) RUN(extract) require(found, "unknown archive contract");
    std::cout << "PASS archive " << name << "\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
