// Row presentation and thumbnail caches: the work that must not happen inside
// a SwiftUI layout pass.
//
// The views cannot run without a window server, so these tests exercise the
// caches they delegate to, plus a source-level guard that the row view cannot
// quietly start decoding or fingerprinting again.

import Foundation
import ImageIO

#if !COPYQMAC_TESTING
#error("The test target must compile with -DCOPYQMAC_TESTING")
#endif

func registerPresentationCacheTests() {
    func textEntry(id: Int64, _ text: String, createdAt: Date = Date()) -> ClipboardEntry {
        ClipboardEntry(id: id, createdAt: createdAt, flavours: [Fixtures.text(text)])
    }

    // MARK: - Presentation cache

    TestRunner.add("presentation cache misses, then hits by entry id") {
        let cache = EntryPresentationCache(capacity: 8)
        let entry = textEntry(id: 11, "hello")
        expectNil(cache.presentation(for: entry.id))
        let presentation = EntryPresentation(entry: entry)
        cache.store(presentation, for: entry)
        expectEqual(cache.presentation(for: entry.id), presentation)
        expectNil(cache.presentation(for: 12), "another entry must not hit")
    }

    TestRunner.add("presentation cache invalidates an entry whose payload changed") {
        let cache = EntryPresentationCache(capacity: 8)
        var entry = textEntry(id: 21, "before")
        cache.store(EntryPresentation(entry: entry), for: entry)
        expectNotNil(cache.presentation(for: entry.id))

        entry.flavours = [Fixtures.text("after!")]  // same length, different bytes
        let invalidated = cache.synchronize(with: [entry])
        expectEqual(invalidated, Set([entry.id]))
        expectNil(cache.presentation(for: entry.id))
    }

    TestRunner.add("presentation cache keeps entries whose visual payload did not change") {
        let cache = EntryPresentationCache(capacity: 8)
        var entry = textEntry(id: 22, "same payload")
        cache.store(EntryPresentation(entry: entry), for: entry)
        entry.note = "a note is drawn from the entry, not the cached presentation"
        entry.pinned = true
        expect(cache.synchronize(with: [entry]).isEmpty, "note and pin changes must not drop the preview")
        expectNotNil(cache.presentation(for: entry.id))
    }

    TestRunner.add("presentation cache retains full text only while selected") {
        let cache = EntryPresentationCache(capacity: 8)
        let fullText = String(repeating: "clipboard text ", count: 200)
        let entry = textEntry(id: 25, fullText)
        cache.store(EntryPresentation(entry: entry), for: entry)
        expectEqual(cache.presentation(for: entry.id)?.searchText, fullText)

        cache.discardFullPreviewData(for: entry.id)
        expectNil(cache.presentation(for: entry.id)?.searchText)
        expect(cache.storeSelectedPreview(
            searchText: fullText,
            fileURLs: [],
            lineCount: EntryPresentation.lineCount(of: fullText, kind: .text),
            for: entry.id
        ), "selected preview text should update a cached presentation")
        expectEqual(cache.presentation(for: entry.id)?.searchText, fullText)
    }

    TestRunner.add("file presentations do not retain full search paths") {
        let entry = ClipboardEntry(id: 26, createdAt: Date(), flavours: [Fixtures.fileURL("/tmp/private/document.txt")])
        let fullPresentation = EntryPresentation(entry: entry)
        let presentation = fullPresentation.discardingFullPreviewData()
        expectEqual(presentation.fileNames, ["document.txt"])
        expectEqual(presentation.fileCount, 1)
        expectEqual(presentation.fileIconPath, "/tmp/private/document.txt")
        expect(presentation.fileURLs.isEmpty, "unselected file rows should not retain full URL lists")
        expectNil(presentation.searchText)

        let cache = EntryPresentationCache(capacity: 8)
        cache.store(presentation, for: entry)
        expect(cache.storeSelectedPreview(searchText: nil, fileURLs: fullPresentation.fileURLs, lineCount: nil, for: entry.id))
        expectEqual(cache.presentation(for: entry.id)?.fileURLs, fullPresentation.fileURLs)
    }

    TestRunner.add("presentation caches the full text's line count, not the excerpt") {
        let text = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let entry = textEntry(id: 27, text)
        let full = EntryPresentation(entry: entry)
        expectEqual(full.lineCount, 500, "the count covers the whole payload")
        expect(
            (full.primaryText ?? "").split(separator: "\n", omittingEmptySubsequences: false).count < 500,
            "the truncated excerpt would undercount"
        )

        let rowOnly = EntryPresentation(
            entry: entry,
            preview: FlavourDecoder.preview(for: entry.flavours),
            retainFullPreviewData: false
        )
        expectNil(
            rowOnly.lineCount,
            "a row that drops the full text does not scan the payload for a count"
        )

        let stripped = full.discardingFullPreviewData()
        expectNil(stripped.lineCount, "a presentation without the full text has no line count")
        expectEqual(
            full.refreshingRelativeTime(language: .simplifiedChinese).lineCount,
            500,
            "a timestamp refresh keeps the cached count"
        )

        let cache = EntryPresentationCache(capacity: 8)
        cache.store(stripped, for: entry)
        let selectedLineCount = EntryPresentation.lineCount(of: text, kind: .text)
        expectEqual(selectedLineCount, 500, "the background selected-preview read counts the full payload")
        expect(cache.storeSelectedPreview(searchText: text, fileURLs: [], lineCount: selectedLineCount, for: entry.id))
        expectEqual(cache.presentation(for: entry.id)?.lineCount, 500, "the selected preview refreshes the cached count")

        let files = EntryPresentation(entry: ClipboardEntry(
            id: 28,
            createdAt: Date(),
            flavours: [Fixtures.fileURL("/tmp/a"), Fixtures.fileURL("/tmp/b")]
        ))
        expectNil(files.lineCount, "file entries count files, not lines")
        expectEqual(files.fileCount, 2)
    }

    TestRunner.add("presentation cache invalidates a deleted entry") {
        let cache = EntryPresentationCache(capacity: 8)
        let entry = textEntry(id: 23, "delete me")
        cache.store(EntryPresentation(entry: entry), for: entry)
        cache.invalidate(entryID: entry.id)
        expectNil(cache.presentation(for: entry.id))
    }

    TestRunner.add("presentation cache refreshes relative timestamps without rebuilding previews") {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let entry = textEntry(id: 24, "timestamped", createdAt: created)
        let cache = EntryPresentationCache(capacity: 8)
        cache.store(EntryPresentation(entry: entry, now: created), for: entry)
        expectEqual(cache.presentation(for: entry.id)?.relativeTime, "just now")

        let refreshed = cache.refreshRelativeTimes(now: created.addingTimeInterval(120))
        expect(refreshed, "the timestamp should have changed")
        expectEqual(cache.presentation(for: entry.id)?.relativeTime, "2 min ago")
        expectEqual(cache.presentation(for: entry.id)?.primaryText, "timestamped")
    }

    TestRunner.add("presentation cache updates timestamps when language changes") {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let entry = textEntry(id: 25, "multilingual", createdAt: created)
        let cache = EntryPresentationCache(capacity: 8, language: .english)
        cache.store(EntryPresentation(entry: entry, now: created.addingTimeInterval(300), language: .english), for: entry)
        expectEqual(cache.presentation(for: entry.id)?.relativeTime, "5 min ago")

        let changed = cache.setLanguage(.simplifiedChinese, now: created.addingTimeInterval(300))
        expect(changed, "setLanguage should report changed")
        expectEqual(cache.language, .simplifiedChinese)
        expectEqual(cache.presentation(for: entry.id)?.relativeTime, "5 分钟前")

        // Setting same language reports false
        expect(!cache.setLanguage(.simplifiedChinese, now: created.addingTimeInterval(300)))

        // The periodic refresh (the main window's 30 s timer) re-describes the
        // age in the cache's language instead of reverting to English.
        let ticked = cache.refreshRelativeTimes(now: created.addingTimeInterval(3_600))
        expect(ticked, "the timestamp should have changed on the timer tick")
        expectEqual(cache.presentation(for: entry.id)?.relativeTime, "1 小时前")
        expectEqual(cache.presentation(for: entry.id)?.language, .simplifiedChinese)
    }

    // MARK: - Thumbnail cache

    TestRunner.add("thumbnail cache misses, then hits by entry id and size") {
        let cache = ThumbnailCache(capacity: 8)
        guard let image = ThumbnailCache.decodeThumbnail(from: Fixtures.pngData, maxPixelSize: 44) else {
            TestRunner.fail("fixture PNG did not decode")
            return
        }
        expectNil(cache.thumbnail(for: 31, maxPixelSize: 44))
        cache.store(image, for: 31, maxPixelSize: 44)
        expectNotNil(cache.thumbnail(for: 31, maxPixelSize: 44))
        expectNil(cache.thumbnail(for: 31, maxPixelSize: 88), "a different size is a separate entry")
    }

    TestRunner.add("thumbnail cache invalidates every size for a changed or deleted entry") {
        let cache = ThumbnailCache(capacity: 8)
        guard let image = ThumbnailCache.decodeThumbnail(from: Fixtures.pngData, maxPixelSize: 44) else {
            TestRunner.fail("fixture PNG did not decode")
            return
        }
        cache.store(image, for: 41, maxPixelSize: 44)
        cache.store(image, for: 41, maxPixelSize: 88)
        cache.store(image, for: 42, maxPixelSize: 44)
        cache.invalidate(entryID: 41)
        expectNil(cache.thumbnail(for: 41, maxPixelSize: 44))
        expectNil(cache.thumbnail(for: 41, maxPixelSize: 88))
        expectNotNil(cache.thumbnail(for: 42, maxPixelSize: 44), "other entries stay cached")

        cache.invalidate(entryIDs: [42])
        expectNil(cache.thumbnail(for: 42, maxPixelSize: 44), "a deleted entry is gone")
    }

    TestRunner.add("thumbnail cache evicts least recently used entries") {
        let cache = ThumbnailCache(capacity: 2)
        guard let image = ThumbnailCache.decodeThumbnail(from: Fixtures.pngData, maxPixelSize: 44) else {
            TestRunner.fail("fixture PNG did not decode")
            return
        }
        cache.store(image, for: 51, maxPixelSize: 44)
        cache.store(image, for: 52, maxPixelSize: 44)
        _ = cache.thumbnail(for: 51, maxPixelSize: 44)  // 51 becomes most recent
        cache.store(image, for: 53, maxPixelSize: 44)
        expectNil(cache.thumbnail(for: 52, maxPixelSize: 44), "52 was the oldest")
        expectNotNil(cache.thumbnail(for: 51, maxPixelSize: 44))
        expectNotNil(cache.thumbnail(for: 53, maxPixelSize: 44))
    }

    // MARK: - No work in the render path

    TestRunner.add("row rendering does not compute fingerprints") {
        FingerprintProbe.reset()
        let entry = ClipboardEntry(
            id: 61,
            createdAt: Date(),
            flavours: [
                Fixtures.text("image with a caption"),
                Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
            ]
        )
        let presentations = EntryPresentationCache(capacity: 8)
        let thumbnails = ThumbnailCache(capacity: 8)

        // What a first layout pass does: build once, then read the caches.
        let presentation = EntryPresentation(entry: entry)
        presentations.store(presentation, for: entry)
        if let data = FlavourDecoder.preview(for: entry.flavours).imageData,
           let image = ThumbnailCache.decodeThumbnail(from: data, maxPixelSize: 88)
        {
            thumbnails.store(image, for: entry.id, maxPixelSize: 88)
        }

        // What every later layout pass does.
        for _ in 0..<100 {
            _ = presentations.presentation(for: entry.id)
            _ = thumbnails.thumbnail(for: entry.id, maxPixelSize: 88)
        }
        expectEqual(FingerprintProbe.count, 0, "building or reading a row must not hash the entry")

        // Prove the probe really sees a fingerprint computation.
        _ = entry.fingerprint
        expectEqual(FingerprintProbe.count, 1)
    }

    TestRunner.add("thumbnail cache evicts by explicit byte budget") {
        guard let image = ThumbnailCache.decodeThumbnail(from: Fixtures.pngData, maxPixelSize: 44) else {
            TestRunner.fail("fixture PNG did not decode")
            return
        }
        let singleImageBytes = max(1, image.bytesPerRow * image.height)
        expect(singleImageBytes > 0)

        // Set budget to hold exactly one image
        let budget = singleImageBytes + (singleImageBytes / 2)
        let cache = ThumbnailCache(byteBudget: budget)

        cache.store(image, for: 101, maxPixelSize: 44)
        expectEqual(cache.count, 1)
        expectEqual(cache.totalBytes, singleImageBytes)
        expectNotNil(cache.thumbnail(for: 101, maxPixelSize: 44))

        // Storing a second image exceeds the budget and evicts the first
        cache.store(image, for: 102, maxPixelSize: 44)
        expectEqual(cache.count, 1)
        expectEqual(cache.totalBytes, singleImageBytes)
        expectNil(cache.thumbnail(for: 101, maxPixelSize: 44), "entry 101 must be evicted to stay within budget")
        expectNotNil(cache.thumbnail(for: 102, maxPixelSize: 44))
        expect(cache.totalBytes <= budget, "totalBytes must stay within byteBudget")
    }

    TestRunner.add("thumbnail cache byte budget respects LRU recency") {
        guard let image = ThumbnailCache.decodeThumbnail(from: Fixtures.pngData, maxPixelSize: 44) else {
            TestRunner.fail("fixture PNG did not decode")
            return
        }
        let singleImageBytes = max(1, image.bytesPerRow * image.height)
        // Budget to hold exactly two images
        let budget = singleImageBytes * 2 + (singleImageBytes / 2)
        let cache = ThumbnailCache(byteBudget: budget)

        cache.store(image, for: 201, maxPixelSize: 44)
        cache.store(image, for: 202, maxPixelSize: 44)
        expectEqual(cache.count, 2)

        // Touch 201 so it becomes more recently used than 202
        _ = cache.thumbnail(for: 201, maxPixelSize: 44)

        // Storing 203 evicts 202 (oldest)
        cache.store(image, for: 203, maxPixelSize: 44)
        expectEqual(cache.count, 2)
        expectNotNil(cache.thumbnail(for: 201, maxPixelSize: 44), "201 was refreshed and must stay")
        expectNil(cache.thumbnail(for: 202, maxPixelSize: 44), "202 was the LRU entry and must be evicted")
        expectNotNil(cache.thumbnail(for: 203, maxPixelSize: 44), "203 was just added")
        expect(cache.totalBytes <= budget)

        // Dropping cache clears everything
        cache.removeAll()
        expectEqual(cache.count, 0)
        expectEqual(cache.totalBytes, 0)
    }

    TestRunner.add("no-image-in-presentation-cache invariant") {
        let tiffData = Fixtures.largeTIFF(width: 500, height: 500)
        expect(tiffData.count > 500_000)

        let entry = ClipboardEntry(
            id: 301,
            createdAt: Date(),
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.tiff, data: tiffData),
            ]
        )

        let presentation = EntryPresentation(entry: entry)
        expectEqual(presentation.kind, .image)
        expect(presentation.primaryText?.contains("Image 500x500") == true)

        let cache = EntryPresentationCache(capacity: 10)
        cache.store(presentation, for: entry)

        let retrieved = cache.presentation(for: entry.id)
        expectNotNil(retrieved)
        expectEqual(retrieved?.kind, .image)
        expectEqual(retrieved?.primaryText, presentation.primaryText)
        // EntryPresentation has no imageData property at all, guaranteeing no full-size images in presentation cache.
    }

    TestRunner.add("decoding a row thumbnail for a large image produces an output no larger than requested size") {
        let largeData = Fixtures.largeTIFF(width: 800, height: 600)
        expect(largeData.count > 1_000_000)

        // Decode for row thumbnail (280 px bound)
        guard let rowThumbnail = ThumbnailCache.decodeThumbnail(from: largeData, maxPixelSize: 280) else {
            TestRunner.fail("failed to decode subsampled row thumbnail")
            return
        }
        expect(rowThumbnail.width <= 280, "width \(rowThumbnail.width) must be <= 280")
        expect(rowThumbnail.height <= 280, "height \(rowThumbnail.height) must be <= 280")
        expectEqual(max(rowThumbnail.width, rowThumbnail.height), 280, "longest edge must be bounded exactly at 280")
        expectEqual(rowThumbnail.width, 280)
        expectEqual(rowThumbnail.height, 210)

        // Decode with smaller bound (88 px)
        guard let smallThumbnail = ThumbnailCache.decodeThumbnail(from: largeData, maxPixelSize: 88) else {
            TestRunner.fail("failed to decode small thumbnail")
            return
        }
        expect(smallThumbnail.width <= 88)
        expect(smallThumbnail.height <= 88)
        expectEqual(max(smallThumbnail.width, smallThumbnail.height), 88)

        // Small image is not upscaled beyond its native size
        guard let nativeThumbnail = ThumbnailCache.decodeThumbnail(from: Fixtures.pngData, maxPixelSize: 1600) else {
            TestRunner.fail("failed to decode fixture PNG")
            return
        }
        expect(nativeThumbnail.width <= 1600)
        expect(nativeThumbnail.height <= 1600)
    }

    TestRunner.add("embedded thumbnail shortcut only used when reaching 0.75x requested size") {
        // 1. 4000x3000 JPEG with a 160x120 EXIF thumbnail
        // When decoding with preview size 1600, the 160x120 embedded thumbnail is < 0.75 * 1600 (1200),
        // so it must NOT be used directly; decode result longest edge must be >= 1200.
        let smallThumbJpeg = Fixtures.jpegWithEmbeddedThumbnail(width: 4000, height: 3000, thumbWidth: 160, thumbHeight: 120)
        guard let preview1 = ThumbnailCache.decodeThumbnail(from: smallThumbJpeg, maxPixelSize: 1600) else {
            TestRunner.fail("failed to decode preview for image with small embedded thumbnail")
            return
        }
        let longest1 = max(preview1.width, preview1.height)
        expect(longest1 >= 1200, "preview decode longest edge \(longest1) must be >= 1200")
        expectEqual(longest1, 1600, "preview decode longest edge must be bounded to 1600")

        // 2. 4000x3000 JPEG with a 1280x960 EXIF thumbnail (0.8x of 1600)
        // When decoding with preview size 1600, the 1280x960 thumbnail is >= 0.75 * 1600 (1200),
        // so the embedded thumbnail is allowed to be directly used without re-decoding the 4000x3000 image.
        let largeThumbJpeg = Fixtures.jpegWithEmbeddedThumbnail(width: 4000, height: 3000, thumbWidth: 1280, thumbHeight: 960)
        guard let preview2 = ThumbnailCache.decodeThumbnail(from: largeThumbJpeg, maxPixelSize: 1600) else {
            TestRunner.fail("failed to decode preview for image with 0.8x embedded thumbnail")
            return
        }
        let longest2 = max(preview2.width, preview2.height)
        expectEqual(longest2, 1280, "0.8x embedded thumbnail must be directly returned")
        expectEqual(preview2.width, 1280)
        expectEqual(preview2.height, 960)
    }
}
