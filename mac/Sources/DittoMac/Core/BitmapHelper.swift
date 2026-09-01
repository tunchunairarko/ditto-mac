import Foundation
import AppKit

/// Port of the DIB half of `BitmapHelper.cpp` / `DIBAPI.H`.
///
/// Windows clipboards carry images as CF_DIB - a BMP file with its 14 byte
/// `BITMAPFILEHEADER` chopped off. macOS knows how to read a whole BMP, so
/// converting in either direction is a matter of adding or removing that
/// header, once the palette and bitfield masks have been measured.
enum BitmapHelper {

    private static let fileHeaderSize = 14

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        guard i + 1 < data.endIndex else { return 0 }
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 3 < data.endIndex else { return 0 }
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    /// How many bytes sit between the info header and the pixels.
    private static func colourTableSize(_ dib: Data) -> Int {
        let headerSize = Int(readUInt32(dib, 0))
        guard headerSize >= 12 else { return 0 }

        if headerSize == 12 {
            // BITMAPCOREHEADER: 3-byte RGBTRIPLE entries.
            let bitCount = Int(readUInt16(dib, 10))
            guard bitCount <= 8 else { return 0 }
            return (1 << bitCount) * 3
        }

        let bitCount = Int(readUInt16(dib, 14))
        let compression = Int(readUInt32(dib, 16))
        let usedColours = Int(readUInt32(dib, 32))

        var size = 0
        if bitCount <= 8 {
            let entries = usedColours > 0 ? usedColours : (1 << bitCount)
            size = entries * 4
        }
        // BI_BITFIELDS adds three DWORD masks after a 40 byte header.
        if compression == 3 && headerSize == 40 {
            size += 12
        }
        return size
    }

    /// CF_DIB bytes -> NSImage.
    static func image(fromDIB dib: Data) -> NSImage? {
        guard dib.count > 20 else { return nil }
        let headerSize = Int(readUInt32(dib, 0))
        guard headerSize >= 12, headerSize < dib.count else { return nil }

        let pixelOffset = fileHeaderSize + headerSize + colourTableSize(dib)
        let fileSize = fileHeaderSize + dib.count

        var bmp = Data()
        bmp.append(0x42)    // 'B'
        bmp.append(0x4D)    // 'M'
        appendUInt32(&bmp, UInt32(truncatingIfNeeded: fileSize))
        appendUInt16(&bmp, 0)
        appendUInt16(&bmp, 0)
        appendUInt32(&bmp, UInt32(truncatingIfNeeded: pixelOffset))
        bmp.append(dib)

        guard let rep = NSBitmapImageRep(data: bmp) else { return nil }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    /// NSImage -> CF_DIB bytes, so images copied on a Mac paste on Windows.
    static func dib(fromImage image: NSImage) -> Data? {
        guard let bmp = bmpData(from: image), bmp.count > fileHeaderSize else { return nil }
        return bmp.subdata(in: (bmp.startIndex + fileHeaderSize)..<bmp.endIndex)
    }

    static func dib(fromPNG png: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: png) else { return nil }
        guard let bmp = rep.representation(using: .bmp, properties: [:]),
              bmp.count > fileHeaderSize else { return nil }
        return bmp.subdata(in: (bmp.startIndex + fileHeaderSize)..<bmp.endIndex)
    }

    private static func bmpData(from image: NSImage) -> Data? {
        if let rep = bitmapRep(from: image) {
            return rep.representation(using: .bmp, properties: [:])
        }
        return nil
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let rep = bitmapRep(from: image) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func bitmapRep(from image: NSImage) -> NSBitmapImageRep? {
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep { return bitmap }
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Scale an image down for the quick paste list. Ditto's
    /// `GetFastThumbnailMode` does the same thing for its list rows.
    static func thumbnail(_ image: NSImage, maxSize: NSSize) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        if size.width <= maxSize.width && size.height <= maxSize.height { return image }

        let scale = min(maxSize.width / size.width, maxSize.height / size.height)
        let target = NSSize(width: max(1, floor(size.width * scale)),
                            height: max(1, floor(size.height * scale)))

        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }

    /// Stitch several images together, as Ditto's PASTE_MULTI_IMAGE_HORIZONTAL
    /// and PASTE_MULTI_IMAGE_VERTICAL actions do.
    static func combine(_ images: [NSImage], vertical: Bool) -> NSImage? {
        let usable = images.filter { $0.size.width > 0 && $0.size.height > 0 }
        guard usable.isEmpty == false else { return nil }
        if usable.count == 1 { return usable[0] }

        let totalWidth = vertical
            ? usable.map { $0.size.width }.max() ?? 0
            : usable.reduce(0) { $0 + $1.size.width }
        let totalHeight = vertical
            ? usable.reduce(0) { $0 + $1.size.height }
            : usable.map { $0.size.height }.max() ?? 0
        guard totalWidth > 0, totalHeight > 0 else { return nil }

        let canvas = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        canvas.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight).fill()

        var offset: CGFloat = 0
        for image in usable {
            let rect: NSRect
            if vertical {
                // Cocoa's origin is bottom-left; stack downwards to match the
                // order the user sees in the list.
                offset += image.size.height
                rect = NSRect(x: 0, y: totalHeight - offset,
                              width: image.size.width, height: image.size.height)
            } else {
                rect = NSRect(x: offset, y: 0,
                              width: image.size.width, height: image.size.height)
                offset += image.size.width
            }
            image.draw(in: rect,
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .sourceOver,
                       fraction: 1.0)
        }
        canvas.unlockFocus()
        return canvas
    }
}
