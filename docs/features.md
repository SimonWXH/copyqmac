# CopyQ Mac Features

Detailed reference for CopyQ Mac features, implementation behaviours, and data model.

- **Main window**, in the shape of the CopyQ window: a standard macOS title
  bar and opaque, resizable body with a menu bar (CopyQmac / File / Edit / Item
  / Tabs / Help), a row of clickable tab pages, a numbered item list with
  alternating row shading and the native blue selection highlight, a preview
  pane, and a status bar. The window remembers its size and position between
  launches; a saved frame whose display is no longer attached is pulled back
  onto an attached screen so it cannot reopen out of reach. The same window
  follows the active Space when summoned from the hotkey or menu-bar icon, and
  the app has no Dock icon while its windows are closed.
- **Window layouts.** The window supports two arrangements, chosen by a stored
  preference: the classic Layout A (tab strip, filter bar, item list, bottom
  preview pane with the note editor, and status bar) and Layout B
  (a native collapsible tab sidebar with per-tab counts and a capture badge, a
  unified toolbar holding the search field, scope picker, and inspector toggle,
  the item list in the centre with responsive primary text wrapping up to a
  6-line cap, and a trailing inspector with entry metadata above a resizable
  preview and note, its column width set by a leading-edge drag handle and
  restored on relaunch). Layout B is the default arrangement, including for
  an install whose preferences predate the layout control; a missing or unknown
  stored value also falls back to Layout B, and users can switch between Layout A and
  Layout B at runtime in Preferences ▸ History ▸ Appearance (Window layout: Top tabs /
  Sidebar + inspector). The exact geometry is in [Architecture](architecture.md).
- **Faithful capture.** Every non-empty pasteboard change that is not excluded,
  marked private, skipped because no source app could be attributed, or dropped
  by the AI-service API-key guard is recorded with all available flavours, so
  text, rich text, HTML, images, file URLs, and unknown custom types are stored
  with their exact bytes keyed by their type identifier. Any decodable
  `public.image` flavour can be previewed (including PNG, TIFF, JPEG, HEIC, and
  GIF). An entry can therefore be written back to the pasteboard exactly as it
  was captured. A payload that spells characters as JavaScript-style `\uXXXX`
  escapes, which some apps emit for copied rich text, is shown and indexed as
  the characters it means, while the stored bytes and what paste-back writes
  stay untouched.
- **Rich rows and preview.** HTML and RTF entries draw their stored fonts,
  headings, and colours in the list and the preview pane, the way CopyQ shows a
  rich item, instead of only their plain-text excerpt. Row text is fitted into
  the compact list, colours are adapted for light and dark appearance, and a
  text-only entry looks exactly as before. Search, the stored payload, and
  paste-back are unchanged.
- **Tabs.** Create, rename, reorder, and remove tabs, and choose which
  tab captures made on this machine are written into. The tab context menu and
  the Tabs menu name each move for the layout's axis - Move Left / Move Right
  above the top tab strip and Move Up / Move Down in the sidebar - while both
  shift the tab one slot toward the start or the end of the list. A tab's sync
  folder is the only sync control: fill it in and the tab imports from it and
  writes captures, new items, and edits back to it; leave it empty and the tab
  stays local. The folder field saves what it holds after a short pause, as well
  as on Return and when it loses focus, so a pasted path is not lost by clicking
  away.
- **Notes.** Every entry has an editable note (Command-E or Item ▸ Edit
  Note), saved as you type and included in search.
- **Images.** Image entries show a thumbnail in the list and a larger
  preview, and paste back in their original format.
