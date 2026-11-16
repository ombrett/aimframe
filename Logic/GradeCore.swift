import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// A colour grade: the "look" applied to a photo after the shot.
struct Look: Identifiable {
    let id: String
    let name: String
    /// Whether skin tones and bright highlights are partly kept from the original (not for black and white).
    let protects: Bool
    let apply: (CIImage) -> CIImage
}

/// A light correction measured on a small copy of the photo and applied the same way to the preview
/// and the full-size export, so both match. Zero means "leave it as it is".
struct LightFix: Equatable {
    var exposure: Double = 0      // stops of brightening (0...1.3)
    var shadows: Double = 0       // shadow lift (0...0.7)

    var isZero: Bool { exposure < 0.01 && shadows < 0.01 }
}

/// Why a look was suggested: measured values, and the rule that used them. No generative analysis.
struct LookAdvice {
    let id: String
    let reason: String
    let brightness: Double      // 0...1 average
    let warmth: Double          // red / blue of the average colour
    let colourfulness: Double   // 0...1, strongest of 9 areas
}

enum Grade {

    static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: Building blocks

    /// Multiplies each colour channel (warmer = more red, less blue).
    static func gains(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
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
    static func tone(_ image: CIImage, r: [CGFloat], g: [CGFloat], b: [CGFloat]) -> CIImage {
        let f = CIFilter.colorPolynomial()
        f.inputImage = image
        f.redCoefficients = CIVector(x: r[0], y: r[1], z: r[2], w: 0)
        f.greenCoefficients = CIVector(x: g[0], y: g[1], z: g[2], w: 0)
        f.blueCoefficients = CIVector(x: b[0], y: b[1], z: b[2], w: 0)
        f.alphaCoefficients = CIVector(x: 0, y: 1, z: 0, w: 0)
        return f.outputImage ?? image
    }

    static func controls(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float = 0) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = saturation
        f.contrast = contrast
        f.brightness = brightness
        return f.outputImage ?? image
    }

