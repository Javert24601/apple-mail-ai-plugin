import Foundation

struct EmailThread {
    let subject: String
    /// Oldest first, so the last element is the message being replied to.
    let messages: [EmailMessage]
    /// The quoted chain exactly as it appears in the email, when available.
    ///
    /// Preferred for the model over the reassembled messages: the chain
    /// already carries its own attribution lines ("On … wrote:"), which state
    /// each author and date unambiguously, and a model reads them directly.
    /// Splitting it into `messages` means guessing where each attribution
    /// starts and re-deriving senders and dates — fine for rendering rows in
    /// the UI, but every guess is a chance to mislabel who said what. Sending
    /// the original text keeps that risk out of the prompt.
    let rawChain: String?

    init(subject: String, messages: [EmailMessage], rawChain: String? = nil) {
        self.subject = subject
        self.messages = messages
        self.rawChain = rawChain
    }

    /// The thread as the model should see it. Newest message is called out
    /// explicitly — with or without parseable dates, the reply has to answer
    /// the latest message, and leaving that to be inferred is how it ends up
    /// answering a months-old one.
    func formatted() -> String {
        if let rawChain, !rawChain.isEmpty {
            return """
            The most recent message appears FIRST, with older messages quoted \
            beneath it, each under its own "On … wrote:" attribution line.

            \(rawChain)
            """
        }

        let total = messages.count
        return messages.enumerated().map { index, msg in
            let position = index + 1
            let label = position == total
                ? "Message \(position) of \(total) — MOST RECENT, this is the one to answer"
                : "Message \(position) of \(total)"
            return """
            [\(label)]
            From: \(msg.sender)
            Date: \(msg.formattedDate)

            \(msg.body)
            """
        }.joined(separator: "\n---\n")
    }
}
