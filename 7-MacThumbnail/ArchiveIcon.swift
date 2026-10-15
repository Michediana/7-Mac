//
//  ArchiveIcon.swift
//  7-MacThumbnail
//
//  A page in the colour of its format with the format's name across it, so
//  a folder of archives sorts itself by eye. Read from the file name alone:
//  nothing is opened, which keeps a folder of large archives quick to show.
//

import AppKit

struct ArchiveIcon {
    let label: String
    let color: NSColor

    init(fileName: String) {
        let kind = Kind(fileName: fileName)
        label = kind.label
        color = kind.color
    }

    func draw(in bounds: CGRect) {
        // A page, a little taller than wide, centred in whatever we are given.
        let height = bounds.height * 0.96
        let width = min(bounds.width * 0.96, height * 0.78)
        let page = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                          width: width, height: height)
        let corner = width * 0.08
        let fold = width * 0.26

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let outline = Self.pageOutline(page, corner: corner, fold: fold)

        // Body: the format's colour, a shade lighter at the top.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -width * 0.01),
                          blur: width * 0.03, color: NSColor(white: 0, alpha: 0.25).cgColor)
        context.addPath(outline)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(outline)
        context.clip()
        let top = color.blended(withFraction: 0.22, of: .white) ?? color
        let bottom = color.blended(withFraction: 0.12, of: .black) ?? color
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [top.cgColor, bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: page.midX, y: page.maxY),
                                       end: CGPoint(x: page.midX, y: page.minY), options: [])
        }

        // A zip down from the top edge, the one thing every archive shares.
        // Left off list-view sizes, where it is only noise.
        if width >= 40 { drawZip(in: context, page: page) }
        context.restoreGState()

        // The turned-down corner.
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        flap.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + corner))
        flap.addQuadCurve(to: CGPoint(x: page.maxX - fold + corner, y: page.maxY - fold),
                          control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
        flap.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        flap.closeSubpath()
        context.addPath(flap)
        context.setFillColor((color.blended(withFraction: 0.5, of: .white) ?? color).cgColor)
        context.fillPath()

        context.addPath(outline)
        context.setStrokeColor(NSColor(white: 0, alpha: 0.15).cgColor)
        context.setLineWidth(max(0.5, width / 200))
        context.strokePath()

        drawLabel(in: page)
    }

    private func drawZip(in context: CGContext, page: CGRect) {
        let width = page.width, height = page.height
        let tooth = width * 0.055
        let zipX = page.minX + width * 0.38
        var y = page.maxY - tooth * 0.6
        var left = true
        context.setFillColor(NSColor(white: 1, alpha: 0.42).cgColor)
        while y > page.maxY - height * 0.36 {
            let rect = CGRect(x: left ? zipX - tooth : zipX, y: y - tooth * 0.7,
                              width: tooth, height: tooth * 0.7)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: tooth * 0.2,
                                   cornerHeight: tooth * 0.2, transform: nil))
            context.fillPath()
            y -= tooth * 0.95
            left.toggle()
        }
        let pull = CGRect(x: zipX - tooth * 0.75, y: y - tooth * 1.9,
                          width: tooth * 1.5, height: tooth * 2.1)
        context.setFillColor(NSColor(white: 1, alpha: 0.6).cgColor)
        context.addPath(CGPath(roundedRect: pull, cornerWidth: tooth * 0.5,
                               cornerHeight: tooth * 0.5, transform: nil))
        context.fillPath()
    }

    /// The name, as large as fits across the lower half of the page.
    private func drawLabel(in page: CGRect) {
        let available = page.width * 0.8
        var size = page.width * 0.3
        var text: NSAttributedString
        repeat {
            text = NSAttributedString(string: label, attributes: [
                .font: Self.labelFont(size: size),
                .foregroundColor: NSColor.white,
                .kern: size * 0.02,
            ])
            size *= 0.92
        } while text.size().width > available && size > 3

        let measured = text.size()
        let band = CGRect(x: page.minX, y: page.minY + page.height * 0.12,
                          width: page.width, height: page.height * 0.36)
        text.draw(at: CGPoint(x: band.midX - measured.width / 2,
                              y: band.midY - measured.height / 2))
    }

    private static func labelFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    /// Rounded on three corners, cut across the top right.
    private static func pageOutline(_ page: CGRect, corner: CGFloat, fold: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: page.minX + corner, y: page.minY))
        path.addArc(tangent1End: CGPoint(x: page.maxX, y: page.minY),
                    tangent2End: CGPoint(x: page.maxX, y: page.maxY), radius: corner)
        path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        path.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY),
                    tangent2End: CGPoint(x: page.minX, y: page.minY), radius: corner)
        path.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY),
                    tangent2End: CGPoint(x: page.maxX, y: page.minY), radius: corner)
        path.closeSubpath()
        return path
    }
}

// MARK: - Formats

private struct Kind {
    let label: String
    let color: NSColor

