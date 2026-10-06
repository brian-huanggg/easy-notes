import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KindMarkdown

struct ImageImportTests {
    private func encoded(_ type: UTType) -> Data {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test func keepsPNGAndJPEGBytes() {
        let png = encoded(.png)
        #expect(ImageImport.normalized(png)?.ext == "png")
        #expect(ImageImport.normalized(png)?.data == png)
        let jpeg = encoded(.jpeg)
        #expect(ImageImport.normalized(jpeg)?.ext == "jpg")
    }

    @Test func reencodesOtherFormatsAsJPEG() throws {
        let result = try #require(ImageImport.normalized(encoded(.tiff)))
        #expect(result.ext == "jpg")
        #expect(result.data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func rejectsNonImages() {
        #expect(ImageImport.normalized(Data("not an image".utf8)) == nil)
        #expect(ImageImport.normalized(Data()) == nil)
    }

    @Test func stagesAFileWithTheRightExtension() throws {
        let staged = try #require(ImageImport.stage(encoded(.tiff)))
        defer { staged.cleanup() }
        #expect(staged.url.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: staged.url.path))
        staged.cleanup()
        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
    }
}
