#pragma once
#include "commander.hpp"

namespace Perun {
enum class CopyConflictMode { Replace, Update, Skip };
enum class OperationType { COPY, MOVE, DELETE, ARCHIVE_CREATE, MKDIR, RENAME, CLIPBOARD, EXTRACT };
struct Operation {
  // ExtractArchive: source is an archive (local, or a file inside another archive), destination the folder its contents go to, in one pass.
  enum class Kind { CopyFile, CreateDirectory, CreateSymlink, DiscoveryFailure, MoveEntry, DeleteEntry, ArchiveInput, RenameEntry, ClipboardText, ExtractArchive };
  Kind           kind;
  Filepath       source, destination, link_text;
  std::string    message;
  int64_t        bytes       = 0;
  std::time_t    modified    = 0;
  DirItem::Perms permissions = boost::filesystem::no_perms;
};
struct OperationPlan {
  OperationType          type     = OperationType::COPY;
  CopyConflictMode       conflict = CopyConflictMode::Replace;
  std::vector<Operation> steps;
};
DirItem              operation_display(const Operation&);
OperationPlan        selection_plan(OperationType, const std::vector<Filepath>&, const Filepath& destination = {});
// The extraction popup's job: everything in `archive` into `folder`, in one pass.
OperationPlan        extraction_plan(const Filepath& archive, const Filepath& folder, CopyConflictMode, int64_t archive_bytes = 0);
// Compatibility adapter for older callers. Executors only interpret typed steps.
OperationPlan        legacy_plan(OperationType, const std::vector<DirItem>&, CopyConflictMode);
std::vector<DirItem> legacy_plan_items(const OperationPlan&);
}  // namespace Perun
