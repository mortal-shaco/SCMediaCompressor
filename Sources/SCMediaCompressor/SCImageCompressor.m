#import "SCImageCompressor.h"
#import "SCLogger.h"
#import "SCInternal.h"
#import "SCSizePolicy.h"
#import "SCFidelity.h"
#import "SCImageHDR.h"
#import "SCImageCodec.h"
#import "SCImageSelection.h"
#import "SCMediaCompressorError.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// sc_QualitySearchSteps：质量搜索步骤。
static const NSUInteger sc_QualitySearchSteps = 4;
// 默认统计日志由唯一日志入口分发，接入方可替换或关闭。

/// 记录单次图片处理的输入统计并返回操作标识。
/// @param inputBytes 输入字节。
/// @param image 图片。
/// @param quality 质量。
static NSString *sc_CompressionBegin(NSUInteger inputBytes, UIImage *image, CGFloat quality) {
    // identifier：标识。
    NSString *identifier = [NSUUID.UUID.UUIDString substringToIndex:8];
    if (image) {
        // width：宽度。
        size_t width = image.CGImage ? CGImageGetWidth(image.CGImage) : image.size.width * image.scale;
        // height：高度。
        size_t height = image.CGImage ? CGImageGetHeight(image.CGImage) : image.size.height * image.scale;
        sc_log(@"[SCImageCompressor][%@] before inputEncodedBytes=unknown pixels=%zux%zu estimatedRGBABytes=%.0f quality=%.2f", identifier, width, height, (double)width * height * 4, (double)quality);
    } else {
        sc_log(@"[SCImageCompressor][%@] before inputBytes=%lu inputKB=%.2f inputMB=%.3f quality=%.2f", identifier, (unsigned long)inputBytes, inputBytes / 1024.0, inputBytes / (1024.0 * 1024.0), (double)quality);
    }
    return identifier;
}
/// 记录单次图片处理的结果、体积与耗时。
/// @param identifier 标识。
/// @param inputBytes 输入字节。
/// @param output 输出。
/// @param start 起始。
/// @param quality 质量。
static void sc_CompressionEnd(NSString *identifier, NSUInteger inputBytes, NSData *output, CFAbsoluteTime start, CGFloat quality) {
    // saved：本次输出相对输入节省的字节比例。
    NSString *saved = inputBytes ? [NSString stringWithFormat:@"%.2f%%", (1 - (double)output.length / inputBytes) * 100] : @"n/a";
    sc_log(@"[SCImageCompressor][%@] after status=%@ outputBytes=%lu outputKB=%.2f outputMB=%.3f rawSizeChange=%@ elapsed=%.3fs quality=%.2f",
        identifier, output.length ? @"completed" : @"failed", (unsigned long)output.length, output.length / 1024.0, output.length / (1024.0 * 1024.0), output.length ? saved : @"n/a", CFAbsoluteTimeGetCurrent() - start, (double)quality);
}
@implementation SCImageCompressor
+ (BOOL)sc_containsHDRInData:(NSData *)data {
    // source：原始素材或像素缓冲。
    CGImageSourceRef source=data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL) : NULL;
    // hdr：源图是否实际携带 HDR 亮度或增益图。
    BOOL hdr=sc_sourceContainsHDR(source);if(source)CFRelease(source);return hdr;
}
+ (NSData *)sc_compressData:(NSData *)data { return [self sc_compressData:data quality:sc_DefaultImageQuality]; }
+ (NSData *)sc_compressImage:(UIImage *)image { return [self sc_compressImage:image quality:sc_DefaultImageQuality]; }
+ (NSData *)sc_compressLivePhotoData:(NSData *)data { return [self sc_compressLivePhotoData:data quality:sc_DefaultImageQuality]; }
+ (NSData *)sc_compressLivePhotoImage:(UIImage *)image { return [self sc_compressLivePhotoImage:image quality:sc_DefaultImageQuality]; }
+ (NSData *)sc_compressData:(NSData *)data quality:(CGFloat)quality {
    // options：配置。
    SCImageCompressionOptions *options = [SCImageCompressionOptions new]; options.quality = quality;
    return [self sc_compressData:data options:options error:nil];
}
+ (NSData *)sc_compressLivePhotoData:(NSData *)data quality:(CGFloat)quality {
    // options：配置。
    SCImageCompressionOptions *options = [SCImageCompressionOptions new]; options.quality = quality;
    return [self sc_compressLivePhotoData:data options:options error:nil];
}
+ (NSData *)sc_compressImage:(UIImage *)image quality:(CGFloat)quality {
    // options：仅覆盖本次质量，尺寸与其他策略沿用独立配置默认值。
    SCImageCompressionOptions *options = [SCImageCompressionOptions new]; options.quality = quality;
    return [self sc_compressImage:image options:options error:nil];
}
+ (NSData *)sc_compressLivePhotoImage:(UIImage *)image quality:(CGFloat)quality {
    // options：配置。
    SCImageCompressionOptions *options = [SCImageCompressionOptions new]; options.quality = quality; options.format = SCImageFormatJPEG;
    return [self sc_compressImage:image options:options error:nil];
}
+ (NSData *)sc_compressData:(NSData *)data options:(SCImageCompressionOptions *)options error:(NSError **)error {
    return [self sc_loggedData:data options:options livePhoto:NO error:error];
}
+ (NSData *)sc_compressLivePhotoData:(NSData *)data options:(SCImageCompressionOptions *)options error:(NSError **)error {
    // copy：副本。
    SCImageCompressionOptions *copy = [options copy] ?: [SCImageCompressionOptions new]; copy.format = SCImageFormatAutomatic;
    return [self sc_loggedData:data options:copy livePhoto:YES error:error];
}
+ (NSData *)sc_loggedData:(NSData *)data options:(SCImageCompressionOptions *)options livePhoto:(BOOL)livePhoto error:(NSError **)error {
    if(error)*error=nil;
    // copy：副本。
    SCImageCompressionOptions *copy = [options copy] ?: [SCImageCompressionOptions new];
    copy.quality = sc_NormalizedQuality(copy.quality,sc_DefaultImageQuality);
    copy.sc_unknownSourceBytes=NO;
    // start：起始。
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    // identifier：标识。
    NSString *identifier = sc_CompressionBegin(data.length,nil,copy.quality);
    copy.sc_metrics=(copy.performanceHandler||copy.sc_performanceHandler)?[[SCImageMetrics alloc]sc_initWithInputBytes:data.length]:nil;
    // comparison：外部统计只接收最终真实基准，而不是压缩搜索中的中间候选。
    void (^comparison)(unsigned long long,BOOL)=copy.sc_comparisonHandler;
    // baselineBytes、converted：只冻结实际基线；失败保留阶段信息，只有成功才报告节省比例。
    __block unsigned long long baselineBytes=0;__block BOOL converted=NO;
    // bytes、usesConversion：冻结真实基线，尚未承诺交付成功。
    copy.sc_comparisonHandler=^(unsigned long long bytes,BOOL usesConversion){baselineBytes=bytes;converted=usesConversion;};
    // output：保留既有画质搜索，按真实完成字节与合规基准择小。
    NSData *output = [self sc_compressData:data options:copy livePhoto:livePhoto error:error];
    if(comparison&&baselineBytes)comparison(baselineBytes,converted);
    if(output) {
        // finishStarted：只发布完成后的真实比较，不把中间候选当作最终节省。
        NSTimeInterval finishStarted=copy.sc_metrics?sc_ImageNow():0;
        if(baselineBytes)sc_log(@"[SCImageCompressor] comparisonBytes=%llu converted=%@ saved=%.2f%%",baselineBytes,converted?@"yes":@"no",(1-(double)output.length/baselineBytes)*100);
        if(copy.sc_metrics)[copy.sc_metrics sc_addDuration:sc_ImageNow()-finishStarted stage:SCImagePerformanceStageFinish];
    }
    if(output&&!sc_ValidFinalImage(output,copy,livePhoto))output=nil;
    if (!output && error && !*error) *error = [NSError errorWithDomain:SCMediaCompressorErrorDomain code:SCMediaCompressorErrorImageFailed userInfo:@{NSLocalizedDescriptionKey:@"Unsupported image, invalid bounds or animation requires original dimensions"}];
    sc_ReportImageDiagnostics(copy,output);
    sc_CompressionEnd(identifier,data.length,output,start,copy.quality);
    return output;
}
+ (NSData *)sc_compressImage:(UIImage *)image options:(SCImageCompressionOptions *)options error:(NSError **)error {
    if(error)*error=nil;
        // copy：副本。
        SCImageCompressionOptions *copy = [options copy] ?: [SCImageCompressionOptions new];
        copy.quality = sc_NormalizedQuality(copy.quality,sc_DefaultImageQuality);
        copy.sc_unknownSourceBytes=YES;
        // start：起始。
        // identifier：标识。
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent(); NSString *identifier = sc_CompressionBegin(0,image,copy.quality);
        copy.sc_metrics=(copy.performanceHandler||copy.sc_performanceHandler)?[[SCImageMetrics alloc]sc_initWithInputBytes:0]:nil;
        if(copy.preservesHDR && sc_UIImageContainsHDR(image)) {
            // original：原始资源。
            CGSize original=image.CGImage ? CGSizeMake(CGImageGetWidth(image.CGImage),CGImageGetHeight(image.CGImage)) : image.CIImage.extent.size;
            if(image.imageOrientation==UIImageOrientationLeft||image.imageOrientation==UIImageOrientationRight||image.imageOrientation==UIImageOrientationLeftMirrored||image.imageOrientation==UIImageOrientationRightMirrored)original=CGSizeMake(original.height,original.width);
            // target：目标。
            CGSize target=sc_TargetSize(original,copy.maximumSize);
            // result：通过实际 HDR 保留校验的编码数据。
            copy.sc_targetSize=target;copy.sc_expectsHDR=YES;
            // result：本次合法 HDR 实际输出，仍需最终描述检查。
            NSData *result=CGSizeEqualToSize(target,CGSizeZero) ? nil : sc_preserveHDRUIImage(image,target,copy,error);
            if(result && copy.sc_fidelityEvaluator){copy.sc_fidelityScore=copy.sc_fidelityEvaluator(result);copy.sc_fidelityEvaluator=nil;}
            if(copy.sc_comparisonHandler)copy.sc_comparisonHandler(0,NO);
            if(result&&!sc_ValidFinalImage(result,copy,NO)){result=nil;if(error)*error=sc_hdrError(@"Final HDR image violates output constraints");}
            sc_ReportImageDiagnostics(copy,result);sc_CompressionEnd(identifier,0,result,start,copy.quality);return result;
        }
        // reference：参考图像。
        UIImage *reference = [self sc_referenceForImage:image bounds:copy.maximumSize];
        // output：输出。
        copy.sc_targetSize=reference?CGSizeMake(CGImageGetWidth(reference.CGImage),CGImageGetHeight(reference.CGImage)):CGSizeZero;
        // output：使用已经确定的实际参考几何编码。
        NSData *output = reference ? [self sc_encodeReference:reference.CGImage original:nil allowPNG:copy.format!=SCImageFormatJPEG metadata:nil options:copy quality:copy.quality] : nil;
        if(output&&!sc_ValidFinalImage(output,copy,NO))output=nil;
        if (!output && error && !*error) *error = [NSError errorWithDomain:SCMediaCompressorErrorDomain code:SCMediaCompressorErrorImageFailed userInfo:@{NSLocalizedDescriptionKey:@"Image encoding failed"}];
        sc_ReportImageDiagnostics(copy,output);sc_CompressionEnd(identifier,0,output,start,copy.quality); return output;
}
+ (NSData *)sc_compressData:(NSData *)data options:(SCImageCompressionOptions *)options livePhoto:(BOOL)livePhoto error:(NSError **)error {
    // quality：质量。
    CGFloat quality = sc_NormalizedQuality(options.quality, sc_DefaultImageQuality);
        if (!data.length) return nil;
        // source：原始素材或像素缓冲。
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) return nil;
        // properties：属性字典。
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        // sourceSize：原始尺寸。
        CGSize sourceSize = CGSizeMake([properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue],
                                       [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue]);
        // orientation：原图片EXIF方向标记。
        NSUInteger orientation = [properties[(__bridge NSString *)kCGImagePropertyOrientation] unsignedIntegerValue];
        if (orientation >= 5 && orientation <= 8) sourceSize = CGSizeMake(sourceSize.height, sourceSize.width);
        // target：目标。
        CGSize target = sc_TargetSize(sourceSize, options.maximumSize);
        if (CGSizeEqualToSize(target, CGSizeZero)) { CFRelease(source); return nil; }
        options.sc_targetSize=target;
        // type：实际媒体或容器类型。
        CFStringRef type = CGImageSourceGetType(source);
        if (CGImageSourceGetCount(source) > 1 && !livePhoto && type && CFEqual(type, (__bridge CFStringRef)UTTypeGIF.identifier) && options.preservesAnimation) {
            CFRelease(source);
            // 动画默认只原样保留；需要重新编码时明确失败，避免静默丢帧。
            return CGSizeEqualToSize(sourceSize, target) && options.format == SCImageFormatAutomatic ? sc_SizeGuard(data,data,YES,options,nil,nil) : nil;
        }
        // hdr：源图是否实际携带 HDR 亮度或增益图。
        BOOL hdr=sc_sourceContainsHDR(source);
        options.sc_expectsHDR=hdr&&options.preservesHDR;
        if(options.preservesHDR && hdr) {
            options.sc_requiresFidelityEvaluation=YES;
            // result：必要 HDR 转换与请求质量共用一次编码，不生成统计专用文件。
            // started：HDR 参考与实际候选共用解码/最终滤波，也计入评估开销。
            NSTimeInterval started=options.sc_metrics?sc_ImageNow():0;
            // size：有界空间采样尺寸。
            CGSize size=sc_FidelitySampleSize(target);
            // reference：浮点域原内容，不混入另一套预缩略流程。
            NSData *reference=sc_FidelitySourcePixels(source,size.width,size.height,YES);
            if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEvaluate];
            sc_SetFidelityEvaluator(reference,size,options,YES);
            // result：一次真实 HDR 转换与后续同参考保真评估。
            NSData *result=sc_preserveHDRSource(source,target,options,livePhoto,error);
            // jpeg：源文件是否为增益图 JPEG。
            BOOL jpeg=type&&CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier);
            // heic：源文件是否为真实 HEIC。
            BOOL heic=type&&CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier);
            // matchesFormat：只有真实编码符合 HDR 输出格式的源文件才能回退。
            BOOL matchesFormat=(livePhoto||options.format==SCImageFormatJPEG)?jpeg:((options.format==SCImageFormatAutomatic||options.format==SCImageFormatHEIC)&&heic);
            // original：不跳过缩放、方向归一化或动画约束。
            NSData *original=matchesFormat&&CGImageSourceGetCount(source)==1&&(orientation==0||orientation==1)&&CGSizeEqualToSize(sourceSize,target)?data:nil;
            result=sc_SizeGuard(result,original?:result,original!=nil,options,nil,nil);
            CFRelease(source);return result;
        }
        // compatible：原编码是否属于允许直接复用的格式。
        BOOL compatible = type && (CFEqual(type, (__bridge CFStringRef)UTTypeJPEG.identifier) || (!livePhoto && (CFEqual(type, (__bridge CFStringRef)UTTypePNG.identifier) || (options.format==SCImageFormatHEIC && CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier)))));
        // singleImage：输入是否只包含一帧静态图片。
        BOOL singleImage = CGImageSourceGetCount(source) == 1;
        // reference：参考图像。
        CGImageRef reference = sc_Decode(source, MAX(target.width, target.height));
        CFRelease(source);
        if (!reference) return nil;
        options.sc_targetSize=CGSizeMake(CGImageGetWidth(reference),CGImageGetHeight(reference));
        // identifier：标识。
        NSString *identifier = properties[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary][@"17"];
        // metadata：元数据。
        NSDictionary *metadata = identifier ? @{(__bridge NSString *)kCGImagePropertyMakerAppleDictionary : @{@"17":identifier}} : nil;
        // A compatible Live JPEG can keep its original pixels and pairing metadata too.
        // HEIC/HEIF, gain maps, resizing and orientation normalization still require conversion.
        // original：原始资源。
        NSData *original = (options.format == SCImageFormatAutomatic || (options.format == SCImageFormatJPEG && type && CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier)) || (options.format == SCImageFormatPNG && type && CFEqual(type,(__bridge CFStringRef)UTTypePNG.identifier)) || (options.format == SCImageFormatHEIC && type && CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier))) && !hdr && compatible && singleImage && (orientation == 0 || orientation == 1) && CGSizeEqualToSize(sourceSize, target) ? data : nil;
        // result：本次系统操作或编码结果。
        NSData *result = [self sc_encodeReference:reference original:original allowPNG:!livePhoto metadata:metadata options:options quality:quality];
        CGImageRelease(reference);
        return result;
}

