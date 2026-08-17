import Foundation

enum MailScripts {
    /// Read context from the currently open compose window in Mail.
    ///
    /// This script is implemented entirely against the Mail scripting
    /// dictionary — no System Events / Accessibility calls — so on its own
    /// it only needs Automation permission for Mail. That guarantee no
    /// longer holds for the app as a whole: when this path comes back
    /// empty on recent macOS versions, `MailBridge` augments the result
    /// via the Accessibility reader (`AccessibilityReader`). That widens
    /// the permission footprint — AX can read every app's UI — which is a
    /// deliberate trade-off recorded here rather than left as silent
    /// comment rot.
    ///
    /// Detection priority:
    ///   1. `outgoing message 1` properties (best: gives recipients + draft).
    ///      In practice this is empty for any compose window the *user*
    ///      opened by hand — Mail only lists messages created through
    ///      `make new outgoing message` — so it usually only helps for
    ///      script-created drafts.
    ///   2. Any Mail `window` that is not the `message viewer`'s window (the
    ///      list/reading pane). This covers the case on newer macOS releases
    ///      where a brand-new blank compose window doesn't show up in
    ///      `outgoing messages`. Only the window *title* is available here,
    ///      which is why it can't supply recipients or the draft body.
    ///   3. The message being replied to, resolved from the message viewer's
    ///      selection and accepted only when its subject matches the compose
    ///      window's (prefix-stripped) subject.
    ///
    /// ## Why the thread is anchored to a message, not a subject
    ///
    /// Matching only on `subject contains baseSubject` treats every message
    /// sharing a phrase as one conversation. For a subject reused across
    /// unrelated correspondences — a property address written to a
    /// solicitor, an estate agent and a broker in separate threads — that
    /// pulls all of them into the model's context.
    ///
    /// So the thread is anchored to step 3's message: the one actually being
    /// replied to. Its body already embeds the quoted chain, which is the
    /// context cited in the reply window. Sibling messages are then admitted
    /// only when they share a participant with that anchor.
    ///
    /// If neither a compose recipient nor an anchor message can be found,
    /// **no thread is emitted at all**. An unfiltered subject sweep is never
    /// run as a fallback: wrong context is worse than none, because the model
    /// silently drafts replies grounded in someone else's conversation.
    static let fetchComposerContext = """
    set composeSubject to ""
    set recipientList to ""
    set recipientAddrs to {}
    set draftContent to ""
    set composeWinL to "-"
    set composeWinT to "-"
    set composeWinR to "-"
    set composeWinB to "-"
    set hasComposer to false
    set debugInfo to ""
    set myAddrs to {}

    tell application "Mail"
        try
            repeat with acct in accounts
                try
                    repeat with ea in (email addresses of acct)
                        set end of myAddrs to (ea as string)
                    end repeat
                end try
            end repeat
        end try

        -- Pass 1: outgoing message. Populates everything when available.
        try
            set outMsgCount to count of outgoing messages
            set debugInfo to "out:" & outMsgCount
            if outMsgCount > 0 then
                set outMsg to outgoing message 1
                try
                    set composeSubject to subject of outMsg
                end try
                try
                    repeat with r in to recipients of outMsg
                        set rAddr to (address of r)
                        if recipientList is not "" then set recipientList to recipientList & ", "
                        set recipientList to recipientList & rAddr
                        set end of recipientAddrs to rAddr
                    end repeat
                end try
                try
                    repeat with r in cc recipients of outMsg
                        set end of recipientAddrs to (address of r)
                    end repeat
                end try
                try
                    set draftContent to content of outMsg
                end try
                set hasComposer to true
            end if
        on error errMsg
            set debugInfo to debugInfo & " outErr:" & errMsg
        end try

        -- Pass 2: find a non-viewer window. Works even for blank new
        -- compose windows that aren't exposed via `outgoing messages`.
        try
            set viewerNames to {}
            set viewerCount to count of message viewers
            set debugInfo to debugInfo & " vCount:" & viewerCount
            repeat with mv in message viewers
                try
                    set n to name of (window of mv)
                    set viewerNames to viewerNames & {n}
                end try
            end repeat

            set winCount to count of windows
            repeat with i from 1 to winCount
                try
                    set w to window i
                    set wName to name of w
                    set isViewer to false
                    repeat with vn in viewerNames
                        if wName is equal to (vn as string) then
                            set isViewer to true
                            exit repeat
                        end if
                    end repeat
                    if not isViewer then
                        -- Non-viewer window in Mail == compose (or reading)
                        -- window. Both are fine for our purposes.
                        if not hasComposer then
                            set composeSubject to wName
                            set hasComposer to true
                        end if
                        try
                            set b to bounds of w
                            set composeWinL to (item 1 of b) as string
                            set composeWinT to (item 2 of b) as string
                            set composeWinR to (item 3 of b) as string
                            set composeWinB to (item 4 of b) as string
                        end try
                        exit repeat
                    end if
                end try
            end repeat
        on error errMsg
            set debugInfo to debugInfo & " winErr:" & errMsg
        end try
    end tell

    if not hasComposer then
        return "ERROR:NO_COMPOSER|" & debugInfo
    end if

    -- Strip reply/forward prefixes to get the bare conversation subject.
    -- Used to (a) recognise a reply and (b) verify that the message selected
    -- in the viewer really belongs to the thread being replied to.
    set baseSubject to composeSubject
    set changed to true
    repeat while changed
        set changed to false
        if baseSubject starts with "Re: " then
            set baseSubject to text 5 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "Re:" then
            set baseSubject to text 4 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "Fwd: " then
            set baseSubject to text 6 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "Fwd:" then
            set baseSubject to text 5 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "Fw: " then
            set baseSubject to text 5 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "AW: " then
            set baseSubject to text 5 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "AW:" then
            set baseSubject to text 4 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "WG: " then
            set baseSubject to text 5 thru -1 of baseSubject
            set changed to true
        else if baseSubject starts with "WG:" then
            set baseSubject to text 4 thru -1 of baseSubject
            set changed to true
        end if
    end repeat

    set threadBody to ""
    set threadFound to 0

    -- Only look for a thread when there is a real subject to anchor to.
    -- "New Message" is Mail's placeholder title for an empty compose window.
    if baseSubject is not "" and baseSubject is not "New Message" then
        tell application "Mail"
            -- Pass 3: resolve the message actually being replied to. The
            -- viewer selection is only trusted when its subject matches the
            -- compose window's, so an unrelated highlighted row can never
            -- become the context.
            set anchorMsg to missing value
            try
                repeat with m in (get selection)
                    try
                        if (subject of m) contains baseSubject then
                            set anchorMsg to (contents of m)
                            exit repeat
                        end if
                    end try
                end repeat
            end try
            if anchorMsg is missing value then
                try
                    repeat with mv in message viewers
                        try
                            repeat with m in (selected messages of mv)
                                try
                                    if (subject of m) contains baseSubject then
                                        set anchorMsg to (contents of m)
                                        exit repeat
                                    end if
                                end try
                            end repeat
                        end try
                        if anchorMsg is not missing value then exit repeat
                    end repeat
                end try
            end if

            -- Participants define the conversation. Prefer the compose
            -- window's own recipients; otherwise take everyone on the
            -- anchor message.
            set participantAddrs to {}
            repeat with a in recipientAddrs
                set end of participantAddrs to (a as string)
            end repeat
            if anchorMsg is not missing value then
                try
                    set end of participantAddrs to (extract address from (sender of anchorMsg))
                end try
                try
                    repeat with r in to recipients of anchorMsg
                        set end of participantAddrs to (address of r)
                    end repeat
                end try
                try
                    repeat with r in cc recipients of anchorMsg
                        set end of participantAddrs to (address of r)
                    end repeat
                end try
            end if

            -- Mail can't tell us the compose window's recipients when the
            -- window was opened by hand. Reconstruct who the reply goes to
            -- from the anchor: its sender plus its other recipients, minus
            -- our own accounts.
            if recipientList is "" and anchorMsg is not missing value then
                set replyAddrs to {}
                try
                    set end of replyAddrs to (extract address from (sender of anchorMsg))
                end try
                try
                    repeat with r in to recipients of anchorMsg
                        set end of replyAddrs to (address of r)
                    end repeat
                end try
                try
                    repeat with r in cc recipients of anchorMsg
                        set end of replyAddrs to (address of r)
                    end repeat
                end try
                repeat with a in replyAddrs
                    set aStr to (a as string)
                    if aStr is not "" and myAddrs does not contain aStr then
                        if recipientList does not contain aStr then
                            if recipientList is not "" then set recipientList to recipientList & ", "
                            set recipientList to recipientList & aStr
                        end if
                    end if
                end repeat
            end if

            -- Collect sibling messages of the same conversation: subject
            -- match narrowed by a shared participant. Skipped entirely when
            -- we have no participants to narrow by.
            set threadMsgs to {}
            set seenIDs to {}
            if anchorMsg is not missing value then
                try
                    set end of seenIDs to (message id of anchorMsg)
                end try
            end if

            if (count of participantAddrs) > 0 then
                set scanned to 0
                try
                    repeat with acct in accounts
                        repeat with mbName in {"INBOX", "Sent Messages", "Sent", "Gesendet", "Archive", "Archiv", "All Mail"}
                            try
                                set mb to mailbox mbName of acct
                                repeat with msg in (every message of mb whose subject contains baseSubject)
                                    if scanned > 300 then exit repeat
                                    set scanned to scanned + 1
                                    try
                                        set thisID to (message id of msg)
                                        if seenIDs does not contain thisID then
                                            set msgSender to ""
                                            try
                                                set msgSender to (sender of msg)
                                            end try
                                            set msgRecipientText to ""
                                            try
                                                repeat with r in to recipients of msg
                                                    set msgRecipientText to msgRecipientText & (address of r) & ", "
                                                end repeat
                                            end try
                                            try
                                                repeat with r in cc recipients of msg
                                                    set msgRecipientText to msgRecipientText & (address of r) & ", "
                                                end repeat
                                            end try
                                            set isParticipant to false
                                            repeat with recAddr in participantAddrs
                                                set aStr to (recAddr as string)
                                                if aStr is not "" then
                                                    if msgSender contains aStr then set isParticipant to true
                                                    if msgRecipientText contains aStr then set isParticipant to true
                                                end if
                                            end repeat
                                            if isParticipant then
                                                set end of seenIDs to thisID
                                                set end of threadMsgs to (contents of msg)
                                            end if
                                        end if
                                    end try
                                end repeat
                            end try
                        end repeat
                    end repeat
                end try
            end if

            -- Keep the most recent siblings, then append the anchor last so
            -- it always survives the cap — it carries the quoted chain.
            set sibCount to count of threadMsgs
            if sibCount > 19 then
                set threadMsgs to items (sibCount - 18) thru sibCount of threadMsgs
            end if
            if anchorMsg is not missing value then
                set end of threadMsgs to anchorMsg
            end if

            repeat with msg in threadMsgs
                set threadFound to threadFound + 1
                try
                    set threadBody to threadBody & "FROM:" & (sender of msg) & linefeed
                on error
                    set threadBody to threadBody & "FROM:unknown" & linefeed
                end try
                try
                    set rList to ""
                    repeat with r in to recipients of msg
                        if rList is not "" then set rList to rList & ", "
                        set rList to rList & (address of r)
                    end repeat
                    set threadBody to threadBody & "TO:" & rList & linefeed
                on error
                    set threadBody to threadBody & "TO:unknown" & linefeed
                end try
                try
                    set threadBody to threadBody & "SUBJECT:" & (subject of msg) & linefeed
                on error
                    set threadBody to threadBody & "SUBJECT:" & baseSubject & linefeed
                end try
                try
                    set threadBody to threadBody & "DATE:" & (date sent of msg as string) & linefeed
                on error
                    set threadBody to threadBody & "DATE:Unknown" & linefeed
                end try
                set threadBody to threadBody & "BODY_START" & linefeed
                try
                    set threadBody to threadBody & (content of msg) & linefeed
                on error
                    set threadBody to threadBody & "(unable to read body)" & linefeed
                end try
                set threadBody to threadBody & "BODY_END" & linefeed
                set threadBody to threadBody & "---END_MESSAGE---" & linefeed
            end repeat
        end tell
    end if

    set output to "COMPOSER" & linefeed
    set output to output & "SUBJECT:" & composeSubject & linefeed
    set output to output & "TO:" & recipientList & linefeed
    set output to output & "FRAME:" & composeWinL & "," & composeWinT & "," & composeWinR & "," & composeWinB & linefeed
    set output to output & "DRAFT_START" & linefeed
    set output to output & draftContent & linefeed
    set output to output & "DRAFT_END" & linefeed
    set output to output & "---END_COMPOSER---" & linefeed
    set output to output & threadBody
    return output
    """

