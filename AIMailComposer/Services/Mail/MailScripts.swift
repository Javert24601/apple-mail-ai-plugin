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
    /// ## Why the thread is one message, not a mailbox search
    ///
    /// Matching on `subject contains baseSubject` treats every message
    /// sharing a phrase as one conversation. For a subject reused across
    /// unrelated correspondences — a property address written to a
    /// solicitor, an estate agent and a broker in separate threads — that
    /// pulls all of them into the model's context.
    ///
    /// Narrowing that sweep by participant was worse: every candidate needed
    /// `message id`, `sender` and `recipients` read off it, and each read is
    /// a synchronous Apple Event. Across seven mailboxes per account it ran
    /// to thousands of round trips and left Mail unresponsive.
    ///
    /// So no search happens at all. The thread is step 3's message — the one
    /// being replied to — whose body already embeds the quoted chain that the
    /// reply window cites. `QuotedThreadParser` splits that chain back into
    /// individual messages in Swift, with no further calls into Mail.
    ///
    /// If no anchor message can be found, **no thread is emitted**: wrong
    /// context is worse than none, because the model silently drafts replies
    /// grounded in someone else's conversation.
    ///
    /// Every block that talks to Mail is wrapped in `with timeout`, so a busy
    /// or stalled Mail surfaces as an AppleScript error instead of hanging
    /// the panel on its loading state.
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

    with timeout of 10 seconds
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
    end timeout

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

    -- Resolve the message being replied to and emit it as the whole thread.
    --
    -- Its body already contains the quoted chain, which is the context cited
    -- in the reply window, so one message is all we need. Earlier revisions
    -- swept every mailbox for subject matches and then read properties off
    -- each hit; every such read is a synchronous Apple Event, and across
    -- seven mailboxes per account that ran into the thousands and left Mail
    -- unresponsive. Read exactly one message instead.
    --
    -- "New Message" is Mail's placeholder title for an empty compose window.
    if baseSubject is not "" and baseSubject is not "New Message" then
        with timeout of 10 seconds
            tell application "Mail"
                -- The viewer selection is only trusted when its subject
                -- matches the compose window's, so an unrelated highlighted
                -- row can never become the context.
                --
                -- Take the *newest* match, never the first. In conversation
                -- view Mail hands back every message of the thread, and the
                -- first one is typically the oldest — anchoring on it cites
                -- only the conversation up to that point, so the model
                -- answers a months-old message instead of the latest.
                set anchorMsg to missing value
                set anchorDate to missing value
                try
                    repeat with m in (get selection)
                        try
                            if (subject of m) contains baseSubject then
                                set thisDate to (date sent of m)
                                if anchorDate is missing value or thisDate > anchorDate then
                                    set anchorMsg to (contents of m)
                                    set anchorDate to thisDate
                                end if
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
                                            set thisDate to (date sent of m)
                                            if anchorDate is missing value or thisDate > anchorDate then
                                                set anchorMsg to (contents of m)
                                                set anchorDate to thisDate
                                            end if
                                        end if
                                    end try
                                end repeat
                            end try
                        end repeat
                    end try
                end if

                if anchorMsg is not missing value then
                    -- Mail can't report a hand-opened compose window's
                    -- recipients. Reconstruct who the reply goes to from the
                    -- anchor: its sender plus its other recipients, minus our
                    -- own accounts.
                    if recipientList is "" then
                        set replyAddrs to {}
                        try
                            set end of replyAddrs to (extract address from (sender of anchorMsg))
                        end try
                        try
                            repeat with r in to recipients of anchorMsg
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

                    try
                        set threadBody to threadBody & "FROM:" & (sender of anchorMsg) & linefeed
                    on error
                        set threadBody to threadBody & "FROM:unknown" & linefeed
                    end try
                    try
                        set rList to ""
                        repeat with r in to recipients of anchorMsg
                            if rList is not "" then set rList to rList & ", "
                            set rList to rList & (address of r)
                        end repeat
                        set threadBody to threadBody & "TO:" & rList & linefeed
                    on error
                        set threadBody to threadBody & "TO:unknown" & linefeed
                    end try
                    try
                        set threadBody to threadBody & "SUBJECT:" & (subject of anchorMsg) & linefeed
                    on error
                        set threadBody to threadBody & "SUBJECT:" & baseSubject & linefeed
                    end try
                    try
                        set threadBody to threadBody & "DATE:" & (date sent of anchorMsg as string) & linefeed
                    on error
                        set threadBody to threadBody & "DATE:Unknown" & linefeed
                    end try
                    set threadBody to threadBody & "BODY_START" & linefeed
                    try
                        set threadBody to threadBody & (content of anchorMsg) & linefeed
                    on error
                        set threadBody to threadBody & "(unable to read body)" & linefeed
                    end try
                    set threadBody to threadBody & "BODY_END" & linefeed
                    set threadBody to threadBody & "---END_MESSAGE---" & linefeed
                end if
            end tell
        end timeout
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
