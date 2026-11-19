import SwiftUI
import Testing
@testable import Ghast

@Suite("TartImagePicker auto-pick")
struct TartImagePickerTests {
    private let versions = TartXcodeVersions(tags: ["27.2", "26.4"], source: .loaded)

    @Test("the New Runner sheet picks the newest Xcode for an empty image")
    func picksWhenAllowed() {
        let ref = TartImagePicker<EmptyView>.newestImage(current: "", isCustom: false, wantsXcode: true, autoPicks: true, macOS: .tahoe, versions: versions)
        #expect(ref == TartImageCatalog.ref(macOS: .tahoe, xcode: "27.2"))
    }

    @Test("the Configuration tab never changes the image on its own", arguments: ["", "saved-image"])
    func neverWhenNotAllowed(current: String) {
        let ref = TartImagePicker<EmptyView>.newestImage(current: current, isCustom: false, wantsXcode: true, autoPicks: false, macOS: .tahoe, versions: versions)
        #expect(ref == nil)
    }

    @Test("a non-empty image, custom mode or a base-image choice is left alone")
    func leavesChoicesAlone() {
        #expect(TartImagePicker<EmptyView>.newestImage(current: "x", isCustom: false, wantsXcode: true, autoPicks: true, macOS: .tahoe, versions: versions) == nil)
        #expect(TartImagePicker<EmptyView>.newestImage(current: "", isCustom: true, wantsXcode: true, autoPicks: true, macOS: .tahoe, versions: versions) == nil)
        #expect(TartImagePicker<EmptyView>.newestImage(current: "", isCustom: false, wantsXcode: false, autoPicks: true, macOS: .tahoe, versions: versions) == nil)
    }
}
