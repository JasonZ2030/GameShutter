//
//  HighlightFoldersViewController.swift
//  GameShutter
//
//  The film button's first screen: a grid of the date albums in Photos'
//  GameShutter folder (newest first), each shown with its earliest clip's
//  thumbnail. Picking one opens the editor with that album's videos laid out
//  along the timeline in creation-date order, earliest first. The last card,
//  "+", opens a blank project instead. The trash button puts the grid in
//  delete mode: folder cards wiggle until one is tapped, then a confirmation
//  offers to delete that album (with or without its clips).
//

import UIKit
import Photos
import AVFoundation

@available(iOS 13.0, *)
final class HighlightFoldersViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private struct Folder {
        let album: PHAssetCollection
        let title: String
        // Videos only, oldest first.
        let videos: PHFetchResult<PHAsset>
    }

    private var folders: [Folder] = []
    private let imageManager = PHCachingImageManager()

    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let deleteModeButton = UIButton(type: .system)
    // While true, folder cards wiggle and tapping one asks to delete it.
    private var isInDeleteMode = false
    private let emptyLabel = UILabel()
    private let busyOverlay = EditorBusyOverlay()
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = UIEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.dataSource = self
        view.delegate = self
        view.register(HighlightFolderCell.self, forCellWithReuseIdentifier: HighlightFolderCell.identifier)
        return view
    }()

    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return EditorOrientation.supported }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return EditorOrientation.preferredForPresentation(of: self)
    }

    // MARK: Life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        titleLabel.text = Constants.PhotosAlbums.FolderName
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)

        emptyLabel.textColor = UIColor(white: 0.6, alpha: 1)
        emptyLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0

        deleteModeButton.tintColor = .white
        deleteModeButton.setTitleColor(.white, for: .normal)
        deleteModeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        deleteModeButton.addTarget(self, action: #selector(deleteModeTapped), for: .touchUpInside)
        updateDeleteModeButton()

        let topBar = UIStackView(arrangedSubviews: [closeButton, titleLabel, UIView(), deleteModeButton])
        topBar.spacing = 12
        topBar.alignment = .center

        [topBar, collectionView, emptyLabel, busyOverlay].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        busyOverlay.isHidden = true

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            deleteModeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            collectionView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),

            busyOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            busyOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            busyOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            busyOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // Also runs when the editor closes, so an export into today's album shows up.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadFolders()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
        })
    }

    // MARK: Loading

    private func reloadFolders() {
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized:
            loadFolders()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { _ in
                DispatchQueue.main.async { self.reloadFolders() }
            }
        default:
            folders = []
            collectionView.reloadData()
            emptyLabel.text = "Allow GameShutter full access to Photos in Settings to see your highlight folders."
            emptyLabel.isHidden = false
        }
    }

    private func loadFolders() {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Album names are yyyy_MM_dd, so sorting names descending is newest first.
        folders = PhotosAlbumSaver.dateAlbums()
            .map { Folder(album: $0, title: $0.localizedTitle ?? "", videos: PHAsset.fetchAssets(in: $0, options: options)) }
            .filter { $0.videos.count > 0 }
            .sorted { $0.title > $1.title }
        collectionView.reloadData()
        emptyLabel.text = "No highlight folders yet.\nHighlights you capture while recording will appear here, grouped by day."
        emptyLabel.isHidden = !folders.isEmpty
        if folders.isEmpty {
            isInDeleteMode = false
        }
        updateDeleteModeButton()
    }

    // MARK: Actions

    @objc private func closeTapped() {
        // Back to the landscape-only camera screen.
        AppDelegate.orientationMask = .landscape
        let presenter = presentingViewController
        dismiss(animated: true) {
            if #available(iOS 16.0, *) {
                presenter?.setNeedsUpdateOfSupportedInterfaceOrientations()
            } else {
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }
    }

    // MARK: Delete mode

    @objc private func deleteModeTapped() {
        setDeleteMode(!isInDeleteMode)
    }

    private func setDeleteMode(_ on: Bool) {
        isInDeleteMode = on
        updateDeleteModeButton()
        for case let cell as HighlightFolderCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            cell.setDeleteMode(on, isFolder: !isBlankProjectItem(indexPath))
        }
    }

    // Trash icon normally; "Done" while the cards are wiggling. Hidden when
    // there's nothing to delete.
    private func updateDeleteModeButton() {
        if isInDeleteMode {
            deleteModeButton.setImage(nil, for: .normal)
            deleteModeButton.setTitle("Done", for: .normal)
        } else {
            deleteModeButton.setTitle(nil, for: .normal)
            deleteModeButton.setImage(UIImage(systemName: "trash"), for: .normal)
        }
        deleteModeButton.isHidden = folders.isEmpty
    }

    private func confirmDelete(_ folder: Folder) {
        let count = folder.videos.count
        let clips = count == 1 ? "1 clip" : "\(count) clips"
        let alert = UIAlertController(
            title: "Delete \(folder.title)?",
            message: "Deleting the clips removes them from your Photos library (they go to Recently Deleted). Removing only the folder keeps the clips in your library.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete Folder and \(clips)", style: .destructive) { _ in
            self.delete(folder, includingClips: true)
        })
        alert.addAction(UIAlertAction(title: "Remove Folder Only", style: .default) { _ in
            self.delete(folder, includingClips: false)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // iOS shows its own delete confirmation on top of ours; declining it comes
    // back as PHPhotosError.userCancelled, which isn't worth an error alert.
    private func delete(_ folder: Folder, includingClips: Bool) {
        PHPhotoLibrary.shared().performChanges({
            if includingClips {
                // Everything in the album, not just the videos the card counts.
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(in: folder.album, options: nil))
            }
            PHAssetCollectionChangeRequest.deleteAssetCollections([folder.album] as NSArray)
        }, completionHandler: { success, error in
            DispatchQueue.main.async {
                if !success, let error = error, (error as NSError).code != PHPhotosError.userCancelled.rawValue {
                    self.showMessage(title: "Couldn't Delete \(folder.title)", message: error.localizedDescription)
                }
                self.reloadFolders()
            }
        })
    }

    // MARK: Opening

    private func openBlankProject() {
        presentEditor(VideoEditorViewController())
    }

    private func presentEditor(_ editor: VideoEditorViewController) {
        editor.modalPresentationStyle = .fullScreen
        present(editor, animated: true)
    }

    // Resolves each video to a file-backed AVURLAsset (downloading from iCloud
    // if needed), keeping the album's oldest-first order, then opens the editor.
    private func open(_ folder: Folder) {
        busyOverlay.show(text: "Loading \(folder.title)…", progress: nil, cancellable: false)
        let videoOptions = PHVideoRequestOptions()
        videoOptions.isNetworkAccessAllowed = true
        videoOptions.deliveryMode = .highQualityFormat
        videoOptions.version = .current

        var assets = [AVURLAsset?](repeating: nil, count: folder.videos.count)
        let group = DispatchGroup()
        folder.videos.enumerateObjects { phAsset, index, _ in
            group.enter()
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: videoOptions) { avAsset, _, _ in
                DispatchQueue.main.async {
                    // Slow-motion and other edited compositions aren't backed by a
                    // single file; the editor only handles plain video files.
                    assets[index] = avAsset as? AVURLAsset
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.busyOverlay.isHidden = true
            let loaded = assets.compactMap { $0 }
            guard !loaded.isEmpty else {
                self.showMessage(title: "Couldn't Open Folder", message: "None of the videos in \(folder.title) could be loaded.")
                return
            }
            if loaded.count < assets.count {
                print("Editor: \(assets.count - loaded.count) video(s) in \(folder.title) couldn't be loaded")
            }
            self.presentEditor(VideoEditorViewController(title: folder.title, assets: loaded))
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Collection view

    // One card per folder, then the "+" blank-project card last.
    private func isBlankProjectItem(_ indexPath: IndexPath) -> Bool {
        return indexPath.item == folders.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return folders.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HighlightFolderCell.identifier, for: indexPath) as! HighlightFolderCell
        cell.setDeleteMode(isInDeleteMode, isFolder: !isBlankProjectItem(indexPath))
        if isBlankProjectItem(indexPath) {
            cell.configureAsBlankProject()
            return cell
        }
        let folder = folders[indexPath.item]
        let count = folder.videos.count
        cell.configure(title: folder.title, subtitle: count == 1 ? "1 clip" : "\(count) clips")

        // The first (earliest) video is the folder's thumbnail.
        if let first = folder.videos.firstObject {
            cell.representedAssetIdentifier = first.localIdentifier
            let scale = UIScreen.main.scale
            let size = HighlightFolderCell.thumbnailSize(forCellWidth: cell.bounds.width)
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            imageManager.requestImage(for: first, targetSize: CGSize(width: size.width * scale, height: size.height * scale),
                                      contentMode: .aspectFill, options: options) { image, _ in
                // The cell may have been reused for another folder meanwhile.
                if cell.representedAssetIdentifier == first.localIdentifier {
                    cell.thumbnail.image = image
                }
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isInDeleteMode {
            // Picking a folder ends delete mode either way; "+" isn't deletable.
            guard !isBlankProjectItem(indexPath) else { return }
            setDeleteMode(false)
            confirmDelete(folders[indexPath.item])
        } else if isBlankProjectItem(indexPath) {
            openBlankProject()
        } else {
            open(folders[indexPath.item])
        }
    }

    // As many ~220pt-wide columns as fit, at least two.
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let flow = collectionViewLayout as! UICollectionViewFlowLayout
        let available = collectionView.bounds.width - flow.sectionInset.left - flow.sectionInset.right
        let columns = max(2, Int((available + flow.minimumInteritemSpacing) / (220 + flow.minimumInteritemSpacing)))
        let width = floor((available - CGFloat(columns - 1) * flow.minimumInteritemSpacing) / CGFloat(columns))
        return CGSize(width: width, height: HighlightFolderCell.height(forWidth: width))
    }
}

// A folder card: 16:9 thumbnail, folder name, clip count.
@available(iOS 13.0, *)
final class HighlightFolderCell: UICollectionViewCell {
    static let identifier = "HighlightFolderCell"
    private static let textHeight: CGFloat = 46

    let thumbnail = UIImageView()
    var representedAssetIdentifier: String?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    // Red ✕ shown on folder cards in delete mode.
    private let deleteBadge = UIImageView()
    private static let wiggleKey = "wiggle"

    static func thumbnailSize(forCellWidth width: CGFloat) -> CGSize {
        return CGSize(width: width, height: (width * 9 / 16).rounded())
    }

    static func height(forWidth width: CGFloat) -> CGFloat {
        return thumbnailSize(forCellWidth: width).height + textHeight
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 8
        thumbnail.backgroundColor = UIColor(white: 0.17, alpha: 1)
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.textColor = UIColor(white: 0.6, alpha: 1)
        subtitleLabel.font = UIFont.systemFont(ofSize: 13)
        deleteBadge.image = UIImage(systemName: "xmark.circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        deleteBadge.tintColor = .systemRed
        deleteBadge.backgroundColor = .white
        deleteBadge.layer.cornerRadius = 12
        deleteBadge.isHidden = true
        [thumbnail, titleLabel, subtitleLabel, deleteBadge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9.0 / 16.0),
            titleLabel.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            deleteBadge.centerXAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: 6),
            deleteBadge.centerYAnchor.constraint(equalTo: thumbnail.topAnchor, constant: 6),
            deleteBadge.widthAnchor.constraint(equalToConstant: 24),
            deleteBadge.heightAnchor.constraint(equalToConstant: 24)
        ])
        // The badge pokes past the card's corner.
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    // Folder cards wiggle with a ✕ badge; the "+" card just dims, since it
    // can't be deleted.
    func setDeleteMode(_ on: Bool, isFolder: Bool) {
        deleteBadge.isHidden = !(on && isFolder)
        contentView.alpha = (on && !isFolder) ? 0.35 : 1
        if on && isFolder {
            startWiggling()
        } else {
            layer.removeAnimation(forKey: HighlightFolderCell.wiggleKey)
        }
    }

    private func startWiggling() {
        guard layer.animation(forKey: HighlightFolderCell.wiggleKey) == nil else { return }
        let angle = 1.6 * Double.pi / 180
        let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wiggle.values = [-angle, angle, -angle]
        wiggle.duration = 0.26
        wiggle.repeatCount = .infinity
        // Otherwise backgrounding the app strips it and the cards come back still.
        wiggle.isRemovedOnCompletion = false
        // Random phase so the cards don't move in lockstep.
        wiggle.beginTime = CACurrentMediaTime() + Double.random(in: 0...0.26)
        layer.add(wiggle, forKey: HighlightFolderCell.wiggleKey)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    // The trailing "+" card: a centered plus instead of a video thumbnail.
    func configureAsBlankProject() {
        configure(title: "Blank Project", subtitle: "Pick clips from Photos")
        thumbnail.contentMode = .center
        thumbnail.tintColor = .white
        thumbnail.image = UIImage(systemName: "plus",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .medium))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.image = nil
        thumbnail.contentMode = .scaleAspectFill
        representedAssetIdentifier = nil
        setDeleteMode(false, isFolder: false)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
