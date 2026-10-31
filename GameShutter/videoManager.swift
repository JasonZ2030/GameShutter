//
//  videoManager.swift
//  GameShutter
//
//  Created by Jason Zhang on 4/16/23.
//
import UIKit
import AVFoundation
import GLKit
import Photos

class videoManager: NSObject {
    
    // MARK: Video Preview Objects
    var videoPreviewView: GLKView?
    var ciContext: CIContext?
    var glContext: EAGLContext?
    var videoPreviewViewBounds: CGRect?

    // MARK: Watermark (see watermarked(_:))
    // GameShutter logo burned into recorded frames only — the live preview
    // stays clean. The asset is a pre-rendered white lockup with its own soft
    // shadow on a transparent background (see the GameShutterWatermark imageset).
    private lazy var watermarkSource: CIImage? = UIImage(named: "GameShutterWatermark")?.cgImage.map { CIImage(cgImage: $0) }
    // Scaled/positioned/faded watermark for the last frame extent seen, so the
    // filter chain is only rebuilt when the frame size changes (camera switch,
    // orientation change).
    private var watermarkCache: (extent: CGRect, image: CIImage)?
    
    // MARK: Camera Input and Outputs Objects
    @objc dynamic var frontCameraDeviceInput: AVCaptureDeviceInput!
    @objc dynamic var backCameraDeviceInput: AVCaptureDeviceInput!
    @objc dynamic var audioDeviceInput: AVCaptureDeviceInput!
    var videoDataOutput: AVCaptureVideoDataOutput?
    
    // MARK: Session Objects

    var captureSession: AVCaptureSession?
    var isSessionRunning = false
    var videoWriter: VideoWriter?
    // Communicate with the session and other session objects on this queue.
    let sessionQueue = DispatchQueue(label: "session queue")
    //MARK: helper zoom
    var previousLocation = CGPoint.zero
    //added by Jason
    var timer: Timer?
    //MARK: helper recording
    var cvPixelBuffer: CVPixelBuffer?
    var isCapturing = false
    var isPaused    = false
    var CMResumed   = false
    var CMPausedTime = CMTime.zero
    var CMSkipTime = CMTime.zero
    var isBackCameraActive = true
    var orientation = UIInterfaceOrientation.portrait
    var deviceZoomFactor: CGFloat = 1.0
    //added by Jason
    var deviceZoomScaleFactor: CGFloat = 0.01 // x2
    //added by Jason
    var ishighLighting = false
    var highLightArray:[CMTime] = []
    // Wall-clock moment of each highlight, parallel to highLightArray — stamped as
    // the saved clip's Photos creationDate, so clips sort in the order they
    // happened (saving runs concurrently, so save time doesn't).
    var highLightDates: [Date] = []
    // The serial queue videoOutput() runs on. stopRecording() dispatches its
    // markAsFinished()/finish() sequence through here so it can never land in the
    // middle of an in-flight (or already-enqueued) videoOutput() call and append
    // to an input that's already been marked finished.
    private var videoCaptureQueue: DispatchQueue?
    // Fired on the main thread if the finished recording could not be saved to
    // Photos, with PHPhotoLibrary's error description — set by CameraViewController
    // so a failure is visible instead of only appearing in the console.
    var onSaveFailed: ((String) -> Void)?
    // Fired on the main thread each time a highlight timestamp is actually
    // captured (not merely requested), with the recording's running total —
    // set by CameraViewController to update the highlight button's badge.
    var onHighlightCaptured: ((Int) -> Void)?

    var HighlightDuration: Float64 = 10.0
    var firstSamplebuf: Bool = false
    var firstSamplebufTime: CMTime = CMTimeMakeWithSeconds(0.0, preferredTimescale: 600)//the time stamp of the first sample buffer during recording
    var (hour, minute, second) = (0, 0, 0)
    
    enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    var setupResult: SessionSetupResult = .success
    
    override init() {
        
    }
    
    func init_setup() {
        ishighLighting = false
        // load score board setting
        //let defaults = UserDefaults.standard
        //IsShowScoreboard = defaults.bool(forKey: "isShowScoreboard")
        //print("IsShowScoreboard \(IsShowScoreboard)")
        /*
         Check the video authorization status. Video access is required and audio
         access is optional. If the user denies audio access, AVCam won't
         record audio during movie recording.
         */
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            break
            
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant
             video access. Suspend the session queue to delay session
             setup until the access request has completed.
             
             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access.
            setupResult = .notAuthorized
        }
        
