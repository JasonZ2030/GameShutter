//
//  CameraViewController.swift
//  GameShutter
//
//  Created by Jason Zhang on 3/14/18.
//

import UIKit
import AVFoundation
import GLKit
import Photos

// Count badge pinned to the highlight button's top-right corner: a pill with
// horizontal padding so multi-digit counts don't crowd the edges.
final class HighlightBadgeLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: max(size.width + 10, 22), height: 22)
    }
}

// The red "PAUSED" tag under the timer: bold caps with side padding.
final class PausedTagLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 14, height: 24)
    }
}

// The round capture controls, styled after the iOS Camera app and drawn with
// layers (no images or SF Symbols, so they also work on iOS 12).
final class CaptureControlButton: UIButton {
    enum Style {
        case record     // red disc inside a ring
        case stop       // red rounded square inside a ring
        case smallStop  // red rounded square on a plain dark disc
        case pause      // white pause bars on a plain dark disc
    }

    var style: Style = .record {
        didSet {
            setNeedsLayout()
            switch style {
            case .record: accessibilityLabel = "Record"
            case .stop, .smallStop: accessibilityLabel = "Stop"
            case .pause: accessibilityLabel = "Pause"
            }
        }
    }

    private let discLayer = CAShapeLayer()
    private let glyphLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(discLayer)
        layer.addSublayer(glyphLayer)
        accessibilityLabel = "Record"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Pressed/disabled dimming goes on the sublayers, leaving the view's own
    // alpha free for the show/hide fades.
    override var isHighlighted: Bool { didSet { updateDimming() } }
    override var isEnabled: Bool { didSet { updateDimming() } }

    private func updateDimming() {
        let opacity: Float = !isEnabled ? 0.4 : (isHighlighted ? 0.6 : 1)
        discLayer.opacity = opacity
        glyphLayer.opacity = opacity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ringed = style == .record || style == .stop

        discLayer.path = UIBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).cgPath
        discLayer.fillColor = UIColor(white: 0.08, alpha: ringed ? 0.5 : 0.65).cgColor
        discLayer.strokeColor = UIColor(white: 1, alpha: ringed ? 0.45 : 0).cgColor
        discLayer.lineWidth = 3

        let glyph: UIBezierPath
        switch style {
        case .record:
            glyph = UIBezierPath(ovalIn: rect.insetBy(dx: side * 0.09, dy: side * 0.09))
        case .stop, .smallStop:
            let square = side * 0.4
            glyph = UIBezierPath(roundedRect: CGRect(x: center.x - square / 2, y: center.y - square / 2,
                                                     width: square, height: square),
                                 cornerRadius: square * 0.22)
        case .pause:
            let barWidth = side * 0.1, barHeight = side * 0.34, gap = side * 0.1
            glyph = UIBezierPath(roundedRect: CGRect(x: center.x - gap / 2 - barWidth, y: center.y - barHeight / 2,
                                                     width: barWidth, height: barHeight),
                                 cornerRadius: barWidth / 2)
            glyph.append(UIBezierPath(roundedRect: CGRect(x: center.x + gap / 2, y: center.y - barHeight / 2,
                                                          width: barWidth, height: barHeight),
                                      cornerRadius: barWidth / 2))
        }
        glyphLayer.path = glyph.cgPath
        glyphLayer.fillColor = (style == .pause ? UIColor.white
                                                : UIColor(red: 0.93, green: 0.27, blue: 0.24, alpha: 1)).cgColor
        CATransaction.commit()
    }
}

class CameraViewController: UIViewController {
    //MARK: IBOutlets

    @IBOutlet weak var cameraSwitchButton: UIButton?
    @IBOutlet weak var videoEditorButton: UIButton!
    @IBOutlet weak var Timerdisp: UILabel!

    @IBOutlet weak var debugInfoLabel: UILabel!
    var vManager = videoManager()

