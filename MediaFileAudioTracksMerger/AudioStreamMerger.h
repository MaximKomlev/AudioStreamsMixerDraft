//
// AudioStreamMerger.h
// Created on 1/3/20
//
//  Created by Maxim Komlev on 1/9/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#ifndef AudioStreamMerger_h
#define AudioStreamMerger_h

#import <Foundation/Foundation.h>

@class AudioStreamMerger;
@protocol AudioStreamMergerDelegate <NSObject>

- (void)didStart:(AudioStreamMerger *_Nonnull)source;
- (void)didError:(AudioStreamMerger *_Nonnull)source error:(NSError * _Nullable)error;
- (void)didProcessing:(AudioStreamMerger *_Nonnull)source withProgress:(long)progress;
- (void)didStop:(AudioStreamMerger *_Nonnull)source forFilePath:(NSString *_Nonnull)path;

@end

@interface AudioStreamMerger: NSObject

- (id _Nullable)initWithUrl:(NSURL *_Nonnull)url;
- (id _Nullable)initWithUrl:(NSURL *_Nonnull)url
                withOptions:(NSDictionary<NSString *, NSString *> *_Nonnull)options;
- (id _Nullable)initWithUrl:(NSURL *_Nonnull)url
                withOptions:(NSDictionary<NSString *, NSString *> *_Nonnull)options
                    onQueue:(dispatch_queue_t _Nonnull)queue;
- (void)start;
- (void)stop;

@property (atomic, readonly) BOOL isStopped;

@property (nonatomic, nullable, weak) id<AudioStreamMergerDelegate> delegate;

@end

#endif /* AudioStreamMerger_h */