    /// Five-point tone curve; `blacks` above 0 gives the lifted, faded shadows of film.
    static func curve(_ image: CIImage, blacks: CGFloat, low: CGFloat, high: CGFloat, whites: CGFloat) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = image
        f.point0 = CGPoint(x: 0, y: blacks)
        f.point1 = CGPoint(x: 0.25, y: low)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: high)
        f.point4 = CGPoint(x: 1, y: whites)
        return f.outputImage ?? image
    }

    /// Darkens the corners. Sized from the picture itself, so preview and full photo match.
    static func vignette(_ image: CIImage, _ amount: Float) -> CIImage {
        let e = image.extent
        let f = CIFilter.vignetteEffect()
        f.inputImage = image
        f.center = CGPoint(x: e.midX, y: e.midY)
        f.radius = Float(hypot(e.width, e.height) / 2 * 0.95)
        f.intensity = amount
        f.falloff = 0.45
        return f.outputImage?.cropped(to: e) ?? image
    }

    /// Film grain, sized so it looks the same on the preview and on the full photo.
    /// The noise is turned into an opaque, nearly mid-grey layer and blended softly, so it can only
    /// nudge each pixel a little lighter or darker and never shows up as white specks.
    static func grain(_ image: CIImage, _ amount: CGFloat) -> CIImage {
        guard amount > 0, let noise = CIFilter.randomGenerator().outputImage else { return image }
        let size = max(1, max(image.extent.width, image.extent.height) / 1400)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: image.extent)
        let opaque = noise
            .transformed(by: CGAffineTransform(scaleX: size, y: size))
            .cropped(to: image.extent)
            .composited(over: black)
        let spread = amount * 2.2                    // how far from mid-grey the grain may go
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

    // MARK: Protecting skin and highlights

    /// A colour cube that turns each colour into "how much to keep from the original":
    /// about half for skin tones, most of it for nearly white highlights.
    private static let protectCube: Data = {
        let n = 32
        var values = [Float](repeating: 0, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let R = Float(r) / Float(n - 1), G = Float(g) / Float(n - 1), B = Float(b) / Float(n - 1)
                    let mx = max(R, G, B), mn = min(R, G, B)
                    let sat = mx > 0 ? (mx - mn) / mx : 0
                    var hue: Float = 0
                    if mx > mn {
                        if mx == R { hue = (G - B) / (mx - mn) } else if mx == G { hue = 2 + (B - R) / (mx - mn) } else { hue = 4 + (R - G) / (mx - mn) }
                        hue *= 60
                        if hue < 0 { hue += 360 }
                    }
                    // Skin: orange-red hues, moderate saturation, not too dark.
                    let hueW = smooth(hue, 0, 8) * (1 - smooth(hue, 45, 60))
                    let satW = smooth(sat, 0.12, 0.2) * (1 - smooth(sat, 0.6, 0.75))
                    let valW = smooth(mx, 0.1, 0.22)
                    let skin = hueW * satW * valW
                    // Highlights: close to white.
                    let luma = 0.2126 * R + 0.7152 * G + 0.0722 * B
                    let high = smooth(luma, 0.86, 0.97)
                    let m = max(skin * 0.7, high * 0.8)
                    let i = (b * n * n + g * n + r) * 4
                    values[i] = m; values[i + 1] = m; values[i + 2] = m; values[i + 3] = 1
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    private static func smooth(_ x: Float, _ a: Float, _ b: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Mixes part of the original back where there is skin or near-white light.
    static func protect(_ graded: CIImage, original: CIImage) -> CIImage {
        // The cube is defined on ordinary (gamma-encoded) sRGB values, so it must be applied in sRGB,
        // not in Core Image's linear working space where dark skin looks far more saturated.
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = original
        cube.cubeDimension = 32
        cube.cubeData = protectCube
        cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let mask = cube.outputImage else { return graded }
        let mix = CIFilter.blendWithMask()
        mix.inputImage = original
        mix.backgroundImage = graded
        mix.maskImage = mask
        return mix.outputImage?.cropped(to: original.extent) ?? graded
    }

    // MARK: Light fix

    /// Measures brightness on a fixed 96-pixel copy (so preview and export measure the same thing).
    static func measureLight(_ image: CIImage) -> LightFix {
        let small = scaled(image, maxSide: 96)
        let e = small.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0 else { return LightFix() }
        var px = [Float](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: space)
        var lumas: [Float] = []
        lumas.reserveCapacity(w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            lumas.append(0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2])
        }
        lumas.sort()
        let median = Double(lumas[lumas.count / 2])
        let bright = Double(lumas[min(lumas.count - 1, lumas.count * 97 / 100)])
        var fix = LightFix()
        // Brighten towards a mid-tone median, but never so much that the bright parts burn.
        if median < 0.36 {
            let wanted = log2(0.42 / max(median, 0.04))
            let room = log2(0.97 / max(bright, 0.05))
            fix.exposure = max(0, min(1.3, min(wanted, max(room, 0) + 0.25)))
        }
        if median < 0.45 {
            fix.shadows = max(0, min(0.7, (0.45 - median) * 2.2))
        }
        return fix
    }

    static func applyLight(_ image: CIImage, _ fix: LightFix) -> CIImage {
        guard !fix.isZero else { return image }
        var out = image
        if fix.exposure > 0.01 {
            let ev = CIFilter.exposureAdjust()
            ev.inputImage = out
            ev.ev = Float(fix.exposure)
            out = ev.outputImage ?? out
            // Roll the brightest tones off gently instead of clipping them.
            out = curve(out, blacks: 0, low: 0.25, high: 0.74, whites: 0.97)
        }
        if fix.shadows > 0.01 {
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = out
            hs.shadowAmount = Float(fix.shadows)
            hs.highlightAmount = 1
            hs.radius = Float(max(image.extent.width, image.extent.height) / 200)
            out = hs.outputImage ?? out
        }
        return out.cropped(to: image.extent)
    }

    // MARK: The looks

    static let looks: [Look] = [
        Look(id: "teal", name: "Teal & Orange", protects: true) { image in
            var i = tone(image, r: [-0.006, 0.97, 0.045], g: [0, 1, 0], b: [0.014, 1.0, -0.045])
            i = controls(i, saturation: 1.05, contrast: 1.05)
            i = curve(i, blacks: 0.02, low: 0.225, high: 0.785, whites: 0.98)
            i = vignette(i, 0.2)
            return grain(i, 0.02)
        },
        Look(id: "golden", name: "Golden Hour", protects: true) { image in
            var i = gains(image, r: 1.05, g: 1.01, b: 0.92)
            i = controls(i, saturation: 1.08, contrast: 1.03)
            i = curve(i, blacks: 0.025, low: 0.235, high: 0.785, whites: 0.98)
            i = vignette(i, 0.15)
            return grain(i, 0.018)
        },
        Look(id: "film", name: "Pellicola", protects: true) { image in
            var i = gains(image, r: 1.025, g: 1.0, b: 0.975)
            i = controls(i, saturation: 0.88, contrast: 0.97)
            i = curve(i, blacks: 0.06, low: 0.245, high: 0.77, whites: 0.955)
            i = vignette(i, 0.15)
            return grain(i, 0.035)
        },
        Look(id: "moody", name: "Moody", protects: true) { image in
            var i = tone(image, r: [-0.012, 1.0, 0], g: [0, 1, 0], b: [0.016, 1.0, -0.016])
            i = controls(i, saturation: 0.84, contrast: 1.08, brightness: -0.01)
            i = curve(i, blacks: 0.015, low: 0.21, high: 0.785, whites: 0.97)
            i = vignette(i, 0.3)
            return grain(i, 0.03)
        },
        Look(id: "clean", name: "Pulito", protects: true) { image in
            var i = controls(image, saturation: 1.04, contrast: 1.04)
            i = curve(i, blacks: 0.0, low: 0.24, high: 0.77, whites: 1.0)
            return vignette(i, 0.06)
        },
        Look(id: "noir", name: "Noir", protects: false) { image in
            var i = controls(image, saturation: 0, contrast: 1.18)
            i = curve(i, blacks: 0.02, low: 0.2, high: 0.8, whites: 0.98)
            i = vignette(i, 0.3)
            return grain(i, 0.045)
        }
    ]

    static func look(_ id: String) -> Look {
        looks.first(where: { $0.id == id }) ?? looks[0]
    }

    /// The photo with the light fix and a look applied at 0...1 strength. 0 gives back the original unchanged.
    static func render(_ base: CIImage, look: Look, intensity: CGFloat, light: LightFix = LightFix()) -> CIImage {
        if intensity <= 0.001 { return base }
        let lit = applyLight(base, light)
        var graded = look.apply(lit).cropped(to: base.extent)
        if look.protects { graded = protect(graded, original: lit) }
        if intensity >= 0.999 { return graded }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = base
        mix.targetImage = graded
        mix.time = Float(intensity)
        return (mix.outputImage ?? graded).cropped(to: base.extent)
    }

    // MARK: Choosing a look

    /// Average colour of part of the picture, 0...1 per channel.
    static func average(_ image: CIImage, rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = rect
        guard let out = f.outputImage else { return (0.5, 0.5, 0.5) }
        var px = [Float](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return (CGFloat(px[0]), CGFloat(px[1]), CGFloat(px[2]))
    }

    /// Picks a look from measured light and colour, with a reason that names what was measured.
    static func recommend(_ image: CIImage) -> LookAdvice {
        let e = image.extent
        let all = average(image, rect: e)
        let top = average(image, rect: CGRect(x: e.minX, y: e.minY + e.height * 0.66, width: e.width, height: e.height * 0.34))
        let light = Double((all.r + all.g + all.b) / 3)
        let warmth = Double(all.r / max(all.b, 0.01))
        var colour: CGFloat = 0
        for row in 0..<3 {
            for col in 0..<3 {
                let cell = average(image, rect: CGRect(x: e.minX + e.width * CGFloat(col) / 3, y: e.minY + e.height * CGFloat(row) / 3,
                                                       width: e.width / 3, height: e.height / 3))
                let mx = max(cell.r, cell.g, cell.b), mn = min(cell.r, cell.g, cell.b)
                if mx > 0 { colour = max(colour, (mx - mn) / mx) }
            }
        }
        let pct = Int((light * 100).rounded())
        func advice(_ id: String, _ text: String) -> LookAdvice {
            LookAdvice(id: id, reason: text, brightness: light, warmth: warmth, colourfulness: Double(colour))
        }
        if light < 0.3 {
            // A dark photo needs light, not a darker look: it is brightened first, then kept clean.
            return advice("clean", "Foto scura (luminosità media \(pct)%): l'ho schiarita e uso Pulito, che non la scurisce")
        }
        if warmth > 1.25 {
            return advice("golden", "Luce calda (rosso/blu \(String(format: "%.1f", warmth))): Golden Hour la asseconda")
        }
        if top.b > top.r * 1.15 {
            return advice("teal", "Parte alta azzurra, probabilmente cielo: Teal & Orange separa cielo e soggetto")
        }
        if colour < 0.18 {
            return advice("film", "Colori tenui (saturazione max \(Int((colour * 100).rounded()))%): Pellicola li ammorbidisce")
        }
        return advice("teal", "Luce neutra (luminosità \(pct)%): Teal & Orange, il look da cinema più versatile")
    }

    // MARK: Photo frame

    /// Puts the photo on a white (1) or black (2) card with a caption underneath. 0 leaves it as it is.
    /// The photo keeps its own pixels and proportions; the card only adds margins.
    static func framed(_ image: CIImage, style: Int) -> CIImage {
        guard style == 1 || style == 2 else { return image }
        let e = image.extent
        let side = max(e.width, e.height)
        let margin = (side * 0.04).rounded(), bottom = (side * 0.11).rounded()
        let canvas = CGRect(x: 0, y: 0, width: e.width + 2 * margin, height: e.height + margin + bottom)
        let white = style == 1
        let paper = white ? CIColor(red: 0.97, green: 0.955, blue: 0.93) : CIColor(red: 0.03, green: 0.03, blue: 0.04)
        let card = CIImage(color: paper).cropped(to: canvas)
        let placed = image.transformed(by: CGAffineTransform(translationX: margin - e.minX, y: bottom - e.minY))
        var out = placed.composited(over: card)

        let text = CIFilter.textImageGenerator()
        text.text = "Aimframe"
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

    // MARK: Export

    /// The full-size photo with the look and frame, upright, as HEIF (JPEG if HEIF is unavailable).
    /// EXIF and location data are carried over; the orientation tag is reset because the pixels are now upright.
    /// With no look and no frame the original file is returned untouched.
    static func export(_ data: Data, look id: String, intensity: Double, frame: Int) -> Data {
        guard intensity >= 0.01 || frame != 0, let full = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        let fix = measureLight(full)
        var graded = framed(render(full, look: look(id), intensity: CGFloat(intensity), light: fix), style: frame)
        var props = full.properties
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        props[kCGImagePropertyPixelWidth as String] = Int(graded.extent.width)
        props[kCGImagePropertyPixelHeight as String] = Int(graded.extent.height)
        graded = graded.settingProperties(props)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        if let heif = context.heifRepresentation(of: graded, format: .RGBA8, colorSpace: space, options: [:]) { return heif }
        if let jpeg = context.jpegRepresentation(of: graded, colorSpace: space, options: [:]) { return jpeg }
        return data
    }

    // MARK: Helpers

    static func scaled(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let k = min(1, maxSide / max(image.extent.width, image.extent.height, 1))
        if k >= 1 { return image }
        return image.transformed(by: CGAffineTransform(scaleX: k, y: k))
    }
}
