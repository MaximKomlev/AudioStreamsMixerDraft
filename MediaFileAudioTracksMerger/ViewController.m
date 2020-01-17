//
//  ViewController.m
//  MediaFileAudioTracksMerger
//
//  Created by Maxim Komlev on 1/9/20.
//  Copyright © 2020 Maxim Komlev. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioStreamMerger.h"
#import "ViewController.h"

//#define TRACE_NETWORK 1
//#define TRACE_ERROR 1
//#define TRACE_STATUS 1
#define TRACE_ALL 1
//#define TRACE_TIME_STATUS 1

static int AAPLPlayerKVOContext = 0;

@interface ViewController () <AudioStreamMergerDelegate>

@end

@implementation ViewController {
    UIButton *_stopButton;
    AVPlayerLayer *_playerLayer;
    
    AudioStreamMerger *_merger;
    id _timeObserverToken;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.title = @"Objective C Audio tracks merger sample";
    
    UIBarButtonItem *rightButton = [[UIBarButtonItem alloc] initWithTitle:@"Media Samples" style:UIBarButtonItemStylePlain target:self action:@selector(buttonNextTouched:)];
    self.navigationItem.rightBarButtonItem = rightButton;

    AVPlayer *player = [AVPlayer playerWithPlayerItem:NULL];
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    _playerLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:_playerLayer];

    _stopButton = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *buttonIcon = [[UIImage imageNamed:@"icon_playback_pause"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [_stopButton setImage:buttonIcon forState:UIControlStateNormal];
    _stopButton.bounds = CGRectMake(0, 0, 64, 64);
    _stopButton.tintColor = UIColor.whiteColor;
    _stopButton.backgroundColor = UIColor.clearColor;
    _stopButton.showsTouchWhenHighlighted = TRUE;
    [_stopButton addTarget:self action:@selector(stopButtonAction:) forControlEvents:UIControlEventTouchUpInside];
    _stopButton.center = self.view.center;
    _stopButton.hidden = TRUE;
    [self.view addSubview:_stopButton];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(playerStalledHandler:)
                                                 name: AVPlayerItemPlaybackStalledNotification
                                               object: NULL];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(errorHandler:)
                                                 name: AVPlayerItemNewErrorLogEntryNotification
                                               object: NULL];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(errorHandler:)
                                                 name: AVPlayerItemFailedToPlayToEndTimeNotification
                                               object: NULL];

    [self addObservers:player];
    [self addPeriodicTimeObserver];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    _stopButton.center = self.view.center;
    _playerLayer.frame = self.view.bounds;
}

#pragma mark - AudioStreamMergerDelegate

- (void)didStart:(AudioStreamMerger * _Nonnull)source {
}

- (void)didProcessing:(AudioStreamMerger * _Nonnull)source withProgress:(long)progress {
    NSLog(@"progress = %ld", progress);
}

- (void)didStop:(AudioStreamMerger * _Nonnull)source forFilePath:(NSString * _Nonnull)path {
    NSString *filePath = [NSString stringWithFormat:@"file://%@", path];
    AVAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:filePath] options:nil];
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
    [_playerLayer.player replaceCurrentItemWithPlayerItem:playerItem];
    self.navigationItem.rightBarButtonItem.enabled = TRUE;
    [self.view layoutSubviews];
    [_playerLayer.player play];
    _stopButton.hidden = FALSE;
    _merger = NULL;
}

- (void)didError:(AudioStreamMerger * _Nonnull)source error:(NSError * _Nullable)error {
    self.navigationItem.rightBarButtonItem.enabled = TRUE;
}

#pragma mark - Events handlers

- (void)buttonNextTouched:(id)sender {
    UIAlertController *ac =   [UIAlertController
                                  alertControllerWithTitle:@"Media sources"
                                  message:@"Select one to transcode and mix"
                                  preferredStyle:UIAlertControllerStyleActionSheet];
     
    UIAlertAction* cancelAction = [UIAlertAction
                             actionWithTitle:@"Cancel"
                             style:UIAlertActionStyleCancel
                             handler:^(UIAlertAction * action)
                             {
                                 [ac dismissViewControllerAnimated:YES completion:nil];
                             }];
    [ac addAction:cancelAction];

    UIAlertAction* monotrack_opus_1track = [UIAlertAction
                         actionWithTitle:@"opus.ogg"
                         style:UIAlertActionStyleDefault
                         handler:^(UIAlertAction * action)
                         {
        NSString* path = [[NSBundle mainBundle] pathForResource:@"monotrack_opus_1_track" ofType:@"ogg"];
        [self startTranscoding:path];
        [ac dismissViewControllerAnimated:YES completion:nil];
                         }];
    [ac addAction:monotrack_opus_1track];

    // todo: suport different sumple rate of enc. and dec.
//    UIAlertAction* multitrack_2tracksAction = [UIAlertAction
//                         actionWithTitle:@"multitrack_2_tracks.mkv"
//                         style:UIAlertActionStyleDefault
//                         handler:^(UIAlertAction * action)
//                         {
//        NSString* path = [[NSBundle mainBundle] pathForResource:@"multitrack_2_tracks" ofType:@"mkv"];
//        [self startTranscoding:path];
//        [ac dismissViewControllerAnimated:YES completion:nil];
//                         }];
//    [ac addAction:multitrack_2tracksAction];

    UIAlertAction* multitrack_3tracksAction = [UIAlertAction
                         actionWithTitle:@"multitrack_3tracks.mp4"
                         style:UIAlertActionStyleDefault
                         handler:^(UIAlertAction * action)
                         {
        NSString* path = [[NSBundle mainBundle] pathForResource:@"multitrack_3_tracks" ofType:@"mp4"];
        [self startTranscoding:path];
        [ac dismissViewControllerAnimated:YES completion:nil];
                         }];
    [ac addAction:multitrack_3tracksAction];

    [self presentViewController:ac animated:YES completion:nil];
}

