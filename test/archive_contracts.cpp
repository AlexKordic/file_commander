// Archives as a read-only filesystem (archive.hpp): browsing reads only the index, copying out extracts only what is copied, straight to its destination.
#include <fstream>
#include <iostream>
#include <set>
#include <map>
#include <random>
#include <thread>
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
  for (const auto& name : extra)
    if (name != "aes.zip" && name != "zipcrypto.zip") names.push_back(name);  // Encrypted: the passwords contract opens them.
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
  fs::create_directories(f / "tree/empty");
  write(f / "tree/a.txt", "alpha\n");
  write(f / "tree/docs/b.md", std::string(5000, 'b'));
  fs::create_symlink("b.md", f / "tree/docs/link");
  auto extra = make_archives(f / "tree", f / "made");
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
  // Links that each stay inside but lead out together; a FIFO; a hard link to a file already written.
  require(!fs::exists(f / "out/chained.txt") && !fs::exists(f / "chained.txt"), "a link chain led an entry out of the destination");
  require(!fs::exists(fs::symlink_status(f / "out/h/pipe")), "a FIFO was extracted");
  require(read(f / "out/h/hard.txt") == "kept" && fs::equivalent(f / "out/h/hard.txt", f / "out/h/ok.txt"), "hard link");
  // Indexed archives' folders and links come out in the same pass as their files.
  require(fs::is_symlink(f / "out/tree/docs/link") && fs::is_directory(f / "out/tree/empty"), "a tar's link and empty folder");
  job = run_plan(extraction_plan(f / "made/tree.zip", f / "out/z", CopyConflictMode::Replace));
  require(job->snapshot()->_state == JobState::COMPLETED && fs::is_directory(f / "out/z/empty"), "a zip's empty folder");
  if (extra.count("tree.bsd.7z")) {
    job = run_plan(extraction_plan(f / "made/tree.bsd.7z", f / "out/s", CopyConflictMode::Replace));
    require(job->snapshot()->_state == JobState::COMPLETED && fs::is_directory(f / "out/s/empty") && fs::is_symlink(f / "out/s/docs/link"),
            "a 7z's link and empty folder");
  }
  staging_free(f / "out");
}

// Names that aren't UTF-8: a zip's legacy names are cp437, as the format says; a tar's bytes are kept as they are.
void names() {
  Fixture f;
  fs::create_directories(f / "tree");
  write(f / "tree/a.txt", "alpha\n");
  make_archives(f / "tree", f / "made");
  std::set<std::string> zip, tar;
  for (auto& e : ArchiveFS::list(archive_root(f / "made/legacy-names.zip"))) zip.insert(e.path.filename().native());
  require(zip == std::set<std::string>{"caf\xc3\xa9.txt", "na\xc3\xafve.txt"}, "zip names");
  for (auto& e : ArchiveFS::list(archive_root(f / "made/latin1.tar"))) tar.insert(e.path.filename().native());
  require(tar == std::set<std::string>{"caf\xe9.txt"}, "a tar name's bytes were changed");
  fs::create_directories(f / "out");
  auto job = copy_out({archive_root(f / "made/legacy-names.zip") / "caf\xc3\xa9.txt"}, f / "out");
  require(job->snapshot()->_state == JobState::COMPLETED && read(f / "out/caf\xc3\xa9.txt") == "cp437", "cp437 name copied out");
  ArchiveFS::close_unused();
}

// Answers the password questions from `answers`, in order, right away; `silent` leaves them unanswered.
struct Prompter {
  std::vector<std::optional<std::string>> answers;
  std::vector<std::pair<std::string, bool>> asked;
  std::vector<ArchiveFS::PasswordAnswer> unanswered;
  bool silent = false;
  std::mutex mutex;
  void install() {
    // Set from another thread: the thread that sets the prompt is never made to wait for it.
    std::thread([this] {
      ArchiveFS::set_password_prompt([this](const std::string& archive, bool wrong, ArchiveFS::PasswordAnswer answer) {
        std::optional<std::string> password;
        {
          std::lock_guard lock(mutex);
          asked.push_back({archive, wrong});
          if (silent) return unanswered.push_back(std::move(answer));
          if (!answers.empty()) {
            password = answers.front();
            answers.erase(answers.begin());
          }
        }
        answer(password);
      });
    }).join();
  }
  size_t count() {
    std::lock_guard lock(mutex);
    return asked.size();
  }
};

