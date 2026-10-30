#import "SCCompressionOutcome.h"
@interface SCCompressionOutcome ()
/// 媒体种类。
@property (nonatomic, readwrite) SCCompressionMediaKind mediaKind;
/// 是否交付成功。
@property (nonatomic, readwrite) BOOL succeeded;
/// 比较基线字节。
@property (nonatomic, readwrite) unsigned long long baselineBytes;
/// 交付字节。
@property (nonatomic, readwrite) unsigned long long outputBytes;
/// 是否交付基线。
@property (nonatomic, readwrite) BOOL usedBaseline;
/// 节省比例。
@property (nonatomic, copy, readwrite, nullable) NSNumber *savedRatio;
/// 图片保真状态。
@property (nonatomic, readwrite) SCImageQualityStatus imageQualityStatus;
/// 图片评分。
@property (nonatomic, copy, readwrite, nullable) NSNumber *imageFidelityScore;
/// 视频保真状态。
@property (nonatomic, readwrite) SCVideoQualityStatus videoQualityStatus;
/// 视频评分。
@property (nonatomic, copy, readwrite, nullable) NSNumber *videoFidelityScore;
/// 图片编码次数。
@property (nonatomic, readwrite) NSUInteger imageEncodingPassCount;
/// 视频编码次数。
@property (nonatomic, readwrite) NSUInteger videoEncodingPassCount;
@end
@implementation SCCompressionOutcome
/// 由任务在完成回调前组装，不持有媒体内容。
+ (instancetype)sc_outcomeWithKind:(SCCompressionMediaKind)kind succeeded:(BOOL)succeeded baselineBytes:(unsigned long long)baseline outputBytes:(unsigned long long)output imageQuality:(SCImageQualityStatus)imageQuality imageScore:(NSNumber *)imageScore videoQuality:(SCVideoQualityStatus)videoQuality videoScore:(NSNumber *)videoScore imageEncodes:(NSUInteger)imageEncodes videoEncodes:(NSUInteger)videoEncodes {
    // outcome：只读摘要实例。
    SCCompressionOutcome *outcome=[self new];
    outcome.mediaKind=kind;
    outcome.succeeded=succeeded;
    outcome.baselineBytes=baseline;
    outcome.outputBytes=succeeded?output:0;
    outcome.usedBaseline=succeeded && baseline>0 && outcome.outputBytes>=baseline;
    outcome.savedRatio=(succeeded && baseline>0) ? @((1.0-(double)outcome.outputBytes/(double)baseline)) : nil;
    outcome.imageQualityStatus=succeeded ? imageQuality : SCImageQualityStatusNotEvaluated;
    outcome.imageFidelityScore=succeeded ? imageScore : nil;
    outcome.videoQualityStatus=succeeded ? videoQuality : SCVideoQualityStatusNotEvaluated;
    outcome.videoFidelityScore=succeeded ? videoScore : nil;
    outcome.imageEncodingPassCount=imageEncodes;
    outcome.videoEncodingPassCount=videoEncodes;
    return outcome;
}
@end
