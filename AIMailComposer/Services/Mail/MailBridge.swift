import Foundation
import AppKit

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case noComposer
    case mailNotRunning
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg):
            return "AppleScript error: \(msg)"
        case .noComposer:
            return "Open a compose window in Mail first, then try again."
        case .mailNotRunning:
            return "Mail is not running. Open Mail and try again."
        case .parseError(let msg):
            return "Failed to parse Mail context: \(msg)"
        }
    }
}

final class MailBridge {
    static func executeAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: MailBridgeError.scriptFailed("Failed to create script"))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: MailBridgeError.scriptFailed(message))
                } else {
                    continuation.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }

    static func isMailRunning() async -> Bool {
        do {
            let result = try await executeAppleScript(MailScripts.checkMailRunning)
            return result.lowercased() == "true"
        } catch {
            return false
        }
    }

    /// Pull context from the currently open Mail compose window, falling
    /// back to the Accessibility reader when Mail's `outgoing messages`
    /// AppleScript collection is empty (recent macOS versions). Never
    /// blocks on Accessibility permission: if AX isn't granted, the
    /// AppleScript context is returned as-is so the UI can offer a
    /// dismissible banner instead of a permission wall.
    ///
    /// The compose window stays the source of truth for *which* conversation
    /// this is. The viewer's selected message is consulted only to resolve
    /// that conversation, and only when its subject matches the compose
    /// window's — so a stray highlighted row can never become the context.
    static func fetchComposerContext() async throws -> ComposerContext {
        guard await isMailRunning() else {
            throw MailBridgeError.mailNotRunning
        }

        let raw = try await executeAppleScript(MailScripts.fetchComposerContext)

        if raw.hasPrefix("ERROR:NO_COMPOSER") {
            throw MailBridgeError.noComposer
        }

        var context = try MailThreadParser.parseComposerContext(raw)

        // An empty draft means Pass 1 (`outgoing messages`) never saw the
        // compose window — the usual case for a reply the user opened by
        // hand. The script can reconstruct the recipients from the message
        // being replied to, but never the draft body, so AX is still the
        // only way to read what's actually typed in the window. Prefer it
        // whenever it's available; otherwise return the context as-is.
        if context.currentDraft.isEmpty {
            context = enrichViaAccessibility(context: context)
        }

        return await recoverThreadIfMissing(context: context)
    }

    /// The script emits no thread when it couldn't identify the message being
    /// replied to — it refuses to guess from the subject alone. If this still
    /// looks like a reply and we now know the recipients (usually recovered
    /// via AX), retry the lookup scoped to those participants. Returns the
    /// context unchanged on any failure.
    private static func recoverThreadIfMissing(context: ComposerContext) async -> ComposerContext {
        guard context.thread == nil,
              context.looksLikeReply,
              !context.recipients.isEmpty
        else {
            return context
        }

        let base = context.baseSubject
        guard !base.isEmpty else { return context }

        let addresses = context.recipients.compactMap(emailAddress(from:))
        guard !addresses.isEmpty else { return context }

        let script = MailScripts.fetchThread(baseSubject: base, participants: addresses)
        guard let raw = try? await executeAppleScript(script) else {
            return context
        }

        let messages = MailThreadParser.parseThreadMessages(raw)
        guard !messages.isEmpty else { return context }

        return ComposerContext(
            recipients: context.recipients,
            subject: context.subject,
            currentDraft: context.currentDraft,
            thread: EmailThread(subject: context.subject, messages: messages),
            composeWindowFrame: context.composeWindowFrame
        )
    }

    /// Pull the bare address out of a recipient string. AX yields display
    /// forms like `Reinholds Bunde <mr@example.com>`, which won't substring
    /// match against a raw address in the thread search.
    private static func emailAddress(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed[open...].firstIndex(of: ">") {
            let inner = trimmed[trimmed.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            return inner.contains("@") ? inner : nil
        }
        return trimmed.contains("@") ? trimmed : nil
    }

    /// Opportunistically enrich the context via the AX reader. If AX isn't
    /// trusted or no compose window is found, the original context is
    /// returned unchanged — never throws.
    private static func enrichViaAccessibility(context: ComposerContext) -> ComposerContext {
        guard AXPermissionChecker.isGranted() else {
            return context
        }

        guard let ax = AccessibilityReader.readComposeWindow() else {
            // AX is granted but no compose window was found — return the
            // original (possibly empty) context rather than failing.
            return context
        }

        let thread = context.thread
        let subject = ax.subject.isEmpty ? context.subject : ax.subject
        // The script may already have reconstructed recipients from the
        // message being replied to. Only let AX override that when it
        // actually found some, so a partial AX read can't blank them out.
        let recipients = ax.recipients.isEmpty ? context.recipients : ax.recipients

        return ComposerContext(
            recipients: recipients,
            subject: subject,
            currentDraft: ax.draftContent,
            thread: thread,
            composeWindowFrame: context.composeWindowFrame
        )
    }

    /// Write the reply directly into the current Mail compose window.
    /// Falls back to the clipboard if the AppleScript insert fails.
    @MainActor
    static func insertReply(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        _ = try? await executeAppleScript(MailScripts.insertReply(text))
        activateMail()
    }

    @MainActor
    private static func activateMail() {
        if let mailApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first {
            mailApp.activate()
        }
    }
}
