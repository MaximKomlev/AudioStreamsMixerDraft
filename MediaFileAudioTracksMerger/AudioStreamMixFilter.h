//
//  AudioStreamMixFilter.h
//  MediaFileAudioTracksMerger
//
//  Created by Maxim Komlev on 1/13/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#ifndef AudioStreamMixFilter_h
#define AudioStreamMixFilter_h

#import <libavformat/avformat.h>
#import <libavfilter/avfilter.h>
#import <libavfilter/buffersink.h>
#import <libavfilter/buffersrc.h>

#include "libavutil/channel_layout.h"
#include "libavutil/opt.h"
#include "libavutil/samplefmt.h"

@interface AVCodecParametersWrap: NSObject

- (id _Nonnull)initWithCodecParameters:(AVCodecParameters *_Nonnull)params;

@property (nonatomic, nonnull) AVCodecParameters *codecParams;

@end

@interface AudioStreamMixFilter: NSObject

- (id _Nonnull)init;

- (int)initializeWithCodecParams:(NSDictionary<NSNumber *, AVCodecParametersWrap *> *_Nonnull)params;

- (int)filterFrame:(AVFrame *_Nonnull)frame forStreamIndex:(NSNumber *_Nonnull)index;
- (AVFrame *_Nullable)getFilteredFrameForStreamIndex:(NSNumber *_Nonnull)index errorCode:(int *_Nullable)error;

- (void)deInitialize;

@end

#endif /* AudioStreamMixFilter_h */
