//
//  PhotosAlbumSaver.swift
//  GameShutter
//

import Foundation
import Photos

// Saves videos into Photos — either into GameShutter (folder) › yyyy_MM_dd
// (album), creating the folder and/or album the first time they're needed
// (Photos only nests albums inside folders, PHCollectionList, not inside other
// albums), or straight into the library with no album.
enum PhotosAlbumSaver {
    private static let dateAlbumFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Constants.PhotosAlbums.DateAlbumFormat
        return formatter
    }()

    // Serializes saves: each one looks up (and, if missing, creates) the
    // folder/album synchronously here, so videos saved concurrently can't each
    // decide the album doesn't exist yet and create duplicates.
    private static let saveQueue = DispatchQueue(label: Constants.QueueLabels.PhotosSaveQueue)

    static func todayAlbumName() -> String {
        return dateAlbumFormatter.string(from: Date())
    }

    // `albumName` nil saves to the library only (no album) — the editor's
    // exports; highlight clips pass their date album.
    // `creationDate` overrides the asset's date in Photos (what the editor's
    // folder view sorts by); nil means "now".
    // `completion` runs on the main thread with the new asset's localIdentifier
    // on success (what Instagram's library URL needs), or the error.
    // Caller must already hold Photos read/write authorization.
    static func save(videoURL: URL, albumName: String?, deleteAfterSave: Bool, creationDate: Date? = nil,
                     completion: ((_ localIdentifier: String?, _ error: Error?) -> Void)? = nil) {
        saveQueue.async {
            let folder = albumName == nil ? nil : fetchTopLevelFolder(named: Constants.PhotosAlbums.FolderName)
            let album = albumName.flatMap { name in folder.flatMap { fetchAlbum(named: name, in: $0) } }
            var saveError: Error?
            var localIdentifier: String?
            do {
                try PHPhotoLibrary.shared().performChangesAndWait {
                    guard let creationRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL),
                          let assetPlaceholder = creationRequest.placeholderForCreatedAsset else { return }
                    localIdentifier = assetPlaceholder.localIdentifier
                    if let creationDate = creationDate {
                        creationRequest.creationDate = creationDate
                    }
                    guard let albumName = albumName else { return }
                    if let album = album {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([assetPlaceholder] as NSArray)
                        return
                    }
                    let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    albumRequest.addAssets([assetPlaceholder] as NSArray)
                    let albumPlaceholder = [albumRequest.placeholderForCreatedAssetCollection] as NSArray
                    if let folder = folder {
                        PHCollectionListChangeRequest(for: folder)?.addChildCollections(albumPlaceholder)
                    } else {
                        PHCollectionListChangeRequest
                            .creationRequestForCollectionList(withTitle: Constants.PhotosAlbums.FolderName)
                            .addChildCollections(albumPlaceholder)
                    }
                }
                print("video saved to " + (albumName.map { "\(Constants.PhotosAlbums.FolderName)/\($0)" } ?? "Photos library"))
            } catch {
                print("Video did not save to photo library, reason- \(error.localizedDescription)")
                saveError = error
            }
            if deleteAfterSave {
                try? FileManager.default.removeItem(at: videoURL)
            }
            if let completion = completion {
                DispatchQueue.main.async { completion(saveError == nil ? localIdentifier : nil, saveError) }
            }
        }
    }

    // Every album in the GameShutter folder (none if the folder doesn't exist yet).
    static func dateAlbums() -> [PHAssetCollection] {
        guard let folder = fetchTopLevelFolder(named: Constants.PhotosAlbums.FolderName) else { return [] }
        var albums: [PHAssetCollection] = []
        PHCollection.fetchCollections(in: folder, options: nil).enumerateObjects { collection, _, _ in
            if let album = collection as? PHAssetCollection {
                albums.append(album)
            }
        }
        return albums
    }

    private static func fetchTopLevelFolder(named title: String) -> PHCollectionList? {
        var match: PHCollectionList?
        PHCollectionList.fetchTopLevelUserCollections(with: nil).enumerateObjects { collection, _, stop in
            if let folder = collection as? PHCollectionList, folder.localizedTitle == title {
                match = folder
                stop.pointee = true
            }
        }
        return match
    }

    private static func fetchAlbum(named title: String, in folder: PHCollectionList) -> PHAssetCollection? {
        var match: PHAssetCollection?
        PHCollection.fetchCollections(in: folder, options: nil).enumerateObjects { collection, _, stop in
            if let album = collection as? PHAssetCollection, album.localizedTitle == title {
                match = album
                stop.pointee = true
            }
        }
        return match
    }
}
