import AVFoundation
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMotion
import ImageIO
import Photos
import UIKit
import Vision

enum GuidePhase {
    case free, guiding, locked, lost
}

enum AppMode: String, CaseIterable {
    case landscape = "Paesaggio"
    case outfit = "Outfit"
}

/// Reads the outfit corrections aloud, without talking over itself or repeating too often.
final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private var lastText = ""
    private var lastTime: CFTimeInterval = 0
    private var sessionReady = false

    func say(_ text: String) {
        let now = CACurrentMediaTime()
        if synth.isSpeaking || now - lastTime < 2.0 { return }
        if text == lastText && now - lastTime < 7 { return }
        if !sessionReady {
            sessionReady = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        lastText = text
        lastTime = now
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "it-IT")
        utterance.rate = 0.5
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}

/// Camera, on-device AI (Apple Vision) and the aiming guide for the landscape mode.
/// Published values are only changed on the main thread. Analysis state lives on `videoQueue`.
final class CameraModel: NSObject, ObservableObject {

    // MARK: Shown by the UI (coordinates are 0...1 with the origin at the top left)

    @Published var authorized = true
    @Published var phase: GuidePhase = .free {
        didSet {
            if oldValue != phase { phaseSince = CACurrentMediaTime() }
            if phase == .free { autoShotFired = false }
            if phase != .guiding && phase != .locked { shotScore = nil }
        }
    }
    @Published var subjectBox: CGRect?
    @Published var target = CGPoint(x: 0.5, y: 0.5)
    @Published var label = ""
    @Published var hint = "Tocca la scintilla per analizzare la scena"
    @Published var zoomShown: CGFloat = 1
    @Published var hasUltraWide = false
    @Published var roll: Double?
    @Published var lastThumb: UIImage?
    @Published var toast: String?
    @Published var flash = false

    // Outfit mode
    @Published var mode: AppMode = .landscape
    @Published var isFront = false
    @Published var body: [Joint: CGPoint] = [:]
    @Published var ghost: [Joint: CGPoint] = [:]
    @Published var poseMatched = false
    @Published var countdown: Int?
    @Published var selectedPoseID = "free"
    @Published var importedPose: RefPose?
    @Published var silhouette: UIImage?           // the person cut out of the inspiration photo
    @Published var silhouetteMirrored = false
    @Published var voiceOn = true
    @Published var autoShot = true

    // Review after the shot
    @Published var reviewImage: UIImage?
    @Published var lookThumbs: [String: UIImage] = [:]
    @Published var selectedLook = "teal"
    @Published var recommendedLook = "teal"
    @Published var recommendReason = ""
    @Published var intensity: Double = 1
    @Published var savingReview = false
    @Published var frameStyle = 0                 // 0 none, 1 white card, 2 black card
    @Published var exposureText = ""
    @Published var shotScore: Int?                // 0...100 while the guide is on (landscape)
    @Published var lightNote = ""                 // shown when the app corrects the exposure

    let session = AVCaptureSession()
    private let speaker = Speaker()

    // MARK: Camera

