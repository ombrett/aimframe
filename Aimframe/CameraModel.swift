import AVFoundation
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMotion
import ImageIO
import Photos
import UIKit
import Vision

enum AppMode: String, CaseIterable {
    case landscape = "Paesaggio"
    case outfit = "Outfit"
    case carousel = "Carosello"
}

enum GuidePhase {
    case free, scanning, guiding, locked, lost
}

enum CameraStatus {
    case unknown, granted, denied, unavailable
}

struct CarouselShot: Identifiable {
    let id = UUID()
    let step: CarouselStep
    let data: Data
    let thumb: UIImage?
}

/// Reads the corrections for the person posing aloud, without talking over itself or repeating too often.
final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private var lastText = ""
    private var lastTime: CFTimeInterval = 0
    private var sessionReady = false

    func say(_ text: String) {
        let now = CACurrentMediaTime()
        if synth.isSpeaking || now - lastTime < 2.5 { return }
        if text == lastText && now - lastTime < 8 { return }
        if !sessionReady {
            sessionReady = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
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

/// Camera, on-device analysis (Apple Vision) and the shooting guide.
/// Published values change only on the main thread; analysis state lives on `videoQueue`;
/// the capture device is configured on `sessionQueue`.
final class CameraModel: NSObject, ObservableObject {

    // MARK: Shown by the UI (coordinates 0...1, origin top left, as on screen)

    @Published var status: CameraStatus = .unknown
    @Published var mode: AppMode = .landscape
    @Published var phase: GuidePhase = .free {
        didSet { if oldValue != phase { phaseSince = CACurrentMediaTime() } }
    }
    @Published var instruction = Instruction.info("Punta il telefono sulla scena")
    @Published var subjectBox: CGRect?
    @Published var target = CGPoint(x: 0.5, y: 0.5)
    @Published var label = ""
    @Published var composition: CompositionResult?
    @Published var autoProgress: Double?
    @Published var zoomShown: CGFloat = 1
    @Published var zoomPresets: [CGFloat] = [1, 2]
    @Published var roll: Double?
    @Published var lastThumb: UIImage?
    @Published var toast: String?
    @Published var flash = false
    @Published var lightNote = ""
    @Published var exposureText = ""
    @Published var systemNote = ""               // camera interrupted, phone hot
    @Published var lightLevel: LightLevel = .good
    @Published var photosDenied = false

    // Outfit
    @Published var isFront = false
    @Published var body: [Joint: CGPoint] = [:]
    @Published var ghost: [Joint: CGPoint] = [:]
    @Published var poseMatched = false
    @Published var countdown: Int?
    @Published var selectedPoseID = "free"
    @Published var importedPose: RefPose?
    @Published var silhouette: UIImage?
    @Published var referenceImage: UIImage?
    @Published var guideStyle = 0                 // 0 photo, 1 silhouette
    @Published var guideOpacity: Double = 0.5
    @Published var guideOffset: CGSize = .zero     // fraction of the viewfinder
    @Published var guideScale: CGFloat = 1
    @Published var guideFlipped = false {
        didSet { let f = guideFlipped; videoQueue.async { self.vGuideFlipped = f } }
    }

    // Carousel
    @Published var carouselStep: CarouselStep = .full
    @Published var carouselShots: [CarouselShot] = []
    @Published var carouselReady = false
    @Published var carouselReviewOpen = false

    // Review after a shot
    @Published var reviewImage: UIImage?
    @Published var reviewOriginal: UIImage?
    @Published var lookThumbs: [String: UIImage] = [:]
    @Published var selectedLook = "teal"
    @Published var recommendedLook = "teal"
    @Published var recommendReason = ""
    @Published var intensity: Double = 1
    @Published var savingReview = false
    @Published var frameStyle = 0

    // Settings (stored)
    @Published var voiceOn: Bool { didSet { store("voiceOn", voiceOn); if !voiceOn { speaker.stop() } } }
    @Published var autoShot: Bool {
        didSet {
            store("autoShot", autoShot)
            let on = autoShot
            videoQueue.async { self.vAutoShot = on; self.resetPoseTimers() }
            if !on { autoProgress = nil }
        }
    }
    @Published var showGrid: Bool { didSet { store("showGrid", showGrid) } }
    @Published var keepCopy: Bool { didSet { store("keepCopy", keepCopy) } }
    @Published var fullResolution: Bool {
        didSet { store("fullResolution", fullResolution); sessionQueue.async { self.applyPhotoSize() } }
    }

    let session = AVCaptureSession()
    private let speaker = Speaker()
    private let defaults = UserDefaults.standard

    // MARK: Queues and camera

    private let sessionQueue = DispatchQueue(label: "aimframe.session")
    private let videoQueue = DispatchQueue(label: "aimframe.video", qos: .userInitiated)
    private let gradeQueue = DispatchQueue(label: "aimframe.grade", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let motion = CMMotionManager()
    private var configured = false

    // The device is set on the session queue and read on the video queue: guard it.
    private let lock = NSLock()
    private var _device: AVCaptureDevice?
    private var _wideFactor: CGFloat = 1
    private var device: AVCaptureDevice? { lock.lock(); defer { lock.unlock() }; return _device }
    private var wideFactor: CGFloat { lock.lock(); defer { lock.unlock() }; return _wideFactor }

    // MARK: Main-thread guide state

    private var phaseSince: CFTimeInterval = 0
    private var stabilizer = HintStabilizer()
    private var auto = AutoShot()
    private var steadySince: CFTimeInterval = 0
    private var lastMotion: CFTimeInterval = 0
    private var nextAutoScan: CFTimeInterval = 0
    private var overlayOpen = false
    private var active = true
    private var captureKind: AppMode = .landscape
    private var captureStep: CarouselStep = .full
    private var captureInFlight = false
    private var shotAttitude: CMAttitude?        // where the phone pointed at the last shot

    // MARK: Video-queue state

    private var paused = false
    private var vMode: AppMode = .landscape
    private var vFront = false
    private var vAutoShot = true
    private var frameCount = 0
    private var analysisEvery = 2               // analyse one frame in N; raised when the phone is hot
    private var analysisStopped = false

    // Landscape (Vision coordinates, origin bottom left)
    private var wantScan = false
    private var tracker: VNTrackObjectRequest?
    private var sequence = VNSequenceRequestHandler()
    private var smoothBox: CGRect?
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    private var zoomMult: CGFloat = 1
    private var zoomStarted = false
    private var homeZoom: CGFloat?              // zoom before the guide zoomed in; restored when the guide ends
    private var scanNotBefore: CFTimeInterval = 0
    private var baseZoom: CGFloat = 1
    private var lockRun = 0
    private var lostRun = 0
    private var locked = false
    private var aimAxis: AimAxis?
    private var advice = ""
    private var meterBox: CGRect?               // subject area for the exposure decision

    // Exposure
    private var exposure = ExposureDecider()
    private var vLight: LightLevel = .good
    private var tick = 0

    // Outfit / carousel body
    private var vStep: CarouselStep = .full
    private var refPose: RefPose?
    private var vPhotoGuide = false
    private var vGuideFlipped = false
    private var useMirror = false
    private var smoothJoints: [Joint: CGPoint] = [:]
    private var poseHoldStart: CFTimeInterval?
    private var countdownEnd: CFTimeInterval?
    private var countdownCancelled = false
    private var lastMatched: CFTimeInterval = 0
    private var cooldownUntil: CFTimeInterval = 0

    // Review (gradeQueue)
    private var reviewData: Data?
    private var reviewBase: CIImage?
    private var reviewLight = LightFix()
    private var renderToken = 0

    // MARK: Init

    override init() {
        let d = UserDefaults.standard
        voiceOn = d.object(forKey: "voiceOn") as? Bool ?? true
        autoShot = d.object(forKey: "autoShot") as? Bool ?? true
        showGrid = d.object(forKey: "showGrid") as? Bool ?? true
        keepCopy = d.object(forKey: "keepCopy") as? Bool ?? true
        fullResolution = d.object(forKey: "fullResolution") as? Bool ?? false
        super.init()
        vAutoShot = autoShot
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        center.addObserver(self, selector: #selector(sessionResumed(_:)), name: .AVCaptureSessionInterruptionEnded, object: session)
        center.addObserver(self, selector: #selector(sessionFailed(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        center.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    private func store(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }

    // MARK: Start, stop, interruptions

    /// Asks for the camera (after the onboarding) and starts it.
    func start() {
        setPaused(false)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status = .granted
            sessionQueue.async { self.configure() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.status = granted ? .granted : .denied }
                if granted { self.sessionQueue.async { self.configure() } }
            }
        default:
            status = .denied
        }
        startMotion()
        thermalChanged()
    }

    /// Called when the app goes to the background and comes back.
    func setActive(_ on: Bool) {
        active = on
        if on {
            guard status == .granted else { return }
            sessionQueue.async { if self.configured && !self.session.isRunning { self.session.startRunning() } }
            startMotion()
        } else {
            speaker.stop()
            cancelAutoShot()
            cancelCountdown()
            motion.stopDeviceMotionUpdates()
            sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        }
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        DispatchQueue.main.async { self.systemNote = "Fotocamera in pausa: la sta usando un'altra app o una chiamata" }
    }

    @objc private func sessionResumed(_ note: Notification) {
        DispatchQueue.main.async { self.systemNote = "" }
    }

    @objc private func sessionFailed(_ note: Notification) {
        sessionQueue.async {
            if self.active && !self.session.isRunning { self.session.startRunning() }
        }
        DispatchQueue.main.async { self.showToast("La fotocamera si è fermata: la riavvio") }
    }

    @objc private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let every: Int
        let stop: Bool
        let note: String
        switch state {
        case .serious: every = 4; stop = false; note = "iPhone caldo: analisi rallentata"
        case .critical: every = 4; stop = true; note = "iPhone molto caldo: guida sospesa, puoi scattare a mano"
        default: every = 2; stop = false; note = ""
        }
        videoQueue.async {
            self.analysisEvery = every
            self.analysisStopped = stop
        }
        DispatchQueue.main.async { if self.systemNote.isEmpty || self.systemNote.hasPrefix("iPhone") { self.systemNote = note } }
    }

    // MARK: Camera setup (sessionQueue)

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
        guard attachCamera(.back) else {
            DispatchQueue.main.async { self.status = .unavailable }
            return
        }
        session.startRunning()
    }

    @discardableResult
    private func attachCamera(_ position: AVCaptureDevice.Position) -> Bool {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        guard let cam = found.first, let input = try? AVCaptureDeviceInput(device: cam) else { return false }
        session.beginConfiguration()
        for old in session.inputs { session.removeInput(old) }
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()

        // Lenses: the switch-over zoom factors say where the ultra-wide ends and each tele lens starts.
        var wide: CGFloat = 1
        var presets: [CGFloat] = [1, 2]
        let switches = cam.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        if cam.deviceType == .builtInTripleCamera || cam.deviceType == .builtInDualWideCamera, let first = switches.first {
            wide = first
            presets = [0.5, 1, 2] + switches.dropFirst().map { ($0 / first * 10).rounded() / 10 }
        } else if cam.deviceType == .builtInDualCamera, let tele = switches.first {
            presets = [1, (tele * 10).rounded() / 10]
        }
        presets = Array(Set(presets)).filter { $0 * wide <= cam.maxAvailableVideoZoomFactor }.sorted()
        if position == .front { presets = [1] }

        lock.lock()
        _device = cam
        _wideFactor = wide
        maxPreset = presets.max() ?? 1
        lock.unlock()

        applyPhotoSize()
        orient(videoOutput.connection(with: .video), mirrored: false)
        // The saved selfie matches the mirrored preview, like the iPhone camera.
        orient(photoOutput.connection(with: .video), mirrored: position == .front)

        let front = position == .front
        let shownPresets = presets
        videoQueue.async {
            self.vFront = front
            self.exposure.reset()
        }
        DispatchQueue.main.async {
            self.isFront = front
            self.zoomPresets = shownPresets
            self.lightNote = ""
        }
        applyZoom(display: 1, ramp: false)
        return true
    }

    /// Up to about 24 MP by default; the full 48 MP only when chosen in the settings.
    private func applyPhotoSize() {
        guard let cam = device else { return }
        let sizes = cam.activeFormat.supportedMaxPhotoDimensions
        let pixels: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        let chosen: CMVideoDimensions?
        if fullResolution {
            chosen = sizes.max(by: { pixels($0) < pixels($1) })
        } else {
            chosen = sizes.filter { pixels($0) <= 25_000_000 }.max(by: { pixels($0) < pixels($1) })
                ?? sizes.min(by: { pixels($0) < pixels($1) })
        }
        if let size = chosen { photoOutput.maxPhotoDimensions = size }
    }

    private func orient(_ connection: AVCaptureConnection?, mirrored: Bool) {
        guard let connection = connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    func flipCamera() {
        let next: AVCaptureDevice.Position = isFront ? .back : .front
        Haptics.tap()
        sessionQueue.async {
            if !self.attachCamera(next) { DispatchQueue.main.async { self.showToast("Questa fotocamera non è disponibile") } }
        }
    }

    // MARK: Motion and the automatic shot (main thread)

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let g = data.gravity
            let across = (g.x * g.x + g.y * g.y).squareRoot()
            self.roll = across > 0.35 ? atan2(g.x, -g.y) : nil
            let r = data.rotationRate
            self.tickAuto(rate: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(), attitude: data.attitude)
        }
    }

    private func tickAuto(rate: Double, attitude: CMAttitude) {
        let now = CACurrentMediaTime()
        lastMotion = now
        let still = rate < 0.12
        if !still { steadySince = now }

        guard active, autoShot, reviewImage == nil, !overlayOpen, !carouselReviewOpen, !captureInFlight, mode != .outfit else {
            if autoProgress != nil { autoProgress = nil }
            steadySince = now
            return
        }
        // Re-arm only once the phone points somewhere else than at the last shot.
        if let shot = shotAttitude {
            guard let turned = attitude.copy() as? CMAttitude else { return }
            turned.multiply(byInverseOf: shot)
            let w = min(1, abs(turned.quaternion.w))
            auto.observe(angleSinceShot: 2 * acos(w))
        }
        switch mode {
        case .landscape:
            if phase == .free {
                if !auto.armed {
                    show(.info("Fatto. Gira il telefono verso un'altra scena"))
                } else if now - steadySince > 0.8 && now > nextAutoScan {
                    nextAutoScan = now + 3
                    startScan()
                } else {
                    show(.info("Punta il telefono sulla scena e tienilo fermo"))
                }
            } else if phase == .lost && now - phaseSince > 2 {
                clearGuide()
            }
            let fire = auto.update(now: now, ready: phase == .locked && lightLevel != .veryLow, steady: still, enabled: true)
            autoProgress = auto.progress
            if fire { capture(automatic: true) }
        case .carousel:
            let fire = auto.update(now: now, ready: carouselReady && carouselStep.usesBody && lightLevel != .veryLow, steady: still, enabled: true)
            autoProgress = auto.progress
            if fire { capture(automatic: true) }
        case .outfit:
            break
        }
    }

    func cancelAutoShot() {
        auto.cancel()
        autoProgress = nil
        Haptics.warning()
    }

    /// Shows an instruction, steadied so it does not flicker; speaks it if it is for the person posing.
    private func show(_ next: Instruction, urgent: Bool = false) {
        let shown = stabilizer.update(next, now: CACurrentMediaTime(), urgent: urgent)
        if shown != instruction { instruction = shown }
        // Offered on every update: the speaker itself waits its turn and avoids repeating within 8 s.
        if voiceOn && mode != .landscape && shown.audience == .subject && reviewImage == nil { speaker.say(shown.text) }
    }

    // MARK: Zoom

    /// `display` is what the user sees: 0.5, 1, 2, 3…
    func setZoom(display: CGFloat) {
        Haptics.selection()
        videoQueue.async { self.homeZoom = nil }            // the user chose this zoom: keep it
        sessionQueue.async { self.applyZoom(display: display, ramp: true) }
    }

    private func applyZoom(display: CGFloat, ramp: Bool) {
        guard let cam = device else { return }
        let wide = wideFactor
        let upper = min(cam.maxAvailableVideoZoomFactor, max(zoomPresetsMax(), 1) * wide)
        let factor = min(max(display * wide, cam.minAvailableVideoZoomFactor), upper)
        do {
            try cam.lockForConfiguration()
            if ramp { cam.ramp(toVideoZoomFactor: factor, withRate: 1.6) } else { cam.videoZoomFactor = factor }
            cam.unlockForConfiguration()
        } catch {
            return
        }
        let shown = factor / wide
        DispatchQueue.main.async { self.zoomShown = shown }
    }

    private var maxPreset: CGFloat = 2
    private func zoomPresetsMax() -> CGFloat {
        lock.lock(); defer { lock.unlock() }
        return maxPreset
    }

    private func currentDisplayZoom() -> CGFloat {
        guard let cam = device else { return 1 }
        return cam.videoZoomFactor / wideFactor
    }

    // MARK: Landscape: scan and guide

    /// The spark button: scan, or clear the guide.
    func scanOrClear() {
        Haptics.tap()
        if phase == .free || phase == .lost { startScan() } else { clearGuide() }
    }

    private func startScan() {
        guard mode == .landscape else { return }
        phase = .scanning
        show(.info("Analizzo la scena…"), urgent: true)
        videoQueue.async {
            self.resetTracking(restoreZoom: true)
            self.wantScan = true
        }
    }

    private func clearGuide() {
        videoQueue.async { self.resetTracking(restoreZoom: true) }
        phase = .free
        subjectBox = nil
        label = ""
        composition = nil
        autoProgress = nil
        stabilizer.reset()
        show(.info(autoShot ? "Punta il telefono sulla scena e tienilo fermo" : "Tocca ✦ per analizzare la scena"), urgent: true)
    }

    /// videoQueue
    private func resetTracking(restoreZoom: Bool) {
        tracker?.isLastFrame = true
        tracker = nil
        wantScan = false
        locked = false
        lockRun = 0
        lostRun = 0
        smoothBox = nil
        meterBox = nil
        aimAxis = nil
        if restoreZoom, let back = homeZoom {
            homeZoom = nil
            scanNotBefore = CACurrentMediaTime() + 0.8      // let the zoom settle before the next scan
            sessionQueue.async { self.applyZoom(display: back, ramp: true) }
        }
        zoomStarted = false
    }

    private func bestBox(_ results: [VNSaliencyImageObservation]?) -> (CGRect, Float)? {
        guard let objects = results?.first?.salientObjects, let best = objects.max(by: { $0.confidence < $1.confidence }) else { return nil }
        return (best.boundingBox, best.confidence)
    }

    /// videoQueue
    private func runScan(_ pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let classify = VNClassifyImageRequest()
        do {
            try handler.perform([objectness, attention, classify])
        } catch {
            publishScanFailure("Analisi non riuscita. Riprova.")
            return
        }
        let found = bestBox(objectness.results) ?? bestBox(attention.results)
        guard let raw = found?.0, raw.width > 0.02, raw.height > 0.02 else {
            publishScanFailure("Non trovo un soggetto chiaro: avvicinati a qualcosa o cambia scena")
            return
        }
        let w = min(max(raw.width, 0.12), 0.7), h = min(max(raw.height, 0.12), 0.7)
        let box = CGRect(x: min(max(raw.midX - w / 2, 0), 1 - w), y: min(max(raw.midY - h / 2, 0), 1 - h), width: w, height: h)

        // A name only when Apple's classifier is fairly sure; otherwise no invented subject.
        let name = (classify.results ?? [])
            .filter { $0.confidence > 0.5 }
            .max(by: { $0.confidence < $1.confidence })?
            .identifier.replacingOccurrences(of: "_", with: " ")
        advice = Self.advice(for: pixelBuffer, subject: box)

        anchor = CGPoint(x: box.midX < 0.4 ? 1.0 / 3.0 : (box.midX > 0.6 ? 2.0 / 3.0 : 0.5),
                         y: box.midY < 0.4 ? 1.0 / 3.0 : (box.midY > 0.6 ? 2.0 / 3.0 : 0.5))
        let mult = min(max(0.45 / max(box.width, box.height), 1), 2.5)
        zoomMult = mult < 1.3 ? 1 : mult
        zoomStarted = false
        baseZoom = currentDisplayZoom()
        lockRun = 0
        lostRun = 0
        locked = false
        aimAxis = nil
        smoothBox = box
        meterBox = box
        exposure.reset()
        resetBias()

        sequence = VNSequenceRequestHandler()
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        request.trackingLevel = .accurate
        tracker = request

        let shownBox = flip(box)
        DispatchQueue.main.async {
            guard self.mode == .landscape, self.phase == .scanning else { return }
            self.label = name ?? "Soggetto"
            self.subjectBox = shownBox
            self.phase = .guiding
        }
    }

    private func publishScanFailure(_ text: String) {
        DispatchQueue.main.async {
            guard self.mode == .landscape else { return }
            self.phase = .lost
            self.show(.warning(text), urgent: true)
        }
    }

    /// videoQueue
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
        lostRun = seen.confidence < 0.3 ? lostRun + 1 : 0
        if lostRun > 12 {
            markLost()
            return
        }

        // Smooth the box so the guide does not shake with the tracker.
        let rawBox = seen.boundingBox
        let previous = smoothBox ?? rawBox
        let k: CGFloat = 0.35
        let box = CGRect(x: previous.minX + (rawBox.minX - previous.minX) * k, y: previous.minY + (rawBox.minY - previous.minY) * k,
                         width: previous.width + (rawBox.width - previous.width) * k, height: previous.height + (rawBox.height - previous.height) * k)
        smoothBox = box
        meterBox = box
        let m = zoomMult

        if m > 1 && !zoomStarted {
            let fitsX = abs(box.midX - 0.5) * m + box.width * m / 2 < 0.46
            let fitsY = abs(box.midY - 0.5) * m + box.height * m / 2 < 0.46
            if fitsX && fitsY {
                zoomStarted = true
                if homeZoom == nil { homeZoom = baseZoom }
                let goal = min(baseZoom * m, min(zoomPresetsMax(), 3))
                sessionQueue.async { self.applyZoom(display: goal, ramp: true) }
            }
        }
        let zoomDone = m == 1 || (zoomStarted && !(device?.isRampingVideoZoom ?? false))

        let goalPoint = (m == 1 || zoomStarted) ? anchor
            : CGPoint(x: 0.5 + (anchor.x - 0.5) / m, y: 0.5 + (anchor.y - 0.5) / m)
        let dx = box.midX - goalPoint.x
        let dy = box.midY - goalPoint.y
        let far = max(abs(dx), abs(dy))

        if !locked {
            lockRun = (far < 0.05 && zoomDone) ? lockRun + 1 : 0
            if lockRun >= 8 { locked = true }
        } else if far > 0.1 {
            locked = false
            lockRun = 0
        }

        let next: Instruction
        if locked, let warn = LightCheck.advice(vLight) {
            next = .warning(warn)
        } else if locked {
            next = .good(advice.isEmpty ? "Inquadratura giusta: resta fermo" : advice)
        } else if let text = Aim.instruction(dx: dx, dy: dy, axis: &aimAxis) {
            next = .guide(text, for: .photographer)
        } else if !zoomDone {
            next = .info("Avvicino l'inquadratura…")
        } else if zoomStarted && max(box.width, box.height) < 0.2 {
            next = .guide("Avvicinati al soggetto", for: .photographer)
        } else {
            next = .info("Tieni fermo…")
        }

        let shownBox = flip(box)
        let shownTarget = CGPoint(x: goalPoint.x, y: 1 - goalPoint.y)
        let nowLocked = locked
        DispatchQueue.main.async {
            guard self.mode == .landscape, self.phase == .guiding || self.phase == .locked else { return }
            let wasLocked = self.phase == .locked
            self.subjectBox = shownBox
            self.target = shownTarget
            self.phase = nowLocked ? .locked : .guiding
            self.composition = Composition.evaluate(roll: self.roll, box: shownBox, distance: far, light: self.lightLevel)
            if nowLocked && !wasLocked { Haptics.success() }
            self.show(next, urgent: nowLocked != wasLocked)
        }
    }

    private func markLost() {
        resetTracking(restoreZoom: false)
        DispatchQueue.main.async {
            guard self.mode == .landscape else { return }
            self.phase = .lost
            self.subjectBox = nil
            self.composition = nil
            self.autoProgress = nil
            Haptics.warning()
            self.show(.warning(self.autoShot ? "Ho perso il soggetto: riprovo tra poco" : "Ho perso il soggetto: tocca ✦ per riprovare"), urgent: true)
        }
    }

    /// One line from measured brightness: subject compared with the whole frame.
    private static func advice(for pixelBuffer: CVPixelBuffer, subject box: CGRect) -> String {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let e = image.extent
        let whole = Grade.average(image, rect: e)
        let sub = Grade.average(image, rect: CGRect(x: e.minX + box.minX * e.width, y: e.minY + box.minY * e.height,
                                                    width: box.width * e.width, height: box.height * e.height))
        let lightAll = (whole.r + whole.g + whole.b) / 3
        let lightSub = (sub.r + sub.g + sub.b) / 3
        if lightSub > lightAll * 1.15 { return "Soggetto più luminoso dello sfondo: resta fermo" }
        if lightSub < lightAll * 0.7 { return "Soggetto in controluce: verrà scuro, va bene per una silhouette" }
        return "Inquadratura giusta: resta fermo"
    }

    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Exposure (videoQueue)

    private func resetBias() {
        sessionQueue.async {
            guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
            cam.setExposureTargetBias(0, completionHandler: nil)
            cam.unlockForConfiguration()
        }
        DispatchQueue.main.async { self.lightNote = "" }
    }

    private func measureLight(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        // Subject area in pixel rows (the buffer's rows go top-down, Vision's y goes up).
        var sx0 = -1, sx1 = -1, sy0 = -1, sy1 = -1
        if let b = meterBox {
            sx0 = Int(b.minX * CGFloat(w)); sx1 = Int(b.maxX * CGFloat(w))
            sy0 = Int((1 - b.maxY) * CGFloat(h)); sy1 = Int((1 - b.minY) * CGFloat(h))
        }
        var sum = 0, count = 0, bright = 0, subSum = 0, subCount = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let v = Int(luma[y * rowBytes + x])
                sum += v
                count += 1
                if v >= 250 { bright += 1 }
                if x >= sx0 && x < sx1 && y >= sy0 && y < sy1 { subSum += v; subCount += 1 }
                x += 12
            }
            y += 12
        }
        guard count > 0 else { return }
        let mean = Double(sum) / Double(count) / 255
        let highlights = Double(bright) / Double(count)
        let subjectMean: Double? = subCount > 8 ? Double(subSum) / Double(subCount) / 255 : nil
        guard let bias = exposure.update(mean: mean, highlights: highlights, subjectMean: subjectMean) else { return }
        let note = exposure.note
        sessionQueue.async {
            guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
            cam.setExposureTargetBias(max(cam.minExposureTargetBias, min(cam.maxExposureTargetBias, bias)), completionHandler: nil)
            cam.unlockForConfiguration()
        }
        DispatchQueue.main.async { self.lightNote = note }
    }

    private func publishExposure() {
        guard let cam = device else { return }
        let seconds = CMTimeGetSeconds(cam.exposureDuration)
        guard seconds > 0, seconds.isFinite else { return }
        let shutter = seconds >= 1 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
        let text = "\(shutter)  ISO \(Int(cam.iso.rounded()))"
        vLight = LightCheck.level(iso: Double(cam.iso), seconds: seconds, previous: vLight)
        let level = vLight
        DispatchQueue.main.async {
            if self.exposureText != text { self.exposureText = text }
            if self.lightLevel != level { self.lightLevel = level }
        }
    }

    // MARK: Modes

    func setMode(_ newMode: AppMode) {
        guard newMode != mode else { return }
        Haptics.selection()
        mode = newMode
        speaker.stop()
        body = [:]
        ghost = [:]
        poseMatched = false
        countdown = nil
        carouselReady = false
        autoProgress = nil
        auto.reset()
        stabilizer.reset()
        phase = .free
        subjectBox = nil
        label = ""
        composition = nil
        let step = carouselStep
        videoQueue.async {
            self.resetTracking(restoreZoom: true)
            self.vMode = newMode
            self.vStep = step
            self.smoothJoints = [:]
            self.resetPoseTimers()
            self.exposure.reset()
        }
        resetBias()
        if newMode == .landscape && isFront { sessionQueue.async { self.attachCamera(.back) } }
        switch newMode {
        case .landscape: show(.info(autoShot ? "Punta il telefono sulla scena e tienilo fermo" : "Tocca ✦ per analizzare la scena"), urgent: true)
        case .outfit: show(.info("Inquadra la persona dalla testa ai piedi"), urgent: true)
        case .carousel: show(.info(carouselStep.tip), urgent: true)
        }
    }

    // MARK: Outfit: poses and guide photo

    func selectPose(_ pose: RefPose?) {
        Haptics.selection()
        selectedPoseID = pose?.id ?? "free"
        ghost = [:]
        let photoGuide = pose?.id == "import"
        videoQueue.async {
            self.vPhotoGuide = photoGuide
            self.refPose = pose
            self.useMirror = false
            self.resetPoseTimers()
        }
    }

    func resetGuideTransform() {
        guideOffset = .zero
        guideScale = 1
        guideFlipped = false
    }

    func cancelCountdown() {
        countdown = nil
        videoQueue.async {
            self.countdownCancelled = true
            self.resetPoseTimers()
        }
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

    /// Only joints Vision is reasonably sure about; uncertain ones are left out, not guessed.
    private static func joints(from observation: VNHumanBodyPoseObservation, minimum: Float = 0.5) -> [Joint: CGPoint] {
        guard let points = try? observation.recognizedPoints(.all) else { return [:] }
        var out: [Joint: CGPoint] = [:]
        for (name, joint) in jointNames {
            if let p = points[name], p.confidence >= minimum { out[joint] = p.location }
        }
        return out
    }

    /// videoQueue: body analysis for Outfit and the carousel's body shots.
    private func runBody(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([request])
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        let now = CACurrentMediaTime()

        var seen: [Joint: CGPoint] = [:]
        if let observation = request.results?.first { seen = Self.joints(from: observation) }
        var joints: [Joint: CGPoint] = [:]
        for (j, p) in seen {
            if let old = smoothJoints[j] {
                joints[j] = CGPoint(x: old.x + (p.x - old.x) * 0.5, y: old.y + (p.y - old.y) * 0.5)
            } else {
                joints[j] = p
            }
        }
        smoothJoints = joints
        meterBox = Self.bodyBox(joints)

        if vMode == .carousel {
            let issue = BodyFraming.issue(step: vStep, joints: joints, selfie: vFront)
            let next = issue ?? (LightCheck.advice(vLight).map { Instruction.warning($0) }
                ?? .good(vAutoShot ? "Pronto: tieni fermo, scatto da solo" : "Pronto: scatta"))
            publishBody(body: joints, ghost: [:], matched: false, count: nil, next: next, carouselReady: issue == nil)
            return
        }

        guard joints[.neck] != nil, joints[.root] != nil else {
            resetPoseTimers()
            let text = vPhotoGuide ? "Ricalca la foto guida e scatta" : "Inquadra la persona dalla testa ai piedi"
            publishBody(body: joints, ghost: [:], matched: false, count: nil,
                        next: vPhotoGuide ? .info(text) : .guide(text, for: .photographer), carouselReady: false)
            return
        }

        let facing = joints[.nose] != nil
        var next = LightCheck.advice(vLight).map { Instruction.warning($0) } ?? Instruction.good("Inquadratura ok: scatta quando vuoi")
        var matched = false
        var ghostJoints: [Joint: CGPoint] = [:]
        let fullRef = (refPose?.angles.count ?? 0) >= 6

        if vPhotoGuide && !fullRef {
            next = .info("Ricalca la foto guida e scatta")
        } else if !vPhotoGuide, let issue = BodyFraming.issue(step: .full, joints: joints, selfie: vFront) {
            next = issue
        } else if let ref = refPose {
            let user = PoseMath.angles(joints, aspect: aspect)
            let target: [Limb: CGFloat]
            let result: PoseComparison
            if ref.id == "import" {
                // The guide photo is shown as the user placed it: compare with that orientation only.
                target = vGuideFlipped ? PoseMath.mirror(ref.angles) : ref.angles
                result = PoseMath.compare(user: user, ref: target)
            } else {
                let mirrored = PoseMath.mirror(ref.angles)
                let direct = PoseMath.compare(user: user, ref: ref.angles)
                let flipped = PoseMath.compare(user: user, ref: mirrored)
                if useMirror {
                    if direct.score > flipped.score + 0.08 { useMirror = false }
                } else if flipped.score > direct.score + 0.08 {
                    useMirror = true
                }
                target = useMirror ? mirrored : ref.angles
                result = useMirror ? flipped : direct
                ghostJoints = PoseMath.ghost(joints: joints, ref: target, aspect: aspect)
            }
            matched = result.matched
            if matched {
                next = .good("Perfetto, resta così", for: .subject)
            } else if let limb = result.worst, let u = user[limb], let r = target[limb] {
                next = .guide(PoseMath.instruction(limb: limb, user: u, ref: r, joints: joints, facing: facing), for: .subject)
            } else {
                next = .guide("Fatti vedere meglio: non riconosco braccia o gambe", for: .subject)
            }
        }

        // Countdown: the pose must hold for a second, then 3 seconds that can be cancelled.
        if !matched { countdownCancelled = false }
        var count: Int?
        if matched && vAutoShot && !countdownCancelled && now > cooldownUntil {
            lastMatched = now
            if poseHoldStart == nil { poseHoldStart = now }
            if countdownEnd == nil, let start = poseHoldStart, now - start > 1.0 { countdownEnd = now + 3 }
        } else if now - lastMatched > 0.6 {
            resetPoseTimers()
        }
        if let end = countdownEnd {
            if now >= end {
                resetPoseTimers()
                cooldownUntil = now + 4
                DispatchQueue.main.async { self.capture(automatic: true) }
            } else {
                count = Int((end - now).rounded(.up))
            }
        }
        publishBody(body: joints, ghost: ghostJoints, matched: matched, count: count, next: next, carouselReady: false)
    }

    private static func bodyBox(_ j: [Joint: CGPoint]) -> CGRect? {
        let pts = Array(j.values)
        guard pts.count >= 3 else { return nil }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 0.05), height: max(y1 - y0, 0.05))
    }

    private func publishBody(body: [Joint: CGPoint], ghost: [Joint: CGPoint], matched: Bool, count: Int?, next: Instruction, carouselReady: Bool) {
        let front = vFront
        func shown(_ joints: [Joint: CGPoint]) -> [Joint: CGPoint] {
            var out: [Joint: CGPoint] = [:]
            for (j, p) in joints { out[j] = CGPoint(x: front ? 1 - p.x : p.x, y: 1 - p.y) }
            return out
        }
        let shownBody = shown(body), shownGhost = shown(ghost)
        DispatchQueue.main.async {
            guard self.mode != .landscape, self.reviewImage == nil else { return }
            self.body = shownBody
            self.ghost = shownGhost
            if matched && !self.poseMatched { Haptics.success() }
            self.poseMatched = matched
            if count != self.countdown, count != nil { Haptics.tap() }
            self.countdown = count
            self.carouselReady = carouselReady
            if let n = count {
                self.show(.good("Scatto tra \(n)…", for: .subject), urgent: true)
            } else {
                self.show(next, urgent: matched)
            }
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

    /// Uses a photo (camera roll, clipboard or web) as the guide. The photo is always kept;
    /// the pose and the cut-out figure are added only when a person is found.
    func importInspiration(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let picked = UIImage(data: data) else {
                self.showToast("Non riesco ad aprire questa foto.")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let scale = min(1, 1280 / max(picked.size.width, picked.size.height))
            let size = CGSize(width: max(1, (picked.size.width * scale).rounded()), height: max(1, (picked.size.height * scale).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                picked.draw(in: CGRect(origin: .zero, size: size))
            }
            var angles: [Limb: CGFloat] = [:]
            var shape: UIImage?
            if let cgImage = upright.cgImage {
                let request = VNDetectHumanBodyPoseRequest()
                let segmentation = VNGeneratePersonSegmentationRequest()
                segmentation.qualityLevel = .accurate
                segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
                try? VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request, segmentation])
                var joints: [Joint: CGPoint] = [:]
                if let observation = request.results?.first { joints = Self.joints(from: observation) }
                angles = PoseMath.angles(joints, aspect: size.width / size.height)
                if !angles.isEmpty, let mask = segmentation.results?.first?.pixelBuffer {
                    shape = Self.silhouetteImage(mask: mask, size: size)
                }
            }
            let pose = RefPose(id: "import", name: "Foto guida", angles: angles)
            let message = angles.count >= 6 ? "Foto guida pronta: posa riconosciuta" : "Foto guida pronta: ricalcala e scatta tu"
            DispatchQueue.main.async {
                self.referenceImage = upright
                self.silhouette = shape
                if shape == nil { self.guideStyle = 0 }
                self.resetGuideTransform()
                self.importedPose = pose
                self.selectPose(pose)
                self.showToast(message)
                completion?(true)
            }
        }
    }

    private static func silhouetteImage(mask buffer: CVPixelBuffer, size: CGSize) -> UIImage? {
        let raw = CIImage(cvPixelBuffer: buffer)
        guard raw.extent.width > 0, raw.extent.height > 0 else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        let mask = raw.transformed(by: CGAffineTransform(scaleX: size.width / raw.extent.width,
                                                         y: size.height / raw.extent.height)).cropped(to: rect)
        let soft = CIFilter.colorMatrix()
        soft.inputImage = mask
        soft.rVector = CIVector(x: 0.4, y: 0, z: 0, w: 0)
        soft.gVector = CIVector(x: 0, y: 0.4, z: 0, w: 0)
        soft.bVector = CIVector(x: 0, y: 0, z: 0.4, w: 0)
        soft.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let edge = CIFilter.morphologyGradient()
        edge.inputImage = mask
        edge.radius = Float(max(2, size.width / 220))
        guard let fillMask = soft.outputImage, let edgeMask = edge.outputImage?.cropped(to: rect) else { return nil }
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        let ivory = CIImage(color: CIColor(red: 0.99, green: 0.95, blue: 0.84)).cropped(to: rect)
        let yellow = CIImage(color: CIColor(red: 1, green: 0.79, blue: 0.01)).cropped(to: rect)
        let fill = CIFilter.blendWithMask()
        fill.inputImage = ivory
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

    func importFromClipboard() {
        guard let image = UIPasteboard.general.image, let data = image.jpegData(compressionQuality: 0.9) else {
            showToast("Negli appunti non c'è una foto. Copiala e riprova.")
            return
        }
        importInspiration(data)
    }

    // MARK: Carousel

    func setCarouselStep(_ step: CarouselStep) {
        Haptics.selection()
        carouselStep = step
        carouselReady = false
        auto.reset()
        autoProgress = nil
        videoQueue.async { self.vStep = step; self.smoothJoints = [:] }
        show(.info(step.tip), urgent: true)
    }

    func removeCarouselShot(_ shot: CarouselShot) {
        carouselShots.removeAll { $0.id == shot.id }
    }

    func openCarouselReview() {
        guard !carouselShots.isEmpty else { return }
        carouselReviewOpen = true
        setPaused(true)
    }

    func closeCarouselReview(clear: Bool) {
        carouselReviewOpen = false
        setPaused(false)
        if clear {
            carouselShots = []
            setCarouselStep(.full)
        }
    }

    private func addCarouselShot(_ data: Data, step: CarouselStep) {
        let thumb = Self.thumbnail(from: data, size: 360)
        DispatchQueue.main.async {
            self.carouselShots.removeAll { $0.step == step }
            self.carouselShots.append(CarouselShot(step: step, data: data, thumb: thumb))
            self.carouselShots.sort { $0.step.rawValue < $1.step.rawValue }
            let done = Set(self.carouselShots.map { $0.step })
            if let next = CarouselStep.allCases.first(where: { !done.contains($0) }) {
                self.setCarouselStep(next)
                self.showToast("\(step.title): fatto")
            } else {
                self.openCarouselReview()
            }
        }
    }

    /// Previews for the carousel review: one shared look over every photo.
    func carouselPreview(_ shot: CarouselShot, look: String, intensity: Double, frame: Int, completion: @escaping (UIImage?) -> Void) {
        gradeQueue.async {
            guard let full = CIImage(data: shot.data, options: [.applyOrientationProperty: true]) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let base = Grade.scaled(full, maxSide: 900)
            let fix = Grade.measureLight(full)
            let image = Grade.uiImage(Grade.framed(Grade.render(base, look: Grade.look(look), intensity: CGFloat(intensity), light: fix), style: frame))
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Saves the whole carousel, one full-size photo at a time to keep memory low,
    /// and reports how many Photos really accepted.
    func saveCarousel(look: String, intensity: Double, frame: Int, completion: @escaping (Int, Int) -> Void) {
        let shots = carouselShots
        let keep = keepCopy
        gradeQueue.async {
            var saved = 0
            for shot in shots {
                let done = DispatchSemaphore(value: 0)
                var ok = false
                autoreleasepool {
                    let output = Grade.export(shot.data, look: look, intensity: intensity, frame: frame)
                    self.saveToPhotos(output, quiet: true) { result in
                        ok = result
                        if result && keep { GalleryStore.shared.add(output) }
                        done.signal()
                    }
                }
                done.wait()
                if ok { saved += 1 } else { break }
            }
            DispatchQueue.main.async {
                if saved == shots.count { self.showToast("Carosello salvato: \(saved) foto") }
                completion(saved, shots.count)
            }
        }
    }

    // MARK: Review and colour grade

    private func prepareReview(_ data: Data) {
        guard let full = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            saveToPhotos(data, quiet: false)
            return
        }
        let base = Grade.scaled(full, maxSide: 1400)
        let small = Grade.scaled(full, maxSide: 220)
        let pick = Grade.recommend(small)
        let fix = Grade.measureLight(full)
        var thumbs: [String: UIImage] = [:]
        for look in Grade.looks {
            if let t = Grade.uiImage(Grade.render(small, look: look, intensity: 1, light: fix)) { thumbs[look.id] = t }
        }
        reviewData = data
        reviewBase = base
        reviewLight = fix
        guard let preview = Grade.uiImage(Grade.render(base, look: Grade.look(pick.id), intensity: 1, light: fix)),
              let original = Grade.uiImage(base) else {
            reviewData = nil
            reviewBase = nil
            saveToPhotos(data, quiet: false)
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
            self.frameStyle = 0
            self.savingReview = false
            self.countdown = nil
            self.reviewOriginal = original
            self.reviewImage = preview
        }
    }

    func selectLook(_ id: String) {
        Haptics.selection()
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

    /// Back to the suggested look at full strength, no frame.
    func resetEdits() {
        Haptics.tap()
        selectedLook = recommendedLook
        intensity = 1
        frameStyle = 0
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
                  let image = Grade.uiImage(Grade.framed(Grade.render(base, look: Grade.look(id), intensity: amount, light: self.reviewLight), style: style)) else { return }
            DispatchQueue.main.async {
                if token == self.renderToken && self.reviewImage != nil { self.reviewImage = image }
            }
        }
    }

    func saveReview() {
        guard reviewImage != nil, !savingReview else { return }
        savingReview = true
        let id = selectedLook
        let amount = intensity
        let style = frameStyle
        let keep = keepCopy
        gradeQueue.async {
            guard let data = self.reviewData else {
                self.closeReview()
                return
            }
            let output = Grade.export(data, look: id, intensity: amount, frame: style)
            self.saveToPhotos(output, quiet: false) { saved in
                if saved {
                    if keep { GalleryStore.shared.add(output) }
                    self.gradeQueue.async { self.closeReview() }
                    DispatchQueue.main.async { Haptics.success() }
                } else {
                    // Keep the photo open so nothing is lost; the review shows how to allow access.
                    DispatchQueue.main.async {
                        self.savingReview = false
                        Haptics.warning()
                    }
                }
            }
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
            self.reviewOriginal = nil
            self.savingReview = false
            if self.mode == .landscape && self.phase != .free { self.clearGuide() }
        }
    }

    /// Writes to Photos and reports whether it really happened.
    private func saveToPhotos(_ data: Data, quiet: Bool, completion: ((Bool) -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.photosDenied = true }
                completion?(false)
                return
            }
            DispatchQueue.main.async { self.photosDenied = false }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { saved, _ in
                if !quiet || !saved { self.showToast(saved ? "Salvata in Foto" : "Salvataggio non riuscito: riprova") }
                completion?(saved)
            })
        }
    }

    // MARK: Capture

    /// The shutter button and the automatic shot.
    func capture(automatic: Bool = false) {
        guard status == .granted, reviewImage == nil, !captureInFlight else { return }
        if !automatic { auto.didShootManually() }
        shotAttitude = motion.deviceMotion?.attitude.copy() as? CMAttitude
        captureInFlight = true
        autoProgress = nil
        captureKind = mode
        captureStep = carouselStep
        flash = true
        Haptics.shutter()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.flash = false }
        sessionQueue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    self.captureInFlight = false
                    self.showToast("La fotocamera non è pronta")
                }
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.toast == text { self.toast = nil }
            }
        }
    }

    static func thumbnail(from data: Data, size: Int = 240) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Frames for the analysis

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        tick += 1
        if tick % 15 == 0 { publishExposure() }
        if tick % 8 == 0 { measureLight(pixelBuffer) }
        guard !analysisStopped else { return }
        frameCount += 1
        switch vMode {
        case .landscape:
            if wantScan && CACurrentMediaTime() >= scanNotBefore && !(device?.isRampingVideoZoom ?? false) {
                wantScan = false
                runScan(pixelBuffer)
            } else if tracker != nil && frameCount % analysisEvery == 0 {
                runTrack(pixelBuffer)
            }
        case .outfit:
            if frameCount % analysisEvery == 0 { runBody(pixelBuffer) }
        case .carousel:
            if vStep.usesBody && frameCount % (analysisEvery * 2) == 0 { runBody(pixelBuffer) }
        }
    }
}

// MARK: - Saving the photo

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.captureInFlight = false }
            showToast("Scatto non riuscito. Riprova.")
            return
        }
        let thumb = Self.thumbnail(from: data)
        DispatchQueue.main.async {
            self.lastThumb = thumb
            self.captureInFlight = false
            if self.captureKind == .carousel {
                let step = self.captureStep
                self.gradeQueue.async { self.addCarouselShot(data, step: step) }
            } else {
                self.gradeQueue.async { self.prepareReview(data) }
            }
        }
    }
}
