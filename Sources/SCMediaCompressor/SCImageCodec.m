#import "SCImageCodec.h"
#import "SCImageCompressionOptions.h"
#import "SCInternal.h"
#import "SCSizePolicy.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#if __has_include(<libwebp/encode.h>)
#import <libwebp/encode.h>
#import <libwebp/mux.h>
#else
#import <webp/encode.h>
#import <webp/mux.h>
#endif

/// 截断有限质量参数并为非有限输入提供回退。
/// @param quality 质量。
/// @param fallback 输入不是有限数值时使用的回退质量。
CGFloat sc_NormalizedQuality(CGFloat quality, CGFloat fallback) {
    return isfinite(quality) ? fmin(1, fmax(0, quality)) : fallback;
}

/// 计算像素边界内且不放大的目标尺寸。
/// @param source 原始素材或像素缓冲。
/// @param bounds 边界。
CGSize sc_TargetSize(CGSize source, CGSize bounds) {
    if (source.width <= 0 || source.height <= 0 || !isfinite(source.width) || !isfinite(source.height)) return CGSizeZero;
    if (!isfinite(bounds.width) || !isfinite(bounds.height) || bounds.width < 0 || bounds.height < 0) return CGSizeZero;
    // factor：本次等比缩放系数。
    double factor = MIN(1, sqrt((double)sc_MaximumDecodedPixels / (source.width * source.height)));
    if (bounds.width > 0) factor = MIN(factor, bounds.width / source.width);
    if (bounds.height > 0) factor = MIN(factor, bounds.height / source.height);
    return CGSizeMake(MAX(1, floor(source.width * factor)), MAX(1, floor(source.height * factor)));
}

/// 按固定参考色域绘制实际像素，避免宽色域经 sRGB 裁剪后再比较。
/// @param image 实际参考或候选。
/// @param size 目标像素或有界评估尺寸。
/// @param referenceSpace 固定的源参考色域；非 RGB 输入回退 sRGB。
NSData *sc_ImagePixels(CGImageRef image, CGSize size, CGColorSpaceRef referenceSpace) {
    if (!image) return nil;
    // width、height：同一参考与候选共享的实际评估几何。
    size_t width=size.width,height=size.height;
    if (!width || !height || width > sc_MaximumDecodedPixels / height) return nil;
    // pixels：本次唯一 RGBA 评估缓冲。
    NSMutableData *pixels=[NSMutableData dataWithLength:width*height*4];
    // colorSpace：以源 RGB 定义解释两份像素，不采用候选自身的 ICC 作为另一套坐标。
    CGColorSpaceRef colorSpace=referenceSpace&&CGColorSpaceGetModel(referenceSpace)==kCGColorSpaceModelRGB ? CGColorSpaceRetain(referenceSpace) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // context：同域、同滤波的实际像素绘制。
    CGContextRef context=CGBitmapContextCreate(pixels.mutableBytes,width,height,8,width*4,colorSpace,kCGBitmapByteOrder32Big|(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;
    CGContextSetBlendMode(context,kCGBlendModeCopy);CGContextSetInterpolationQuality(context,kCGInterpolationHigh);
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);return pixels;
}
/// 提取源 RGB 色域中的完整参考像素。
/// @param image 本次源参考。
NSData *sc_Pixels(CGImageRef image) {
    return image ? sc_ImagePixels(image,CGSizeMake(CGImageGetWidth(image),CGImageGetHeight(image)),CGImageGetColorSpace(image)) : nil;
}

/// 使用 ImageIO 缩略解码并按可用系统接口转换为 SDR。
/// @param source 原始素材或像素缓冲。
/// @param longestSide 最大解码像素长边。
CGImageRef sc_Decode(CGImageSourceRef source, NSUInteger longestSide) CF_RETURNS_RETAINED {
    // options：配置。
    NSMutableDictionary *options = [@{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(longestSide),
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES
    } mutableCopy];
    if (@available(iOS 17.0, *)) {
        options[(__bridge NSString *)kCGImageSourceDecodeRequest] = (__bridge NSString *)kCGImageSourceDecodeToSDR;
    }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
}

/// 使用 ImageIO 生成指定格式的图片编码数据。
/// @param image 图片。
/// @param type 实际媒体或容器类型。
/// @param quality 质量。
/// @param metadata 元数据。
/// @param options 本轮性能累加器及独立回归探针，不增加编码或像素扫描。
NSData *sc_Encode(CGImageRef image, CFStringRef type, double quality, NSDictionary *metadata, SCImageCompressionOptions *options) {
    // data：编码数据。
    NSMutableData *data = [NSMutableData data];
    // dest：ImageIO 编码目标。
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, type, 1, NULL);
    if (!dest) return nil;
    // encodingStarted：真实 ImageIO 写入起点，不额外生成图片。
    NSTimeInterval encodingStarted=sc_BeginImageEncoding(options,(__bridge NSString *)type,quality);
    // properties：属性字典。
    NSMutableDictionary *properties = [metadata mutableCopy] ?: [NSMutableDictionary dictionary];
    properties[(__bridge NSString *)kCGImagePropertyOrientation] = @1;
    if (CFEqual(type, (__bridge CFStringRef)UTTypeJPEG.identifier) || CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier)) properties[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] = @(quality);
    CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)properties);
    // ok：当前操作是否成功。
    BOOL ok = CGImageDestinationFinalize(dest);
    sc_EndImageEncoding(options,encodingStarted);
    CFRelease(dest);
    return ok ? data.copy : nil;
}