    let activityIndicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.whiteLarge)

    private var pinchStartZoomFactor: CGFloat = 1.0

    private let highlightBadge = HighlightBadgeLabel()

    // Capture controls, iOS Camera style, in a column on the right edge (built in
    // setupCaptureControls; updateCaptureControls switches them per state):
    //   idle:      big Record in the middle; nothing else.
    //   recording: big Stop in the middle, Pause above it, Highlight below it.
    //   paused:    big Record (resume) above, small Stop in the middle, no Highlight.
    private let mainCaptureButton = CaptureControlButton()
    private let sideCaptureButton = CaptureControlButton()
    private let highLight = UIButton(type: .custom)
    private var mainCaptureWidth: NSLayoutConstraint!
    private var sideCaptureWidth: NSLayoutConstraint!
    private static let largeCaptureSize: CGFloat = 80
    private static let smallCaptureSize: CGFloat = 56
    private static let highlightSize: CGFloat = 64
    // Distance from the middle slot's center to the slots above and below.
    private static let captureSlotSpacing: CGFloat = 112

    // Zoom presets, Camera-app style: a column just inside the capture controls.
    // Values are shown zoom (1 = standard wide). The active one gets a dark disc
    // and yellow text showing the live zoom. Hidden: presets turned off in
    // Settings (all but 1×, via ZoomPresetSettings) and presets the active
    // camera can't reach (0.75× on a camera without an ultra-wide).
    private static let zoomPresets: [CGFloat] = [0.75, 1, 1.25, 1.5]
    private static let zoomPresetSize: CGFloat = 40
    private var zoomPresetButtons: [UIButton] = []

    // Timer styling: a half-transparent rounded backing behind the storyboard
    // timer label (red while recording, gray while paused) with white text,
    // plus a red PAUSED tag below it while paused. Idle shows the plain gray
    // label. The backing lives in the timer's stack's superview, behind the
    // stack, since a label's own subviews would draw over its text.
    private let timerBacking = UIView()
    private let pausedTag = PausedTagLabel()

    //added by Jason, hide navigation item bar
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        // Back from Settings, where presets may have been turned on or off.
        refreshZoomPresets()
    }

    // MARK: Object Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = false
        // Keeps UIDevice.orientation current for the video editor, which opens in
        // whichever orientation the device is held. Started here rather than when
        // the editor opens: right after starting, the orientation reads .unknown.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        if #available(iOS 13.0, *) {} else {
            videoEditorButton.isHidden = true
        }
        vManager.init_setup()
        vManager.onSaveFailed = { [weak self] message in
            self?.presentSimpleAlert(title: "Save Failed",
                                     message: "The recording could not be saved to Photos: \(message)")
        }
        vManager.onHighlightCaptured = { [weak self] count in
            // A frame already in flight when Stop was pressed can still report
            // a capture after saveVideo() has reset the badge — ignore it.
            guard let self = self, self.vManager.isCapturing else { return }
            self.setHighlightCount(count)
        }
        setupCaptureControls()
        setupZoomPresets()
        setupTimerStyling()
        setupHighlightBadge()
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appwillTerminate), name: UIApplication.willTerminateNotification, object: nil)

        DispatchQueue.main.async {
            self.vManager.setupVideoPreviewView(view: self.view)
            self.activityIndicator.center = self.view.center
            self.activityIndicator.hidesWhenStopped = true
            self.view.addSubview(self.activityIndicator)
            self.activityIndicator.stopAnimating()
        }

        // Pinch-to-zoom
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        view.addGestureRecognizer(pinchGesture)
    }

    private func setupCaptureControls() {
        mainCaptureButton.addTarget(self, action: #selector(mainCaptureTapped), for: .touchUpInside)
        sideCaptureButton.addTarget(self, action: #selector(sideCaptureTapped), for: .touchUpInside)
        highLight.addTarget(self, action: #selector(highLightTouched(_:)), for: .touchUpInside)

        // Highlight: a white shutter-style disc with the running figure in
        // Court Orange.
        highLight.backgroundColor = .white
        highLight.layer.cornerRadius = Self.highlightSize / 2
        highLight.layer.borderWidth = 4
        highLight.layer.borderColor = UIColor(white: 0.1, alpha: 0.6).cgColor
        highLight.tintColor = UIColor(red: 1.0, green: 0x6A / 255.0, blue: 0x13 / 255.0, alpha: 1.0)
        highLight.accessibilityLabel = "Highlight"
        if #available(iOS 13.0, *) {
            highLight.setImage(UIImage(systemName: "figure.run",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)),
                               for: .normal)
        } else {
            highLight.setImage(UIImage(named: "Highlight"), for: .normal)
            highLight.imageView?.contentMode = .scaleAspectFit
            highLight.imageEdgeInsets = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        }

        let guide = view.safeAreaLayoutGuide
        for control in [sideCaptureButton, mainCaptureButton, highLight] as [UIView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        mainCaptureWidth = mainCaptureButton.widthAnchor.constraint(equalToConstant: Self.largeCaptureSize)
        sideCaptureWidth = sideCaptureButton.widthAnchor.constraint(equalToConstant: Self.smallCaptureSize)
        NSLayoutConstraint.activate([
            mainCaptureButton.centerXAnchor.constraint(equalTo: guide.trailingAnchor,
                                                       constant: -(Self.largeCaptureSize / 2 + 12)),
            mainCaptureButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            mainCaptureWidth,
            mainCaptureButton.heightAnchor.constraint(equalTo: mainCaptureButton.widthAnchor),

            sideCaptureButton.centerXAnchor.constraint(equalTo: mainCaptureButton.centerXAnchor),
            sideCaptureButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -Self.captureSlotSpacing),
            sideCaptureWidth,
            sideCaptureButton.heightAnchor.constraint(equalTo: sideCaptureButton.widthAnchor),

            highLight.centerXAnchor.constraint(equalTo: mainCaptureButton.centerXAnchor),
            highLight.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: Self.captureSlotSpacing),
            highLight.widthAnchor.constraint(equalToConstant: Self.highlightSize),
            highLight.heightAnchor.constraint(equalTo: highLight.widthAnchor)
        ])
        updateCaptureControls(animated: false)
    }

    private func setupZoomPresets() {
        zoomPresetButtons = Self.zoomPresets.enumerated().map { index, _ in
            let button = UIButton(type: .custom)
            button.tag = index
            button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
            button.layer.cornerRadius = Self.zoomPresetSize / 2
            // Keeps the plain (inactive) labels readable over bright footage.
            button.titleLabel?.layer.shadowColor = UIColor.black.cgColor
            button.titleLabel?.layer.shadowOpacity = 0.6
            button.titleLabel?.layer.shadowRadius = 2
            button.titleLabel?.layer.shadowOffset = .zero
            button.addTarget(self, action: #selector(zoomPresetTapped(_:)), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.zoomPresetSize),
                button.heightAnchor.constraint(equalToConstant: Self.zoomPresetSize)
            ])
            return button
        }
        let column = UIStackView(arrangedSubviews: zoomPresetButtons)
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: mainCaptureButton.centerXAnchor,
                                            constant: -(Self.largeCaptureSize / 2 + 16 + Self.zoomPresetSize / 2)),
            column.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        refreshZoomPresets()
    }

    // `zoom` is the shown zoom to reflect; nil reads the camera's current one
    // (pass the target while a ramp is still running).
    private func refreshZoomPresets(zoom: CGFloat? = nil) {
        let zoom = zoom ?? vManager.shownZoom
        let range = vManager.shownZoomRange
        for (button, preset) in zip(zoomPresetButtons, Self.zoomPresets) {
            let reachable = range.map { preset >= $0.lowerBound - 0.01 && preset <= $0.upperBound + 0.01 } ?? true
            button.isHidden = !reachable || !ZoomPresetSettings.isEnabled(preset)
        }
        let visible = zip(zoomPresetButtons, Self.zoomPresets).filter { !$0.0.isHidden }
        // The active preset is the highest one at or below the zoom, as in the Camera app.
        let active = visible.last { $0.1 <= zoom + 0.01 } ?? visible.first
        for (button, preset) in visible {
            let isActive = button === active?.0
            let label: String
            if isActive {
                let shown = abs(zoom - preset) < 0.01 ? preset : (zoom * 10).rounded() / 10
                label = Self.zoomLabel(shown, withTimes: true)
            } else {
                label = Self.zoomLabel(preset, withTimes: false)
            }
            button.setTitle(label, for: .normal)
            button.setTitleColor(isActive ? UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1) : .white, for: .normal)
            button.backgroundColor = isActive ? UIColor(white: 0.08, alpha: 0.6) : .clear
            button.accessibilityLabel = "Zoom \(Self.zoomLabel(preset, withTimes: true))"
            button.accessibilityTraits = isActive ? [.button, .selected] : .button
        }
    }

    // Camera-app labels: plain ".75", "1", "1.5" for inactive presets; the active
    // one gets a "×" and keeps its leading zero ("0.75×").
    private static func zoomLabel(_ zoom: CGFloat, withTimes: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = withTimes ? 1 : 0
        let number = formatter.string(from: NSNumber(value: Double(zoom))) ?? "\(zoom)"
        return withTimes ? number + "×" : number
    }

    @objc private func zoomPresetTapped(_ sender: UIButton) {
        let preset = Self.zoomPresets[sender.tag]
        vManager.setShownZoom(preset)
        refreshZoomPresets(zoom: preset)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func setupTimerStyling() {
        guard let stack = Timerdisp.superview, let container = stack.superview else { return }
        timerBacking.layer.cornerRadius = 6
        timerBacking.isUserInteractionEnabled = false
        timerBacking.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(timerBacking, belowSubview: stack)

        pausedTag.text = "PAUSED"
        pausedTag.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        pausedTag.textColor = .white
        pausedTag.textAlignment = .center
        pausedTag.backgroundColor = UIColor(red: 0.93, green: 0.27, blue: 0.24, alpha: 1)
        pausedTag.layer.cornerRadius = 5
        pausedTag.layer.masksToBounds = true
        pausedTag.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pausedTag)

        NSLayoutConstraint.activate([
            timerBacking.centerXAnchor.constraint(equalTo: Timerdisp.centerXAnchor),
            timerBacking.centerYAnchor.constraint(equalTo: Timerdisp.centerYAnchor),
            timerBacking.widthAnchor.constraint(equalTo: Timerdisp.widthAnchor, constant: 14),
            timerBacking.heightAnchor.constraint(equalToConstant: 30),
            pausedTag.centerXAnchor.constraint(equalTo: Timerdisp.centerXAnchor),
            pausedTag.topAnchor.constraint(equalTo: timerBacking.bottomAnchor, constant: 6)
        ])
    }

    private func updateTimerStyling() {
        let recording = vManager.isCapturing && !vManager.isPaused
        let paused = vManager.isCapturing && vManager.isPaused
        timerBacking.backgroundColor = recording ? UIColor(red: 0.93, green: 0.27, blue: 0.24, alpha: 0.5)
                                     : paused ? UIColor(white: 0.2, alpha: 0.5)
                                     : .clear
        Timerdisp.textColor = recording || paused ? .white : .systemGray
        pausedTag.isHidden = !paused
    }

    // Matches the controls to vManager's state (see the property comment above).
    private func updateCaptureControls(animated: Bool) {
        let recording = vManager.isCapturing && !vManager.isPaused
        let paused = vManager.isCapturing && vManager.isPaused

        mainCaptureButton.style = !vManager.isCapturing ? .record : (paused ? .smallStop : .stop)
        mainCaptureWidth.constant = paused ? Self.smallCaptureSize : Self.largeCaptureSize
        sideCaptureButton.style = paused ? .record : .pause
        sideCaptureWidth.constant = paused ? Self.largeCaptureSize : Self.smallCaptureSize
        sideCaptureButton.isEnabled = vManager.isCapturing
        updateTimerStyling()
        highLight.isEnabled = recording
        // Hidden controls also stop taking touches while they fade out.
        sideCaptureButton.isUserInteractionEnabled = vManager.isCapturing
        highLight.isUserInteractionEnabled = recording

        let changes = {
            self.sideCaptureButton.alpha = self.vManager.isCapturing ? 1 : 0
            self.highLight.alpha = recording ? 1 : 0
            self.view.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut],
                           animations: changes)
        } else {
            changes()
        }
    }

    // Middle button: Record when idle, Stop (with confirmation) once recording or paused.
    @objc private func mainCaptureTapped() {
        if vManager.isCapturing {
            stopRecording(isLocal: true)
        } else {
            startRecording()
        }
    }

    // Upper button: Pause while recording, Record (resume) while paused.
    @objc private func sideCaptureTapped() {
        guard vManager.isCapturing else { return }
        if vManager.isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    private func setupHighlightBadge() {
        highlightBadge.translatesAutoresizingMaskIntoConstraints = false
        highlightBadge.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        highlightBadge.textColor = .white
        highlightBadge.textAlignment = .center
        // Court Orange (#FF6A13), with a white ring so it reads over any video.
        highlightBadge.backgroundColor = UIColor(red: 1.0, green: 0x6A / 255.0, blue: 0x13 / 255.0, alpha: 1.0)
        highlightBadge.layer.cornerRadius = 11
        highlightBadge.layer.borderWidth = 1.5
        highlightBadge.layer.borderColor = UIColor.white.cgColor
        highlightBadge.layer.masksToBounds = true
        highlightBadge.isHidden = true
        highLight.addSubview(highlightBadge)
        NSLayoutConstraint.activate([
            highlightBadge.centerXAnchor.constraint(equalTo: highLight.trailingAnchor, constant: -6),
            highlightBadge.centerYAnchor.constraint(equalTo: highLight.topAnchor, constant: 6)
        ])
    }

    // Hidden at 0; otherwise shows how many highlights this recording has captured.
    private func setHighlightCount(_ count: Int) {
        highlightBadge.text = "\(count)"
        highlightBadge.isHidden = count == 0
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc func appMovedToBackground() {
        if self.vManager.isCapturing {
            self.stopRecording(isLocal: false)
        }
    }

    @objc func appwillTerminate() {
        print("appwillTerminate")
        if self.vManager.isCapturing {
            self.saveVideo()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        vManager.sessionQueue.async {
            switch self.vManager.setupResult {
            case .success:
                self.vManager.captureSession?.startRunning()
                self.vManager.isSessionRunning = ((self.vManager.captureSession?.isRunning) != nil)
                // The camera devices exist now, so the presets can show the
                // right zoom and hide what this camera can't reach.
                DispatchQueue.main.async { self.refreshZoomPresets() }

            case .notAuthorized:
                DispatchQueue.main.async {
                    let changePrivacySetting = "GameShutter doesn't have permission to use the camera, please change privacy settings"
                    let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "GameShutter", message: message, preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"), style: .`default`, handler: { _ in
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                    }))
                    self.present(alertController, animated: true, completion: nil)
                }

            case .configurationFailed:
                DispatchQueue.main.async {
                    let alertMsg = "Alert message when something goes wrong during capture session configuration"
                    let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
                    let alertController = UIAlertController(title: "GameShutter", message: message, preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        print("viewDidDisappear stop recording")
        vManager.sessionQueue.async {
            if self.vManager.setupResult == .success {
                self.vManager.captureSession?.stopRunning()
                self.vManager.isSessionRunning = ((self.vManager.captureSession?.isRunning) != nil)
                self.removeObservers()
                if self.vManager.isCapturing {
                    self.stopRecording(isLocal: false)
                }
            }
        }
        self.activityIndicator.stopAnimating()
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        vManager.orientation = UIApplication.shared.statusBarOrientation
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        self.vManager.videoPreviewView?.transform = (self.vManager.videoPreviewView?.transform.scaledBy(x: 0.9999, y: 1.0))!
    }

    func stop_activityIndicator() {
        DispatchQueue.main.async {
            self.activityIndicator.stopAnimating()
        }
    }

    // MARK: User Interface
    @IBAction func switchCamera(_ sender: Any) {
        vManager.switchCamera()
        refreshZoomPresets()
    }

    private func startRecording() {
        setHighlightCount(0)
        vManager.startRecording()
        // Presenting the editor full-screen would tear down the capture session.
        videoEditorButton.isEnabled = false
        vManager.timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(keep_timer), userInfo: nil, repeats: true)
        updateCaptureControls(animated: true)
        print("Start Capturing")
    }

    private func pauseRecording() {
        vManager.pauseRecording()
        updateCaptureControls(animated: true)
        print("Capturing pause")
    }

    private func resumeRecording() {
        vManager.resumeRecording()
        vManager.timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(keep_timer), userInfo: nil, repeats: true)
        updateCaptureControls(animated: true)
        print("Capturing resume")
    }

    // askToSaveFullVideo: prompt (once the file is finished) whether to keep the
    // full recording in Photos or delete it. Off for background/termination stops,
    // where no prompt can be answered — those always save.
    private func saveVideo(askToSaveFullVideo: Bool = false) {
        self.activityIndicator.startAnimating()
        self.vManager.stopRecording(
            confirmSaveFullVideo: askToSaveFullVideo ? { [weak self] decide in
                guard let self = self else { return decide(true) }
                self.presentSaveFullVideoPrompt(decide)
            } : nil,
            completion: {DispatchQueue.main.async {self.activityIndicator.stopAnimating()}})
        setHighlightCount(0)
        Timerdisp.text = "0:00:00"
        videoEditorButton.isEnabled = true
        updateCaptureControls(animated: true)
    }

    private func presentSaveFullVideoPrompt(_ decide: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "Save Full Video?",
                                      message: "Highlight clips are saved either way. If you don't save the full recording, it will be deleted.",
                                      preferredStyle: .alert)
        let save = UIAlertAction(title: "Save", style: .default) { _ in decide(true) }
        alert.addAction(save)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in decide(false) })
        // Save is the default: shown bold, and triggered by Return on a keyboard.
        alert.preferredAction = save
        present(alert, animated: true)
    }

    private func stopRecording(isLocal: Bool) {
        if self.vManager.isCapturing {
            if isLocal {
                let dialogMessage = UIAlertController(title: "Confirm", message: "Are you sure you want to stop recording?", preferredStyle: .alert)
                let ok = UIAlertAction(title: "OK", style: .default, handler: { (action) -> Void in
                    self.saveVideo(askToSaveFullVideo: true)
                })
                let cancel = UIAlertAction(title: "Cancel", style: .cancel) { (action) -> Void in
                    print("Cancel button tapped")
                }
                dialogMessage.addAction(ok)
                dialogMessage.addAction(cancel)
                self.present(dialogMessage, animated: true, completion: nil)
            } else {
                self.saveVideo()
            }
        }
    }

    @IBAction func openVideoEditor(_ sender: Any) {
        guard #available(iOS 13.0, *), !vManager.isCapturing else { return }
        // Highlight folders first; picking one opens the editor on top.
        let folders = HighlightFoldersViewController()
        folders.modalPresentationStyle = .fullScreen
        // Let the folder browser and editor match how the device is held
        // (portrait or landscape); the browser resets this when it closes.
        AppDelegate.orientationMask = .allButUpsideDown
        present(folders, animated: true)
    }

    @objc private func highLightTouched(_ sender: Any) {
        print("hightlight pressed")
        (sender as! UIButton).shake()
        self.vManager.ishighLighting = true
    }

    @objc func handlePinchGesture(_ pinch: UIPinchGestureRecognizer) {
        guard let backDevice = vManager.backCameraDeviceInput?.device,
              let frontDevice = vManager.frontCameraDeviceInput?.device else { return }

        let device = vManager.isBackCameraActive ? backDevice : frontDevice

        if pinch.state == .began {
            pinchStartZoomFactor = device.videoZoomFactor
        }

        if pinch.state == .began || pinch.state == .changed {
            let maxZoom = device.activeFormat.videoMaxZoomFactor
            let minZoom = videoManager.minimumZoomFactor(of: device) // no wider than 0.75×
            let newFactor = max(minZoom, min(pinchStartZoomFactor * pinch.scale, maxZoom))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = newFactor
                device.unlockForConfiguration()
                vManager.deviceZoomFactor = newFactor
                refreshZoomPresets()
            } catch {
                print("Can't change zoom factor")
            }
        }
    }

    @IBAction func handlePanGestureRecognizer(_ panGestureRecognizer: UIPanGestureRecognizer) {
    }

    func changeDeviceZoom(percent: CGFloat) {
        print(percent)
        guard let backDevice = self.vManager.backCameraDeviceInput?.device else {
            print("Can't find back device")
            return;
        }

        guard let frontDevice = self.vManager.frontCameraDeviceInput?.device else {
            print("Can't find front device")
            return;
        }

        let device = self.vManager.isBackCameraActive ? backDevice : frontDevice

        let maxZoomFactor = min(frontDevice.activeFormat.videoMaxZoomFactor, backDevice.activeFormat.videoMaxZoomFactor)
        let minZoomFactor: CGFloat = 1
        self.vManager.deviceZoomFactor = maxZoomFactor * percent

        self.vManager.deviceZoomFactor = min(maxZoomFactor, self.vManager.deviceZoomFactor)
        self.vManager.deviceZoomFactor = max(minZoomFactor, self.vManager.deviceZoomFactor)

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = self.vManager.deviceZoomFactor
            device.unlockForConfiguration()
        } catch {
            print("Can't change zoom factor")
        }
    }

    @objc private func keep_timer(){
        self.vManager.second += 1
        if self.vManager.second == 60 {
            self.vManager.minute += 1
            self.vManager.second = 0
        }
        if self.vManager.minute == 60 {
            self.vManager.hour += 1
            self.vManager.minute = 0
        }
        let secondStr = self.vManager.second > 9 ? "\(self.vManager.second)" : "0\(self.vManager.second)"
        let minuteStr = self.vManager.minute > 9 ? "\(self.vManager.minute)" : "0\(self.vManager.minute)"
        Timerdisp.text = "\(self.vManager.hour):\(minuteStr):\(secondStr)"
    }

    private func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void ) {
        let authorizationStatus = PHPhotoLibrary.authorizationStatus()

        switch authorizationStatus {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization({ (status) in
                let granted = (status == .authorized)
                DispatchQueue.main.async {
                    completion(granted)
                }
            })
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .limited:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func showDeviceAccessAlert(for mediaType: AVMediaType) {
        var alertTitle: String?
        var alertMessage: String?

        if mediaType == .video {
            alertTitle = Constants.AlertTitles.CameraAccess
            alertMessage = Constants.AlertMessages.CameraAccess
        } else if mediaType == .audio {
            alertTitle = Constants.AlertTitles.MicrophoneAccess
            alertMessage = Constants.AlertMessages.MicrophoneAccess
        } else {
            print("Unknown Media Type to show alert")
            return
        }

        let alertController = UIAlertController(title: alertTitle!, message: alertMessage!, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Constants.AlertActionTitles.Ok, style: .default) { (action) in
            let settingsURL = URL(string: UIApplication.openSettingsURLString)
            if let url = settingsURL {
                UIApplication.shared.open(url, options: [:], completionHandler: nil);
            } else {
                print("Can't open application settings")
            }
        }
        let cancelAction = UIAlertAction(title: Constants.AlertActionTitles.Cancel, style: .cancel, handler: nil);
        alertController.addAction(okAction)
        alertController.addAction(cancelAction)

        present(alertController, animated: true, completion: nil)
    }

    private func videofilePath() -> String {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDirectory = paths.first!
        let videoPath = "\(documentsDirectory)/video.mp4"
        return videoPath
    }

     // MARK: KVO and Notifications

     private var keyValueObservations = [NSKeyValueObservation]()
     private func addObservers() {
         let keyValueObservation = self.vManager.captureSession?.observe(\.isRunning, options: .new) { _, change in
             guard let isSessionRunning = change.newValue else { return }
             DispatchQueue.main.async {
                 // Pausing stops the session, but Stop and Resume must still work then.
                 self.mainCaptureButton.isEnabled = isSessionRunning || self.vManager.isCapturing
             }
         }
         keyValueObservations.append(keyValueObservation!)
         let systemPressureStateObservation = observe(\.vManager.backCameraDeviceInput.device.systemPressureState, options: .new) { _, change in
             guard let systemPressureState = change.newValue else { return }
             self.setRecommendedFrameRateRangeForPressureState(systemPressureState: systemPressureState)
         }
         keyValueObservations.append(systemPressureStateObservation)

         NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: .AVCaptureDeviceSubjectAreaDidChange, object: self.vManager.backCameraDeviceInput.device)
         NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: self.vManager.captureSession)
         NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: self.vManager.captureSession)
         NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: self.vManager.captureSession)
     }

     private func removeObservers() {
         NotificationCenter.default.removeObserver(self)
         for keyValueObservation in keyValueObservations {
             keyValueObservation.invalidate()
         }
         keyValueObservations.removeAll()
     }

     @objc func subjectAreaDidChange(notification: NSNotification) {
         let devicePoint = CGPoint(x: 0.5, y: 0.5)
         focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
     }

    private func focus(with focusMode: AVCaptureDevice.FocusMode,
                       exposureMode: AVCaptureDevice.ExposureMode,
                       at devicePoint: CGPoint,
                       monitorSubjectAreaChange: Bool) {
        self.vManager.sessionQueue.async {
            let device = self.vManager.backCameraDeviceInput.device
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = focusMode
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = exposureMode
                }
                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }

     @objc func sessionRuntimeError(notification: NSNotification) {
         guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
         print("Capture session runtime error: \(error)")
         if error.code == .mediaServicesWereReset {
             self.vManager.sessionQueue.async {
                 if self.vManager.isSessionRunning {
                     self.vManager.captureSession?.startRunning()
                     self.vManager.isSessionRunning = ((self.vManager.captureSession?.isRunning) != nil)
                 }
             }
         }
     }

     private func setRecommendedFrameRateRangeForPressureState(systemPressureState: AVCaptureDevice.SystemPressureState) {
         let pressureLevel = systemPressureState.level
         if pressureLevel == .serious || pressureLevel == .critical {
             if self.vManager.videoWriter == nil || self.vManager.isCapturing == false {
                 do {
                     try self.vManager.backCameraDeviceInput?.device.lockForConfiguration()
                     print("WARNING: Reached elevated system pressure level: \(pressureLevel). Throttling frame rate.")
                     self.vManager.backCameraDeviceInput?.device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 20)
                     self.vManager.backCameraDeviceInput?.device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
                     self.vManager.backCameraDeviceInput?.device.unlockForConfiguration()
                 } catch {
                     print("Could not lock device for configuration: \(error)")
                 }
             }
         } else if pressureLevel == .shutdown {
             print("Session stopped running due to shutdown system pressure level.")
         }
     }

    @available(iOS 11.1, *)
    @objc func sessionWasInterrupted(notification: NSNotification) {
         if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
             let reasonIntegerValue = userInfoValue.integerValue,
             let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
             print("Capture session was interrupted with reason \(reason)")
         }
     }

     @objc func sessionInterruptionEnded(notification: NSNotification) {
         print("Capture session interruption ended")
     }
}
