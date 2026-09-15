import AppKit
import Testing

@testable import BetterflowApp

@Test
func screenshotAppearanceUsesImageLuminance() throws {
  #expect(screenshotIsMostlyDark(try solidImage(gray: 0.08)))
  #expect(!screenshotIsMostlyDark(try solidImage(gray: 0.92)))
}

@Test
func overlappingFocusRectanglesRemainAdditivelyFocused() throws {
  let width = 24
  let height = 8
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  context.setFillColor(NSColor.white.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))

  drawFocusDimming(
    in: context,
    bounds: CGRect(x: 0, y: 0, width: width, height: height),
    focusedRects: [
      CGRect(x: 3, y: 1, width: 9, height: 6),
      CGRect(x: 9, y: 1, width: 9, height: 6),
    ]
  )

  let image = try #require(context.makeImage())
  #expect(try pixelBrightness(in: image, x: 1, y: 4) < 0.6)
  #expect(try pixelBrightness(in: image, x: 5, y: 4) > 0.9)
  #expect(try pixelBrightness(in: image, x: 10, y: 4) > 0.9)
  #expect(try pixelBrightness(in: image, x: 16, y: 4) > 0.9)
}

@Test
func screenshotBlurSmoothsAHardEdge() throws {
  let image = try hardEdgeImage()
  let blurred = try #require(makeBlurredScreenshot(image, radius: 6))
  let brightness = try pixelBrightness(in: blurred, x: 31, y: 4)

  #expect(brightness > 0.1)
  #expect(brightness < 0.9)
}

private func solidImage(gray: CGFloat) throws -> CGImage {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let context = try #require(
    CGContext(
      data: nil,
      width: 16,
      height: 16,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  let color = try #require(
    CGColor(colorSpace: colorSpace, components: [gray, gray, gray, 1])
  )
  context.setFillColor(color)
  context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
  return try #require(context.makeImage())
}

private func hardEdgeImage() throws -> CGImage {
  let context = try #require(
    CGContext(
      data: nil,
      width: 64,
      height: 8,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  context.setFillColor(NSColor.black.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: 32, height: 8))
  context.setFillColor(NSColor.white.cgColor)
  context.fill(CGRect(x: 32, y: 0, width: 32, height: 8))
  return try #require(context.makeImage())
}

private func pixelBrightness(in image: CGImage, x: Int, y: Int) throws -> Double {
  let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
  var pixel = [UInt8](repeating: 0, count: 4)
  let rendered = pixel.withUnsafeMutableBytes { bytes in
    guard let context = CGContext(
      data: bytes.baseAddress,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return false }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return true
  }
  try #require(rendered)
  return (
    0.2126 * Double(pixel[0])
      + 0.7152 * Double(pixel[1])
      + 0.0722 * Double(pixel[2])
  ) / 255
}
