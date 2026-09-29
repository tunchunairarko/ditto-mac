import Foundation
import AppKit

/// Port of the parts of `Clip_ImportExport.cpp` that matter day to day:
/// EXPORT_TO_TEXT_FILE, EXPORT_TO_BITMAP_FILE and IMPORT_CLIP.
///
/// Windows Ditto also has its own `.dto` archive for moving a whole database
/// between machines. That is unnecessary here: the database file itself is the
/// portable format, and this port keeps it byte-compatible, so copying
/// `Ditto.db` does the same job on either platform.
enum ImportExport {

    // MARK: - Export

    static func exportClips(ids: [Int], window: NSWindow?) {
        guard ids.isEmpty == false else { return }

        if ids.count == 1 {
            exportSingle(id: ids[0], window: window)
        } else {
            exportMany(ids: ids, window: window)
        }
    }

    private static func exportSingle(id: Int, window: NSWindow?) {
        guard let clip = try? ClipRepository.shared.loadClip(id: id) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName(for: clip)
        panel.title = "Save Clip"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(clip: clip, to: url)
            } catch {
                Log.error("export failed: \(error)")
                presentError(error)
            }
        }
    }

    private static func exportMany(ids: [Int], window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = "Choose a folder for \(ids.count) clips"
        panel.prompt = "Save Here"

        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            for (index, id) in ids.enumerated() {
                guard let clip = try? ClipRepository.shared.loadClip(id: id) else { continue }
                let name = String(format: "%03d-", index + 1) + suggestedFileName(for: clip)
                do {
                    try write(clip: clip, to: directory.appendingPathComponent(name))
                } catch {
                    Log.error("could not export clip \(id): \(error)")
                }
            }
        }
    }

    private static func write(clip: Clip, to url: URL) throws {
        if let png = clip.format(ClipFormat.png) {
            try png.bytes.write(to: url)
            return
        }
        if let dib = clip.format(ClipFormat.dib),
           let image = BitmapHelper.image(fromDIB: dib.bytes),
           let png = BitmapHelper.pngData(from: image) {
            try png.write(to: url)
            return
        }
        if let rtf = clip.format(ClipFormat.richText), url.pathExtension.lowercased() == "rtf" {
            try ClipFormat.decodeRTF(rtf.bytes).write(to: url)
            return
        }
        if let html = clip.format(ClipFormat.html), url.pathExtension.lowercased() == "html" {
            try Data(ClipFormat.decodeHTML(html.bytes).utf8).write(to: url)
            return
        }
        let text = clip.text ?? clip.desc
        try Data(text.utf8).write(to: url)
    }

    private static func suggestedFileName(for clip: Clip) -> String {
        let base = SpecialPaste.slugify(String(clip.desc.prefix(40)))
        let name = base.isEmpty ? "clip-\(clip.id)" : base

        if clip.format(ClipFormat.png) != nil || clip.format(ClipFormat.dib) != nil {
            return name + ".png"
        }
        if clip.format(ClipFormat.html) != nil {
            return name + ".html"
        }
        if clip.format(ClipFormat.richText) != nil {
            return name + ".rtf"
        }
        return name + ".txt"
    }

    // MARK: - Import

    /// IMPORT_CLIP - read files from disk and turn each into a clip.
    static func importClips(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Import Clips"

        panel.begin { response in
            guard response == .OK else { return }
            var imported = 0
            for url in panel.urls {
                if importClip(from: url) { imported += 1 }
            }
            Log.write("imported \(imported) clips")
            ClipRepository.shared.notifyChanged()
        }
    }

    @discardableResult
    static func importClip(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }

        let clip = Clip()
        clip.date = Date()
        clip.lastPasteDate = Date()

        if let image = NSImage(data: data), image.isValid,
           let png = BitmapHelper.pngData(from: image) {
            clip.formats.append(ClipFormatData(ClipFormat.png, png))
            if let dib = BitmapHelper.dib(fromPNG: png) {
                clip.formats.append(ClipFormatData(ClipFormat.dib, dib))
            }
        } else if let text = String(data: data, encoding: .utf8) {
            clip.formats.append(ClipFormatData(ClipFormat.unicodeText,
                                               ClipFormat.encodeUnicodeText(text)))
            clip.formats.append(ClipFormatData(ClipFormat.text, ClipFormat.encodeText(text)))
        } else {
            // Anything else becomes a file clip pointing at what was imported.
            clip.formats.append(ClipFormatData(ClipFormat.fileDrop,
                                               ClipFormat.encodeFileDrop([url.path])))
        }

        clip.generateDescription()

        do {
            _ = try ClipRepository.shared.add(clip, checkDuplicates: false)
            return true
        } catch {
            Log.error("could not import \(url.lastPathComponent): \(error)")
            return false
        }
    }

    // MARK: - Whole database

    /// Copy the database somewhere else, for a backup or to move it to another
    /// machine. `CompactDatabase` first, so the copy is as small as it can be.
    static func backupDatabase(window: NSWindow?) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Ditto-backup.db"
        panel.title = "Back Up Database"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Maintenance.compact()
                let source = Options.shared.databaseURL
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: source, to: url)
                Log.write("backed the database up to \(url.path)")
            } catch {
                presentError(error)
            }
        }
    }

    private static func presentError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Ditto could not finish that"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
