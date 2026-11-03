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
    if (options.format==SCImageFormatPNG || options.format==SCImageFormatWebP) {if(error)*error=sc_hdrError(@"HDR preservation supports HEIC or gain-map JPEG; PNG/WebP are not supported by this HDR path");return NULL;}
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
/// 在同一 HDR 源参考中建立候选评估器；高层已有参考时直接复用。
/// @param reference 有界浮点源像素，不使用任何有损候选作参考。
/// @param size 固定评估尺寸。
/// @param options 本轮配置和共享统计。
static void sc_setHDRCandidateReference(NSData *reference, CGSize size, SCImageCompressionOptions *options) {
    options.sc_requiresFidelityEvaluation=YES;
    // weakOptions：评估器不形成配置自持有。
    __weak SCImageCompressionOptions *weakOptions=options;
    // data：实际待比较的编码字节。
    options.sc_fidelityEvaluator=^NSNumber *(NSData *data){
        // current：只累加本轮仍存在的统计。
        SCImageCompressionOptions *current=weakOptions;
        if(!current||!reference||!data)return nil;
        // started：实际解码与保真评估计入评估阶段。
        NSTimeInterval started=current.sc_metrics?sc_ImageNow():0;
        // source：候选真实文件描述。
        CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);
        // candidate：与原参考使用相同浮点采样。
        NSData *candidate=sc_FidelitySourcePixels(source,size.width,size.height,YES);
        // score：不能评估时明确未知，不把编码成功当作达标。
        double score=-1;sc_PassesFidelity(reference,candidate,size.width,size.height,current.quality,&score);
        if(source)CFRelease(source);
        if(current.sc_metrics)[current.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEvaluate];
        return score<0?nil:@(score);
    };
}
/// 只扫描目标参考的 alpha，不改变 HDR 颜色或为格式选择额外编码。
/// @param image 已经完成几何处理的源参考。
static BOOL sc_HDRRequiresAlpha(CGImageRef image) {
    // alpha：没有 alpha 通道的参考无需像素扫描。
    CGImageAlphaInfo alpha=CGImageGetAlphaInfo(image);
    if(alpha==kCGImageAlphaNone||alpha==kCGImageAlphaNoneSkipFirst||alpha==kCGImageAlphaNoneSkipLast)return NO;
    // width、height：本次实际目标像素。
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    // values：只保留透明度，不在 SDR 空间处理 HDR 色值。
    NSMutableData *values=[NSMutableData dataWithLength:width*height];
    // context：无法确定透明度时保守保留 alpha 约束。
    CGContextRef context=CGBitmapContextCreate(values.mutableBytes,width,height,8,width,NULL,(CGBitmapInfo)kCGImageAlphaOnly);
    if(!context)return YES;
    CGContextSetBlendMode(context,kCGBlendModeCopy);CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);
    // bytes：原源实际的 alpha 值。
    const uint8_t *bytes=values.bytes;
    // i：逐目标像素判定，不用有界评分样本猜测透明度。
    for(NSUInteger i=0;i<values.length;i++)if(bytes[i]!=255)return YES;
    return NO;
}
/// 验证候选真实格式、目标几何、方向及 HDR，禁止不合规候选影响排序。
/// @param data 已完成的候选字节。
/// @param target 本次目标显示尺寸。
/// @param format 本次实际编码格式。
/// @param requiresAlpha 源内容是否包含必须保留的透明度。
static BOOL sc_validHDRCandidate(NSData *data, CGSize target, SCImageFormat format, BOOL requiresAlpha) {
    // source：只读候选描述。
    CGImageSourceRef source=data.length?CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL):NULL;
    if(!source)return NO;
    // properties：真实像素与方向。
    NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    // type：实际容器类型。
    CFStringRef type=CGImageSourceGetType(source);
    // valid：全部硬约束通过后才允许按字节比较。
    BOOL valid=type&&CFEqual(type,(__bridge CFStringRef)(format==SCImageFormatJPEG?UTTypeJPEG.identifier:UTTypeHEIC.identifier))&&[properties[(id)kCGImagePropertyPixelWidth]doubleValue]==target.width&&[properties[(id)kCGImagePropertyPixelHeight]doubleValue]==target.height&&[properties[(id)kCGImagePropertyOrientation]integerValue]<=1&&CGImageSourceGetCount(source)==1&&(!requiresAlpha||[properties[(id)kCGImagePropertyHasAlpha]boolValue])&&sc_sourceContainsHDR(source);
    CFRelease(source);return valid;
}
/// 对所有已实现的 HDR 格式各执行既有编码流程，能力不足的格式不阻断其他候选。
/// @param target 统一的目标几何。
/// @param requiresAlpha 不允许用 JPEG 丢弃透明度。
/// @param options 保留原始 Automatic 配置及同源评估器。
/// @param encode 固定源参考的单格式编码，不重放 UIKit 渲染。
/// @param error 所有格式均不可交付时的明确错误。
static NSData *sc_selectAutomaticHDR(CGSize target, BOOL requiresAlpha, SCImageCompressionOptions *options, NSData *(^encode)(SCImageCompressionOptions *,NSError **), NSError **error) {
    if(error)*error=nil;
    options.sc_fidelityScore=nil;
    // best、bestScore：保真优先，其次按实际字节择小；未达标时保留最佳尽力结果。
    NSData *best=nil;NSNumber *bestScore=nil;
    // lastError：仅全部不可用时发布，成功不携带落选格式的错误。
    NSError *lastError=nil;
    // format：当前支持真实 HDR 保留的实现集合，显式格式与 Live 不进入此循环。
    for(NSNumber *format in @[@(SCImageFormatHEIC),@(SCImageFormatJPEG)]){
        if(options.sc_cancellationCheck&&options.sc_cancellationCheck()){options.sc_fidelityEvaluator=nil;return nil;}
        if(requiresAlpha&&format.integerValue==SCImageFormatJPEG)continue;
        @autoreleasepool {
            // candidateOptions：内部固定格式，统计与参考仍共享同一轮。
            SCImageCompressionOptions *candidateOptions=[options copy];candidateOptions.format=format.integerValue;
            // candidateError：单格式能力错误不污染成功结果。
            NSError *candidateError=nil;
            // candidate：复用此格式实际完成结果，不因体积再编码。
            NSData *candidate=encode(candidateOptions,&candidateError);
            if(options.sc_cancellationCheck&&options.sc_cancellationCheck()){options.sc_fidelityEvaluator=nil;return nil;}
            if(!candidate){
                if(candidateError&&(![candidateError.domain isEqual:SCMediaCompressorErrorDomain]||candidateError.code!=SCMediaCompressorErrorConfigurationConflict)){if(error)*error=candidateError;return nil;}
                lastError=candidateError;continue;
            }
            if(!sc_validHDRCandidate(candidate,target,candidateOptions.format,requiresAlpha)){lastError=sc_hdrError(@"HDR candidate violates format, dimensions or orientation constraints");continue;}
            // score：每个候选仅在原 HDR 源参考中评估一次。
            NSNumber *score=options.sc_fidelityEvaluator?options.sc_fidelityEvaluator(candidate):nil;
            // met、bestMet：未知分数不能取得达标资格。
            BOOL met=score&&score.doubleValue+1e-9>=sc_EffectiveFidelityTarget(options.quality);
            // bestMet：当前最佳候选的保真资格。
            BOOL bestMet=bestScore&&bestScore.doubleValue+1e-9>=sc_EffectiveFidelityTarget(options.quality);
            // selectionStarted：只累加实际排序时间，不重复包含编码与评分。
            NSTimeInterval selectionStarted=options.sc_metrics?sc_ImageNow():0;
            // choose：已达标候选只比较字节，未达标时已知评分优先于未知。
            BOOL choose=!best;
            if(best){
                if(met!=bestMet)choose=met;
                else if(!met&&(score||bestScore)&&![score isEqual:bestScore])choose=score&&(!bestScore||score.doubleValue>bestScore.doubleValue);
                else choose=candidate.length<best.length;
            }
            if(choose){best=candidate;bestScore=score;}
            if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-selectionStarted stage:SCImagePerformanceStageFinish];
        }
    }
    options.sc_fidelityScore=bestScore;
    if(!options.sc_imageFinalizer)options.sc_fidelityEvaluator=nil;
    if(!best&&error)*error=lastError?:sc_hdrError(@"No supported encoder can preserve HDR under the requested constraints");
    return best;
}
/// 使用系统 HDR 编码请求生成 HEIC 或 ISO 增益图 JPEG。
/// @param image 真正包含 HDR 像素的图片。
/// @param options 本次保真请求，候选编码参数与实际评估分开。
/// @param livePhoto 是否需要 JPEG 配对资源。
/// @param error 不支持或无法保留 HDR 的原因。
NSData *sc_encodeHDRImage(CGImageRef image, SCImageCompressionOptions *options, BOOL livePhoto, NSError **error) {
    if(options.format==SCImageFormatAutomatic&&!livePhoto&&options.preservesHDR){
        // target：像素入口已经完成必要方向和尺寸处理。
        CGSize target=CGSizeMake(CGImageGetWidth(image),CGImageGetHeight(image));
        if(!options.sc_fidelityEvaluator){
            // started、size、reference：低层入口独立建立一次有界原参考。
            NSTimeInterval started=options.sc_metrics?sc_ImageNow():0;CGSize size=sc_FidelitySampleSize(target);
            // reference：固定源像素的有界 HDR 参考。
            NSData *reference=sc_FidelityImagePixels(image,size.width,size.height,YES);
            if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEvaluate];
            sc_setHDRCandidateReference(reference,size,options);
        }
        // candidateOptions、candidateError：复用同一浮点像素，只改变实际输出格式。
        return sc_selectAutomaticHDR(target,sc_HDRRequiresAlpha(image),options,^NSData *(SCImageCompressionOptions *candidateOptions,NSError **candidateError){return sc_encodeHDRImage(image,candidateOptions,NO,candidateError);},error);
    }
    // type：满足调用方显式格式策略的目标类型。
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
    if(options.format==SCImageFormatAutomatic&&!livePhoto&&options.preservesHDR){
        if(!options.sc_fidelityEvaluator){
            // started、size、reference：高层已准备时复用，否则只从原文件采样一次。
            NSTimeInterval started=options.sc_metrics?sc_ImageNow():0;CGSize size=sc_FidelitySampleSize(target);
            // reference：固定原文件的有界 HDR 参考。
            NSData *reference=sc_FidelitySourcePixels(source,size.width,size.height,YES);
            if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEvaluate];
            sc_setHDRCandidateReference(reference,size,options);
        }
        // decoded：跨格式候选共用一次原源浮点解码，保留 HEIF 的既有辅助图写入路径。
        __block CGImageRef decoded=NULL;
        // properties：只有源描述存在 alpha 时才展开目标像素核对透明度。
        NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
        // requiresAlpha：透明度是硬约束，不能以 JPEG 更小为由丢弃。
        BOOL requiresAlpha=NO;
        if([properties[(id)kCGImagePropertyHasAlpha]boolValue]){decoded=sc_decodeHDRReference(source,target);requiresAlpha=decoded?sc_HDRRequiresAlpha(decoded):YES;}
        // result：所有候选的实际字节与已有评分参与选择。
        NSData *result=sc_selectAutomaticHDR(target,requiresAlpha,options,^NSData *(SCImageCompressionOptions *candidateOptions,NSError **candidateError){
            if(candidateOptions.format==SCImageFormatHEIC)return sc_preserveHDRSource(source,target,candidateOptions,NO,candidateError);
            if(!decoded)decoded=sc_decodeHDRReference(source,target);
            if(!decoded){if(candidateError)*candidateError=sc_hdrError(@"System HDR source decoding is unavailable");return nil;}
            return sc_encodeHDRImage(decoded,candidateOptions,NO,candidateError);
        },error);
        if(decoded)CGImageRelease(decoded);return result;
    }
    // type：由共享显式格式策略选择的目标类型。
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
            if(valid&&sc_validHDRCandidate(data,target,SCImageFormatHEIC,NO))return data;
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
