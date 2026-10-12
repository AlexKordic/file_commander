#include "archive_formats.hpp"

#include <algorithm>
#include <cstring>

namespace {

constexpr ArchiveKind A = ArchiveKind::Archive, T = ArchiveKind::CompressedTar, C = ArchiveKind::Compressed, O = ArchiveKind::OpenOnly,
                      U = ArchiveKind::Unsupported;

// The suffixes Enter knows. A longer suffix wins, so ".tar.gz" beats ".gz".
constexpr ArchiveFormat kFormats[] = {
    {".7z", "7z", A, true, ""},
    {".zip", "zip", A, false, ""},
    {".zipx", "zip", A, false, ""},
    {".tar", "tar", A, false, ""},
    {".cpio", "Cpio", A, false, ""},
    {".cab", "Cab", A, false, ""},
    {".arj", "Arj", A, false, ""},
    {".lzh", "Lzh", A, false, ""},
    {".lha", "Lzh", A, false, ""},
    {".rpm", "Rpm", A, false, ""},
    {".deb", "Ar", A, false, ""},
    {".ar", "Ar", A, false, ""},
    {".iso", "Iso", A, false, ""},
    {".wim", "wim", A, false, ""},
    {".swm", "wim", A, false, ""},
    {".esd", "wim", A, false, ""},
    {".xar", "Xar", A, false, ""},
    {".tar.gz", "gzip", T, false, ""},
    {".tgz", "gzip", T, false, ""},
    {".tar.bz2", "bzip2", T, false, ""},
    {".tbz", "bzip2", T, false, ""},
    {".tbz2", "bzip2", T, false, ""},
    {".tar.xz", "xz", T, false, ""},
    {".txz", "xz", T, false, ""},
    {".tar.zst", "zstd", T, false, ""},
    {".tzst", "zstd", T, false, ""},
    {".tar.lzma", "lzma", T, false, ""},
    {".tlz", "lzma", T, false, ""},
    {".tar.z", "Z", T, false, ""},
    {".taz", "Z", T, false, ""},
    {".gz", "gzip", C, false, ""},
    {".bz2", "bzip2", C, false, ""},
    {".xz", "xz", C, false, ""},
    {".zst", "zstd", C, false, ""},
    {".lzma", "lzma", C, false, ""},
    {".z", "Z", C, false, ""},
    {".dmg", "Dmg", O, false, ""},
    {".img", "", O, false, ""},
    {".vhd", "VHD", O, false, ""},
    {".vhdx", "VHDX", O, false, ""},
    {".vmdk", "VMDK", O, false, ""},
    {".vdi", "VDI", O, false, ""},
    {".qcow2", "QCOW", O, false, ""},
    {".squashfs", "SquashFS", O, false, ""},
    {".pkg", "Xar", O, false, ""},
    {".msi", "Compound", O, false, ""},
    {".chm", "Chm", O, false, ""},
    {".jar", "zip", O, false, ""},
    {".war", "zip", O, false, ""},
    {".ear", "zip", O, false, ""},
    {".apk", "zip", O, false, ""},
    {".aab", "zip", O, false, ""},
    {".ipa", "zip", O, false, ""},
    {".xpi", "zip", O, false, ""},
    {".epub", "zip", O, false, ""},
    {".docx", "zip", O, false, ""},
    {".xlsx", "zip", O, false, ""},
    {".pptx", "zip", O, false, ""},
    {".odt", "zip", O, false, ""},
    {".ods", "zip", O, false, ""},
    {".odp", "zip", O, false, ""},
    {".whl", "zip", O, false, ""},
    {".nupkg", "zip", O, false, ""},
    {".vsix", "zip", O, false, ""},
    {".appx", "zip", O, false, ""},
    {".msix", "zip", O, false, ""},
    {".rar", "", U, false, "FC doesn't open RAR archives"},
};

std::string lower(std::string text) {
  std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return char(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c); });
  return text;
}

}  // namespace

const ArchiveFormat* archive_format_of(const Filepath& name) {
  const auto file = lower(name.filename().native());
  const ArchiveFormat* best = nullptr;
  for (const auto& row : kFormats) {
    const size_t n = std::strlen(row.suffix);
    if (file.size() > n && file.compare(file.size() - n, n, row.suffix) == 0 && (!best || n > std::strlen(best->suffix))) best = &row;
  }
  return best;
}

EnterAction enter_action(const Filepath& name) {
  const auto* row = archive_format_of(name);
  if (!row) return EnterAction::None;
  switch (row->kind) {
    case ArchiveKind::Archive: return EnterAction::Browse;
    case ArchiveKind::CompressedTar:
    case ArchiveKind::Compressed: return EnterAction::OfferExtraction;
    case ArchiveKind::Unsupported: return EnterAction::Refuse;
    case ArchiveKind::OpenOnly: return EnterAction::None;
  }
  return EnterAction::None;
}

std::string archive_format_hint(const Filepath& name) {
  const auto* row = archive_format_of(name);
  return row ? row->format : "";
}

std::string archive_stem(const Filepath& name) {
  const auto file = name.filename().native();
  if (const auto* row = archive_format_of(name)) return file.substr(0, file.size() - std::strlen(row->suffix));
  return name.stem().native();
}

std::string archive_icon_kind(const std::string& name) {
  const auto* row = archive_format_of(Filepath(name));
  return row && row->kind != ArchiveKind::OpenOnly ? "archive" : "";
}
