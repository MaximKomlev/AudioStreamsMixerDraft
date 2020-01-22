//
// common.h
// Created on 1/3/20
//
//  Created by Maxim Komlev on 1/9/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#ifndef common_h
#define common_h

#import <libavformat/avformat.h>

#define AAC_SAMPLE_FMT AV_SAMPLE_FMT_FLTP
#define AAC_OUTPUT_BIT_RATE 96000
#define AAC_OUTPUT_SAMPLE_RATE 48000
#define AAC_CHANNEL_LAYOUT AV_CH_LAYOUT_STEREO
#define AAC_CODEC_ID AV_CODEC_ID_AAC
#define AV_FILE_FORMAT @"mp4"

int encode(AVCodecContext *avctx, AVPacket *pkt, const AVFrame *frame, int *got_packet);
int decode(AVCodecContext *avctx, AVFrame *frame, AVPacket *pkt, int *got_frame);

/*
* AVPlayer does not support all possible channels layout,
* the method validate it against ffmpeg supported channel layouts.
*/
uint64_t validateChannelLayout(uint64_t channelLayout);

#endif /* common_h */
