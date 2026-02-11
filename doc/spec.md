
# What

An orthodox file manager. Exploring directories to run commands on selected files.

Bugs:
+ DataSource concept for vertical menu
+ instead of redraw() I could use active interactive screen
- Copy dir into itself !!
- MacOS mounted flash disk does not trigger inotify events.
  - external mkdir does not trigger inotify events.
+ Test move across disks
+ Performance fix for large number of displayed errors

Design goals:
- UI is always responsive, displaying what job machinery is doing.
  - Separate Discovery and Execution threads. 
    - JobSpec to become job when posted to file_operations
    - discovery thread to start when spec parameters are set
    - discovery stops when JobSpec is canceled
    - execution stops when JobSpec is canceled
    - execution to start when posted to file_operations and discovery thread is attached to JobSpec
    - JobSpec can be posted by UI ok button even before discovery is completed
    - UI displays discovery progress while dialog is open
    - task UI displays execution progress
    - UI can pause/resume execution
    - UI can cancel execution
    - UI cancels discovery by creating new JobSpec without posting old one to file_operations
- Design machinery first, then place UI as observer, issuing commands to machinery.

Initial Features:
- keep focused item according to path. `selected` as index will *move* when `FileChangeFunnel` adds/removes item from `Dir`.
- glob select & deselect - popup
+ try ResizableSplitRight between panels
+ prepend char to item render
  + dir marked with `/`
  + symlink takes 2 rows `-> real path` 
  + executable file colored green
+ monitor dir changes and real-time updates
  + Macos
  - Linux inotify
  - Windows ??
+ Left and Right panel
- Panel having multiple tabs
  - new tab to inherit configuration from focused tab: (dir, columns, sort, filter, selection)
  - Do not refresh UI if changes are inside not-shown tab
+ tab contains file list allowing selection ?with undo-selection-action?
+ esc clears selection
+ If no item selected then item under the cursor is considered selected
+ List can be sorted on any column ASC/DESC
+ Target for the command is always other-panel-selected-tab. Some commands ignore target dir and files.
- Command search like vscode-F1 with option to update key-shorcut on the spot
- Easily add new commands 
- Show single panel full-width, with visible other panel path, toggle on key-event
+ All commands happen in separate thread, like TC copy in background.
+ Command progress panel TBD
+ FileList implement vscroll_indicator & yframe and create Element's for only visible items.
- Dir Bookmarks
- Inc/Dec columns in tab 
- Keep state across runs
- mouse/trackpad only usage

Initial commands:
+ mkdir
+ copy & confirm popup
  - replace/update/skip checkboxes as overrite option
+ move & confirm popup
+ delete & confirm popup
+ rename
+ multi-rename
+ names to clipboard
+ paths to clipboard
- Find files, breadth-first-search, creates new tab for results
  - `Result-TABS`: Allow Dir to contain empty-path(no parent dir) but contain file list to work on
  - store ignore list for each dir in settings
- allow defining custom command
  - 7z compress & extract
  - tar/gz extract
  - open in installed editor app
- new tab from selected items
+ enter focused dir in target tab
- Back <> Forward navigation tree
  - remembering `Result-TABS` state
  - Display navigation tree - new dialog
  - move through navigation tree nodes - new dialog
  - Delete navigation and associated `Dir`s on key-event

## Extra

Drag and drop to other apps:
- https://github.com/rkevin-arch/CLIdrag
  Would be good as external `action`. Call it action because it should be triggered by mouse drag.
  Make it as command and allow command key to be `mouse-drag`.
  Implement as shared-library? Allowing to be used by all instances of the app and shut-down when last instance is closed. 
  ? Also consider usage over ssh. Is this just a desktop environment thing ?

- Allow multiple commands to have same shortcut. In this case a latest-recently-used list is maintained. When command is invoked from command menu, it is moved to the top of the list.

- Extract mouse click to be command key.
  Focus is now internal command that can be mapped to mouse click ?
  Select is now internal command that can be mapped to mouse click ?
  ? Or is this different mechanic requiring settings dialog ?

Clipboard support
+ text paste works good
- text copy is not possible when mouse is captured
- https://stackoverflow.com/questions/65840288/monitor-clipboard-changes-c-for-all-applications-windows

Usability:
  https://www.redhat.com/en/blog/midnight-commander-file-manager#:~:text=To%20copy%20or%20move%20a,in%20the%20non%2Dactive%20panel.

Performance:
  https://unix.stackexchange.com/questions/771238/linux-syscalls-advantage-of-copy-file-range-over-sendfile  


Extended key events allowing shift+left, alt+enter, etc.

Builtin editor: https://github.com/howl-editor/howl https://howl.io/

# History

## Reasons for creating this tool

Ortodox file manager such as norton commander is just a cool software to start with. What would be possible to create in 2025?

vscode-like command pallete (https://code.visualstudio.com/docs/getstarted/userinterface#_command-palette) is awesome:
- Single key to remember for accessing all commands and shortcuts, noone used f1 key to read help pages of an app!
- fuzzy search to find command is very helpfull
- latest used commands are moved to the top of the list
- key shortcuts is immediately visible and can be updated on the spot
- key shortcuts have specified condition when they apply, for example only when specified dialog is focused.

Terminal UI is awesome:
- FTXUI is great library
- Accesible over ssh
- Can look awesome in colored terminal

Multithreading for file operations. This alone is huge move toward modern app look and feel.
Usual workflow looks like this:
- Use UI to navigate and issue commands. This part is slow mainly waiting for key strokes.
- When command is issued, selection is now promoted to file job input list.
- Additional dialog is displayed to confirm action and tune available parameters.
- Based on initial parameters an recursive discovery process runs in background to compile list of required commands to complete the job.
- Any change in action parameters by UI causes new discovery process to be started in place of current one.
- UI can confirm action, promoting it to a job. Even when discovery is not completed.
- Execution process starts in background.
- Execution progress can be monitored by UI.
- UI can choose to pause, resume or cancel execution of any running job.

Loading settings from HTTP url is quick way to continue working on any machine.

File list filter by typing.

No integrated terminal.

Custom commands are easily implemented using luajit.

Multi rename dialog. Where find next command is easily implemented using luajit. Also add lua implementation of totalcmd multirename.

Easily adding new commands.
- TBD...
Easy integration with other apps, like text editors, image viewers, etc.
- TBD...


## What are baseline requirements for ortodox file manager

basic commands: copy, move, delete, rename, mkdir

Twin panel layout.

colums for: name, size, date, permissions, owner, group

## TODO:

Some platform differences.

Dir change notifications.

boost::filesystem limitations.

immediate gui limitations when creating file list.

Spacing 
