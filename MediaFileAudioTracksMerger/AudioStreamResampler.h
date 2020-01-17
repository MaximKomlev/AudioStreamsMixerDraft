//
// AudioStreamResampler.h
// Created on 1/3/20
//
//  Created by Maxim Komlev on 1/9/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#ifndef AudioStreamResampler_h
#define AudioStreamResampler_h

#import <libavformat/avformat.h>

@class AudioStreamResampler;

@interface AudioStreamResamplers: NSObject

- (id _Nonnull)init;

- (int)addResampler:(AudioStreamResampler *_Nonnull)resampler forStreamIndex:(NSNumber *_Nonnull)index;
- (AudioStreamResampler *_Nullable)getResamplerForStreamIndex:(NSNumber *_Nonnull)index;

- (void)removeAll;

@end

@interface AudioStreamResampler: NSObject

- (id _Nullable)initWithInFormatContext:(AVFormatContext *_Nonnull)in_format_context
                         inCodecContext:(AVCodecContext *_Nonnull)in_codec_context
                       outFormatContext:(AVFormatContext *_Nonnull)out_format_context
                        outCodecContext:(AVCodecContext *_Nonnull)out_codec_context;

- (int)resampleFrame:(AVFrame *_Nonnull)frame done:(BOOL *_Nonnull)done;
- (int)getResampledFrame:(AVFrame *_Nonnull*_Nullable)frame;
- (BOOL)isResampledFrame;

@property (nonnull) NSString *resamplerId;

@end

#endif /* AudioStreamResampler_h */
