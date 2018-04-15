//
//  WSImageDecoder.m
//  YYTest_ws
//
//  Created by great Lock on 2018/4/4.
//  Copyright © 2018年 great Lock. All rights reserved.
//

#import "WSImageCoder.h"
#import "WSKitMacro.h"
#import <CoreFoundation/CoreFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <zlib.h>

#ifndef WSIMAGE_WEBP_ENABLED
#if __has_include(<webp/decode.h>) && __has_include(<webp/encode.h>) && \
__has_include(<webp/demux.h>) && __has_include(<web/mux.h>)
#define WSIMAGE_WEBP_ENABLED 1
#import <webp/decode.h>
#import <webp/encode.h>
#import <webp/demux.h>
#import <webp/mux.h>
#elif __has_include("webp/decode.h") && __has_include("webp/encode.h") && \
__has_include("webp/demux.h") && __has_include("webp/mux.h")
#define WSIMAGE_WEBP_ENABLED 1
#import "webp/decode.h"
#import "webp/encode.h"
#import "webp/demux.h"
#import "webp/mux.h"
#else
#define WSIMAGE_WEBP_ENABLED 0
#endif
#endif


#pragma mark - Utility (for little endian platform)

#define WS_FOUR_CC(c1, c2, c3, c4) ((uint32_t)(((c4) << 24) | ((c3) << 16) | ((c2) << 8) | (c1)))
#define WS_TWO_CC(c1, c2) ((uint16_t)(((c2) << 8) | (c1)))

static inline uint16_t ws_swap_endian_uint16(uint16_t value) {
    return (uint16_t) ((value & 0x00FF) <<8) | (uint16_t) ((value & 0xFF00) >> 8);
}

static inline uint32_t ws_swap_endian_uint32(uint32_t value) {
    return
    (uint32_t)((value & 0x000000FFU) << 24) |
    (uint32_t)((value & 0x0000FF00U) <<  8) |
    (uint32_t)((value & 0x00FF0000U) >>  8) |
    (uint32_t)((value & 0xFF000000U) >> 24) ;
}

typedef enum {
    WS_PNG_ALPHA_TYPE_PALEETE = 1 << 0,
    WS_PNG_ALPHA_TYPE_COLOR = 1 << 1,
    WS_PNG_ALPHA_TYPE_ALPHA = 1 << 2,
} ws_png_alpha_type;

typedef enum {
    WS_PNG_DISPOSE_OP_NONE = 0,
    WS_PNG_DISPOSE_OP_BACKGROUND = 1,
    WS_PNG_DISPOSE_OP_PREVIOUS = 2,
} ws_png_dispose_op;

typedef enum {
    WS_PNG_BLEND_OP_SOURCE = 0,
    WS_PNG_BLEND_OP_OVER = 1,
} ws_png_blend_op;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t bit_depth;
    uint8_t color_type;
    uint8_t compression_method;
    uint8_t filter_method;
    uint8_t interlace_method;
} ws_png_chunk_IHDR;

typedef struct {
    uint32_t sequence_number;
    uint32_t width;
    uint32_t height;
    uint32_t x_offset;
    uint32_t y_offset;
    uint16_t delay_num;
    uint16_t delay_den;
    uint8_t dispose_op;
    uint8_t blend_op;
} ws_png_chunk_fcTL;

typedef struct {
    uint32_t offset;
    uint32_t fourcc;
    uint32_t length;
    uint32_t crc32;
} ws_png_chunk_info;

typedef struct {
    uint32_t chunk_index;
    uint32_t chunk_num;
    uint32_t chunk_size;
    ws_png_chunk_fcTL frame_control;
} ws_png_frame_info;

typedef struct {
    ws_png_chunk_IHDR header;
    ws_png_chunk_info *chunks;
    uint32_t chunk_num;
    
    ws_png_frame_info *apng_frames;
    uint32_t apng_frame_num;
    uint32_t apng_loop_num;
    
    uint32_t *apng_shared_chunk_indexs;
    uint32_t apng_shared_chunk_num;
    uint32_t apng_shared_chunk_size;
    uint32_t apng_shared_insert_index;
    bool apng_first_frame_is_cover;
} ws_png_info;

