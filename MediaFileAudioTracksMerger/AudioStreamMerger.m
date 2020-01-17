//
// AudioStreamMerger.m
// Created on 1/3/20
//
//  Created by Maxim Komlev on 1/9/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#import <Foundation/Foundation.h>

// ffmpeg
#import <libavformat/avformat.h>
#import <libavutil/timestamp.h>
#import <libavfilter/avfilter.h>
#import <libavfilter/buffersink.h>
#import <libavfilter/buffersrc.h>

#include "libavutil/opt.h"
#include "libavutil/samplefmt.h"

// arlo
#import "common.h"
#import "AudioStreamMerger.h"
#import "AudioStreamResampler.h"
#import "AudioStreamMixFilter.h"

struct interrupt_cb_context {
    const AudioStreamMerger *merger;
};

static int interrupt_cb(void *opaque) {
    struct interrupt_cb_context *ctx = (struct interrupt_cb_context *)opaque;
    return ctx->merger.isStopped ? 1 : 0;
}

@interface StreamContext: NSObject

@property (nonatomic, nullable) AVCodecParameters *codecParams;
@property (nonatomic, nullable) AVCodecContext *audioDecContext;

@end

@implementation StreamContext
@end

@interface StreamContextContainer: NSObject

- (void)addCodecParameters:(AVCodecParameters *)codecParams forIndex:(NSNumber *_Nonnull)index;
- (AVCodecParameters *_Nullable)getCodecParametersForIndex:(NSNumber *_Nonnull)index;
- (void)addCodecContext:(AVCodecContext *)codecContext forIndex:(NSNumber *_Nonnull)index;
- (AVCodecContext *_Nullable)getCodecContextForIndex:(NSNumber *_Nonnull)index;

- (void)enumerateKeysAndObjectsUsingBlock:(void (NS_NOESCAPE ^)(NSNumber *key, StreamContext *context, BOOL *stop))block;

@property (nonatomic, nullable) AVCodecContext *audioEncContext;

- (NSUInteger)contextsCount;

- (void)deInitialize;

@end

@implementation StreamContextContainer {
    NSMutableDictionary<NSNumber *, StreamContext *> *_contexts;
    
    NSLock *_locker;
}

- (id)init {
    if (self = [super init]) {
        _contexts = [NSMutableDictionary new];
        _locker = [NSLock new];
    }
    return self;
}

- (void)addCodecParameters:(AVCodecParameters *)codecParams forIndex:(NSNumber *_Nonnull)index {
    [self synchronize:^{
        StreamContext *context = [self retrieveStreamContextFor:index];
        context.codecParams = codecParams;
    }];
}

- (AVCodecParameters *_Nullable)getCodecParametersForIndex:(NSNumber *_Nonnull)index {
    __block AVCodecParameters *codecParams = NULL;
    [self synchronize:^{
        codecParams = self->_contexts[index].codecParams;
    }];
    return codecParams;
}

- (void)addCodecContext:(AVCodecContext *)codecContext forIndex:(NSNumber *_Nonnull)index {
    [self synchronize:^{
        StreamContext *context = [self retrieveStreamContextFor:index];
        context.audioDecContext = codecContext;
    }];
}

- (AVCodecContext *_Nullable)getCodecContextForIndex:(NSNumber *)index {
    __block AVCodecContext *codecContext = NULL;
    [self synchronize:^{
        codecContext = self->_contexts[index].audioDecContext;
    }];
    return codecContext;
}

- (void)deInitialize {
    [self synchronize:^{
        for (NSNumber* key in self->_contexts) {
            AVCodecContext *ctx = self->_contexts[key].audioDecContext;
            if (ctx) {
                avcodec_free_context(&ctx);
            }
            self->_contexts[key].audioDecContext = NULL;
            self->_contexts[key].codecParams = NULL;
        }
        
        if (self->_audioEncContext) {
            avcodec_free_context(&(self->_audioEncContext));
        }
        
        [self->_contexts removeAllObjects];
    }];
}