    /// Second-chance thread lookup, scoped to a known participant set.
    ///
    /// `fetchComposerContext` anchors the thread to the message selected in
    /// the viewer. When that selection has moved on — the user clicked
    /// another row after hitting Reply — there is no anchor, and the script
    /// deliberately emits no thread rather than guessing from the subject.
    /// Once the Accessibility reader has recovered the compose window's real
    /// recipients, this runs the same participant-scoped search using them,
    /// so the thread is still bounded by who is actually on the reply.
    ///
    /// Emits only `---END_MESSAGE---` blocks, matching the thread half of
    /// `fetchComposerContext`'s output.
    static func fetchThread(baseSubject: String, participants: [String]) -> String {
        let subjectLiteral = appleScriptString(baseSubject)
        let participantList = participants
            .map(appleScriptString)
            .joined(separator: ", ")
        return """
        set baseSubject to \(subjectLiteral)
        set participantAddrs to {\(participantList)}
        set output to ""
        set threadMsgs to {}
        set seenIDs to {}

        tell application "Mail"
            set scanned to 0
            try
                repeat with acct in accounts
                    repeat with mbName in {"INBOX", "Sent Messages", "Sent", "Gesendet", "Archive", "Archiv", "All Mail"}
                        try
                            set mb to mailbox mbName of acct
                            repeat with msg in (every message of mb whose subject contains baseSubject)
                                if scanned > 300 then exit repeat
                                set scanned to scanned + 1
                                try
                                    set thisID to (message id of msg)
                                    if seenIDs does not contain thisID then
                                        set msgSender to ""
                                        try
                                            set msgSender to (sender of msg)
                                        end try
                                        set msgRecipientText to ""
                                        try
                                            repeat with r in to recipients of msg
                                                set msgRecipientText to msgRecipientText & (address of r) & ", "
                                            end repeat
                                        end try
                                        try
                                            repeat with r in cc recipients of msg
                                                set msgRecipientText to msgRecipientText & (address of r) & ", "
                                            end repeat
                                        end try
                                        set isParticipant to false
                                        repeat with recAddr in participantAddrs
                                            set aStr to (recAddr as string)
                                            if aStr is not "" then
                                                if msgSender contains aStr then set isParticipant to true
                                                if msgRecipientText contains aStr then set isParticipant to true
                                            end if
                                        end repeat
                                        if isParticipant then
                                            set end of seenIDs to thisID
                                            set end of threadMsgs to (contents of msg)
                                        end if
                                    end if
                                end try
                            end repeat
                        end try
                    end repeat
                end repeat
            end try

            set msgCount to count of threadMsgs
            if msgCount > 20 then
                set threadMsgs to items (msgCount - 19) thru msgCount of threadMsgs
            end if

            repeat with msg in threadMsgs
                try
                    set output to output & "FROM:" & (sender of msg) & linefeed
                on error
                    set output to output & "FROM:unknown" & linefeed
                end try
                try
                    set rList to ""
                    repeat with r in to recipients of msg
                        if rList is not "" then set rList to rList & ", "
                        set rList to rList & (address of r)
                    end repeat
                    set output to output & "TO:" & rList & linefeed
                on error
                    set output to output & "TO:unknown" & linefeed
                end try
                try
                    set output to output & "SUBJECT:" & (subject of msg) & linefeed
                on error
                    set output to output & "SUBJECT:" & baseSubject & linefeed
                end try
                try
                    set output to output & "DATE:" & (date sent of msg as string) & linefeed
                on error
                    set output to output & "DATE:Unknown" & linefeed
                end try
                set output to output & "BODY_START" & linefeed
                try
                    set output to output & (content of msg) & linefeed
                on error
                    set output to output & "(unable to read body)" & linefeed
                end try
                set output to output & "BODY_END" & linefeed
                set output to output & "---END_MESSAGE---" & linefeed
            end repeat
        end tell
        return output
        """
    }

    /// Wrap a Swift string as an AppleScript string literal, escaping the
    /// characters that would otherwise terminate or re-open it.
    private static func appleScriptString(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }

    /// Write the generated reply into the current compose window.
    /// Mail-scripting-only path: set `content of outgoing message 1`. If that
    /// fails (no outgoing message visible to the API), fall back to placing
    /// the text on the clipboard + activating Mail so the user can paste.
    static func insertReply(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let lines = escaped.components(separatedBy: "\n")
        let asString = lines.joined(separator: "\" & return & \"")
        return """
        set insertedViaAPI to false
        tell application "Mail"
            try
                if (count of outgoing messages) > 0 then
                    set outMsg to outgoing message 1
                    set oldContent to ""
                    try
                        set oldContent to content of outMsg
                    end try
                    set content of outMsg to "\(asString)" & return & return & oldContent
                    set insertedViaAPI to true
                end if
            on error errMsg
                -- fall through
            end try
            activate
        end tell

        if not insertedViaAPI then
            set the clipboard to "\(asString)"
        end if
        return "OK"
        """
    }

    static let checkMailRunning = """
    tell application "System Events"
        return (name of processes) contains "Mail"
    end tell
    """
}