static void ws_png_chunk_IHDR_write(ws_png_chunk_IHDR *IHDR, uint8_t *data) {
    *((uint32_t *)(data)) = ws_swap_endian_uint32(IHDR->width);
    *((uint32_t *)(data + 4)) = ws_swap_endian_uint32(IHDR->height);
    data[8] = IHDR->bit_depth;
    data[9] = IHDR->color_type;
    data[10] = IHDR->compression_method;
    data[11] = IHDR->filter_method;
    data[12] = IHDR->interlace_method;
}

CGColorSpaceRef WSCGColorSpaceGetDeviceRGB() {
    static CGColorSpaceRef space;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        space = CGColorSpaceCreateDeviceRGB();
    });
    return space;
}

static void WSCGDataProviderReleaseDataCallBack(void *info, const void *data, size_t size) {
    if (info) free(info);
}

static inline size_t WSImageByteAlign(size_t size, size_t alignment) {
    return ((size + (alignment - 1)) / alignment) * alignment;
}

CGImageRef WSCGImageCreateDecodedCopy(CGImageRef imageRef, BOOL decodeForDisplay) {
    if (!imageRef) return NULL;
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    if (width == 0 || height == 0) return NULL;
    
    if (decodeForDisplay) {
        CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(imageRef);
        BOOL hasAlpha = false;
        if (alphaInfo == kCGImageAlphaPremultipliedLast ||
            alphaInfo == kCGImageAlphaPremultipliedFirst ||
            alphaInfo == kCGImageAlphaLast ||
            alphaInfo == kCGImageAlphaFirst) {
            hasAlpha = true;
        }
        
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
        bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, WSCGColorSpaceGetDeviceRGB(), bitmapInfo);
        if (!context) return NULL;
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), imageRef);
        CGImageRef newImage = CGBitmapContextCreateImage(context);
        CFRelease(context);
        return newImage;
    }else {
        CGColorSpaceRef space = CGImageGetColorSpace(imageRef);
        size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
        size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
        size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
        CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
        if (bytesPerRow == 0 || width == 0 || height == 0) return NULL;
        
        CGDataProviderRef dataProvider = CGImageGetDataProvider(imageRef);
        if (!dataProvider) return NULL;
        CFDataRef data = CGDataProviderCopyData(dataProvider);
        if (!data) return NULL;
        
        CGDataProviderRef newProvider = CGDataProviderCreateWithCFData(data);
        CFRelease(data);
        if (!newProvider) return NULL;
        
        CGImageRef newImage = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, space, bitmapInfo, newProvider, NULL, false, kCGRenderingIntentDefault);
        CFRelease(newProvider);
        return newImage;
    }
}

static uint8_t *ws_png_copy_frame_data_at_index(const uint8_t *data,
                                                const ws_png_info *info,
                                                const uint32_t index,
                                                uint32_t *size) {
    if (index >= info->apng_frame_num) return NULL;
    
    ws_png_frame_info *frame_info = info->apng_frames + index;
    uint32_t frame_remux_size = 8 + info->apng_shared_chunk_size + frame_info->chunk_size;
    if (!(info->apng_first_frame_is_cover && index == 0)) {
        frame_remux_size -= frame_info->chunk_num * 4;
    }
    uint8_t *frame_data = malloc(frame_remux_size);
    if (!frame_data) return NULL;
    *size = frame_remux_size;
    
    uint32_t data_offset = 0;
    bool inserted = false;
    memcpy(frame_data, data, 8);
    data_offset += 8;
    for (uint32_t i = 0; i < info->apng_shared_chunk_num; i ++) {
        uint32_t shared_chunk_index = info->apng_shared_chunk_indexs[i];
        ws_png_chunk_info *shared_chunk_info = info->chunks + shared_chunk_index;
        
        if (shared_chunk_index >= info->apng_shared_insert_index && !inserted) {
            inserted = true;
            for (uint32_t c = 0; c < frame_info->chunk_num; c ++) {
                ws_png_chunk_info *insert_chunk_info = info->chunks + frame_info->chunk_index + c;
                if (insert_chunk_info->fourcc == WS_FOUR_CC('f', 'd', 'A', 'T')) {
                    *((uint32_t *)(frame_data + data_offset)) = ws_swap_endian_uint32(insert_chunk_info->length - 4);
                    *((uint32_t *)(frame_data + data_offset + 4)) = WS_FOUR_CC('I', 'd', 'A', 'T');
                    memcpy(frame_data + data_offset + 8, data + insert_chunk_info->offset + 12, insert_chunk_info->length - 4);
                    uint32_t crc = (uint32_t)crc32(0, frame_data + data_offset + 4, insert_chunk_info->length);
                    *((uint32_t *)(frame_data + data_offset + insert_chunk_info->length + 4)) = ws_swap_endian_uint32(crc);
                    data_offset += insert_chunk_info->length + 8;
                }else {
                    memcpy(frame_data + data_offset, data + insert_chunk_info->offset, insert_chunk_info->length + 12);
                    data_offset += insert_chunk_info->length + 12;
                }
                
            }
        }
        
        if (shared_chunk_info->fourcc == WS_FOUR_CC('I', 'H', 'D', 'R')) {
            uint8_t tmp[25] = {0};
            memcpy(tmp, data + shared_chunk_info->offset, 25);
            ws_png_chunk_IHDR IHDR = info->header;
            IHDR.width = frame_info->frame_control.width;
            IHDR.height = frame_info->frame_control.height;
            ws_png_chunk_IHDR_write(&IHDR, tmp + 8);
            *((uint32_t *)(tmp + 21)) = ws_swap_endian_uint32((uint32_t)crc32(0, tmp + 4, 17));
            memcpy(frame_data + data_offset, tmp, 25);
            data_offset += 25;
        }else {
            memcpy(frame_data + data_offset, data + shared_chunk_info->offset, shared_chunk_info->length + 12);
            data_offset += shared_chunk_info->length + 12;
        }
    }
    return frame_data;
}


