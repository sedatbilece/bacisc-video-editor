import Foundation

/// The app version as x.y.z.DDMMYY (marketing version + build date), set by `scripts/set-version.sh`.
enum AppVersion {
    static var number: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing).\(build)"
    }

    /// "v0.0.1.131026"
    static var display: String { "v\(number)" }
}