        /*
         Setup the capture session.
         In general, it's not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Don't perform these tasks on the main queue because
         AVCaptureSession.startRunning() is a blocking call, which can
         take a long time. Dispatch session setup to the sessionQueue, so
         that the main queue isn't blocked, which keeps the UI responsive.
         */
        sessionQueue.async {
            self.setupCaptureSession()
        }
    }
    // MARK: Setup
    func setupCaptureSession() {
        sessionQueue.async {
            // fetch camera device inputs
            guard let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                print("Can't fetch front camera device")
                return
            }
            
            let backCameraDevice: AVCaptureDevice?
            if #available(iOS 13.0, *) {
                backCameraDevice = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            } else {
                backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            }
            guard let backCameraDevice else {
                print("Can't fetch back camera device")
                return
            }
            
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                print("Can't getch audio device")
                return
            }
            
            do {
                self.frontCameraDeviceInput = try AVCaptureDeviceInput(device: frontCameraDevice)
                self.backCameraDeviceInput = try AVCaptureDeviceInput(device: backCameraDevice)
            } catch {
                print("Unable to obtain video device input")
                return
            }
            
            self.audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice)
            
            // create the capture session
            self.captureSession = AVCaptureSession()
            self.captureSession?.sessionPreset = .high
            
            // CoreImage wants BGRA pixel format
            let outputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            
            // create and configure video data output
            self.videoDataOutput = AVCaptureVideoDataOutput()
            
            
            self.videoDataOutput?.videoSettings = outputSettings
            let videoSessionQueue = DispatchQueue(label: Constants.QueueLabels.VideoSessionQueue)
            self.videoCaptureQueue = videoSessionQueue
            self.videoDataOutput?.setSampleBufferDelegate(self, queue: videoSessionQueue)
            self.videoDataOutput?.alwaysDiscardsLateVideoFrames = true
            
            // create and configure audio data output
            let audioDataOutput = AVCaptureAudioDataOutput()
            let audioSessionQueue = DispatchQueue(label: Constants.QueueLabels.AudioSessionQueue)
            audioDataOutput.setSampleBufferDelegate(self, queue: audioSessionQueue)
            
            // begin configure capture session
            self.captureSession?.beginConfiguration()
            
            // connect the video device input and video data output
            self.captureSession?.addInput(self.backCameraDeviceInput!)
            self.captureSession?.addOutput(self.videoDataOutput!)
            if let audioDeviceInput = self.audioDeviceInput {
                self.captureSession?.addInput(audioDeviceInput)
                self.captureSession?.addOutput(audioDataOutput)
            }
            self.captureSession?.commitConfiguration()
            // Start at the standard wide view (1×), like the Camera app. This
            // has to come after the session is configured: adding the input
            // applies the session preset's format, which resets the zoom to
            // factor 1.0, the ultra-wide (0.5×) on multi-camera devices.
            self.setZoom(1, on: backCameraDevice, ramped: false)
            //captureSession?.startRunning()
        }
    }
    
    
    func setupVideoPreviewView(view: UIView) {
        glContext = EAGLContext(api: .openGLES2)
        if let eaglContext = glContext {
            videoPreviewView = GLKView(frame: view.bounds, context: eaglContext)
            ciContext = CIContext(eaglContext: eaglContext)
        }
        if let videoPreviewView = videoPreviewView {
            videoPreviewView.enableSetNeedsDisplay = false
            videoPreviewView.frame = view.bounds
            videoPreviewView.isUserInteractionEnabled = false
            
            view.addSubview(videoPreviewView)
            view.sendSubviewToBack(videoPreviewView)
        }
        
        resizePreviewView(view: view)
    }
    
    // MARK: Update
    func resizePreviewView(view: UIView) {
        print("resizePreviewView")
        guard let videoPreviewView =  videoPreviewView else {
            print("can't resize preview vide")
            return
        }
        
        videoPreviewView.frame = view.bounds
        videoPreviewView.bindDrawable()
        videoPreviewViewBounds = CGRect.zero
        videoPreviewViewBounds?.size.width = view.bounds.width * videoPreviewView.contentScaleFactor
        videoPreviewViewBounds?.size.height = view.bounds.height * videoPreviewView.contentScaleFactor
    }
    
    // MARK: Zoom presets

    // The videoZoomFactor that gives `device` the standard wide (1×) view. On
    // the virtual multi-camera devices (triple / dual-wide) factor 1 is the
    // ultra-wide (0.5×), and the wide camera takes over at the first
    // switch-over factor, usually 2. Single cameras: 1.
    static func wideZoomFactor(of device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 13.0, *), let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(truncating: first)
        }
        return 1
    }

    // The widest zoom the app allows. The ultra-wide's full 0.5× is left out on
    // purpose; 0.75× is the widest preset.
    static let minimumShownZoom: CGFloat = 0.75

    // The lowest videoZoomFactor allowed on `device` (0.75× where it can go that
    // wide, otherwise its own minimum).
    static func minimumZoomFactor(of device: AVCaptureDevice) -> CGFloat {
        return max(device.minAvailableVideoZoomFactor, minimumShownZoom * wideZoomFactor(of: device))
    }

    var activeCameraDevice: AVCaptureDevice? {
        return (isBackCameraActive ? backCameraDeviceInput : frontCameraDeviceInput)?.device
    }

    // Zoom as the user sees it (1 = standard wide, 0.5 = ultra-wide) on the active camera.
    var shownZoom: CGFloat {
        guard let device = activeCameraDevice else { return 1 }
        return device.videoZoomFactor / videoManager.wideZoomFactor(of: device)
    }

    // The shown-zoom range the active camera supports, or nil before setup.
    var shownZoomRange: ClosedRange<CGFloat>? {
        guard let device = activeCameraDevice else { return nil }
        let wide = videoManager.wideZoomFactor(of: device)
        return (videoManager.minimumZoomFactor(of: device) / wide)...(device.activeFormat.videoMaxZoomFactor / wide)
    }

    // Zooms the active camera to a shown zoom (clamped to what it supports),
    // ramping smoothly like the Camera app's zoom buttons.
    func setShownZoom(_ zoom: CGFloat) {
        guard let device = activeCameraDevice else { return }
        setZoom(zoom, on: device, ramped: true)
    }

    private func setZoom(_ zoom: CGFloat, on device: AVCaptureDevice, ramped: Bool) {
        let factor = min(max(zoom * videoManager.wideZoomFactor(of: device), videoManager.minimumZoomFactor(of: device)),
                         device.activeFormat.videoMaxZoomFactor)
        do {
            try device.lockForConfiguration()
            if ramped {
                device.ramp(toVideoZoomFactor: factor, withRate: 8)
            } else {
                device.videoZoomFactor = factor
            }
            device.unlockForConfiguration()
            deviceZoomFactor = factor
        } catch {
            print("Can't change zoom factor")
        }
    }

    func switchCamera() {
         guard let captureSession = captureSession else {
             print("Can't switch camera, session is nil")
             return
         }
         
         guard let frontCameraDeviceInput = frontCameraDeviceInput else {
             print("Can't switch camera, frontCameraDeviceInput is nil")
             return
         }
         
         guard let backCameraDeviceInput = backCameraDeviceInput else {
             print("Can't switch camera, backCameraDeviceInput is nil")
             return
         }
         
         // Keep the zoom the user sees (e.g. 1.5×) across the switch. The raw
         // factor differs per device: on the back multi-camera device 1× is
         // factor 2, on the front camera it's factor 1.
         let shownZoom = activeCameraDevice.map { deviceZoomFactor / videoManager.wideZoomFactor(of: $0) } ?? 1

         captureSession.beginConfiguration()
         //Change camera device inputs from back to front or opposite
         if captureSession.inputs.contains(frontCameraDeviceInput) == true {
             captureSession.removeInput(frontCameraDeviceInput)
             captureSession.addInput(backCameraDeviceInput)
             isBackCameraActive = true
         } else if captureSession.inputs.contains(backCameraDeviceInput) == true {
             captureSession.removeInput(backCameraDeviceInput)
             captureSession.addInput(frontCameraDeviceInput)
             isBackCameraActive = false
         }
         //Commit all the configuration changes at once
         captureSession.commitConfiguration();
         // After the commit, which can change the device's format and reset its zoom.
         if let device = activeCameraDevice {
             setZoom(shownZoom, on: device, ramped: false)
         }
         
         // fix mirrored preview
         videoPreviewView?.transform = (videoPreviewView?.transform.scaledBy(x: -1, y: 1))!
         cvPixelBuffer = nil
    }
    
    
    func focus(with focusMode: AVCaptureDevice.FocusMode,
                       exposureMode: AVCaptureDevice.ExposureMode,
                       at devicePoint: CGPoint,
                       monitorSubjectAreaChange: Bool) {
        
        sessionQueue.async {
            let device = self.backCameraDeviceInput!.device
            do {
                try device.lockForConfiguration()
                
                /*
                 Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                 Call set(Focus/Exposure)Mode() to apply the new point of interest.
                 */
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
    
    func restartSession() {
        sessionQueue.async {
            if self.isSessionRunning {
                self.captureSession?.startRunning()
                self.isSessionRunning = ((self.captureSession?.isRunning) != nil)
                print("restartSession")
            } else {
                DispatchQueue.main.async {
                    //self.resumeButton.isHidden = false
                }
                print("restartSession, isSessionRunning = false")
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async {
            if self.setupResult == .success {
                self.captureSession?.stopRunning()
                self.isSessionRunning = ((self.captureSession?.isRunning) != nil)
            }
        }
    }
    
    
    func limitFrameRate() {
        if self.videoWriter == nil || self.isCapturing == false {
            do {
                try self.backCameraDeviceInput?.device.lockForConfiguration()
                print("WARNING: Reached elevated system pressure level: . Throttling frame rate.")
                self.backCameraDeviceInput?.device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 20)
                self.backCameraDeviceInput?.device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
                self.backCameraDeviceInput?.device.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }
    
    func changeDeviceZoom(percent: CGFloat) {
        print(percent)
        guard let backDevice = backCameraDeviceInput?.device else {
            print("Can't find back device")
            return;
        }
        
        guard let frontDevice = frontCameraDeviceInput?.device else {
            print("Can't find front device")
            return;
        }
        
        let device = isBackCameraActive ? backDevice : frontDevice
        
        let maxZoomFactor = min(frontDevice.activeFormat.videoMaxZoomFactor, backDevice.activeFormat.videoMaxZoomFactor)
        let minZoomFactor: CGFloat = 1
        deviceZoomFactor = maxZoomFactor * percent
        
        deviceZoomFactor = min(maxZoomFactor, deviceZoomFactor)
        deviceZoomFactor = max(minZoomFactor, deviceZoomFactor)
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = deviceZoomFactor
            device.unlockForConfiguration()
        } catch {
            print("Can't change zoom factor")
        }
    }
    
    func startRecording() {
        firstSamplebuf = true
        isPaused = false
        if isCapturing == true {
            print("Can't start recording, already recording!")
            return
        }
        
        guard let videoDataOutput = videoDataOutput else {
            print("videoDataOutput is nil, can't create VideoWriter")
            return
        }
        
        guard let videoWidth = videoDataOutput.videoSettings["Width"] as? Int else  {
            print("Can't recognize video resolution, can't create VideoWriter")
            return
        }
        
        guard let videoHeight = videoDataOutput.videoSettings["Height"] as? Int else  {
            print("Can't recognize video resolution, can't create VideoWriter")
            return
        }
        
        let path = videofilePath()
        let videoURL = URL(fileURLWithPath: path)
        let fileManager = FileManager()
        
        if fileManager.fileExists(atPath: path) {
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                print("Can't remove file at path \(path) so can't create VideoWriter")
                return
            }
        }
        
        var size = CGSize(width: videoWidth, height: videoHeight)
        if UIApplication.shared.statusBarOrientation.isPortrait {
            size = CGSize(width: videoHeight, height: videoWidth)
        }
        
        self.videoWriter = VideoWriter(fileUrl: videoURL, size: size)
        self.isCapturing = true
        //highLight.isEnabled = true //update UIButton
        (hour, minute, second) = (0, 0, 0)
    }
    
    // `confirmSaveFullVideo`, if given, is called on the main thread once the
    // recording file is finished, and must call its argument with whether to save
    // the full video to Photos (false = delete it; highlight clips are saved
    // either way). nil saves without asking — for background/termination stops.
    func stopRecording(confirmSaveFullVideo: ((@escaping (Bool) -> Void) -> Void)? = nil,
                       completion: @escaping () -> Void) {
        if (isPaused) { //reset "isPaused"
            isPaused = false
            restartSession()
        }
        self.CMSkipTime = CMTime.zero // reset skip time
        self.firstSamplebuf = true
        if isCapturing == false {
            print("Can't stop recording")
            return
        }
        //added by Jason
        //highLight.isEnabled = false //update UIButton
        ishighLighting = false
        timer?.invalidate()
        (hour, minute, second) = (0, 0, 0)
        for lightTime in highLightArray
        {
            let UtimeValue = lightTime.value
            print(UtimeValue)
        }
        
        
        guard let videoWriter = videoWriter else {
            print("Video writer is nil")
            return
        }
        // self.activityIndicator.startAnimating() // //update UI, spinner start
        self.isCapturing = false

        // markAsFinished()/finish() must not race a videoOutput() call that's
        // still in flight (or already enqueued) on the video capture queue —
        // appending a sample to an input already marked finished throws — so route
        // through that queue rather than calling straight from the (main-thread) caller.
        let finishQueue = videoCaptureQueue ?? DispatchQueue.main
        finishQueue.async {
            videoWriter.markAsFinished()

            videoWriter.finish {
                // Check the authorization status.
                PHPhotoLibrary.requestAuthorization { status in
                    if status == .authorized {
                        self.videoWriter = nil
                        self.cvPixelBuffer = nil
                        let videoFilePath = self.videofilePath()
                        let videoFileURL = URL(fileURLWithPath: videoFilePath)
                        // Highlight exports read videoFileURL concurrently, so a declined
                        // full video is only deleted once they've all finished.
                        let highlightsDone = DispatchGroup()
                        highlightsDone.enter()
                        self.generateHighLightClip(sourceURL: videoFileURL, completion: {
                            highlightsDone.leave()
                            completion()
                        })
                        //clear the lightight queue
                        self.highLightArray.removeAll()
                        self.highLightDates.removeAll()
                        let decide = confirmSaveFullVideo ?? { $0(true) }
                        DispatchQueue.main.async {
                            decide { saveFullVideo in
                                guard saveFullVideo else {
                                    highlightsDone.notify(queue: .main) {
                                        // A new recording has already replaced the file.
                                        if !self.isCapturing { self.cleanup() }
                                    }
                                    return
                                }
                                self.requestPhotoLibraryAccess(completion: { (granted) in
                                    // Save the movie file to the photo library and cleanup.
                                    // shouldMoveFile: false — generateHighLightClip (above) reads
                                    // this same URL concurrently via AVAssetExportSession; moving
                                    // (renaming) it out from under that read was a real race that
                                    // could make the main video silently fail to save. Copying
                                    // instead costs one extra disk write but is race-free; cleanup()
                                    // removes the local original either way.
                                    PHPhotoLibrary.shared().performChanges({
                                        let options = PHAssetResourceCreationOptions()
                                        options.shouldMoveFile = false
                                        let creationRequest = PHAssetCreationRequest.forAsset()
                                        creationRequest.addResource(with: .video, fileURL: videoFileURL, options: options)
                                    }, completionHandler: { success, error in
                                        DispatchQueue.main.async {
                                            if !success {
                                                let message = error?.localizedDescription ?? "Unknown error"
                                                print("AVCam couldn't save the movie to your photo library: \(message)")
                                                self.onSaveFailed?(message)
                                            }
                                            self.cleanup()
                                        }
                                    })
                                   /* PHPhotoLibrary.shared().performChanges({
                                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: URL(fileURLWithPath: videoFilePath))
                                    }) { saved, error in
                                        if saved == true {
                                            print("Video saved to photo library")
                                        } else {
                                            print("Video did not save to photo library, reason- \(String(describing: error?.localizedDescription))")
                                        }*/
                                })
                            }
                        }
                    }

                    else {
                            self.cleanup()
                    }
                }

            }
        }
    }
    
    func pauseRecording() {
        timer?.invalidate()     // reset the timer
        isPaused = true
        stopSession()
        print("stopSession")
    }
    
    func resumeRecording(){
        CMResumed = true // flag the pause starting to calculated the pause time
        isPaused = false
        restartSession()
        print("restartSession")
    }
    
    private func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void ) {
        

        let authorizationStatus = PHPhotoLibrary.authorizationStatus()
        
        switch authorizationStatus {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization({ (status) in
                let granted = (status == .authorized)
                    completion(granted)
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
    
    // get video file path
    private func videofilePath() -> String {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDirectory = paths.first!
        let videoPath = "\(documentsDirectory)/video.mp4"
        
        return videoPath
    }
    
    // Note: Because we use a unique file path for each recording, a new
    // recording won't overwrite a recording mid-save.
    func cleanup() {
        let path = videofilePath()
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                print("Could not remove file at url: \(path)")
            }
        }
        /*
        if let currentBackgroundRecordingID = backgroundRecordingID {
            backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
            
            if currentBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
                UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID)
            }
        }*/
    }
    
    //added by Jason
    private func generateHighLightClip(sourceURL:URL, completion: @escaping () -> Void) {
        print ("generate hight")
        // Every export enters this group; skipped highlights never do. So
        // `completion` fires exactly once on all paths — including no highlights
        // and every highlight skipped for being too close to the start.
        let exports = DispatchGroup()
        // Decided once per recording, so every clip lands in the same album even
        // if the saves straddle midnight.
        let albumName = PhotosAlbumSaver.todayAlbumName()
        for (lightTime, lightDate) in zip(highLightArray, highLightDates)
        {
            let uuid = UUID().uuidString
            let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
            let documentsDirectory = paths.first!
            let clippath = "\(documentsDirectory)/\(uuid).mp4"
            let videoURL = URL(fileURLWithPath: clippath)
            let fileManager = FileManager()
            if fileManager.fileExists(atPath: clippath) {
                do {
                    try fileManager.removeItem(atPath: clippath)
                } catch {
                    print("Can't remove file at path \(clippath) so can't export this highlight")
                    continue
                }
            }
            let asset = AVURLAsset(url: sourceURL)
            let exportSession = AVAssetExportSession.init(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
            exportSession.outputURL = videoURL
            exportSession.shouldOptimizeForNetworkUse = true
            exportSession.outputFileType = AVFileType.mp4
            // calculate the highlight time window
            let delay = CMTimeMakeWithSeconds(1.0, preferredTimescale: 600) //include 1sec after the highlight trigger
            let endTime = CMTimeAdd(lightTime, delay)  // add 1sec to the end time
            let duration = CMTimeMakeWithSeconds(HighlightDuration,preferredTimescale: 600)
            if (endTime.seconds - duration.seconds) < 0.0 {
                continue //ignore current highlight
            }
            let startTime = CMTimeSubtract(endTime, duration)
            let range = CMTimeRangeMake(start: startTime, duration: duration)
            exportSession.timeRange = range
            exports.enter()
            exportSession.exportAsynchronously {
                switch(exportSession.status) {
                case .completed:
                    print("exported at \(videoURL)")//
                    self.requestPhotoLibraryAccess(completion: { (granted) in
                        guard granted else {
                            print("No Photos access, highlight not saved")
                            try? FileManager.default.removeItem(at: videoURL)
                            return
                        }
                        PhotosAlbumSaver.save(videoURL: videoURL, albumName: albumName, deleteAfterSave: true, creationDate: lightDate)
                    })
                    break
                case .failed:
                    print("failed \(String(describing: exportSession.error))")//
                case .cancelled:
                    print("cancelled \(String(describing: exportSession.error))")//
                default: break
                }
                exports.leave()
            }
        }
        exports.notify(queue: .main) {
            completion() // spinner stop
        }
    }
    
    func setRecommendedFrameRateRangeForPressureState(systemPressureState: AVCaptureDevice.SystemPressureState) {
        /*
         The frame rates used here are only for demonstration purposes.
         Your frame rate throttling may be different depending on your app's camera configuration.
         */
        let pressureLevel = systemPressureState.level
        if pressureLevel == .serious || pressureLevel == .critical {
            if self.videoWriter == nil || self.isCapturing == false {
                do {
                    try self.backCameraDeviceInput?.device.lockForConfiguration()
                    print("WARNING: Reached elevated system pressure level: \(pressureLevel). Throttling frame rate.")
                    self.backCameraDeviceInput?.device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 20)
                    self.backCameraDeviceInput?.device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
                    self.backCameraDeviceInput?.device.unlockForConfiguration()
                } catch {
                    print("Could not lock device for configuration: \(error)")
                }
            }
        } else if pressureLevel == .shutdown {
            print("Session stopped running due to shutdown system pressure level.")
        }
    }
}

extension videoManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if CMSampleBufferDataIsReady(sampleBuffer) == false {
            print("Sample buffer is not ready")
            return
        }
        
        // calculate sample timing, skip the pause time period
        var sampleTime = CMSampleTimingInfo()
        sampleTime.duration = CMSampleBufferGetDuration(sampleBuffer)
        sampleTime.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        sampleTime.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        // adjust the time stamp, calculation the Pause time
        
        if(CMResumed) {
            CMPausedTime = CMTimeSubtract(sampleTime.presentationTimeStamp, CMPausedTime) //calculate the pause duration
            CMSkipTime = CMTimeAdd(CMSkipTime, CMPausedTime)
            print("Pause end")
            CMPausedTime = CMTime.zero
            CMResumed = false
        }
        else {
            CMPausedTime = sampleTime.presentationTimeStamp //record time of the pause start
        }

        if output is AVCaptureVideoDataOutput {
            videoOutput(output, didOutput: sampleBuffer, from: connection)
        }
        
        if output is AVCaptureAudioDataOutput {
            audioOutput(output, didOutput: sampleBuffer, from: connection)
        }
    }
    
    // MARK: Watermark

    // Proportions relative to frame height, taken from the 1280×720 design:
    // asset height 68 (52pt mark + shadow padding), 28/24 from the right/bottom.
    private static let watermarkHeightFraction: CGFloat = 68.0 / 720.0
    private static let watermarkRightMarginFraction: CGFloat = 28.0 / 720.0
    private static let watermarkBottomMarginFraction: CGFloat = 24.0 / 720.0
    private static let watermarkOpacity: CGFloat = 0.9

    private func watermarked(_ image: CIImage) -> CIImage {
        guard let source = watermarkSource else { return image }
        let extent = image.extent
        if watermarkCache?.extent != extent {
            let scale = extent.height * videoManager.watermarkHeightFraction / source.extent.height
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // CIImage origin is bottom-left, so bottom-right = max x, min y.
            let x = extent.maxX - scaled.extent.width - extent.height * videoManager.watermarkRightMarginFraction
            let y = extent.minY + extent.height * videoManager.watermarkBottomMarginFraction
            let placed = scaled
                .transformed(by: CGAffineTransform(translationX: x - scaled.extent.minX, y: y - scaled.extent.minY))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: videoManager.watermarkOpacity)
                ])
            watermarkCache = (extent, placed)
        }
        return watermarkCache!.image.composited(over: image).cropped(to: extent)
    }

    private func videoOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Can't create pixel buffer")
            return
        }

        guard let videoPreviewViewBounds = videoPreviewViewBounds else {
            print("Unrecognized preview bounds")
            return
        }
        
        var sourceImage = CIImage(cvImageBuffer: pixelBuffer)
        // fix video orientation issue
        if isBackCameraActive == true && orientation == .landscapeLeft {
            sourceImage = sourceImage.oriented(forExifOrientation: 3)
        } else if isBackCameraActive == false && orientation == .landscapeRight {
            sourceImage = sourceImage.oriented(forExifOrientation: 3)
        } else if orientation == .portrait {
            sourceImage = sourceImage.oriented(forExifOrientation: 6)
        }
        let sourceExtent = sourceImage.extent
        
        let sourceAspect = sourceExtent.size.width / sourceExtent.size.height
        let previewAspect = videoPreviewViewBounds.size.width / videoPreviewViewBounds.size.height
        
        // we want to maintain the aspect radio of the screen size, so we clip the video image
        var drawRect = sourceExtent
        if sourceAspect > previewAspect {
            // use full height of the video image, and center crop the width
            drawRect.origin.x += (drawRect.size.width - drawRect.size.height * previewAspect) / 2.0
            drawRect.size.width = drawRect.size.height * previewAspect
        } else {
            // use full width of the video image, and center crop the height
            drawRect.origin.y += (drawRect.size.height - drawRect.size.width / previewAspect) / 2.0
            drawRect.size.height = drawRect.size.width / previewAspect
        }
        
        videoPreviewView?.bindDrawable()
        if glContext != EAGLContext.current() {
            EAGLContext.setCurrent(glContext)
        }
        
        // clear eagl view to grey
        glClearColor(0.5, 0.5, 0.5, 1.0);
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT));
        
        // set the blend mode to "source over" so that CI will use that
        glEnable(GLenum(GL_BLEND));
        glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA));
        
        //ciContext?.draw(filteredImage, in: videoPreviewViewBounds, from: drawRect)
        ciContext?.draw(sourceImage, in: videoPreviewViewBounds, from: drawRect)
        videoPreviewView?.display()
       
        // calculate sample timing, skip the pause time period
        var sampleTime = CMSampleTimingInfo()
        sampleTime.duration = CMSampleBufferGetDuration(sampleBuffer)
        sampleTime.duration = CMTimeSubtract(sampleTime.duration, CMSkipTime)
        
        // recalculate the presentationTime by skipping the paused time
        sampleTime.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        sampleTime.presentationTimeStamp = CMTimeSubtract(sampleTime.presentationTimeStamp, CMSkipTime)
        
        sampleTime.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        sampleTime.decodeTimeStamp = CMTimeSubtract(sampleTime.decodeTimeStamp, CMSkipTime)
        
        //recording
        if (isCapturing == true && isPaused == false) {
            // convert CIImage to CVPixelBuffer
            if cvPixelBuffer == nil {
                let attributesDictionary = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
                CVPixelBufferCreate(kCFAllocatorDefault,
                                    Int(sourceImage.extent.size.width),
                                    Int(sourceImage.extent.size.height),
                                    kCVPixelFormatType_32BGRA,
                                    attributesDictionary as CFDictionary,
                                    &cvPixelBuffer);
            }
            
            ciContext?.render(watermarked(sourceImage), to: cvPixelBuffer!)
            // convert new CVPixelBuffer to new CMSampleBuffer

            
            if(self.firstSamplebuf == true ){
                self.firstSamplebufTime = sampleTime.presentationTimeStamp
                self.firstSamplebuf = false
            }
            //added by Jason
            if(ishighLighting)
            {
                ishighLighting = false //disable the highlight
                let hightTime = CMTimeSubtract(sampleTime.presentationTimeStamp, self.firstSamplebufTime)
                highLightArray.append(hightTime)
                highLightDates.append(Date())
                let count = highLightArray.count
                DispatchQueue.main.async { self.onHighlightCaptured?(count) }
            }
            var videoInfo: CMVideoFormatDescription? = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: cvPixelBuffer!, formatDescriptionOut: &videoInfo)
            var newSampleBuffer: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: cvPixelBuffer!, formatDescription: videoInfo!, sampleTiming: &sampleTime, sampleBufferOut: &newSampleBuffer)
            
            // writer new CMSampleBuffer to asser writer
            self.videoWriter?.write(sample: newSampleBuffer!, isVideoBuffer: true)
        }
    }

    private func audioOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        //recording
        if (isCapturing == true && isPaused == false) {
            // calculate sample timing, skip the pause time period
            var sampleTime = CMSampleTimingInfo()
            sampleTime.duration = CMSampleBufferGetDuration(sampleBuffer)
            
            // recalculate the presentationTime by skipping the paused time
            sampleTime.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            sampleTime.presentationTimeStamp = CMTimeSubtract(sampleTime.presentationTimeStamp, CMSkipTime)
            
            sampleTime.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
            sampleTime.decodeTimeStamp = CMTimeSubtract(sampleTime.decodeTimeStamp, CMSkipTime)
            var newSampleBuffer: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &sampleTime, sampleBufferOut: &newSampleBuffer)
            self.videoWriter?.write(sample: newSampleBuffer!, isVideoBuffer: false)
        }
    }
}


