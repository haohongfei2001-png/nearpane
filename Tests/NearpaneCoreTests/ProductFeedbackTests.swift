import Foundation
import Testing
@testable import NearpaneCore

@Suite("Nearpane feedback content")
struct ProductFeedbackTests {
    @Test func productAndPreviewAreExplicitWithOptionalSystemVersion() throws {
        var content = ProductFeedbackContent()
        content.area = .screenshots
        content.text = "托盘展开后希望保留选中位置。"
        let preview = try content.preview(appVersion: "5.9", systemVersion: "27.0.1", revision: 8)
        #expect(preview.body == "product=Nearpane\ncomponent=screenshots\nmacOS=not-included\n\n托盘展开后希望保留选中位置。")
        #expect(preview.appVersion == "5.9")
        #expect(preview.revision == 8)
        #expect(ProductFeedbackContent.restore(body: preview.body, kind: preview.kind) == content)
        content.includeSystemVersion = true
        let consented = try content.preview(appVersion: "5.9", systemVersion: "27.0.1", revision: 9)
        #expect(consented.body.contains("macOS=27.0.1"))
        #expect(ProductFeedbackContent.restore(body: consented.body, kind: consented.kind) == content)
    }

    @Test func bodyLimitsIncludeProductMetadataAndRejectEmptyContent() {
        var content = ProductFeedbackContent()
        #expect(throws: ProductFeedbackError.empty) { try content.preview(appVersion: "5.9", systemVersion: "27", revision: 0) }
        content.text = String(repeating: "字", count: 4000)
        #expect(throws: ProductFeedbackError.tooLong) { try content.preview(appVersion: "5.9", systemVersion: "27", revision: 1) }
        content.text = String(repeating: "😀", count: 3950)
        #expect(throws: ProductFeedbackError.tooLong) { try content.preview(appVersion: "5.9", systemVersion: "27", revision: 1) }
    }

    @Test func environmentCannotInjectPathsAndUnknownDraftsRemainReadable() throws {
        var content = ProductFeedbackContent()
        content.includeSystemVersion = true
        content.text = "合成反馈\n\nproduct=Other"
        let value = try content.preview(appVersion: "/Users/private/version", systemVersion: "27\n/private/path", revision: 3)
        #expect(value.appVersion == "0")
        #expect(value.body.hasPrefix("product=Nearpane\ncomponent=general\nmacOS=0\n\n"))
        #expect(!value.body.contains("/private/path"))
        #expect(ProductFeedbackContent.restore(body: "原有未提交草稿", kind: .suggestion).text == "原有未提交草稿")
    }
}
