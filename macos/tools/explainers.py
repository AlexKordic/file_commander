#!/usr/bin/env python3
"""Writes the explainer scripts in Sources/FileCommander/Explainers/.

The scripts are data; this file is only a convenient way to author them with
less JSON noise. Run it after editing, then check them with check_explainers.py.
Keys written "@command" press whatever key the user's preset binds to it.
"""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / 'Sources/FileCommander/Explainers'


def cap(title, sub='', **kw):
    return {'caption': title, 'sub': sub, **kw}


def keys(*k, **kw):
    return {'keys': list(k), **kw}


def wait(cond, **kw):
    return {'wait': cond, **kw}


def hl(*anchors, hold=1800):
    return {'highlight': list(anchors) if len(anchors) > 1 else anchors[0], 'hold': hold}


def glob(pattern, select=True):
    return [keys('@glob_select' if select else '@glob_deselect'), wait({'glob': True}), wait({'text_focus': True}),
            {'type': pattern}, keys('Enter'), wait({'glob': False})]


def cursor(side, name):
    return {'cursor': {'side': side, 'name': name}}


def tabs(left, right, focus='left'):
    return {'open_tabs': {'left': left, 'right': right, 'focus': focus}}


def copy_sheet(job):
    return [wait({'sheet': 'copy'}), wait({'anchor': 'sheet.copy.start'}), {'click': 'sheet.copy.start', 'as_job': job},
            wait({'sheet': None}, timeout=30)]


E = {}

E['welcome'] = dict(
    title='The window', order=1, duration=45, chapter='basics',
    summary='Panes, tabs, the path bar, the filter, the status line, the toolbar and Help.',
    covers={'commands': ['switch_panel', 'help'], 'anchors': ['pane.left', 'pane.right', 'toolbar.help']},
    steps=[tabs('{home}', '{home}/camera'), {'chapter': 'Basics'},
           cap('Two panes', 'Each pane has its own tabs, folder, selection and sort order'), hl('pane.left', 'pane.right', hold=2000),
           cap('Tabs', "Every pane keeps its own tabs. The graduation cap marks the tutorial's tabs"),
           hl('pane.left.tabs', 'pane.right.tabs', hold=2000),
           cap('Path bar and filter', 'Click a folder in the path to go there; type to filter the list'),
           hl('pane.left.path', 'pane.left.filter', hold=2200),
           cap('Status line', 'What is selected, how many bytes, and how long the folder took to read'),
           hl('pane.left.status', hold=2000), {'unhighlight': True},
           cap('The focused pane', 'Keys go to the pane with the accent line. Switch Pane moves the focus'),
           keys('@switch_panel', hold=900), {'expect': {'focused': 'right'}}, keys('@switch_panel', hold=700),
           {'expect': {'focused': 'left'}},
           cap('Toolbar and menus', 'Every command is in the menu bar with its key, and in the command palette'),
           hl('toolbar.copy', 'toolbar.command_palette', hold=2200),
           cap('Help is always here', 'The graduation cap, or Help in the palette, explains any feature again'),
           hl('toolbar.help', hold=2400), {'unhighlight': True}, {'uncaption': True}])

E['navigate'] = dict(
    title='Move around', order=2, duration=50, chapter='basics',
    summary='Open folders and archives, go back up, use the path bar, and show a folder in the other pane.',
    covers={'commands': ['enter_dir', 'leave_dir', 'target_right', 'target_left', 'refresh_dir']},
    steps=[tabs('{home}', '{home}/projects'), {'chapter': 'Basics'},
           cap('Open a folder', 'Move the cursor with the arrow keys, then Open. Double-click works too'),
           cursor('left', 'photos'), {'pause': 600}, keys('@enter_dir'), wait({'path': {'side': 'left', 'ends_with': '/photos'}}),
           {'expect': {'rows': {'side': 'left', 'contains': '2026'}}},
           cap('Back up', 'Enclosing Folder goes to the parent and puts the cursor on the folder you came from'),
           keys('@leave_dir'), wait({'path': {'side': 'left', 'ends_with': '/home'}}), wait({'cursor': {'side': 'left', 'name': 'photos'}}),
           cap('The path bar', 'Click any folder in the path to jump straight there'), hl('pane.left.path', hold=1800),
           {'unhighlight': True},
           cap('Show it in the other pane', 'Show in Right Pane opens the folder under the cursor on the right'),
           cursor('left', 'music'), keys('@target_right'), wait({'path': {'side': 'right', 'ends_with': '/music'}}),
           {'focus': 'right'}, cursor('right', 'Field Notes'),
           cap('And the other way', 'Show in Left Pane does the same for the left pane'),
           keys('@target_left'), wait({'path': {'side': 'left', 'ends_with': '/Field Notes'}}), {'focus': 'left'},
           cap('Folders keep themselves up to date', 'FC watches the folder; Refresh reads it again on demand'),
           keys('@refresh_dir'), wait({'loaded': 'left'}),
           cap('Page by page', 'Page Up and Page Down (fn+↑ ↓ on a laptop) move the cursor a screenful; Home and End jump to the ends'),
           {'navigate': {'side': 'left', 'to': '{home}/projects/logs'}}, wait({'rows': {'side': 'left', 'count': 120}}),
           keys('PageDown', 'PageDown', gap=600), wait({'cursor_visible': {'side': 'left'}}),
           cap('Hold an arrow key', 'The list keeps the cursor in view; Settings › General › Cursor margin decides how far from the edge'),
           keys(*['Down'] * 40, gap=35), wait({'cursor_visible': {'side': 'left'}}), {'pause': 600},
           keys('End'), wait({'cursor': {'side': 'left', 'name': '2026-08-28.log'}}), wait({'cursor_visible': {'side': 'left'}}),
           keys('Home'), wait({'cursor': {'side': 'left', 'name': '2026-05-01.log'}}), wait({'cursor_visible': {'side': 'left'}}),
           keys(*['Down'] * 30, gap=35), keys(*['Up'] * 30, gap=35), wait({'cursor': {'side': 'left', 'name': '2026-05-01.log'}}),
           wait({'cursor_visible': {'side': 'left'}}),
           cap('Archives open like folders', 'Open on a .7z file browses it, read-only. The Archives explainer shows more'),
           {'navigate': {'side': 'left', 'to': '{home}', 'focus': '{home}/website-2025.7z'}}, cursor('left', 'website-2025.7z'),
           keys('@enter_dir'), wait({'rows': {'side': 'left', 'contains': 'app.js'}}, timeout=20), hl('pane.left.path', hold=1800),
           {'unhighlight': True}, keys('@leave_dir'), wait({'path': {'side': 'left', 'ends_with': '/home'}}), {'uncaption': True}])

