//
// common.h
// Created on 1/3/20
//
//  Created by Maxim Komlev on 1/9/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#include "common.h"

int encode(AVCodecContext *avctx, AVPacket *pkt, const AVFrame *frame, int *got_packet) {
    int ret;
    
    *got_packet = 0;
    
    if ((ret = avcodec_send_frame(avctx, frame)) < 0) {
        return ret;
    }
    
    if ((ret = avcodec_receive_packet(avctx, pkt)) >= 0) {
        *got_packet = 1;
    }
    if (ret == AVERROR(EAGAIN)) {
        return 0;
    }
    
    return ret;
}

int decode(AVCodecContext *avctx, AVFrame *frame, AVPacket *pkt, int *got_frame) {
    int ret;
    
    *got_frame = 0;
    
    if (pkt) {
        if ((ret = avcodec_send_packet(avctx, pkt)) < 0) {
            return ret == AVERROR_EOF ? 0 : ret;
        }
    }
    
    if ((ret = avcodec_receive_frame(avctx, frame)) < 0 &&
        ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
        return ret;
    }
    if (ret >= 0) {
        *got_frame = 1;
    }
    
    return 0;
}

uint64_t validateChannelLayout(uint64_t channelLayout) {
    if (channelLayout == AV_CH_LAYOUT_MONO ||
        channelLayout == AV_CH_LAYOUT_2POINT1 ||
        channelLayout == AV_CH_LAYOUT_2_1 ||
        channelLayout == AV_CH_LAYOUT_SURROUND ||
        channelLayout == AV_CH_LAYOUT_3POINT1 ||
        channelLayout == AV_CH_LAYOUT_2_2 ||
        channelLayout == AV_CH_LAYOUT_QUAD ||
        channelLayout == AV_CH_LAYOUT_5POINT0 ||
        channelLayout == AV_CH_LAYOUT_5POINT1 ||
        channelLayout == AV_CH_LAYOUT_5POINT0_BACK ||
        channelLayout == AV_CH_LAYOUT_5POINT1_BACK ||
        channelLayout == AV_CH_LAYOUT_6POINT0 ||
        channelLayout == AV_CH_LAYOUT_6POINT0_FRONT ||
        channelLayout == AV_CH_LAYOUT_6POINT1 ||
        channelLayout == AV_CH_LAYOUT_6POINT1_BACK ||
        channelLayout == AV_CH_LAYOUT_6POINT1_FRONT ||
        channelLayout == AV_CH_LAYOUT_7POINT0 ||
        channelLayout == AV_CH_LAYOUT_7POINT0_FRONT ||
        channelLayout == AV_CH_LAYOUT_7POINT1 ||
        channelLayout == AV_CH_LAYOUT_7POINT1_WIDE ||
        channelLayout == AV_CH_LAYOUT_7POINT1_WIDE_BACK ||
        channelLayout == AV_CH_LAYOUT_7POINT1 ||
        channelLayout == AV_CH_LAYOUT_7POINT1) {
        return channelLayout;
    }
    return AAC_CHANNEL_LAYOUT;
}
