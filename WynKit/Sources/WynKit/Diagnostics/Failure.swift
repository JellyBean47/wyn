//
//  Failure.swift
//  Wyn
//
//  What broke, at which step, and what to try.
//
//  The app used to surface every failure as `error.localizedDescription` in a
//  dialog titled "Wyn". Two things were thrown away each time. The first is the
//  step: `runLaunch` is *given* "Opening Steam…" or "Launching Satisfactory…"
//  and shows it in the busy overlay, then drops it the moment the throw
//  happens — so the one dialog a person sees says what failed but never what
//  was being attempted. The second is the fix: `LocalizedError` has
//  `recoverySuggestion` and nothing ever read it.
//
//  Both matter more in a beta than in development, because the person reading
//  the dialog cannot look at the code to work out which call site threw.
//

import Foundation


public struct Failure: Equatable, Sendable {
    /// What Wyn was doing, in the words already shown in the busy overlay:
    /// "Opening Steam", "Launching Satisfactory", "Creating the bottle".
    public let step: String
    /// What went wrong.
    public let reason: String
    /// What to try, when we know something worth suggesting.
    public let hint: String?

    public var title: String { "\(step) didn't work" }

    /// One line for the diagnostics bundle, so the zip carries the failure it
    /// was exported for rather than arriving contextless.
    public var noteLine: String { "\(step) — \(reason)" }

    public init(step: String, reason: String, hint: String? = nil) {
        self.step = Failure.tidyStep(step)
        self.reason = reason
        self.hint = hint
    }

    public init(step: String, error: Error) {
        self.init(
            step: step,
            reason: Failure.reason(from: error),
            hint: (error as? LocalizedError)?.recoverySuggestion
        )
    }

    /// The busy overlay says "Opening Steam…"; a sentence wants "Opening Steam".
    private static func tidyStep(_ step: String) -> String {
        var trimmed = step.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("…") || trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? "That" : trimmed
    }

    /// Foundation's fallback — "The operation couldn't be completed.
    /// (NSPOSIXErrorDomain error 2.)" — tells a person nothing, and it is what
    /// most non-LocalizedError throws produce. Keep the domain and code, since
    /// they are worth something in a bug report, but say plainly that Wyn does
    /// not have a better explanation rather than dressing it up as one.
    public static func reason(from error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.isEmpty {
            return localized
        }
        let described = error.localizedDescription
        if described.contains("The operation couldn’t be completed")
            || described.contains("The operation couldn't be completed") {
            let ns = error as NSError
            return "Wyn has no detail for this one. The system reported "
                + "\(ns.domain) code \(ns.code)."
        }
        return described
    }
}
