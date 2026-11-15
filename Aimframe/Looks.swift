import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// A colour grade: the "look" applied to a photo after the shot.
struct Look: Identifiable {
    let id: String
    let name: String
    let apply: (CIImage) -> CIImage
}

enum Grade {

    static let context = CIContext()

    // MARK: Building blocks

    /// Multiplies each colour channel (warmer = more red, less blue).
    private static func gains(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// Split toning: each channel is c0 + c1·x + c2·x², so shadows and highlights can lean different ways.
    private static func tone(_ image: CIImage, r: [CGFloat], g: [CGFloat], b: [CGFloat]) -> CIImage {
        let f = CIFilter.colorPolynomial()
        f.inputImage = image
        f.redCoefficients = CIVector(x: r[0], y: r[1], z: r[2], w: 0)
        f.greenCoefficients = CIVector(x: g[0], y: g[1], z: g[2], w: 0)
        f.blueCoefficients = CIVector(x: b[0], y: b[1], z: b[2], w: 0)
        f.alphaCoefficients = CIVector(x: 0, y: 1, z: 0, w: 0)
        return f.outputImage ?? image
    }

    private static func controls(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float = 0) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = saturation
        f.contrast = contrast
        f.brightness = brightness
        return f.outputImage ?? image
    }

    /// Five-point tone curve; `blacks` above 0 gives the lifted, faded shadows of film.
    private static func curve(_ image: CIImage, blacks: CGFloat, low: CGFloat, high: CGFloat, whites: CGFloat) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = image
        f.point0 = CGPoint(x: 0, y: blacks)
        f.point1 = CGPoint(x: 0.25, y: low)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: high)
        f.point4 = CGPoint(x: 1, y: whites)
        return f.outputImage ?? image
    }

    private static func vignette(_ image: CIImage, _ amount: Float) -> CIImage {
        let f = CIFilter.vignette()
        f.inputImage = image
        f.intensity = amount
        f.radius = 1.8
        return f.outputImage ?? image
    }

    /// Film grain, sized so it looks the same on the preview and on the full photo.
    private static func grain(_ image: CIImage, _ amount: CGFloat) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let size = max(1, max(image.extent.width, image.extent.height) / 1400)
        let mono = CIFilter.colorMatrix()
        mono.inputImage = noise.transformed(by: CGAffineTransform(scaleX: size, y: size))
        mono.rVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        mono.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        mono.bVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: 0, y: 0, z: 0, w: amount)
        guard let speckle = mono.outputImage?.cropped(to: image.extent) else { return image }
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = speckle
        over.backgroundImage = image
        return over.outputImage ?? image
    }

    // MARK: The looks

    static let looks: [Look] = [
        Look(id: "teal", name: "Teal & Orange") { image in
            var i = tone(image, r: [-0.02, 0.95, 0.10], g: [0, 1, 0], b: [0.035, 1.0, -0.085])
            i = controls(i, saturation: 1.08, contrast: 1.06)
            i = curve(i, blacks: 0.02, low: 0.21, high: 0.80, whites: 0.98)
            i = vignette(i, 0.6)
            return grain(i, 0.035)
        },
        Look(id: "golden", name: "Golden Hour") { image in
            var i = gains(image, r: 1.07, g: 1.01, b: 0.90)
            i = controls(i, saturation: 1.10, contrast: 1.03)
            i = curve(i, blacks: 0.03, low: 0.23, high: 0.79, whites: 0.98)
            i = vignette(i, 0.4)
            return grain(i, 0.03)
        },
        Look(id: "film", name: "Pellicola") { image in
            var i = gains(image, r: 1.03, g: 1.0, b: 0.97)
            i = controls(i, saturation: 0.86, contrast: 0.97)
            i = curve(i, blacks: 0.07, low: 0.24, high: 0.77, whites: 0.95)
            i = vignette(i, 0.35)
            return grain(i, 0.06)
        },
        Look(id: "moody", name: "Moody") { image in
            var i = tone(image, r: [-0.015, 1.0, 0], g: [0, 1, 0], b: [0.02, 1.0, -0.02])
            i = controls(i, saturation: 0.80, contrast: 1.14, brightness: -0.03)
            i = curve(i, blacks: 0.01, low: 0.19, high: 0.80, whites: 0.97)
            i = vignette(i, 1.0)
            return grain(i, 0.05)
        },
        Look(id: "clean", name: "Pulito") { image in
            var i = controls(image, saturation: 1.05, contrast: 1.04)
            i = curve(i, blacks: 0.0, low: 0.24, high: 0.77, whites: 1.0)
            return vignette(i, 0.2)
        },
        Look(id: "noir", name: "Noir") { image in
            var i = controls(image, saturation: 0, contrast: 1.2)
            i = curve(i, blacks: 0.02, low: 0.20, high: 0.80, whites: 0.98)
            i = vignette(i, 0.8)
            return grain(i, 0.07)
        }
    ]

    static func look(_ id: String) -> Look {
        looks.first(where: { $0.id == id }) ?? looks[0]
    }

    /// The photo with a look applied at 0...1 strength.
    static func render(_ base: CIImage, look: Look, intensity: CGFloat) -> CIImage {
        let graded = look.apply(base).cropped(to: base.extent)
        if intensity >= 0.999 { return graded }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = base
        mix.targetImage = graded
        mix.time = Float(max(0, intensity))
        return (mix.outputImage ?? graded).cropped(to: base.extent)
    }

    // MARK: Choosing a look

    /// Average colour of part of the picture, 0...1 per channel.
    private static func average(_ image: CIImage, rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = rect
        guard let out = f.outputImage else { return (0.5, 0.5, 0.5) }
        var px = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: space)
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }

    /// Picks the look that suits the light and colours of this photo, with the reason in plain words.
    static func recommend(_ image: CIImage) -> (id: String, reason: String) {
        let e = image.extent
        let all = average(image, rect: e)
        let top = average(image, rect: CGRect(x: e.minX, y: e.minY + e.height * 0.66, width: e.width, height: e.height * 0.34))
        let light = (all.r + all.g + all.b) / 3
        let mx = max(all.r, all.g, all.b), mn = min(all.r, all.g, all.b)
        let colour = mx > 0 ? (mx - mn) / mx : 0

        if light < 0.28 { return ("moody", "Scena scura: contrasto forte e ombre fredde") }
        if all.r > all.b * 1.25 { return ("golden", "Luce calda: la rendo più dorata") }
        if top.b > top.r * 1.15 { return ("teal", "Cielo in alto: azzurri profondi e toni caldi sul soggetto") }
        if colour < 0.12 { return ("film", "Colori tenui: resa morbida da pellicola") }
        return ("teal", "Luce neutra: il classico look da cinema")
    }

    // MARK: Helpers

    static func scaled(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let k = min(1, maxSide / max(image.extent.width, image.extent.height, 1))
        if k >= 1 { return image }
        return image.transformed(by: CGAffineTransform(scaleX: k, y: k))
    }

    static func uiImage(_ image: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
