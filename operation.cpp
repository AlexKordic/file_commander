#include "operation.hpp"
namespace Perun {
DirItem operation_display(const Operation& op) {
  auto    path = op.source.empty() ? op.destination : op.source;
  auto    type = op.kind == Operation::Kind::CreateDirectory ? boost::filesystem::directory_file : op.kind == Operation::Kind::CreateSymlink ? boost::filesystem::symlink_file : op.kind == Operation::Kind::DiscoveryFailure ? boost::filesystem::status_error : boost::filesystem::regular_file;
  DirItem item(path, path.filename().native(), type, op.permissions, op.modified, op.bytes);
  if (op.kind == Operation::Kind::CreateSymlink) item._set_symlink_target(op.link_text);
  if (op.kind == Operation::Kind::DiscoveryFailure) item._set_warning(op.message);
  return item;
}
OperationPlan selection_plan(OperationType type, const std::vector<Filepath>& paths, const Filepath& destination) {
  OperationPlan plan;
  plan.type = type;
  for (const auto& path : paths) {
    Operation op;
    op.source      = path;
    op.kind        = type == OperationType::DELETE ? Operation::Kind::DeleteEntry : type == OperationType::ARCHIVE_CREATE ? Operation::Kind::ArchiveInput : Operation::Kind::MoveEntry;
    op.destination = type == OperationType::DELETE ? Filepath() : type == OperationType::ARCHIVE_CREATE ? destination : destination / path.filename();
    plan.steps.push_back(std::move(op));
  }
  return plan;
}
OperationPlan legacy_plan(OperationType type, const std::vector<DirItem>& items, CopyConflictMode conflict) {
  OperationPlan plan;
  plan.type     = type;
  plan.conflict = conflict;
  for (const auto& item : items) {
    Operation op;
    op.source      = item.path_ref();
    op.destination = item.symlink_ref().value_or(Filepath());
    op.bytes       = item.size();
    op.modified    = item.write_time();
    op.permissions = item.perms();
    op.kind        = type == OperationType::DELETE ? Operation::Kind::DeleteEntry : type == OperationType::MOVE ? Operation::Kind::MoveEntry : type == OperationType::ARCHIVE_CREATE ? Operation::Kind::ArchiveInput : Operation::Kind::CopyFile;
    if (type == OperationType::DELETE) op.destination.clear();
    if (type == OperationType::COPY) {
      if (item.type() == boost::filesystem::directory_file) {
        op.kind        = Operation::Kind::CreateDirectory;
        op.destination = op.source;
        op.source.clear();
      }
      if (item.type() == boost::filesystem::symlink_file) {
        op.kind        = Operation::Kind::CreateSymlink;
        op.link_text   = op.destination;
        op.destination = op.source;
        op.source.clear();
      }
      if (item.type() == boost::filesystem::status_error) {
        op.kind    = Operation::Kind::DiscoveryFailure;
        op.message = item.warning_ref().value_or("Discovery failed");
      }
    }
    plan.steps.push_back(std::move(op));
  }
  return plan;
}
std::vector<DirItem> legacy_plan_items(const OperationPlan& plan) {
  std::vector<DirItem> items;
  for (const auto& op : plan.steps) {
    auto item = operation_display(op);
    if (op.kind != Operation::Kind::CreateSymlink) item._set_symlink_target(op.destination);
    items.push_back(std::move(item));
  }
  return items;
}
}  // namespace Perun