@interface _WSImageDecoderFrame: WSImageFrame
@property (nonatomic, assign) BOOL hasAlpha;
@property (nonatomic, assign) BOOL isFullSize;
@property (nonatomic, assign) NSUInteger blendFromIndex;
@end

@implementation _WSImageDecoderFrame
- (id)copyWithZone:(NSZone *)zone {
    _WSImageDecoderFrame *frame = [super copyWithZone:zone];
    frame.hasAlpha = _hasAlpha;
    frame.isFullSize = _isFullSize;
    frame.blendFromIndex = _blendFromIndex;
    return frame;
}
@end

@implementation WSImageDecoder {
    pthread_mutex_t _lock;
    
    BOOL _sourceTypeDetected;
    CGImageSourceRef _source;
    ws_png_info *_apngSource;
#if WSIMAGE_WEBP_ENABLED
    WebPDemuxer *_webpSource;
#endif
    
    UIImageOrientation _orientation;
    dispatch_semaphore_t _framesLock;
    NSArray *_frames;
    BOOL _needBlend;
    NSUInteger _blendFrameIndex;
    CGContextRef _blendCanvas;
}

- (instancetype)init {
    self = [super init];
    return [self initWithScale:[UIScreen mainScreen].scale];
}

- (instancetype)initWithScale:(CGFloat)scale {
    self = [super init];
    if (scale < 0) scale = 1;
    _scale = scale;
    _framesLock = dispatch_semaphore_create(1);
    pthread_mutex_init_recursive(&_lock, true);
    return self;
}

- (WSImageFrame *)frameAtIndex:(NSUInteger)index decodeForDisplay:(BOOL)decodeForDisplay {
    WSImageFrame *result = nil;
    pthread_mutex_lock(&_lock);
    result = [self ]
    pthread_mutex_unlock(&_lock);
}


- (WSImageFrame *)_frameAtIndex:(NSUInteger)index decodeForDisplay:(BOOL)decodeFroDisplay {
    if (index >= _frames.count) return 0;
    _WSImageDecoderFrame *frame = [(_WSImageDecoderFrame *)_frames[index] copy];
    BOOL decoded = false;
    BOOL extendToCanves = false;
    if (_type != WSImageTypeICO && decodeFroDisplay) {
        extendToCanves = true;
    }
    
    if (!_needBlend) {
        CGImageRef imageRef = [self _newUnblendedImageAtIndex:index extendToCanvas:extendToCanves decoded:&decoded];
        if (!imageRef) return nil;
        if (decodeFroDisplay && !decoded) {
            CGImageRef imageRefDecoded = WSCGImageCreateDecodedCopy(imageRef, true);
            if (imageRefDecoded) {
                CFRelease(imageRef);
                imageRef = imageRefDecoded;
                decoded = true;
            }
        }
        UIImage *image = [UIImage imageWithCGImage:imageRef scale:_scale orientation:_orientation];
        CFRelease(imageRef);
        if (!image) return nil;
        image.isDecodedForDisplay = true;
        frame.image = image;
        return frame;
    }
    
    //blend
    if (![self _createBlendContextIfNeeded]) return nil;
    CGImageRef imageRef = NULL;
    
    if (_blendFrameIndex + 1 == frame.index) {
        imageRef = [self _newBlendedImageWithFrame:frame];
        _blendFrameIndex = index;
    }else {
        _blendFrameIndex = NSNotFound;
        CGContextClearRect(_blendCanvas, CGRectMake(0, 0, _width, _height));
        
        if (frame.blendFromIndex == frame.index) {
            CGImageRef unblendedImage = [self _newUnblendedImageAtIndex:index extendToCanvas:false decoded:NULL];
            if (unblendedImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendedImage);
                CFRelease(unblendedImage)
            }
        }
    }
}

