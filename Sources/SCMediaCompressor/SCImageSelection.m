#import "SCImageSelection.h"
#import "SCImageCodec.h"
#import "SCImageCompressionOptions.h"
#import "SCInternal.h"
#import "SCFidelity.h"
#import "SCImageHDR.h"
#import "SCLogger.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// 保存已经取得的同域参考，在最后必要写入后评估真实候选。
/// @param reference 有界参考像素。
/// @param size 参考和候选的统一空间采样尺寸。
/// @param options 本轮配置和统计。
/// @param hdr 是否保留扩展亮度。
/// @param referenceSpace SDR 固定源 RGB 色域；nil 沿用 HDR/既有采样路径。
static void sc_SetFidelityEvaluatorInColorSpace(NSData *reference,CGSize size,SCImageCompressionOptions *options,BOOL hdr,id referenceSpace) {
    options.sc_requiresFidelityEvaluation=YES;
    // weakOptions：评估器不形成配置自持有，也不保留完整大图像素。
    __weak SCImageCompressionOptions *weakOptions=options;
    // data：配对或格式编码后实际待交付的候选字节。
    options.sc_fidelityEvaluator=^NSNumber *(NSData *data){
        // current：仅本轮存在时更新评估统计。
        SCImageCompressionOptions *current=weakOptions;
        if(!data||!reference||!current)return nil;
        // started：包含真实候选解码、采样与保真计算。
        NSTimeInterval started=current.sc_metrics?sc_ImageNow():0;
        // source：真实最终写入文件的只读描述。
        CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);
        // candidate：参考与候选共用最终滤波，不把不同缩略流程的误差当成压缩损失。
        NSData *candidate=nil;
        if(referenceSpace&&!hdr){
            // decoded：配对后候选只解码一次，再绘制到源参考的色域。
            CGImageRef decoded=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;
            candidate=sc_ImagePixels(decoded,size,(__bridge CGColorSpaceRef)referenceSpace);
            if(decoded)CGImageRelease(decoded);
        }else candidate=sc_FidelitySourcePixels(source,size.width,size.height,hdr);
        // score：未知结果绝不冒充达标。
        double score=-1;sc_PassesFidelity(reference,candidate,size.width,size.height,current.quality,&score);
        if(source)CFRelease(source);
        if(current.sc_metrics)[current.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEvaluate];
        return score<0?nil:@(score);
    };
}

/// 保留 HDR/原始源采样入口的既有色域语义。
/// @param reference 同域参考像素。
/// @param size 有界评估尺寸。
/// @param options 本轮配置。
/// @param hdr 是否保留扩展亮度。
void sc_SetFidelityEvaluator(NSData *reference,CGSize size,SCImageCompressionOptions *options,BOOL hdr) {
    sc_SetFidelityEvaluatorInColorSpace(reference,size,options,hdr,nil);
}

/// 从实际参考建立有界的格式/配对后评分，不重新调用绘制或业务渲染。
/// @param image 目标几何与动态范围下的参考。
/// @param options 本轮配置及统计。
/// @param hdr 是否在扩展亮度中比较。
void sc_SetImageFidelityReference(CGImageRef image,SCImageCompressionOptions *options,BOOL hdr) {
    // started：参考采样也属于实际评估成本。
    NSTimeInterval started=options.sc_metrics?sc_ImageNow():0;
    // size：只改变评估空间采样，不改变真实输出尺寸。
    CGSize size=sc_FidelitySampleSize(CGSizeMake(CGImageGetWidth(image),CGImageGetHeight(image)));
    // reference：与最终解码采用相同色域和最终滤波。
    NSData *reference=hdr?sc_FidelityImagePixels(image,size.width,size.height,YES):sc_ImagePixels(image,size,CGImageGetColorSpace(image));
    // referenceSpace：闭包独立持有源 ICC，候选解码色域不能改变评估坐标。
    id referenceSpace=!hdr&&CGImageGetColorSpace(image)?CFBridgingRelease(CGColorSpaceRetain(CGImageGetColorSpace(image))):nil;
    if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEvaluate];
    sc_SetFidelityEvaluatorInColorSpace(reference,size,options,hdr,referenceSpace);
}