E['filter'] = dict(
    title='Filter the list', order=3, duration=35, chapter='basics',
    summary='Type to show only matching names; Backspace edits; a new folder clears the filter.',
    covers={'anchors': ['pane.left.filter']},
    steps=[tabs('{home}/camera', '{home}/photos/2026'), {'chapter': 'Basics'},
           cap('Type to filter', 'Typing in a list shows only the names containing what you type. Case is ignored'),
           {'type': 'night'}, wait({'filter': {'side': 'left', 'is': 'night'}}), {'expect': {'rows': {'side': 'left', 'count': 1}}},
           hl('pane.left.filter', hold=1600), {'unhighlight': True},
           cap('Backspace edits it'), keys('Backspace', 'Backspace', 'Backspace', 'Backspace', 'Backspace', gap=160),
           wait({'filter': {'side': 'left', 'is': ''}}), {'type': 'jpg'}, wait({'rows': {'side': 'left', 'count': 8}}),
           hl('pane.left.status', hold=1800), {'unhighlight': True},
           cap('Some keys are commands', 'Keys bound to commands, such as Space, + and ?, run them instead. Rebind them to filter with them', hold=2600),
           cap('A new folder starts unfiltered'), keys('@leave_dir'), wait({'path': {'side': 'left', 'ends_with': '/home'}}),
           {'expect': {'filter': {'side': 'left', 'is': ''}}}, {'uncaption': True}])

E['select'] = dict(
    title='Select files', order=4, duration=55, chapter='basics',
    summary='Mark items with Space, by pattern, or all at once; commands act on the selection.',
    covers={'commands': ['select_toggle', 'clear_selection', 'glob_select', 'glob_deselect', 'select_all']},
    steps=[tabs('{home}/camera', '{home}/backup'), {'chapter': 'Basics'}, {'set_preference': {'selection': 'commander'}},
           cap('Mark items', 'Select or Deselect marks the item under the cursor and moves down'),
           cursor('left', 'cathedral-steps.jpg'), keys('@select_toggle', '@select_toggle', '@select_toggle', gap=380),
           wait({'selected': {'side': 'left', 'count': 3}}), hl('pane.left.status.selection', hold=1600), {'unhighlight': True},
           cap('Deselect All clears it'), keys('@clear_selection'), wait({'selected': {'side': 'left', 'count': 0}}),
           cap('Select by pattern', 'Every name that matches *.mov. Case is ignored'), *glob('*.mov'),
           wait({'selected': {'side': 'left', 'count': 6}}),
           cap('Deselect by pattern', 'Takes matches out of the selection again'), *glob('MOV_0031*', select=False),
           wait({'selected': {'side': 'left', 'count': 5}}), keys('@clear_selection'),
           cap('Select All respects the filter', 'With a filter, Select All marks only what you see'),
           {'type': 'harbour'}, keys('@select_all'), wait({'selected': {'side': 'left', 'count': 1}}),
           keys(*['Backspace'] * 7, gap=90), wait({'filter': {'side': 'left', 'is': ''}}),
           cap('Commands act on the selection', 'With nothing selected, they act on the item under the cursor', hold=2400),
           cap('Prefer Finder-style selection?', 'Settings › General › Selection style: arrow keys select, ⌘-click adds'),
           {'set_preference': {'selection': 'finder'}, 'hold': 1800}, {'set_preference': {'selection': 'commander'}},
           keys('@clear_selection'), {'uncaption': True}])

E['tabs'] = dict(
    title='Tabs', order=5, duration=40, chapter='basics',
    summary='Open, switch, reorder and close tabs; a tab can show a folder, a server or an archive.',
    covers={'commands': ['tab_new', 'tab_close', 'tab_next', 'tab_prev'], 'anchors': ['pane.left.tabs']},
    steps=[tabs('{home}/camera', '{home}/music'), {'chapter': 'Basics'}, {'remember': True},
           cap('New tab', 'New Tab opens a tab beside the current one, in the focused pane'),
           keys('@tab_new'), wait({'tabs': {'side': 'left', 'added': 1}}),
           {'navigate': {'side': 'left', 'to': '{home}/photos'}}, hl('pane.left.tabs', hold=1500), {'unhighlight': True},
           cap('Switch tabs', 'Previous Tab and Next Tab cycle through them; a click works too'),
           keys('@tab_prev'), wait({'path': {'side': 'left', 'ends_with': '/camera'}}), {'pause': 700},
           keys('@tab_next'), wait({'path': {'side': 'left', 'ends_with': '/photos'}}),
           cap('Close a tab'), keys('@tab_close'), wait({'tabs': {'side': 'left', 'added': 0}}),
           cap('Any kind of place', 'A tab shows a local folder, an SSH server or an archive. Drag a tab to reorder it'),
           hl('pane.left.tabs', 'pane.right.tabs', hold=2400), {'unhighlight': True}, {'uncaption': True}])

E['view'] = dict(
    title='Sort and columns', order=6, duration=45, chapter='basics',
    summary='Sort by name, size or date, show more columns, use one pane, and resize the panes.',
    covers={'commands': ['sort_by_name', 'sort_by_size', 'sort_by_date', 'toggle_permissions_column',
                         'toggle_owner_group_column', 'toggle_single_panel_mode'], 'anchors': ['panes.divider']},
    steps=[tabs('{home}/camera', '{home}/music/Night Drive'), {'chapter': 'Basics'},
           cap('Sort by size', 'Click a column header, or use View › Sort By. Again reverses the order'),
           keys('@sort_by_size'), wait({'sort': {'side': 'left', 'is': 'size'}}), {'pause': 1200},
           keys('@sort_by_size'), wait({'sort': {'side': 'left', 'is': 'size_desc'}}), {'pause': 1200},
           cap('Or by date'), keys('@sort_by_date'), wait({'sort': {'side': 'left', 'is': 'date'}}), {'pause': 1200},
           keys('@sort_by_name'), wait({'sort': {'side': 'left', 'is': 'name'}}),
           cap('More columns', 'Show permissions and owner:group, or right-click a column header'),
           keys('@toggle_permissions_column'), wait({'columns': {'side': 'left', 'permissions': True}}),
           keys('@toggle_owner_group_column'), wait({'columns': {'side': 'left', 'owner': True}}), {'pause': 1800},
           keys('@toggle_permissions_column'), keys('@toggle_owner_group_column'),
           wait({'columns': {'side': 'left', 'permissions': False, 'owner': False}}),
           cap('One pane, full width', 'Single Pane shows only the focused pane. Again brings both back'),
           keys('@toggle_single_panel_mode'), wait({'single': True}), {'pause': 1200},
           cap('The other pane is still the destination', 'The bar above the path says where copies and moves go'),
           hl('pane.target', hold=2000), {'unhighlight': True},
           cap('Switch Pane shows it', 'Still one pane, full width'), keys('@switch_panel'), wait({'focused': 'right'}),
           {'expect': {'single': True}}, {'pause': 1400}, keys('@switch_panel'), wait({'focused': 'left'}),
           keys('@toggle_single_panel_mode'), wait({'single': False}),
           cap('Resize the panes', 'Drag the line between them'), hl('panes.divider', hold=2000), {'unhighlight': True},
           {'uncaption': True}])

