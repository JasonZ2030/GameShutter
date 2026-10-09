//
//  VideoEditorViewController.swift
//  GameShutter
//
//  A simple CapCut-style editor: pick clips from Photos, trim them by splitting
//  and deleting pieces, add background audio and a GameShutter ending card, then
//  export straight into the Photos library (not the GameShutter folder).
//

import UIKit
import AVFoundation
import Photos
import PhotosUI
import MobileCoreServices

// The editor screens (folder browser + editor) follow how the device is held,
// unlike the landscape-only camera screen. AppDelegate.orientationMask must be
// widened while they're up — HighlightFoldersViewController does that.
enum EditorOrientation {
    static let supported: UIInterfaceOrientationMask = .allButUpsideDown

    static func preferredForPresentation(of viewController: UIViewController) -> UIInterfaceOrientation {
        // Device and interface landscape are mirror images: rotating the device
        // so its top points left (.landscapeLeft) means the UI is .landscapeRight.
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default:
            // Face up/down or unknown (e.g. lying on a table): keep whatever
            // orientation the screen is already in.
            if #available(iOS 13.0, *) {
                return viewController.view.window?.windowScene?.interfaceOrientation
                    ?? viewController.presentingViewController?.view.window?.windowScene?.interfaceOrientation
                    ?? .landscapeRight
            }
            return .landscapeRight
        }
    }
}

// SF Symbols throughout — the entry button is only enabled on iOS 13+.
@available(iOS 13.0, *)
final class VideoEditorViewController: UIViewController {

    private enum ExportQuality: String, CaseIterable {
        case hd = "720p", fullHD = "1080p", uhd = "4K"

        var preset: String {
            switch self {
            case .hd: return AVAssetExportPreset1280x720
            case .fullHD: return AVAssetExportPreset1920x1080
            case .uhd: return AVAssetExportPreset3840x2160
            }
        }
    }

    // MARK: State

    private var project = EditorProject()
    private var undoStack: [EditorProject] = []
    private var redoStack: [EditorProject] = []
    private static let maxUndoSteps = 50
    // True once anything's been changed since the last successful export.
    private var hasUnexportedChanges = false
    private var exportQuality = ExportQuality.fullHD
    private var hasPresentedInitialPicker = false

    // Imported clip/audio copies live here for the editor's lifetime.
    private let importDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GameShutterEditor", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    // MARK: Playback

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var timeObserver: Any?
    private var isPlaying = false {
        didSet { updatePlayButton() }
    }

    // MARK: Views

    private static let background = UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    private static let exportColor = UIColor(red: 0.36, green: 0.78, blue: 0.87, alpha: 1)

    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let qualityButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let previewContainer = UIView()
    private let emptyLabel = UILabel()
    private let timeLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let timeline = EditorTimelineView()
    private let addClipButton = UIButton(type: .system)
    private let splitButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let busyOverlay = EditorBusyOverlay()

