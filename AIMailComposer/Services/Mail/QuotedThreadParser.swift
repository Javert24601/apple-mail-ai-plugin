import Foundation

/// Splits an email body into the text written at the top and the chain of
/// quoted messages below it.
///
/// A reply carries its own history: Mail writes an attribution line ("On …
/// wrote:", "Am … schrieb …:", "Begin forwarded message:") above each older
/// message it quotes. Reading that chain is how the plugin recovers a thread
/// without asking Mail for anything — which matters because every Apple Event
/// into Mail is a synchronous round trip, and enough of them make Mail
/// unresponsive.
///
/// Deliberately conservative: if no attribution line is recognised, the whole
/// body comes back as `typedByUser` with no quoted messages, and the caller
/// keeps whatever context it already had.
enum QuotedThreadParser {

    struct Split {
        /// Text above the first attribution line — the reply being written,
        /// or the newest message's own words.
        let typedByUser: String
        /// Quoted messages, oldest first, to match `EmailThread` ordering.
        let quoted: [EmailMessage]

        /// The newest text plus the quoted chain as one thread, for when the
        /// body came from a message rather than a compose window. Returns the
        /// quoted messages alone when there is no leading text.
        func allAsThread(recipients: [String], subject: String) -> [EmailMessage] {
            guard !typedByUser.isEmpty else { return quoted }
            return quoted + [
                EmailMessage(
                    sender: newestSender,
                    recipients: recipients,
                    subject: subject,
                    dateSent: newestDate,
                    body: typedByUser
                ),
            ]
        }

        fileprivate let newestSender: String
        fileprivate let newestDate: Date?
    }

    /// Break `body` at each attribution line.
    ///
    /// `newestSender` and `newestDate` describe the text above the first
    /// attribution — the message the body itself belongs to — since the body
    /// never states its own author.
    static func split(
        body: String,
        newestSender: String,
        newestDate: Date?,
        subject: String
    ) -> Split {
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // Each boundary is (line index, sender parsed from the attribution).
        var boundaries: [(index: Int, sender: String, date: Date?)] = []
        for (index, line) in lines.enumerated() {
            guard let attribution = parseAttribution(line) else { continue }
            boundaries.append((index, attribution.sender, attribution.date))
        }

        guard !boundaries.isEmpty else {
            return Split(
                typedByUser: cleaned(lines),
                quoted: [],
                newestSender: newestSender,
                newestDate: newestDate
            )
        }

        let head = cleaned(Array(lines[..<boundaries[0].index]))

        // Segments run newest to oldest down the body: each attribution owns
        // the text between it and the next one.
        var segments: [EmailMessage] = []
        for (position, boundary) in boundaries.enumerated() {
            let start = boundary.index + 1
            let end = position + 1 < boundaries.count
                ? boundaries[position + 1].index
                : lines.count
            guard start < end else { continue }

            let text = cleaned(Array(lines[start..<end]))
            guard !text.isEmpty else { continue }

            segments.append(EmailMessage(
                sender: boundary.sender,
                recipients: [],
                subject: subject,
                dateSent: boundary.date,
                body: text
            ))
        }

        return Split(
            typedByUser: head,
            quoted: segments.reversed(),
            newestSender: newestSender,
            newestDate: newestDate
        )
    }

    // MARK: - Attribution lines

    /// Recognise the line Mail writes above a quoted message and pull the
    /// sender out of it. Returns nil for ordinary body text.
    private static func parseAttribution(_ rawLine: String) -> (sender: String, date: Date?)? {
        let line = stripQuoteMarkers(rawLine)
        guard !line.isEmpty, line.count < 300 else { return nil }

        if line.caseInsensitiveCompare("Begin forwarded message:") == .orderedSame {
            return ("Forwarded message", nil)
        }

        // "On <date>, <sender> wrote:" and the German "Am <date> schrieb
        // <sender>:". Both put the sender last, before the colon.
        let isEnglish = line.hasPrefix("On ") && line.hasSuffix("wrote:")
        let isGerman = line.hasPrefix("Am ") && line.hasSuffix(":") && line.contains("schrieb")
        guard isEnglish || isGerman else { return nil }

        var remainder = line
        if isEnglish {
            remainder = String(line.dropLast("wrote:".count))
        } else if let range = line.range(of: "schrieb ") {
            remainder = String(line[range.upperBound...].dropLast())
        }

        return (senderName(from: remainder), parseDate(from: line))
    }

    /// Pull a display name out of the attribution's tail, which looks like
    /// "…, at 14:13, Reinholds Bunde <mr@example.com> " by this point.
    private static func senderName(from remainder: String) -> String {
        var text = remainder.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(",") { text = String(text.dropLast()) }

        if let open = text.lastIndex(of: "<") {
            let name = text[..<open].trimmingCharacters(in: .whitespaces)
            let address = text[text.index(after: open)...]
                .drop(while: { $0 == " " })
                .prefix(while: { $0 != ">" })
            let trimmedName = name
                .components(separatedBy: ", ")
                .last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !trimmedName.isEmpty { return trimmedName }
            return String(address)
        }

        // No angle-bracketed address: take the text after the last comma,
        // which is where the name sits in every layout we handle.
        if let tail = text.components(separatedBy: ", ").last {
            let candidate = tail.trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { return candidate }
        }
        return text.isEmpty ? "Unknown sender" : text
    }

    /// Best-effort date from an attribution line. Locale-dependent and often
    /// absent, so a nil result is expected and harmless — ordering comes from
    /// the chain's position, never from these dates.
    private static func parseDate(from line: String) -> Date? {
        let formats = [
            "d MMM yyyy 'at' HH:mm",
            "d MMMM yyyy 'at' HH:mm",
            "MMM d, yyyy 'at' h:mm a",
            "dd.MM.yyyy 'um' HH:mm",
        ]
        let formatter = DateFormatter()
        for format in formats {
            formatter.dateFormat = format
            for candidate in dateCandidates(in: line) {
                if let date = formatter.date(from: candidate) { return date }
            }
        }
        return nil
    }

    /// Comma-separated runs of the attribution line, longest first, so a
    /// format spanning "17 Aug 2026 at 12:35" is tried before its fragments.
    private static func dateCandidates(in line: String) -> [String] {
        let body = line
            .replacingOccurrences(of: "On ", with: "")
            .replacingOccurrences(of: "Am ", with: "")
        return body
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Text helpers

    /// Drop the leading ">" markers Mail adds to quoted plain text.
    private static func stripQuoteMarkers(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == ">" || first == " " || first == "\t" {
            text = text.dropFirst()
        }
        return String(text).trimmingCharacters(in: .whitespaces)
    }

    private static func cleaned(_ lines: [String]) -> String {
        lines
            .map(stripQuoteMarkers)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
