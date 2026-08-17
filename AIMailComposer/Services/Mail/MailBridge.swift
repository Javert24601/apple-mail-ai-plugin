import Foundation
import AppKit

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case noComposer
    case mailNotRunning
    case parseError(String)
    case timedOut

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
        case .timedOut:
            return "Mail didn't respond in time. It may be busy syncing — try again in a moment."
        }
    }
}

final class MailBridge {
    /// Ceiling on a single script run. The scripts also carry their own
    /// `with timeout` blocks, which is what actually bounds each Apple Event;
    /// this is the outer backstop so the caller can never be left awaiting a
    /// script that never returns.
    private static let scriptTimeout: Duration = .seconds(25)

    static func executeAppleScript(_ source: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await runScript(source)
            }
            group.addTask {
                try await Task.sleep(for: scriptTimeout)
                throw MailBridgeError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MailBridgeError.timedOut
            }
            return result
        }
    }

    private static func runScript(_ source: String) async throws -> String {
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

        return expandCitedThread(context: context)
    }

    /// Split the quoted chain into individual messages.
    ///
    /// The script hands back the replied-to message as a single block whose
    /// body still contains the whole cited history. Splitting it here is pure
    /// string work — no further Apple Events, so it costs nothing and can't
    /// stall Mail.
    ///
    /// The compose window's own text is the better source when AX could read
    /// it: it is literally what the reply cites, and splitting it also
    /// separates what the user has already typed from the quoted history
    /// below it. Falls back to the anchor message's body otherwise.
    private static func expandCitedThread(context: ComposerContext) -> ComposerContext {
        let anchor = context.thread?.messages.first

        if !context.currentDraft.isEmpty {
            let split = QuotedThreadParser.split(
                body: context.currentDraft,
                newestSender: anchor?.sender ?? "",
                newestDate: anchor?.dateSent,
                subject: context.subject
            )
            if !split.quoted.isEmpty {
                return ComposerContext(
                    recipients: context.recipients,
                    subject: context.subject,
                    currentDraft: split.typedByUser,
                    thread: EmailThread(subject: context.subject, messages: split.quoted),
                    composeWindowFrame: context.composeWindowFrame
                )
            }
        }

        guard let anchor else { return context }

        let split = QuotedThreadParser.split(
            body: anchor.body,
            newestSender: anchor.sender,
            newestDate: anchor.dateSent,
            subject: anchor.subject
        )
        let messages = split.allAsThread(
            recipients: anchor.recipients,
            subject: anchor.subject
        )
        guard messages.count > 1 else { return context }

        return ComposerContext(
            recipients: context.recipients,
            subject: context.subject,
            currentDraft: context.currentDraft,
            thread: EmailThread(subject: context.subject, messages: messages),
            composeWindowFrame: context.composeWindowFrame
        )
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