    private var exportSession: AVAssetExportSession?
    private var exportProgressTimer: Timer?

    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }
    // Follows how the device is held — opens in portrait or landscape to match,
    // and rotates with it afterwards.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return EditorOrientation.supported }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return EditorOrientation.preferredForPresentation(of: self)
    }

    // MARK: Life cycle

    private let projectTitle: String?
    private let initialAssets: [AVURLAsset]

    // `assets` (already in timeline order) are laid out as the starting project —
    // not an undoable edit, and not counted as unexported changes. With none,
    // the editor starts empty and opens the clip picker.
    init(title: String? = nil, assets: [AVURLAsset] = []) {
        projectTitle = title
        initialAssets = assets
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = VideoEditorViewController.background
        try? FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        buildViews()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        previewContainer.layer.addSublayer(playerLayer)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self = self, self.isPlaying else { return }
            self.timeline.setCurrentTime(time)
            self.updateTimeLabel(time)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinish),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
        refreshUI()
        if !initialAssets.isEmpty {
            hasPresentedInitialPicker = true
            addClips(assets: initialAssets, recordUndo: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Nothing to edit yet — go straight to picking clips.
        if !hasPresentedInitialPicker && project.clips.isEmpty {
            hasPresentedInitialPicker = true
            presentClipPicker()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = previewContainer.bounds
        CATransaction.commit()
    }

    deinit {
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func buildViews() {
        // Top bar: close · quality · export
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        qualityButton.setTitleColor(.white, for: .normal)
        qualityButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        qualityButton.backgroundColor = UIColor(white: 0.17, alpha: 1)
        qualityButton.layer.cornerRadius = 8
        qualityButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        qualityButton.addTarget(self, action: #selector(qualityTapped), for: .touchUpInside)

        exportButton.setTitle("Export", for: .normal)
        exportButton.setTitleColor(.black, for: .normal)
        exportButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        exportButton.backgroundColor = VideoEditorViewController.exportColor
        exportButton.layer.cornerRadius = 8
        exportButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        // Preview
        previewContainer.backgroundColor = .black
        previewContainer.clipsToBounds = true
        emptyLabel.text = "Tap + to add clips"
        emptyLabel.textColor = UIColor(white: 0.6, alpha: 1)
        emptyLabel.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(emptyLabel)

        // Controls: time · play · undo/redo
        timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        timeLabel.textColor = .white
        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        configureIconButton(undoButton, symbol: "arrow.uturn.backward", action: #selector(undoTapped))
        configureIconButton(redoButton, symbol: "arrow.uturn.forward", action: #selector(redoTapped))

        // Timeline + add-clips button
        timeline.delegate = self
        addClipButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)), for: .normal)
        addClipButton.tintColor = .black
        addClipButton.backgroundColor = .white
        addClipButton.layer.cornerRadius = 6
        addClipButton.addTarget(self, action: #selector(addClipTapped), for: .touchUpInside)

        // Edit actions
        configureActionButton(splitButton, title: "Split", symbol: "scissors", action: #selector(splitTapped))
        configureActionButton(deleteButton, title: "Delete", symbol: "trash", action: #selector(deleteTapped))

        titleLabel.text = projectTitle
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topBar = UIStackView(arrangedSubviews: [closeButton, titleLabel, UIView(), qualityButton, exportButton])
        topBar.spacing = 12
        topBar.alignment = .center

        let controlBar = UIView()
        let undoRedo = UIStackView(arrangedSubviews: [undoButton, redoButton])
        undoRedo.spacing = 20
        [timeLabel, playButton, undoRedo].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            controlBar.addSubview($0)
        }

        let actionBar = UIStackView(arrangedSubviews: [splitButton, deleteButton])
        actionBar.spacing = 40

        [topBar, previewContainer, controlBar, timeline, addClipButton, actionBar, busyOverlay].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        busyOverlay.isHidden = true
        busyOverlay.cancelButton.addTarget(self, action: #selector(cancelExportTapped), for: .touchUpInside)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 44),

            previewContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),

            controlBar.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 2),
            controlBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            controlBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            controlBar.heightAnchor.constraint(equalToConstant: 32),
            timeLabel.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            playButton.centerXAnchor.constraint(equalTo: controlBar.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 32),
            undoRedo.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor),
            undoRedo.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),

            timeline.topAnchor.constraint(equalTo: controlBar.bottomAnchor),
            timeline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            timeline.heightAnchor.constraint(equalToConstant: EditorTimelineView.preferredHeight),

            addClipButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            addClipButton.topAnchor.constraint(equalTo: timeline.topAnchor, constant: EditorTimelineView.clipTop),
            addClipButton.widthAnchor.constraint(equalToConstant: EditorTimelineView.clipHeight),
            addClipButton.heightAnchor.constraint(equalToConstant: EditorTimelineView.clipHeight),

            actionBar.topAnchor.constraint(equalTo: timeline.bottomAnchor),
            actionBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 30),
            actionBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -4),

            busyOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            busyOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            busyOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            busyOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureIconButton(_ button: UIButton, symbol: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func configureActionButton(_ button: UIButton, title: String, symbol: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.setTitle("  " + title, for: .normal)
        button.tintColor = .white
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: Project changes

    // Every edit goes through here, so undo/redo, the player and the timeline
    // all stay in sync.
    private func apply(_ newProject: EditorProject) {
        undoStack.append(project)
        if undoStack.count > VideoEditorViewController.maxUndoSteps {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        setProject(newProject)
    }

    private func setProject(_ newProject: EditorProject) {
        let time = timeline.currentTime
        project = newProject
        hasUnexportedChanges = true
        // Drop a selection whose clip no longer exists.
        switch timeline.selection {
        case .clip(let id)? where !project.clips.contains(where: { $0.id == id }):
            timeline.selection = nil
        case .audio? where project.audio == nil:
            timeline.selection = nil
        default:
            break
        }
        timeline.project = project
        reloadPlayer(at: CMTimeMinimum(time, project.duration))
        refreshUI()
    }

    private func reloadPlayer(at time: CMTime) {
        pause()
        guard let built = EditorCompositionBuilder.build(project) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        player.replaceCurrentItem(with: item)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        timeline.setCurrentTime(time)
        updateTimeLabel(time)
    }

    private func refreshUI() {
        let hasClips = !project.clips.isEmpty
        emptyLabel.isHidden = hasClips
        exportButton.isEnabled = hasClips
        exportButton.alpha = hasClips ? 1 : 0.4
        playButton.isEnabled = hasClips
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        splitButton.isEnabled = hasClips
        deleteButton.isEnabled = timeline.selection != nil
        qualityButton.setTitle(exportQuality.rawValue + " ▾", for: .normal)
        updatePlayButton()
        updateTimeLabel(timeline.currentTime)
    }

    private func updateTimeLabel(_ time: CMTime) {
        timeLabel.text = EditorTimelineView.format(seconds: time.seconds) + " / " +
            EditorTimelineView.format(seconds: project.duration.seconds)
    }

    private func updatePlayButton() {
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
    }

    // MARK: Playback controls

    @objc private func playTapped() {
        if isPlaying {
            pause()
            return
        }
        guard player.currentItem != nil else { return }
        // At (or within a frame of) the end — start over.
        if CMTimeSubtract(project.duration, timeline.currentTime).seconds < 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            timeline.setCurrentTime(.zero)
        }
        player.play()
        isPlaying = true
    }

    private func pause() {
        player.pause()
        isPlaying = false
    }

    @objc private func playerDidFinish(_ notification: Notification) {
        guard (notification.object as? AVPlayerItem) === player.currentItem else { return }
        isPlaying = false
        timeline.setCurrentTime(project.duration)
        updateTimeLabel(project.duration)
    }

    // MARK: Edit actions

    @objc private func undoTapped() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        setProject(previous)
    }

    @objc private func redoTapped() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        setProject(next)
    }

    @objc private func splitTapped() {
        var edited = project
        if edited.split(at: timeline.currentTime) {
            apply(edited)
        } else {
            splitButton.shake()
        }
    }

    @objc private func deleteTapped() {
        var edited = project
        switch timeline.selection {
        case .clip(let id)?:
            edited.clips.removeAll { $0.id == id }
        case .audio?:
            edited.audio = nil
        case nil:
            return
        }
        timeline.selection = nil
        apply(edited)
    }

    // MARK: Top bar

    @objc private func closeTapped() {
        guard hasUnexportedChanges && !project.clips.isEmpty else {
            close()
            return
        }
        let alert = UIAlertController(title: "Discard this edit?",
                                      message: "Your changes haven't been exported and will be lost.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { _ in self.close() })
        present(alert, animated: true)
    }

    private func close() {
        pause()
        player.replaceCurrentItem(with: nil)
        try? FileManager.default.removeItem(at: importDirectory)
        // Back to the folder browser, which handles returning to the camera.
        dismiss(animated: true)
    }

    @objc private func qualityTapped() {
        let sheet = UIAlertController(title: "Export Resolution", message: nil, preferredStyle: .actionSheet)
        for quality in ExportQuality.allCases {
            let title = quality == exportQuality ? "✓ " + quality.rawValue : quality.rawValue
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                self.exportQuality = quality
                self.refreshUI()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = qualityButton
        sheet.popoverPresentationController?.sourceRect = qualityButton.bounds
        present(sheet, animated: true)
    }

    @objc private func exportTapped() {
        pause()
        PHPhotoLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.showMessage(title: "No Photos Access",
                                     message: "Allow GameShutter full access to Photos in Settings to export.")
                    return
                }
                self.startExport()
            }
        }
    }

    private func startExport() {
        guard let built = EditorCompositionBuilder.build(project) else { return }
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: built.composition)
        let preset = compatible.contains(exportQuality.preset) ? exportQuality.preset : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            showMessage(title: "Export Failed", message: "This edit can't be exported.")
            return
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameShutter_Edit_\(UUID().uuidString).mp4")
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = built.videoComposition
        exportSession = session

        busyOverlay.show(text: "Exporting 0%", progress: 0, cancellable: true)
        exportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let session = self?.exportSession else { return }
            self?.busyOverlay.show(text: "Exporting \(Int(session.progress * 100))%",
                                   progress: session.progress, cancellable: true)
        }

        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.exportProgressTimer?.invalidate()
                self.exportProgressTimer = nil
                self.exportSession = nil
                switch session.status {
                case .completed:
                    self.busyOverlay.show(text: "Saving to Photos…", progress: nil, cancellable: false)
                    // Straight into the library, not the GameShutter folder —
                    // that's for highlight clips (the editor's source material).
                    // The file is kept until sharing is done — the TikTok path
                    // shares the file itself.
                    PhotosAlbumSaver.save(videoURL: outputURL, albumName: nil, deleteAfterSave: false) { localIdentifier, error in
                        self.busyOverlay.isHidden = true
                        if let error = error {
                            try? FileManager.default.removeItem(at: outputURL)
                            self.showMessage(title: "Save Failed", message: error.localizedDescription)
                        } else {
                            self.hasUnexportedChanges = false
                            self.offerToShare(fileURL: outputURL, localIdentifier: localIdentifier)
                        }
                    }
                case .cancelled:
                    self.busyOverlay.isHidden = true
                    try? FileManager.default.removeItem(at: outputURL)
                default:
                    self.busyOverlay.isHidden = true
                    try? FileManager.default.removeItem(at: outputURL)
                    self.showMessage(title: "Export Failed",
                                     message: session.error?.localizedDescription ?? "Unknown error")
                }
            }
        }
    }

    // MARK: Sharing

    // After a successful export: Instagram, TikTok, or neither. Every path ends
    // by deleting the local export file (the video is already in Photos).
    private func offerToShare(fileURL: URL, localIdentifier: String?) {
        let alert = UIAlertController(title: "Saved to Photos",
                                      message: "Share your highlight video?",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Instagram", style: .default) { _ in
            self.shareToInstagram(localIdentifier: localIdentifier, fileURL: fileURL)
        })
        alert.addAction(UIAlertAction(title: "TikTok", style: .default) { _ in
            self.shareToTikTok(fileURL: fileURL)
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in
            try? FileManager.default.removeItem(at: fileURL)
        })
        present(alert, animated: true)
    }

    // Instagram's library hook opens its posting flow with this Photos asset
    // already selected. No Info.plist query-scheme entry is needed: open(_:)
    // simply reports failure when Instagram isn't installed.
    private func shareToInstagram(localIdentifier: String?, fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        guard let localIdentifier = localIdentifier,
              let encoded = localIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "instagram://library?LocalIdentifier=\(encoded)") else {
            showMessage(title: "Couldn't Open Instagram", message: "The video is saved in Photos — share it from there.")
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                self.showMessage(title: "Instagram Isn't Installed",
                                 message: "Install Instagram to share directly. The video is saved in Photos.")
            }
        }
    }

    // TikTok has no public URL scheme for handing over a video; its official
    // route is the TikTok OpenSDK (needs a client key from TikTok's developer
    // portal). Until that's set up, this offers the system share sheet, where
    // TikTok appears as a target when it's installed.
    private func shareToTikTok(fileURL: URL) {
        let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = exportButton
        sheet.popoverPresentationController?.sourceRect = exportButton.bounds
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: fileURL)
        }
        present(sheet, animated: true)
    }

    @objc private func cancelExportTapped() {
        exportSession?.cancelExport()
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Importing clips

    @objc private func addClipTapped() {
        presentClipPicker()
    }

    private func presentClipPicker() {
        pause()
        if #available(iOS 14.0, *) {
            var config = PHPickerConfiguration()
            config.filter = .videos
            config.selectionLimit = 0
            // Hand over the original file instead of transcoding it.
            config.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            present(picker, animated: true)
        } else {
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.mediaTypes = [kUTTypeMovie as String]
            picker.videoExportPreset = AVAssetExportPresetPassthrough
            picker.delegate = self
            present(picker, animated: true)
        }
    }

    // Copies a file the system will soon delete into this editor's own folder.
    private func copyIntoImportDirectory(_ url: URL) -> URL? {
        let destination = importDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            print("Editor: couldn't copy \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // Loads tracks/duration up front (so building the composition never blocks),
    // drops anything without a video track, and appends the rest as clips.
    private func addClips(from urls: [URL]) {
        addClips(assets: urls.map { AVURLAsset(url: $0) }, recordUndo: true)
    }

    // recordUndo false = the starting project (see init), which also doesn't
    // count as an unexported change.
    private func addClips(assets: [AVURLAsset], recordUndo: Bool) {
        guard !assets.isEmpty else { return }
        busyOverlay.show(text: recordUndo ? "Importing…" : "Loading clips…", progress: nil, cancellable: false)
        loadPlayableValues(of: assets) {
            self.busyOverlay.isHidden = true
            let clips = assets.compactMap { asset -> EditorClip? in
                guard !asset.tracks(withMediaType: .video).isEmpty, asset.duration.seconds > 0 else { return nil }
                return EditorClip(asset: asset, timeRange: CMTimeRange(start: .zero, duration: asset.duration))
            }
            if clips.count < assets.count {
                self.showMessage(title: "Some Videos Skipped", message: "\(assets.count - clips.count) item(s) couldn't be read.")
            }
            guard !clips.isEmpty else { return }
            var edited = self.project
            edited.append(clips)
            if recordUndo {
                self.apply(edited)
            } else {
                self.setProject(edited)
                self.hasUnexportedChanges = false
            }
        }
    }

    private func loadPlayableValues(of assets: [AVURLAsset], completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for asset in assets {
            group.enter()
            asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }
}

// MARK: - Timeline

@available(iOS 13.0, *)
extension VideoEditorViewController: EditorTimelineViewDelegate {
    func timelineDidScrub(to time: CMTime) {
        if isPlaying { pause() }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        updateTimeLabel(time)
    }

    func timelineDidChangeSelection(_ selection: EditorTimelineView.Selection?) {
        refreshUI()
    }

    func timelineDidTapAddEnding() {
        busyOverlay.show(text: "Creating ending…", progress: nil, cancellable: false)
        EndingClipRenderer.endingAsset { asset in
            guard let asset = asset else {
                self.busyOverlay.isHidden = true
                self.showMessage(title: "Couldn't Add Ending", message: "The ending clip couldn't be created.")
                return
            }
            self.loadPlayableValues(of: [asset]) {
                self.busyOverlay.isHidden = true
                guard !self.project.hasEnding else { return }
                var edited = self.project
                edited.clips.append(EditorClip(asset: asset,
                                               timeRange: CMTimeRange(start: .zero, duration: asset.duration),
                                               isEnding: true))
                self.apply(edited)
            }
        }
    }

    func timelineDidTapAddAudio() {
        pause()
        let picker = UIDocumentPickerViewController(documentTypes: [kUTTypeAudio as String], in: .import)
        picker.delegate = self
        present(picker, animated: true)
    }
}

// MARK: - Pickers

@available(iOS 14.0, *)
extension VideoEditorViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        busyOverlay.show(text: "Importing…", progress: nil, cancellable: false)
        // Keep the user's selection order, whatever order the copies finish in.
        var copied = [URL?](repeating: nil, count: results.count)
        let group = DispatchGroup()
        for (i, result) in results.enumerated() {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(kUTTypeMovie as String) else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: kUTTypeMovie as String) { url, error in
                // `url` is deleted when this handler returns — copy it now.
                if let url = url {
                    let copy = self.copyIntoImportDirectory(url)
                    DispatchQueue.main.async { copied[i] = copy; group.leave() }
                } else {
                    print("Editor: couldn't load picked video: \(String(describing: error))")
                    DispatchQueue.main.async { group.leave() }
                }
            }
        }
        group.notify(queue: .main) {
            self.busyOverlay.isHidden = true
            self.addClips(from: copied.compactMap { $0 })
        }
    }
}

