//
//  WebviewCefTexture.m
//  Pods-Runner
//
//  Created by Hao Linwei on 2022/8/18.
//

#import "WebviewCefTexture.h"
#import <Foundation/Foundation.h>

typedef void(^RetainSelfBlock)(void);

@implementation WebviewCefTexture

- (id) init {
    self = [super init];
    if (self) {
        _lock = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)dealloc {
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
    if (_pixelBuffer) { CVPixelBufferRelease(_pixelBuffer); _pixelBuffer = NULL; }
    if (_heldSurface) { IOSurfaceDecrementUseCount(_heldSurface); _heldSurface = NULL; }
    // _pixelBufferTemp is intentionally NOT released here: copyPixelBuffer hands its
    // retained reference to the Flutter engine, which owns and releases it per the
    // FlutterTexture contract. Releasing it again would over-release that buffer.
}

- (void)onFrame:(const void *)buffer width:(int64_t)width height:(int64_t)height{
    // Reuse buffers from a CVPixelBufferPool instead of allocating a fresh
    // CVPixelBuffer every frame (this is called per OnPaint, up to 30fps). The pool
    // recycles a buffer once Flutter releases its retained copy, so steady-state
    // frames do no heap allocation. The pool is (re)created only when the frame
    // dimensions change.
    if (_pool == NULL || _poolWidth != (size_t)width || _poolHeight != (size_t)height) {
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary* pbAttrs = @{
            (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString*)kCVPixelBufferWidthKey: @(width),
            (__bridge NSString*)kCVPixelBufferHeightKey: @(height),
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (__bridge NSString*)kCVPixelBufferOpenGLCompatibilityKey : @YES,
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)pbAttrs, &_pool);
        _poolWidth = (size_t)width;
        _poolHeight = (size_t)height;
    }

    CVPixelBufferRef buf = NULL;
    if (_pool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &buf);
    }
    if (buf == NULL) { return; } // pool creation failed — drop this frame rather than crash

    //copy data
    CVPixelBufferLockBaseAddress(buf, 0);
    char *copyBaseAddress = (char *) CVPixelBufferGetBaseAddress(buf);
            
    //MUST align pixel to _pixelBuffer. Otherwise cause render issue. see https://www.codeprintr.com/thread/6563066.html about 16 bytes align
    size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    char* src = (char*) buffer;
    int actureRowSize = width * 4;
    for(int line = 0; line < height; line++) {
        memcpy(copyBaseAddress, src, actureRowSize);
        src += actureRowSize;
        copyBaseAddress += bytesPerRow;
    }
    CVPixelBufferUnlockBaseAddress(buf, 0);
            
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    if(_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
    }
    // A CPU frame supersedes any GPU surface we were holding — release that hold.
    if (_heldSurface) { IOSurfaceDecrementUseCount(_heldSurface); _heldSurface = NULL; }
    _pixelBuffer = buf;
    dispatch_semaphore_signal(_lock);
}

- (void)onIOSurface:(IOSurfaceRef)surface width:(int64_t)width height:(int64_t)height {
    if (surface == NULL) { return; }
    // Zero-copy: wrap the CEF-owned IOSurface as a CVPixelBuffer rather than memcpy a
    // CPU buffer. CEF cycles a small pool of surfaces and hands us the current one per
    // frame; Flutter reads it via copyPixelBuffer. The pixel format (BGRA) is carried
    // by the IOSurface itself, so no format is specified here.
    NSDictionary* attrs = @{
        (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
        (__bridge NSString*)kCVPixelBufferOpenGLCompatibilityKey : @YES,
    };
    CVPixelBufferRef buf = NULL;
    CVReturn r = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                                  (__bridge CFDictionaryRef)attrs, &buf);
    if (r != kCVReturnSuccess || buf == NULL) {
        if (buf) { CVPixelBufferRelease(buf); }
        return;
    }
    // Mark the surface in-use so CEF's surface pool won't recycle (overwrite) it
    // while Flutter is still compositing the CVPixelBuffer that wraps it — without
    // this the zero-copy path can tear/corrupt. Balanced when this buffer is
    // replaced (here or in onFrame) or in dealloc.
    IOSurfaceIncrementUseCount(surface);
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
    }
    if (_heldSurface) { IOSurfaceDecrementUseCount(_heldSurface); }
    _pixelBuffer = buf;
    _heldSurface = surface;
    dispatch_semaphore_signal(_lock);
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    _pixelBufferTemp = _pixelBuffer;
    CVPixelBufferRetain(_pixelBufferTemp);
    dispatch_semaphore_signal(_lock);
    return _pixelBufferTemp;
}

@end
