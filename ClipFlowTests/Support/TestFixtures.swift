import Foundation
@testable import ClipFlow

extension RawClipboardCapture {
    static func fixture(
        _ content: String,
        at timestamp: TimeInterval = 0,
        sourceBundleID: String? = nil
    ) -> Self {
        .init(
            content: content,
            capturedAt: Date(timeIntervalSince1970: timestamp),
            sourceBundleID: sourceBundleID
        )
    }
}

extension CapturedText {
    static func fixture(
        _ content: String,
        at timestamp: TimeInterval = 0,
        sourceBundleID: String? = nil,
        category: ClipboardItem.Category = .english
    ) -> Self {
        .init(
            content: content,
            category: category,
            capturedAt: Date(timeIntervalSince1970: timestamp),
            sourceBundleID: sourceBundleID
        )
    }
}

extension ClipboardItem {
    static func fixture(
        content: String = "fixture",
        at timestamp: TimeInterval = 0,
        customCategoryID: UUID? = nil
    ) -> Self {
        .init(
            content: content,
            category: .english,
            customCategoryID: customCategoryID,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }
}

extension AIRequest {
    static func fixture(itemID: UUID = UUID()) -> Self {
        .init(
            itemID: itemID,
            operation: .summarize,
            text: "fixture",
            allowedCategories: []
        )
    }
}

extension PersistedCustomCategory {
    static func fixture(name: String, sortOrder: Int) -> Self {
        let now = Date(timeIntervalSince1970: 0)
        return .init(
            id: UUID(),
            name: name,
            prompt: "",
            sortOrder: sortOrder,
            isEnabled: true,
            createdAt: now,
            updatedAt: now
        )
    }
}
