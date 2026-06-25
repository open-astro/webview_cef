//
//  WebviewCefTexture.h
//  Pods
//
//  Created by Hao Linwei on 2022/8/18.
//

#ifndef WebviewCefTexture_h
#define WebviewCefTexture_h
#import <FlutterMacOS/FlutterMacOS.h>
#import <IOSurface/IOSurface.h>

@interface WebviewCefTexture : NSObject<FlutterTexture>
{
    CVPixelBufferRef _pixelBuffer;
    CVPixelBufferRef _pixelBufferTemp;
    dispatch_semaphore_t _lock;
    // CPU-path (onFrame) buffer pool — recycles CVPixelBuffers instead of
    // allocating one per frame; recreated only when the frame size changes.
    CVPixelBufferPoolRef _pool;
    size_t _poolWidth;
    size_t _poolHeight;
}

- (void)onFrame:(const void *)buffer width:(int64_t)width height:(int64_t)height;

// GPU shared-texture frame (accelerated OSR): wrap the CEF IOSurface as the
// texture's CVPixelBuffer with no CPU copy. Dimensions are taken from the surface.
- (void)onIOSurface:(IOSurfaceRef)surface width:(int64_t)width height:(int64_t)height;

@end

#endif /* WebviewCefTexture_h */