void passwords() {
  Fixture f;
  fs::create_directories(f / "tree/docs");
  write(f / "tree/a.txt", "alpha\n");
  write(f / "tree/docs/b.md", std::string(5000, 'b'));
  auto extra = make_archives(f / "tree", f / "made");
  SevenZip::Encryption names{"secret", true}, data{"secret", false};
  require(SevenZip::create("7z", {{f / "tree/a.txt", "a.txt"}, {f / "tree/docs", "docs"}}, f / "made/names.7z", {}, names).ok(), "names.7z");
  require(SevenZip::create("7z", {{f / "tree/a.txt", "a.txt"}, {f / "tree/docs", "docs"}}, f / "made/data.7z", {}, data).ok(), "data.7z");

  // The thread that set the prompt fails instead of waiting.
  ArchiveFS::set_password_prompt([](const std::string&, bool, ArchiveFS::PasswordAnswer) { throw std::runtime_error("asked on the prompt's thread"); });
  bool refused = false;
  try {
    ArchiveFS::list(archive_root(f / "made/names.7z"));
  } catch (const std::exception& e) { refused = std::string(e.what()).find("password") != std::string::npos; }
  require(refused, "a read on the prompt's thread must fail without asking");

  // Encrypted names: opening asks, again after a wrong answer, and remembers the one that worked.
  Prompter prompter;
  prompter.answers = {"wrong", "secret"};
  prompter.install();
  require(ArchiveFS::list(archive_root(f / "made/names.7z")).size() == 2, "listing with the password");
  require(prompter.asked.size() == 2 && !prompter.asked[0].second && prompter.asked[1].second, "asked again after a wrong password");
  require(prompter.asked[0].first.find("names.7z") != std::string::npos, "the question names the archive");
  ArchiveFS::close_unused();
  require(ArchiveFS::list(archive_root(f / "made/names.7z")).size() == 2 && prompter.asked.size() == 2, "the password is remembered");

  // Encrypted data: browsing doesn't ask; copying out checks the password before writing anything.
  prompter.asked.clear();
  prompter.answers = {"nope", "secret"};
  require(ArchiveFS::list(archive_root(f / "made/data.7z") / "docs").size() == 1 && prompter.asked.empty(), "listing data.7z asked");
  fs::create_directories(f / "out");
  auto job = copy_out({archive_root(f / "made/data.7z") / "docs/b.md", archive_root(f / "made/data.7z") / "a.txt"}, f / "out");
  require(job->snapshot()->_state == JobState::COMPLETED && read(f / "out/b.md") == std::string(5000, 'b') && read(f / "out/a.txt") == "alpha\n",
          "copy out of data.7z");
  require(prompter.asked.size() == 2 && prompter.asked[1].second, "data.7z asked again after a wrong password");
  staging_free(f / "out");

  // Cancel: the copy fails and writes nothing.
  ArchiveFS::forget_passwords();
  ArchiveFS::close_unused();
  prompter.answers = {std::nullopt};
  fs::create_directories(f / "none");
  job = copy_out({archive_root(f / "made/data.7z") / "a.txt"}, f / "none");
  require(job->snapshot()->_state == JobState::COMPLETED_WITH_ERRORS && count_in(f / "none") == 0, "a refused password must fail the copy cleanly");

  // Encrypted zips, AES and the old ZipCrypto, through the extraction popup's one pass.
  for (const char* name : {"aes.zip", "zipcrypto.zip"}) {
    if (!extra.count(name)) continue;
    prompter.answers = {"bad", "secret"};
    prompter.asked.clear();
    auto plan = run_plan(extraction_plan(f / "made" / name, f / "zips" / name, CopyConflictMode::Replace));
    require(plan->snapshot()->_state == JobState::COMPLETED && read(f / "zips" / name / "a.txt") == "alpha\n", std::string("extract ") + name);
    require(prompter.asked.size() == 2, std::string("asked twice for ") + name);
  }

  // A question nobody answers never holds up a cancel or a shutdown: the waiting read gives up.
  ArchiveFS::forget_passwords();
  ArchiveFS::close_unused();
  prompter.asked.clear();
  prompter.silent = true;
  fs::create_directories(f / "waiting");
  for (bool shut_down : {false, true}) {
    CopyPlanner planner({{archive_root(f / "made/data.7z") / "a.txt"}, f / "waiting", false, true, CopyConflictMode::Replace});
    until([&] { return !planner._running.load(); }, "copy discovery timeout");
    auto job = std::make_shared<JobSpec>(planner.take_plan());
    auto jobs = make_file_jobs();
    const auto asked_before = prompter.count();
    jobs->add_job(job);
    until([&] { return prompter.count() > asked_before; }, "the copy didn't ask for the password");
    if (shut_down) jobs->shutdown();
    else job->_cancel_requested = true;
    until([&] { return jobs->idle() || job->is_stopped(); }, "an unanswered password question held up the job");
    jobs->shutdown();
    require(count_in(f / "waiting") == 0, "a cancelled copy left files");
  }
  for (auto& answer : prompter.unanswered) answer(std::string("too late"));  // Answers after the reader gave up are ignored.
  ArchiveFS::set_password_prompt({});
  ArchiveFS::forget_passwords();
  ArchiveFS::close_unused();
}

