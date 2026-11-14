// Content-level privacy: an AI-service API key copied once is left out of the
// history, so a key copied here never sits in SQLite or a sync folder in
// plaintext.
//
// The rule is applied to the pasteboard snapshot before
// `ClipboardHistory.record`, so a blocked payload never reaches the store, and
// the skip log names only the rule, never the matched secret. It is the sibling
// of the app-based rules in `core/CaptureExclusion.swift`, which protect the
// same boundary from the other side; the two share the principle that the
// decision happens before anything is written.
//
// Detection is deliberately narrow: a fixed table of prefixes, minimum and
// maximum body lengths, and allowed body characters for the shapes we actually
// meet. There is no entropy heuristic and no general secrets scanner, so a
// sentence that merely mentions a prefix is never blocked, and a key shape that
// is not in the table is not detected. A generic `Bearer` credential is not a
// shape of its own: it is skipped only when the credential inside it has one of
// the AI-service shapes in the table. The rule covers captures made on this
// machine; an item already arriving through a sync folder is not filtered, so
// an inbound item can still store a key here. The setting says as much to the
// reader: this greatly reduces what can leak, it cannot promise nothing ever
// does.
//
// AppKit-free: the pasteboard side lives in `app/ClipboardWatcher.swift`.

import Foundation

/// The character set a key body may use after its prefix.
public enum APIKeyBody: Sendable {
    /// Letters and digits only, for example OpenAI's legacy `sk-` keys.
    case base62
    /// Letters, digits, `-`, and `_`, the body of `sk-proj-`, `sk-ant-` and the
    /// Google `AIza` keys.
    case base64URL

    /// Whether this byte may appear in the body after the prefix.
    func allows(_ byte: UInt8) -> Bool {
        switch self {
        case .base62:
            return Self.isLetter(byte) || Self.isDigit(byte)
        case .base64URL:
            return Self.isLetter(byte) || Self.isDigit(byte) || byte == 0x2D || byte == 0x5F
        }
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// The bytes that continue a credential rather than end it. A prefix that
    /// starts right after one of these is part of a longer word, not a key.
    ///
    /// Punctuation that separates a value from its label (`=`), quotes a shell
    /// argument (`"`, `'`), or closes a sentence is a boundary: `KEY=sk-...` and
    /// `"sk-..."` are keys, while `xsk-...` is one word and not.
    static func isTokenByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == 0x2D || byte == 0x5F || byte == 0x2E
    }
}

/// One row of the detection table: a prefix, the body it must be followed by,
/// and the body length that makes it a key rather than a word.
public struct APIKeyRule: Equatable, Sendable {
    /// Names the family in the skip log, for example `anthropic`. Never contains
    /// any part of a matched secret.
    public let label: String
    /// Openings that start the credential, matched case-sensitively.
    public let prefixes: [String]
    /// The characters the body after the prefix may use.
    public let body: APIKeyBody
    /// How many body bytes make a key of this shape.
    public let bodyLength: ClosedRange<Int>

    public init(
        label: String,
        prefixes: [String],
        body: APIKeyBody,
        bodyLength: ClosedRange<Int>
    ) {
        self.label = label
        self.prefixes = prefixes
        self.body = body
        self.bodyLength = bodyLength
    }
}

/// The fixed table of AI-service key shapes, and the match against a payload.
public enum APIKeyDetection {
    /// The single place to extend when another service's key shape shows up.
    ///
    /// Order matters: the specific openings come first, so `sk-or-v1-`,
    /// `sk-proj-`, `sk-svcacct-`, `sk-admin-` and `sk-ant-` are named as
    /// themselves instead of as the generic `sk-` key they also start with.
    public static let rules: [APIKeyRule] = [
        APIKeyRule(
            label: "openai-project",
            prefixes: ["sk-proj-"],
            body: .base64URL,
            bodyLength: 40...300
        ),
        APIKeyRule(
            label: "openai-service-account",
            prefixes: ["sk-svcacct-"],
            body: .base64URL,
            bodyLength: 40...300
        ),
        APIKeyRule(
            label: "openai-admin",
            prefixes: ["sk-admin-"],
            body: .base64URL,
            bodyLength: 40...300
        ),
        APIKeyRule(
            label: "openrouter",
            prefixes: ["sk-or-v1-"],
            body: .base62,
            bodyLength: 32...128
        ),
        APIKeyRule(
            label: "anthropic",
            prefixes: ["sk-ant-"],
            body: .base64URL,
            bodyLength: 30...300
        ),
        APIKeyRule(
            label: "google",
            prefixes: ["AIza"],
            body: .base64URL,
            bodyLength: 30...45
        ),
        APIKeyRule(
            label: "openai",
            prefixes: ["sk-"],
            body: .base62,
            bodyLength: 32...120
        ),
    ]

    /// The first rule in the table that matches anywhere in `text`.
    ///
    /// The table order decides which rule is named when two could match, so the
    /// caller gets a stable reason for the skip log.
    public static func match(in text: String) -> APIKeyRule? {
        guard !text.isEmpty else { return nil }
        let bytes = Array(text.utf8)
        return rules.first { matches($0, in: bytes) }
    }

    /// The first rule that matches the text of any text flavour in a snapshot.
    ///
    /// Only the plain-text family is read: a key pasted as plain text always
    /// arrives in one of those flavours, and the other flavours are left to the
    /// paste path untouched.
    public static func match(in flavours: [Flavour]) -> APIKeyRule? {
        for flavour in flavours where PasteboardTypes.textTypes.contains(flavour.type) {
            guard let text = FlavourDecoder.decodeText(type: flavour.type, data: flavour.data)
            else { continue }
            if let rule = match(in: text) { return rule }
        }
        return nil
    }

    /// Scans for one rule's prefixes. A match is a prefix that does not continue
    /// a longer word, followed by a body of allowed bytes whose length is in the
    /// rule's range; the body is taken as the longest allowed run, so a key is
    /// never cut short to fit the range.
    private static func matches(_ rule: APIKeyRule, in bytes: [UInt8]) -> Bool {
        for prefix in rule.prefixes {
            let prefixBytes = Array(prefix.utf8)
            guard !prefixBytes.isEmpty, bytes.count > prefixBytes.count else { continue }
            var start = 0
            while start + prefixBytes.count <= bytes.count {
                guard matchesPrefix(bytes, at: start, prefix: prefixBytes) else {
                    start += 1
                    continue
                }
                if start > 0, APIKeyBody.isTokenByte(bytes[start - 1]) {
                    start += 1
                    continue
                }
                let bodyStart = start + prefixBytes.count
                var end = bodyStart
                while end < bytes.count, rule.body.allows(bytes[end]) { end += 1 }
                if rule.bodyLength.contains(end - bodyStart) { return true }
                start = max(end, start + 1)
            }
        }
        return false
    }

    private static func matchesPrefix(
        _ bytes: [UInt8],
        at start: Int,
        prefix: [UInt8]
    ) -> Bool {
        for offset in 0..<prefix.count {
            if bytes[start + offset] != prefix[offset] { return false }
        }
        return true
    }
}
