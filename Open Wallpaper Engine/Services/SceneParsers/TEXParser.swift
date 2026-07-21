//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine TEXV texture container files.
//  Structure: TEXV0005 > TEXI (TexHeader) > TEXB (image container) > images > mipmaps.
//
//  Supports:
//   - Embedded image files (PNG/JPEG/...) — decoded via NSImage.
//   - Raw RGBA8888 (format 0), RG88 (8), R8 (9) — direct byte expansion.
//   - Block-compressed DXT5/BC3 (format 4), DXT3/BC2 (6), DXT1/BC1 (7) —
//     soft-decoded through the vendored `bcdec` library (see bcdec.h).
//   - Per-mipmap raw-LZ4-block compression (Apple Compression, COMPRESSION_LZ4_RAW).
//
//  Layout verified against notscuffed/repkg and Almamu/linux-wallpaperengine
//  (see sidequest tex-format-spec.md). The correct TexFormat enum is
//  0=RGBA8888, 4=DXT5(BC3), 6=DXT3(BC2), 7=DXT1(BC1), 8=RG88, 9=R8 — NOT the
//  "4=DXT1, 8=DXT5" the previous comment claimed.
//

import Cocoa
import Compression
import Foundation

struct TEXMetadata {
    let format: UInt32
    let width: UInt32
    let height: UInt32
    let textureWidth: UInt32  // power-of-2 / block-aligned padded
    let textureHeight: UInt32
}

class TEXParser {
    private let data: Data

    // TexFormat enum (see file header). Only the ones WE actually emits.
    private enum TexFormat: Int32 {
        case rgba8888 = 0
        case dxt5 = 4   // BC3
        case dxt3 = 6   // BC2
        case dxt1 = 7   // BC1
        case rg88 = 8
        case r8 = 9
    }

    init(data: Data) {
        self.data = data
    }

    /// Extract the image from this TEX container.
    /// Returns nil only if the container is malformed or an unhandled format.
    func extractImage() -> NSImage? {
        if let img = decodeStructured() {
            return img
        }
        // Structured parse failed — fall back to the old best-effort embedded
        // JPEG/PNG scan so previously-working textures never regress.
        return legacyScanForEmbeddedImage()
    }

    /// Extract raw JPEG/PNG data without creating NSImage (legacy helper).
    func extractImageData() -> Data? {
        guard let texbRange = findSection("TEXB") else { return nil }
        let texbData = data[texbRange]
        if let jpegOffset = findJPEGMagic(in: texbData) {
            return Data(texbData[jpegOffset...])
        }
        if let pngOffset = findPNGMagic(in: texbData) {
            return Data(texbData[pngOffset...])
        }
        return nil
    }

    // MARK: - Structured decode