// A damaged entry fails alone; the rest of the copy completes.
void damaged() {
  Fixture f;
  fs::create_directories(f / "tree");
  write(f / "tree/a.txt", "alpha\n");
  make_archives(f / "tree", f / "made");
  fs::create_directories(f / "out");
  const auto root = archive_root(f / "made/damaged.zip");
  auto job = copy_out({root / "bad.txt", root / "good.txt"}, f / "out");
  require(job->snapshot()->_state == JobState::COMPLETED_WITH_ERRORS, "the damaged entry wasn't reported");
  require(read(f / "out/good.txt") == "good data" && !fs::exists(f / "out/bad.txt"), "the intact entry must be copied, the damaged one not");
  staging_free(f / "out");
  ArchiveFS::close_unused();
}

// Too many entries are refused; long reads report progress.
void limits() {
  Fixture f;
  fs::create_directories(f / "tree/docs");
  write(f / "tree/a.txt", "alpha\n");
  write(f / "tree/docs/b.md", std::string(5000, 'b'));
  make_archives(f / "tree", f / "made");
  SevenZip::set_entry_limit(2);
  for (const char* name : {"tree.zip", "tree.tar.gz"}) {
    bool refused = false;
    try {
      ArchiveFS::list(archive_root(f / "made" / name));
    } catch (const std::exception& e) { refused = std::string(e.what()).find("entries") != std::string::npos; }
    require(refused, std::string("too many entries in ") + name);
  }
  SevenZip::set_entry_limit(1'000'000);
  std::vector<double> seen;
  {
    ArchiveFS::ReadProgress progress([&](double fraction) { seen.push_back(fraction); });
    require(ArchiveFS::list(archive_root(f / "made/tree.tar.gz")).size() == 2, "listing");
  }
  require(!seen.empty() && seen.back() > 0.99 && std::is_sorted(seen.begin(), seen.end()), "listing progress");
  ArchiveFS::close_unused();
}

