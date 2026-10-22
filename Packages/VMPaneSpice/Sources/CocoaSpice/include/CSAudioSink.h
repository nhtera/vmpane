//
// Copyright © 2026 VMPane. Apache-2.0.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Receives a session's sound when CocoaSpice's own (GStreamer) audio is off: the guest's playback, and requests
/// for recorded sound (answered with `-[CSConnection sendRecordedAudio:]`). Samples are signed 16-bit, interleaved.
/// Every method is called on the SPICE main loop thread.
@protocol CSAudioSink <NSObject>

- (void)playbackStartWithChannels:(int)channels rate:(int)rate;
- (void)playbackData:(const void *)data size:(int)size;
- (void)playbackStop;
/// The guest's volume (0 to 1) and mute for its playback.
- (void)playbackVolume:(float)volume muted:(BOOL)muted;

- (void)recordStartWithChannels:(int)channels rate:(int)rate;
- (void)recordStop;
/// The guest's volume (0 to 1) and mute for its recording.
- (void)recordVolume:(float)volume muted:(BOOL)muted;

@end

NS_ASSUME_NONNULL_END
