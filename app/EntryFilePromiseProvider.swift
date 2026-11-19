// File promises for rows dragged out of the history list.
//
// A drag only carried the entry's standard pasteboard representations, and a
// pasteboard with no file on it is not something Finder can copy: it turned a
// text drag into a `.textClipping` and refused an image drag altogether. A file
// promise is the missing piece. Finder asks the source for a file name and the
// bytes, then writes a real file, so a text entry arrives as a `.txt` named
// after its first line and an image arrives in the format it was copied in.
//
// The promise rides alongside the standard representations instead of replacing
// them: the tab chips keep receiving `com.copyqmac.entry-ids`, and apps that
// accept text, HTML, RTF or image data keep accepting those types. Finder
// prefers the promise, which is what makes a drop there land as a file.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// What one dragged entry writes when a file-manager drop accepts it.
struct EntryFilePromiseSpec: Equatable {
    /// The promised UTI. AppKit requires a type that conforms to `public.data`.
    let fileType: String
    /// The proposed file name, extension included. Finder appends a suffix when
    /// the name is already taken.
    let fileName: String
    /// The exact bytes the file receives; an image keeps its stored encoding.
    let payload: Data
}

/// The UTI and file name one image format promises.
struct EntryImageFileSpec: Equatable {
    let fileType: String
    let fileName: String
}

/// Builds the promise a dragged entry can make.
///
/// The entry's kind comes from `FlavourDecoder.preview`, the same decoding that
/// decides how the row draws, so an entry shown as text promises a text file and
/// an entry shown as an image promises that image's own format. Entries that are
/// files already drag as `public.file-url` items, and entries with no text or
/// decodable image have nothing a file could hold, so both promise nothing.
enum EntryFilePromises {
    /// `public.plain-text`'s preferred extension on macOS is `txt`, and the
    /// promised bytes are UTF-8.
    static let textFileType = "public.plain-text"

    /// Stems used when the content cannot name a file itself. They stay English
    /// like the app's other technical defaults; the extension is what Finder
    /// and the receiving app key off.
    private static let textFallbackStem = "Text"
    private static let imageStem = "Image"

    /// Longest first line kept for a file stem, in characters and in UTF-8
    /// bytes. The byte cap keeps the finished name inside the file system's
    /// 255-byte limit even when every character is four bytes wide.
    private static let maxStemCharacters = 80
    private static let maxStemUTF8Bytes = 240

    /// The image formats the app stores from the pasteboard, in both spellings
    /// a flavour can carry: the MIME name the source wrote and the UTI macOS
    /// reports. The promised UTI is the canonical one, and the extension is the
    /// one that UTI's own preferred extension agrees with (in particular
    /// `public.jpeg` prefers `jpeg`, not `jpg`).
    private static let imageFormats: [String: (fileType: String, fileExtension: String)] = [
        "image/png": ("public.png", "png"),
        "public.png": ("public.png", "png"),
        "image/jpeg": ("public.jpeg", "jpeg"),
        "image/jpg": ("public.jpeg", "jpeg"),
        "public.jpeg": ("public.jpeg", "jpeg"),
        "image/tiff": ("public.tiff", "tiff"),
        "public.tiff": ("public.tiff", "tiff"),
        "image/heic": ("public.heic", "heic"),
        "public.heic": ("public.heic", "heic"),
        "image/gif": ("com.compuserve.gif", "gif"),
        "public.gif": ("com.compuserve.gif", "gif"),
        "com.compuserve.gif": ("com.compuserve.gif", "gif"),
        "image/bmp": ("com.microsoft.bmp", "bmp"),
        "com.microsoft.bmp": ("com.microsoft.bmp", "bmp"),
    ]