/// 将同域预乘像素还原为直通 RGBA，编码并附带实际源 ICC。
/// @param image 已完成方向和几何处理的源参考。
/// @param pixels 同一参考的预乘 RGBA 像素，不重新绘制。
/// @param quality 本次有界搜索的编码参数，独立于保真目标。
/// @param options 本轮编码计数及耗时累加器。
NSData *sc_EncodeWebP(CGImageRef image, NSData *pixels, double quality, SCImageCompressionOptions *options) {
    // width、height：规范允许的尺寸，不静默缩小以适配编码器。
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    if(!width||!height||width>WEBP_MAX_DIMENSION||height>WEBP_MAX_DIMENSION||pixels.length!=width*height*4)return nil;
    // profile：没有 ICC 的设备色域先实际转换到 sRGB，再写入对应描述。
    NSData *profile=CFBridgingRelease(CGColorSpaceCopyICCData(CGImageGetColorSpace(image)));
    if(!profile.length){
        // standard：无配置文件像素的明确编码坐标，不只改标签。
        CGColorSpaceRef standard=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        pixels=sc_ImagePixels(image,CGSizeMake(width,height),standard);
        profile=CFBridgingRelease(CGColorSpaceCopyICCData(standard));CGColorSpaceRelease(standard);
        if(!pixels||!profile.length)return nil;
    }
    // straight：编码器要求非预乘 RGBA，保留真实 alpha。
    NSMutableData *straight=[pixels mutableCopy];
    // rgba：只修改本轮私有像素副本。
    uint8_t *rgba=straight.mutableBytes;
    // i：当前像素起点。
    for(NSUInteger i=0;i<straight.length;i+=4){
        // alpha：透明度为零时隐藏颜色归零，避免除零。
        unsigned alpha=rgba[i+3];
        // channel：只还原颜色，不修改透明度。
        for(NSUInteger channel=0;channel<3;channel++)rgba[i+channel]=alpha?MIN(255,(rgba[i+channel]*255+alpha/2)/alpha):0;
    }
    // encoded：由 libwebp 分配，完成封装后释放。
    uint8_t *encoded=NULL;
    // started：真实编码及封装的统计起点。
    NSTimeInterval started=sc_BeginImageEncoding(options,UTTypeWebP.identifier,quality);
    // length：实际编码字节，失败为零。
    size_t length=WebPEncodeRGBA(rgba,(int)width,(int)height,(int)width*4,(float)(quality*100),&encoded);
    // result：交付源色域描述，不误标宽色域字节。
    NSData *result=nil;
    if(length){
        // bitstream：已完成的真实 WebP 数据。
        WebPData bitstream={encoded,length};
        // mux：附加 ICC，不重新编码图像。
        WebPMux *mux=WebPMuxCreate(&bitstream,1);
        // icc：封装只复制配置文件，不改变色值。
        WebPData icc={profile.bytes,profile.length};
        // assembled：mux 分配的完整容器字节。
        WebPData assembled={NULL,0};
        if(mux&&profile.length&&WebPMuxSetChunk(mux,"ICCP",&icc,1)==WEBP_MUX_OK&&WebPMuxAssemble(mux,&assembled)==WEBP_MUX_OK)result=[NSData dataWithBytes:assembled.bytes length:assembled.size];
        WebPDataClear(&assembled);if(mux)WebPMuxDelete(mux);
    }
    WebPFree(encoded);sc_EndImageEncoding(options,started);return result;
}