- (CGImageRef)_newUnblendedImageAtIndex:(NSUInteger)index
                         extendToCanvas:(BOOL)extendToCanvas
                                decoded:(BOOL *)decoded CF_RETURNS_RETAINED {
    if (!_finalized && index >0) return NULL;
    if (_frames.count <= index) return NULL;
    _WSImageDecoderFrame *frame = _frames[index];
    
    if (_source) {
        CGImageRef imageRef = CGImageSourceCreateImageAtIndex(_source, index, (CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @(true)});
        if (imageRef && extendToCanvas) {
            size_t width = CGImageGetWidth(imageRef);
            size_t height = CGImageGetHeight(imageRef);
            if (width == _width && height == _height) {
                CGImageRef imageRefExtended = WSCGImageCreateDecodedCopy(imageRef, true);
                if (imageRefExtended) {
                    CFRelease(imageRef);
                    imageRef = imageRefExtended;
                    if (decoded) *decoded = true;
                }
            }else {
                CGContextRef context = CGBitmapContextCreate(NULL, _width, _height, 8, 0, WSCGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
                if (context) {
                    CGContextDrawImage(context, CGRectMake(0, _height - height, width, height), imageRef);
                    CGImageRef imageRefExtended = CGBitmapContextCreateImage(context);
                    CFRelease(context);
                    if (imageRefExtended) {
                        CFRelease(imageRef);
                        imageRef = imageRefExtended;
                        if (decoded) *decoded = true;
                    }
                }
            }
        }
        return imageRef;
    }
    
    if (_apngSource) {
        uint32_t size = 0;
        uint8_t *bytes = ws_png_copy_frame_data_at_index(_data.bytes, _apngSource, (uint32_t)index, &size);
        if (!bytes) return NULL;
        CGDataProviderRef provider = CGDataProviderCreateWithData(bytes, bytes, size, WSCGDataProviderReleaseDataCallBack);
        if (!provider) {
            free(bytes);
            return NULL;
        }
        bytes = NULL;
        
        CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (!source) {
            CFRelease(provider);
            return NULL;
        }
        CFRelease(provider);
        
        if (CGImageSourceGetCount(source) < 1) {
            CFRelease(source);
            return NULL;
        }
        
        CGImageRef imageRef = CGImageSourceCreateImageAtIndex(source, 0, (CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @(true)});
        CFRelease(source);
        if (!imageRef) return NULL;
        if (extendToCanvas) {
            CGContextRef context = CGBitmapContextCreate(NULL, _width, _height, 8, 0, WSCGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
            if (context) {
                CGContextDrawImage(context, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), imageRef);
                CFRelease(imageRef);
                imageRef = CGBitmapContextCreateImage(context);
                CFRelease(context);
                if (decoded) *decoded = true;
            }
        }
        return imageRef;
    }
    
#if WSIMAGE_WEBP_ENABLED
    if (_webpSource) {
        WebPIterator iter;
        if (!WebPDemuxGetFrame(_webpSource, (int)(index + 1), &iter)) return NULL;
        
        int frameWidth = iter.width;
        int frameHeight = iter.height;
        if (frameWidth < 1 || frameHeight < 1) return NULL;
        
        int width = extendToCanvas ? (int)_width : frameWidth;
        int height = extendToCanvas ? (int)_height : frameHeight;
        if (width > _width || height > _height) return NULL;
        
        const uint8_t *payload = iter.fragment.bytes;
        size_t payloadSize = iter.fragment.size;
        
        WebPDecoderConfig config;
        if (!WebPInitDecoderConfig(&config)) {
            WebPDemuxReleaseIterator(&iter);
            return NULL;
        }
        if (WebPGetFeatures(payload, payloadSize, &config.input) != VP8_STATUS_OK) {
            WebPDemuxReleaseIterator(&iter);
            return NULL;
        }
        
        size_t bitsPerComponent = 8;
        size_t bitsPrePixel = 32;
        size_t bytesPreRow = WSImageByteAlign(bitsPrePixel / 8 * width, 32);
        size_t length = bytesPreRow * height;
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst;
        
        void *pixels = calloc(1, length);
        if (!pixels) {
            WebPDemuxReleaseIterator(&iter);
            return NULL;
        }
        
        config.output.colorspace = MODE_bgrA;
        config.output.is_external_memory = 1;
        config.output.u.RGBA.rgba = pixels;
        config.output.u.RGBA.stride = (int)bytesPreRow;
        config.output.u.RGBA.size = length;
        VP8StatusCode result = WebPDecode(payload, payloadSize, &config);
        if ((result != VP8_STATUS_OK) && (result != VP8_STATUS_NOT_ENOUGH_DATA)) {
            WebPDemuxReleaseIterator(&iter);
            free(pixels);
            return NULL;
        }
        WebPDemuxReleaseIterator(&iter);
        
        if (extendToCanvas && (iter.x_offset != 0 || iter.y_offset != 0)) {
            void *tmp = calloc(1, length);
            if (tmp) {
                vImage_Buffer src = {pixels, height, width, bytesPreRow};
                vImage_Buffer dest = {tmp, height, width, bytesPreRow};
                vImage_CGAffineTransform transform = {1, 0, 0, 1, iter.x_offset, -iter.y_offset};
                uint8_t backColor[4] = {0};
                vImage_Error error = vImageAffineWarpCG_ARGB8888(&src, &dest, NULL, &transform, backColor, kvImageBackgroundColorFill);
                if (error == kvImageNoError) {
                    memcpy(pixels, tmp, length);
                }
                free(tmp);
            }
        }
        
        CGDataProviderRef provider = CGDataProviderCreateWithData(pixels, pixels, length, WSCGDataProviderReleaseDataCallBack);
        if (!provider) {
            free(pixels);
            return NULL;
        }
        pixels = NULL;
        
        CGImageRef image = CGImageCreate(width, height, bitsPerComponent, bitsPrePixel, bytesPreRow, WSCGColorSpaceGetDeviceRGB(), bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);
        CFRelease(provider);
        if (decoded) *decoded = true;
        return image;
    }
#endif
    
    return NULL;
}

- (BOOL)_createBlendContextIfNeeded {
    if (!_blendCanvas) {
        _blendFrameIndex = NSNotFound;
        _blendCanvas = CGBitmapContextCreate(NULL, _width, _height, 8, 0, WSCGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
    }
    BOOL suc = _blendCanvas != NULL;
    return suc;
}

- (CGImageRef)_newBlendedImageWithFrame:(_WSImageDecoderFrame *)frame CF_RETURNS_RETAINED{
    CGImageRef imageRef = NULL;
    if (frame.dispose == WSImageDisposePrevious) {
        if (frame.blend == WSImageBlendOver) {
            CGImageRef previousImage = CGBitmapContextCreateImage(_blendCanvas);
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:false decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(0, 0, _width, _height));
            if (previousImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(0, 0, _width, _height), previousImage);
                CFRelease(previousImage);
            }
        }else {
            CGImageRef previousImage = CGBitmapContextCreateImage(_blendCanvas);
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:false decoded:NULL];
            if (unblendImage) {
                CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, _width, _height));
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, _width, _height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(0, 0, _width, _height));
            if (previousImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(0, 0, _width, _height), previousImage);
                CFRelease(previousImage);
            }
        }
    }else if (frame.dispose == WSImageDisposeBackground) {
        if (frame.blend == WSImageBlendOver) {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
        } else {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
        }
    }else {
        if (frame.blend == WSImageBlendOver) {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
        } else {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
        }
    }
    return imageRef;
}

@end

#pragma mark - image
@implementation UIImage (WSImageCoder)

- (BOOL)isDecodedForDisplay {
    if (self.images.count > 1) return true;
    NSNumber *num = objc_getAssociatedObject(self, @selector(isDecodedForDisplay));
    return [num boolValue];
}

- (void)setIsDecodedForDisplay:(BOOL)isDecodedForDisplay {
    objc_setAssociatedObject(self, @selector(isDecodedForDisplay), @(isDecodedForDisplay), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