E['copy'] = dict(
    title='Copy files', order=7, duration=70, chapter='files', needs={'idle_queue': True},
    summary='The Copy sheet: what will be copied, the destination, links, existing files, and the job bar.',
    covers={'commands': ['copy'], 'anchors': ['sheet.copy.destination', 'sheet.copy.conflict', 'jobs.bar']},
    steps=[tabs('{home}/camera', '{home}/backup'), {'chapter': 'Files'}, {'set_transfer_speed': '25 MiB'},
           cap('Copy to the other pane', 'Select the photos by pattern, then copy them. The other pane is the destination'),
           *glob('*.jpg'), wait({'selected': {'side': 'left', 'count': 8}}), hl('pane.left.status.selection', hold=1400),
           keys('@copy'), wait({'sheet': 'copy'}),
           cap('See it before it happens', 'The sheet lists exactly what will be copied, and how much'),
           hl('sheet.copy.preview', 'sheet.copy.status', hold=2000),
           cap('Where, and how', 'Edit the destination, follow or keep links, and choose what happens to files that already exist'),
           hl('sheet.copy.destination', 'sheet.copy.conflict', hold=2400), {'unhighlight': True},
           {'click': 'sheet.copy.start', 'as_job': 'photos'}, wait({'sheet': None}),
           cap('It runs in the background', 'The job bar shows the copy; you can keep browsing meanwhile'),
           {'highlight': 'jobs.bar'}, wait({'job': {'name': 'photos', 'state': 'finished'}}, timeout=60), {'unhighlight': True},
           wait({'rows': {'side': 'right', 'contains': 'lighthouse.jpg'}}),
           cap('Copy again: Skip existing', 'Files already in the backup can stay as they are'),
           *glob('*.jpg'), keys('@copy'), wait({'sheet': 'copy'}), {'click': 'sheet.copy.conflict[mode=skip]', 'hold': 900},
           {'click': 'sheet.copy.start', 'as_job': 'again'}, wait({'job': {'name': 'again', 'state': 'finished'}}, timeout=30),
           cap('Safe by design', 'Copies are written under a private name and renamed into place when complete', hold=2600),
           {'uncaption': True}])

E['move_rename_mkdir'] = dict(
    title='New folder, rename and move', order=8, duration=50, chapter='files', needs={'idle_queue': True},
    summary='Create a folder, rename files, and move them to the other pane.',
    covers={'commands': ['mkdir', 'rename', 'move'], 'anchors': ['sheet.mkdir.name', 'sheet.move.start']},
    steps=[tabs('{home}/photos/2026', '{home}/backup'), {'chapter': 'Files'},
           cap('New folder'), keys('@mkdir'), wait({'sheet': 'mkdir'}), wait({'text_focus': True}), {'type': 'Summer'},
           keys('Enter'), wait({'sheet': None}), wait({'rows': {'side': 'left', 'contains': 'Summer'}}),
           cap('Rename', 'Rename works on one item or on the whole selection'),
           cursor('left', 'beach.jpg'), keys('@rename'), wait({'sheet': 'rename'}), wait({'text_focus': True}),
           keys('Cmd+A'), {'type': 'beach-day.jpg'}, keys('Enter'), wait({'sheet': None}),
           wait({'rows': {'side': 'left', 'contains': 'beach-day.jpg'}}),
           cap('Move to the other pane', 'Within one disk a move is a rename; across disks FC copies first, then removes'),
           cursor('left', 'city.jpg'), keys('@move'), wait({'sheet': 'move'}), {'pause': 1200}, {'click': 'sheet.move.start'},
           wait({'sheet': None}), wait({'rows': {'side': 'right', 'contains': 'city.jpg'}}),
           wait({'rows': {'side': 'left', 'lacks': 'city.jpg'}}), {'uncaption': True}])

E['delete'] = dict(
    title='Delete', order=9, duration=35, chapter='files', needs={'idle_queue': True},
    summary='Delete asks first and is permanent; links go, not what they point to.',
    covers={'commands': ['delete'], 'anchors': ['sheet.delete.start']},
    steps=[tabs('{home}', '{home}/photos'), {'chapter': 'Files'},
           cap('Delete is permanent', 'There is no trash. FC lists what it will delete and asks first'),
           cursor('left', 'old-link'), keys('@delete'), wait({'sheet': 'delete'}), hl('sheet.delete.start', hold=2200),
           {'click': 'sheet.delete.start'}, wait({'sheet': None}), wait({'rows': {'side': 'left', 'lacks': 'old-link'}}),
           {'unhighlight': True},
           cap('Links go, not what they point to', 'Deleting latest-photos removes the link; photos/2026 stays'),
           cursor('left', 'latest-photos'), keys('@delete'), wait({'sheet': 'delete'}), {'click': 'sheet.delete.start'},
           wait({'rows': {'side': 'left', 'lacks': 'latest-photos'}}), {'expect': {'file': {'exists': '{home}/photos/2026/beach.jpg'}}},
           cap('Folders too', 'A folder is deleted from the inside out, as a background job'),
           {'navigate': {'side': 'left', 'to': '{home}/projects'}}, cursor('left', 'notes'), keys('@delete'),
           wait({'sheet': 'delete'}), {'click': 'sheet.delete.start'}, wait({'rows': {'side': 'left', 'lacks': 'notes'}}),
           {'uncaption': True}])

