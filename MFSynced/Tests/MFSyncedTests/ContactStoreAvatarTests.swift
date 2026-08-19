import AppKit
import XCTest
@testable import MFSynced

/// The catalog wire caps a photo at 100 KiB of base64. Contacts can hand back
/// 320px+ thumbnails (~80 KB raw → >100 KiB encoded), which used to be dropped
/// silently — a real contact photo never reached the console. `avatarJPEG`
/// must bring ANY source image down to a small square.
final class ContactStoreAvatarTests: XCTestCase {
    private func noisyImage(_ edge: Int) -> NSImage {
        // High-entropy content so JPEG can't trivially compress it away — the
        // size bound must come from the downscale, not from a flat fill.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        var rng = SystemRandomNumberGenerator()
        for y in 0..<edge {
            for x in 0..<edge {
                rep.setColor(
                    NSColor(red: CGFloat.random(in: 0...1, using: &rng),
                            green: CGFloat.random(in: 0...1, using: &rng),
                            blue: CGFloat.random(in: 0...1, using: &rng), alpha: 1),
                    atX: x, y: y)
            }
        }
        let img = NSImage(size: NSSize(width: edge, height: edge))
        img.addRepresentation(rep)
        return img
    }

    func testLargeThumbnailIsDownscaledWellUnderTheCatalogCap() throws {
        let big = noisyImage(400)
        let jpeg = try XCTUnwrap(ContactStore.avatarJPEG(from: big))
        let b64 = jpeg.base64EncodedString().utf8.count
        XCTAssertLessThan(b64, CRMSyncService.catalogMaxPhotoBase64Length / 2,
                          "a 400px noisy source must land far under the cap after downscale")
        // Decodes back to the avatar square.
        let out = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertEqual(out.pixelsWide, Int(ContactStore.avatarEdge))
        XCTAssertEqual(out.pixelsHigh, Int(ContactStore.avatarEdge))
    }

    func testNonSquareSourceIsAspectFilledNotStretched() throws {
        let wide = noisyImage(300)
        // Pretend it's 300x100 by resizing the NSImage's logical size.
        wide.size = NSSize(width: 300, height: 100)
        let jpeg = try XCTUnwrap(ContactStore.avatarJPEG(from: wide))
        let out = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertEqual(out.pixelsWide, 128)
        XCTAssertEqual(out.pixelsHigh, 128)
    }
}