/// 在相同输出约束下比较实际完成文件；候选严格更小时才采用，否则交付基准。
/// @param output 既有画质搜索选出的合法候选。
/// @param baseline 可交付的原文件或已经完成的同配置转换结果。
/// @param original 基准是否直接复用原文件。
/// @param options 本轮配置、统计与可选的 Live 配对回调。
/// @param outputScore 候选已有的 JPEG 评分，其他格式为 nil。
/// @param baselineScore 基准已有的 JPEG 评分，不重新扫描原文件。
NSData *sc_SizeGuard(NSData *output, NSData *baseline, BOOL original, SCImageCompressionOptions *options, NSNumber *outputScore, NSNumber *baselineScore) {
    if(!output.length || !baseline.length || (options.sc_cancellationCheck && options.sc_cancellationCheck()))return nil;
    // rawBaseline：配对回调需要先识别本次基准，避免对相同 JPEG 重写两次。
    NSData *rawBaseline=baseline;
    // rawOutput：只有最终字节改变或原本未评分时，才需要重新评估候选。
    NSData *rawOutput=output;
    if(!options.sc_unknownSourceBytes && options.sc_baselineDataHandler)options.sc_baselineDataHandler(rawBaseline);
    // finalizes：最终配对可能重写 JPEG，评分必须描述最终候选。
    BOOL finalizes=options.sc_imageFinalizer!=nil;
    if(finalizes){
        baseline=options.sc_imageFinalizer(rawBaseline,options.sc_metrics);
        output=[output isEqualToData:rawBaseline]?baseline:options.sc_imageFinalizer(output,options.sc_metrics);
    }
    if(!output.length || !baseline.length || (options.sc_cancellationCheck && options.sc_cancellationCheck()))return nil;
    // evaluated：区分缺少评估能力与已经完成的评分，不能把未知结果当作达标。
    BOOL evaluated=options.sc_fidelityEvaluator!=nil || options.sc_requiresFidelityEvaluation;
    if(options.sc_fidelityEvaluator){
        if(!(outputScore && [rawOutput isEqualToData:output]) &&
           (finalizes || ![output isEqualToData:rawBaseline] || !original))outputScore=options.sc_fidelityEvaluator(output);
        if([output isEqualToData:baseline] && (!original||finalizes))baselineScore=outputScore;
        else if(finalizes && !(baselineScore && [rawBaseline isEqualToData:baseline]))baselineScore=options.sc_fidelityEvaluator(baseline);
        options.sc_fidelityEvaluator=nil;
    }
    // started：仅比较与发布元数据，不把 JPEG 配对时间重复计入 finish。
    NSTimeInterval started=options.sc_metrics?sc_ImageNow():0;
    // smaller：等大优先基准，不再要求最终文件严格小于源文件。
    BOOL smaller=output.length<baseline.length;
    // outputMet、baselineMet：先判断保真资格，再在合格资源间择小；无评分的原内容/无损 PNG 可作为合法基线。
    BOOL outputMet=outputScore ? outputScore.doubleValue+1e-9>=sc_EffectiveFidelityTarget(options.quality) : (!evaluated || (original&&!finalizes&&[output isEqualToData:baseline]));
    // baselineMet：基线也须具备对应的保真资格。
    BOOL baselineMet=baselineScore ? baselineScore.doubleValue+1e-9>=sc_EffectiveFidelityTarget(options.quality) : (!finalizes && (!evaluated || original));
    if(outputMet!=baselineMet)smaller=outputMet;
    else if(!outputMet && outputScore && baselineScore)smaller=outputScore.doubleValue>baselineScore.doubleValue;
    if(!baselineMet){
        if(smaller){if(![baseline isEqualToData:output])original=NO;baseline=output;baselineScore=outputScore;}
        output=baseline;outputScore=baselineScore;smaller=NO;
    }
    options.sc_baselineFidelityScore=baselineScore;
    options.sc_fidelityScore=smaller?outputScore:baselineScore;
    if(options.sc_comparisonHandler)options.sc_comparisonHandler(options.sc_unknownSourceBytes?0:baseline.length,options.sc_unknownSourceBytes?NO:!original);
    if(!options.sc_unknownSourceBytes && options.sc_baselineDataHandler)options.sc_baselineDataHandler(baseline);
    if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageFinish];
    return smaller?output:baseline;
}

/// 复用现有像素评分，同一候选只解码一次，不新增普通路径的扫描。
/// @param reference 目标几何下的原始参考像素。
/// @param jpeg 本轮实际编码数据。
/// @param image 只读取目标像素尺寸的原参考。
/// @param options 本轮统计及请求质量。
/// @param score 已有算法给出的实际保真评分。
BOOL sc_EvaluateJPEG(NSData *reference,NSData *jpeg,CGImageRef image,SCImageCompressionOptions *options,double *score) {
    // started：仅记录候选解码、像素转换与既有评分。
    NSTimeInterval started=options.sc_metrics?sc_ImageNow():0;
    // source：本候选的 ImageIO 只读源。
    CGImageSourceRef source=jpeg?CGImageSourceCreateWithData((__bridge CFDataRef)jpeg,NULL):NULL;
    // decoded：本候选实际解码像素。
    CGImageRef decoded=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;
    // candidate：对应的固定格式像素缓冲。
    NSData *candidate=decoded?sc_ImagePixels(decoded,CGSizeMake(CGImageGetWidth(image),CGImageGetHeight(image)),CGImageGetColorSpace(image)):nil;
    // sameSize：评分不能掩盖候选尺寸错误。
    BOOL sameSize=decoded&&CGImageGetWidth(decoded)==CGImageGetWidth(image)&&CGImageGetHeight(decoded)==CGImageGetHeight(image);
    // good：保留原门槛，不为体积目标伪造评分达标。
    BOOL good=sameSize&&sc_PassesFidelity(reference,candidate,CGImageGetWidth(image),CGImageGetHeight(image),options.quality,score);
    if(decoded)CGImageRelease(decoded);if(source)CFRelease(source);
    if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEvaluate];return good;
}

