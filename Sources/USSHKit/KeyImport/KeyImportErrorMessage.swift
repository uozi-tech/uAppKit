import Foundation

public nonisolated enum KeyImportErrorMessage {
    public static func message(for error: Error, fallback: String) -> String {
        let localized = error as? LocalizedError
        let nsError = error as NSError

        let description = firstNonEmpty(localized?.errorDescription, nsError.localizedDescription)
            ?? fallback
        let reason = firstNonEmpty(localized?.failureReason, nsError.localizedFailureReason)
        let suggestion = firstNonEmpty(
            localized?.recoverySuggestion,
            nsError.localizedRecoverySuggestion
        )

        var lines = [description]
        if let reason, reason != description {
            lines.append(String(localized: "原因：\(reason)", bundle: ModuleBundle.bundle))
        }
        if let suggestion {
            lines.append(String(localized: "建议：\(suggestion)", bundle: ModuleBundle.bundle))
        }
        return lines.joined(separator: "\n")
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }
}
