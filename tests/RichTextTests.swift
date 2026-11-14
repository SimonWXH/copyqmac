// Rich row and preview rendering: HTML and RTF entries draw their own fonts
// and colours instead of the plain-text excerpt.
//
// The views cannot run without a window server, so these tests exercise the
// builder and its cache directly, which is the only work a layout pass would
// otherwise trigger.

import AppKit
import Foundation
import SwiftUI

#if !COPYQMAC_TESTING
#error("The test target must compile with -DCOPYQMAC_TESTING")
#endif

func registerRichTextTests() {
    let html = """
        <html><head><meta charset="utf-8"></head><body>
        <h1 style="color:#cc0000">Red Heading</h1>
        <p>Body <b>bold</b> <i>italic</i> <span style="color:#0000ff">blue</span></p>
        </body></html>
        """

    let rtf = """
        {\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\
        \\f0\\fs36\\b Title\\b0\\par body \\i italic\\i0 }
        """

    func htmlEntry(id: Int64, type: String = PasteboardTypes.html) -> ClipboardEntry {
        ClipboardEntry(
            id: id,
            createdAt: Date(),
            flavours: [
                Fixtures.text("Red Heading\nBody bold italic blue"),
                Flavour(itemIndex: 0, type: type, data: Data(html.utf8)),
            ]
        )
    }

    func rtfEntry(id: Int64, type: String = PasteboardTypes.rtf) -> ClipboardEntry {
        ClipboardEntry(
            id: id,
            createdAt: Date(),
            flavours: [
                Flavour(itemIndex: 0, type: type, data: Data(rtf.utf8)),
            ]
        )
    }

    // MARK: - Styled output

    TestRunner.add("an HTML entry yields an attributed string with style attributes") {
        MainActor.assumeIsolated {
            RichTextParseProbe.reset()
            guard let parsed = RichTextBuilder.parse(
                from: htmlEntry(id: 701).flavours,
                appearance: .light
            ) else {
                TestRunner.fail("HTML entry did not produce rich content")
                return
            }
            expect(!parsed.presentation.preview.characters.isEmpty, "the preview must not be empty")
            expect(!parsed.presentation.row.characters.isEmpty, "the row must not be empty")
            expectEqual(RichTextParseProbe.count, 1, "one payload read produces the preview and the row")

            let richRuns = Array(parsed.presentation.preview.runs)
            expect(richRuns.count > 1, "styled text needs more than one attribute run")
            expect(richRuns.contains { $0.font != nil }, "the rich text carries fonts")
            expect(richRuns.contains { $0.foregroundColor != nil }, "the rich text carries colours")

            let plainRuns = Array(AttributedString("Red Heading\nBody bold italic blue").runs)
            expect(plainRuns.allSatisfy { $0.font == nil && $0.foregroundColor == nil })
        }
    }

    TestRunner.add("an RTF entry yields styled text too") {
        MainActor.assumeIsolated {
            guard let parsed = RichTextBuilder.parse(
                from: rtfEntry(id: 702).flavours,
                appearance: .light
            ) else {
                TestRunner.fail("RTF entry did not produce rich content")
                return
            }
            let runs = Array(parsed.presentation.preview.runs)
            expect(!parsed.presentation.preview.characters.isEmpty)
            expect(runs.contains { $0.font != nil }, "RTF fonts survive the read")
            expect(String(parsed.presentation.preview.characters).contains("Title"))
        }
    }

    TestRunner.add("MIME aliases of HTML and RTF are read as rich text") {
        MainActor.assumeIsolated {
            for type in ["text/html", "NSHTMLPboardType"] {
                let entry = htmlEntry(id: 703, type: type)
                expectNotNil(
                    RichTextBuilder.parse(from: entry.flavours, appearance: .light),
                    "\(type) should render as rich text"
                )
            }
            for type in ["text/rtf", "NSRTFPboardType"] {
                let entry = rtfEntry(id: 704, type: type)
                expectNotNil(
                    RichTextBuilder.parse(from: entry.flavours, appearance: .light),
                    "\(type) should render as rich text"
                )
            }
        }
    }

    // MARK: - Cache

    TestRunner.add("rich text is parsed once and reused across layout passes") {
        MainActor.assumeIsolated {
            RichTextParseProbe.reset()
            let cache = RichTextCache(capacity: 8)
            let entry = htmlEntry(id: 711)
            guard let first = cache.presentation(for: entry, appearance: .light) else {
                TestRunner.fail("the cache did not build the rich presentation")
                return
            }
            expectEqual(RichTextParseProbe.count, 1)

            // What every later layout pass does: a pure cache lookup.
            for _ in 0..<100 {
                expectNotNil(cache.presentation(for: entry.id))
            }
            expectEqual(RichTextParseProbe.count, 1, "a layout pass must not read the payload again")
            expectEqual(cache.count, 1)
            expectEqual(cache.presentation(for: entry.id)?.byteCount, Optional(first.byteCount))
        }
    }

    TestRunner.add("rich cache invalidates a changed or deleted entry") {
        MainActor.assumeIsolated {
            let cache = RichTextCache(capacity: 8)
            var entry = htmlEntry(id: 712)
            cache.store(RichTextBuilder.parse(from: entry.flavours, appearance: .light), for: entry)
            expectNotNil(cache.presentation(for: entry.id))

            entry.flavours = [Fixtures.text("changed")]
            let invalidated = cache.synchronize(with: [entry])
            expectEqual(invalidated, Set([entry.id]))
            expectNil(cache.presentation(for: entry.id), "a changed payload drops the parsed text")

            cache.store(
                RichTextBuilder.parse(from: htmlEntry(id: 713).flavours, appearance: .light),
                for: htmlEntry(id: 713)
            )
            cache.invalidate(entryID: 713)
            expectNil(cache.presentation(for: 713), "a deleted entry is dropped")
        }
    }

    TestRunner.add("appearance changes re-derive rich text without reading the payload again") {
        MainActor.assumeIsolated {
            RichTextParseProbe.reset()
            let cache = RichTextCache(capacity: 8)
            let entry = htmlEntry(id: 714)
            guard cache.presentation(for: entry, appearance: .light) != nil else {
                TestRunner.fail("the cache did not build the rich presentation")
                return
            }
            expectEqual(RichTextParseProbe.count, 1)

            cache.retarget(to: .dark)
            expectEqual(RichTextParseProbe.count, 1, "retargeting reuses the parsed document")
            guard let dark = cache.presentation(for: entry.id) else {
                TestRunner.fail("the dark rendition is missing")
                return
            }
            expectNotNil(dark.preview.runs.first { $0.foregroundColor != nil })

            let blackHTML = "<html><body><p style=\"color:#111111\">dark page text</p></body></html>"
            let blackEntry = ClipboardEntry(
                id: 715,
                createdAt: Date(),
                flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(blackHTML.utf8))]
            )
            guard let black = RichTextBuilder.parse(from: blackEntry.flavours, appearance: .dark),
                  let color = black.presentation.preview.runs.first(where: { $0.foregroundColor != nil })?.foregroundColor,
                  let nsColor = NSColor(color).usingColorSpace(.sRGB)
            else {
                TestRunner.fail("the dark rendition has no adapted colour")
                return
            }
            let luminance = 0.2126 * nsColor.redComponent
                + 0.7152 * nsColor.greenComponent
                + 0.0722 * nsColor.blueComponent
            expect(luminance > 0.3, "dark-mode source text must be lifted off the dark background")
        }
    }

    // MARK: - Plain path

    TestRunner.add("a plain entry keeps the existing plain-text preview") {
        MainActor.assumeIsolated {
            RichTextParseProbe.reset()
            let entry = ClipboardEntry(
                id: 721,
                createdAt: Date(),
                flavours: [Fixtures.text("just text")]
            )
            let presentation = EntryPresentation(entry: entry)
            expectEqual(presentation.kind, .text)
            expectEqual(presentation.primaryText, "just text")
            expectEqual(RichTextParseProbe.count, 0, "a plain entry must not invoke the document reader")

            let cache = RichTextCache(capacity: 8)
            expectNil(cache.presentation(for: entry, appearance: .light), "plain text has no rich rendition")
            expectNil(cache.presentation(for: entry.id))
        }
    }

    TestRunner.add("an unreadable rich payload falls back without storing a row") {
        MainActor.assumeIsolated {
            RichTextParseProbe.reset()
            let entry = ClipboardEntry(
                id: 722,
                createdAt: Date(),
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<html><body>   </body></html>".utf8)),
                ]
            )
            expectNil(RichTextBuilder.parse(from: entry.flavours, appearance: .light))
            let cache = RichTextCache(capacity: 8)
            expectNil(cache.presentation(for: entry, appearance: .light))
            expectEqual(cache.count, 0, "an empty parse must not occupy cache space")
        }
    }

    TestRunner.add("a mixed entry joins each item's rich content in item order") {
        MainActor.assumeIsolated {
            let first = Flavour(
                itemIndex: 0,
                type: PasteboardTypes.html,
                data: Data("<html><body><p>first</p></body></html>".utf8)
            )
            let second = Flavour(
                itemIndex: 1,
                type: PasteboardTypes.html,
                data: Data("<html><body><p>second</p></body></html>".utf8)
            )
            let entry = ClipboardEntry(id: 723, createdAt: Date(), flavours: [second, first])
            guard let parsed = RichTextBuilder.parse(from: entry.flavours, appearance: .light) else {
                TestRunner.fail("the mixed entry did not produce rich content")
                return
            }
            expectEqual(String(parsed.presentation.preview.characters), "first\nsecond")
        }
    }

    // MARK: - MainActor entry point, contrast, attachment, and purge

    TestRunner.add("rich text @MainActor entry point parses document and cache hit does not reparse") {
        MainActor.assumeIsolated {
            RichTextParseProbe.reset()
            let cache = RichTextCache(capacity: 8)
            let entry = htmlEntry(id: 730)
            guard let first = cache.presentation(for: entry, appearance: .light) else {
                TestRunner.fail("the cache did not build the rich presentation")
                return
            }
            expectEqual(RichTextParseProbe.count, 1, "first call invokes the parser")
            expect(!first.row.characters.isEmpty)

            let second = cache.presentation(for: entry, appearance: .light)
            expectEqual(RichTextParseProbe.count, 1, "cache hit must not reparse")
            expectEqual(first.byteCount, second?.byteCount)
        }
    }

    TestRunner.add("in light mode, explicit light text is reduced to 0.25-0.35 luminance with at least 4.5:1 contrast") {
        MainActor.assumeIsolated {
            let whiteHTML = "<html><body><p style=\"color:#ffffff\">white text</p></body></html>"
            let whiteEntry = ClipboardEntry(
                id: 731,
                createdAt: Date(),
                flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(whiteHTML.utf8))]
            )
            guard let parsed = RichTextBuilder.parse(from: whiteEntry.flavours, appearance: .light),
                  let color = parsed.presentation.preview.runs.first(where: { $0.foregroundColor != nil })?.foregroundColor,
                  let nsColor = NSColor(color).usingColorSpace(.sRGB)
            else {
                TestRunner.fail("the light rendition has no adapted color")
                return
            }
            let luminance = 0.2126 * nsColor.redComponent
                + 0.7152 * nsColor.greenComponent
                + 0.0722 * nsColor.blueComponent
            expect(luminance >= 0.25 && luminance <= 0.35, "luminance must be in 0.25-0.35, was \(luminance)")

            func wcagLuminance(_ c: NSColor) -> CGFloat {
                func linear(_ v: CGFloat) -> CGFloat {
                    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(c.redComponent)
                    + 0.7152 * linear(c.greenComponent)
                    + 0.0722 * linear(c.blueComponent)
            }
            let rowBgLuminance: CGFloat = 1.0
            let textWcag = wcagLuminance(nsColor)
            let contrast = (rowBgLuminance + 0.05) / (textWcag + 0.05)
            expect(contrast >= 4.5, "contrast ratio against row background must be at least 4.5:1, was \(contrast)")
        }
    }

    TestRunner.add("a rich document that begins with an inline attachment is not discarded") {
        MainActor.assumeIsolated {
            let htmlWithImg = "<html><body><img src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\"><h1>Heading After Image</h1></body></html>"
            let entry = ClipboardEntry(
                id: 732,
                createdAt: Date(),
                flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(htmlWithImg.utf8))]
            )
            guard let parsed = RichTextBuilder.parse(from: entry.flavours, appearance: .light) else {
                TestRunner.fail("document with leading attachment should not be discarded")
                return
            }
            let previewText = String(parsed.presentation.preview.characters)
            expect(previewText.contains("Heading After Image"), "text following attachment must be preserved")
        }
    }

    TestRunner.add("retargeting multiple entries does not trap on dictionary mutation") {
        MainActor.assumeIsolated {
            let cache = RichTextCache(capacity: 16)
            for id in 800..<810 {
                let entry = htmlEntry(id: Int64(id))
                _ = cache.presentation(for: entry, appearance: .light)
            }
            expectEqual(cache.count, 10)
            cache.retarget(to: .dark)
            expectEqual(cache.count, 10)
        }
    }

    TestRunner.add("idle purge clears failed rich text ids") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let emptyHTML = "<html><body>   </body></html>"
                guard case .inserted(let badEntry) = try history.record([
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(emptyHTML.utf8)),
                ]) else {
                    TestRunner.fail("could not record bad entry")
                    return
                }
                model.reload(capturedEntryID: badEntry.id)
                model.select(badEntry.id)
                expectNil(model.richText(for: badEntry))
                expect(model.failedRichTextIDsForTesting.contains(badEntry.id))

                model.triggerIdlePurgeForTesting()
                expect(!model.failedRichTextIDsForTesting.contains(badEntry.id), "failed ids must be cleared on idle purge")
            } catch {
                TestRunner.fail("setup threw \(error)")
            }
        }
    }
}
