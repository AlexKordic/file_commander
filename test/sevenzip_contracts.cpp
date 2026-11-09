// 7-Zip's archive library through FC's wrapper: loading it, listing archives without extracting them, extracting only the entries asked for, and writing 7z archives.
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <map>
#include <set>
#include <sys/stat.h>
#include "sevenzip.hpp"
#include "support/contracts.hpp"
using namespace test;

namespace {

// A small tree with nesting, an empty file, an empty folder and a non-ASCII name.
void make_tree(const Filepath& root) {
  fs::create_directories(root / "docs" / "deep");
  fs::create_directories(root / "empty");
  write(root / "a.txt", "alpha\n");
  write(root / "docs" / "b.md", std::string(5000, 'b'));
  write(root / "docs" / "deep" / "c.bin", std::string("\0\1\2\xff", 4));
  write(root / "docs" / "zero", "");
  write(root / "Ω name.txt", "omega");
}

std::map<std::string, const SevenZip::Entry*> by_path(const SevenZip::Archive& archive) {
  std::map<std::string, const SevenZip::Entry*> out;
  for (const auto& e : archive.entries()) out[e.path] = &e;
  return out;
}

std::unique_ptr<SevenZip::Archive> open(const Filepath& file, const std::string& format = {}) {
  std::unique_ptr<SevenZip::Archive> archive;
  auto error = SevenZip::Archive::open(file, format, archive);
  require(error.ok() && archive, "cannot open " + file.string() + ": " + (error.steps.empty() ? "" : error.steps.front()));
  return archive;
}

// Extracts `paths` into `into`, flattening them to their file names, and returns how each went.
std::map<std::string, std::string> extract(SevenZip::Archive& archive, const std::vector<std::string>& paths, const Filepath& into) {
  auto entries = by_path(archive);
  std::vector<uint32_t> indices;
  for (const auto& p : paths) {
    require(entries.count(p) == 1, "no entry " + p);
    indices.push_back(entries[p]->index);
  }
  std::map<std::string, std::string> results;
  fs::create_directories(into);
  auto error = archive.extract(
      indices, [&](const SevenZip::Entry& e) { return into / Filepath(e.path).filename(); },
      [&](const SevenZip::Entry& e, Err err) { results[e.path] = err.ok() ? "" : err.steps.front(); });
  require(error.ok(), "extraction failed: " + (error.steps.empty() ? "" : error.steps.front()));
  return results;
}

void make_python_archives(const Filepath& source, const Filepath& output) {
  const std::string command = std::string(FC_TEST_PYTHON) + " '" + FC_TEST_SOURCE_DIR + "/test/fixtures/archives/make_archives.py' '" + source.string() +
                              "' '" + output.string() + "'";
  require(std::system(command.c_str()) == 0, "fixture archives could not be written");
}

void load() {
  require(SevenZip::available(), "library unavailable: " + SevenZip::error());
  std::set<std::string> names;
  for (const auto& f : SevenZip::formats()) names.insert(f.name);
  for (auto expected : {"7z", "zip", "tar", "gzip", "bzip2", "xz", "zstd", "Iso", "Cab", "Cpio", "Rpm", "Ar", "wim", "Dmg"})
    require(names.count(expected), std::string("format missing: ") + expected);
  for (const auto& name : names) require(name.find("Rar") == std::string::npos && name.find("rar") == std::string::npos, "RAR is built in: " + name);
  require(SevenZip::find_format("7z") && SevenZip::find_format("7z")->writable, "7z is not writable");
  require(SevenZip::find_format("zip") && SevenZip::find_format("zip")->writable, "zip is not writable");
  const auto* gz = SevenZip::find_format("gzip");
  require(gz && std::find(gz->extensions.begin(), gz->extensions.end(), "tgz") != gz->extensions.end(), "gzip extensions not read");
}

void seven() {
  Fixture f;
  make_tree(f / "tree");
  const auto archive_path = f / "tree.7z";
  auto error = SevenZip::create("7z", {{f / "tree" / "a.txt", "a.txt"}, {f / "tree" / "docs", "docs"}, {f / "tree" / "empty", "empty"},
                                       {f / "tree" / "Ω name.txt", "Ω name.txt"}},
                                archive_path);
  require(error.ok(), "7z creation failed");
  require(SevenZip::create("7z", {{f / "tree" / "a.txt", "a.txt"}}, archive_path).steps.size() > 0, "an existing destination was overwritten");
  auto archive = open(archive_path);
  require(archive->format() == "7z", "format: " + archive->format());
  auto entries = by_path(*archive);
  for (auto p : {"a.txt", "docs", "docs/b.md", "docs/deep", "docs/deep/c.bin", "docs/zero", "empty", "Ω name.txt"})
    require(entries.count(p), std::string("entry missing: ") + p);
  require(entries["docs"]->directory && entries["empty"]->directory && !entries["a.txt"]->directory, "folder flags");
  require(entries["docs/b.md"]->size == 5000u && entries["docs/zero"]->size == 0u, "sizes");
  require(entries["a.txt"]->modified_ns.has_value() && entries["a.txt"]->posix_mode && S_ISREG(*entries["a.txt"]->posix_mode), "times and modes");
  auto results = extract(*archive, {"docs/deep/c.bin", "Ω name.txt"}, f / "out");
  require(results.size() == 2 && results["docs/deep/c.bin"].empty() && results["Ω name.txt"].empty(), "entries not reported as written");
  require(read(f / "out" / "c.bin") == std::string("\0\1\2\xff", 4) && read(f / "out" / "Ω name.txt") == "omega", "extracted bytes");
  require(!fs::exists(f / "out" / "a.txt") && !fs::exists(f / "out" / "b.md"), "entries not asked for were written");
}

// A solid archive: extracting one entry in the middle writes that entry only.
void solid() {
  Fixture f;
  fs::create_directories(f / "many");
  for (int i = 0; i < 200; ++i) write(f / "many" / ("f" + std::to_string(1000 + i)), std::string(1000 + i, char('a' + i % 26)));
  require(SevenZip::create("7z", {{f / "many", "many"}}, f / "many.7z").ok(), "solid 7z creation failed");
  auto archive = open(f / "many.7z");
  int written = 0;
  auto entries = by_path(*archive);
  auto error = archive->extract({entries["many/f1100"]->index},
                                [&](const SevenZip::Entry& e) { ++written; return f.root / Filepath(e.path).filename(); },
                                [&](const SevenZip::Entry&, Err err) { require(err.ok(), "entry failed"); });
  require(error.ok() && written == 1, "solid extraction wrote " + std::to_string(written) + " files");
  require(read(f / "f1100") == std::string(1100, char('a' + 100 % 26)), "solid entry bytes");
}

void formats() {
  Fixture f;
  make_tree(f / "tree");
  make_python_archives(f / "tree", f / "made");
  for (auto name : {"tree.zip", "tree.tar", "tree.tar.gz", "tree.tar.bz2", "tree.tar.xz"}) {
    auto archive = open(f / "made" / name);
    if (std::string(name) == "tree.zip" || std::string(name) == "tree.tar") {
      auto entries = by_path(*archive);
      require(entries.count("docs/b.md") && entries.count("Ω name.txt") && entries["docs"]->directory, std::string("listing of ") + name);
      auto results = extract(*archive, {"docs/b.md"}, f / "out" / name);
      require(results["docs/b.md"].empty() && read(f / "out" / name / "b.md") == std::string(5000, 'b'), std::string("bytes from ") + name);
    } else {
      // A compressed tar is a stream holding one tar.
      require(archive->entries().size() == 1 && archive->entries()[0].path == "tree.tar", std::string("stream entry of ") + name);
    }
  }
  auto gz = open(f / "made" / "one.txt.gz");
  require(gz->format() == "gzip" && gz->entries().size() == 1 && gz->entries()[0].path == "a.txt", "gzip keeps the stored name");
  auto results = extract(*gz, {"a.txt"}, f / "gz");
  require(results["a.txt"].empty() && read(f / "gz" / "a.txt") == "alpha\n", "gzip bytes");
  // Formats are found from contents when the extension says nothing.
  fs::copy_file(f / "made" / "tree.zip", f / "disguised.bin");
  require(open(f / "disguised.bin")->format() == "zip", "zip not found by signature");
}

void failures() {
  Fixture f;
  write(f / "plain.txt", "not an archive at all");
  std::unique_ptr<SevenZip::Archive> archive;
  auto error = SevenZip::Archive::open(f / "plain.txt", "", archive);
  require(!error.ok() && !archive && error.steps.front().find("Not an archive") != std::string::npos, "a text file opened");
  error = SevenZip::Archive::open(f / "missing.7z", "", archive);
  require(!error.ok() && !archive, "a missing file opened");
  require(!SevenZip::create("gzip-nope", {}, f / "x").ok(), "unknown format accepted");
  require(!SevenZip::create("Iso", {{f / "plain.txt", "plain.txt"}}, f / "x.iso").ok(), "read-only format written");
  make_tree(f / "tree");
  require(SevenZip::create("7z", {{f / "tree", "tree"}}, f / "tree.7z").ok(), "7z creation failed");
  auto opened = open(f / "tree.7z");
  // An output that already exists fails that entry only.
  fs::create_directories(f / "out");
  write(f / "out" / "a.txt", "kept");
  auto results = extract(*opened, {"tree/a.txt", "tree/docs/b.md"}, f / "out");
  require(!results["tree/a.txt"].empty() && results["tree/docs/b.md"].empty(), "an existing output was not reported");
  require(read(f / "out" / "a.txt") == "kept" && read(f / "out" / "b.md") == std::string(5000, 'b'), "existing output overwritten");
  // Cancellation stops the extraction.
  std::atomic<bool> cancelled{true};
  SevenZip::Progress progress;
  progress.cancelled = &cancelled;
  auto entries = by_path(*opened);
  error = opened->extract({entries["tree/docs/zero"]->index}, [&](const SevenZip::Entry& e) { return f.root / "c" / e.path; },
                          [](const SevenZip::Entry&, Err) {}, {}, progress);
  require(!error.ok() && error.steps.front().find("cancelled") != std::string::npos, "cancelled extraction succeeded");
  // A damaged archive is refused, not crashed on.
  auto bytes = read(f / "tree.7z");
  bytes.resize(bytes.size() / 2);
  write(f / "torn.7z", bytes);
  error = SevenZip::Archive::open(f / "torn.7z", "7z", archive);
  require(!error.ok(), "a torn 7z opened");
}

}  // namespace

int main(int argc, char** argv) {
  try {
    require(argc == 2, "one 7-Zip contract ID required");
    std::string name = argv[1];
    bool found = false;
#define RUN(n)     \
  if (name == #n) { \
    n();           \
    found = true;  \
  }
    RUN(load) RUN(seven) RUN(solid) RUN(formats) RUN(failures) require(found, "unknown 7-Zip contract");
    std::cout << "PASS sevenzip " << name << "\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