+ (UIImage *)sc_referenceForImage:(UIImage *)image bounds:(CGSize)bounds {
    if (!image) return nil;
    // source：原始素材或像素缓冲。
    CGSize source = image.CGImage ? CGSizeMake(CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage))
        : CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
    if (image.imageOrientation == UIImageOrientationLeft || image.imageOrientation == UIImageOrientationRight ||
        image.imageOrientation == UIImageOrientationLeftMirrored || image.imageOrientation == UIImageOrientationRightMirrored) {
        source = CGSizeMake(source.height, source.width);
    }
    // target：目标。
    CGSize target = sc_TargetSize(source, bounds);
    if (CGSizeEqualToSize(target, CGSizeZero)) return nil;
    UIGraphicsBeginImageContextWithOptions(target, NO, 1);
    CGContextSetInterpolationQuality(UIGraphicsGetCurrentContext(), kCGInterpolationHigh);
    [image drawInRect:(CGRect){CGPointZero,target}];
    // result：本次系统操作或编码结果。
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

+ (NSData *)sc_encodeReference:(CGImageRef)image original:(NSData *)original allowPNG:(BOOL)allowPNG
                  metadata:(NSDictionary *)metadata options:(SCImageCompressionOptions *)options quality:(CGFloat)requestedQuality {
    options.sc_fidelityScore=nil;
    if(options.format==SCImageFormatHEIC || options.sc_imageFinalizer)sc_SetImageFidelityReference(image,options,NO);
    if (options.format == SCImageFormatJPEG && (CGImageGetAlphaInfo(image) == kCGImageAlphaPremultipliedLast || CGImageGetAlphaInfo(image) == kCGImageAlphaPremultipliedFirst || CGImageGetAlphaInfo(image) == kCGImageAlphaLast || CGImageGetAlphaInfo(image) == kCGImageAlphaFirst)) {
        // size：尺寸。
        CGSize size = CGSizeMake(CGImageGetWidth(image),CGImageGetHeight(image));
        UIGraphicsBeginImageContextWithOptions(size,YES,1);
        [options.backgroundColor ?: UIColor.whiteColor setFill]; UIRectFill((CGRect){CGPointZero,size});
        [[UIImage imageWithCGImage:image] drawInRect:(CGRect){CGPointZero,size}];
        // flattened：按背景色合成的无透明图片。
        UIImage *flattened = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
        // copy：副本。
        SCImageCompressionOptions *copy = [options copy]; copy.format = SCImageFormatAutomatic;
        // result：铺底后的同一次候选搜索结果，评分仍属于最终选中的 JPEG。
        NSData *result=flattened ? [self sc_encodeReference:flattened.CGImage original:nil allowPNG:NO metadata:metadata options:copy quality:requestedQuality] : nil;
        options.sc_fidelityScore=copy.sc_fidelityScore; return result;
    }
    if (options.format == SCImageFormatHEIC && allowPNG) {
        // converted：请求质量的实际 HEIC 转换结果，像素入口仍报告原文件基准未知。
        NSData *converted=sc_Encode(image,(__bridge CFStringRef)UTTypeHEIC.identifier,sc_FidelityEncodingQuality(requestedQuality),metadata,options);
        return sc_SizeGuard(converted,original?:converted,original!=nil,options,nil,nil);
    }
    if (options.format == SCImageFormatPNG && allowPNG) {
        // png：无损格式无需重复有损压缩。
        NSData *png=sc_Encode(image,(__bridge CFStringRef)UTTypePNG.identifier,1,metadata,options);
        return sc_SizeGuard(png,original ?: png,original!=nil,options,nil,nil);
    }
    if (options.format == SCImageFormatJPEG) allowPNG = NO;
    // reference：参考图像。
    NSData *reference = sc_Pixels(image);
    if (!reference) return nil;
    // pixels：像素缓冲。
    const uint8_t *pixels = reference.bytes;
    // transparent：是否存在非完全不透明的像素。
    BOOL transparent = NO;
    // i：当前循环索引。
    for (NSUInteger i = 3; i < reference.length; i += 4) if (pixels[i] != 255) { transparent = YES; break; }
    if (transparent && !allowPNG) {
        // copy：副本。
        SCImageCompressionOptions *copy=[options copy]; copy.format=SCImageFormatJPEG;
        // result：透明内容铺底后的实际结果，保留内部评分。
        NSData *result=[self sc_encodeReference:image original:nil allowPNG:NO metadata:metadata options:copy quality:requestedQuality];
        options.sc_fidelityScore=copy.sc_fidelityScore; return result;
    }
    // best：已测试且满足目标的最小编码结果。
    NSData *best = nil;
    // maximumQualityJPEG：JPEG 最高质量的可用回退结果。
    NSData *maximumQualityJPEG = nil;
    // fallbackScore：最高质量 JPEG 的校准分数。
    double fallbackScore = -1;
    // bestScore、baselineScore：仅 JPEG 候选实际执行过评分；PNG/原文件不伪造评分。
    NSNumber *bestScore=nil, *baselineScore=nil;
    // Reuse only compatible original data that reproduces the reference pixels; retain original orientation/ICC.
    if (original.length) best = original;
    if (allowPNG) {
        // png：本轮PNG编码数据。
        NSData *png = sc_Encode(image, (__bridge CFStringRef)UTTypePNG.identifier, 1, metadata, options);
        if (png.length && (!best || png.length < best.length)) best = png;
    }
    if (transparent) return sc_SizeGuard(best,original ?: best,original!=nil,options,nil,nil);
    // baseline：原文件或画质搜索期间已经实际产出的必要转换候选。
    NSData *baseline=nil;
    // low：JPEG 搜索的质量下界。
    // high：JPEG 搜索的质量上界。
    double low = 0.20, high = 1.0;
    // step：有限JPEG搜索步骤索引。
    for (NSUInteger step = 0; step <= sc_QualitySearchSteps; step++) {
        if (options.sc_cancellationCheck && options.sc_cancellationCheck()) return nil;
        @autoreleasepool {
            // quality：质量。
            // 首个探测点向严格目标偏移，为接近 1 的区间保留后续细分预算；资格仍由实际评分决定。
            double quality = step == 0 ? 1.0 : (step == 1 ? MAX((low + high)/2,sc_EffectiveFidelityTarget(requestedQuality)) : (low + high)/2);
            // jpeg：本轮JPEG编码数据。
            NSData *jpeg = sc_Encode(image, (__bridge CFStringRef)UTTypeJPEG.identifier, quality, metadata, options);
            if (step == 0) maximumQualityJPEG = jpeg;
            // score：该候选复用原有固定参考评分。
            double score=-1;
            // good：仅描述画质目标，体积目标另外检查。
            BOOL good=sc_EvaluateJPEG(reference,jpeg,image,options,&score);
            if (step == 0) {
                fallbackScore = score;
                baseline=original ?: (best.length && (!good || !jpeg.length || best.length<jpeg.length) ? best : jpeg);
                if(baseline==jpeg && score>=0)baselineScore=@(score);
            }
            if (good) {
                high = quality;
                if ((!best || jpeg.length < best.length)) { best = jpeg; bestScore=@(score); }
            } else {
                if (step == 0) break;
                low = quality;
            }
        }
    }
    // A JPEG-only Live Photo cannot use PNG even if JPEG chroma sampling misses the conservative gate.
    // Keep the maximum-quality JPEG available rather than turn a valid photo into a send failure.
    // result：体积择小后必须报告实际所选候选的已有评分。
    return sc_SizeGuard(best ?: maximumQualityJPEG,baseline,original!=nil,options,best ? bestScore : (fallbackScore>=0 ? @(fallbackScore) : nil),baselineScore);
}

+ (NSString *)sc_fileExtensionForData:(NSData *)data {
    // source：原始素材或像素缓冲。
    CGImageSourceRef source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    // type：实际媒体或容器类型。
    CFStringRef type = source ? CGImageSourceGetType(source) : NULL;
    // suffix：真实编码的扩展名。
    NSString *suffix = type && CFEqual(type,(__bridge CFStringRef)UTTypePNG.identifier) ? @"png" : type && CFEqual(type,(__bridge CFStringRef)UTTypeGIF.identifier) ? @"gif" : type && CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier) ? @"jpg" : type && (CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier) || [[UTType typeWithIdentifier:(__bridge NSString *)type]conformsToType:UTTypeHEIF]) ? @"heic" : @"";
    if (source) CFRelease(source);
    return suffix;
}
+ (NSString *)sc_mimeTypeForData:(NSData *)data {
    // suffix：真实编码的扩展名。
    NSString *suffix = [self sc_fileExtensionForData:data];
    if (!suffix.length) return @"application/octet-stream";
    return [suffix isEqualToString:@"jpg"] ? @"image/jpeg" : [@"image/" stringByAppendingString:suffix];
}
@end
