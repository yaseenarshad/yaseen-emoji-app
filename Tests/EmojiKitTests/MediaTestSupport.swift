import AVFoundation
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import EmojiKit

// Small test files, made in the test. No test reads a file of the user.

/// Writes an H.264 video of `seconds` at 30 frames a second with `AVAssetWriter`: a color ramp, a moving
/// square and a light noise, so the GIF has real work to do.
func makeTestVideo(at url: URL, seconds: Double, width: Int = 640, height: Int = 360, fileType: AVFileType = .mp4) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let frames = Int(seconds * 30)
    var seed: UInt32 = 12345
    for index in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let phase = CGFloat(index) / CGFloat(max(frames, 1))
        for column in stride(from: 0, to: width, by: 8) {
            context.setFillColor(red: CGFloat(column) / CGFloat(width), green: phase, blue: 1 - phase, alpha: 1)
            context.fill(CGRect(x: column, y: 0, width: 8, height: height))
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: phase * CGFloat(width - 80), y: CGFloat(height) / 2 - 40, width: 80, height: 80))
        // A light noise: about 1 pixel in 50 changes in each frame, as in a real video.
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for _ in 0..<(width * height / 50) {
            seed = seed &* 1_103_515_245 &+ 12345
            let x = Int(seed >> 8) % width, y = Int(seed >> 4) % height
            pixels[y * row + x * 4] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

/// The bytes of a picture in one type: a white picture with `text` in big black letters, or noise.
func makeTestImage(width: Int, height: Int, type: UTType, text: String? = nil, noise: Bool = false, frames: Int = 1) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if noise, let pixels = context.data?.assumingMemoryBound(to: UInt32.self) {
        var seed: UInt32 = 99
        for index in 0..<(context.bytesPerRow / 4 * height) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = seed | 0xFF00_0000
        }
    }
    if let text {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(height) * 0.5, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
        context.textPosition = CGPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.3)
        CTLineDraw(line, context)
    }
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// The number of frames and the pixel size of the first frame of an image file.
func frameInfo(_ data: Data) -> (frames: Int, width: Int, height: Int) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (0, 0, 0) }
    return (CGImageSourceGetCount(source), properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
}
