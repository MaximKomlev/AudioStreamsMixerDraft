//
// AudioStreamResampler.h
// Created on 1/3/20
//
//  Created by Maxim Komlev on 1/9/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#import <Foundation/Foundation.h>

//ffmpeg
#include "libavutil/audio_fifo.h"
#include "libavutil/avassert.h"
#include "libavutil/avstring.h"
#include "libavutil/frame.h"
#include "libavutil/opt.h"
#include "libswresample/swresample.h"

#import "AudioStreamResampler.h"

@implementation AudioStreamResamplers {
    NSLock *_locker;
    NSMutableDictionary<NSNumber *, AudioStreamResampler *> *_resamplers;
}

- (id _Nonnull)init {
    if (self = [super init]) {
        _locker = [NSLock new];
        _resamplers = [NSMutableDictionary new];
    }
    return self;
}

- (int)addResampler:(AudioStreamResampler *_Nonnull)resampler forStreamIndex:(NSNumber *_Nonnull)index {
    __block int ret = 0;
    [self synchronize:^{
        AudioStreamResampler *oldResampler = self->_resamplers[index];
        if (oldResampler) {
            ret = AVERROR(EEXIST);
        } else {
            self->_resamplers[index] = resampler;
        }
    }];
    return ret;
}

- (AudioStreamResampler *_Nullable)getResamplerForStreamIndex:(NSNumber *_Nonnull)index {
    __block AudioStreamResampler *result = 0;
    [self synchronize:^{
        result = self->_resamplers[index];
    }];
    return result;
}

- (void)removeAll {
    [self synchronize:^{
        [self->_resamplers removeAllObjects];
    }];
}

#pragma mark - Helpers

- (void)synchronize:(dispatch_block_t)block {
    [_locker lock]; {
        block();
    }
    [_locker unlock];
}

@end

@implementation AudioStreamResampler {
    AVFormatContext *_in_format_context;
    AVCodecContext *_in_codec_context;
    AVFormatContext *_out_format_context;
    AVCodecContext *_out_codec_context;
    
    SwrContext *_resampler_context;
    AVAudioFifo *_fifo;
    
    int64_t _pts;
}

- (id _Nullable)initWithInFormatContext:(AVFormatContext *_Nonnull)in_format_context
                         inCodecContext:(AVCodecContext *_Nonnull)in_codec_context
                       outFormatContext:(AVFormatContext *_Nonnull)out_format_context
                        outCodecContext:(AVCodecContext *_Nonnull)out_codec_context {
    if (self = [super init]) {
        _in_format_context = in_format_context;
        _in_codec_context = in_codec_context;
        _out_format_context = out_format_context;
        _out_codec_context = out_codec_context;
        
        if ([self initResampler] < 0 || [self initIOBuffer] < 0) {
            return NULL;
        }
        
        _resamplerId = [NSString stringWithFormat:@"AudioStreamResampler_%d", (int)self];
        
        _pts = 0;
    }
    return self;
}

- (void)dealloc {
    if (_resampler_context) {
        swr_free(&_resampler_context);
    }
    
    if (_fifo) {
        av_audio_fifo_free(_fifo);
    }
}

- (int)resampleFrame:(AVFrame *_Nonnull)frame done:(BOOL *)done {
    uint8_t **converted_input_samples = NULL;
    int ret = 0;

    int in_frame_size = frame->nb_samples;
    /* compute the number of converted samples: buffering is avoided
    * ensuring that the output buffer will contain at least all the
    * converted input samples
    */
    int64_t out_nb_samples = av_rescale_rnd(in_frame_size, _out_codec_context->sample_rate, _in_codec_context->sample_rate, AV_ROUND_UP);

    while (TRUE) {
        /* Initialize the temporary storage for the converted input samples. */
        if ((ret = [self initConvertedSamples:&converted_input_samples
                                in_frame_size:in_frame_size
                               out_frame_size:(int)out_nb_samples]) < 0) {
            return ret;
        }

        if ((ret = [self convertSamples:(const uint8_t**)frame->extended_data
                         converted_data:converted_input_samples
                          in_frame_size:in_frame_size
                         out_frame_size:(int)out_nb_samples]) < 0) {
            break;
        }

        if ((ret = [self addSamplesToFifo:converted_input_samples
                               frame_size:(int)out_nb_samples]) < 0) {
            break;
        }
        break;
    }
    
    if (converted_input_samples) {
        av_freep(&converted_input_samples[0]);
        free(converted_input_samples);
    }

    *done = (av_audio_fifo_size(_fifo) >= _out_codec_context->frame_size);
    
    return ret;
}

