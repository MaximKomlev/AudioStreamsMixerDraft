//
//  AudioStreamMerger.swift
//  MediaFileAudioTracksMerger
//
//  Created by Maxim Komlev on 1/21/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

import Foundation

private class StreamContext {
    var codecParams: AVCodecParameters?
    var codecContext: AVCodecContext?
    
    init(codecParams: AVCodecParameters, codecContext: AVCodecContext) {
        self.codecParams = codecParams
        self.codecContext = codecContext
    }
}

private class StreamContextContainerSwift {
    
}

class AudioStreamMergerSwift {
    
}