- (void)enumerateKeysAndObjectsUsingBlock:(void (NS_NOESCAPE ^)(NSNumber *key, StreamContext *context, BOOL *stop))block {
    [self synchronize:^{
        [self->_contexts enumerateKeysAndObjectsUsingBlock:block];
    }];
}

- (NSUInteger)contextsCount {
    __block NSUInteger count = 0;
    [self synchronize:^{
        count = self->_contexts.count;
    }];
    return count;
}

#pragma mark - Helpers

- (StreamContext *_Nonnull)retrieveStreamContextFor:(NSNumber *)index {
    if (!_contexts[index]) {
        _contexts[index] = [[StreamContext alloc] init];
    }
    return _contexts[index];
}

- (void)synchronize:(dispatch_block_t)block {
    [_locker lock]; {
        block();
    }
    [_locker unlock];
}

@end

// ffmpeg -i multitrack.mp4 -filter_complex "[0:1][0:2] amix=inputs=2" -c:v copy -c:a aac output2.mp4

@implementation AudioStreamMerger {
    NSURL *_sessionUrl;
    NSDictionary<NSString *, NSString *> *_options;

    NSLock *_locker;
    dispatch_queue_t _queue;
    
    AVFormatContext *ofmt_ctx;
    AVFormatContext *ifmt_ctx;
    
    StreamContextContainer *_streamContexts;
    
    AudioStreamResamplers *_resamplers;
    AudioStreamMixFilter *_filterGraph;
}

@synthesize isStopped = _isStopped;

+ (void)ffmpegInitialization {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        av_register_all();
        avfilter_register_all();
        avcodec_register_all();
    });
}

- (id)initWithUrl:(NSURL *)url {
    if (self = [super init]) {
        [AudioStreamMerger ffmpegInitialization];
        
        _isStopped = TRUE;
        _sessionUrl = url;
        _locker = [NSLock new];
        _queue = dispatch_get_main_queue();
        
        _streamContexts = [StreamContextContainer new];
        _filterGraph = [AudioStreamMixFilter new];
        _resamplers = [AudioStreamResamplers new];
    }
    return self;
}

- (id)initWithUrl:(NSURL *_Nonnull)url
      withOptions:(NSDictionary<NSString *, NSString *> *_Nonnull)options {
    if (self = [self initWithUrl:url]) {
        _options = options;
    }
    return self;
}

- (id)initWithUrl:(NSURL *_Nonnull)url
      withOptions:(NSDictionary<NSString *, NSString *> *_Nonnull)options
          onQueue:(dispatch_queue_t)queue {
    if (self = [self initWithUrl:url withOptions:options]) {
        _queue = queue;
    }
    return self;
}

- (void)dealloc {
    NSLog(@"AudioStreamMerger:dealloc");
}

- (void)start {
    self.isStopped = FALSE;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self processing];
    });
}

- (void)stop {
    self.isStopped = TRUE;
}

- (BOOL)isStopped {
    __block BOOL result = FALSE;
    [self synchronize:^{
        result = self->_isStopped;
    }];
    return result;
}

- (void)setIsStopped:(BOOL)isStopped {
    [self synchronize:^{
        self->_isStopped = isStopped;
    }];
}

#pragma mark - Helpers