- (void)stopButtonAction:(UIButton *)button {
    [_playerLayer.player pause];
    button.hidden = TRUE;
}

#pragma mark - Player Observing

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &AAPLPlayerKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    AVPlayer *player = _playerLayer.player;
    AVPlayerItem *item = (AVPlayerItem *)player.currentItem;
    if ([keyPath isEqualToString:@"currentItem"]) {
#if TRACE_STATUS || TRACE_ALL
        NSLog(@"RTSPAVPlayer:observeValueForKeyPath currentItem.url: %@", ((AVURLAsset *)item.asset).URL.absoluteString);
#endif
    } else if ([keyPath isEqualToString:@"status"]) {
        if (player.status == AVPlayerStatusFailed) {
#if TRACE_ERROR || TRACE_ALL
            NSLog(@"RTSPAVPlayer:observeValueForKeyPath status.Fail.url: %@, error: %@", ((AVURLAsset *)item.asset).URL.absoluteString, player.error);
#endif
        } else if (player.status == AVPlayerStatusReadyToPlay) {
#if TRACE_STATUS || TRACE_ALL
            NSLog(@"RTSPAVPlayer:observeValueForKeyPath status.ReadyToPlay.url: %@", ((AVURLAsset *)item.asset).URL.absoluteString);
#endif
        } else {
#if TRACE_STATUS || TRACE_ALL
            NSLog(@"RTSPAVPlayer:observeValueForKeyPath status.....url: %@", ((AVURLAsset *)item.asset).URL.absoluteString);
#endif
        }
    }
}

- (void)addObservers:(AVPlayer *)player {
    [player addObserver:self forKeyPath:@"currentItem" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:&AAPLPlayerKVOContext];
    [player addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:&AAPLPlayerKVOContext];
}

- (void)removeObservers:(AVPlayer *)player {
    if ([player observationInfo]) {
        [player removeObserver:self forKeyPath:@"currentItem"];
        [player removeObserver:self forKeyPath:@"status"];
    }
}

- (void)addPeriodicTimeObserver {
    __weak typeof(_playerLayer.player) weakPlayer = _playerLayer.player;
    __weak typeof(self) weakSelf = self;
    _timeObserverToken = [_playerLayer.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.21, NSEC_PER_SEC)
                                              queue:dispatch_get_main_queue()
                                         usingBlock:^(CMTime time) {
                                             __strong typeof(weakSelf) strongSelf = weakSelf;
                                             if (strongSelf) {
#if TRACE_TIME_STATUS || TRACE_ALL
                                                 NSString *currentItemURL = NULL;
                                                 __strong typeof(weakPlayer) strongPlayer = weakPlayer;
                                                 if (strongPlayer) {
                                                     AVPlayerItem *item = strongPlayer.currentItem;
                                                         if (item) {
                                                             currentItemURL = ((AVURLAsset *)item.asset).URL.absoluteString;
                                                         }
                                                         NSLog(@"RTSPAVPlayer:addPeriodicTimeObserverForInterval url: %@, time: %f, duration: %f", currentItemURL, CMTimeGetSeconds(time), CMTimeGetSeconds(item.duration));
#endif
                                                 }
                                             }
                                         }];
}

#pragma mark - Helpers (Notification handlers)

- (void)playerStalledHandler:(NSNotification *)notification {
    AVPlayer *player = _playerLayer.player;
    AVPlayerItem *item = player.currentItem;
    if (item) {
#if TRACE_ERROR || TRACE_ALL
        NSLog(@"RTSPAVPlayer:playerStalled, currentItem.url: %@", ((AVURLAsset *)item.asset).URL.absoluteString);
#endif
    }
}

- (void)errorHandler:(NSNotification *)notification {
    AVPlayer *player = _playerLayer.player;
    AVPlayerItem *item = player.currentItem;
    if (item) {
#if TRACE_ERROR || TRACE_ALL
        NSLog(@"RTSPAVPlayer:errorHandler, currentItem.url: %@, error: %@", ((AVURLAsset *)item.asset).URL.absoluteString, item.errorLog);
#endif
    }
}

#pragma mark - Helpers

- (void)startTranscoding:(NSString *)path {
    _merger = NULL;
    _merger = [[AudioStreamMerger alloc] initWithUrl:[NSURL URLWithString:path]];
    _merger.delegate = self;
    [_merger start];
    self.navigationItem.rightBarButtonItem.enabled = FALSE;
}


@end