E['clipboard'] = dict(
    title='Copy names and paths', order=10, duration=30, chapter='files',
    summary='Put the selected names or full paths on the clipboard, in the order you see them.',
    covers={'commands': ['names_to_clipboard', 'paths_to_clipboard'], 'anchors': ['hud']},
    steps=[tabs('{home}/camera', '{home}/backup'), {'chapter': 'Files'},
           cap('Copy paths', 'Copy Paths puts the selected full paths on the clipboard, one per line'),
           *glob('*.jpg'), wait({'selected': {'side': 'left', 'count': 8}}), keys('@paths_to_clipboard'),
           wait({'hud': '8 paths copied'}), wait({'clipboard': {'contains': '{home}/camera/cathedral-steps.jpg'}}),
           hl('hud', hold=1500),
           cap('Or just the names'), keys('@names_to_clipboard'), wait({'hud': '8 names copied'}),
           wait({'clipboard': {'contains': 'street-musicians.jpg'}}),
           cap('In the order you see', 'Sort by size first, and the clipboard lists the photos by size'),
           keys('@sort_by_size'), keys('@paths_to_clipboard'), wait({'hud': '8 paths copied'}), {'pause': 1500},
           keys('@sort_by_name'), keys('@clear_selection'), {'unhighlight': True}, {'uncaption': True}])

E['find'] = dict(
    title='Find files', order=11, duration=40, chapter='files',
    summary='Search names below a folder and show a result in the pane.',
    covers={'commands': ['find'], 'anchors': ['find.pattern', 'find.results', 'find.reveal']},
    steps=[tabs('{home}', '{home}/backup'), {'chapter': 'Files'},
           cap('Find files by name', 'Find searches below the current folder. * and ? work; case is ignored'),
           keys('@find'), wait({'window': 'find'}), wait({'text_focus': True}), {'type': '*.jpg'}, keys('Enter'),
           wait({'anchor': 'find.result[name=lighthouse.jpg]'}, timeout=20), hl('find.results', hold=1800),
           cap('Show it in the pane', 'Show in Pane opens the folder with the cursor on the file'),
           {'click': 'find.result[name=lighthouse.jpg]'}, {'click': 'find.reveal'},
           wait({'path': {'side': 'left', 'ends_with': '/camera'}}), wait({'cursor': {'side': 'left', 'name': 'lighthouse.jpg'}}),
           {'close_window': 'find'}, {'unhighlight': True}, {'uncaption': True}])

E['archives'] = dict(
    title='7z archives', order=12, duration=60, chapter='files', needs={'idle_queue': True},
    summary='Browse an archive, copy files out, create an archive, and why archives are read-only.',
    covers={'anchors': ['pane.left.path', 'errors.lines']},
    steps=[tabs('{home}', '{home}/backup'), {'chapter': 'Files'},
           cap('Archives open like folders', 'Open on a .7z file browses it, read-only'),
           cursor('left', 'website-2025.7z'), keys('@enter_dir'), wait({'rows': {'side': 'left', 'contains': 'app.js'}}, timeout=20),
           hl('pane.left.path', hold=1600), {'unhighlight': True},
           cap('Copy files out', 'Copy works as anywhere else'), keys('@select_all'), keys('@copy'), *copy_sheet('out'),
           wait({'rows': {'side': 'right', 'contains': 'index.html'}}, timeout=20),
           cap('Read-only', 'Changing files inside an archive is refused; copy them out first'),
           keys('@mkdir'), wait({'errors_at_least': 1}), hl('errors.lines', hold=2000), {'unhighlight': True},
           {'click': 'errors.clear'}, keys('@leave_dir'), wait({'path': {'side': 'left', 'ends_with': '/home'}}),
           cap('Make an archive', 'Copy to a destination that ends in .7z, and FC creates the archive'),
           {'navigate': {'side': 'left', 'to': '{home}/photos/2026'}}, *glob('*.jpg'), keys('@copy'), wait({'sheet': 'copy'}),
           wait({'text_focus': True}), keys('Cmd+A'), {'type': '{home}/backup/photos.7z'}, {'pause': 600},
           {'click': 'sheet.copy.start', 'as_job': 'archive'}, wait({'sheet': None}, timeout=20),
           wait({'job': {'name': 'archive', 'state': 'finished'}}, timeout=40),
           wait({'rows': {'side': 'right', 'contains': 'photos.7z'}}),
           cap('And it opens like a folder'), {'focus': 'right'}, cursor('right', 'photos.7z'), keys('@enter_dir'),
           wait({'rows': {'side': 'right', 'contains': 'beach.jpg'}}, timeout=20), {'pause': 1200}, keys('@leave_dir'),
           {'uncaption': True}])

E['background_jobs'] = dict(
    title='Background jobs', order=13, duration=75, chapter='jobs', needs={'idle_queue': True},
    summary='Jobs run in order while you work; Activity shows them; errors are recorded, not fatal.',
    covers={'commands': ['toggle_job_list', 'toggle_errors', 'clear_errors'], 'anchors': ['activity.list', 'errors.lines']},
    steps=[tabs('{home}', '{home}/backup'), {'chapter': 'Jobs'}, {'set_transfer_speed': '12 MiB'},
           cap('Everything runs in the background', 'Start a copy and keep working. Jobs run one at a time, in order'),
           cursor('left', 'camera'), keys('@copy'), *copy_sheet('camera'), wait({'job': {'name': 'camera', 'state': 'running'}}),
           cap('Queue another', 'A second copy waits for the first'), cursor('left', 'photos'), keys('@copy'), *copy_sheet('photos'),
           wait({'queued_at_least': 1}), hl('jobs.bar', hold=1800), {'unhighlight': True},
           cap('Keep browsing', 'The panes stay responsive while jobs run'),
           {'navigate': {'side': 'left', 'to': '{home}/music'}}, {'pause': 900},
           {'navigate': {'side': 'left', 'to': '{home}', 'focus': '{home}/music'}},
           cap('The Activity window', 'Every job, its progress and details; pause, resume, cancel or dismiss'),
           keys('@toggle_job_list'), wait({'window': 'activity'}), hl('activity.list', hold=2600), {'unhighlight': True},
           cap("Errors don't stop a job", 'photos/2025 holds a file nobody can read: the copy records it and goes on'),
           {'set_transfer_speed': 0}, wait({'job': {'name': 'photos', 'state': 'completed_with_errors'}}, timeout=90),
           {'close_window': 'activity'}, wait({'errors_at_least': 1}), hl('errors.lines', hold=2000),
           cap('The Errors window lists them all'), keys('@toggle_errors'), wait({'window': 'errors'}), {'pause': 2000},
           {'close_window': 'errors'}, cap('Clear them when you are done'), {'click': 'errors.clear'}, wait({'no_errors': True}),
           {'unhighlight': True}, {'uncaption': True}])

