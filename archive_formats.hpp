#ifndef FC_ARCHIVE_FORMATS_HPP_
#define FC_ARCHIVE_FORMATS_HPP_

// Which files FC treats as archives, decided from the name alone so it is safe on the UI thread. 7-Zip's library reads many more formats; "Open as archive" reaches those by their contents.

#include "bfs.hpp"

#include <string>
#include <vector>

enum class ArchiveKind {
  Archive,        // An index FC browses on Enter: 7z, zip, tar, iso, ...
  CompressedTar,  // A tar inside a compressed stream: listing it means decompressing all of it.
  Compressed,     // One compressed file: .gz, .xz, ...
  OpenOnly,       // Usually opened some other way (documents, installers, disk images); browsed with Open as archive.
  Unsupported,    // Refused, with `ArchiveFormat::refusal`.
};

struct ArchiveFormat {
  const char* suffix;   // lower case, with its dot: ".tar.gz"
  const char* format;   // 7-Zip's name for the outer format; empty lets 7-Zip decide from the contents
  ArchiveKind kind;
  bool writable;        // FC can create it
  const char* refusal;  // for Unsupported
};

// The row for `name`'s longest matching suffix, or null.
const ArchiveFormat* archive_format_of(const Filepath& name);

enum class EnterAction { None, Browse, OfferExtraction, Refuse };
// What Enter does on a file with this name.
EnterAction enter_action(const Filepath& name);

// The format's name for 7-Zip when opening `name`, or empty to detect it.
std::string archive_format_hint(const Filepath& name);

// The name without its archive suffix ("release-1.2.tar.gz" gives "release-1.2"), for the folder an archive is extracted into.
std::string archive_stem(const Filepath& name);

// "archive" for names of any archive kind, for icons; empty otherwise.
std::string archive_icon_kind(const std::string& name);

// What copying `sources` to `destination` does, decided from the destination's name: a plain copy, a new archive (`text` says which, for the copy dialogs), or a refusal (`text` says why).
struct ArchiveDestination {
  enum Kind { Copy, Create, Refuse } kind = Copy;
  std::string text;
  const ArchiveFormat* format = nullptr;
};
ArchiveDestination archive_destination(const Filepath& destination, const std::vector<Filepath>& sources);

#endif  // FC_ARCHIVE_FORMATS_HPP_
