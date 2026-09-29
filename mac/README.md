# Ditto for macOS

A native macOS port of [Ditto](https://github.com/sabrogden/Ditto), the Windows
clipboard manager. Everything you copy is kept; a hot key brings up the list;
pressing Return on a clip pastes it into whatever you were using.

The Windows original is MFC and Win32 through and through - a clipboard chain
viewer, `HGLOBAL` blocks keyed by `CLIPFORMAT`, `RegisterHotKey`, `SendInput`,
an owner-drawn list control. None of that exists on macOS, so the port is a
rewrite in Swift and AppKit rather than a recompile. What carried over is the
behaviour, the options, and - deliberately - the database.

## The database is the same file

`Ditto.db` here has the identical schema to the Windows one: the same `Main`,
`Data`, `Types`, `CopyBuffers` and `MainDeletes` tables, the same triggers, the
same indexes, the same `Data.strClipBoardFormat` names (`CF_UNICODETEXT`,
`Rich Text Format`, `HTML Format`, `CF_HDROP`, ...), and the same Windows byte
layouts inside the blobs - UTF-16 with a NUL terminator for text, `DROPFILES`
for files, `CF_HTML` with its offset header for HTML. Even the CRC used for
duplicate detection is the same polynomial with the same seed.

So one `Ditto.db` in a synced folder can be used from a Mac and from a PC (not
at the same moment - SQLite locking is not a substitute for a sync protocol),
and a database you already have opens here with your clips, groups, stars and
sticky ordering intact.

Two things do not transfer:

- **Per-clip shortcuts** (`Main.lShortCut`) hold a key code, and key codes are
  not the same on the two platforms. A shortcut set on Windows will not fire
  here; set it again on this side.
- **File clips** point at paths. `C:\...` means nothing on a Mac, so a file clip
  from Windows pastes as the list of path names instead of the files.

## Building

Requires Xcode's command line tools (Swift 5.7 or later) and macOS 12 or later.

    cd mac
    make            # builds build/Ditto.app for this Mac
    make universal  # builds it for arm64 and x86_64
    make run        # builds and launches it
    make install    # copies it to /Applications

There is no Xcode project: it is a Swift package, and the `Makefile` wraps
`swift build` with the few steps that turn the binary into an app bundle.

## Continuous integration

`.github/workflows/macos.yml` builds this on every push and pull request that
touches `mac/`, and can be started by hand from the Actions tab. It:

- runs the tests (see below) first, so a logic failure does not wait on a build
- builds `Ditto.app` - universal on `master`, for the runner's own architecture
  on a pull request, where quicker feedback is worth more
- checks the bundle: both architectures present, `Info.plist` valid, the
  `LSUIElement` flag set, the ad-hoc signature verifying
- starts the app and reads its log back, to confirm it gets through launch,
  opens its database and claims its hot keys
- uploads the zipped app as a build artifact, and attaches it to a GitHub
  release when one is published

The Windows workflows ignore `mac/`, so a change here never cuts a Windows
release, and a change to the Windows source never starts a macOS build.

## Tests

    cd mac
    swift test

The package is split so that this is possible: everything lives in the
`DittoKit` library and the `DittoMac` executable is two lines that hand over to
it, because a test bundle cannot link against an executable's top-level code.
The tests use `@testable import`, so nothing had to be made `public` for them.

What they cover is what can be checked without a window server, which is most of
what a port can get wrong:

- **the schema** - every table, both triggers, the indexes the list query sorts
  on, and the exact column list of `Main`, taken from `CreateDB` in
  `DatabaseUtilities.cpp`. Also that deleting a clip queues its payload rather
  than removing it, and that a database from an older Ditto gains the columns it
  is missing. This is the compatibility contract with Windows Ditto.
- **the byte layouts** - the UTF-16 NUL terminator, the `DROPFILES` header, and
  that the `CF_HTML` offsets really do bracket the fragment, counted in bytes so
  that multi-byte characters do not shift them.
- **the CRC** - against the standard CRC-32 check values, since that is what
  decides whether two copies are the same clip on either platform.
- **the search language** - `AND`/`OR`/`NOT`, quoted phrases, wildcards, `/f`
  and `/q`, and that `/f` really reaches inside a stored UTF-16 blob through the
  `ditto_like` function registered on the connection.
- **the paste transforms** and the hot key packing.
- **the auto-delete rules** - and, more to the point, their exemptions: a clip
  that is starred, stuck, in a group or carries a shortcut is never removed
  automatically.

Each test gets its own database in a temporary directory and its own options
store, so nothing touches a real `Ditto.db` or the user defaults of whoever is
running them.

## Permissions

Ditto asks for one thing macOS does not grant by default:

**Accessibility** (System Settings → Privacy & Security → Accessibility).
Pasting means pressing Command-V in another application, which is a privileged
act on macOS. Without it Ditto still works - picking a clip puts it on the
clipboard - you just press Command-V yourself.

The build signs the app ad-hoc so that the permission survives a rebuild. If you
move the app after granting it, macOS may ask again.

## Using it

Copy things as usual. Then:

| Key | Does |
| --- | --- |
| `⌃\`` or `⌘⇧V` | open the clip list |
| type anything | search as you type |
| `↑` `↓` `⇞` `⇟` | move through the list |
| `Return` | paste into the app you came from |
| `⇧Return` | paste as plain text |
| `⌘Return` | paste without moving the clip back to the top |
| `⌘1` … `⌘0` | paste the first ten clips |
| `→` / `←` | step into a group / back out |
| `⌘E` | edit the clip's text |
| `⌘D` | star the clip (starred clips are never auto-deleted) |
| `⌘T` / `⇧⌘T` | stick the clip to the top / unstick it |
| `⌘B` | stick the clip to the bottom |
| `⌘U` | move the clip to the top |
| `⌘G` | move the clip to a group |
| `⌘N` | make a new group |
| `⌘S` | show only starred clips |
| `⇧⌘C` | copy without pasting |
| `⌘I` | clip properties |
| `⌘P` | keep the window on top |
| `⌘R` | refresh |
| `Delete` | delete the selected clips |
| `Escape` | clear the search, then leave the group, then close |

Right-clicking a clip offers the same actions plus the "special paste"
transforms - upper case, lower case, sentence case, camel case, inverted case,
slugified, ASCII only, trimmed, line feeds added or removed, typoglycemia,
posixified paths, a fresh GUID.

### Searching

The search language is Ditto's:

- several words are ANDed; `OR`, `AND` and `NOT` (or `!`) change that
- `"a phrase"` keeps spaces together
- `*` is a wildcard
- `/f text` searches inside the clips rather than their descriptions
- `/q text` searches the quick paste text

Two options replace the parser entirely: one treats the whole box as a single
literal phrase, the other as a regular expression.

Full text search is more useful here than on Windows. Clip contents are stored
as UTF-16 blobs, which SQL's `LIKE` cannot see into; this port registers its own
`ditto_like` and `ditto_regexp` functions that decode the blob first.

### Groups, stars and sticky clips

Same as Windows. Groups are ordinary rows with `bIsGroup = 1`; a clip in a group
keeps a second ordering column so it can sit in one place in the main list and
another inside the group. Starred clips (`lDontAutoDelete`) and sticky clips
survive every automatic deletion, along with clips in groups and clips that have
their own shortcut.

### Copy buffers

A numbered slot: one hot key puts what you just copied into it, another pastes
it back. Set the keys on the Keyboard page. Windows Ditto binds these to
`Ctrl+Shift+1`…`5` and `Ctrl+1`…`5` by default; here they start unset, because
those combinations are already spoken for on macOS.

## What is different from Windows, and why

| Windows Ditto | Here | Why |
| --- | --- | --- |
| Clipboard chain viewer | polling `NSPasteboard.changeCount` | macOS has no clipboard-change notification. The interval is on the General page. |
| `RegisterHotKey` | Carbon `RegisterEventHotKey` | Still the only supported system-wide hot key API for a background app. |
| `SendInput` | `CGEvent` posting `⌘V` | Needs Accessibility permission; see above. |
| Tray icon | menu bar status item | Same menu, including the ten most recent clips. |
| Ignore-window list by window class | ignore list by bundle identifier, plus `org.nspasteboard.ConcealedType` | The macOS convention password managers already use. |
| CF_DIB images | PNG, with a DIB written alongside | So images copied here still paste into Windows apps from a shared database. |
| ICU for case conversion | Foundation | Same results, one less dependency. |

## What is not ported

Left out deliberately, either because the macOS platform already answers the
need or because they are large features orthogonal to a clipboard manager:

- **Network send/receive** (`Server.cpp`, `SendSocket.cpp`, friends) - sending
  clips to another machine over TCP, with its own password and friend list.
- **ChaiScript** scripting of copy and paste (`chaiscript/`, `DittoChaiScript`).
- **Add-ins** (`Addins/`, `DittoAddin.cpp`) - the COM plugin surface.
- **Encrypted databases** (`EncryptDecrypt/`, sqlitemc) - macOS FileVault covers
  the same ground for most people, and the DB stays readable by Windows Ditto.
- **The `.dto` archive format** - unnecessary when the database file itself is
  the portable format. Backing up copies `Ditto.db`.
- **QR codes, Google Translate, email-to, web search** exports.
- **Multi-language resources** - the UI is English only for now.

## Layout of the source

    Sources/DittoMac/main.swift   two lines: hand over to DittoKit
    Tests/DittoKitTests/          what CI runs
    Sources/DittoKit/
      DittoApp.swift the entry point, and the only public symbol
      Core/          the parts that mirror Ditto's own logic
        Clip.swift             CClip: formats, CRC, description
        ClipFormat.swift       the Windows format names and byte layouts
        ClipRepository.swift   every query Ditto runs on clips
        ClipboardMonitor.swift CCopyThread / CClipboardViewer
        DatabaseSchema.swift   DatabaseUtilities.cpp's CreateDB
        Maintenance.swift      RemoveOldEntries
        Options.swift          CGetSetOptions
        PasteboardBridge.swift NSPasteboard <-> the Windows layouts
        SearchQuery.swift      CFormatSQL
        SpecialPaste.swift     the paste transforms in COleClipSource
        SQLite*.swift          CppSQLite3DB, plus the search functions
      System/        the parts macOS does differently
        Accessibility.swift    (no Windows counterpart)
        FrontAppTracker.swift  CExternalWindowTracker
        HotKey*.swift          CHotKey / CHotKeys
        PasteEngine.swift      CProcessPaste + CSendKeys
      UI/            AppKit in place of MFC
        QuickPasteWindow*.swift  CQPasteWnd
        OptionsWindowController.swift  the options property sheet
        StatusItemController.swift     CSystemTray
        ClipRowCellView.swift          the owner-drawn list row

Each file names the Windows source it came from, so the two can be read side by
side.

## Licence

Ditto is released under the GNU General Public License; this port is part of the
same project and carries the same licence. See `LICENSE` at the root.
