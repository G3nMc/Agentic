# Agentic Project Explorer implementation

This patch is based on the supplied `lib/` directory and adds no third-party dependencies.

## Changed files

- `lib/ui/widgets/project_explorer.dart` (new): local filesystem explorer, lazy directory expansion, Dart/Python symbol listing, bounded project search, refresh and folder selection, internal drag payload.
- `lib/ui/widgets/sidebar.dart`: places Project Explorer above the Recent conversations list.
- `lib/ui/widgets/chat_input.dart`: accepts internal explorer drag-and-drop and inserts a compact reference at the current text selection.

## Usage

1. Open/select a project folder using the folder button in the explorer.
2. Expand directories. Expand `.dart` or `.py` files to list detected symbols.
3. Search by filename or symbol name (minimum two characters).
4. Drag a folder, file, class, function/method, or variable onto the chat input.
5. Add instructions and send as usual.

The inserted references are intentionally compact, e.g. `@symbol lib/services/project_service.dart:42 — Future<void> init() async`. They identify context but do not automatically attach file contents; this avoids adding large content to every prompt. The existing agent/tool workflow can use these paths to read the relevant source when needed.

## Scope and limitations

- Filesystem browsing, scanning, and parsing run in Flutter; Python is not invoked by the explorer.
- Supported source extensions are `.dart` and `.py`.
- Symbol detection is a lightweight line-based parser, not a full language server/compiler parser. It recognizes common class/function/method/variable declarations, but may miss complex syntax, getters, multiline signatures, and instance attributes such as `self.field`.
- Search is bounded to 12,000 filesystem entries and 100 results. Common generated/vendor directories are skipped.
- The supplied archive contains only `lib/`, not `pubspec.yaml` or tests. The container has no Flutter/Dart SDK available, so `flutter analyze` and runtime tests could not be run here. No new packages were added.