    /// The promise the entry's stored flavours can make, or nil when the drag
    /// has nothing to offer as a file.
    static func spec(for flavours: [Flavour]) -> EntryFilePromiseSpec? {
        let preview = FlavourDecoder.preview(for: flavours)
        switch preview.kind {
        case .image:
            guard let imageType = preview.imageType,
                  let imageData = preview.imageData,
                  let image = imageFileSpec(forImageType: imageType)
            else { return nil }
            return EntryFilePromiseSpec(
                fileType: image.fileType,
                fileName: image.fileName,
                payload: imageData
            )
        case .text, .html, .rtf:
            // Rich text is promised as its plain text, the same derivation
            // Paste as Plain Text uses, so the file holds what the row shows.
            guard let text = FlavourDecoder.plainTextRepresentation(from: flavours),
                  !text.isEmpty
            else { return nil }
            return EntryFilePromiseSpec(
                fileType: textFileType,
                fileName: fileName(forText: text),
                payload: Data(text.utf8)
            )
        case .files, .other:
            return nil
        }
    }

    /// One file promise per entry that can make one, in drag order.
    static func providers(for entries: [ClipboardEntry]) -> [NSFilePromiseProvider] {
        entries.compactMap { entry in
            guard let spec = spec(for: entry.flavours) else { return nil }
            return EntryFilePromiseProvider(
                fileType: spec.fileType,
                fileName: spec.fileName,
                payload: spec.payload
            )
        }
    }

    // MARK: File names

    /// The file name a text entry promises: its first line, cleaned into a legal
    /// stem, plus `.txt`. A first line with nothing usable left falls back to
    /// `Text.txt`.
    static func fileName(forText text: String) -> String {
        let stem = sanitizedStem(firstLine(of: text))
        return (stem.isEmpty ? textFallbackStem : stem) + ".txt"
    }

    /// Everything before the first line break. The rest of the text still reaches
    /// the file; only the name comes from the first line.
    static func firstLine(of text: String) -> String {
        guard let breakIndex = text.firstIndex(where: \.isNewline) else { return text }
        return String(text[..<breakIndex])
    }

    /// Cleans a line into a file stem the file system and Finder both accept:
    /// path separators become dashes, control characters are dropped, the text
    /// is cut to a bounded length, and surrounding spaces and dots are trimmed so
    /// the file is neither hidden nor separator-only.
    static func sanitizedStem(_ line: String) -> String {
        var stem = String(line.prefix(maxStemCharacters))
        while stem.utf8.count > maxStemUTF8Bytes, !stem.isEmpty {
            stem.removeLast()
        }
        var cleaned = String.UnicodeScalarView()
        let controls = CharacterSet.controlCharacters
        for scalar in stem.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                cleaned.append("-")
            } else if !controls.contains(scalar) {
                cleaned.append(scalar)
            }
        }
        return String(cleaned).trimmingCharacters(
            in: CharacterSet(charactersIn: ".-").union(.whitespacesAndNewlines)
        )
    }

    /// The UTI and file name an image flavour promises, keeping its own format.
    ///
    /// A format outside the stored set is promised as itself when the system
    /// knows a file extension for it, and promises nothing otherwise: promising
    /// a type the bytes are not would hand Finder a file no app can open.
    static func imageFileSpec(forImageType type: String) -> EntryImageFileSpec? {
        let lowercased = type.lowercased()
        if let known = imageFormats[lowercased] {
            return EntryImageFileSpec(
                fileType: known.fileType,
                fileName: imageStem + "." + known.fileExtension
            )
        }
        guard let utType = UTType(lowercased) ?? UTType(mimeType: lowercased),
              utType.conforms(to: .image),
              let fileExtension = utType.preferredFilenameExtension
        else { return nil }
        return EntryImageFileSpec(
            fileType: utType.identifier,
            fileName: imageStem + "." + fileExtension
        )
    }
}

// MARK: - Delivery

/// The delivery object behind one promised file.
///
/// The provider is its own delegate, so the payload lives exactly as long as the
/// promise AppKit holds for the drag: no registry to unwind when a drag is
/// cancelled, and nothing kept alive once Finder has written the file.
final class EntryFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    /// The bytes written when the destination asks for the file.
    private let payload: Data
    /// The name offered for the file; Finder appends a suffix when the name is
    /// already taken.
    private let proposedFileName: String

    /// Promised writes run off the main thread. A dropped image can be large,
    /// and the drop should never wait behind the main run loop.
    private static let deliveryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "copyqmac.file-promise-delivery"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(fileType: String, fileName: String, payload: Data) {
        self.payload = payload
        self.proposedFileName = fileName
        super.init()
        self.fileType = fileType
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        proposedFileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.deliveryQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try payload.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