- (int)getResampledFrame:(AVFrame *_Nonnull*_Nullable)frame {
    AVFrame *output_frame;
    int ret = 0;

    const int frame_size = FFMIN(av_audio_fifo_size(_fifo), _out_codec_context->frame_size);

    if (!(output_frame = av_frame_alloc())) {
        return AVERROR_EXIT;
    }
    output_frame->nb_samples = frame_size;
    output_frame->channel_layout = _out_codec_context->channel_layout;
    output_frame->format = _out_codec_context->sample_fmt;
    output_frame->sample_rate = _out_codec_context->sample_rate;

    if ((ret = av_frame_get_buffer(output_frame, 0)) < 0) {
        av_frame_free(&output_frame);
        return ret;
    }

    if (av_audio_fifo_read(_fifo, (void **)output_frame->data, frame_size) < frame_size) {
        av_frame_free(&output_frame);
        return AVERROR_EXIT;
    }
    
    if (output_frame) {
         output_frame->pts = _pts;
         _pts += output_frame->nb_samples;
    }

    *frame = output_frame;
    
    return 0;
}

- (BOOL)isResampledFrame {
    return av_audio_fifo_size(_fifo) >= _out_codec_context->frame_size;
}

#pragma mark - Helpers

- (int)initResampler {
    int ret;
    _resampler_context = swr_alloc_set_opts(NULL,
                                          av_get_default_channel_layout(_out_codec_context->channels),
                                          _out_codec_context->sample_fmt,
                                          _out_codec_context->sample_rate,
                                          av_get_default_channel_layout(_in_codec_context->channels),
                                          _in_codec_context->sample_fmt,
                                          _in_codec_context->sample_rate,
                                          0, NULL);
    if (!_resampler_context) {
        return AVERROR(ENOMEM);
    }

    av_opt_set_int(_resampler_context, "in_sample_rate",     _in_codec_context->sample_rate, 0);
    av_opt_set_int(_resampler_context, "out_sample_rate",    _out_codec_context->sample_rate, 0);

    if ((ret = swr_init(_resampler_context)) < 0) {
        swr_free(&_resampler_context);
        return ret;
    }
    return 0;
}

- (int)initIOBuffer {
    if (!(_fifo = av_audio_fifo_alloc(_out_codec_context->sample_fmt,
                                      _out_codec_context->channels, 1))) {
        return AVERROR(ENOMEM);
    }
    return 0;
}

- (int)initConvertedSamples:(uint8_t ***)converted_input_samples
              in_frame_size:(int)in_frame_size
             out_frame_size:(int)out_frame_size {
    int ret;
    if (!(*converted_input_samples = calloc(_out_codec_context->channels,
                                            sizeof(**converted_input_samples)))) {
        return AVERROR(ENOMEM);
    }

    if ((ret = av_samples_alloc(*converted_input_samples, NULL,
                                  _out_codec_context->channels,
                                  out_frame_size,
                                  _out_codec_context->sample_fmt, 0)) < 0) {
        return ret;
    }
    return 0;
}

- (int)convertSamples:(const uint8_t **)input_data
       converted_data:(uint8_t **)converted_data
        in_frame_size:(int)in_frame_size
       out_frame_size:(int)out_frame_size {
    int ret = 0;
    ret = swr_convert(_resampler_context, converted_data, out_frame_size, input_data, in_frame_size);
    return ret;
}

- (int)addSamplesToFifo:(uint8_t **)converted_input_samples
             frame_size:(int)frame_size {
    int ret;

    if ((ret = av_audio_fifo_realloc(_fifo, av_audio_fifo_size(_fifo) + frame_size)) < 0) {
        return ret;
    }

    if (av_audio_fifo_write(_fifo, (void **)converted_input_samples, frame_size) < frame_size) {
        return AVERROR_EXIT;
    }
    
    return 0;
}

@end
