import AVFoundation
import Combine
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
    @Published var phase: GuidePhase = .free
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
    @Published var voiceOn = true
    @Published var autoShot = true

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
        videoQueue.async { self.vFront = front }
        DispatchQueue.main.async {
            self.hasUltraWide = ultra
            self.isFront = front
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
            message = "Inquadratura giusta. Resta fermo e scatta."
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
        DispatchQueue.main.async {
            guard self.phase == .guiding || self.phase == .locked else { return }
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
            self.poseMatched = matched
            self.countdown = count
            self.hint = hint
            if speak && self.voiceOn { self.speaker.say(hint) }
        }
    }

    /// Reads the pose out of a photo the user picked, to use as the pose to copy.
    func importInspiration(_ data: Data) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let picked = UIImage(data: data) else {
                self.showToast("Non riesco ad aprire questa foto.")
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
                self.showToast("Non riesco ad aprire questa foto.")
                return
            }
            let request = VNDetectHumanBodyPoseRequest()
            try? VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request])
            var joints: [Joint: CGPoint] = [:]
            if let observation = request.results?.first { joints = Self.joints(from: observation) }
            let angles = PoseMath.angles(joints, aspect: size.width / size.height)
            guard angles.count >= 6 else {
                self.showToast("In questa foto non trovo una persona a figura intera.")
                return
            }
            let pose = RefPose(id: "import", name: "Ispirazione", angles: angles)
            DispatchQueue.main.async {
                self.importedPose = pose
                self.selectPose(pose)
                self.showToast("Posa copiata dalla foto")
            }
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
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
}
