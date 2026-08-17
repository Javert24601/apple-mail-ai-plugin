import Foundation
import CoreGraphics

/// Snapshot of the currently open Mail compose window, plus the matching
/// thread context (if this is a reply). The composer window is the single
/// source of truth — never derived from which message is selected in the list.
struct ComposerContext {
    let recipients: [String]
    let subject: String
    let currentDraft: String
    let thread: EmailThread?
    /// The compose window's screen frame (AppleScript/AX coordinates: origin
    /// at the top-left of the primary display, y grows downward).
    let composeWindowFrame: CGRect?

    var isNewEmail: Bool { thread == nil }
    var hasRecipients: Bool { !recipients.isEmpty }
    var messageCount: Int { thread?.messages.count ?? 0 }

    /// True when the subject carries a reply/forward prefix. A compose
    /// window can look like a reply while carrying no thread at all — Mail
    /// hides hand-opened compose windows from AppleScript — so this is what
    /// distinguishes "reply we failed to read" from "genuinely new email".
    var looksLikeReply: Bool {
        Self.replyPrefixes.contains { subject.lowercased().hasPrefix($0) }
    }

    /// The subject with any stack of reply/forward prefixes removed.
    var baseSubject: String {
        Self.strippingReplyPrefixes(subject)
    }

    private static let replyPrefixes = ["re:", "fwd:", "fw:", "aw:", "wg:"]

    static func strippingReplyPrefixes(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in replyPrefixes where result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return result
    }

    var displaySubject: String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "New Message" {
            return "New message"
        }
        return trimmed
    }

    var recipientSummary: String {
        guard !recipients.isEmpty else { return "No recipients yet" }
        if recipients.count == 1 { return recipients[0] }
        return "\(recipients[0]) +\(recipients.count - 1)"
    }
}