    init(fileName: String) {
        var name = fileName.lowercased()
        // A volume stands for its set: `site.7z.001`, `site.tgz.aa`.
        let last = (name as NSString).pathExtension
        if last == "aa" || (last.count == 3 && last.allSatisfy(\.isNumber)) {
            name = (name as NSString).deletingPathExtension
        }
        let ext = (name as NSString).pathExtension
        let inner = ((name as NSString).deletingPathExtension as NSString).pathExtension

        // A compressed tar reads as both: TAR.GZ, in the compressor's colour.
        if inner == "tar", let compressor = Self.compressors[ext] {
            label = "TAR.\(compressor.short)"
            color = compressor.color
            return
        }
        if let (label, color) = Self.tarAliases[ext] ?? Self.formats[ext] {
            self.label = label
            self.color = color
            return
        }
        if let compressor = Self.compressors[ext] {
            label = compressor.name
            color = compressor.color
            return
        }
        label = ext.isEmpty ? "ARCHIVE" : ext.uppercased()
        color = Palette.slate
    }

    private struct Compressor {
        let name: String
        let short: String
        let color: NSColor
    }

    private static let compressors: [String: Compressor] = [
        "gz":   Compressor(name: "GZIP",  short: "GZ",   color: Palette.orange),
        "bz2":  Compressor(name: "BZIP2", short: "BZ2",  color: Palette.red),
        "xz":   Compressor(name: "XZ",    short: "XZ",   color: Palette.teal),
        "zst":  Compressor(name: "ZSTD",  short: "ZST",  color: Palette.cyan),
        "lzma": Compressor(name: "LZMA",  short: "LZMA", color: Palette.lime),
        "lz":   Compressor(name: "LZIP",  short: "LZ",   color: Palette.lime),
        "z":    Compressor(name: "Z",     short: "Z",    color: Palette.stone),
    ]

    private static let tarAliases: [String: (String, NSColor)] = [
        "tgz":  ("TAR.GZ",  Palette.orange),
        "tbz":  ("TAR.BZ2", Palette.red),
        "tbz2": ("TAR.BZ2", Palette.red),
        "txz":  ("TAR.XZ",  Palette.teal),
        "tzst": ("TAR.ZST", Palette.cyan),
        "taz":  ("TAR.Z",   Palette.stone),
    ]

    private static let formats: [String: (String, NSColor)] = [
        "7z":       ("7Z",   Palette.green),
        "zip":      ("ZIP",  Palette.blue),
        "zipx":     ("ZIPX", Palette.blue),
        "jar":      ("JAR",  Palette.brown),
        "war":      ("WAR",  Palette.brown),
        "apk":      ("APK",  Palette.mint),
        "ipa":      ("IPA",  Palette.indigo),
        "rar":      ("RAR",  Palette.purple),
        "cbr":      ("CBR",  Palette.pink),
        "cbz":      ("CBZ",  Palette.pink),
        "cb7":      ("CB7",  Palette.pink),
        "cbt":      ("CBT",  Palette.pink),
        "tar":      ("TAR",  Palette.amber),
        "lzh":      ("LZH",  Palette.olive),
        "lha":      ("LHA",  Palette.olive),
        "arj":      ("ARJ",  Palette.slate),
        "cab":      ("CAB",  Palette.sky),
        "msi":      ("MSI",  Palette.sky),
        "wim":      ("WIM",  Palette.navy),
        "swm":      ("SWM",  Palette.navy),
        "esd":      ("ESD",  Palette.navy),
        "cpio":     ("CPIO", Palette.stone),
        "rpm":      ("RPM",  Palette.crimson),
        "deb":      ("DEB",  Palette.magenta),
        "xar":      ("XAR",  Palette.slate),
        "iso":      ("ISO",  Palette.graphite),
        "udf":      ("UDF",  Palette.graphite),
        "squashfs": ("SQFS", Palette.steel),
        "sfs":      ("SFS",  Palette.steel),
        "chm":      ("CHM",  Palette.gold),
    ]
}

private enum Palette {
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
                green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let green    = rgb(0x2E9E5B)
    static let blue     = rgb(0x2F6FDE)
    static let brown    = rgb(0x8A5A3C)
    static let mint     = rgb(0x1FA38A)
    static let indigo   = rgb(0x5552D6)
    static let purple   = rgb(0x8E44AD)
    static let pink     = rgb(0xD6457F)
    static let amber    = rgb(0xC98A1B)
    static let orange   = rgb(0xE8722C)
    static let red      = rgb(0xD64541)
    static let teal     = rgb(0x178F9C)
    static let cyan     = rgb(0x1C9FD1)
    static let lime     = rgb(0x6DA330)
    static let stone    = rgb(0x8C7B6B)
    static let olive    = rgb(0x7D8A2E)
    static let slate    = rgb(0x5E6B7D)
    static let sky      = rgb(0x3A8FD6)
    static let navy     = rgb(0x2C4A8C)
    static let crimson  = rgb(0xB3263B)
    static let magenta  = rgb(0xB8326E)
    static let graphite = rgb(0x4A4F57)
    static let steel    = rgb(0x557A95)
    static let gold     = rgb(0xB59A1F)
}
