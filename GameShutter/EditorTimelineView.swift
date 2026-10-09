//
//  EditorTimelineView.swift
//  GameShutter
//
//  The editor's scrollable timeline: time ruler, one thumbnail strip per clip,
//  the background-audio row, and a fixed center playhead. Horizontal scroll
//  position *is* the playhead time — contentInset is half the view's width on
//  each side, so time 0 sits under the playhead at the leftmost scroll offset.
//

import UIKit
import AVFoundation

protocol EditorTimelineViewDelegate: AnyObject {
    // User scrubbed (dragging or decelerating) — not called for setCurrentTime(_:).
    func timelineDidScrub(to time: CMTime)
    func timelineDidChangeSelection(_ selection: EditorTimelineView.Selection?)
    func timelineDidTapAddEnding()
    func timelineDidTapAddAudio()
}

final class EditorTimelineView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    enum Selection: Equatable {
        case clip(UUID)
        case audio
    }

    weak var delegate: EditorTimelineViewDelegate?

    var project = EditorProject() {
        didSet { relayout(keeping: currentTime) }
    }

    var selection: Selection? {
        didSet { updateSelectionHighlight() }
    }

    // Kept compact so the preview above gets as much height as possible.
    private static let rulerHeight: CGFloat = 18
    static let clipTop: CGFloat = 22
    static let clipHeight: CGFloat = 44
    private static let audioTop: CGFloat = clipTop + clipHeight + 6
    private static let audioHeight: CGFloat = 28
    static let preferredHeight: CGFloat = audioTop + audioHeight + 4
    private static let addEndingWidth: CGFloat = 160

    private var pointsPerSecond: CGFloat = 40
    private var pinchStartPointsPerSecond: CGFloat = 40

    private let scrollView = UIScrollView()
    private let playhead = UIView()
    private var contentViews: [UIView] = []
    private var clipViews: [UUID: EditorClipStripView] = [:]
    private var audioView: UIView?
    private let thumbnails = EditorThumbnailCache()
    private var isSettingOffset = false

    var currentTime: CMTime {
        let x = scrollView.contentOffset.x + scrollView.contentInset.left
        let seconds = max(0, Double(x / pointsPerSecond))
        return CMTimeMinimum(CMTime(seconds: seconds, preferredTimescale: 600), project.duration)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.delegate = self
        addSubview(scrollView)

        playhead.backgroundColor = .white
        playhead.isUserInteractionEnabled = false
        playhead.layer.cornerRadius = 1
        addSubview(playhead)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
        scrollView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Programmatic (playback-driven) move — doesn't report a scrub.
    func setCurrentTime(_ time: CMTime) {
        isSettingOffset = true
        scrollView.contentOffset.x = CGFloat(time.seconds) * pointsPerSecond - scrollView.contentInset.left
        isSettingOffset = false
    }

    private var lastLaidOutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        playhead.frame = CGRect(x: bounds.midX - 1, y: EditorTimelineView.rulerHeight + 2,
                                width: 2, height: bounds.height - EditorTimelineView.rulerHeight - 2)
        if bounds.width != lastLaidOutWidth {
            lastLaidOutWidth = bounds.width
            relayout(keeping: currentTime)
        }
    }

    // MARK: Layout

    private func relayout(keeping time: CMTime) {
        scrollView.frame = bounds
        let halfWidth = bounds.width / 2
        scrollView.contentInset = UIEdgeInsets(top: 0, left: halfWidth, bottom: 0, right: halfWidth)

        contentViews.forEach { $0.removeFromSuperview() }
        contentViews.removeAll()
        clipViews.removeAll()
        audioView = nil

        let pps = pointsPerSecond
        let totalWidth = CGFloat(project.duration.seconds) * pps
        layoutRuler(totalWidth: totalWidth)

        // Clip strips, with a small white marker at each junction.
        let starts = project.clipStarts
        for (i, clip) in project.clips.enumerated() {
            let frame = CGRect(x: CGFloat(starts[i].seconds) * pps, y: EditorTimelineView.clipTop,
                               width: max(2, CGFloat(clip.duration.seconds) * pps),
                               height: EditorTimelineView.clipHeight)
            let strip = EditorClipStripView(frame: frame)
            strip.configure(with: clip, pointsPerSecond: pps, thumbnails: thumbnails)
            add(strip)
            clipViews[clip.id] = strip
        }
        for start in starts.dropFirst() {
            let marker = UIView(frame: CGRect(x: CGFloat(start.seconds) * pps - 4,
                                              y: EditorTimelineView.clipTop + (EditorTimelineView.clipHeight - 18) / 2,
                                              width: 8, height: 18))
            marker.backgroundColor = .white
            marker.layer.cornerRadius = 2
            marker.isUserInteractionEnabled = false
            add(marker)
        }

        var contentWidth = totalWidth
        if !project.clips.isEmpty && !project.hasEnding {
            let button = makeAddButton(title: "Add ending", action: #selector(addEndingTapped))
            button.frame = CGRect(x: totalWidth + 12, y: EditorTimelineView.clipTop,
                                  width: EditorTimelineView.addEndingWidth, height: EditorTimelineView.clipHeight)
            add(button)
            contentWidth = button.frame.maxX
        }

        if let audio = project.audio {
            let audioSeconds = min(audio.asset.duration.seconds, project.duration.seconds)
            let bar = UIView(frame: CGRect(x: 0, y: EditorTimelineView.audioTop,
                                           width: max(40, CGFloat(audioSeconds) * pps),
                                           height: EditorTimelineView.audioHeight))
            bar.backgroundColor = UIColor(red: 0.18, green: 0.44, blue: 0.42, alpha: 1)
            bar.layer.cornerRadius = 4
            bar.clipsToBounds = true
            let label = UILabel(frame: bar.bounds.insetBy(dx: 10, dy: 0))
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.text = "♪  " + audio.name
            label.textColor = .white
            label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            bar.addSubview(label)
            add(bar)
            audioView = bar
        } else if !project.clips.isEmpty {
            let button = makeAddButton(title: "Add audio", action: #selector(addAudioTapped))
            button.contentHorizontalAlignment = .left
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
            button.frame = CGRect(x: 0, y: EditorTimelineView.audioTop,
                                  width: max(180, totalWidth), height: EditorTimelineView.audioHeight)
            add(button)
        }

        scrollView.contentSize = CGSize(width: contentWidth, height: bounds.height)
        updateSelectionHighlight()
        setCurrentTime(CMTimeMinimum(time, project.duration))
    }

    private func layoutRuler(totalWidth: CGFloat) {
        let pps = pointsPerSecond
        // Smallest "nice" label interval that keeps labels >= 70pt apart.
        let interval = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { CGFloat($0) * pps >= 70 } ?? 600
        let totalSeconds = Int(ceil(project.duration.seconds))
        var second = 0
        while second <= max(totalSeconds, 0) {
            let x = CGFloat(second) * pps
            let label = UILabel()
            label.text = EditorTimelineView.format(seconds: Double(second))
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = UIColor(white: 0.6, alpha: 1)
            label.sizeToFit()
            label.center = CGPoint(x: x, y: EditorTimelineView.rulerHeight / 2)
            add(label)

            let dotX = x + CGFloat(interval) * pps / 2
            if dotX < totalWidth {
                let dot = UIView(frame: CGRect(x: dotX - 1.5, y: EditorTimelineView.rulerHeight / 2 - 1.5,
                                               width: 3, height: 3))
                dot.backgroundColor = UIColor(white: 0.5, alpha: 1)
                dot.layer.cornerRadius = 1.5
                add(dot)
            }
            second += interval
        }
    }

    private func add(_ view: UIView) {
        scrollView.addSubview(view)
        contentViews.append(view)
    }

    private func makeAddButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("+  " + title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        button.backgroundColor = UIColor(white: 0.17, alpha: 1)
        button.layer.cornerRadius = 4
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func updateSelectionHighlight() {
        for (id, view) in clipViews {
            view.isSelectedClip = (selection == .clip(id))
        }
        audioView?.layer.borderWidth = selection == .audio ? 2 : 0
        audioView?.layer.borderColor = UIColor.white.cgColor
    }

    static func format(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Interaction

    @objc private func addEndingTapped() { delegate?.timelineDidTapAddEnding() }
    @objc private func addAudioTapped() { delegate?.timelineDidTapAddAudio() }

    // Buttons inside the scroll view handle their own taps.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return !(touch.view is UIControl)
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: scrollView)
        var newSelection: Selection?
        if let audioView = audioView, audioView.frame.contains(point) {
            newSelection = .audio
        } else if let (id, _) = clipViews.first(where: { $0.value.frame.contains(point) }) {
            newSelection = .clip(id)
        }
        // Tapping the selected item again deselects it.
        selection = (newSelection == selection) ? nil : newSelection
        delegate?.timelineDidChangeSelection(selection)
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchStartPointsPerSecond = pointsPerSecond
        case .changed:
            let time = currentTime
            pointsPerSecond = min(240, max(4, pinchStartPointsPerSecond * pinch.scale))
            relayout(keeping: time)
        default:
            break
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSettingOffset, scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        delegate?.timelineDidScrub(to: currentTime)
    }
}

// One clip on the timeline: thumbnails tiled across its width (or the logo, for
// the ending card) with a white border while selected.
final class EditorClipStripView: UIView {
    var isSelectedClip = false {
        didSet {
            layer.borderWidth = isSelectedClip ? 2.5 : 0
            layer.borderColor = UIColor.white.cgColor
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 3
        backgroundColor = UIColor(white: 0.12, alpha: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with clip: EditorClip, pointsPerSecond: CGFloat, thumbnails: EditorThumbnailCache) {
        if clip.isEnding {
            backgroundColor = UIColor(red: 0x0E / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0, alpha: 1)
            let logo = UIImageView(image: UIImage(named: "GameShutterWatermark"))
            logo.contentMode = .scaleAspectFit
            logo.frame = bounds.insetBy(dx: 8, dy: 12)
            addSubview(logo)
            return
        }
        guard let track = clip.asset.tracks(withMediaType: .video).first else { return }
        let upright = EditorCompositionBuilder.uprightSize(of: track)
        let tileWidth = upright.height > 0 ? bounds.height * upright.width / upright.height : bounds.height
        guard tileWidth > 0 else { return }
        let tileCount = Int(ceil(bounds.width / tileWidth))
        for i in 0..<tileCount {
            let imageView = UIImageView(frame: CGRect(x: CGFloat(i) * tileWidth, y: 0,
                                                      width: tileWidth, height: bounds.height))
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            addSubview(imageView)
            let offsetSeconds = Double((CGFloat(i) + 0.5) * tileWidth / pointsPerSecond)
            let time = CMTimeMinimum(CMTimeAdd(clip.timeRange.start, CMTime(seconds: offsetSeconds, preferredTimescale: 600)),
                                     CMTimeRangeGetEnd(clip.timeRange))
            thumbnails.image(for: clip.asset, at: time, height: bounds.height, into: imageView)
        }
    }
}

// Thumbnail generation + caching, shared by every strip. Times are bucketed to
// half-seconds so re-layouts (zoom, split, undo) mostly hit the cache.
final class EditorThumbnailCache {
    private let cache = NSCache<NSString, UIImage>()
    private var generators: [URL: AVAssetImageGenerator] = [:]

    func image(for asset: AVURLAsset, at time: CMTime, height: CGFloat, into imageView: UIImageView) {
        let bucket = (time.seconds * 2).rounded()
        let key = "\(asset.url.path)#\(bucket)" as NSString
        imageView.accessibilityIdentifier = key as String
        if let cached = cache.object(forKey: key) {
            imageView.image = cached
            return
        }
        let generator = generators[asset.url] ?? {
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: height * 4, height: height * 2)
            g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
            g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            generators[asset.url] = g
            return g
        }()
        let bucketTime = CMTime(seconds: bucket / 2, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: bucketTime)]) { [weak self] _, cgImage, _, _, _ in
            guard let cgImage = cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                self?.cache.setObject(image, forKey: key)
                // The view may have been reused for a different tile meanwhile.
                if imageView.accessibilityIdentifier == key as String {
                    imageView.image = image
                }
            }
        }
    }
}