// Every format FC writes: browse what was made and compare it with the tree it came from.
void create() {
  Fixture f;
  fs::create_directories(f / "tree/docs");
  fs::create_directories(f / "tree/empty");
  write(f / "tree/a.txt", "alpha\n");
  write(f / "tree/docs/b.md", std::string(5000, 'b'));
  write(f / "tree/caf\xc3\xa9.txt", "utf8");
  fs::create_symlink("b.md", f / "tree/docs/link");
  ::chmod((f / "tree/a.txt").c_str(), 0750);
  fs::last_write_time(f / "tree/a.txt", 1700000000);
  const std::vector<Filepath> sources{f / "tree/a.txt", f / "tree/docs", f / "tree/empty", f / "tree/caf\xc3\xa9.txt"};
  for (const char* name : {"t.7z", "t.zip", "t.tar", "t.tar.gz", "t.tgz", "t.tar.bz2", "t.tbz2", "t.tar.xz", "t.txz"}) {
    const auto archive = f / "made" / name;
    auto error = create_archive(archive, sources, f / "tree");
    require(error.ok(), std::string("create ") + name + ": " + (error.ok() ? "" : error.steps.front()));
    const auto root = archive_root(archive);
    std::set<std::string> top, docs;
    for (auto& e : ArchiveFS::list(root)) top.insert(e.path.filename().native());
    require(top == std::set<std::string>{"a.txt", "docs", "empty", "caf\xc3\xa9.txt"}, std::string("top level of ") + name);
    for (auto& e : ArchiveFS::list(root / "docs")) docs.insert(e.path.filename().native());
    require(docs == std::set<std::string>{"b.md", "link"}, std::string("docs in ") + name);
    const auto link = ArchiveFS::inspect(root / "docs/link");
    require(link.symlink() && link.link == "b.md", std::string("the link in ") + name);
    require(ArchiveFS::inspect(root / "empty").directory, std::string("the empty folder in ") + name);
    const auto a = ArchiveFS::inspect(root / "a.txt");
    require((a.mode & 0777) == 0750 && a.mtime_ns / 1000000000 == 1700000000, std::string("mode and time in ") + name);
    fs::create_directories(f / "out" / name);
    auto job = copy_out({root / "docs/b.md", root / "caf\xc3\xa9.txt"}, f / "out" / name);
    require(job->snapshot()->_state == JobState::COMPLETED && read(f / "out" / name / "b.md") == std::string(5000, 'b') &&
                read(f / "out" / name / "caf\xc3\xa9.txt") == "utf8",
            std::string("copy out of ") + name);
  }
  // One compressed file, under its own name.
  for (const char* name : {"a.txt.gz", "a.txt.bz2", "a.txt.xz"}) {
    require(create_archive(f / "made" / name, {f / "tree/a.txt"}, f / "tree").ok(), std::string("create ") + name);
    fs::create_directories(f / "one" / name);
    auto error = ArchiveFS::extract_all(f / "made" / name, [&](const SevenZip::Entry& e) { return f / "one" / name / e.path; }, [](const SevenZip::Entry&, Err) {});
    require(error.ok() && read(f / "one" / name / "a.txt") == "alpha\n", std::string("the file in ") + name);
  }
  // Through a job, as the copy dialogs make one.
  auto job = run_plan(selection_plan(OperationType::ARCHIVE_CREATE, {f / "tree/a.txt"}, f / "made/job.zip"));
  require(job->snapshot()->_state == JobState::COMPLETED && ArchiveFS::list(archive_root(f / "made/job.zip")).size() == 1, "archive job");
  // What the destination's name refuses, and what it leaves a plain copy.
  auto refused = [&](const char* name, const std::vector<Filepath>& from, const std::string& why) {
    auto error = create_archive(f / "made" / name, from, f / "tree");
    require(!error.ok() && error.steps.front().find(why) != std::string::npos && !fs::exists(f / "made" / name), std::string("refusal of ") + name);
  };
  refused("two.gz", {f / "tree/a.txt", f / "tree/docs/b.md"}, "holds one file");
  refused("folder.xz", {f / "tree/docs"}, "use .tar.xz");
  refused("t.tar.zst", sources, "can't create .tar.zst");
  refused("t.iso", sources, "can't create .iso");
  refused("t.rar", sources, "can't create .rar");
  require(archive_destination("report.docx", sources).kind == ArchiveDestination::Copy &&
              archive_destination("folder", sources).kind == ArchiveDestination::Copy,
          "plain copies");
  require(archive_destination("x.tar.gz", sources).text == "Creates a gzip-compressed tar archive" &&
              archive_destination("x.zip", sources).text == "Creates a ZIP archive",
          "what the dialogs say");
  // Cancelled while tar and the compressor are both running: nothing is left behind.
  fs::create_directories(f / "big");
  {
    std::ofstream big((f / "big/data.bin").native(), std::ios::binary);
    std::mt19937 random(7);
    std::string block(1 << 20, '\0');
    for (int i = 0; i < 64; ++i) {
      for (auto& c : block) c = char(random());
      big.write(block.data(), std::streamsize(block.size()));
    }
  }
  fs::create_directories(f / "cancel");
  std::atomic<bool> cancelled{false};
  Err result;
  std::thread worker([&] { result = create_archive(f / "cancel/big.tar.xz", {f / "big/data.bin"}, f / "big", ArchiveConflict::Replace, &cancelled); });
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  cancelled = true;
  worker.join();
  require(!result.ok() && count_in(f / "cancel") == 0, "a cancelled compressed tar left files behind");
  ArchiveFS::close_unused();
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
    RUN(browse) RUN(copy) RUN(cancel) RUN(nested) RUN(formats) RUN(extract) RUN(names) RUN(passwords) RUN(damaged) RUN(limits) RUN(create) require(found, "unknown archive contract");
    std::cout << "PASS archive " << name << "\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
