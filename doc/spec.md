
# What

An orthodox file manager. Exploring directories to run commands on selected files.

Initial Features:
- prepend char to item render
  - dir marked with `/`
  - symlink marked with `~`
  - executable file marked with `*`
- Maybe change boost to std filesystem https://en.cppreference.com/w/cpp/filesystem/is_socket~
  - Color based on file type
    - Block file('b')
    - Character device file('c')
    - Named pipe file or just a pipe file('p')
    - Symbolic link file('l')
    - Socket file('s')
- monitor dir changes and real-time updates
+ Left and Right panel
- Panel having multiple tabs
+ tab contains file list allowing selection ?with undo-selection-action?
+ esc clears selection
+ If no item selected then item under the cursor is considered selected
+ List can be sorted on any column ASC/DESC
- Target for the command is always other-panel-selected-tab. Some commands ignore target dir and files.
- Command search like vscode-F1 with option to update key-shorcut on the spot
- Easily add new commands 
- When width is small show single panel only with visible other panel path
- All commands happen in separate thread, like TC copy in background.
- Command progress panel TBD
- FileList implement vscroll_indicator & yframe and create Element's for only visible items.

Initial commands:
+ mkdir
- copy & confirm popup
- move & confirm popup
- delete & confirm popup
+ rename
+ multi-rename
- names to clipboard
- paths to clipboard
- Find files, breadth-first-search, creates new tab for results
- allow defining custom command
  - 7z compress & extract
  - tar/gz extract
  - open in installed editor app

## Extra

Clipboard support
+ text paste works good
- text copy is not possible when mouse is captured
- https://stackoverflow.com/questions/65840288/monitor-clipboard-changes-c-for-all-applications-windows

# Design

                                                                                        
  Left     File     Command     Options     Right
┌<─ ~/code/FTXUI/build/examples/dom ──.[^]>┐┌<─ ...TXUI/build/examples/component ─.[^]>┐
│.n       Name        │ Size  │Modify time ││.n       Name        │ Size  │Modify time │
│*ftxui_exam~r_gallery│1210280│Sep  2 18:00││*ftxui_exam~_checkbox│3663336│Sep  2 18:00│
│*ftxui_exam~alette256│ 877360│Sep  2 18:00││*ftxui_exam~_in_frame│3594768│Sep  2 18:00│
│*ftxui_exam~color_HSV│ 758624│Sep  2 18:00││*ftxui_exam~llapsible│3776360│Sep  2 18:00│
│*ftxui_exam~color_RGB│ 989424│Sep  2 18:00││*ftxui_exam~mposition│3787656│Sep  2 18:00│
│*ftxui_example_dbox  │ 950016│Sep  2 18:00││*ftxui_exam~stom_loop│2545832│Sep  2 18:00│
│*ftxui_example_gauge │ 738208│Sep  2 18:00││*ftxui_exam~_dropdown│4043928│Sep  2 18:00│
│*ftxui_exam~direction│1053744│Sep  2 18:00││*ftxui_exam~wn_custom│4182864│Sep  2 18:00│
│*ftxui_example_graph │1251280│Sep  2 18:00││*ftxui_exam~x_gallery│4263904│Sep  2 18:00│
│*ftxui_exam~e_gridbox│ 956616│Sep  2 18:00││*ftxui_example_focus │3482064│Sep  2 18:00│
│*ftxui_example_hflow │1190944│Sep  2 18:00││*ftxui_exam~us_cursor│2313752│Sep  2 18:00│
│*ftxui_exam~html_like│1450488│Sep  2 18:00││*ftxui_exam~e_gallery│4691736│Sep  2 18:00│
│*ftxui_exam~_gradient│ 982112│Sep  2 18:00││*ftxui_exam~omescreen│5299384│Sep  2 18:00│
│*ftxui_exam~e_manager│1261808│Sep  2 18:00││*ftxui_example_input │3872448│Sep  2 18:00│
│*ftxui_exam~paragraph│1220168│Sep  2 18:00││*ftxui_exam~put_style│4001496│Sep  2 18:00│
│*ftxui_exam~separator│1016440│Sep  2 18:00││*ftxui_exam~t_gallery│3213704│Sep  2 18:00│
│*ftxui_exam~tor_style│ 999760│Sep  2 18:00││*ftxui_example_maybe │3891328│Sep  2 18:00│
│*ftxui_example_size  │1014224│Sep  2 18:00││*ftxui_example_menu  │3648912│Sep  2 18:00│
│*ftxui_exam~e_spinner│1267848│Sep  2 18:00││*ftxui_example_menu2 │3962144│Sep  2 18:00│
│*ftxui_exam~yle_blink│ 697256│Sep  2 18:00││*ftxui_exam~u_entries│4035160│Sep  2 18:00│
│*ftxui_exam~tyle_bold│ 697192│Sep  2 18:00││*ftxui_exam~_animated│3882336│Sep  2 18:00│
│*ftxui_exam~yle_color│1073208│Sep  2 18:00││*ftxui_exam~_in_frame│3900808│Sep  2 18:00│
│*ftxui_exam~style_dim│ 697128│Sep  2 18:00││*ftxui_exam~orizontal│3858616│Sep  2 18:00│
│*ftxui_exam~e_gallery│ 964120│Sep  2 18:00││*ftxui_exam~_multiple│4014840│Sep  2 18:00│
│*ftxui_exam~hyperlink│ 709232│Sep  2 18:00││*ftxui_exam~enu_style│4254376│Sep  2 18:00│
│*ftxui_exam~_inverted│ 697456│Sep  2 18:00││*ftxui_exam~d_gallery│3996448│Sep  2 18:00│
│*ftxui_exam~kethrough│ 698880│Sep  2 18:00││*ftxui_exam~al_dialog│3944152│Sep  2 18:00│
│*ftxui_exam~nderlined│ 697648│Sep  2 18:00││*ftxui_exam~og_custom│3994848│Sep  2 18:00│
│*ftxui_exam~ed_double│ 699096│Sep  2 18:00││*ftxui_exam~ed_screen│3805768│Sep  2 18:00│
│*ftxui_example_table │1100448│Sep  2 18:00││*ftxui_exam~key_press│2939872│Sep  2 18:00│
│*ftxui_exam~vbox_hbox│ 611256│Sep  2 18:00││*ftxui_exam~_radiobox│3351320│Sep  2 18:00│
│*ftxui_example_vflow │1190896│Sep  2 18:00││*ftxui_exam~_in_frame│3621568│Sep  2 18:00│
├──────────────────────────────────────────┤├──────────────────────────────────────────┤
│*ftxui_example_vflow                      ││*ftxui_example_radiobox_in_frame          │
└────────────────────── 394G / 926G (42%) ─┘└────────────────────── 394G / 926G (42%) ─┘
Hint: M-! will allow you to execute programs and see the output in the viewer.
component #                                                                          [^]
 1Help   2Menu    3View    4Edit    5Copy    6RenMov 7Mkdir   8Delete  9PullDn 10Quit

