# GameShutter

Record the whole game, tap once for the highlight, and post the clip before you leave the gym.

GameShutter is an iPad-first sports camera. It records full games, cuts highlight clips with a single tap, sorts them into Photos albums by day, and includes a simple editor for turning them into a video to share.

## Features

- **One-tap highlights.** Tap the highlight button the moment something happens. Each tap becomes a 10-second clip ending just after that moment, and a badge counts the highlights captured so far.
- **Organized automatically.** Highlight clips are saved to Photos under **GameShutter › yyyy_MM_dd**, one album per day, in the order they happened.
- **Keep or discard the full game.** When you stop, choose whether to save the full recording. Highlights are saved either way.
- **Pause and resume** without gaps in the recording.
- **Pinch to zoom**, and switch between front and back cameras (using the ultra-wide and triple cameras where available).
- **Watermark.** Recordings and the clips cut from them carry the GameShutter logo.
- **Highlight editor** (iOS 13+):
  - Pick a day's album to load its clips onto the timeline in order, or start a blank project.
  - Add more clips from Photos, split clips, delete pieces, and undo or redo any step.
  - Add background music.
  - Add an optional GameShutter ending card.
  - Export at 720p, 1080p or 4K.
  - Delete old highlight albums from the album browser.
- **Share.** Exported videos go straight into Photos, then open in Instagram with the video preselected, or go to any other app through the share sheet (Messages, AirDrop, TikTok, WhatsApp…).

## Requirements

- iPadOS / iOS 12.4 or later. The editor needs iOS 13 or later.
- Designed for iPad and runs on iPhone. The camera screen is landscape; the editor follows how the device is held.
- Camera, microphone and Photos access.
- Xcode with the iOS SDK to build. The project has no third-party dependencies.

## Building

Open `GameShutter.xcodeproj` in Xcode, choose a connected device, and run. From the command line:

```bash
# Device build
xcodebuild build -project GameShutter.xcodeproj -scheme GameShutter -destination 'generic/platform=iOS'

# Simulator build (compiles, but the simulator has no usable camera)
xcodebuild build -project GameShutter.xcodeproj -scheme GameShutter -destination 'generic/platform=iOS Simulator'
```

Recording, highlight export and saving to Photos need a real device.

## Project layout

| Path | What it is |
|---|---|
| `GameShutter/CameraViewController.swift` | The main camera screen: record, pause, highlight, zoom |
| `GameShutter/videoManager.swift` | Capture session, watermarking, recording, highlight export |
| `GameShutter/VideoWriter.swift` | `AVAssetWriter` wrapper that writes the recording |
| `GameShutter/PhotosAlbumSaver.swift` | Saves videos into Photos and manages the GameShutter albums |
| `GameShutter/HighlightFoldersViewController.swift` | Album browser that opens the editor |
| `GameShutter/VideoEditorViewController.swift` | Editor screen, export and sharing |
| `GameShutter/EditorComposition.swift` | Editor model and video composition |
| `GameShutter/EditorTimelineView.swift` | Scrollable, zoomable editor timeline |
| `Tools/` | Scripts that generate the app icon and watermark images (not part of the app) |

## Privacy

GameShutter uses the camera, microphone and Photos only to record and save videos on your device. It collects no data and sends nothing to a server. Videos you share go to the app you choose, under that app's own terms.
