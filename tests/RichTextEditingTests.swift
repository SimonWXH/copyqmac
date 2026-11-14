// Styled editing of HTML and RTF items.
//
// An item that stores HTML or RTF is edited as rich text and written back in
// its own format, while a plain item stays plain. These tests cover the rules
// (`EntryTextEditing`, `ClipboardHistory`), the writers that produce the
// payloads, and the round trip through the same document reader the row and
// preview use. The editor and toolbar tests drive real AppKit views headlessly,
// without synthesising input.

import AppKit
import Foundation

func registerRichTextEditingTests() {
    /// A colour whose channels are exact bytes, so a save and reload returns
    /// the same value instead of a quantised one.
    func srgb(_ red: Int, _ green: Int, _ blue: Int) -> StyledTextColor {
        StyledTextColor(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    func expectSameColor(
        _ actual: StyledTextColor?,
        _ expected: StyledTextColor?,
        _ message: String
    ) {
        guard let actual, let expected else {
            expectNil(actual, "\(message): expected no colour")
            expectNil(expected, "\(message): expected a colour")
            return
        }
        // A payload records 8-bit (HTML) or thousandths-of-a-percent (RTF)
        // channels, so a component is allowed to land on the nearest byte.
        let tolerance = 1.0 / 255.0 + 0.0001
        expectEqual(actual.red, expected.red, accuracy: tolerance, "\(message): red")
        expectEqual(actual.green, expected.green, accuracy: tolerance, "\(message): green")
        expectEqual(actual.blue, expected.blue, accuracy: tolerance, "\(message): blue")
    }

    /// Compares the parts that carry meaning for the editor. Paragraph styles
    /// and other attributes the editor does not model are not part of it.
    func expectSameDocument(
        _ actual: StyledTextDocument,
        _ expected: StyledTextDocument,
        _ message: String
    ) {
        expectEqual(actual.plainText, expected.plainText, "\(message): text")
        expectEqual(actual.runs.count, expected.runs.count, "\(message): run count")
        for (index, pair) in zip(actual.runs, expected.runs).enumerated() {
            let (lhs, rhs) = pair
            expectEqual(lhs.text, rhs.text, "\(message): run \(index) text")
            expectEqual(lhs.isBold, rhs.isBold, "\(message): run \(index) bold")
            expectEqual(lhs.isItalic, rhs.isItalic, "\(message): run \(index) italic")
            expectEqual(lhs.isUnderline, rhs.isUnderline, "\(message): run \(index) underline")
            expectEqual(lhs.pointSize, rhs.pointSize, accuracy: 0.01, "\(message): run \(index) size")
            expectEqual(lhs.fontFamily, rhs.fontFamily, "\(message): run \(index) family")
            expectEqual(lhs.link, rhs.link, "\(message): run \(index) link")
            expectSameColor(lhs.color, rhs.color, "\(message): run \(index) colour")
        }
    }

    func styledEntry(
        format: RichTextFormat,
        document: StyledTextDocument,
        extraFlavours: [Flavour] = []
    ) -> ClipboardEntry {
        ClipboardEntry(
            createdAt: Date(),
            flavours: [
                Flavour(
                    itemIndex: 0,
                    type: format.canonicalType,
                    data: RichTextEncoding.data(for: document, format: format)
                ),
                Fixtures.text(document.plainText),
            ] + extraFlavours
        )
    }

    /// The document the tests edit: every one of the five attributes, two font
    /// families, CJK text, and line breaks.
    let sample = StyledTextDocument(runs: [
        StyledTextRun(
            text: "Heading 中文",
            isBold: true,
            color: srgb(217, 26, 26),
            pointSize: 24,
            fontFamily: "Helvetica Neue"
        ),
        StyledTextRun(text: "\nBody ", pointSize: 13),
        StyledTextRun(text: "bold", isBold: true, pointSize: 13),
        StyledTextRun(text: " and ", pointSize: 13),
        StyledTextRun(text: "italic", isItalic: true, pointSize: 13),
        StyledTextRun(text: " & <tag> ", pointSize: 13),
        StyledTextRun(text: "under", isUnderline: true, pointSize: 13),
        StyledTextRun(
            text: " blue",
            color: srgb(26, 51, 230),
            pointSize: 13,
            fontFamily: "Times New Roman"
        ),
        StyledTextRun(text: "\nsecond line", pointSize: 13),
    ])

    // MARK: - Flavour rewriting

    TestRunner.currentSuite = "styled flavour rewriting"

    TestRunner.add("an HTML item is rewritten as HTML and the stale RTF is dropped") {
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            Fixtures.text("old text"),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>old text</p>".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.legacyHTML, data: Data("<p>old text</p>".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data("{\\rtf1 old}".utf8)),
        ])
        expectEqual(EntryTextEditing.richFormat(for: entry), .html)

        let data = RichTextEncoding.data(for: sample, format: .html)
        let updated = try EntryTextEditing.updatedFlavours(
            for: entry,
            format: .html,
            richData: data,
            plainText: sample.plainText
        )
        // Both HTML flavours the entry already carried are rewritten, so
        // paste-back keeps the types the source app expects.
        expectEqual(updated.first { $0.type == PasteboardTypes.html }?.data, data)
        expectEqual(updated.first { $0.type == PasteboardTypes.legacyHTML }?.data, data)
        expectNil(updated.first { $0.type == PasteboardTypes.rtf }, "the stale RTF must be dropped")
        expectEqual(FlavourDecoder.storedPlainText(from: updated), sample.plainText)
        expectEqual(updated.first { $0.type == PasteboardTypes.utf8Text }?.data, Data(sample.plainText.utf8))
    }

    TestRunner.add("an RTF item is rewritten as RTF and gains no HTML") {
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data("{\\rtf1 old}".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.mimeRtf, data: Data("{\\rtf1 old}".utf8)),
        ])
        expectEqual(EntryTextEditing.richFormat(for: entry), .rtf)

        let data = RichTextEncoding.data(for: sample, format: .rtf)
        let updated = try EntryTextEditing.updatedFlavours(
            for: entry,
            format: .rtf,
            richData: data,
            plainText: sample.plainText
        )
        expectEqual(updated.first { $0.type == PasteboardTypes.rtf }?.data, data)
        expectEqual(updated.first { $0.type == PasteboardTypes.mimeRtf }?.data, data)
        expectNil(updated.first { $0.type == PasteboardTypes.html }, "an RTF item must not gain HTML")
        expectEqual(FlavourDecoder.storedPlainText(from: updated), sample.plainText)
        expectEqual(FlavourDecoder.preview(for: updated).kind, .rtf)
    }

    TestRunner.add("images, files, and the sync base-name bookkeeping flavour survive") {
        let baseName = Flavour(
            itemIndex: 0,
            type: Fingerprint.syncBaseNameFlavour,
            data: Data("copyq_custom".utf8)
        )
        let png = Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)
        let file = Fixtures.fileURL("/tmp/report.pdf")
        let unknown = Flavour(itemIndex: 0, type: "com.example.custom", data: Data([0x00, 0xFF]))
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>old</p>".utf8)),
            Fixtures.text("old"),
            baseName,
            png,
            file,
            unknown,
        ])
        let updated = try EntryTextEditing.updatedFlavours(
            for: entry,
            format: .html,
            richData: Data("<p>new</p>".utf8),
            plainText: "new"
        )
        expectEqual(updated.first { $0.type == PasteboardTypes.png }?.data, Fixtures.pngData)
        expectEqual(updated.first { $0.type == PasteboardTypes.fileURL }?.data, file.data)
        expectEqual(updated.first { $0.type == Fingerprint.syncBaseNameFlavour }?.data, baseName.data)
        expectNil(updated.first { $0.type == unknown.type }, "an unknown attachment described the old text")
    }

    TestRunner.add("a plain item is never upgraded to rich text") {
        let plain = ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text("plain entry")])
        expectNil(EntryTextEditing.richFormat(for: plain), "a plain item has no rich format")

        MainActor.assumeIsolated {
            expectNil(RichTextEditing.seed(for: plain), "a plain item has no styled seed")
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                guard case .inserted(let entry) = try history.record([Fixtures.text("plain entry")]) else {
                    TestRunner.fail("fixture entry was not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()
                expectNotNil(model.pendingTextEdit, "a plain item still opens the editor")
                expectNil(model.pendingTextEdit?.rich, "a plain item opens the plain editor")

                let failure = model.commitTextEdit(.text("still plain"))
                expectNil(failure)
                let stored = try history.store.entry(id: entry.id)
                expectNil(stored?.flavours.first { RichTextFormat.of(type: $0.type) != nil }, "no rich flavour may appear")
                expectEqual(FlavourDecoder.storedPlainText(from: stored?.flavours ?? []), "still plain")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a multi-item rich entry keeps the plain editor") {
        let twoRichItems = ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>first</p>".utf8)),
            Flavour(itemIndex: 1, type: PasteboardTypes.html, data: Data("<p>second</p>".utf8)),
        ])
        expectNil(
            EntryTextEditing.richFormat(for: twoRichItems),
            "the styled editor shows one item and would drop the other"
        )
        expectEqual(
            EntryTextEditing.seed(for: twoRichItems).text,
            "first\nsecond",
            "the plain editor shows every item"
        )

        let mixedItems = ClipboardEntry(createdAt: Date(), flavours: [
            Fixtures.text("first"),
            Flavour(itemIndex: 1, type: PasteboardTypes.html, data: Data("<p>second</p>".utf8)),
        ])
        expectNil(
            EntryTextEditing.richFormat(for: mixedItems),
            "the styled editor would overwrite the first item's text"
        )

        MainActor.assumeIsolated {
            expectNil(RichTextEditing.seed(for: twoRichItems), "a multi-item entry has no styled seed")
            expectNil(RichTextEditing.seed(for: mixedItems), "a mixed multi-item entry has no styled seed")
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let entry = try history.store.insert(twoRichItems)
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()
                expectNotNil(model.pendingTextEdit, "the multi-item entry still opens the editor")
                expectNil(model.pendingTextEdit?.rich, "the multi-item entry opens the plain editor")
                expectEqual(model.pendingTextEdit?.text, "first\nsecond", "the plain editor shows both items")

                let failure = model.commitTextEdit(.text("first\nsecond"))
                expectNil(failure)
                let stored = try history.store.entry(id: entry.id)
                expectEqual(
                    stored?.flavours,
                    entry.flavours,
                    "saving the joined text unchanged must not collapse the entry"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the styled save refuses a multi-item entry") {
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>first</p>".utf8)),
            Flavour(itemIndex: 1, type: PasteboardTypes.html, data: Data("<p>second</p>".utf8)),
        ])
        expectThrows {
            _ = try EntryTextEditing.updatedFlavours(
                for: entry,
                format: .html,
                richData: Data("<p>edited</p>".utf8),
                plainText: "edited"
            )
        }
        do {
            _ = try EntryTextEditing.updatedFlavours(
                for: entry,
                format: .html,
                richData: Data("<p>edited</p>".utf8),
                plainText: "edited"
            )
        } catch let error as EntryTextEditingError {
            expectEqual(error, .multipleItems)
        } catch {
            TestRunner.fail("unexpected error \(error)")
        }
    }

    TestRunner.add("a second save of the same document is a no-op") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let entry = try history.store.insert(styledEntry(format: .html, document: sample))

        // Saving the document the entry already holds writes nothing.
        let unchanged = try history.replaceRichText(of: entry.id, with: sample, format: .html)
        expectEqual(unchanged?.flavours ?? [], entry.flavours, "an unchanged save must not rewrite the payload")
        expectEqual(try history.store.isEntryLocallyEdited(id: entry.id), false)

        // A real edit is stored once and marked locally edited.
        let modified = StyledTextDocument(runs: sample.runs + [
            StyledTextRun(text: "\nmore", isBold: true, pointSize: 13),
        ])
        let first = try history.replaceRichText(of: entry.id, with: modified, format: .html)
        expectNotNil(first)
        expectEqual(try history.store.isEntryLocallyEdited(id: entry.id), true)
        let afterFirst = try history.store.entry(id: entry.id)

        // Saving that same edit again changes nothing, so a reopened item that
        // is saved untouched does not churn the payload or the sync file.
        let second = try history.replaceRichText(of: entry.id, with: modified, format: .html)
        expectEqual(second?.flavours ?? [], afterFirst?.flavours ?? [], "a repeated save must not rewrite the payload")
        expectEqual(
            second?.fingerprint,
            afterFirst?.fingerprint,
            "the entry version must stay put so the row cache is not invalidated"
        )
    }

    TestRunner.add("an unchanged save of a compressed payload is still a no-op") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let large = StyledTextDocument(runs: [
            StyledTextRun(
                text: String(repeating: "compressed payload ", count: 120),
                color: srgb(26, 51, 230),
                pointSize: 13
            ),
        ])
        expect(
            RichTextEncoding.data(for: large, format: .html).count > 1024,
            "the fixture has to exceed the at-rest compression threshold"
        )
        let entry = try history.store.insert(styledEntry(format: .html, document: large))
        let stored = try history.store.entry(id: entry.id)
        expect(
            stored?.flavours.contains(where: { $0.isCompressed }) == true,
            "the stored payload has to be compressed for this test"
        )

        let unchanged = try history.replaceRichText(of: entry.id, with: large, format: .html)
        expectEqual(
            unchanged?.flavours ?? [],
            entry.flavours,
            "an unchanged save must not rewrite the payload"
        )
        expectEqual(try history.store.isEntryLocallyEdited(id: entry.id), false)
    }

    TestRunner.add("an empty styled document is rejected") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let entry = try history.store.insert(styledEntry(format: .html, document: sample))
        expectThrows {
            _ = try history.replaceRichText(
                of: entry.id,
                with: StyledTextDocument(runs: [StyledTextRun(text: "  \n ")]),
                format: .html
            )
        }
        let stored = try history.store.entry(id: entry.id)
        expectEqual(stored?.fingerprint, entry.fingerprint, "a rejected save must not touch the entry")
    }

    // MARK: - Round trip

    TestRunner.currentSuite = "styled round trip"

    TestRunner.add("HTML styling survives a save and reload") {
        MainActor.assumeIsolated {
            let entry = styledEntry(format: .html, document: sample)
            guard let seed = RichTextEditing.seed(for: entry) else {
                TestRunner.fail("the stored HTML did not open in the styled editor")
                return
            }
            expectEqual(seed.format, .html)
            expectSameDocument(seed.document, sample, "HTML round trip")

            // The text the entry stores is complete: nothing truncated by the
            // preview's excerpt or trimmed as surrounding whitespace.
            expectEqual(seed.document.plainText, sample.plainText)

            // Re-encoding must reproduce the payload, or every save would
            // rewrite bytes and mark the entry locally edited.
            expectEqual(
                RichTextEncoding.data(for: seed.document, format: .html),
                RichTextEncoding.data(for: sample, format: .html)
            )
        }
    }

    TestRunner.add("RTF styling survives a save and reload") {
        MainActor.assumeIsolated {
            let entry = styledEntry(format: .rtf, document: sample)
            guard let seed = RichTextEditing.seed(for: entry) else {
                TestRunner.fail("the stored RTF did not open in the styled editor")
                return
            }
            expectEqual(seed.format, .rtf)
            expectSameDocument(seed.document, sample, "RTF round trip")
            expectEqual(
                RichTextEncoding.data(for: seed.document, format: .rtf),
                RichTextEncoding.data(for: sample, format: .rtf)
            )
        }
    }

    TestRunner.add("an RTF payload stays ASCII and round-trips for a non-ASCII font family") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "localized", pointSize: 13, fontFamily: "ヒラギノ角ゴシック"),
            ])
            let data = RichTextEncoding.data(for: document, format: .rtf)
            expect(
                data.allSatisfy { $0 < 0x80 },
                "the cp1252 RTF must not carry raw UTF-8 bytes in the font table"
            )
            guard let stored = RichTextBuilder.document(
                from: Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: data)
            ) else {
                TestRunner.fail("the written RTF did not read back")
                return
            }
            let seed = RichTextEditing.styledDocument(from: stored)
            expectEqual(
                seed.runs.first?.fontFamily,
                StyledTextDocument.defaultFontFamily,
                "an unrepresentable family falls back to the default"
            )
            expectEqual(
                RichTextEncoding.data(for: seed, format: .rtf),
                data,
                "the stored payload must re-encode to the same bytes"
            )
        }
    }

    TestRunner.add("a genuine trailing newline survives an HTML save and reload") {
        MainActor.assumeIsolated {
            for text in ["a", "a\n", "a\n\n"] {
                let document = StyledTextDocument(runs: [
                    StyledTextRun(text: text, pointSize: 13),
                ])
                let entry = styledEntry(format: .html, document: document)
                guard let seed = RichTextEditing.seed(for: entry) else {
                    TestRunner.fail("the stored HTML for \(text.debugDescription) did not open")
                    continue
                }
                expectEqual(seed.document.plainText, text, "the trailing newlines of \(text.debugDescription)")
                expectEqual(
                    RichTextEncoding.data(for: seed.document, format: .html),
                    RichTextEncoding.data(for: document, format: .html),
                    "re-encoding \(text.debugDescription) must reproduce the payload"
                )
            }
        }
    }

    TestRunner.add("an edited HTML entry keeps its link") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let linked = StyledTextDocument(runs: [
                    StyledTextRun(text: "before ", pointSize: 13),
                    StyledTextRun(text: "Example", pointSize: 13, link: "https://example.com"),
                    StyledTextRun(text: " after", pointSize: 13),
                ])
                let entry = try history.store.insert(styledEntry(format: .html, document: linked))
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()
                guard let rich = model.pendingTextEdit?.rich else {
                    TestRunner.fail("the linked HTML did not open in the styled editor")
                    return
                }
                let link = rich.document.runs.first(where: { $0.link != nil })?.link
                expectNotNil(link, "the seed keeps the hyperlink")
                guard let link else { return }

                let controller = RichTextEditingController()
                let editor = RichTextEditor.makeEditor(document: rich.document, delegate: nil, format: rich.format)
                controller.attach(editor.textView)
                expectEqual(
                    controller.document().runs.first(where: { $0.link != nil })?.link,
                    link,
                    "the live editor keeps the hyperlink"
                )

                var runs = rich.document.runs
                runs[0].text += " edited"
                let failure = model.commitStyledTextEdit(StyledTextDocument(runs: runs))
                expectNil(failure)

                let stored = try history.store.entry(id: entry.id)
                guard let flavour = stored?.flavours.first(where: { $0.type == PasteboardTypes.html }),
                      let saved = RichTextBuilder.document(from: flavour)
                else {
                    TestRunner.fail("the saved HTML did not read back")
                    return
                }
                var links: [String] = []
                saved.enumerateAttribute(
                    .link,
                    in: NSRange(location: 0, length: saved.length),
                    options: []
                ) { value, _, _ in
                    if let url = value as? URL { links.append(url.absoluteString) }
                    if let string = value as? String { links.append(string) }
                }
                expectEqual(links.first, link, "the saved payload keeps the hyperlink")
                expect(saved.string.contains("edited"), "the saved payload keeps the edit")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an edited RTF entry keeps its link") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let linked = StyledTextDocument(runs: [
                    StyledTextRun(text: "before ", pointSize: 13),
                    StyledTextRun(text: "Example", pointSize: 13, link: "https://example.com"),
                    StyledTextRun(text: " after", pointSize: 13),
                ])
                let entry = try history.store.insert(styledEntry(format: .rtf, document: linked))
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()
                guard let rich = model.pendingTextEdit?.rich else {
                    TestRunner.fail("the linked RTF did not open in the styled editor")
                    return
                }
                let link = rich.document.runs.first(where: { $0.link != nil })?.link
                expectNotNil(link, "the seed keeps the hyperlink")
                guard let link else { return }

                let controller = RichTextEditingController()
                let editor = RichTextEditor.makeEditor(document: rich.document, delegate: nil, format: rich.format)
                controller.attach(editor.textView)
                expectEqual(
                    controller.document().runs.first(where: { $0.link != nil })?.link,
                    link,
                    "the live editor keeps the hyperlink"
                )

                var runs = rich.document.runs
                runs[0].text = "edited " + runs[0].text
                let failure = model.commitStyledTextEdit(StyledTextDocument(runs: runs))
                expectNil(failure)

                let stored = try history.store.entry(id: entry.id)
                guard let flavour = stored?.flavours.first(where: { $0.type == PasteboardTypes.rtf }),
                      let saved = RichTextBuilder.document(from: flavour)
                else {
                    TestRunner.fail("the saved RTF did not read back")
                    return
                }
                var links: [String] = []
                saved.enumerateAttribute(
                    .link,
                    in: NSRange(location: 0, length: saved.length),
                    options: []
                ) { value, _, _ in
                    if let url = value as? URL { links.append(url.absoluteString) }
                    if let string = value as? String { links.append(string) }
                }
                expectEqual(links.first, link, "the saved payload keeps the hyperlink")
                expect(saved.string.contains("edited"), "the saved payload keeps the edit")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a payload with formatting the editor cannot keep opens the plain editor with a notice") {
        MainActor.assumeIsolated {
            let payloads: [(name: String, html: String, text: String)] = [
                (
                    "centred paragraph",
                    "<html><body><p style=\"text-align:center\">centred</p></body></html>",
                    "centred"
                ),
                (
                    "background colour",
                    "<html><body><div><span style=\"background-color:yellow\">marked</span></div></body></html>",
                    "marked"
                ),
                (
                    "list",
                    "<html><body><ul><li>one</li></ul></body></html>",
                    "one"
                ),
                (
                    "strikethrough",
                    "<html><body><div><s>struck</s></div></body></html>",
                    "struck"
                ),
                (
                    "right-to-left paragraph",
                    "<html><body><div dir=\"rtl\" style=\"white-space: pre-wrap\">Version 2: שלום</div></body></html>",
                    "Version 2: שלום"
                ),
            ]
            for payload in payloads {
                do {
                    let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                    let model = AppModel(history: history)
                    model.bootstrap()
                    let entry = try history.store.insert(ClipboardEntry(createdAt: Date(), flavours: [
                        Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(payload.html.utf8)),
                        Fixtures.text(payload.text),
                    ]))
                    model.reload()
                    model.select(entry.id)
                    model.requestEditSelectedEntry()

                    expectNotNil(model.pendingTextEdit, "\(payload.name) is still editable as plain text")
                    expectNil(model.pendingTextEdit?.rich, "\(payload.name) must keep the plain editor")
                    expectEqual(
                        model.pendingTextEdit?.detail,
                        PendingTextEdit.Detail.formattingFallback,
                        "\(payload.name) must say that saving drops its formatting"
                    )
                } catch {
                    TestRunner.fail("threw \(error)")
                }
            }
        }
    }

    TestRunner.add("an RTF paragraph alignment keeps the plain editor") {
        MainActor.assumeIsolated {
            do {
                let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\pard\qc centred\par}"#
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let entry = try history.store.insert(ClipboardEntry(createdAt: Date(), flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(rtf.utf8)),
                    Fixtures.text("centred"),
                ]))
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()

                expectNotNil(model.pendingTextEdit, "the aligned RTF is still editable as plain text")
                expectNil(model.pendingTextEdit?.rich, "the aligned RTF must keep the plain editor")
                expectEqual(
                    model.pendingTextEdit?.detail,
                    PendingTextEdit.Detail.formattingFallback,
                    "the panel must say that saving drops the alignment"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an HTML item keeps a non-ASCII family in the styled editor") {
        MainActor.assumeIsolated {
            let family = "ヒラギノ角ゴシック"
            expectEqual(
                RichTextEncoding.writtenFamily(family, format: .html),
                family,
                "HTML keeps the family name"
            )
            expect(
                RichTextEncoding.writtenFamily(family, format: .rtf) != family,
                "RTF cannot record a non-ASCII family name"
            )
            let entry = styledEntry(format: .html, document: StyledTextDocument(runs: [
                StyledTextRun(text: "localized", pointSize: 13, fontFamily: family),
            ]))
            expectNotNil(
                RichTextEditing.seed(for: entry),
                "the HTML item has to stay style-editable"
            )
        }
    }

    TestRunner.add("a right-to-left paragraph keeps the plain editor") {
        MainActor.assumeIsolated {
            // The editor writes no direction, so an RTL paragraph would be
            // flattened on save; it takes the same refusal path as alignment.
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = .rightToLeft
            let font = NSFont(name: StyledTextDocument.defaultFontFamily, size: 13)
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if let font { attributes[.font] = font }
            expect(
                !RichTextEditing.isRepresentable(
                    NSAttributedString(string: "שלום עולם", attributes: attributes),
                    format: .html
                ),
                "an RTL paragraph must not reach the styled editor"
            )
            style.baseWritingDirection = .leftToRight
            attributes[.paragraphStyle] = style
            expect(
                RichTextEditing.isRepresentable(
                    NSAttributedString(string: "hello", attributes: attributes),
                    format: .html
                ),
                "a left-to-right paragraph is representable"
            )

            // The same decision through a real payload and the sheet.
            let entry = ClipboardEntry(createdAt: Date(), flavours: [
                Flavour(
                    itemIndex: 0,
                    type: PasteboardTypes.html,
                    data: Data("<html><body><div dir=\"rtl\" style=\"white-space: pre-wrap\">שלום עולם</div></body></html>".utf8)
                ),
                Fixtures.text("שלום עולם"),
            ])
            expectEqual(EntryTextEditing.richFormat(for: entry), .html, "the payload is HTML")
            expectNil(RichTextEditing.seed(for: entry), "an RTL payload has to keep the plain editor")
        }
    }

    TestRunner.add("the family rule admits recorded names and refuses rewritten ones") {
        MainActor.assumeIsolated {
            // This is the only family rule left: the item's own writer has to
            // record the name unchanged. It fails if the rule is removed,
            // because RTF then claims to record a non-ASCII name it cannot.
            let nonASCII = "ヒラギノ角ゴシック"
            expect(
                !RichTextEditing.isRepresentable(family: nonASCII, format: .rtf),
                "RTF can only record printable ASCII family names"
            )
            expect(
                RichTextEditing.isRepresentable(family: nonASCII, format: .html),
                "HTML records the family name unchanged"
            )
            expect(
                RichTextEditing.isRepresentable(family: "Menlo", format: .rtf),
                "a monospaced ASCII family survives RTF"
            )
            expect(
                RichTextEditing.isRepresentable(family: "Helvetica", format: .html),
                "an ordinary family survives HTML"
            )
        }
    }

    TestRunner.add("an RTF family the writer cannot record keeps the plain editor") {
        MainActor.assumeIsolated {
            guard let family = NSFontManager.shared.availableFontFamilies.first(where: {
                !$0.unicodeScalars.allSatisfy(\.isASCII)
            }), let font = NSFont(
                descriptor: NSFontDescriptor(fontAttributes: [.family: family]),
                size: 13
            ) else {
                // The rule itself is covered by "the family rule admits recorded
                // names and refuses rewritten ones"; this end-to-end case needs
                // a font only some systems install.
                print("SKIP: no installed font has a non-ASCII family name")
                return
            }
            let styled = NSAttributedString(string: "localized", attributes: [.font: font])
            guard let rtf = try? styled.data(
                from: NSRange(location: 0, length: styled.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ), let readBack = RichTextBuilder.document(
                from: Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: rtf)
            ) else {
                TestRunner.fail("the RTF fixture did not read back")
                return
            }
            var readFamily: String?
            readBack.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: readBack.length),
                options: []
            ) { value, _, _ in
                readFamily = (value as? NSFont)?.familyName
            }
            guard readFamily == family else {
                print("SKIP: the RTF round trip did not keep the non-ASCII family")
                return
            }

            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let entry = try history.store.insert(ClipboardEntry(createdAt: Date(), flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: rtf),
                    Fixtures.text("localized"),
                ]))
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()

                expectNotNil(model.pendingTextEdit, "the item is still editable as plain text")
                expectNil(
                    model.pendingTextEdit?.rich,
                    "\(family) must keep the plain editor instead of being renamed on save"
                )
                expectEqual(
                    model.pendingTextEdit?.detail,
                    PendingTextEdit.Detail.formattingFallback,
                    "the panel must say that saving drops the formatting"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a natural paragraph stays natural through a save and reload") {
        MainActor.assumeIsolated {
            do {
                let text = "שלום עולם"
                let document = StyledTextDocument(runs: [StyledTextRun(text: text, pointSize: 13)])
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let entry = try history.store.insert(styledEntry(format: .html, document: document))
                let historyModel = AppModel(history: history)
                historyModel.bootstrap()
                historyModel.reload()
                historyModel.select(entry.id)
                historyModel.requestEditSelectedEntry()
                guard let rich = historyModel.pendingTextEdit?.rich else {
                    TestRunner.fail("the natural HTML did not open in the styled editor")
                    return
                }
                var runs = rich.document.runs
                runs[0].text += "!"
                let failure = historyModel.commitStyledTextEdit(StyledTextDocument(runs: runs))
                expectNil(failure)

                let stored = try history.store.entry(id: entry.id)
                guard let flavour = stored?.flavours.first(where: { $0.type == PasteboardTypes.html }),
                      let saved = RichTextBuilder.document(from: flavour)
                else {
                    TestRunner.fail("the saved HTML did not read back")
                    return
                }
                let style = saved.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                expectEqual(style?.alignment, .natural, "a natural paragraph must stay natural")
                expect(saved.string.contains(text + "!"), "the saved payload keeps the edit")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the HTML writer keeps an empty paragraph without adding a blank line") {
        MainActor.assumeIsolated {
            let text = "first\n\nsecond"
            let document = StyledTextDocument(runs: [StyledTextRun(text: text, pointSize: 13)])
            let entry = styledEntry(format: .html, document: document)
            guard let seed = RichTextEditing.seed(for: entry) else {
                TestRunner.fail("the HTML with an empty paragraph did not open")
                return
            }
            expectEqual(seed.document.plainText, text, "the empty paragraph must not add a blank line")
            expectEqual(
                RichTextEncoding.data(for: seed.document, format: .html),
                RichTextEncoding.data(for: document, format: .html),
                "re-encoding must not add a paragraph break"
            )
        }
    }

    TestRunner.add("the published payload draws the styling in the list and preview") {
        MainActor.assumeIsolated {
            let entry = styledEntry(format: .html, document: sample)
            RichTextParseProbe.reset()
            guard let parsed = RichTextBuilder.parse(from: entry.flavours, appearance: .light) else {
                TestRunner.fail("the saved HTML does not render")
                return
            }
            let runs = Array(parsed.presentation.preview.runs)
            expect(runs.contains { $0.font != nil }, "the saved HTML carries fonts")
            expect(runs.contains { $0.foregroundColor != nil }, "the saved HTML carries colours")
            expect(
                String(parsed.presentation.preview.characters).contains("Heading 中文"),
                "the saved HTML keeps its text"
            )
        }
    }

    TestRunner.add("an HTML payload with an inline image keeps the plain editor") {
        MainActor.assumeIsolated {
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
            let html = "<html><body><p>captioned</p><img src=\"data:image/png;base64,\(png)\"></body></html>"
            let entry = ClipboardEntry(createdAt: Date(), flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8)),
            ])
            expectNotNil(EntryTextEditing.richFormat(for: entry), "the payload is still HTML")
            expectNil(
                RichTextEditing.seed(for: entry),
                "an inline image cannot be styled, and saving would drop it"
            )
        }
    }

    // MARK: - Styled editor

    TestRunner.currentSuite = "styled editor"

    TestRunner.add("the toolbar applies the five attributes to the selection") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [StyledTextRun(text: "plain text", pointSize: 13)])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: 0, length: 5))

            controller.toggle(.bold)
            controller.toggle(.italic)
            controller.toggle(.underline)
            controller.apply(color: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1))
            controller.apply(pointSize: 18)

            let edited = controller.document()
            expectEqual(edited.plainText, "plain text", "styling must not change the text")
            expectEqual(edited.runs.count, 2, "only the selected half is styled")
            guard edited.runs.count == 2 else { return }
            let styled = edited.runs[0]
            expectEqual(styled.text, "plain")
            expect(styled.isBold, "bold was not applied")
            expect(styled.isItalic, "italic was not applied")
            expect(styled.isUnderline, "underline was not applied")
            expectEqual(styled.pointSize, 18, accuracy: 0.01)
            expectNotNil(styled.color)
            expectSameColor(
                styled.color,
                StyledTextColor(red: 0.9, green: 0.1, blue: 0.2),
                "colour"
            )
            let untouched = edited.runs[1]
            expectEqual(untouched.text, " text")
            expect(!untouched.isBold && !untouched.isItalic && !untouched.isUnderline)
            expectEqual(untouched.pointSize, 13, accuracy: 0.01)
            expectNil(untouched.color, "the unselected half keeps the default colour")
        }
    }

    TestRunner.add("attaching the styled editor refreshes the toolbar after the view update") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "bold", isBold: true, pointSize: 24),
            ])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            expectEqual(controller.hasText, false, "attach must not publish during the view update")

            let deadline = Date().addingTimeInterval(2)
            while !controller.hasText, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            expectEqual(controller.hasText, true, "the deferred refresh fills the toolbar")
            expectEqual(controller.isBold, true, "the toolbar shows the seeded bold run")
            expectEqual(controller.pointSize, 24, accuracy: 0.01, "the toolbar shows the seeded size")
        }
    }

    TestRunner.add("a stored colour is drawn legibly but saved unchanged") {
        MainActor.assumeIsolated {
            do {
                let stored = StyledTextColor(red: 0x21 / 255, green: 0x25 / 255, blue: 0x29 / 255)
                let document = StyledTextDocument(runs: [
                    StyledTextRun(text: "dark", color: stored, pointSize: 13),
                ])
                let drawn = RichTextEditing.attributedText(from: document, appearance: .dark)
                guard let display = drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                      let source = drawn.attribute(.storedRichTextColor, at: 0, effectiveRange: nil) as? NSColor,
                      let displaySRGB = display.usingColorSpace(.sRGB),
                      let sourceSRGB = source.usingColorSpace(.sRGB)
                else {
                    TestRunner.fail("the drawn run has no stored and display colours")
                    return
                }
                let luminance = 0.2126 * Double(displaySRGB.redComponent)
                    + 0.7152 * Double(displaySRGB.greenComponent)
                    + 0.0722 * Double(displaySRGB.blueComponent)
                expect(luminance > 0.35, "a dark stored colour has to be lifted for the dark surface")
                expectEqual(Double(sourceSRGB.redComponent), stored.red, accuracy: 0.001)
                expectEqual(Double(sourceSRGB.greenComponent), stored.green, accuracy: 0.001)
                expectEqual(Double(sourceSRGB.blueComponent), stored.blue, accuracy: 0.001)
                expectSameColor(
                    RichTextEditing.styledDocument(from: drawn, useStoredColors: true).runs.first?.color,
                    stored,
                    "reading the drawn text back must return the stored colour"
                )

                let entry = styledEntry(format: .html, document: document)
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let inserted = try history.store.insert(entry)
                var runs = RichTextEditing.styledDocument(from: drawn, useStoredColors: true).runs
                runs[0].text += "er"
                _ = try history.replaceRichText(of: inserted.id, with: StyledTextDocument(runs: runs), format: .html)
                let saved = try history.store.entry(id: inserted.id)
                guard let flavour = saved?.flavours.first(where: { $0.type == PasteboardTypes.html }),
                      let savedDocument = RichTextBuilder.document(from: flavour)
                else {
                    TestRunner.fail("the saved HTML did not read back")
                    return
                }
                expectSameColor(
                    RichTextEditing.styledDocument(from: savedDocument).runs.first?.color,
                    stored,
                    "saving must keep the payload's own colour"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the styled editor refuses a pasted image") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [StyledTextRun(text: "text", pointSize: 13)])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(Fixtures.pngData, forType: .png)
            defer { pasteboard.clearContents() }
            expect(
                (pasteboard.types ?? []).contains { NSImage.imageTypes.contains($0.rawValue) },
                "the pasteboard has to carry an image for this test"
            )

            editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
            editor.textView.paste(nil)

            expectEqual(editor.textView.string, "text", "the image must not be inserted")
            let attributed = editor.textView.attributedString()
            expectNil(
                attributed.attribute(.attachment, at: 0, effectiveRange: nil),
                "the editor must not hold an attachment"
            )
        }
    }

    TestRunner.add("a paste that also carries a picture inserts its text") {
        MainActor.assumeIsolated {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(Fixtures.pngData, forType: .png)
            pasteboard.setString(" from picture", forType: .string)
            defer { pasteboard.clearContents() }

            let document = StyledTextDocument(runs: [StyledTextRun(text: "text", pointSize: 13)])
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
            editor.textView.paste(nil)

            expectEqual(
                editor.textView.string,
                "text from picture",
                "the text representation is inserted even though a picture is advertised"
            )
            expectNil(
                editor.textView.attributedString().attribute(.attachment, at: 0, effectiveRange: nil),
                "the picture itself is not inserted"
            )
        }
    }

    TestRunner.add("a pasted file reference lands as its path") {
        MainActor.assumeIsolated {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/pasted file.txt") as NSURL])
            defer { pasteboard.clearContents() }

            let document = StyledTextDocument(runs: [StyledTextRun(text: "open: ", pointSize: 13)])
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
            editor.textView.paste(nil)

            expect(
                editor.textView.string.contains("/tmp/pasted file.txt"),
                "a file reference must still paste its path"
            )
        }
    }

    TestRunner.add("a paste with a picture and unsaveable rich text is refused") {
        MainActor.assumeIsolated {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(Fixtures.pngData, forType: .png)
            let html = "<div><span style=\"background-color:yellow\">marked</span></div>"
            pasteboard.setData(Data(html.utf8), forType: .html)
            defer { pasteboard.clearContents() }

            let document = StyledTextDocument(runs: [StyledTextRun(text: "text", pointSize: 13)])
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
            editor.textView.paste(nil)

            expectEqual(editor.textView.string, "text", "rich text the save cannot keep is refused")
        }
    }

            TestRunner.add("the styled editor reports unsupported content as unsaveable") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [StyledTextRun(text: "text", pointSize: 13)])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            expect(controller.isRepresentable(for: .html), "the seeded editor is representable")

            editor.textView.textStorage?.addAttribute(
                .backgroundColor,
                value: NSColor.yellow,
                range: NSRange(location: 0, length: 4)
            )
            expect(!controller.isRepresentable(for: .html), "a background colour cannot be saved")
        }
    }

        TestRunner.add("a payload whose declared font is not installed stays style-editable") {
        MainActor.assumeIsolated {
            // CopyQ does not validate fonts: the item opens in the editor, the
            // platform substitutes a missing family when it renders, and saving
            // writes the editor's own document. Refusing the item would hide a
            // large class of ordinary HTML/RTF behind the plain editor.
            let missing = "CopyQmacMissingFamily"
            let span = "<span style=\"font-family:'\(missing)';font-size:13px\">hello</span>"
            let cases: [(name: String, format: RichTextFormat, flavours: [Flavour])] = [
                (
                    "HTML with an uninstalled family",
                    .html,
                    [
                        Flavour(
                            itemIndex: 0,
                            type: PasteboardTypes.html,
                            data: Data("<html><body><div style=\"white-space: pre-wrap\">\(span)</div></body></html>".utf8)
                        ),
                        Fixtures.text("hello"),
                    ]
                ),
                (
                    "HTML declaring two families where one is installed",
                    .html,
                    [
                        Flavour(
                            itemIndex: 0,
                            type: PasteboardTypes.html,
                            data: Data("""
                                <html><body><div style="white-space: pre-wrap">\
                                <span style="font-family:'Helvetica Neue';font-size:13px">hello </span>\
                                <span style="font-family:'\(missing)';font-size:13px">world</span>\
                                </div></body></html>
                                """.utf8)
                        ),
                        Fixtures.text("hello world"),
                    ]
                ),
                (
                    "RTF with an uninstalled family",
                    .rtf,
                    [
                        Flavour(
                            itemIndex: 0,
                            type: PasteboardTypes.rtf,
                            data: Data("{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fnil\\fcharset0 \(missing);}}\\pard{\\f0\\fs26 hello}}".utf8)
                        ),
                        Fixtures.text("hello"),
                    ]
                ),
            ]

            for testCase in cases {
                let entry = ClipboardEntry(
                    createdAt: Date(),
                    tabID: 1,
                    flavours: testCase.flavours
                )
                guard let seed = RichTextEditing.seed(for: entry) else {
                    TestRunner.fail("\(testCase.name) has to stay style-editable")
                    continue
                }
                expect(
                    !seed.document.hasNoText,
                    "\(testCase.name): the editor has text"
                )
                expectEqual(seed.format, testCase.format, "\(testCase.name): the entry keeps its format")

                // Saving is not refused either; the payload becomes what the
                // editor showed after the platform's substitution.
                let saved = try? EntryTextEditing.updatedFlavours(
                    for: entry,
                    format: testCase.format,
                    richData: RichTextEncoding.data(for: seed.document, format: testCase.format),
                    plainText: seed.document.plainText
                )
                expectNotNil(saved, "\(testCase.name): the save has to succeed")
                expectEqual(
                    saved.flatMap { FlavourDecoder.storedPlainText(from: $0) },
                    seed.document.plainText,
                    "\(testCase.name): the plain-text companion follows the editor"
                )
            }
        }
    }

    TestRunner.add("a monospaced payload stays style-editable") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "let x = 1", pointSize: 13, fontFamily: "Menlo"),
            ])
            guard let seed = RichTextEditing.seed(for: styledEntry(format: .html, document: document)) else {
                TestRunner.fail("a monospaced HTML item has to open the styled editor")
                return
            }
            expectEqual(seed.document.runs.first?.fontFamily, "Menlo", "the seed keeps the family")
            expectEqual(
                RichTextEncoding.data(for: seed.document, format: .html),
                RichTextEncoding.data(for: document, format: .html),
                "a monospaced family round-trips through HTML"
            )
            guard let rtfSeed = RichTextEditing.seed(for: styledEntry(format: .rtf, document: document)) else {
                TestRunner.fail("a monospaced RTF item has to open the styled editor")
                return
            }
            expectEqual(rtfSeed.document.runs.first?.fontFamily, "Menlo", "RTF keeps a printable family")

            guard let font = NSFont(name: "Menlo", size: 13) else {
                TestRunner.fail("the system has no Menlo for this test")
                return
            }
            expect(
                RichTextEditing.isRepresentable(
                    NSAttributedString(string: "code", attributes: [.font: font]),
                    format: .html
                ),
                "monospaced text can be pasted"
            )
        }
    }

                TestRunner.add("copying and pasting inside the editor keeps the stored colour") {
        MainActor.assumeIsolated {
            let previous = NSApplication.shared.appearance
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            defer {
                NSApplication.shared.appearance = previous
                NSPasteboard.general.clearContents()
            }

            let stored = StyledTextColor(red: 0.1, green: 0.2, blue: 0.3)
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "dark", color: stored, pointSize: 13),
            ])
            let drawn = RichTextEditing.attributedText(from: document)
            guard let display = drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                  let displaySRGB = display.usingColorSpace(.sRGB)
            else {
                TestRunner.fail("the drawn run has no colour")
                return
            }
            let luminance = 0.2126 * Double(displaySRGB.redComponent)
                + 0.7152 * Double(displaySRGB.greenComponent)
                + 0.0722 * Double(displaySRGB.blueComponent)
            expect(luminance > 0.35, "the test needs the dark-appearance adjustment")

            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            let textView = editor.textView
            textView.setSelectedRange(NSRange(location: 0, length: 4))
            textView.copy(nil)
            textView.setSelectedRange(NSRange(location: 4, length: 0))
            textView.paste(nil)

            let edited = controller.document()
            expectEqual(edited.plainText, "darkdark", "the paste inserts the copied text")
            expect(!edited.runs.isEmpty, "the pasted text has a run")
            for (index, run) in edited.runs.enumerated() {
                expectSameColor(run.color, stored, "run \(index) keeps the payload colour")
            }
        }
    }

    TestRunner.add("a style command at the caret styles the next keystroke") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [StyledTextRun(text: "abc", pointSize: 13)])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            let textView = editor.textView
            textView.setSelectedRange(NSRange(location: 3, length: 0))

            controller.toggle(.bold)
            expect(controller.isBold, "the toolbar has to show the pending bold")
            textView.insertText("d", replacementRange: textView.selectedRange())

            let edited = controller.document()
            expectEqual(edited.plainText, "abcd")
            guard let last = edited.runs.last else {
                TestRunner.fail("the typed text has no run")
                return
            }
            expectEqual(last.text, "d")
            expect(last.isBold, "the typed character has to carry the pending bold")
        }
    }

    TestRunner.add("the first keystroke after opening an item takes the style at the caret") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "Heading\n", isBold: true, pointSize: 24),
                StyledTextRun(
                    text: "Body plain",
                    color: StyledTextColor(red: 0.8, green: 0.1, blue: 0.1),
                    pointSize: 13
                ),
            ])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            let textView = editor.textView
            expectEqual(
                textView.selectedRange(),
                NSRange(location: document.plainText.utf16.count, length: 0),
                "the caret opens at the end of the document"
            )

            controller.refresh()
            expect(!controller.isBold, "the toolbar shows the style at the caret, not the first run")
            expectEqual(controller.pointSize, 13, accuracy: 0.01, "the toolbar shows the size at the caret")
            guard let shown = controller.color.usingColorSpace(.sRGB) else {
                TestRunner.fail("the toolbar shows no colour")
                return
            }
            expectEqual(Double(shown.redComponent), 0.8, accuracy: 0.01, "the toolbar shows the colour at the caret")
            expectEqual(Double(shown.greenComponent), 0.1, accuracy: 0.01, "the toolbar shows the colour at the caret")
            expectEqual(Double(shown.blueComponent), 0.1, accuracy: 0.01, "the toolbar shows the colour at the caret")

            textView.insertText("x", replacementRange: textView.selectedRange())
            let edited = controller.document()
            expectEqual(edited.plainText, "Heading\nBody plainx")
            guard let last = edited.runs.last else {
                TestRunner.fail("the typed text has no run")
                return
            }
            expectEqual(last.text, "Body plainx", "the typed character joins the run at the caret")
            expect(!last.isBold, "the typed character takes the style at the caret")
            expectEqual(last.pointSize, 13, accuracy: 0.01, "the typed character takes the size at the caret")
            expectSameColor(
                last.color,
                StyledTextColor(red: 0.8, green: 0.1, blue: 0.1),
                "the typed character takes the colour at the caret"
            )
        }
    }

    TestRunner.add("an untouched editor preference keeps the text view's typing inheritance") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "georgia", pointSize: 24, fontFamily: "Georgia"),
            ])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            let textView = editor.textView

            textView.insertText("x", replacementRange: textView.selectedRange())
            guard let typed = controller.document().runs.last else {
                TestRunner.fail("the typed text has no run")
                return
            }
            expectEqual(typed.fontFamily, "Georgia", "an untouched setting keeps the run before the caret")
            expectEqual(typed.pointSize, 24, accuracy: 0.01)

            textView.setSelectedRange(
                NSRange(location: 0, length: (textView.string as NSString).length)
            )
            textView.deleteBackward(nil)
            expectEqual(textView.string, "", "select all and delete empties the item")
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.insertText("y", replacementRange: textView.selectedRange())
            guard let restarted = controller.document().runs.first else {
                TestRunner.fail("the text typed after emptying the item has no run")
                return
            }
            expectEqual(
                restarted.fontFamily,
                "Georgia",
                "an untouched setting keeps the attributes of the deleted run"
            )
            expectEqual(restarted.pointSize, 24, accuracy: 0.01)
        }
    }

    TestRunner.add("the first keystroke at the opening caret is typed in the editor font") {
        MainActor.assumeIsolated {
            let chosen = NSFont(name: "Menlo", size: 20) ?? NSFont.systemFont(ofSize: 20)
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "Heading\n", isBold: true, pointSize: 24),
                StyledTextRun(
                    text: "Body plain",
                    color: StyledTextColor(red: 0.8, green: 0.1, blue: 0.1),
                    pointSize: 13
                ),
            ])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(
                document: document,
                delegate: nil,
                format: .html,
                font: chosen
            )
            controller.attach(editor.textView)
            let textView = editor.textView
            expectEqual(
                textView.selectedRange(),
                NSRange(location: document.plainText.utf16.count, length: 0),
                "the caret opens at the end of the document"
            )

            controller.refresh()
            expect(!controller.isBold, "the toolbar shows the base font, not the run before the caret")
            expect(!controller.isItalic)
            expectEqual(controller.pointSize, 20, accuracy: 0.01, "the toolbar shows the base font's size")
            expect(controller.color.type == .catalog, "the toolbar shows the system text colour")

            textView.insertText("x", replacementRange: textView.selectedRange())
            let edited = controller.document()
            expectEqual(edited.plainText, "Heading\nBody plainx")
            guard let last = edited.runs.last else {
                TestRunner.fail("the typed text has no run")
                return
            }
            expectEqual(last.text, "x", "the typed character is its own run")
            expectEqual(last.fontFamily, chosen.familyName, "the typed character is drawn in the editor font")
            expectEqual(last.pointSize, 20, accuracy: 0.01, "the typed character takes the editor font's size")
            expect(!last.isBold, "the typed character is not bold")
            expect(!last.isItalic, "the typed character is not italic")
            expectNil(last.color, "the typed character takes the system text colour")

            guard let body = edited.runs.first(where: { $0.text.contains("Body plain") }) else {
                TestRunner.fail("the payload's own run disappeared")
                return
            }
            expectEqual(body.pointSize, 13, accuracy: 0.01, "the existing run keeps its own size")
            expectSameColor(
                body.color,
                StyledTextColor(red: 0.8, green: 0.1, blue: 0.1),
                "the existing run keeps its own colour"
            )
        }
    }

    TestRunner.add("a seeded item types new text in the editor font") {
        MainActor.assumeIsolated {
            let chosen = NSFont(name: "Menlo", size: 20) ?? NSFont.systemFont(ofSize: 20)
            let html = """
                <html><body><div style="white-space: pre-wrap"><b style="font-family:'Georgia';font-size:24px">georgia</b></div></body></html>
                """
            let entry = ClipboardEntry(createdAt: Date(), flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8)),
                Fixtures.text("georgia"),
            ])
            guard let seed = RichTextEditing.seed(for: entry) else {
                TestRunner.fail("the payload did not open in the styled editor")
                return
            }
            let controller = RichTextEditingController()
            let coordinator = RichTextEditor.Coordinator(controller: controller)
            let editor = RichTextEditor.makeEditor(
                document: seed.document,
                delegate: coordinator,
                format: seed.format,
                font: chosen
            )
            controller.attach(editor.textView)
            let textView = editor.textView
            expectEqual(
                textView.selectedRange(),
                NSRange(location: seed.document.plainText.utf16.count, length: 0),
                "the caret opens at the end of the seeded payload"
            )

            textView.insertText("x", replacementRange: textView.selectedRange())
            let edited = controller.document()
            guard let existing = edited.runs.first, let typed = edited.runs.last else {
                TestRunner.fail("the edited document lost a run")
                return
            }
            expectEqual(existing.fontFamily, "Georgia", "the payload's own run keeps its family")
            expectEqual(existing.pointSize, 24, "the payload's own run keeps its size")
            expectEqual(typed.text, "x")
            expectEqual(typed.fontFamily, chosen.familyName, "the new text is typed in the editor font")
            expectEqual(typed.pointSize, 20, "the new text takes the editor font's size")
            expect(!typed.isBold)
            expect(!typed.isItalic)

            textView.setSelectedRange(
                NSRange(location: 0, length: (textView.string as NSString).length)
            )
            textView.deleteBackward(nil)
            expectEqual(textView.string, "", "select all and delete empties the item")
            expect(!controller.isBold, "the toolbar drops the deleted run's bold")
            expect(!controller.isItalic, "the toolbar drops the deleted run's italic")
            expectEqual(
                controller.pointSize,
                20,
                accuracy: 0.01,
                "the toolbar shows the editor font's size, not the deleted run's"
            )
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.insertText("y", replacementRange: textView.selectedRange())
            guard let restarted = controller.document().runs.first else {
                TestRunner.fail("the text typed after emptying the item has no run")
                return
            }
            expectEqual(restarted.text, "y")
            expectEqual(
                restarted.fontFamily,
                chosen.familyName,
                "text typed after emptying the item returns to the editor font"
            )
            expectEqual(restarted.pointSize, 20)
            expect(!restarted.isBold)
            expect(!restarted.isItalic)
        }
    }

    TestRunner.add("typing at the end of a link does not extend the link") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "plain ", pointSize: 13),
                StyledTextRun(text: "Example", pointSize: 13, link: "https://example.com"),
            ])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            let textView = editor.textView

            textView.insertText("x", replacementRange: textView.selectedRange())
            let edited = controller.document()
            guard let last = edited.runs.last else {
                TestRunner.fail("the typed text has no run")
                return
            }
            expectEqual(last.text, "x")
            expectNil(last.link, "the typed character is not part of the link")
        }
    }

    TestRunner.add("default colour removes the explicit colour again") {
        MainActor.assumeIsolated {
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "coloured", color: StyledTextColor(red: 0.8, green: 0.1, blue: 0.1)),
            ])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: 0, length: 8))
            controller.applyDefaultColor()
            expectNil(controller.document().runs.first?.color, "the colour has to be gone")
            expect(controller.color.type == .catalog, "the toolbar falls back to the system colour")
        }
    }

    TestRunner.add("the toolbar reflects the attributes at the selection") {
        MainActor.assumeIsolated {
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: sample, delegate: nil, format: .html)
            controller.attach(editor.textView)
            let textView = editor.textView

            textView.setSelectedRange(NSRange(location: 0, length: 4))
            controller.refresh()
            expect(controller.isBold, "the heading is bold")
            expectEqual(controller.pointSize, 24, accuracy: 0.01)
            expectNotNil(controller.color)

            let body = (sample.plainText as NSString).range(of: "italic")
            textView.setSelectedRange(body)
            controller.refresh()
            expect(!controller.isBold, "the body text is not bold")
            expectEqual(controller.pointSize, 13, accuracy: 0.01)
            expect(controller.color.type == .catalog, "the body text has the default colour")

            // A collapsed caret reports the style of the next typed character.
            textView.setSelectedRange(NSRange(location: body.location, length: 0))
            controller.refresh()
            expect(!controller.isBold)
            expectEqual(controller.pointSize, 13, accuracy: 0.01)
        }
    }

    TestRunner.add("the standard shortcuts map to bold, italic, and underline") {
        MainActor.assumeIsolated {
            func event(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: 0
                )
            }
            guard let bold = event("b", .command),
                  let italic = event("i", .command),
                  let underline = event("u", .command),
                  let plain = event("b", []),
                  let shifted = event("b", [.command, .shift])
            else {
                TestRunner.fail("could not build the key events")
                return
            }
            expectEqual(StyledTextView.formatCommand(for: bold), .bold)
            expectEqual(StyledTextView.formatCommand(for: italic), .italic)
            expectEqual(StyledTextView.formatCommand(for: underline), .underline)
            expectNil(StyledTextView.formatCommand(for: plain), "a plain keystroke is not a format command")
            expectNil(StyledTextView.formatCommand(for: shifted), "shift-command is a different command")

            let document = StyledTextDocument(runs: [StyledTextRun(text: "shortcut", pointSize: 13)])
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
            controller.attach(editor.textView)
            editor.textView.formatHandler = { controller.toggle($0) }
            editor.textView.setSelectedRange(NSRange(location: 0, length: 8))

            expect(editor.textView.performKeyEquivalent(with: bold), "the shortcut has to be handled")
            expect(controller.document().runs.first?.isBold == true, "command-B has to bold the selection")
        }
    }

    TestRunner.add("a styled edit rewrites the item's sync group in its own format") {
        func makeTempDirectory() throws -> URL {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-styled-sync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        do {
            let folder = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "Styled", syncFolder: folder.path))
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("old text"),
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>old text</p>".utf8)),
                ]
            ))
            let capture = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
            let stem = try unwrap(capture?.stem, "the capture was written")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                ["\(stem).html", "\(stem).txt"],
                "the captured group has the text and HTML files"
            )

            let edited = StyledTextDocument(runs: [
                StyledTextRun(text: "edited", isBold: true, pointSize: 13),
            ])
            let history = ClipboardHistory(store: store)
            _ = try history.replaceRichText(of: entry.id, with: edited, format: .html)

            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                ["\(stem).html", "\(stem).txt"],
                "the edit rewrites the entry's own group instead of adding one"
            )
            let contents = try CopyQSyncFolder.read(atPath: folder.path)
            expectEqual(contents.items.count, 1, "the folder holds exactly one group")
            expectEqual(contents.items.first?.baseName, stem)
            expectEqual(contents.items.first?.text, "edited", "the text file carries the edited text")
            expect(
                contents.items.first?.html?.contains("<b>edited</b>") == true,
                "the HTML file carries the edited styling"
            )
            let updated = try unwrap(try store.entry(id: entry.id), "the edited row")
            expectEqual(
                CopyQSyncDeletion.syncBaseName(of: updated, in: store, folder: folder.path),
                stem,
                "the entry still owns the rewritten stem"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    // MARK: - Editor sheet

    TestRunner.currentSuite = "styled editor sheet"

    TestRunner.add("an HTML item opens the styled editor and saves its own format") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let entry = try history.store.insert(styledEntry(format: .html, document: sample))
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()

                guard let request = model.pendingTextEdit, let rich = request.rich else {
                    TestRunner.fail("an HTML item did not open the styled editor")
                    return
                }
                expectEqual(rich.format, .html)
                expectEqual(rich.document.plainText, sample.plainText)

                let edited = StyledTextDocument(runs: rich.document.runs + [
                    StyledTextRun(text: "\nadded", isItalic: true, pointSize: 16),
                ])
                let failure = model.commitStyledTextEdit(edited)
                expectNil(failure)
                expectNil(model.pendingTextEdit)

                let stored = try history.store.entry(id: entry.id)
                let html = stored?.flavours.first { $0.type == PasteboardTypes.html }
                expectNotNil(html, "the edited item keeps its HTML flavour")
                expectNil(stored?.flavours.first { $0.type == PasteboardTypes.rtf })
                let payload = String(decoding: html?.data ?? Data(), as: UTF8.self)
                expect(payload.contains("font-size:16px"), "the new size has to be in the payload")
                expect(payload.contains("<i>"), "the new italic has to be in the payload")
                expect(payload.contains("added"), "the new text has to be in the payload")
                expectEqual(
                    FlavourDecoder.storedPlainText(from: stored?.flavours ?? []),
                    edited.plainText
                )
                expectEqual(try history.search("added").count, 1, "search follows the edited text")
                expectEqual(model.entries.first?.id, entry.id)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("saving the seed unchanged closes the sheet without touching the entry") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                // A payload captured elsewhere: its bytes are not the canonical
                // form the writer produces, so a rewrite would be visible.
                let foreign = "<html><body><div style=\"white-space: pre-wrap\"><span style=\"font-size:13px\">foreign <b>bold</b></span></div></body></html>"
                let entry = try history.store.insert(ClipboardEntry(createdAt: Date(), flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(foreign.utf8)),
                    Fixtures.text("foreign bold"),
                ]))
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()
                guard let rich = model.pendingTextEdit?.rich else {
                    TestRunner.fail("the foreign HTML did not open in the styled editor")
                    return
                }
                let seed = rich.document

                // Drive the live editor the sheet installs and submit the
                // document it reports, which is the path an unchanged save
                // actually takes. Handing `seed` straight to the model would
                // still pass if the editor's own conversion drifted.
                let controller = RichTextEditingController()
                let editor = RichTextEditor.makeEditor(
                    document: seed,
                    delegate: nil,
                    format: rich.format
                )
                controller.attach(editor.textView)
                let live = controller.document()
                expectEqual(live.plainText, seed.plainText, "the live editor shows the seed text")
                expectEqual(live, seed, "an untouched editor must convert back to the seed document")

                let failure = model.commitStyledTextEdit(live)
                expectNil(failure)
                expectNil(model.pendingTextEdit, "the unchanged sheet closes")
                let stored = try history.store.entry(id: entry.id)
                expectEqual(stored?.flavours, entry.flavours, "the payload must not be rewritten")
                expectEqual(stored?.fingerprint, entry.fingerprint)
                expectEqual(try history.store.isEntryLocallyEdited(id: entry.id), false)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the editor sets the configured font as its base font") {
        MainActor.assumeIsolated {
            let chosen = NSFont(name: "Menlo", size: 16) ?? NSFont.systemFont(ofSize: 16)
            let editor = RichTextEditor.makeEditor(
                document: StyledTextDocument(runs: []),
                delegate: nil,
                format: .html,
                font: chosen
            )
            expectEqual(editor.textView.font?.fontName, chosen.fontName)
            expectEqual(editor.textView.font?.pointSize, chosen.pointSize)

            let typing = editor.textView.typingAttributes[.font] as? NSFont
            expectEqual(typing?.fontName, chosen.fontName)
            expectEqual(typing?.pointSize, chosen.pointSize)
        }
    }

    TestRunner.add("a document built in code draws its uninstalled families in the base font") {
        MainActor.assumeIsolated {
            let chosen = NSFont(name: "Menlo", size: 20) ?? NSFont.systemFont(ofSize: 20)
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "missing family", pointSize: 16, fontFamily: "NoSuchFontFamilyForTests"),
                StyledTextRun(
                    text: " italic",
                    isItalic: true,
                    pointSize: 16,
                    fontFamily: "NoSuchFontFamilyForTests"
                ),
                StyledTextRun(
                    text: " bold",
                    isBold: true,
                    pointSize: 16,
                    fontFamily: "NoSuchFontFamilyForTests"
                ),
                StyledTextRun(text: " and georgia", pointSize: 16, fontFamily: "Georgia"),
            ])

            let drawn = RichTextEditing.attributedText(from: document, baseFont: chosen)
            let text = drawn.string as NSString

            let missingRange = text.range(of: "missing family")
            let missing = drawn.attribute(.font, at: missingRange.location, effectiveRange: nil) as? NSFont
            expectEqual(missing?.fontName, chosen.fontName)
            expectEqual(missing?.pointSize, 16, "the run keeps its own size, not the base font's")

            let italicRange = text.range(of: "italic")
            let italic = drawn.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
            expectEqual(italic?.familyName, "Menlo", "the fallback keeps the base family")
            expectEqual(italic?.pointSize, 16, "the italic fallback keeps the run's size")
            expectEqual(italic?.fontDescriptor.symbolicTraits.contains(.italic), true)

            let boldRange = text.range(of: "bold")
            let bold = drawn.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
            expectEqual(bold?.familyName, "Menlo", "the fallback keeps the base family")
            expectEqual(bold?.pointSize, 16, "the bold fallback keeps the run's size")
            expectEqual(bold?.fontDescriptor.symbolicTraits.contains(.bold), true)

            let installedRange = text.range(of: "georgia")
            let installed = drawn.attribute(.font, at: installedRange.location, effectiveRange: nil) as? NSFont
            expectEqual(installed?.familyName, "Georgia", "an installed family keeps its own font")
            expectEqual(installed?.pointSize, 16)
        }
    }

    TestRunner.add("a payload's missing declared family keeps the reader's rendition") {
        MainActor.assumeIsolated {
            @MainActor
            func open(_ format: RichTextFormat, _ payload: String) -> EntryRichTextEditSeed? {
                let entry = ClipboardEntry(createdAt: Date(), flavours: [
                    Flavour(itemIndex: 0, type: format.canonicalType, data: Data(payload.utf8)),
                    Fixtures.text("missing bold italic"),
                ])
                return RichTextEditing.seed(for: entry)
            }

            @MainActor
            func check(_ seed: EntryRichTextEditSeed?, format: String, readerFamily: String) {
                guard let seed else {
                    TestRunner.fail("\(format) payload did not open in the styled editor")
                    return
                }
                expectEqual(seed.document.plainText, "missing bold italic", "\(format) payload keeps its text")
                let runs = seed.document.runs

                guard let missing = runs.first(where: { $0.text.contains("missing") }) else {
                    TestRunner.fail("\(format) payload lost the run with the missing family")
                    return
                }
                expectEqual(
                    missing.fontFamily,
                    readerFamily,
                    "\(format) a declared family this system lacks keeps the reader's substitution"
                )
                expectEqual(missing.pointSize, 24, "\(format) the payload's own size survives")

                guard let bold = runs.first(where: { $0.text.contains("bold") }) else {
                    TestRunner.fail("\(format) payload lost the bold run")
                    return
                }
                expectEqual(bold.fontFamily, readerFamily)
                expectEqual(bold.pointSize, 24)
                expectEqual(bold.isBold, true, "\(format) the payload's bold survives")

                guard let italic = runs.first(where: { $0.text.contains("italic") }) else {
                    TestRunner.fail("\(format) payload lost the italic run")
                    return
                }
                expectEqual(italic.fontFamily, readerFamily)
                expectEqual(italic.pointSize, 24)
                expectEqual(italic.isItalic, true, "\(format) the payload's italic survives")
            }

            let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0\fnil\fcharset0 NoSuchFontXYZ;}}\f0\fs48 missing {\b bold} {\i italic}}"#
            check(open(.rtf, rtf), format: "RTF", readerFamily: "Helvetica")

            let html = """
                <html><body><div style="white-space: pre-wrap"><span style="font-family:'NoSuchFontXYZ';font-size:24px">missing <b>bold</b> <i>italic</i></span></div></body></html>
                """
            check(open(.html, html), format: "HTML", readerFamily: "Times")
        }
    }

    TestRunner.add("System plus a size in the styled editor round-trips as the default writing family") {
        MainActor.assumeIsolated {
            let chosen = FontPreference(pointSize: 17).chosenFont
            guard let chosen else {
                TestRunner.fail("System plus a size has to resolve to a font")
                return
            }
            expectEqual(chosen.fontName, NSFont.systemFont(ofSize: 17).fontName)

            let html = """
                <html><body><div style="white-space: pre-wrap"><span style="font-family:'Georgia';font-size:24px">georgia</span></div></body></html>
                """
            let entry = ClipboardEntry(createdAt: Date(), flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8)),
                Fixtures.text("georgia"),
            ])
            guard let seed = RichTextEditing.seed(for: entry) else {
                TestRunner.fail("the payload did not open in the styled editor")
                return
            }
            let controller = RichTextEditingController()
            let editor = RichTextEditor.makeEditor(
                document: seed.document,
                delegate: nil,
                format: seed.format,
                font: chosen
            )
            controller.attach(editor.textView)
            let textView = editor.textView
            guard let typing = textView.typingAttributes[.font] as? NSFont else {
                TestRunner.fail("the styled editor has no typing font")
                return
            }
            expectEqual(
                typing.familyName,
                StyledTextDocument.defaultFontFamily,
                "new text is typed in the default writing family"
            )
            expectEqual(Double(typing.pointSize), 17, accuracy: 0.01, "at the chosen size")

            textView.insertText("x", replacementRange: textView.selectedRange())
            let document = controller.document()
            guard let typed = document.runs.last else {
                TestRunner.fail("the typed text has no run")
                return
            }
            expectEqual(
                typed.fontFamily,
                StyledTextDocument.defaultFontFamily,
                "the styled document records the default writing family"
            )
            expectEqual(typed.pointSize, 17, accuracy: 0.01, "the styled document keeps the chosen size")
            expect(!typed.isBold)
            expect(!typed.isItalic)

            let drawn = RichTextEditing.attributedText(from: document)
            let typedRange = (drawn.string as NSString).range(of: "x", options: .backwards)
            guard typedRange.location != NSNotFound,
                  let drawnFont = drawn.attribute(
                      .font,
                      at: typedRange.location,
                      effectiveRange: nil
                  ) as? NSFont
            else {
                TestRunner.fail("the saved text has no drawn font")
                return
            }
            expectEqual(drawnFont.familyName, StyledTextDocument.defaultFontFamily)
            expectEqual(Double(drawnFont.pointSize), 17, accuracy: 0.01)

            for format in RichTextFormat.allCases {
                let payload = String(
                    data: RichTextEncoding.data(for: document, format: format),
                    encoding: .utf8
                ) ?? ""
                expect(
                    payload.contains(StyledTextDocument.defaultFontFamily),
                    "the \(format.rawValue) payload names the default writing family"
                )
                let saved = ClipboardEntry(createdAt: Date(), flavours: [
                    Flavour(
                        itemIndex: 0,
                        type: format.canonicalType,
                        data: RichTextEncoding.data(for: document, format: format)
                    ),
                    Fixtures.text(document.plainText),
                ])
                guard let reopened = RichTextEditing.seed(for: saved),
                      let reopenedTyped = reopened.document.runs.last
                else {
                    TestRunner.fail("the \(format.rawValue) payload did not reopen")
                    return
                }
                expectEqual(
                    reopenedTyped.fontFamily,
                    StyledTextDocument.defaultFontFamily,
                    "the reopened \(format.rawValue) item keeps the default writing family"
                )
                expectEqual(
                    reopenedTyped.pointSize,
                    17,
                    accuracy: 0.01,
                    "the reopened \(format.rawValue) item keeps the chosen size"
                )

                let reopenedDrawn = RichTextEditing.attributedText(from: reopened.document)
                let reopenedRange = (reopenedDrawn.string as NSString).range(of: "x", options: .backwards)
                guard reopenedRange.location != NSNotFound,
                      let reopenedFont = reopenedDrawn.attribute(
                          .font,
                          at: reopenedRange.location,
                          effectiveRange: nil
                      ) as? NSFont
                else {
                    TestRunner.fail("the reopened \(format.rawValue) item has no drawn font")
                    return
                }
                expectEqual(reopenedFont.familyName, StyledTextDocument.defaultFontFamily)
                expectEqual(Double(reopenedFont.pointSize), 17, accuracy: 0.01)
            }
        }
    }

    TestRunner.add("an editor family without a face keeps a code-built document's emphasis") {
        MainActor.assumeIsolated {
            let cases: [(family: String, bold: Bool, italic: Bool)] = [
                ("Monaco", true, false),
                ("PingFang SC", false, true),
                ("Monaco", true, true),
                ("PingFang SC", true, true),
                ("Smiley Sans", true, true),
            ]
            for testCase in cases {
                guard NSFont(name: testCase.family, size: 13) != nil else { continue }
                let run = StyledTextRun(
                    text: "emphasis",
                    isBold: testCase.bold,
                    isItalic: testCase.italic,
                    pointSize: 13,
                    fontFamily: testCase.family
                )
                let font = RichTextEditing.font(for: run)
                expectEqual(font.pointSize, 13, "\(testCase.family) keeps the run's size")
                let traits = font.fontDescriptor.symbolicTraits
                expectEqual(
                    traits.contains(.bold),
                    testCase.bold,
                    "\(testCase.family) keeps the bold face"
                )
                expectEqual(
                    traits.contains(.italic),
                    testCase.italic,
                    "\(testCase.family) keeps the italic face"
                )

                let readBack = RichTextEditing.styledDocument(
                    from: NSAttributedString(string: run.text, attributes: [.font: font])
                )
                guard let saved = readBack.runs.first else {
                    TestRunner.fail("\(testCase.family) lost the run when it was read back")
                    continue
                }
                expectEqual(saved.isBold, testCase.bold, "\(testCase.family) bold survives the read-back")
                expectEqual(saved.isItalic, testCase.italic, "\(testCase.family) italic survives the read-back")

                let entry = styledEntry(format: .html, document: readBack)
                guard let seed = RichTextEditing.seed(for: entry), let reopened = seed.document.runs.first
                else {
                    TestRunner.fail("\(testCase.family) item did not reopen in the styled editor")
                    continue
                }
                expectEqual(reopened.isBold, testCase.bold, "\(testCase.family) bold survives a saved item")
                expectEqual(reopened.isItalic, testCase.italic, "\(testCase.family) italic survives a saved item")
            }
        }
    }

    TestRunner.add("an HTML item with an inline image still opens the plain editor") {
        MainActor.assumeIsolated {
            do {
                let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
                let html = "<html><body><p>captioned</p><img src=\"data:image/png;base64,\(png)\"></body></html>"
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let entry = try history.store.insert(ClipboardEntry(createdAt: Date(), flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8)),
                    Fixtures.text("captioned"),
                ]))
                model.reload()
                model.select(entry.id)
                model.requestEditSelectedEntry()
                expectNotNil(model.pendingTextEdit, "the item is still editable as text")
                expectNil(model.pendingTextEdit?.rich, "the styled editor cannot keep the inline image")
                expectEqual(model.pendingTextEdit?.text, "captioned")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
