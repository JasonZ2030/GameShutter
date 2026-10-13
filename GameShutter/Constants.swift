//
//  Constants.swift
//  GameShutter
//
//  Created by Jason Zhang on 3/14/18.
//

struct Constants {
    struct AlertTitles {
        static let CameraAccess = "Camera Access"
        static let MicrophoneAccess = "Microphone Access"
    }
    
    struct AlertMessages {
        static let CameraAccess = "This app does not have access to your Camera. To enable press OK and switch Camera on."
        static let MicrophoneAccess = "This app does not have access to your Microphone. To enable press OK and switch Microphone on."
    }
    
    struct AlertActionTitles {
        static let Ok = "OK"
        static let Cancel = "Cancel"
    }
    
    struct CIEffectKeys {
        static let InputAmountKey = "inputAmount"
        static let InputHighlightAmount = "inputHighlightAmount"
        static let InputShadowAmount = "inputShadowAmount"
    }
    
    struct QueueLabels {
        static let VideoSessionQueue = "video_capture_session_queue"
        static let AudioSessionQueue = "audio_capture_session_queue"
        static let PhotosSaveQueue = "photos_save_queue"
    }

    struct PhotosAlbums {
        // Highlight clips are saved to Photos as <FolderName> (folder) › yyyy_MM_dd (album).
        static let FolderName = "GameShutter"
        static let DateAlbumFormat = "yyyy_MM_dd"
    }
}
