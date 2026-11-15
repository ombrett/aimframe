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
    /// The noise is turned into an opaque, nearly mid-grey layer and blended softly, so it can only
    /// nudge each pixel a little lighter or darker and never shows up as white specks.
    private static func grain(_ image: CIImage, _ amount: CGFloat) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let size = max(1, max(image.extent.width, image.extent.height) / 1400)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: image.extent)
        let opaque = noise
            .transformed(by: CGAffineTransform(scaleX: size, y: size))
            .cropped(to: image.extent)
            .composited(over: black)
        let spread = amount * 4                      // how far from mid-grey the grain may go
        let grey = CIFilter.colorMatrix()
        grey.inputImage = opaque
        grey.rVector = CIVector(x: 0, y: spread, z: 0, w: 0)
        grey.gVector = CIVector(x: 0, y: spread, z: 0, w: 0)
        grey.bVector = CIVector(x: 0, y: spread, z: 0, w: 0)
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let level = 0.5 - 0.25 * spread
        grey.biasVector = CIVector(x: level, y: level, z: level, w: 0)
        guard let layer = grey.outputImage?.cropped(to: image.extent) else { return image }
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = layer
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: image.extent) ?? image
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
    static func average(_ image: CIImage, rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
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
        var colour: CGFloat = 0
        for row in 0..<3 {
            for col in 0..<3 {
                let cell = average(image, rect: CGRect(x: e.minX + e.width * CGFloat(col) / 3, y: e.minY + e.height * CGFloat(row) / 3,
                                                       width: e.width / 3, height: e.height / 3))
                let mx = max(cell.r, cell.g, cell.b), mn = min(cell.r, cell.g, cell.b)
                if mx > 0 { colour = max(colour, (mx - mn) / mx) }
            }
        }

        if light < 0.28 { return ("moody", "Scena scura: contrasto forte e ombre fredde") }
        if all.r > all.b * 1.25 { return ("golden", "Luce calda: la rendo più dorata") }
        if top.b > top.r * 1.15 { return ("teal", "Cielo in alto: azzurri profondi e toni caldi sul soggetto") }
        if colour < 0.18 { return ("film", "Colori tenui: resa morbida da pellicola") }
        return ("teal", "Luce neutra: il classico look da cinema")
    }

    // MARK: Photo frame

    /// Puts the photo on a white (1) or black (2) card with a caption underneath. 0 leaves it as it is.
    static func framed(_ image: CIImage, style: Int) -> CIImage {
        guard style == 1 || style == 2 else { return image }
        let e = image.extent
        let side = max(e.width, e.height)
        let margin = (side * 0.04).rounded(), bottom = (side * 0.11).rounded()
        let canvas = CGRect(x: 0, y: 0, width: e.width + 2 * margin, height: e.height + margin + bottom)
        let white = style == 1
        let paper = white ? CIColor(red: 0.97, green: 0.965, blue: 0.95) : CIColor(red: 0.04, green: 0.04, blue: 0.045)
        let card = CIImage(color: paper).cropped(to: canvas)
        let placed = image.transformed(by: CGAffineTransform(translationX: margin - e.minX, y: bottom - e.minY))
        var out = placed.composited(over: card)

        let text = CIFilter.textImageGenerator()
        text.text = "Shot on iPhone  ·  Aimframe"
        text.fontName = "HelveticaNeue-Medium"
        text.fontSize = Float(side * 0.017)
        text.scaleFactor = 1
        if let glyphs = text.outputImage {
            let ink: CGFloat = white ? 0.25 : 0.8
            let tint = CIFilter.colorMatrix()
            tint.inputImage = glyphs
            tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            tint.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            tint.biasVector = CIVector(x: ink, y: ink, z: ink, w: 0)
            if let caption = tint.outputImage {
                let t = caption.extent
                let moved = caption.transformed(by: CGAffineTransform(
                    translationX: (canvas.width - t.width) / 2 - t.minX,
                    y: (bottom - t.height) / 2 - t.minY))
                out = moved.composited(over: out)
            }
        }
        return out.cropped(to: canvas)
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
