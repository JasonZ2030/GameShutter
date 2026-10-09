//
//  CameraViewController.swift
//  MagicVideo
//
//  Created by jaba odishelashvili on 3/14/18.
//  Copyright © 2018 Jabson. All rights reserved.
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

class CameraViewController: UIViewController {
    //MARK: IBOutlets

    @IBOutlet weak var recordButton: UIButton?
    @IBOutlet weak var stopButton: UIButton?
    @IBOutlet weak var cameraSwitchButton: UIButton?
    @IBOutlet weak var highLight: UIButton!
    @IBOutlet weak var videoEditorButton: UIButton!
    @IBOutlet weak var Timerdisp: UILabel!

    @IBOutlet weak var debugInfoLabel: UILabel!
    @IBOutlet weak var resumeButton: UIButton!
    var vManager = videoManager()

    let activityIndicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.whiteLarge)

    private var pinchStartZoomFactor: CGFloat = 1.0

    private let highlightBadge = HighlightBadgeLabel()

    //added by hanhui, hide navigation item bar
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        resumeButton.isHidden = true
        resumeButton.isEnabled = false
    }

    // MARK: Object Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = false
        // Keeps UIDevice.orientation current for the video editor, which opens in
        // whichever orientation the device is held. Started here rather than when
        // the editor opens: right after starting, the orientation reads .unknown.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        highLight.isEnabled = false
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
    }

    private func recordToggled() {
        var recordButtonImage: UIImage?
        if self.vManager.isCapturing {
            if self.vManager.isPaused {
                self.vManager.resumeRecording()
                self.vManager.timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(keep_timer), userInfo: nil, repeats: true)
                if #available(iOS 13.0, *) {
                    recordButtonImage = UIImage(systemName: "pause.circle")
                    recordButtonImage?.withTintColor(.yellow)
                } else {
                    recordButtonImage = UIImage(named: "recording")
                }
                self.recordButton?.tintColor = .yellow
                resumeButton.isHidden = true
                resumeButton.isEnabled = false
                print("Capturing resume")
            } else {
                self.vManager.pauseRecording()
                if #available(iOS 13.0, *) {
                    recordButtonImage = UIImage(systemName: "record.circle")
                    recordButtonImage?.withTintColor(.green)
                } else {
                    recordButtonImage = UIImage(named: "recording")
                }
                self.recordButton?.tintColor = .green
                resumeButton.isHidden = false
                resumeButton.isEnabled = true
                print("Capturing pause")
            }
            self.recordButton?.setImage(recordButtonImage, for: .normal)
        } else {
            resumeButton.isHidden = true
            resumeButton.isEnabled = false
            setHighlightCount(0)
            self.vManager.startRecording()
            highLight.isEnabled = true
            // Presenting the editor full-screen would tear down the capture session.
            videoEditorButton.isEnabled = false
            self.vManager.timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(keep_timer), userInfo: nil, repeats: true)
            if #available(iOS 13.0, *) {
                recordButtonImage = UIImage(systemName: "pause.circle")
            } else {
                recordButtonImage = UIImage(named: "recording")
            }
            self.recordButton?.tintColor = .yellow
            self.recordButton?.setImage(recordButtonImage, for: .normal)
            print("Start Capturing")
        }
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
        self.highLight.isEnabled = false
        setHighlightCount(0)
        Timerdisp.text = "0:00:00"
        videoEditorButton.isEnabled = true
        var recordButtonImage: UIImage?
        if #available(iOS 13.0, *) {
            recordButtonImage = UIImage(systemName: "record.circle")
            recordButtonImage?.withTintColor(.green)
        } else {
            recordButtonImage = UIImage(named: "recording")
        }
        self.resumeButton.isHidden = true
        self.resumeButton.isEnabled = false
        self.recordButton?.tintColor = .green
        self.recordButton?.setImage(recordButtonImage, for: .normal)
    }

    private func presentSaveFullVideoPrompt(_ decide: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "Save Full Video?",
                                      message: "Highlight clips are saved either way. If you don't save the full recording, it will be deleted.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in decide(true) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in decide(false) })
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

    @IBAction func record(_ sender: Any) {
        recordToggled()
    }

    @IBAction func stopRecord(_ sender: Any) {
        stopRecording(isLocal: true)
    }

    @IBAction func ResumeTapped(_ sender: Any) {
        recordToggled()
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

    @IBAction func highLightTouched(_ sender: Any) {
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
            let minZoom = device.minAvailableVideoZoomFactor
            let newFactor = max(minZoom, min(pinchStartZoomFactor * pinch.scale, maxZoom))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = newFactor
                device.unlockForConfiguration()
                vManager.deviceZoomFactor = newFactor
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
                 self.recordButton?.isEnabled = isSessionRunning
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