- (void)processing {
    
//    av_log_set_level(AV_LOG_TRACE);
        
    const char *in_file_path, *out_file_path;
    __block int ret, i;
    
    NSString *homeDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSString *inFileName = [_sessionUrl lastPathComponent];
    NSString *inFileExt = [_sessionUrl pathExtension];
    NSString *outFileName = [inFileName stringByReplacingOccurrencesOfString:inFileExt withString:AV_FILE_FORMAT];
    NSString *outFilePath = [homeDir stringByAppendingPathComponent:outFileName];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:outFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:outFilePath error:nil];
    }

    in_file_path  = [_sessionUrl.absoluteString UTF8String];
    out_file_path = [outFilePath UTF8String];
  
    NSMutableDictionary<NSNumber *, NSNumber *> *outStreamMapping = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, AVCodecParametersWrap *> *codecParams = [NSMutableDictionary new];

    struct interrupt_cb_context *interrupt_ctx = malloc(sizeof(struct interrupt_cb_context));
    interrupt_ctx->merger = self;

    while (TRUE) {
        if ((ret = avformat_open_input(&ifmt_ctx, in_file_path, NULL, NULL)) < 0 || self.isStopped) {
            break;
        }

        if ((ret = avformat_find_stream_info(ifmt_ctx, 0)) < 0 || self.isStopped) {
            break;
        }
        
        av_dump_format(ifmt_ctx, 0, in_file_path, 0);
        if (!(ofmt_ctx = avformat_alloc_context()) || self.isStopped) {
            ret = AVERROR(ENOMEM);
            break;
        }
        
        if ((ret = avformat_alloc_output_context2(&ofmt_ctx, NULL, NULL, out_file_path) < 0) || self.isStopped) {
            break;
        }
        
        ofmt_ctx->interrupt_callback.opaque = interrupt_ctx;
        ofmt_ctx->interrupt_callback.callback = &interrupt_cb;
        ifmt_ctx->interrupt_callback.opaque = interrupt_ctx;
        ifmt_ctx->interrupt_callback.callback = &interrupt_cb;
        
        int out_stream_index = 0;
        
        // initialize in|out codec contexts and streams
        BOOL isAudioAdded = FALSE;
        for (i = 0; i < ifmt_ctx->nb_streams; ++i) {
            AVStream *in_stream = ifmt_ctx->streams[i];
            AVCodecParameters *in_codecpar = in_stream->codecpar;

            if (self.isStopped) {
                break;
            }

            if (in_codecpar->codec_type != AVMEDIA_TYPE_UNKNOWN) {
                NSNumber *inStreamIndex = [NSNumber numberWithInt:i];
                NSNumber *streamType = [NSNumber numberWithInt:in_codecpar->codec_type];

                if (in_codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
                    NSNumber *outStreamIndex = [NSNumber numberWithInt:out_stream_index];
                    outStreamMapping[streamType] = outStreamIndex;
                    if ((ret = [self addNotAudioOutStreamWith:outStreamIndex
                                                inStreamIndex:inStreamIndex]) < 0) {
                        break;
                    }
                    ++out_stream_index;
                } else {
                    [self initializeAudioDecodeContext:in_codecpar
                                         inStreamIndex:inStreamIndex];
                    if (!isAudioAdded) {
                        NSNumber *outStreamIndex = [NSNumber numberWithInt:out_stream_index];
                        outStreamMapping[streamType] = outStreamIndex;
                        isAudioAdded = TRUE;
                        ++out_stream_index;
                    }
                }

            }
        }

        if (ret < 0 || self.isStopped) {
            break;
        }
        
        NSNumber *streamType = [NSNumber numberWithInt:AVMEDIA_TYPE_AUDIO];
        NSNumber *outStreamIndex = outStreamMapping[streamType];
        if ((ret = [self addAudioOutStreamWith:outStreamIndex]) < 0) {
            break;
        }

        // initialize audio frame resamplers
        [_streamContexts enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, StreamContext *context, BOOL *stop) {
            codecParams[key] = [[AVCodecParametersWrap alloc] initWithCodecParameters:context.codecParams];
            AudioStreamResampler *resampler = [[AudioStreamResampler alloc] initWithInFormatContext:ifmt_ctx
                                                                         inCodecContext:context.audioDecContext
                                                                       outFormatContext:ofmt_ctx
                                                                        outCodecContext:_streamContexts.audioEncContext];
            resampler.resamplerId = [NSString stringWithFormat:@"AudioStreamResampler_%d", key.intValue];
            if ((ret = [_resamplers addResampler:resampler forStreamIndex:key]) < 0) {
                *stop = TRUE;
            }
        }];
        
        if (ret < 0) {
            break;
        }
        
        // initialize audio frame filters
        if ((ret = [_filterGraph initializeWithCodecParams:codecParams]) < 0) {
            break;
        }

        if (self.isStopped) {
            break;
        }
        
        if (!(ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
            if ((ret = avio_open(&ofmt_ctx->pb, out_file_path, AVIO_FLAG_WRITE)) < 0) {
                break;
            }
        }

        if ((ret = avformat_write_header(ofmt_ctx, NULL)) < 0) {
            break;
        }

        dispatch_async(_queue, ^{
            [self.delegate didStart:self];
        });

        while (ret == 0 && !self.isStopped) {
            if ((ret = [self processingFor:outStreamMapping]) >= 0) {
                uint64_t currPos = self->ifmt_ctx->pb->pos;
                dispatch_async( _queue, ^{
                    [self.delegate didProcessing:self withProgress:currPos];
                });
            }
        }
        
        if (ret == AVERROR_EOF && !self.isStopped) {
            av_write_trailer(ofmt_ctx);
        }
        
        break;
    }

    [codecParams removeAllObjects];
    [outStreamMapping removeAllObjects];

    [_streamContexts deInitialize];

    [_filterGraph deInitialize];
    
    [_resamplers removeAll];

    interrupt_ctx->merger = NULL;
    free(interrupt_ctx);
    
    if (ifmt_ctx) {
        ifmt_ctx->interrupt_callback.opaque = NULL;
        avformat_close_input(&ifmt_ctx);
        avformat_free_context(ifmt_ctx);
    }

    if (ofmt_ctx) {
        ofmt_ctx->interrupt_callback.opaque = NULL;
        if (ofmt_ctx->oformat &&
            !(ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
            avio_close(ofmt_ctx->pb);
        }
        avformat_free_context(ofmt_ctx);
    }
    ifmt_ctx = NULL;
    ofmt_ctx = NULL;
    //

    if (ret < 0 && ret != AVERROR_EOF) {
        [self errorHandling:ret];
    } else if (self.isStopped) {
        [self errorHandling:AVERROR(AVERROR_EXIT)];
    } else {
        dispatch_async( _queue, ^{
            [self.delegate didStop:self forFilePath:outFilePath];
        });
    }
}