@available(iOS 13.0, *)
extension VideoEditorViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let url = info[.mediaURL] as? URL, let copy = copyIntoImportDirectory(url) {
            addClips(from: [copy])
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

@available(iOS 13.0, *)
extension VideoEditorViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let copy = copyIntoImportDirectory(url) else { return }
        let asset = AVURLAsset(url: copy)
        loadPlayableValues(of: [asset]) {
            guard !asset.tracks(withMediaType: .audio).isEmpty else {
                self.showMessage(title: "Can't Use This File", message: "It doesn't contain any audio.")
                return
            }
            var edited = self.project
            edited.audio = EditorAudio(asset: asset, name: url.deletingPathExtension().lastPathComponent)
            self.apply(edited)
        }
    }
}

// MARK: - Busy overlay

// Dimmed full-screen overlay for importing/exporting, with optional progress
// bar and Cancel button.
final class EditorBusyOverlay: UIView {
    let cancelButton = UIButton(type: .system)
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .whiteLarge)
    private let progressView = UIProgressView(progressViewStyle: .default)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.textColor = .white
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        progressView.progressTintColor = UIColor(red: 0.36, green: 0.78, blue: 0.87, alpha: 1)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.tintColor = .white
        let stack = UIStackView(arrangedSubviews: [spinner, label, progressView, cancelButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressView.widthAnchor.constraint(equalToConstant: 240)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // `progress` nil shows a spinner instead of a bar.
    func show(text: String, progress: Float?, cancellable: Bool) {
        isHidden = false
        superview?.bringSubviewToFront(self)
        label.text = text
        if let progress = progress {
            progressView.isHidden = false
            progressView.progress = progress
            spinner.stopAnimating()
            spinner.isHidden = true
        } else {
            progressView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimating()
        }
        cancelButton.isHidden = !cancellable
    }
}