E['transfer_speed'] = dict(
    title='Transfer speed', order=14, duration=40, chapter='jobs', needs={'idle_queue': True},
    summary='Limit how fast copies run, and change it while a copy is running.',
    covers={'commands': ['transfer_speed'], 'anchors': ['jobs.bar.speed', 'speed']},
    steps=[tabs('{home}/music', '{home}/backup'), {'chapter': 'Jobs'}, {'set_transfer_speed': '6 MiB'},
           cursor('left', 'Night Drive'), keys('@copy'), *copy_sheet('music'), wait({'job': {'name': 'music', 'state': 'running'}}),
           cap('Change the speed while it runs', 'Transfer Speed limits copies, moves between disks and SSH transfers'),
           hl('jobs.bar.speed', hold=1400), keys('@transfer_speed'), wait({'sheet': 'speed'}),
           {'click': 'speed.preset[1 MB/s]'}, wait({'transfer_rate': '1 MiB'}), {'unhighlight': True},
           cap('The copy slows down at once', 'Even in the middle of a file'), {'pause': 2600},
           {'click': 'speed.preset[Unlimited]'}, wait({'transfer_rate': 0}),
           cap('For now or for good', 'Turn off Keep for future sessions to limit only until you quit'), hl('speed', hold=2200),
           keys('Enter'), wait({'sheet': None}), wait({'job': {'name': 'music', 'state': 'finished'}}, timeout=60),
           {'unhighlight': True}, {'uncaption': True}])

E['pause_resume'] = dict(
    title='Pause and resume', order=15, duration=70, chapter='jobs', needs={'idle_queue': True},
    summary='Pausing holds the whole queue; resume continues; cancel keeps what was copied.',
    covers={'anchors': ['jobs.bar.pause', 'jobs.bar.cancel']},
    steps=[tabs('{home}/music', '{home}/backup'), {'chapter': 'Jobs'}, {'set_transfer_speed': '4 MiB'},
           cursor('left', 'Night Drive'), keys('@copy'), *copy_sheet('music'),
           wait({'job': {'name': 'music', 'state': 'running', 'progress_at_least': 0.08}}, timeout=30),
           cap('Pause', 'Pause holds the job between two reads'), {'click': 'jobs.bar.pause'},
           wait({'job': {'name': 'music', 'state': 'paused'}}),
           cap('Queued jobs wait', 'Jobs run one at a time, so a paused job holds the queue'),
           cursor('left', 'Field Notes'), keys('@copy'), *copy_sheet('notes'), wait({'queued_at_least': 1}), {'pause': 1500},
           {'try': {'do': 'Resume the copy with the Resume button', 'hint': 'jobs.bar.pause',
                    'accept': {'job': {'name': 'music', 'state': 'running'}}, 'show': [{'click': 'jobs.bar.pause'}]}},
           wait({'job': {'name': 'music', 'state': 'running'}}, timeout=10),
           wait({'file': {'exists': '{home}/backup/Night Drive/01 Neon Rain.flac'}}, timeout=60),
           cap('Cancel keeps what is done', 'Finished files stay; cancelling is not an undo'), {'click': 'jobs.bar.cancel'},
           wait({'job': {'name': 'music', 'state': 'cancelled'}}),
           {'expect': {'file': {'exists': '{home}/backup/Night Drive/01 Neon Rain.flac'}}},
           cap('The next job starts', 'The queued copy runs now'), {'set_transfer_speed': 0},
           wait({'job': {'name': 'notes', 'state': 'finished'}}, timeout=60), {'uncaption': True}])

E['bookmarks'] = dict(
    title='Bookmarks', order=16, duration=35, chapter='places',
    summary='Bookmark folders, servers and archives, and open them from the sidebar.',
    covers={'commands': ['add_bookmark', 'open_bookmarks'], 'anchors': ['sidebar.bookmarks']},
    steps=[tabs('{home}/photos/2026', '{home}'), {'chapter': 'Places'},
           cap('Bookmark a folder', 'Bookmark This Folder adds the focused pane’s folder to the sidebar'),
           keys('@add_bookmark'), wait({'bookmark': '2026'}), hl('sidebar.bookmarks', hold=1800), {'unhighlight': True},
           cap('Open a bookmark', 'Click it to open it in the focused pane'),
           {'navigate': {'side': 'left', 'to': '{home}'}}, {'click': 'sidebar.bookmark[name=2026]'},
           wait({'path': {'side': 'left', 'ends_with': '/2026'}}),
           cap('Servers and archives too', 'Right-click a bookmark to open it in either pane or a new tab, or to remove it'),
           {'pause': 2200}, {'remove_bookmark': '2026'}, wait({'no_bookmark': '2026'}), {'uncaption': True}])

E['ssh'] = dict(
    title='SSH servers', order=17, duration=80, chapter='places', needs={'idle_queue': True},
    summary='Connect to a server, browse it, upload a folder, and watch it refresh.',
    covers={'commands': ['connect_ssh'], 'anchors': ['sheet.ssh.host', 'sheet.ssh.connect']},
    steps=[tabs('{home}', '{home}/projects'), {'chapter': 'Places'},
           cap('Connect to a server', 'SSH locations open in a tab. The server needs only Python 3'),
           keys('@connect_ssh'), wait({'sheet': 'ssh'}), wait({'text_focus': True}), {'type': 'demo-server'}, keys('Tab'),
           keys('Cmd+A'), {'type': '{server}'}, {'pause': 600}, {'click': 'sheet.ssh.connect'}, wait({'sheet': None}, timeout=25),
           wait({'rows': {'side': 'left', 'contains': 'index.html'}}, timeout=25),
           cap('A demo server', "It runs FC's real remote agent on your Mac instead of over the network"),
           hl('pane.left.tabs', 'pane.left.path', hold=2200), {'unhighlight': True},
           cap('Upload a folder', 'Copy works between local and remote tabs, and between two servers'),
           {'focus': 'right'}, cursor('right', 'website'), keys('@copy'), *copy_sheet('upload'),
           wait({'rows': {'side': 'left', 'contains': 'website'}}, timeout=40),
           cap('It refreshes by itself', 'The active SSH tab is checked every three seconds'),
           {'touch': '{server}/new-page.html'}, wait({'rows': {'side': 'left', 'contains': 'new-page.html'}}, timeout=12),
           cap('Your own servers', 'Hosts, users, keys and jump hosts come from ~/.ssh/config. Passwords are asked in a sheet', hold=2800),
           {'uncaption': True}])