/// 对最终字节只核对格式描述和硬几何，避免回退或配对绕过配置，不新增完整解码。
/// @param data 最终选中的资源。
/// @param options 本次目标几何、格式及 HDR。
/// @param live 是否固定输出 Live JPEG。
BOOL sc_ValidFinalImage(NSData *data,SCImageCompressionOptions *options,BOOL live) {
    if(!data.length)return NO;
    // source：最终文件的真实媒体描述。
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);
    if(!source)return NO;
    // properties：只读取像素和方向，不重新扫描内容。
    NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    // type：实际编码格式，而不是扩展名。
    CFStringRef type=CGImageSourceGetType(source);
    // valid：输出必须匹配本次计算的几何、方向与动态范围。
    BOOL valid=[properties[(__bridge NSString *)kCGImagePropertyPixelWidth]doubleValue]==options.sc_targetSize.width&&[properties[(__bridge NSString *)kCGImagePropertyPixelHeight]doubleValue]==options.sc_targetSize.height&&[properties[(__bridge NSString *)kCGImagePropertyOrientation]integerValue]<=1&&sc_sourceContainsHDR(source)==options.sc_expectsHDR;
    if(live)valid=valid&&type&&CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier);
    else if(options.format==SCImageFormatJPEG)valid=valid&&type&&CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier);
    else if(options.format==SCImageFormatPNG)valid=valid&&type&&CFEqual(type,(__bridge CFStringRef)UTTypePNG.identifier);
    else if(options.format==SCImageFormatWebP)valid=valid&&type&&CFEqual(type,(__bridge CFStringRef)UTTypeWebP.identifier);
    else if(options.format==SCImageFormatHEIC)valid=valid&&type&&CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier);
    else valid=valid&&type&&(options.sc_expectsHDR?(CFEqual(type,(__bridge CFStringRef)UTTypeHEIC.identifier)||CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier)):(CFEqual(type,(__bridge CFStringRef)UTTypeJPEG.identifier)||CFEqual(type,(__bridge CFStringRef)UTTypePNG.identifier)||(options.preservesAnimation&&CFEqual(type,(__bridge CFStringRef)UTTypeGIF.identifier))));
    CFRelease(source);return valid;
}

/// 交付已有质量评分与性能快照，外部回调不计入媒体处理总时长。
/// @param options 本轮配置与已有诊断接收器。
/// @param output 实际选中的图片；nil 表示失败或取消。
void sc_ReportImageDiagnostics(SCImageCompressionOptions *options, NSData *output) {
    // performance：在所有外部完成诊断回调前冻结，不持有媒体内容。
    SCImagePerformance *performance=[options.sc_metrics sc_snapshotWithOutputBytes:output.length succeeded:output.length>0];
    // score：只使用候选搜索已经算出的分数，不重新编码、解码或扫描。
    NSNumber *score=output.length ? options.sc_fidelityScore : nil;
    // status：未评估与未达标必须明确区分。
    SCImageQualityStatus status=score ? (score.doubleValue+1e-9>=sc_EffectiveFidelityTarget(options.quality) ? SCImageQualityStatusMet : SCImageQualityStatusNotMet) : SCImageQualityStatusNotEvaluated;
    sc_log(@"[SCImageCompressor] reference=scaledSource fidelityScore=%@ requested=%.2f target=%.3f targetMet=%@",score ?: @"notEvaluated",(double)options.quality,sc_EffectiveFidelityTarget(options.quality),status==SCImageQualityStatusMet ? @"yes" : status==SCImageQualityStatusNotMet ? @"no" : @"notEvaluated");
    if(options.sc_qualityHandler)options.sc_qualityHandler(status,options.quality,score);
    if(options.sc_performanceHandler)options.sc_performanceHandler(performance);
    if(output.length && options.qualityAssessmentHandler)options.qualityAssessmentHandler(status,options.quality,score);
    if(options.performanceHandler)options.performanceHandler(performance);
}