    private let sessionQueue = DispatchQueue(label: "aimframe.session")
    private let videoQueue = DispatchQueue(label: "aimframe.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var wideFactor: CGFloat = 1          // zoom factor at which the main (1x) lens is used
    private let motion = CMMotionManager()

    // Auto mode (main thread): the app scans and shoots by itself, the user only points the phone.
    private var phaseSince: CFTimeInterval = 0
    private var steadySince: CFTimeInterval = 0
    private var nextAutoScan: CFTimeInterval = 0
    private var needsMove = false                 // after a shot, wait for the phone to move to a new scene
    private var autoShotFired = false             // one automatic shot per lock, until the guide is reset
    private var overlayOpen = false

    // MARK: Guide state (videoQueue only; Vision coordinates, origin at the bottom left)

    private var wantScan = false
    private var tracker: VNTrackObjectRequest?
    private var sequence = VNSequenceRequestHandler()
    private var anchor = CGPoint(x: 0.5, y: 0.5)   // where the subject should sit in the final frame
    private var zoomMult: CGFloat = 1
    private var zoomStarted = false
    private var baseZoom: CGFloat = 1
    private var lockRun = 0
    private var lostRun = 0
    private var locked = false
    private var advice = "Inquadratura giusta. Resta fermo e scatta."
    private var exposureTick = 0

    // Exposure correction (videoQueue)
    private var lightBias: Float = 0
    private var pendingBias: Float = 0
    private var biasVotes = 0
    private var lightScore: CGFloat = 1

    // MARK: Outfit state (videoQueue only)

    private var vMode: AppMode = .landscape
    private var vFront = false
    private var vAutoShot = true
    private var refPose: RefPose?
    private var useMirror = false
    private var frameCount = 0
    private var poseHoldStart: CFTimeInterval?
    private var countdownEnd: CFTimeInterval?
    private var lastMatched: CFTimeInterval = 0
    private var cooldownUntil: CFTimeInterval = 0
    private var configured = false
    private var paused = false                    // true while the review screen is open

    // MARK: Review state

    private let gradeQueue = DispatchQueue(label: "aimframe.grade", qos: .userInitiated)
    private var reviewData: Data?                 // the untouched photo (gradeQueue)
    private var reviewBase: CIImage?              // preview-sized copy (gradeQueue)
    private var renderToken = 0

    // MARK: Start

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.authorized = granted }
            guard granted else { return }
            self.sessionQueue.async { self.configure() }
        }
        startMotion()
    }

    private func configure() {
        if configured {
            if !session.isRunning { session.startRunning() }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        photoOutput.maxPhotoQualityPrioritization = .quality
        configured = true
        attachCamera(.back)
        session.startRunning()
    }

    /// Puts the back or front camera on the session. Called on `sessionQueue`.
    private func attachCamera(_ position: AVCaptureDevice.Position) {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        guard let cam = found.first, let input = try? AVCaptureDeviceInput(device: cam) else {
            DispatchQueue.main.async { self.hint = "Nessuna fotocamera trovata." }
            return
        }
        session.beginConfiguration()
        for old in session.inputs { session.removeInput(old) }
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()

        // Full iPhone quality: the largest photo size the lens offers.
        let sizes = cam.activeFormat.supportedMaxPhotoDimensions
        if let largest = sizes.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        setPortrait(videoOutput.connection(with: .video))
        setPortrait(photoOutput.connection(with: .video))

        device = cam
        wideFactor = 1
        var ultra = false
        if cam.deviceType == .builtInTripleCamera || cam.deviceType == .builtInDualWideCamera,
           let first = cam.virtualDeviceSwitchOverVideoZoomFactors.first {
            wideFactor = CGFloat(truncating: first)
            ultra = true
        }
        let front = position == .front
        videoQueue.async {
            self.vFront = front
            self.lightBias = 0
            self.pendingBias = 0
            self.biasVotes = 0
        }
        DispatchQueue.main.async {
            self.hasUltraWide = ultra
            self.isFront = front
            self.lightNote = ""
        }
        applyZoom(display: 1, ramp: false)
    }

    func flipCamera() {
        let next: AVCaptureDevice.Position = isFront ? .back : .front
        sessionQueue.async { self.attachCamera(next) }
    }

    private func setPortrait(_ connection: AVCaptureConnection?) {
        guard let connection = connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        // The AI always sees the true picture; only the on-screen preview of the front camera is mirrored.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let g = data?.gravity else { return }
            // Roll is only meaningful while the phone is not pointing steeply up or down.
            let across = (g.x * g.x + g.y * g.y).squareRoot()
            self.roll = across > 0.35 ? atan2(g.x, -g.y) : nil
            if let r = data?.rotationRate {
                self.autoPilot(turning: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot())
            }
        }
    }

    /// Runs about 30 times a second. In auto mode it starts the scan when the phone is held still,
    /// takes the photo once the framing has stayed right for a moment, and starts over on a new scene.
    private func autoPilot(turning: Double) {
        let now = CACurrentMediaTime()
        if turning > 0.12 { steadySince = now }
        guard mode == .landscape, autoShot, reviewImage == nil, !overlayOpen else {
            steadySince = now
            return
        }
        if turning > 0.6 { needsMove = false }
        switch phase {
        case .free:
            if needsMove {
                hint = "Fatto. Punta il telefono su un'altra scena"
            } else if now - steadySince > 0.9 && now > nextAutoScan {
                nextAutoScan = now + 3
                scanOrClear()
            } else if hint != "Analizzo la scena…" {
                hint = "Punta il telefono sulla scena e tienilo fermo"
            }
        case .locked:
            if !autoShotFired && now - phaseSince > 0.9 {
                autoShotFired = true
                needsMove = true
                nextAutoScan = now + 2
                capture()
                scanOrClear()
            }
        case .lost:
            if now - phaseSince > 1.5 { scanOrClear() }
        case .guiding:
            break
        }
    }

    // MARK: Zoom

    /// `display` is what the user sees: 0.5, 1, 2, 3.
    func setZoom(display: CGFloat) {
        sessionQueue.async { self.applyZoom(display: display, ramp: true) }
    }

    private func applyZoom(display: CGFloat, ramp: Bool) {
        guard let device = device else { return }
        let upper = min(device.maxAvailableVideoZoomFactor, 10 * wideFactor)
        let factor = min(max(display * wideFactor, device.minAvailableVideoZoomFactor), upper)
        do {
            try device.lockForConfiguration()
            if ramp { device.ramp(toVideoZoomFactor: factor, withRate: 3) } else { device.videoZoomFactor = factor }
            device.unlockForConfiguration()
        } catch {
            return
        }
        let shown = factor / wideFactor
        DispatchQueue.main.async { self.zoomShown = shown }
    }

    private func currentDisplayZoom() -> CGFloat {
        guard let device = device else { return 1 }
        return device.videoZoomFactor / wideFactor
    }

    // MARK: Scan and guide

    func scanOrClear() {
        guard mode == .landscape else { return }
        if phase == .free {
            hint = "Analizzo la scena…"
            videoQueue.async { self.wantScan = true }
        } else {
            videoQueue.async { self.clearGuide(message: "Tocca la scintilla per analizzare la scena") }
        }
    }

    private func clearGuide(message: String) {
        tracker?.isLastFrame = true
        tracker = nil
        wantScan = false
        locked = false
        lockRun = 0
        lostRun = 0
        DispatchQueue.main.async {
            self.phase = .free
            self.subjectBox = nil
            self.label = ""
            self.hint = message
        }
    }

    private func bestBox(_ results: [VNSaliencyImageObservation]?) -> CGRect? {
        guard let objects = results?.first?.salientObjects, !objects.isEmpty else { return nil }
        return objects.max(by: { $0.confidence < $1.confidence })?.boundingBox
    }

    private func runScan(_ pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let classify = VNClassifyImageRequest()
        do {
            try handler.perform([objectness, attention, classify])
        } catch {
            clearGuide(message: "Analisi non riuscita. Riprova.")
            return
        }

        // The subject: the strongest object, or else whatever draws the eye, or else the middle.
        var box = bestBox(objectness.results) ?? bestBox(attention.results) ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        let w = min(max(box.width, 0.12), 0.7), h = min(max(box.height, 0.12), 0.7)
        box = CGRect(x: min(max(box.midX - w / 2, 0), 1 - w), y: min(max(box.midY - h / 2, 0), 1 - h), width: w, height: h)

        // What the scene is, in the words of Apple's classifier.
        let names = (classify.results ?? [])
            .filter { $0.confidence > 0.2 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(2)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let text = names.isEmpty ? "soggetto" : names.joined(separator: ", ")
        advice = Self.advice(for: pixelBuffer, subject: box)

        // Composition: the thirds point nearest the subject keeps the rest of the scene in the frame.
        anchor = CGPoint(x: box.midX < 0.4 ? 1.0 / 3.0 : (box.midX > 0.6 ? 2.0 / 3.0 : 0.5),
                         y: box.midY < 0.4 ? 1.0 / 3.0 : (box.midY > 0.6 ? 2.0 / 3.0 : 0.5))
        let mult = min(max(0.45 / max(box.width, box.height), 1), 2.5)
        zoomMult = mult < 1.15 ? 1 : mult
        zoomStarted = false
        baseZoom = currentDisplayZoom()
        lockRun = 0
        lostRun = 0
        locked = false

        sequence = VNSequenceRequestHandler()
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        request.trackingLevel = .accurate
        tracker = request

        let shownBox = flip(box)
        DispatchQueue.main.async {
            self.label = text
            self.subjectBox = shownBox
            self.phase = .guiding
        }
    }

    private func runTrack(_ pixelBuffer: CVPixelBuffer) {
        guard let request = tracker else { return }
        do {
            try sequence.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            markLost()
            return
        }
        guard let seen = request.results?.first as? VNDetectedObjectObservation else {
            markLost()
            return
        }
        request.inputObservation = seen
        lostRun = seen.confidence < 0.25 ? lostRun + 1 : 0
        if lostRun > 20 {
            markLost()
            return
        }

        let box = seen.boundingBox
        let m = zoomMult

        // Zoom in only once the subject is close enough to the middle to stay in the frame.
        if m > 1 && !zoomStarted {
            let fitsX = abs(box.midX - 0.5) * m + box.width * m / 2 < 0.48
            let fitsY = abs(box.midY - 0.5) * m + box.height * m / 2 < 0.48
            if fitsX && fitsY {
                zoomStarted = true
                let goal = baseZoom * m
                sessionQueue.async { self.applyZoom(display: goal, ramp: true) }
            }
        }
        let zoomDone = m == 1 || (zoomStarted && !(device?.isRampingVideoZoom ?? false))

        // Before the zoom, aim at the spot that will land on the anchor once zoomed.
        let goalPoint = (m == 1 || zoomStarted)
            ? anchor
            : CGPoint(x: 0.5 + (anchor.x - 0.5) / m, y: 0.5 + (anchor.y - 0.5) / m)
        let dx = box.midX - goalPoint.x      // > 0: the subject is right of where it should be
        let dy = box.midY - goalPoint.y      // > 0: the subject is above where it should be
        let far = max(abs(dx), abs(dy))

        if !locked {
            lockRun = (far < 0.05 && zoomDone) ? lockRun + 1 : 0
            if lockRun >= 8 {
                locked = true
                DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
        } else if far > 0.1 {
            locked = false
            lockRun = 0
        }

        let message: String
        if locked {
            message = advice
        } else {
            var parts: [String] = []
            if abs(dx) > 0.04 { parts.append(dx > 0 ? "a destra" : "a sinistra") }
            if abs(dy) > 0.04 { parts.append(dy > 0 ? "in alto" : "in basso") }
            if parts.isEmpty {
                message = zoomDone ? "Fermo così…" : "Avvicino l'inquadratura…"
            } else {
                message = (far < 0.13 ? "Ci sei quasi, un po' " : "Punta il telefono ") + parts.joined(separator: " e ")
            }
        }

        let shownBox = flip(box)
        let shownTarget = CGPoint(x: goalPoint.x, y: 1 - goalPoint.y)
        let nowLocked = locked
        let framing = nowLocked ? 1 : max(0, 1 - far / 0.3) * (zoomDone ? 1 : 0.85)
        let light = lightScore
        DispatchQueue.main.async {
            guard self.phase == .guiding || self.phase == .locked else { return }
            var level: CGFloat = 1
            if let r = self.roll { level = max(0, min(1, 1 - (CGFloat(abs(r)) - 0.026) / 0.15)) }
            self.shotScore = Int(((0.6 * framing + 0.2 * level + 0.2 * light) * 100).rounded())
            self.subjectBox = shownBox
            self.target = shownTarget
            self.phase = nowLocked ? .locked : .guiding
            self.hint = message
        }
    }

    private func markLost() {
        tracker?.isLastFrame = true
        tracker = nil
        locked = false
        DispatchQueue.main.async {
            self.phase = .lost
            self.subjectBox = nil
            self.hint = "Ho perso il soggetto. Tocca ✕ e analizza di nuovo."
        }
    }

    /// One line on what makes this shot work, from the light on the subject compared with the rest of the scene.
    private static func advice(for pixelBuffer: CVPixelBuffer, subject box: CGRect) -> String {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let e = image.extent
        let whole = Grade.average(image, rect: e)
        let sub = Grade.average(image, rect: CGRect(x: e.minX + box.minX * e.width, y: e.minY + box.minY * e.height,
                                                    width: box.width * e.width, height: box.height * e.height))
        let sky = Grade.average(image, rect: CGRect(x: e.minX, y: e.minY + e.height * 0.66, width: e.width, height: e.height * 0.34))
        let lightAll = (whole.r + whole.g + whole.b) / 3
        let lightSub = (sub.r + sub.g + sub.b) / 3
        let warm = sub.r > sub.b * 1.2
        let mx = max(whole.r, whole.g, whole.b), mn = min(whole.r, whole.g, whole.b)
        let colour = mx > 0 ? (mx - mn) / mx : 0

        if lightSub > lightAll * 1.15 && warm { return "Bella luce calda sul soggetto: resta lì e scatta" }
        if lightSub > lightAll * 1.15 { return "Il soggetto è in piena luce: resta lì e scatta" }
        if lightSub < lightAll * 0.7 { return "Soggetto in controluce: lascialo in silhouette e scatta" }
        if sky.b > sky.r * 1.15 { return "Soggetto isolato, cielo pulito sopra: scatta" }
        if colour < 0.12 { return "Pochi colori: contano forme e contrasto. Scatta" }
        return "Soggetto isolato dallo sfondo: resta fermo e scatta"
    }

    /// Reads the brightness of the frame and, when it is clearly too bright or too dark,
    /// shifts the camera's exposure so beginners don't get burnt skies or murky rooms.
    private func measureLight(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, count = 0, bright = 0, dark = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let v = Int(luma[y * rowBytes + x])
                sum += v
                count += 1
                if v >= 250 { bright += 1 } else if v <= 10 { dark += 1 }
                x += 12
            }
            y += 12
        }
        guard count > 0 else { return }
        let mean = CGFloat(sum) / CGFloat(count) / 255
        let hi = CGFloat(bright) / CGFloat(count), lo = CGFloat(dark) / CGFloat(count)
        lightScore = max(0, min(1, 1 - hi * 4 - lo * 2 - max(0, 0.22 - mean) * 3 - max(0, mean - 0.78) * 3))

        // What the exposure should be, with some stickiness so it does not flip back and forth.
        var want: Float = lightBias
        if lightBias < 0 {
            if hi < 0.005 && mean < 0.3 { want = 0 }
        } else if lightBias > 0 {
            if hi > 0.04 || mean > 0.5 { want = 0 }
        } else if hi > 0.10 {
            want = -0.7
        } else if mean < 0.2 && hi < 0.02 {
            want = 0.7
        }
        if want == pendingBias { biasVotes += 1 } else { pendingBias = want; biasVotes = 1 }
        guard biasVotes >= 4, want != lightBias else { return }
        lightBias = want
        let note = want < 0 ? "Troppa luce: abbasso l'esposizione" : (want > 0 ? "Scena scura: alzo l'esposizione" : "")
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            let bias = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, want))
            device.setExposureTargetBias(bias, completionHandler: nil)
            device.unlockForConfiguration()
        }
        DispatchQueue.main.async { self.lightNote = note }
    }

    /// Shutter speed and ISO the camera is using right now.
    private func publishExposure() {
        guard let device = device else { return }
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        guard seconds > 0, seconds.isFinite else { return }
        let shutter = seconds >= 1 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
        let text = "\(shutter)   ISO \(Int(device.iso.rounded()))"
        DispatchQueue.main.async { if self.exposureText != text { self.exposureText = text } }
    }

    /// Vision rectangles start at the bottom left, the screen starts at the top left.
    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Outfit mode

    func setMode(_ newMode: AppMode) {
        guard newMode != mode else { return }
        mode = newMode
        speaker.stop()
        body = [:]
        ghost = [:]
        poseMatched = false
        countdown = nil
        let needBack = newMode == .landscape && isFront
        videoQueue.async {
            self.clearGuide(message: newMode == .landscape ? "Tocca la scintilla per analizzare la scena" : "Mettiti a figura intera davanti alla fotocamera")
            self.vMode = newMode
            self.resetPoseTimers()
        }
        if needBack { sessionQueue.async { self.attachCamera(.back) } }
    }

    func selectPose(_ pose: RefPose?) {
        selectedPoseID = pose?.id ?? "free"
        ghost = [:]
        videoQueue.async {
            self.refPose = pose
            self.useMirror = false
            self.resetPoseTimers()
        }
    }

    func setAutoShot(_ on: Bool) {
        autoShot = on
        videoQueue.async {
            self.vAutoShot = on
            self.resetPoseTimers()
        }
    }

    func setVoice(_ on: Bool) {
        voiceOn = on
        if !on { speaker.stop() }
    }

    private func resetPoseTimers() {
        poseHoldStart = nil
        countdownEnd = nil
    }

    private static let jointNames: [VNHumanBodyPoseObservation.JointName: Joint] = [
        .nose: .nose, .neck: .neck, .root: .root,
        .leftShoulder: .lShoulder, .rightShoulder: .rShoulder,
        .leftElbow: .lElbow, .rightElbow: .rElbow,
        .leftWrist: .lWrist, .rightWrist: .rWrist,
        .leftHip: .lHip, .rightHip: .rHip,
        .leftKnee: .lKnee, .rightKnee: .rKnee,
        .leftAnkle: .lAnkle, .rightAnkle: .rAnkle
    ]

    private static func joints(from observation: VNHumanBodyPoseObservation) -> [Joint: CGPoint] {
        guard let points = try? observation.recognizedPoints(.all) else { return [:] }
        var out: [Joint: CGPoint] = [:]
        for (name, joint) in jointNames {
            if let p = points[name], p.confidence > 0.3 { out[joint] = p.location }
        }
        return out
    }

    /// What is wrong with the framing of the whole figure, or nil when it is fine.
    private func framingIssue(_ j: [Joint: CGPoint], neck: CGPoint, root: CGPoint, facing: Bool) -> String? {
        let ankles = [j[.lAnkle], j[.rAnkle]].compactMap { $0 }
        guard let bottom = ankles.map({ $0.y }).min() else { return "Non vedo i piedi: fai un passo indietro" }
        let top = j[.nose]?.y ?? neck.y
        if bottom < 0.04 { return "I piedi sono al bordo: fai un passo indietro" }
        if top > 0.9 { return "La testa è al bordo: fai un passo indietro" }
        if top - bottom < 0.45 { return "Sei lontano: avvicinati un po'" }
        if root.x < 0.3 || root.x > 0.7 {
            let towardsPictureRight = root.x < 0.3
            let towardsPersonLeft = facing ? towardsPictureRight : !towardsPictureRight
            return "Spostati un passo alla tua " + (towardsPersonLeft ? "sinistra" : "destra")
        }
        return nil
    }

    private func runPose(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        let now = CACurrentMediaTime()

        var joints: [Joint: CGPoint] = [:]
        if let observation = request.results?.first { joints = Self.joints(from: observation) }
        guard let neck = joints[.neck], let root = joints[.root] else {
            resetPoseTimers()
            publishPose(body: [:], ghost: [:], matched: false, count: nil, hint: "Mettiti a figura intera davanti alla fotocamera", speak: false)
            return
        }

        let facing = joints[.nose] != nil
        var hint = "Inquadratura ok. Scatta quando vuoi."
        var speak = false
        var matched = false
        var ghostJoints: [Joint: CGPoint] = [:]

        if let issue = framingIssue(joints, neck: neck, root: root, facing: facing) {
            hint = issue
            speak = true
        } else if let ref = refPose {
            speak = true
            let user = PoseMath.angles(joints, aspect: aspect)
            let mirroredAngles = PoseMath.mirror(ref.angles)
            let direct = PoseMath.compare(user: user, ref: ref.angles)
            let flipped = PoseMath.compare(user: user, ref: mirroredAngles)
            // The mirror image of a pose looks just as good, so follow whichever the person is closer to.
            if useMirror {
                if direct.score > flipped.score + 0.08 { useMirror = false }
            } else if flipped.score > direct.score + 0.08 {
                useMirror = true
            }
            let target = useMirror ? mirroredAngles : ref.angles
            let result = useMirror ? flipped : direct
            ghostJoints = PoseMath.ghost(joints: joints, ref: target, aspect: aspect)
            matched = result.matched
            if matched {
                hint = "Perfetto, resta così"
            } else if let limb = result.worst, let u = user[limb], let r = target[limb] {
                hint = PoseMath.instruction(limb: limb, user: u, ref: r, joints: joints, facing: facing)
            } else {
                hint = "Mostrati a figura intera"
            }
        }

        // Auto shot: hold the pose, three seconds of countdown, photo.
        var count: Int?
        if matched && vAutoShot && now > cooldownUntil {
            lastMatched = now
            if poseHoldStart == nil { poseHoldStart = now }
            if countdownEnd == nil, let start = poseHoldStart, now - start > 0.7 { countdownEnd = now + 3 }
        } else if now - lastMatched > 0.6 {
            resetPoseTimers()
        }
        if let end = countdownEnd {
            if now >= end {
                resetPoseTimers()
                cooldownUntil = now + 4
                DispatchQueue.main.async { self.capture() }
            } else {
                count = Int((end - now).rounded(.up))
            }
        }

        publishPose(body: joints, ghost: ghostJoints, matched: matched, count: count, hint: hint, speak: speak)
    }

    private func publishPose(body: [Joint: CGPoint], ghost: [Joint: CGPoint], matched: Bool, count: Int?, hint: String, speak: Bool) {
        let front = vFront
        let flipShape = front != useMirror
        func shown(_ joints: [Joint: CGPoint]) -> [Joint: CGPoint] {
            var out: [Joint: CGPoint] = [:]
            for (j, p) in joints { out[j] = CGPoint(x: front ? 1 - p.x : p.x, y: 1 - p.y) }
            return out
        }
        let shownBody = shown(body), shownGhost = shown(ghost)
        DispatchQueue.main.async {
            guard self.mode == .outfit else { return }
            self.body = shownBody
            self.ghost = shownGhost
            self.silhouetteMirrored = flipShape
            self.poseMatched = matched
            self.countdown = count
            self.hint = hint
            if speak && self.voiceOn { self.speaker.say(hint) }
        }
    }

    /// Stops the live analysis and the voice while another screen is on top of the camera.
    func setPaused(_ on: Bool) {
        overlayOpen = on
        if on { speaker.stop() }
        videoQueue.async {
            self.paused = on
            self.resetPoseTimers()
        }
    }

    /// Reads the pose out of a photo (from the camera roll, the clipboard or the web) to use as the pose to copy.
    /// `completion` runs on the main thread with true when a whole figure was found.
    func importInspiration(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            func fail(_ text: String) {
                self.showToast(text)
                DispatchQueue.main.async { completion?(false) }
            }
            guard let picked = UIImage(data: data) else {
                fail("Non riesco ad aprire questa foto.")
                return
            }
            // Redraw upright and smaller, so Vision sees the picture the way the user does.
            let scale = min(1, 1280 / max(picked.size.width, picked.size.height))
            let size = CGSize(width: max(1, picked.size.width * scale), height: max(1, picked.size.height * scale))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                picked.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let cgImage = upright.cgImage else {
                fail("Non riesco ad aprire questa foto.")
                return
            }
            let request = VNDetectHumanBodyPoseRequest()
            let segmentation = VNGeneratePersonSegmentationRequest()
            segmentation.qualityLevel = .accurate
            segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request, segmentation])
            var joints: [Joint: CGPoint] = [:]
            if let observation = request.results?.first { joints = Self.joints(from: observation) }
            let angles = PoseMath.angles(joints, aspect: size.width / size.height)
            guard angles.count >= 6 else {
                fail("In questa foto non trovo una persona a figura intera.")
                return
            }
            let pose = RefPose(id: "import", name: "Ispirazione", angles: angles)
            let shape = segmentation.results?.first.flatMap { Self.silhouetteImage(mask: $0.pixelBuffer, size: size) }
            DispatchQueue.main.async {
                self.silhouette = shape
                self.importedPose = pose
                self.selectPose(pose)
                self.showToast("Posa copiata dalla foto")
                completion?(true)
            }
        }
    }

    /// A see-through white figure with a yellow outline, the same size as the inspiration photo.
    private static func silhouetteImage(mask buffer: CVPixelBuffer, size: CGSize) -> UIImage? {
        let raw = CIImage(cvPixelBuffer: buffer)
        guard raw.extent.width > 0, raw.extent.height > 0 else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        let mask = raw.transformed(by: CGAffineTransform(scaleX: size.width / raw.extent.width,
                                                         y: size.height / raw.extent.height)).cropped(to: rect)
        let soft = CIFilter.colorMatrix()                   // the inside of the figure, at 40%
        soft.inputImage = mask
        soft.rVector = CIVector(x: 0.4, y: 0, z: 0, w: 0)
        soft.gVector = CIVector(x: 0, y: 0.4, z: 0, w: 0)
        soft.bVector = CIVector(x: 0, y: 0, z: 0.4, w: 0)
        soft.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let edge = CIFilter.morphologyGradient()            // the outline
        edge.inputImage = mask
        edge.radius = Float(max(2, size.width / 220))
        guard let fillMask = soft.outputImage, let edgeMask = edge.outputImage?.cropped(to: rect) else { return nil }

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
        let yellow = CIImage(color: CIColor(red: 1, green: 0.77, blue: 0.24)).cropped(to: rect)
        let fill = CIFilter.blendWithMask()
        fill.inputImage = white
        fill.backgroundImage = clear
        fill.maskImage = fillMask
        guard let inside = fill.outputImage else { return nil }
        let outline = CIFilter.blendWithMask()
        outline.inputImage = yellow
        outline.backgroundImage = inside
        outline.maskImage = edgeMask
        guard let figure = outline.outputImage?.cropped(to: rect) else { return nil }
        return Grade.uiImage(figure)
    }

    /// Uses a picture the user copied in another app (Pinterest, Safari, Instagram).
    func importFromClipboard() {
        guard let image = UIPasteboard.general.image, let data = image.jpegData(compressionQuality: 0.9) else {
            showToast("Negli appunti non c'è una foto. Copiala e riprova.")
            return
        }
        importInspiration(data)
    }

    // MARK: Review and colour grade

    /// Builds the preview, the look thumbnails and the recommendation for a fresh shot.
    private func prepareReview(_ data: Data) {
        guard let full = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            saveToPhotos(data)
            return
        }
        let base = Grade.scaled(full, maxSide: 1400)
        let small = Grade.scaled(full, maxSide: 220)
        let pick = Grade.recommend(small)
        var thumbs: [String: UIImage] = [:]
        for look in Grade.looks {
            if let t = Grade.uiImage(Grade.render(small, look: look, intensity: 1)) { thumbs[look.id] = t }
        }
        reviewData = data
        reviewBase = base
        let style = DispatchQueue.main.sync { self.frameStyle }
        guard let preview = Grade.uiImage(Grade.framed(Grade.render(base, look: Grade.look(pick.id), intensity: 1), style: style)) else {
            reviewData = nil
            reviewBase = nil
            saveToPhotos(data)
            return
        }
        videoQueue.async { self.paused = true }
        DispatchQueue.main.async {
            self.speaker.stop()
            self.lookThumbs = thumbs
            self.recommendedLook = pick.id
            self.recommendReason = pick.reason
            self.selectedLook = pick.id
            self.intensity = 1
            self.savingReview = false
            self.countdown = nil
            self.reviewImage = preview
        }
    }

    func selectLook(_ id: String) {
        selectedLook = id
        rerender()
    }

    func setIntensity(_ value: Double) {
        intensity = value
        rerender()
    }

    func setFrameStyle(_ style: Int) {
        frameStyle = style
        rerender()
    }

    private func rerender() {
        renderToken += 1
        let token = renderToken
        let id = selectedLook
        let amount = CGFloat(intensity)
        let style = frameStyle
        gradeQueue.async {
            guard token == self.renderToken, let base = self.reviewBase,
                  let image = Grade.uiImage(Grade.framed(Grade.render(base, look: Grade.look(id), intensity: amount), style: style)) else { return }
            DispatchQueue.main.async {
                if token == self.renderToken && self.reviewImage != nil { self.reviewImage = image }
            }
        }
    }

    /// Applies the chosen look to the full-size photo and saves it to the camera roll.
    func saveReview() {
        guard reviewImage != nil, !savingReview else { return }
        savingReview = true
        let id = selectedLook
        let amount = CGFloat(intensity)
        let style = frameStyle
        gradeQueue.async {
            guard let data = self.reviewData else {
                self.closeReview()
                return
            }
            var output = data                       // at 0% the original file is kept untouched
            if amount >= 0.01 || style != 0, let full = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                let graded = Grade.framed(Grade.render(full, look: Grade.look(id), intensity: amount), style: style)
                let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
                if let heif = Grade.context.heifRepresentation(of: graded, format: .RGBA8, colorSpace: space, options: [:]) {
                    output = heif
                } else if let jpeg = Grade.context.jpegRepresentation(of: graded, colorSpace: space, options: [:]) {
                    output = jpeg
                }
            }
            self.saveToPhotos(output)
            self.closeReview()
        }
    }

    func discardReview() {
        gradeQueue.async { self.closeReview() }
    }

    private func closeReview() {
        reviewData = nil
        reviewBase = nil
        videoQueue.async {
            self.paused = false
            self.resetPoseTimers()
            self.cooldownUntil = CACurrentMediaTime() + 3
        }
        DispatchQueue.main.async {
            self.reviewImage = nil
            self.savingReview = false
        }
    }

    private func saveToPhotos(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.showToast("Consenti l'accesso a Foto in Impostazioni per salvare.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { saved, _ in
                self.showToast(saved ? "Salvata nel rullino" : "Salvataggio non riuscito")
            })
        }
    }

    // MARK: Photo

    func capture() {
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.flash = false }
        sessionQueue.async {
            guard self.session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.toast == text { self.toast = nil }
            }
        }
    }

    private func thumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Frames for the AI

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        exposureTick += 1
        if exposureTick % 10 == 0 { publishExposure() }
        if exposureTick % 8 == 0 { measureLight(pixelBuffer) }
        if vMode == .outfit {
            frameCount += 1
            if frameCount % 2 == 0 { runPose(pixelBuffer) }
        } else if wantScan {
            wantScan = false
            runScan(pixelBuffer)
        } else if tracker != nil {
            runTrack(pixelBuffer)
        }
    }
}

// MARK: - Saving the photo

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            showToast("Scatto non riuscito. Riprova.")
            return
        }
        let thumb = thumbnail(from: data)
        DispatchQueue.main.async { self.lastThumb = thumb }
        gradeQueue.async { self.prepareReview(data) }
    }
}