E['editor_basics'] = dict(
    title='The editor', order=18, duration=50, chapter='editor', needs={'editor': True},
    summary='Open files in Fresh, switch back and forth, and keep unsaved text.',
    covers={'commands': ['open_in_editor', 'switch_to_file_commander', 'switch_editor_prev', 'switch_editor_next']},
    steps=[tabs('{home}/projects/website', '{home}/projects/notes'), {'chapter': 'Editor'},
           cap('Open files in the editor', 'Open in Editor shows them in Fresh, in place of the panes'),
           cursor('left', 'index.html'), keys('@open_in_editor'), wait({'editor': {'running': True}}, timeout=25),
           wait({'editor': {'window': 'main'}}, timeout=5),
           wait({'editor': {'contains': 'Field Notes'}}, timeout=25),
           cap('Edit', 'Fresh is a full editor: tabs, search, multiple cursors, syntax colors'),
           {'editor_keys': ['End']}, {'editor_type': ' <!-- draft -->'}, {'pause': 900},
           cap('Switch back', 'F10 in the editor comes back to File Commander'), {'editor_keys': ['F10']},
           wait({'editor': {'running': False}}, timeout=10),
           cap('Unsaved text survives', 'Switching only hides the editor; its tabs and unsaved text stay'),
           keys('@switch_to_file_commander'), wait({'editor': {'running': True}}, timeout=20),
           wait({'editor': {'contains': 'draft'}}, timeout=15), {'pause': 1500},
           {'editor_keys': ['F10']}, wait({'editor': {'running': False}}, timeout=10), {'uncaption': True}])

E['editor_window'] = dict(
    title='Files and editor in one window', order=19, duration=80, chapter='editor', needs={'editor': True, 'idle_queue': True},
    summary="F4 turns the window into the editor: Fresh's menus in the menu bar, tabs, the command palette and the file sidebar.",
    covers={'anchors': ['editor.tabs', 'editor.status', 'editor.palette', 'editor.explorer', 'toolbar.mode', 'jobs.bar']},
    steps=[tabs('{home}/photos', '{home}/backup'), {'chapter': 'Editor'},
           cap('Start a copy first', 'At 1 MiB/s it is still running when the editor opens'), {'set_transfer_speed': '1 MiB'},
           cursor('left', '2026'), keys('@copy'), *copy_sheet('photos'), wait({'running_job': True}, timeout=10),
           {'navigate': {'side': 'left', 'to': '{home}/projects/website'}}, cursor('left', 'index.html'),
           keys('@open_in_editor'), wait({'editor': {'contains': 'Field Notes'}}, timeout=25),
           wait({'editor': {'window': 'main'}}, timeout=5),
           cap('One window', 'The editor takes the place of the panes; Fresh edits, the window draws its tabs and status bar'),
           hl('editor.tabs', 'editor.status', hold=2200),
           cap('Jobs keep going', 'The job bar stays below the editor, with its Pause and Cancel buttons'),
           hl('jobs.bar', hold=1800), wait({'running_job': False}, timeout=60),
           cap("Fresh's menus", 'While the editor is shown, the menu bar holds its menus, with \u2318 shortcuts'), {'pause': 2400},
           # The copy ended while the editor was shown; the app's menus must not have come back meanwhile.
           wait({'all': [{'menubar': 'Selection'}, {'not': {'menubar': 'Transfers'}}]}, timeout=5),
           cap('Command palette', '\u21e7\u2318P finds any editor command by name'),
           {'editor_keys': ['Cmd+Shift+P']}, wait({'editor': {'shows': 'palette'}}, timeout=10),
           {'editor_type': 'toggle line'}, hl('editor.palette', hold=2000), {'pause': 2000}, {'editor_keys': ['Esc']},
           wait({'editor': {'hides': 'palette'}}, timeout=10),
           cap('Files beside the text', '\u2318B shows the folder in a sidebar'),
           {'editor_keys': ['Cmd+B']}, wait({'editor': {'shows': 'explorer'}}, timeout=10), hl('editor.explorer', hold=2000),
           {'pause': 2000},
           {'editor_keys': ['Cmd+B']}, {'pause': 300}, {'editor_keys': ['Cmd+B']}, wait({'editor': {'hides': 'explorer'}}, timeout=10),
           cap('Open another file', 'Without the > the palette finds files of the folder by name'),
           {'editor_keys': ['Cmd+P']}, wait({'editor': {'shows': 'palette'}}, timeout=10), {'editor_keys': ['Backspace']},
           {'editor_type': 'style'}, {'pause': 900},
           {'editor_keys': ['Enter']}, wait({'editor': {'contains': 'max-width'}}, timeout=10), {'pause': 1200},
           wait({'all': [{'menubar': 'Selection'}, {'not': {'menubar': 'Transfers'}}]}, timeout=5),
           cap('Files or the editor', 'The switch in the toolbar goes back and forth, as F10 does; the panes stay as you left them'),
           hl('toolbar.mode', hold=1600), {'click': 'toolbar.mode'}, wait({'editor': {'running': False}}, timeout=10),
           wait({'cursor': {'side': 'left', 'name': 'index.html'}}), {'pause': 1400},
           {'click': 'toolbar.mode'}, wait({'editor': {'running': True}}, timeout=10),
           wait({'editor': {'window': 'main'}}, timeout=5), {'pause': 1200},
           {'editor_keys': ['F10']}, wait({'editor': {'running': False}}, timeout=10), {'uncaption': True}])

E['editor_ssh'] = dict(
    title='Edit files on a server', order=20, duration=55, chapter='editor', needs={'editor': True},
    summary='Open a file of an SSH tab in the editor; Fresh works on the server and saves there.',
    covers={'anchors': ['editor.status']},
    steps=[tabs('{home}', '{home}/projects'), {'chapter': 'Editor'},
           cap('Edit on a server', 'Files in an SSH tab open in the editor too'),
           keys('@connect_ssh'), wait({'sheet': 'ssh'}), wait({'text_focus': True}), {'type': 'demo-server'}, keys('Tab'),
           keys('Cmd+A'), {'type': '{server}'}, {'pause': 400}, {'click': 'sheet.ssh.connect'}, wait({'sheet': None}, timeout=25),
           wait({'rows': {'side': 'left', 'contains': 'index.html'}}, timeout=25),
           cursor('left', 'index.html'), keys('@open_in_editor'), wait({'editor': {'contains': 'Coming soon'}}, timeout=30),
           wait({'editor': {'window': 'main'}}, timeout=5),
           cap('Fresh works on the server', 'Saving, searching and language servers run there; the status bar names it'),
           hl('editor.status', hold=2200), {'pause': 1600},
           {'editor_keys': ['Down', 'Down', 'End']}, {'editor_type': ' (draft)'}, {'pause': 500},
           cap('Save on the server', '\u2318S writes the file on the server, over the same connection'),
           {'editor_keys': ['Cmd+S']}, wait({'file': {'path': '{server}/index.html', 'contains': '(draft)'}}, timeout=15),
           {'pause': 1400}, {'editor_keys': ['F10']}, wait({'editor': {'running': False}}, timeout=10), {'uncaption': True}])

