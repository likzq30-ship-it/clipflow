import Foundation

struct PrivacyConfiguration: Equatable, Sendable {
    var excludedBundleIDs: Set<String>
    var maxUTF8Bytes: Int
    var detectsSensitiveContent: Bool

    static let standard = PrivacyConfiguration(
        excludedBundleIDs: [],
        maxUTF8Bytes: 1_048_576,
        detectsSensitiveContent: true
    )
}

enum PrivacyDecision: Equatable, Sendable {
    case allow
    case skip(PrivacySkipReason)
}

enum PrivacySkipReason: Equatable, Sendable {
    case excludedApplication
    case exceedsSizeLimit(actualBytes: Int, limitBytes: Int)
    case sensitive(SensitiveContentKind)
}

enum SensitiveContentKind: Equatable, Sendable {
    case privateKey
    case apiToken
    case paymentCard
}

struct PrivacyGuard: Sendable {
    let detector: SensitiveContentDetector

    func evaluate(
        _ capture: RawClipboardCapture,
        configuration: PrivacyConfiguration
    ) -> PrivacyDecision {
        if let sourceBundleID = capture.sourceBundleID,
           configuration.excludedBundleIDs.contains(sourceBundleID) {
            return .skip(.excludedApplication)
        }

        let actualBytes = capture.content.utf8.count
        if actualBytes > configuration.maxUTF8Bytes {
            return .skip(
                .exceedsSizeLimit(
                    actualBytes: actualBytes,
                    limitBytes: configuration.maxUTF8Bytes
                )
            )
        }

        if configuration.detectsSensitiveContent,
           let kind = detector.detect(in: capture.content) {
            return .skip(.sensitive(kind))
        }

        return .allow
    }
}
