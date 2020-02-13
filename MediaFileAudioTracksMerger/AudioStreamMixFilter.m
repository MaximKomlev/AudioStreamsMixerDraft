//
//  AudioStreamMixFilter.m
//  MediaFileAudioTracksMerger
//
//  Created by Maxim Komlev on 1/13/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "common.h"
#import "AudioStreamMixFilter.h"

@interface AVFilterContextWrap: NSObject

- (id _Nonnull)initWithFilterContext:(AVFilterContext *_Nonnull)filter;

@property (nonatomic, nonnull) AVFilterContext *filter;

@end

@implementation AVFilterContextWrap

- (id)initWithFilterContext:(AVFilterContext *_Nonnull)filter {
    if (self = [super init]) {
        _filter = filter;
    }
    return self;
}

@end

@implementation AVCodecParametersWrap

- (id)initWithCodecParameters:(AVCodecParameters *_Nonnull)params {
    if (self = [super init]) {
        _codecParams = params;
    }
    return self;
}

@end

@implementation AudioStreamMixFilter {
    AVFilterContext *_filterSink;
    AVFilterGraph *_graph;

    NSLock *_locker;
    NSMutableDictionary<NSNumber *, AVFilterContextWrap *> *_filtersSrcs;
}

- (id)init {
    if (self = [super init]) {
        _locker = [NSLock new];
        _filtersSrcs = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc {
    NSLog(@"AudioStreamMixFilter:dealloc");
}

- (int)initializeWithCodecParams:(NSDictionary<NSNumber *, AVCodecParametersWrap *> *_Nonnull)params
              forOutCodecContext:(AVCodecContext *_Nonnull)codecContext {
    __block int ret = 0;
    
    AVFilterGraph *filter_graph = NULL;
    
    AVFilterContext *amerge_ctx;
    const AVFilter  *amerge;

    AVFilterContext *aformat_ctx;
    const AVFilter  *aformat;

    AVFilterContext *abuffersink_ctx = NULL;
    const AVFilter  *abuffersink;

    [self synchronize:^{
        ret = (self->_graph) ? AVERROR(EEXIST) : 0;
    }];

    if (ret < 0) {
        return ret;
    }
    
    /* Create a new filtergraph, which will contain all the filters. */
    filter_graph = avfilter_graph_alloc();
    if (!filter_graph) {
        return AVERROR(ENOMEM);
    }
    
    while (TRUE) {
        int numChannels = 0;
        for (NSNumber *key in params) {
            AVCodecParameters *codecParams = params[key].codecParams;
            if (codecParams) {
                numChannels += codecParams->channels;
            }
        }

        uint64_t ch_layout_id = av_get_default_channel_layout(numChannels);
        ch_layout_id = validateChannelLayout(ch_layout_id);
        const char *ch_layout = [[NSString stringWithFormat:@"%lld", ch_layout_id] UTF8String];

        /* Create the abuffer(s) filter;
        * it will be used for feeding the data into the graph. */
        enum AVSampleFormat sample_fmt = AAC_SAMPLE_FMT;
        NSMutableArray<NSNumber *> *outSampleRates = [NSMutableArray new];
        __block int i = 0;
        for (NSNumber *key in params) {
            AVCodecParameters *codecParams = params[key].codecParams;
            if (codecParams) {
                AVFilterContext *abuffer_ctx;
                const AVFilter  *abuffer;

                abuffer = avfilter_get_by_name("abuffer");
                if (!abuffer) {
                    ret = AVERROR_FILTER_NOT_FOUND;
                    break;
                }

                NSNumber *sampleRate = [NSNumber numberWithInt:codecParams->sample_rate];
                if (![outSampleRates containsObject:sampleRate]) {
                     [outSampleRates addObject:sampleRate];
                }

                NSString *filterName = [NSString stringWithFormat:@"%@%d", @"src", i++];
                const char *filter_name = [filterName UTF8String];
                abuffer_ctx = avfilter_graph_alloc_filter(filter_graph, abuffer, filter_name);
                if (!abuffer_ctx) {
                    ret = AVERROR(ENOMEM);
                    break;
                }
                
                av_opt_set(abuffer_ctx, "channel_layout", ch_layout, AV_OPT_SEARCH_CHILDREN);
                AVCodec *codec_ptr = avcodec_find_encoder(codecContext->codec_id);
                if (codec_ptr &&
                    *(codec_ptr->sample_fmts) != AV_SAMPLE_FMT_NONE &&
                    *(codec_ptr->sample_fmts) != AV_SAMPLE_FMT_NB) {
                    sample_fmt = *(codec_ptr->sample_fmts);
                }
                av_opt_set(abuffer_ctx, "sample_fmt", av_get_sample_fmt_name(sample_fmt), AV_OPT_SEARCH_CHILDREN);
                av_opt_set_q(abuffer_ctx, "time_base", (AVRational){ 1, codecContext->sample_rate }, AV_OPT_SEARCH_CHILDREN);
                av_opt_set_int(abuffer_ctx, "sample_rate", codecContext->sample_rate, AV_OPT_SEARCH_CHILDREN);

                if ((ret = avfilter_init_str(abuffer_ctx, NULL)) < 0) {
                    break;
                }
                
                [self synchronize:^{
                    self->_filtersSrcs[key] = [[AVFilterContextWrap alloc] initWithFilterContext:abuffer_ctx];
                }];
            }
        }
        
        [outSampleRates removeAllObjects];
        /* abuffer */

        /* Create amerge filter. */
        amerge = avfilter_get_by_name("amix");
        if (!amerge) {
            ret = AVERROR_FILTER_NOT_FOUND;
            break;
        }

        amerge_ctx = avfilter_graph_alloc_filter(filter_graph, amerge, "mix");
        if (!amerge_ctx) {
            ret = AVERROR(ENOMEM);
            break;
        }

        const char *merge_options_str = [[NSString stringWithFormat:@"inputs=%d:duration=longest:dropout_transition=3", i] UTF8String];
        /* This filter takes input options. */
        if ((ret = avfilter_init_str(amerge_ctx, merge_options_str)) < 0) {
            break;
        }
        /* amerge */

        /* Create the aformat filter;
        * it ensures that the output is of the format we want. */
        aformat = avfilter_get_by_name("aformat");
        if (!aformat) {
            ret = AVERROR_FILTER_NOT_FOUND;
            break;
        }

        aformat_ctx = avfilter_graph_alloc_filter(filter_graph, aformat, "aformat");
        if (!aformat_ctx) {
            ret = AVERROR(ENOMEM);
            break;
        }

        const char *options_str = [[NSString stringWithFormat:@"sample_fmts=%s:sample_rates=%d:channel_layouts=%s", av_get_sample_fmt_name(AAC_SAMPLE_FMT), codecContext->sample_rate, ch_layout] UTF8String];
        if ((ret = avfilter_init_str(aformat_ctx, options_str)) < 0) {
            break;
        }
        /* aformat */

        /* Finally create the abuffersink filter;
        * it will be used to get the filtered data out of the graph. */
        abuffersink = avfilter_get_by_name("abuffersink");
        if (!abuffersink) {
            ret = AVERROR_FILTER_NOT_FOUND;
            break;
        }

        abuffersink_ctx = avfilter_graph_alloc_filter(filter_graph, abuffersink, "out");
        if (!abuffersink_ctx) {
            ret = AVERROR(ENOMEM);
            break;
        }

        /* This filter takes no options. */
        if ((ret = avfilter_init_str(abuffersink_ctx, NULL)) < 0) {
            break;
        }

        /* Connect the filters;
        * in this simple case the filters just form a linear chain. */
        i = 0;
        [self synchronize:^{
            for (NSNumber *key in self->_filtersSrcs) {
                AVFilterContext *abuffer_ctx = self->_filtersSrcs[key].filter;
                if ((ret = avfilter_link(abuffer_ctx, 0, amerge_ctx, i++)) < 0) {
                    break;
                }
            }
        }];
        if (ret < 0) {
            break;
        }
        if ((ret = avfilter_link(amerge_ctx, 0, aformat_ctx, 0)) < 0) {
            break;
        }
        if ((ret = avfilter_link(aformat_ctx, 0, abuffersink_ctx, 0)) < 0) {
            break;
        }

        /* Configure the graph. */
        if ((ret = avfilter_graph_config(filter_graph, NULL)) < 0){
            break;
        }

        break;
    }

    if (ret < 0) {
        if (filter_graph) {
            avfilter_graph_free(&filter_graph);
        }
    } else {
        _graph = filter_graph;
        _filterSink  = abuffersink_ctx;
    }

    return ret;

}

- (int)filterFrame:(AVFrame *)frame forStreamIndex:(NSNumber *)index {
    __block int ret = 0;
    [self synchronize:^{
        AVFilterContext *filterSrc = self->_filtersSrcs[index].filter;
        if (!filterSrc) {
            ret = AVERROR_FILTER_NOT_FOUND;
        }
        ret = av_buffersrc_add_frame(filterSrc, frame);
    }];
    return ret;
}

- (AVFrame *_Nullable)getFilteredFrameForStreamIndex:(NSNumber *)index errorCode:(int *)error {
    __block AVFrame *frame = NULL;
    [self synchronize:^{
        AVFilterContext *filterSinc = self->_filterSink;
        if (!filterSinc) {
            *error = AVERROR_FILTER_NOT_FOUND;
        } else {
            frame = av_frame_alloc();
            *error = av_buffersink_get_frame(filterSinc, frame);
            if (*error == AVERROR(EAGAIN) || *error == AVERROR_EOF) {
                *error = 0;
                av_frame_free(&frame);
            }
        }
    }];
    return frame;
}

- (void)deInitialize {
    [self synchronize:^{
        [self releaseFilterSinc];

        [self->_filtersSrcs removeAllObjects];
        if (self->_graph) {
            avfilter_graph_free(&(self->_graph));
        }
    }];
}

#pragma mark - Helpers

- (void)releaseFilterSinc {
    if (!_filterSink) {
        return;
    }
    
    AVFrame *frame = av_frame_alloc();
    while (av_buffersink_get_frame(_filterSink, frame) >= 0) {
        av_frame_free(&frame);
    }
    av_frame_free(&frame);
}

- (NSString *)arrayToString:(NSArray<NSNumber *> *)array {
    NSMutableString *str = [NSMutableString new];
    for(int i = 0; i < array.count; ++i) {
        [str appendFormat:@"%d", array[i].intValue];
        if (i + 1 < array.count) {
            [str appendFormat:@"|"];
        }
    }
    return str;
}

- (void)synchronize:(dispatch_block_t)block {
    [_locker lock]; {
        block();
    }
    [_locker unlock];
}

@end