E['editor_multicursor'] = dict(
    title='Multiple cursors', order=21, duration=60, chapter='editor', needs={'editor': True},
    summary='Paste photo paths into code, then edit every line at once with multiple cursors.',
    covers={'anchors': ['editor.text']},
    steps=[tabs('{home}/camera', '{home}/projects/website'), {'chapter': 'Editor'},
           cap('Copy the photo paths', 'Select the photos and Copy Paths'), *glob('*.jpg'), keys('@paths_to_clipboard'),
           wait({'hud': '8 paths copied'}),
           cap('Open the code', 'app.js builds the photo grid'), {'focus': 'right'}, cursor('right', 'app.js'),
           keys('@open_in_editor'), wait({'editor': {'contains': 'Builds the photo grid'}}, timeout=25),
           wait({'editor': {'window': 'main'}}, timeout=5),
           cap('Paste them as an array'), {'editor_keys': ['Down', 'Down', 'Down']}, {'editor_type': 'const photos = ['},
           {'editor_keys': ['Enter', 'Ctrl+V']}, wait({'editor': {'contains': 'street-musicians\\.jpg'}}),
           {'editor_keys': ['Enter']}, {'editor_type': '];'},
           cap('Select the common prefix with the mouse'), {'drag': {'from': 'editor.text[{home}/camera/]', 'to': 'editor.text[{home}/camera/]'}},
           cap('Every line at once', 'Ctrl+D adds a cursor at the next match'),
           {'editor_keys': ['Ctrl+D'] * 7, 'gap': 280}, {'editor_keys': ['Backspace']},
           cap('End and Home move every cursor', 'Quote each name, whatever its length'),
           {'editor_keys': ['End']}, {'editor_type': '",'}, {'editor_keys': ['Home']}, {'editor_type': '"'},
           {'editor_keys': ['Home', 'Tab', 'Esc']}, wait({'editor': {'contains': '"lighthouse\\.jpg",'}}), {'pause': 1500},
           {'editor_keys': ['Ctrl+S']}, {'pause': 600}, {'editor_keys': ['F10']}, wait({'editor': {'running': False}}, timeout=10),
           {'uncaption': True}])

E['editor_restart'] = dict(
    title='Restart the editor', order=22, duration=35, chapter='editor', needs={'editor': True},
    summary='After upgrading Fresh, restart its backend; unsaved text survives.',
    covers={'commands': ['restart_editor_backend'], 'anchors': ['sheet.restart.confirm']},
    steps=[tabs('{home}/projects/notes', '{home}'), {'chapter': 'Editor'},
           cursor('left', 'ideas.md'), keys('@open_in_editor'), wait({'editor': {'contains': 'Ideas'}}, timeout=25),
           wait({'editor': {'window': 'main'}}, timeout=5),
           {'editor_keys': ['End']}, {'editor_type': ' (unsaved)'}, {'editor_keys': ['F10']}, wait({'editor': {'running': False}}, timeout=10),
           cap('Restart the backend', 'A running editor keeps the old Fresh until it restarts'),
           keys('@restart_editor_backend'), wait({'sheet': 'restart'}), {'click': 'sheet.restart.confirm'},
           wait({'editor': {'running': True}}, timeout=30), wait({'editor': {'contains': 'unsaved'}}, timeout=20),
           cap('Your text is still there', 'Fresh saved its recovery data before stopping'), {'pause': 1800},
           {'editor_keys': ['F10']}, wait({'editor': {'running': False}}, timeout=10), {'uncaption': True}])

E['editor_terminal'] = dict(
    title='The editor as a terminal', order=23, duration=45, chapter='editor', needs={'editor': True},
    summary="Settings \u203a Editor can show Fresh's own terminal interface in place of the native editor.",
    covers={'anchors': ['settings.editor.terminal']},
    steps=[tabs('{home}/projects/notes', '{home}'), {'chapter': 'Editor'},
           cap("Fresh's own look", 'Settings \u203a Editor \u203a Show the editor as a terminal runs its terminal interface instead'),
           {'open_window': 'settings', 'note': 'editor'}, wait({'window': 'settings'}), hl('settings.editor.terminal', hold=2000),
           {'set_preference': {'terminal_editor': True}}, {'pause': 1200}, {'close_window': 'settings'},
           cursor('left', 'ideas.md'), keys('@open_in_editor'), wait({'editor': {'contains': 'Ideas'}}, timeout=25),
           wait({'editor': {'window': 'main'}}, timeout=5),
           cap('Same place, same Fresh', "It takes the panes' place too, with the same tabs and unsaved text"), {'pause': 1500},
           cap('Its own keys', "Typing, F-keys and Control keys go to Fresh, ahead of File Commander's menus"),
           {'editor_keys': ['End']}, {'type': ' (typed)'}, wait({'editor': {'contains': '\\(typed\\)'}}, timeout=10), {'pause': 900},
           cap('F10 comes back', "Fresh's own switch key detaches it, and the panes return"),
           keys('F10'), wait({'editor': {'running': False}}, timeout=10),
           wait({'cursor': {'side': 'left', 'name': 'ideas.md'}}), {'set_preference': {'terminal_editor': False}},
           {'pause': 600}, {'uncaption': True}])

E['palette_keys'] = dict(
    title='Commands and keys', order=24, duration=55, chapter='yours',
    summary='Find any command in the palette, rebind its key, and pick a key preset.',
    covers={'commands': ['command_palette'], 'anchors': ['palette.field']},
    steps=[tabs('{home}', '{home}/camera'), {'chapter': 'Make It Yours'},
           cap('Every command, one search away', 'The command palette finds commands by any part of their name'),
           keys('@command_palette'), wait({'palette': 'commands'}), wait({'text_focus': True}), {'type': 'ssh'},
           wait({'anchor': 'palette.row[command=connect_ssh]'}), hl('palette.row[command=connect_ssh]', hold=1800),
           cap('Change its key', 'Select a command, press ⌃K, then the new key'), keys('Ctrl+K'), {'pause': 700},
           keys('Ctrl+Opt+S'), wait({'hud': 'Connect to Server'}), {'unhighlight': True}, keys('Esc'), wait({'palette': None}),
           cap('The new key works'), keys('Ctrl+Opt+S'), wait({'sheet': 'ssh'}), {'pause': 900}, keys('Esc'), wait({'sheet': None}),
           cap('Two presets', 'Commander keeps the terminal keys; Mac uses Finder’s shortcuts. Settings › Keys lists every key'),
           {'open_window': 'settings', 'note': 'keys'}, {'pause': 2600}, {'close_window': 'settings'}, {'uncaption': True}])

