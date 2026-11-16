import CoreImage
import UIKit

extension Grade {
    static func uiImage(_ image: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