    /// Sequential cursor-based reader over the whole .tex byte stream.
    private final class Cursor {
        let b: [UInt8]
        var i: Int = 0
        init(_ b: [UInt8]) { self.b = b }
        var remaining: Int { b.count - i }

        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            let v = UInt32(b[i]) | (UInt32(b[i+1]) << 8)
                | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
            i += 4
            return v
        }
        func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }

        /// Read a NUL-terminated ASCII string (repkg's ReadNString), consuming the NUL.
        func nstr(maxLen: Int = 16) -> String? {
            let start = i
            var end = i
            while end < b.count && b[end] != 0 && (end - start) < maxLen { end += 1 }
            guard end < b.count && b[end] == 0 else { return nil }
            let s = String(bytes: b[start..<end], encoding: .ascii)
            i = end + 1
            return s
        }

        func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, i + n <= b.count else { return nil }
            let slice = Array(b[i..<i+n])
            i += n
            return slice
        }
    }

    private func decodeStructured() -> NSImage? {
        let c = Cursor([UInt8](data))

        // TEXV0005 / TEXI0001
        guard let v = c.nstr(), v.hasPrefix("TEXV") else { return nil }
        guard let ti = c.nstr(), ti.hasPrefix("TEXI") else { return nil }

        // TexHeader: format, flags, textureW, textureH, imageW, imageH, unk
        guard let rawFormat = c.i32(),
              c.u32() != nil,                     // flags
              let textureW = c.u32(),
              let textureH = c.u32(),
              let imageW = c.u32(),
              let imageH = c.u32(),
              c.u32() != nil                       // unkInt0
        else { return nil }

        // TEXB image container
        guard let texb = c.nstr(), texb.hasPrefix("TEXB") else { return nil }
        guard let imageCount = c.i32(), imageCount > 0 else { return nil }

        var imageFormat: Int32 = -1   // FreeImageFormat; -1 == FIF_UNKNOWN == raw pixel/BC data
        var isVideoMp4 = false
        if texb >= "TEXB0003" { imageFormat = c.i32() ?? -1 }
        if texb == "TEXB0004" { isVideoMp4 = (c.i32() ?? 0) == 1 }

        // First image, first (largest) mipmap.
        guard let mipCount = c.i32(), mipCount > 0 else { return nil }

        // TEXB0004 uses the extra V4 mipmap prefix (param/param/json/param) ONLY for
        // genuine mp4 video textures; everything else follows the V2/V3 mipmap layout.
        let useV4Prefix = (texb == "TEXB0004" && isVideoMp4)

        let mip = readFirstMipmap(c, containerMagic: texb, useV4Prefix: useV4Prefix)
        guard let mip = mip else { return nil }

        // Embedded image file (PNG/JPEG/...)? repkg trusts FreeImageFormat when it's
        // not FIF_UNKNOWN; also sniff magic bytes as a backstop.
        if imageFormat != -1 || startsWithImageMagic(mip.bytes) {
            return NSImage(data: Data(mip.bytes))
        }

        guard let fmt = TexFormat(rawValue: rawFormat) else {
            NSLog("[TEXParser] Unhandled TexFormat %d (%dx%d)", rawFormat, mip.width, mip.height)
            return nil
        }

        let cropW = (imageW > 0 && imageW <= mip.width) ? Int(imageW) : Int(mip.width)
        let cropH = (imageH > 0 && imageH <= mip.height) ? Int(imageH) : Int(mip.height)
        return decodePixels(format: fmt,
                            width: Int(mip.width), height: Int(mip.height),
                            cropW: cropW, cropH: cropH,
                            bytes: mip.bytes,
                            textureW: Int(textureW), textureH: Int(textureH))
    }

    private struct Mipmap {
        let width: UInt32
        let height: UInt32
        let bytes: [UInt8]   // already LZ4-decompressed
    }

    private func readFirstMipmap(_ c: Cursor, containerMagic: String, useV4Prefix: Bool) -> Mipmap? {
        // V1 (TEXB0001): width, height, byteCount, bytes — never LZ4.
        if containerMagic == "TEXB0001" {
            guard let w = c.u32(), let h = c.u32(), let n = c.i32(),
                  let raw = c.bytes(Int(n)) else { return nil }
            return Mipmap(width: w, height: h, bytes: raw)
        }

        // V4 prefix (mp4 textures only): param1(1) param2(2) conditionJson param3(1)
        if useV4Prefix {
            guard c.i32() != nil, c.i32() != nil, c.nstr(maxLen: 4096) != nil, c.i32() != nil
            else { return nil }
        }

        // V2/V3 (and non-video V4): width, height, isLZ4, decompressedSize, onDiskSize, bytes.
        guard let w = c.u32(), let h = c.u32(),
              let isLZ4 = c.i32(),
              let decompSize = c.i32(),
              let onDisk = c.i32(),
              let raw = c.bytes(Int(onDisk))
        else { return nil }

        if isLZ4 == 1 {
            guard let out = lz4Decompress(raw, decompressedSize: Int(decompSize)) else {
                NSLog("[TEXParser] LZ4 decompress failed (%d -> %d)", raw.count, decompSize)
                return nil
            }
            return Mipmap(width: w, height: h, bytes: out)
        }
        return Mipmap(width: w, height: h, bytes: raw)
    }

    /// Raw-LZ4-block decompress via Apple's Compression framework.
    private func lz4Decompress(_ src: [UInt8], decompressedSize: Int) -> [UInt8]? {
        guard decompressedSize > 0 else { return nil }
        var dst = [UInt8](repeating: 0, count: decompressedSize)
        let written = dst.withUnsafeMutableBufferPointer { dstBuf in
            src.withUnsafeBufferPointer { srcBuf in
                compression_decode_buffer(dstBuf.baseAddress!, decompressedSize,
                                          srcBuf.baseAddress!, srcBuf.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == decompressedSize else { return nil }
        return dst
    }

    // MARK: - Pixel decode

    private func decodePixels(format: TexFormat,
                              width: Int, height: Int,
                              cropW: Int, cropH: Int,
                              bytes: [UInt8],
                              textureW: Int, textureH: Int) -> NSImage? {
        guard width > 0, height > 0 else { return nil }

        // Decode into a tightly-packed RGBA8 buffer whose row width is `bufW`.
        // For BC formats we over-allocate to the 4-aligned block grid so bcdec
        // never writes past the edge, then crop on copy.
        let rgba: [UInt8]
        let bufW: Int
        let bufH: Int

        switch format {
        case .rgba8888:
            guard bytes.count >= width * height * 4 else { return nil }
            rgba = bytes
            bufW = width; bufH = height

        case .rg88:
            guard bytes.count >= width * height * 2 else { return nil }
            var out = [UInt8](repeating: 0, count: width * height * 4)
            for p in 0..<(width * height) {
                out[p*4+0] = bytes[p*2+0]   // R
                out[p*4+1] = bytes[p*2+1]   // G
                out[p*4+2] = 0              // B
                out[p*4+3] = 255           // A
            }
            rgba = out; bufW = width; bufH = height

        case .r8:
            guard bytes.count >= width * height else { return nil }
            var out = [UInt8](repeating: 0, count: width * height * 4)
            for p in 0..<(width * height) {
                let s = bytes[p]
                out[p*4+0] = s; out[p*4+1] = s; out[p*4+2] = s; out[p*4+3] = 255
            }
            rgba = out; bufW = width; bufH = height

        case .dxt1, .dxt3, .dxt5:
            let blockW = (width + 3) / 4
            let blockH = (height + 3) / 4
            bufW = blockW * 4
            bufH = blockH * 4
            let blockSize = (format == .dxt1) ? 8 : 16
            guard bytes.count >= blockW * blockH * blockSize else {
                NSLog("[TEXParser] BC buffer short: have %d need %d", bytes.count, blockW * blockH * blockSize)
                return nil
            }
            var out = [UInt8](repeating: 0, count: bufW * bufH * 4)
            let pitch = bufW * 4
            bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let srcBase = src.baseAddress!
                    let dstBase = dst.baseAddress!
                    var blockOffset = 0
                    for by in stride(from: 0, to: bufH, by: 4) {
                        for bx in stride(from: 0, to: bufW, by: 4) {
                            let blockPtr = srcBase.advanced(by: blockOffset)
                            let dstPtr = dstBase.advanced(by: by * pitch + bx * 4)
                            switch format {
                            case .dxt1: bcdec_bc1(blockPtr, dstPtr, Int32(pitch))
                            case .dxt3: bcdec_bc2(blockPtr, dstPtr, Int32(pitch))
                            case .dxt5: bcdec_bc3(blockPtr, dstPtr, Int32(pitch))
                            default: break
                            }
                            blockOffset += blockSize
                        }
                    }
                }
            }
            rgba = out
        }

        let finalW = min(cropW, bufW)
        let finalH = min(cropH, bufH)
        return makeImage(rgba: rgba, srcRowWidth: bufW, width: finalW, height: finalH)
    }

    /// Build an NSImage from a straight (non-premultiplied) RGBA8 buffer, copying
    /// `height` rows of `width` px from a buffer whose stride is `srcRowWidth` px.
    private func makeImage(rgba: [UInt8], srcRowWidth: Int, width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: width * 4, bitsPerPixel: 32)
        else { return nil }
        guard let dst = rep.bitmapData else { return nil }
        let dstStride = width * 4
        let srcStride = srcRowWidth * 4
        rgba.withUnsafeBufferPointer { src in
            let base = src.baseAddress!
            for row in 0..<height {
                memcpy(dst.advanced(by: row * dstStride),
                       base.advanced(by: row * srcStride),
                       dstStride)
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func startsWithImageMagic(_ b: [UInt8]) -> Bool {
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xD8 { return true }               // JPEG
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true } // PNG
        return false
    }

    // MARK: - Legacy fallback (best-effort embedded JPEG/PNG scan)

    private func legacyScanForEmbeddedImage() -> NSImage? {
        if let texbRange = findSection("TEXB") {
            let texbData = data[texbRange]
            if let jpegOffset = findJPEGMagic(in: texbData) {
                if let endOffset = findJPEGEnd(in: texbData, from: jpegOffset),
                   let image = NSImage(data: Data(texbData[jpegOffset...endOffset])) {
                    return image
                }
                if let image = NSImage(data: Data(texbData[jpegOffset...])) { return image }
            }
            if let pngOffset = findPNGMagic(in: texbData),
               let image = NSImage(data: Data(texbData[pngOffset...])) {
                return image
            }
        }
        if let jpegOffset = findJPEGMagic(in: data) {
            let jpegData: Data
            if let endOffset = findJPEGEnd(in: data, from: jpegOffset) {
                jpegData = Data(data[jpegOffset...endOffset])
            } else {
                jpegData = Data(data[jpegOffset...])
            }
            if let image = NSImage(data: jpegData) { return image }
        }
        NSLog("[TEXParser] No decodable image found (%d bytes)", data.count)
        return nil
    }

    private func findSection(_ name: String) -> Range<Data.Index>? {
        guard let nameData = name.data(using: .ascii) else { return nil }
        let nameLen = nameData.count
        var i = data.startIndex
        while i + nameLen + 4 <= data.endIndex {
            if data[i..<i+nameLen] == nameData {
                let lenStart = i + nameLen
                guard lenStart + 4 <= data.endIndex else { return nil }
                let sectionLen = UInt32(data[lenStart])
                    | (UInt32(data[lenStart+1]) << 8)
                    | (UInt32(data[lenStart+2]) << 16)
                    | (UInt32(data[lenStart+3]) << 24)
                let contentStart = lenStart + 4
                let contentEnd = contentStart + Int(sectionLen)
                guard contentEnd <= data.endIndex else {
                    return contentStart..<data.endIndex
                }
                return contentStart..<contentEnd
            }
            i += 1
        }
        return nil
    }

    private func findJPEGEnd(in slice: Data, from start: Data.Index) -> Data.Index? {
        var i = start
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD9 { return i + 1 }
            i += 1
        }
        return nil
    }

    private func findJPEGMagic(in slice: Data) -> Data.Index? {
        var i = slice.startIndex
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD8 { return i }
            i += 1
        }
        return nil
    }

    private func findPNGMagic(in slice: Data) -> Data.Index? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        var i = slice.startIndex
        while i + 3 < slice.endIndex {
            if slice[i] == pngMagic[0] && slice[i+1] == pngMagic[1]
                && slice[i+2] == pngMagic[2] && slice[i+3] == pngMagic[3] {
                return i
            }
            i += 1
        }
        return nil
    }
}