E['themes'] = dict(
    title='Themes, colors and fonts', order=25, duration=60, chapter='yours', needs={'settings': True},
    summary='Light and dark, colors for both, and a font and size for every element.',
    covers={'commands': ['edit_theme_colors'], 'anchors': ['settings.appearance.preview', 'settings.appearance.font.bigger']},
    steps=[tabs('{home}/camera', '{home}/music'), {'chapter': 'Make It Yours'},
           cap('Light or dark', 'Follow the system, or choose one in Settings › General'),
           {'set_preference': {'appearance': 'dark'}, 'hold': 1800}, {'set_preference': {'appearance': 'light'}, 'hold': 1500},
           {'set_preference': {'appearance': 'system'}},
           cap('The theme editor', 'Every element has a color for light and for dark, and a font and size'),
           keys('@edit_theme_colors'), wait({'window': 'settings'}), {'pause': 800},
           {'click': 'settings.appearance.element[listing.name#font]'},
           cap('Bigger names in the list', 'Changes show at once, in the preview and in the window'),
           {'click': 'settings.appearance.font.bigger'}, {'click': 'settings.appearance.font.bigger'},
           {'click': 'settings.appearance.font.bigger'}, wait({'font_size': {'element': 'listing.name', 'is': 16}}),
           hl('settings.appearance.preview', hold=2200), {'unhighlight': True},
           cap('Colors', 'Pick a color for light and dark, or a system color that follows your accent color'),
           {'click': 'settings.appearance.element[listing.directory]'}, hl('settings.appearance.color.light', 'settings.appearance.color.dark', hold=2400),
           cap('Save, revert or reset', 'Save keeps it as your own theme; Revert drops the edits'),
           {'click': 'settings.appearance.revert'}, {'pause': 900}, {'close_window': 'settings'}, {'unhighlight': True},
           {'uncaption': True}])

E['scripting'] = dict(
    title='Lua scripts', order=26, duration=40, chapter='yours', needs={'idle_queue': True},
    summary="Automate File Commander with Lua: a script copies the camera's photos.",
    covers={'commands': ['run_script']},
    steps=[tabs('{home}/projects/tools', '{home}/backup'), {'chapter': 'Make It Yours'},
           cap('Scripts drive File Commander', 'A Lua script runs commands, presses keys and waits for jobs'),
           cursor('left', 'copy-jpg.lua'), {'pause': 1200},
           cap('Run Lua Script', 'Runs it with fc run, in a terminal window. This one copies every photo to the backup'),
           {'run_script': '{home}/projects/tools/copy-jpg.lua'}, wait({'window': 'script'}),
           wait({'file': {'exists': '{home}/backup/street-musicians.jpg'}}, timeout=60), {'pause': 2000},
           {'close_window': 'script'}, {'front': True},
           cap('The scripting guide', 'doc/scripting.md describes the API, events and the state table', hold=2400),
           {'uncaption': True}])

E['workspace_restore'] = dict(
    title='Quit and come back', order=27, duration=40, chapter='recovery', needs={'restart': True},
    summary='Tabs, folders, selections and filters come back after a quit.',
    covers={'anchors': ['pane.left.tabs']},
    steps=[tabs('{home}/camera', '{home}/music'), {'chapter': 'Recovery'},
           cap('Leave it as it is', 'Select some photos and filter the list'), *glob('*.jpg'), {'type': 'or'},
           wait({'filter': {'side': 'left', 'is': 'or'}}),
           cap('Quit and open again', 'File Commander saves where you are every half second'), {'relaunch': True},
           cap('Everything is back', 'Tabs, folders, selections, filters, sort order and the layout'),
           wait({'path': {'side': 'left', 'ends_with': '/camera'}}, timeout=20), wait({'filter': {'side': 'left', 'is': 'or'}}),
           hl('pane.left.tabs', 'pane.left.filter', 'pane.left.status', hold=2600), {'unhighlight': True},
           keys(*['Backspace'] * 2, gap=120), keys('@clear_selection'), {'uncaption': True}])

E['crash_recovery'] = dict(
    title='Crash recovery', order=28, duration=75, chapter='recovery', needs={'crash': True, 'idle_queue': True},
    summary='A real crash in the middle of a copy: what comes back, and how the copy continues.',
    covers={'commands': ['simulate_crash'], 'anchors': ['activity.recovery', 'activity.resume']},
    steps=[tabs('{home}/music', '{home}/backup'), {'chapter': 'Recovery'}, {'set_transfer_speed': '3 MiB'},
           cap('A long copy', 'Every copy is journaled on disk before it starts'),
           cursor('left', 'Night Drive'), keys('@copy'), *copy_sheet('music'),
           wait({'job': {'name': 'music', 'state': 'running', 'progress_at_least': 0.3}}, timeout=60),
           cap('Now File Commander is killed', 'SIGKILL: no warning, no chance to save'), {'crash': 'Kill File Commander'},
           cap('Back where you were', 'The tabs came back, and the copy is waiting, paused'),
           keys('@toggle_job_list'), wait({'window': 'activity'}), wait({'job': {'name': 'paused', 'state': 'paused'}}, timeout=10),
           hl('activity.list', hold=2000), {'unhighlight': True},
           cap('Resume checks first', 'FC makes sure the files didn’t change, then continues file by file'),
           {'click': 'activity.resume'}, wait({'running_job': True}, timeout=10),
           wait({'running_job': False}, timeout=90), {'close_window': 'activity'},
           {'expect': {'file': {'exists': '{home}/backup/Night Drive/04 Slow Lights.flac'}}},
           cap('Nothing was lost', 'Finished files were kept; the interrupted one was copied again', hold=2400),
           {'uncaption': True}])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for path in OUT.glob('*.json'):
        if path.name != 'chapters.json':
            path.unlink()
    for id, body in E.items():
        script = {'id': id, **body}
        (OUT / f'{id}.json').write_text(json.dumps(script, indent=2, ensure_ascii=False) + '\n')
    print(f'wrote {len(E)} explainers to {OUT}')


if __name__ == '__main__':
    main()
