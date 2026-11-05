import Foundation
import CoreGraphics
import ImageIO

/// A decoded, oriented thumbnail. Decode on a worker; the main thread only
/// retains and draws the already decoded CGImage.
public final class ComposeImageAsset: @unchecked Sendable {
  public let id = UUID()
  public let image: CGImage
  public let originalSize: CGSize
  public var cost: Int { image.bytesPerRow * image.height }

  private init(image: CGImage, originalSize: CGSize) {
    self.image = image
    self.originalSize = originalSize
  }

  public enum Failure: Error, LocalizedError {
    case invalid, unsupported, dimensions, decode
    public var errorDescription: String? {
      switch self {
      case .invalid: return "Image data is invalid or exceeds 16 MiB"
      case .unsupported: return "Image format is unsupported; use PNG or JPEG"
      case .dimensions: return "Image exceeds the source dimension or pixel limit"
      case .decode: return "Image could not be decoded"
      }
    }
  }

  /// Bounds compressed bytes, original dimensions/pixels, and decoded output.
  /// Image I/O's thumbnail path avoids allocating the full source bitmap.
  public static func decode(_ bytes: Data, maximumDimension: Int = 2048) throws -> ComposeImageAsset {
    guard !bytes.isEmpty, bytes.count <= ComposeAssetReceiver.maximumBytes,
          let source = CGImageSourceCreateWithData(bytes as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { throw Failure.invalid }
    let type = CGImageSourceGetType(source) as String?
    guard type == "public.png" || type == "public.jpeg" else { throw Failure.unsupported }
    guard let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = values[kCGImagePropertyPixelWidth] as? NSNumber,
          let h = values[kCGImagePropertyPixelHeight] as? NSNumber else { throw Failure.invalid }
    let width = w.doubleValue, height = h.doubleValue
    guard width.isFinite, height.isFinite, width > 0, height > 0,
          width <= 32_768, height <= 32_768, width * height <= 80_000_000 else { throw Failure.dimensions }
    let orientation = (values[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let size = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    let dimension = min(2048, max(1, maximumDimension))
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: dimension,
    ] as CFDictionary), image.width <= dimension, image.height <= dimension else { throw Failure.decode }
    return ComposeImageAsset(image: image, originalSize: size)
  }
}

public enum ComposeImageState {
  case loading
  case ready(ComposeImageAsset)
  case failed(String)

  public func size(body: CGFloat, width: CGFloat, block: Bool) -> CGSize {
    let maxWidth = block ? width : min(width, body * 8)
    let maxHeight = block ? CGFloat(480) : body * 6
    switch self {
    case .ready(let asset):
      let scale = min(1, maxWidth / asset.originalSize.width, maxHeight / asset.originalSize.height)
      return CGSize(width: max(1, asset.originalSize.width * scale), height: max(1, asset.originalSize.height * scale))
    default:
      return CGSize(width: min(maxWidth, block ? 360 : body * 4), height: min(maxHeight, block ? 150 : body * 2))
    }
  }
}