/* Add an output stream. */
- (int)addNotAudioOutStreamWith:(NSNumber *)outStreamIndex
                  inStreamIndex:(NSNumber *)inStreamIndex {
    int ret = 0;
    
    AVStream *in_stream = ifmt_ctx->streams[inStreamIndex.intValue];
    
    AVCodecParameters *in_codecpar = in_stream->codecpar;
    
    AVStream *out_stream = avformat_new_stream(ofmt_ctx, NULL);
    if (!out_stream) {
        return AVERROR(EINVAL);
    }
    
    if ((ret = avcodec_parameters_copy(out_stream->codecpar, in_codecpar)) < 0) {
        return ret;
    }
    out_stream->index = outStreamIndex.intValue;
    out_stream->codecpar->codec_tag = in_stream->codecpar->codec_tag;

    return ret;
}

- (int)addAudioOutStreamWith:(NSNumber *)outStreamIndex {
    int ret = 0;
    
    AVCodec *codec_encode_ptr = avcodec_find_encoder(AAC_CODEC_ID);
    if (!codec_encode_ptr) {
        return AVERROR(EINVAL);
    }

    AVStream *out_stream = avformat_new_stream(ofmt_ctx, codec_encode_ptr);
    if (!out_stream) {
        return AVERROR(EINVAL);
    }

    __block int numChannels = 0;
    NSMutableArray<NSNumber *> *outSampleRates = [NSMutableArray new];
    [_streamContexts enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, StreamContext *context, BOOL *stop) {
        AVCodecContext *codecContext = context.audioDecContext;
        if (codecContext) {
            NSNumber *sampleRate = [NSNumber numberWithInt:codecContext->sample_rate];
            if (![outSampleRates containsObject:sampleRate]) {
                 [outSampleRates addObject:sampleRate];
            }
        }
        
        AVCodecParameters *codecParams = context.codecParams;
        if (codecParams) {
            numChannels += codecParams->channels;
        }
    }];

    uint64_t ch_layout_id = av_get_default_channel_layout(numChannels);
    ch_layout_id = validateChannelLayout(ch_layout_id);

    out_stream->index = outStreamIndex.intValue;
    
    _streamContexts.audioEncContext = avcodec_alloc_context3(codec_encode_ptr);
    _streamContexts.audioEncContext->sample_rate = (outSampleRates.count > 0 ? outSampleRates[0].intValue : AAC_OUTPUT_SAMPLE_RATE);
    _streamContexts.audioEncContext->channel_layout = ch_layout_id;
    _streamContexts.audioEncContext->sample_fmt = codec_encode_ptr->sample_fmts[0];
    _streamContexts.audioEncContext->time_base = (AVRational){1, _streamContexts.audioEncContext->sample_rate};
    _streamContexts.audioEncContext->bit_rate = AAC_OUTPUT_BIT_RATE;
    _streamContexts.audioEncContext->profile = FF_PROFILE_AAC_LOW;//FF_PROFILE_AAC_MAIN
    _streamContexts.audioEncContext->level = FF_LEVEL_UNKNOWN;
    /* Allow the use of the experimental AAC encoder. */
    _streamContexts.audioEncContext->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;
    
    [outSampleRates removeAllObjects];
    
    out_stream->time_base = (AVRational){1, _streamContexts.audioEncContext->sample_rate};

    if (ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
        _streamContexts.audioEncContext->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    if ((ret = avcodec_open2(_streamContexts.audioEncContext, codec_encode_ptr, NULL)) < 0) {
        return ret;
    }
    
    if ((ret = avcodec_parameters_from_context(out_stream->codecpar, _streamContexts.audioEncContext)) < 0) {
        return ret;
    }
    
    return ret;
}

