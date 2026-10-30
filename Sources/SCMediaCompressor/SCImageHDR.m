#import "SCImageHDR.h"
#import "SCInternal.h"
#import "SCFidelity.h"
#import "SCMediaCompressorError.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// 输出不能满足调用方明确要求时，不静默改变 HDR 或格式策略。
/// @param message 配置冲突或系统能力不足的说明。
NSError *sc_hdrError(NSString *message) {
    return [NSError errorWithDomain:SCMediaCompressorErrorDomain code:SCMediaCompressorErrorConfigurationConflict userInfo:@{NSLocalizedDescriptionKey:message}];
}
/// 检测已解码图片是否实际声明了 HDR 色彩空间或内容亮度范围。
/// @param image 待检测的图片；NULL 返回 NO。
BOOL sc_imageContainsHDR(CGImageRef image) {
    if (!image) return NO;
    // space：图片实际色彩空间。
    CGColorSpaceRef space=CGImageGetColorSpace(image);
    if (space && (CGColorSpaceIsPQBased(space) || CGColorSpaceIsHLGBased(space))) return YES;
    if (@available(iOS 18.0,*)) return CGImageGetContentHeadroom(image)>1;
    return NO;
}
/// 检测 Apple 和 ISO 增益图；否则检查原始像素的 HDR 声明，不完整解码大图。
/// @param source 已创建的 ImageIO 源。
BOOL sc_sourceContainsHDR(CGImageSourceRef source) {
    if (!source) return NO;
    // gain：Apple HDR 增益图描述，仅用于判断是否存在。
    CFDictionaryRef gain=CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeHDRGainMap);
    if (gain) {CFRelease(gain);return YES;}
    if (@available(iOS 18.0,*)) {
        gain=CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeISOGainMap);
        if (gain) {CFRelease(gain);return YES;}
    }
    // image：不缓存全图像素的源图描述。
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO,(__bridge NSString *)kCGImageSourceShouldAllowFloat:@YES});
    // hdr：原始图片是否具有 HDR 像素声明。
    BOOL hdr=sc_imageContainsHDR(image);if(image)CGImageRelease(image);return hdr;
}
/// 根据配置选出能够承载 HDR 的输出格式。
/// @param options 本次图片配置。
/// @param livePhoto Live 静态图要求 JPEG。
/// @param error 配置冲突输出。
static CFStringRef sc_hdrDestinationType(SCImageCompressionOptions *options, BOOL livePhoto, NSError **error) {
    if (!options.preservesHDR) {if(error)*error=sc_hdrError(@"HDR preservation requires preservesHDR=YES");return NULL;}
    if (options.format==SCImageFormatPNG) {if(error)*error=sc_hdrError(@"HDR preservation supports HEIC or gain-map JPEG; PNG is not supported by this HDR path");return NULL;}
    return (__bridge CFStringRef)(livePhoto || options.format==SCImageFormatJPEG ? UTTypeJPEG.identifier : UTTypeHEIC.identifier);
}
/// 检查重新编码结果确实携带 HDR；失败时不把 SDR 数据冒充 HDR 交付。
/// @param data 候选编码结果。
static BOOL sc_encodedHasHDR(NSData *data) {
    // source：候选结果对应的只读 ImageIO 源。
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);
    // hdr：候选是否仍保留 HDR。
    BOOL hdr=sc_sourceContainsHDR(source);if(source)CFRelease(source);return hdr;
}
/// 使用系统 HDR 编码请求生成 HEIC 或 ISO 增益图 JPEG。
/// @param image 真正包含 HDR 像素的图片。
/// @param options 本次保真请求，候选编码参数与实际评估分开。
/// @param livePhoto 是否需要 JPEG 配对资源。
/// @param error 不支持或无法保留 HDR 的原因。
NSData *sc_encodeHDRImage(CGImageRef image, SCImageCompressionOptions *options, BOOL livePhoto, NSError **error) {
    // type：满足调用方格式策略的目标类型。
    CFStringRef type=sc_hdrDestinationType(options,livePhoto,error);if(!type)return nil;
    if (@available(iOS 18.0,*)) {
        // data：仅在本次操作中持有的编码缓冲。
        NSMutableData *data=[NSMutableData data];
        // destination：系统 HDR 图片写入器。
        CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,type,1,NULL);
        if(!destination){if(error)*error=sc_hdrError(@"System HDR image encoder is unavailable");return nil;}
        // properties：显式要求 ISO HDR/增益图，禁止以 SDR 回退冒充成功。
        NSDictionary *properties=@{(__bridge NSString *)kCGImageDestinationEncodeRequest:(__bridge NSString *)(CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier) ? kCGImageDestinationEncodeToISOGainmap : kCGImageDestinationEncodeToISOHDR),(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@(sc_FidelityEncodingQuality(options.quality)),(__bridge NSString *)kCGImagePropertyOrientation:@1};
        // encodingStarted：只测量系统实际写入，不追加转换文件。
        NSTimeInterval encodingStarted=sc_BeginImageEncoding(options,(__bridge NSString *)type,sc_FidelityEncodingQuality(options.quality));
        CGImageDestinationAddImage(destination,image,(__bridge CFDictionaryRef)properties);
        // valid：编码成功且 HDR 仍存在。
        BOOL valid=CGImageDestinationFinalize(destination);sc_EndImageEncoding(options,encodingStarted);CFRelease(destination);
        if(valid&&sc_encodedHasHDR(data))return data;
        if(error)*error=sc_hdrError(@"System encoder could not retain HDR; no SDR fallback was returned");return nil;
    }
    if(error)*error=sc_hdrError(@"This HDR pixel conversion requires iOS 18 or later");return nil;
}
/// 为必要 HDR 转换或体积收敛提供同一原源的浮点参考，不经过 SDR 绘制。
/// @param source 原始 HDR 编码源，不能传上一轮有损候选。
/// @param target 已按方向计算的目标边界，不改变压缩尺寸要求。
CGImageRef sc_decodeHDRReference(CGImageSourceRef source, CGSize target) {
    if(@available(iOS 18.0,*))return CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@(MAX(target.width,target.height)),(__bridge NSString *)kCGImageSourceShouldAllowFloat:@YES,(__bridge NSString *)kCGImageSourceDecodeRequest:(__bridge NSString *)kCGImageSourceDecodeToHDR});
    return NULL;
}
/// 保留原始 HEIF 增益图并同步缩放；跨格式时使用明确的系统 HDR 解码与编码。
/// @param source 原始只读 ImageIO 源。
/// @param target 已计算且不放大的目标像素范围。
/// @param options 本轮静态图配置。
/// @param livePhoto Live JPEG 配对约束。
/// @param error 不能满足配置时的错误。
NSData *sc_preserveHDRSource(CGImageSourceRef source, CGSize target, SCImageCompressionOptions *options, BOOL livePhoto, NSError **error) {
    // type：由共享格式策略选择的目标类型。
    CFStringRef type=sc_hdrDestinationType(options,livePhoto,error);if(!type)return nil;
    // originalType：原始编码类型，用于判断能否直接保留 HEIF 增益图。
    CFStringRef originalType=CGImageSourceGetType(source);
    // heif：源数据是否属于 HEIF/HEIC。
    BOOL heif=originalType && (CFEqual(originalType,(__bridge CFStringRef)UTTypeHEIC.identifier) || [[UTType typeWithIdentifier:(__bridge NSString *)originalType]conformsToType:UTTypeHEIF]);
    if(heif&&CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier)) {
        // data：本次 HEIC 结果缓冲。
        NSMutableData *data=[NSMutableData data];
        // destination：保留源辅助增益图的系统写入器。
        CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,type,1,NULL);
        if(destination){
            // encodingStarted：保留增益图路径的实际写入时间和尝试次数。
            NSTimeInterval encodingStarted=sc_BeginImageEncoding(options,(__bridge NSString *)type,sc_FidelityEncodingQuality(options.quality));
            CGImageDestinationAddImageFromSource(destination,source,0,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationPreserveGainMap:@YES,(__bridge NSString *)kCGImageDestinationImageMaxPixelSize:@(MAX(target.width,target.height)),(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@(sc_FidelityEncodingQuality(options.quality))});
            // valid：辅助图与编码结果均实际保留 HDR。
            BOOL valid=CGImageDestinationFinalize(destination);sc_EndImageEncoding(options,encodingStarted);CFRelease(destination);
            if(valid&&sc_encodedHasHDR(data))return data;
        }
    }
    if(@available(iOS 18.0,*)) {
        // decoded：明确展开 HDR 后按目标大小解码的参考图。
        CGImageRef decoded=sc_decodeHDRReference(source,target);
        // output：只有能保留 HDR 的编码结果才会返回。
        NSData *output=decoded ? sc_encodeHDRImage(decoded,options,livePhoto,error) : nil;
        if(decoded)CGImageRelease(decoded);if(output)return output;
    }
    if(error&&!*error)*error=sc_hdrError(@"HDR cannot be preserved for this format and OS combination");return nil;
}
