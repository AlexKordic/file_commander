#pragma once
#include "commander.hpp"

namespace Perun {
enum class CopyConflictMode { Replace, Update, Skip };
enum class OperationType { COPY, MOVE, DELETE, ARCHIVE_CREATE, MKDIR, RENAME, CLIPBOARD };
struct Operation {
  enum class Kind { CopyFile, CreateDirectory, CreateSymlink, DiscoveryFailure, MoveEntry, DeleteEntry, ArchiveInput, RenameEntry, ClipboardText };
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
// Compatibility adapter for older callers. Executors only interpret typed steps.
OperationPlan        legacy_plan(OperationType, const std::vector<DirItem>&, CopyConflictMode);
std::vector<DirItem> legacy_plan_items(const OperationPlan&);
}  // namespace Perun