- (int)initializeAudioDecodeContext:(AVCodecParameters *)codecpar
                      inStreamIndex:(NSNumber *)streamIndex {
    int ret = 0;
    
    AVCodec *codec_decode_ptr = avcodec_find_decoder(codecpar->codec_id);
    if (!codec_decode_ptr) {
        return AVERROR(EINVAL);
    }

    AVCodecContext *decode_ctx = avcodec_alloc_context3(codec_decode_ptr);
    if (!decode_ctx) {
        return AVERROR(EINVAL);
    }
    
    if ((ret = avcodec_parameters_to_context(decode_ctx, codecpar) < 0)) {
        return ret;
    }

    if ((ret = avcodec_open2(decode_ctx, codec_decode_ptr, NULL)) < 0) {
        return ret;
    }
    
    [_streamContexts addCodecParameters:codecpar forIndex:streamIndex];
    [_streamContexts addCodecContext:decode_ctx forIndex:streamIndex];

    return ret;
}

- (int)processingFor:(NSMutableDictionary<NSNumber *, NSNumber *> *)outStreamMapping {
    AVPacket pkt;
    
    AVStream *in_stream;
    int ret = av_read_frame(ifmt_ctx, &pkt);
    
    while (ret >= 0 || ret == AVERROR_EOF) {
        int in_stream_index = pkt.stream_index;
        in_stream = ifmt_ctx->streams[in_stream_index];

        NSNumber *inStreamType = [NSNumber numberWithInt:in_stream->codecpar->codec_type]; // get stream type by stream index
        NSNumber *outStreamIndex = outStreamMapping[inStreamType]; // get out stream index by stream type
        NSNumber *inStreamIndex = [NSNumber numberWithInt:in_stream_index];

        if (!outStreamIndex) {
            break;
        }
        
        if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            ret = [self writeAudioPacket:&pkt
                                  isLats:(ret == AVERROR_EOF)
                           inStreamIndex:inStreamIndex
                          outStreamIndex:outStreamIndex];
        } else {
            ret = [self writeVideoPacket:&pkt
                           isLats:(ret == AVERROR_EOF)
                           inStreamIndex:inStreamIndex
                          outStreamIndex:outStreamIndex];
        }
        break;
    }
        
    av_packet_unref(&pkt);

    return ret;
}