- **Editing items.** Item ▸ Edit Item… (`fn`-`F2`, also in the row context
  menu and status menu) opens the selected entry's text in an editor sheet. An
  entry that stores HTML or RTF in a single item opens a styled editor: the
  text keeps its own styling, and a toolbar adds exactly bold, italic,
  underline, colour, and size (⌘B, ⌘I, and ⌘U for the first three). Saving
  writes the entry back in the format it already stores - HTML for an HTML
  item, RTF for an RTF item - and re-opening it shows the same styling; a
  plain-text item stays plain text and is never silently upgraded to rich text.
  A rich item whose formatting the styled editor cannot keep - an inline image,
  a list, centre, right, or justified alignment, paragraph spacing, a
  background or strikethrough, or another unmodelled attribute - opens the
  plain editor instead, with a note that saving will drop that formatting.
  Fonts are not validated, the way CopyQ does it: a payload that names a font
  this system does not have stays editable, and the editor shows it exactly as
  the list and preview do - at the family the system's reader substituted, at
  the payload's own size. A family the payload names that this system has keeps
  its own font. The exception is an RTF family name with non-ASCII characters,
  which the app's RTF writer cannot record: that item keeps the plain editor
  instead of having its family silently renamed on save. The Editor font in
  Preferences ▸ History ▸ Fonts is the base font new text is typed in, while a
  payload's own runs keep their fonts; see Preferences for what it
  changes and what it leaves alone.
  For image and file entries the item reads
  "Edit Item… (Use Edit Note)" and stays disabled because their preview draws
  the payload instead of editable text. Saving a plain item replaces its
  plain-text flavours and, when the text changed, keeps only image and file-URL
  payloads; HTML, RTF, RTFD, URLs, text-bearing UTI/MIME types, and other
  attachments that described the old content are dropped. It reindexes search.
  Saving an edited item also rewrites its own file group in the tab's sync
  folder under the same stem, so the other machine updates the same item rather
  than seeing a new one; a dropped HTML or other flavour does not leave an
  orphan file. Remote edits are resolved by timestamp instead of a permanent
  local-edit veto: a newer remote edit replaces the local content and logs a
  payload summary (formats, byte length, short hash) of what was discarded,
  while an older one is discarded, logged the same way, and the local version
  is written back. A save hidden by the active filter is announced. Item ▸
  New Item… (⌘N, also in the row context menu, empty list area, status menu,
  and via an empty-tab affordance) adds typed text to the current tab. Both
  Edit Item and New Item write to the tab's sync folder when it has one.
- **Files.** A file copied in Finder shows its file name as the entry text, the
  way CopyQ shows it (not as the icon image Finder also puts on the pasteboard),
  while paste-back still pastes the real file.
- **Search.** Case-insensitive substring search, including CJK text and file
  names and paths, scoped to the current tab or across all tabs.
- **Global hotkeys.** Option-V by default summons the window; a second
  shortcut, ⇧⌘V by default, pastes as plain text. Both are registered through
  Carbon so they need no Accessibility permission. They are configurable in
  Preferences, which reports a conflict when another app already owns a
  combination or when both shortcuts are set to the same combination.
