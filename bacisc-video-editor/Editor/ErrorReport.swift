import AppKit
import Foundation
import SwiftUI

/// A user-facing error with copyable details for bug reports.
struct ErrorReport: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let details: String

    init(title: String, message: String, details: String) {
        self.title = title
        self.message = message
        self.details = Self.context + "\n\n" + details
    }

    init(title: String, error: any Error) {
        self.init(title: title, message: error.localizedDescription, details: Self.describe(error))
    }

    /// Title, message and details as one text.
    var fullText: String {
        "\(title)\n\(message)\n\n\(details)"
    }

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullText, forType: .string)
    }

    /// The error and its underlying errors (domain, code, reasons), then Swift's own description.
    static func describe(_ error: any Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 5 {
            lines.append("\(depth == 0 ? "Error" : "Underlying"): \(nsError.domain) \(nsError.code)")
            lines.append("  \(nsError.localizedDescription)")
            if let reason = nsError.localizedFailureReason { lines.append("  Reason: \(reason)") }
            if let suggestion = nsError.localizedRecoverySuggestion { lines.append("  Suggestion: \(suggestion)") }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        lines.append("Swift: \(String(reflecting: error))")
        return lines.joined(separator: "\n")
    }

    private static var context: String {
        """
            App: \(AppVersion.display)
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Date: \(Date().formatted(.iso8601))
            """
    }
}

/// Sheet showing one error report: message, selectable details, Copy and OK.
struct ErrorReportView: View {
    let report: ErrorReport
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(report.title)
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(report.message)
                .textSelection(.enabled)

            ScrollView {
                Text(report.details)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button(copied ? "Copied" : "Copy Details") {
                    report.copyToPasteboard()
                    copied = true
                }
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