- (int)writeAudioPacket:(AVPacket *)packet
                 isLats:(BOOL)isLast
          inStreamIndex:(NSNumber *)inStreamIndex
         outStreamIndex:(NSNumber *)outStreamIndex {
    int ret = 0;

    AVCodecContext *codecContext = [_streamContexts getCodecContextForIndex:inStreamIndex];
    if (codecContext) { // if null then proccess another packet

        AudioStreamResampler *resampler = [_resamplers getResamplerForStreamIndex:inStreamIndex];

        AVFrame *frame = av_frame_alloc();

        int got_frame = 0;
        BOOL resampled = FALSE;
        BOOL canProccess = TRUE;
        
        if (!isLast) {
            ret = decode(codecContext, frame, packet, &got_frame);
        }
        
        if (got_frame || isLast) {
            int retResumpling = [resampler resampleFrame:frame done:&resampled];
            
            av_frame_free(&frame); frame = NULL;
            
            if (retResumpling >= 0) {
                canProccess = resampled;
            }
            while ((canProccess && [resampler isResampledFrame]) || isLast) {
                
                [resampler getResampledFrame:&frame];
                
                if ((ret = [_filterGraph filterFrame:frame forStreamIndex:inStreamIndex]) < 0) {
                    break;
                }

                av_frame_free(&frame); frame = NULL;

                ret = [self writeAudioFilteredFrameTo:ofmt_ctx
                             inStreamIndex:inStreamIndex
                            outStreamIndex:outStreamIndex];
                
                if (!frame && isLast) {
                    break;
                }
            }
        }

        av_frame_free(&frame);
    }
    
    return isLast ? AVERROR_EOF : ret;
}

- (int)writeVideoPacket:(AVPacket *)packet
                 isLats:(BOOL)isLast
           inStreamIndex:(NSNumber *)inStreamIndex
          outStreamIndex:(NSNumber *)outStreamIndex {
    int ret = isLast ? AVERROR_EOF : 0;
    if (!isLast) {
        packet->stream_index = outStreamIndex.intValue;

        av_packet_rescale_ts(packet,
                             ifmt_ctx->streams[inStreamIndex.intValue]->time_base,
                             ofmt_ctx->streams[outStreamIndex.intValue]->time_base);
        
        ret = av_interleaved_write_frame(ofmt_ctx, packet);
    }
    return ret;
}

- (int)writeAudioFilteredFrameTo:(AVFormatContext *)ofmt_ctx
              inStreamIndex:(NSNumber *)inStreamIndex
             outStreamIndex:(NSNumber *)outStreamIndex {
    
    AVFrame *frame = NULL;
    int ret = 0;
    
    while (TRUE) {
        frame = [_filterGraph getFilteredFrameForStreamIndex:inStreamIndex errorCode:&ret];
        if (!frame) {
            break;
        }
            
        AVPacket pkt; av_init_packet(&pkt);
        
        int got_output = 0;
        if ((ret = encode(_streamContexts.audioEncContext, &pkt, frame, &got_output)) >= 0 && got_output) {
            pkt.stream_index = outStreamIndex.intValue;
            ret = av_write_frame(ofmt_ctx, &pkt);
        }
        
        av_packet_unref(&pkt);
        
        break;
    }
    
    av_frame_free(&frame);

    return ret;
}

- (void)errorHandling:(int)errorNum {
    char *cErrDesc = av_err2str(errorNum);
    NSString *in_file_path  = _sessionUrl.absoluteString;
    NSString *errDesc = [NSString stringWithFormat:@"File '%@' processing error: %s", in_file_path, cErrDesc];
    NSLog(@"AudioStreamMerger:processing, %@", errDesc);
    dispatch_async( _queue, ^{
        NSDictionary* details = @{NSLocalizedDescriptionKey: errDesc};
        NSError *err = [NSError errorWithDomain:@"AudioStreamMerger" code:errorNum userInfo:details];
        [self.delegate didError:self error:err];
    });
}

#pragma mark - Helpers (Sync)

- (void)synchronize:(dispatch_block_t)block {
    [_locker lock]; {
        block();
    }
    [_locker unlock];
}

@end
