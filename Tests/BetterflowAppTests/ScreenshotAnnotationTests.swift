import CoreGraphics
import Testing

@testable import BetterflowApp

@Test
func screenshotAppearanceUsesImageLuminance() throws {
  #expect(screenshotIsMostlyDark(try solidImage(gray: 0.08)))
  #expect(!screenshotIsMostlyDark(try solidImage(gray: 0.92)))
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