- **Paste-back.** Activating the selected entry writes it to the clipboard, returns
  focus to the previously frontmost application, and sends a synthetic
  Command-V. The first attempt while Accessibility is missing asks macOS to show
  its own permission dialog, which is also what puts `CopyQmac` in System
  Settings ▸ Privacy & Security ▸ Accessibility; until it is granted the entry is
  left on the clipboard with a banner that explains why, instead of failing
  silently. The banner fades after a few seconds and the status bar keeps the
  permission reminder while the permission is missing; both clear automatically
  once the app recognizes the grant. The app re-reads the state at each paste
  and on activation, and a paste that actually posts its Command-V counts as
  trust for the rest of the launch, so the reminder stays retired even when
  macOS keeps reporting a re-granted build as untrusted. Because builds are
  signed ad hoc, macOS ties the grant to the exact binary, so every rebuild or
  update needs it re-established; see
  [Granting Accessibility](build.md#granting-accessibility). The banner explains
  this and offers a button that opens the pane.
- **Paste as Plain Text.** Item ▸ Paste as Plain Text and the global ⇧⌘V
  shortcut paste only text, dropping every rich flavour. While the CopyQmac
  window is open and an item is selected the shortcut uses that entry: its
  stored plain-text flavour, or HTML, RTF, or a URL reduced to text when there
  is none. Otherwise it takes the text from the live clipboard, so the
  formatting of whatever the user just copied in another app is stripped and
  pasted into that app. Both paths use the same safe paste flow as a normal
  paste, and the stored entry keeps its original flavours. An entry with no
  text keeps the menu item enabled and shows a notice instead of failing
  silently; the global shortcut likewise reports an image-only clipboard and
  brings the window forward so the explanation is visible.
- **List behaviour.** The selection always follows clicks and the arrow keys,
  including straight after editing a note, and the list scrolls the selected or
  newly captured entry into view.
- **Multi-selection and bulk actions.** Command-click toggles a row, Shift-click
  extends a contiguous range, Command-A selects every item the list shows, and a
  plain click returns to one row. Escape clears a multi-selection once the note
  editor and filter are already done; with a single row selected it keeps the
  existing hide-the-window behaviour. A selection survives a refresh that keeps
  the same entries and is cleared when the tab changes. Up/Down move the focus
  and the selection together, Shift-arrow extends, and Delete removes every
  selected entry through the recoverable trash, asking once and naming the count
  when more than one row is selected. Item ▸ Move Up / Move Down / Move to Top /
  Move to Bottom act on the whole selection and keep the selected rows in their
  relative order; each row moves within its own pin group, so an unpinned entry
  never rises above a pinned one, and with a filter active the commands are
  unavailable because the list no longer shows the tab's true order. Item ▸ Move
  to Tab, or dragging the selection onto a tab chip, moves the entries to that
  tab, and the destination tab then enforces the history limit, evicting its
  oldest items through the same trash path as a delete. A source tab with a sync
  folder rewrites its file groups into a destination that has a folder, or moves
  them to the trash when the destination has none. A tab move asks for
  confirmation only when it would rewrite or delete sync files, and the disk
  work is rolled back if the move itself fails. Copy copies the
  focused entry (the last one activated) without changing the rest of the
  selection.
- **Activation (CopyQ's History ▸ Activation).** Activating an item - a double
  click, Return, or Item ▸ Activate - always copies it to the clipboard and then
  runs the switches from Preferences ▸ History ▸ Activation in one fixed order:
  copy → paste into the previous app → focus the previous app → close the main
  window → move the item to the top of its tab. A single click activates too once
  "Single click activates" is on; while it is off (the default) a click only
  selects. Pasting focuses the previous app as part of its own step, so "Focus
  the previous app" only changes anything with pasting off. A delivery that
  does not arrive leaves the window open with the explanation: without
  Accessibility trust the item is only copied, and the status bar keeps the
  permission reminder until the grant is recognized; an app that refused to
  activate is a logged failure whose reason stays in the status bar until it
  is dismissed. With no previous app to paste into, the item is copied and the
  window shows a hint instead, which is not kept as a failure. The defaults are:
  a click selects, and activating pastes, focuses, and closes the window. See
  [Activation](architecture.md#activation) for the exact order.
- **Preferences.** The global history limit, search scope, tabs (capture
  tab and sync-folder mappings), the one Pause Sync switch, ignored apps, the
  AI-service API-key guard, the item list and editor fonts, the window layout,
  launch at login, and the summon and Paste as Plain Text shortcuts (presets or
  custom combinations, with a conflict warning). The Activation group holds the
  five switches above, each with a note on what it changes.
  Appearance is chosen in Preferences ▸ History ▸ Appearance: follow the system
  appearance or keep the app Light or Dark, which keeps the system's Increase
  Contrast setting. Both fonts are set in the Fonts section of Preferences ▸
  History. Both start as the font the surface already drew with, so nothing
  changes until one is chosen. A chosen editor font styles the whole editor:
  the plain editor draws its text in it, and in the styled editor it is the
  base font new text is typed in - the first keystroke at the opening caret and
  text typed after deleting everything are written in it, without bold or
  italic, while text typed inside an existing run keeps that run's formatting
  and a payload's own families always keep their rendering. Choosing System
  with only a size draws Helvetica Neue, the app's default writing family, at
  that size in the styled editor, because a styled item cannot carry the system
  UI font; the plain editor and the item list keep the real system font, since
  no payload is involved. The editor's family picker only offers families both
  rich-text writers record unchanged. The list font is a base font for rows
  whose text carries no font of its own, so a rich row keeps the fonts it
  stores. The launch-at-login toggle reflects the real Login Items state and
  reports a registration failure instead of showing a stale state.
- **Interface language.** Preferences ▸ History ▸ Language switches the interface
  between English and 简体中文, and the switch takes effect there and then: the
  menu bar, the status item, the in-window status bar, the preferences window,
  the dialogs and file panels the app presents, the Help dialog, the notice
  banner's failure and permission text, the main window's own content (filter
  bar, empty states, row and tab context menus, preview and note labels, hover
  help, and the text editor sheet), the in-window success notices and report
  summaries, and the item rows' relative timestamps ("just now", "5 min ago",
  "2 h ago", "Yesterday"), whose numeric values stay as they are. English
  remains the default, so nothing changes for anyone who never touches the
  picker. Clipboard capture, storage, sync, item rendering, and window layout
  behave exactly the same in both languages.
- **Ignored apps.** A capture is skipped when an app on the ignore list was
  frontmost at any point since the last clipboard check: no history row or
  sync-folder file is written, and nothing about the content is logged. A
  capture is also skipped when the window is empty, or when its newest
  observation is stale after a gap, so the frontmost app cannot be determined;
  this is the deliberate fail-safe. CopyQmac
  itself counts as an observed, non-ignored source, so content copied while its
  own window is frontmost is still recorded. The list starts enabled with
  1Password, 1Password 7, Bitwarden, Keychain Access, Passwords, KeePassXC,
  LastPass, Dashlane, and Enpass. Each rule can be switched off or removed, and
  Preferences ▸ Ignored Apps adds the last observed frontmost app. A capture
  that the source marks as concealed, transient, or auto-generated is skipped
  too. These rules apply to what this machine captures; items arriving through a
  sync folder are not filtered.
- **AI service API keys.** Leave the switch on and a capture made on this Mac
  whose plain text carries an OpenAI, Anthropic, Google, or OpenRouter
  credential is skipped before anything is stored: no history row, no
  sync-folder file, no payload in any log, and a short menu-bar notice says so.
  Copying and pasting the key keeps working. It greatly reduces what can leak to
  this machine and the other one, but it cannot promise that nothing ever does:
  detection is a fixed table of key shapes, not a general secrets scanner, and
  keys already in the history stay there. The guard covers copies made on this
  machine only; items already arriving through a sync folder are not filtered,
  so a key written by another machine can still appear here. The switch sits on
  Preferences ▸ Ignored Apps and is on by default.
- **Sync write-back.** Background write-back of newly captured entries
  and typed new items directly into mapped CopyQ sync folders, with 1 ms
  collision bumping, pause controls in menus and Preferences, and strict path
  protection. A tab with a folder always writes; there is no separate enable
  switch.
- **Sync folder watcher.** Background FSEvents directory watcher that
  automatically imports items synced from other machines (e.g. Fedora) once complete
  and settled, with per-tab folder routing that is never diverted to the capture tab,
  dates resolved as the later of the file-name stamp and the file modification time,
  durable per-folder echo-loop prevention, content deduplication, and no per-tab
  gating beyond the folder itself.
- **Two-way content edits.** Saving an edit rewrites the entry's own
  file group under its existing stem, so the other machine updates that item in
  place, and files from the old content are removed rather than left behind. A
  changed upstream group updates the local row in place when its timestamp is
  newer, and loses with a sync-log line carrying a payload summary (never the
  clipboard text) when it is older; the winning local version is written back. Notes and pins travel in the
  same group and follow the same newest-wins rule.
- **Two-way deletion sync.** Deleting an entry whose tab has a sync folder moves
  its owned file group out of the sync folder into `~/Library/Application Support/CopyQmac/trash/<timestamp>/`,
  so Syncthing propagates the deletion while the bytes stay recoverable with their
  original names. Deleting a multi-selection routes every selected entry through
  the same path in one pass. When a tracked group disappears from a watched folder and stays
  absent on a settled rescan, the matching local entry is removed and its payload
  is archived in the same trash. A local edit that could not be written to the
  folder is kept; once written back, the entry follows the normal deletion rule.
  Paused sync performs neither direction. Removing a tab unregisters the tab and
  leaves sync files untouched; it releases the stem history that tab recorded, and
  so does clearing a tab's folder when no other tab maps it, so a tab pointed at
  the same folder again imports those items instead of counting them as
  duplicates. Clear Tab confirms with a dialog before moving files to the trash.
  File ▸ "Reconcile Sync Folders…" reports entries without files and file groups
  without entries and defaults to reporting only; File ▸ "Empty Sync Trash…"
  empties the local, never-synced trash after confirmation. The tab context menu
  "Compare with Sync Folder…" compares one tab with its folder and reports
  matched content, content differences, entries with no file, file stems with no
  entry, unresolved entries, and unreadable entries and files. The report is read
  only and is the default; a separate confirmed "Apply Changes…" step imports
  folder-only stems, removes entries whose files are gone (after archiving each
  payload to the app trash), and updates content-different entries while keeping
  their notes and pins. Entries with a pending local edit, a differing note or
  pin, disagreeing owned groups, or only a legacy creation-time identity are
  reported as conflicts and never changed by resync, and a group that is still
  being written is skipped until it settles. The comparison runs off the main
  thread.
- **Writing local items back into a sync folder.** The tab context menu's
  "Write Local Items to Sync Folder…" restores a folder that was emptied by
  another program: every local item of the tab is written into its folder with
  the same files, stems, and metadata a capture writes, so the other machine
  sees the items again instead of losing them. It is the one write path that
  starts from the whole tab rather than from an event. A confirmation states,
  with counts taken from the plan, how many entries are written, how many files
  are created and rewritten, and which entries are skipped: each skipped entry
  is named with its stem, a short content preview, and its reason (only
  internal markers, no content, content that cannot be decoded into the sync
  format, a group the folder already carries, or a stem held only by the legacy
  creation-time rule whose content differs), listed for the first 12 and then
  summarised. It is write-only: no file in the folder is deleted, renamed, or
  moved, a stem that belongs to another entry is never touched, a written entry
  replaces only the files it itself produces, so an older file under its stem
  that the entry no longer produces is left exactly where it is and named in
  the plan, the confirmation, and the result, and a failure stops the run
  where it happened and keeps every file already written. Unmapped tabs and
  paused sync are refused, the write runs inside the writer's settled-writes
  barrier, and every written stem is recorded for its entry so a repeat writes
  no duplicate and the watcher never echoes the files back as new items.
- **CopyQ import.** File ▸ "Import from CopyQ…" (⌘I) reads an itemsync folder, a
  folder holding several of them, or a `.cpq` archive and merges the items into a
  matching tab or a tab named after the source. File ▸ "Import Configured Sync
  Folders" (⇧⌘I) reads the folder set for each tab; when none is set, it says so and
  offers to pick one, which becomes the selected tab's sync folder and is imported
  into that tab.
- **Backup export.** File ▸ "Export Backup…" (every tab, Command-Shift-E, also in
  the status menu) and "Export Current Tab…" write a CopyQ-compatible `.cpq` archive
  to a path chosen in a save panel. Native pasteboard flavours travel under the CopyQ
  MIME name for the same payload (`text/plain`, `text/html`, `text/rtf`, `image/png`,
  `text/uri-list`) and other types keep their own identifier, with payload bytes
  unchanged (private sync bookkeeping flavours are omitted), together with notes,
  pins, tab order and capture times. Importing the archive
  restores those entries; an entry whose content already exists in the tab is
  skipped as a duplicate, so a repeated payload keeps only its first capture. A
  capture that carried several pasteboard items (for example copying two images)
  backs up only the first item's flavours, while multi-file copies keep every
  path in `text/uri-list`; splitting such a capture into separate archive items
  is not supported. Duplicate tab names are disambiguated as "Name (2)", "Name
  (3)", … and the result reports how many were renamed. Flavours larger than
  1 KiB are compressed with `qCompress` to match CopyQ's archive size. The archive
  is written on a background queue with progress in the status bar, and a
  destination inside a configured tab sync folder or a Syncthing folder is
  reported as syncing to the other devices. See
  [`core/CopyQSync/README.md`](../core/CopyQSync/README.md) for format details.
- **Local storage** in a versioned SQLite schema, with flavours above 1 KiB
  zlib-compressed on disk and restored byte-for-byte for preview and paste-back,
  plus a headless test suite.

## Data isolation

The app stores its local history in an isolated SQLite database and does not modify
existing CopyQ data files. A capture writes a new itemsync group by staging its
files under temporary names and renaming them into place, so an existing group is
never half-overwritten; an edit rewrites only its own entry's group, and a deletion
moves the affected group out of the sync folder into the app's local,
never-synced trash instead of hard-deleting it. For the storage location and private test override,
see [`build.md`](build.md).

