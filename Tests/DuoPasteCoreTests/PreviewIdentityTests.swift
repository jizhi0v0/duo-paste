import Testing
@testable import DuoPasteCore

@Suite("PreviewIdentity")
struct PreviewIdentityTests {
    @Test("item id / kind / sha 变化时 identity 必须变化")
    func identityTracksPreviewSource() {
        let text = PreviewIdentity.make(itemID: "item-1", kindRawValue: "text", blobSHA256: nil)
        let image = PreviewIdentity.make(itemID: "item-1", kindRawValue: "image", blobSHA256: "sha-1")
        let anotherImage = PreviewIdentity.make(itemID: "item-1", kindRawValue: "image", blobSHA256: "sha-2")

        #expect(text != image)
        #expect(image != anotherImage)
    }
}
