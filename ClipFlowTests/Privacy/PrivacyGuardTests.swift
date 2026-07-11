import XCTest
@testable import ClipFlow

final class PrivacyGuardTests: XCTestCase {
    private let guardrail = PrivacyGuard(detector: SensitiveContentDetector())

    func testStandardConfigurationUsesOneMiBAndSensitiveDetection() {
        XCTAssertEqual(PrivacyConfiguration.standard.excludedBundleIDs, [])
        XCTAssertEqual(PrivacyConfiguration.standard.maxUTF8Bytes, 1_048_576)
        XCTAssertTrue(PrivacyConfiguration.standard.detectsSensitiveContent)
    }

    func testExcludedApplicationTakesPrecedenceOverSizeAndSensitiveInspection() {
        let capture = RawClipboardCapture.fixture(
            "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "x", count: 100),
            sourceBundleID: "com.password.manager"
        )
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: ["com.password.manager"],
            maxUTF8Bytes: 1,
            detectsSensitiveContent: true
        )

        XCTAssertEqual(
            guardrail.evaluate(capture, configuration: configuration),
            .skip(.excludedApplication)
        )
    }

    func testUTF8ByteLimitTakesPrecedenceOverSensitiveDetection() {
        let capture = RawClipboardCapture.fixture("-----BEGIN PRIVATE KEY-----")
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: [],
            maxUTF8Bytes: 5,
            detectsSensitiveContent: true
        )

        XCTAssertEqual(
            guardrail.evaluate(capture, configuration: configuration),
            .skip(
                .exceedsSizeLimit(
                    actualBytes: capture.content.utf8.count,
                    limitBytes: 5
                )
            )
        )
    }

    func testUsesUTF8BytesRatherThanCharacterCount() {
        let capture = RawClipboardCapture.fixture(String(repeating: "你", count: 4))
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: [],
            maxUTF8Bytes: 11,
            detectsSensitiveContent: false
        )

        XCTAssertEqual(
            guardrail.evaluate(capture, configuration: configuration),
            .skip(.exceedsSizeLimit(actualBytes: 12, limitBytes: 11))
        )
    }

    func testAllowsContentAtExactUTF8ByteLimit() {
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: [],
            maxUTF8Bytes: 12,
            detectsSensitiveContent: false
        )

        XCTAssertEqual(
            guardrail.evaluate(
                RawClipboardCapture.fixture(String(repeating: "你", count: 4)),
                configuration: configuration
            ),
            .allow
        )
    }

    func testSensitiveDetectionCanBeDisabled() {
        let configuration = PrivacyConfiguration(
            excludedBundleIDs: [],
            maxUTF8Bytes: 1_048_576,
            detectsSensitiveContent: false
        )

        XCTAssertEqual(
            guardrail.evaluate(
                RawClipboardCapture.fixture("-----BEGIN PRIVATE KEY-----\nsecret"),
                configuration: configuration
            ),
            .allow
        )
    }

    func testDetectsApprovedPrivateKeyMarkers() {
        let markers = [
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN OPENSSH PRIVATE KEY-----"
        ]

        for marker in markers {
            XCTAssertEqual(
                guardrail.evaluate(
                    RawClipboardCapture.fixture("header\n\(marker)\nsecret"),
                    configuration: .standard
                ),
                .skip(.sensitive(.privateKey)),
                marker
            )
        }
    }

    func testDetectsEveryApprovedTokenPrefix() {
        let body = String(repeating: "a", count: 20)
        let tokens = [
            "sk-\(body)",
            "ghp_\(body)",
            "github_pat_\(body)",
            "xoxb-\(body)",
            "xoxp-\(body)",
            "xoxa-\(body)",
            "xoxr-\(body)",
            "xoxs-\(body)",
            "AKIA1234567890ABCDEF"
        ]

        for token in tokens {
            XCTAssertEqual(
                guardrail.evaluate(
                    RawClipboardCapture.fixture("credential: \(token)."),
                    configuration: .standard
                ),
                .skip(.sensitive(.apiToken)),
                token
            )
        }
    }

    func testRejectsNineteenCharacterTokenBodies() {
        let shortBody = String(repeating: "a", count: 19)
        let prefixes = [
            "sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-"
        ]

        for prefix in prefixes {
            XCTAssertEqual(
                guardrail.evaluate(
                    RawClipboardCapture.fixture(prefix + shortBody),
                    configuration: .standard
                ),
                .allow,
                prefix
            )
        }
    }

    func testRejectsTokenBodyWithIllegalCharacterBeforeMinimumLength() {
        let invalid = "sk-" + String(repeating: "a", count: 10)
            + "." + String(repeating: "b", count: 10)

        XCTAssertEqual(
            guardrail.evaluate(RawClipboardCapture.fixture(invalid), configuration: .standard),
            .allow
        )
    }

    func testAWSAccessKeyRequiresExactlySixteenUppercaseAlphanumericCharacters() {
        let invalidValues = [
            "AKIA1234567890ABCDE",
            "AKIA1234567890ABCDEFG",
            "AKIA1234567890ABCDEf",
            "XAKIA1234567890ABCDEF"
        ]

        for value in invalidValues {
            XCTAssertEqual(
                guardrail.evaluate(
                    RawClipboardCapture.fixture(value),
                    configuration: .standard
                ),
                .allow,
                value
            )
        }
    }

    func testAcceptsLuhnValidPaymentCardWithSpaces() {
        XCTAssertEqual(
            guardrail.evaluate(
                RawClipboardCapture.fixture("4111 1111 1111 1111"),
                configuration: .standard
            ),
            .skip(.sensitive(.paymentCard))
        )
    }

    func testRejectsSameLengthPaymentCardWhenLuhnFails() {
        XCTAssertEqual(
            guardrail.evaluate(
                RawClipboardCapture.fixture("4111 1111 1111 1112"),
                configuration: .standard
            ),
            .allow
        )
    }

    func testAcceptsThirteenAndNineteenDigitLuhnCandidates() {
        let candidates = [
            "4222-2222-2222-2",
            "4000 0000 0000 0000 006"
        ]

        for candidate in candidates {
            XCTAssertEqual(
                guardrail.evaluate(
                    RawClipboardCapture.fixture(candidate),
                    configuration: .standard
                ),
                .skip(.sensitive(.paymentCard)),
                candidate
            )
        }
    }

    func testRejectsLuhnValidCandidatesOutsideDigitBounds() {
        let candidates = [
            String(repeating: "0", count: 12),
            String(repeating: "0", count: 20)
        ]

        for candidate in candidates {
            XCTAssertEqual(
                guardrail.evaluate(
                    RawClipboardCapture.fixture(candidate),
                    configuration: .standard
                ),
                .allow,
                candidate
            )
        }
    }
}
