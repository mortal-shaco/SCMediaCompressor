#import "SCInternal.h"
#import "SCFidelity.h"
/// 按次配置和所有便捷入口共用的固定质量，不提供全局可写状态。
const CGFloat sc_DefaultImageQuality = 0.8;
@implementation SCImageCompressionOptions
/// 系统初始化入口，设置独立的默认配置。
- (instancetype)init {
    if ((self = [super init])) {
        _maximumSize = CGSizeMake(1920, 1920);
        _quality = sc_DefaultImageQuality;
        _format = SCImageFormatAutomatic;
        _preservesAnimation = YES;

    }
    return self;
}
/// NSCopying 系统入口；每次操作捕获独立配置，避免后续配置修改影响进行中的任务。
/// 统一容差后的保真目标，不修改调用方的请求属性。
- (CGFloat)sc_effectiveQualityTarget {return sc_EffectiveFidelityTarget(isfinite(self.quality)?self.quality:sc_DefaultImageQuality);}
/// 复制本次独立配置。
/// @param zone 复制对象使用的分配区域。
- (id)copyWithZone:(NSZone *)zone {
    // 副本：只复制配置，不共享可变任务状态。
    SCImageCompressionOptions *copy = [[[self class] allocWithZone:zone] init];
    copy.maximumSize = self.maximumSize;
    copy.quality = self.quality;
    copy.format = self.format;
    copy.preservesHDR = self.preservesHDR;
    copy.preservesAnimation = self.preservesAnimation;
    copy.backgroundColor = self.backgroundColor;
    copy.qualityAssessmentHandler=self.qualityAssessmentHandler;
    copy.performanceHandler=self.performanceHandler;
    copy.sc_performanceHandler=self.sc_performanceHandler;
    copy.sc_metrics=self.sc_metrics;
    copy.sc_qualityHandler=self.sc_qualityHandler;
    copy.sc_imageEncodingHandler=self.sc_imageEncodingHandler;
    copy.sc_unknownSourceBytes=self.sc_unknownSourceBytes;
    copy.sc_imageFinalizer=self.sc_imageFinalizer;
    copy.sc_cancellationCheck = self.sc_cancellationCheck;
    copy.sc_comparisonHandler = self.sc_comparisonHandler;
    copy.sc_baselineDataHandler = self.sc_baselineDataHandler;
    copy.sc_fidelityEvaluator=self.sc_fidelityEvaluator;copy.sc_requiresFidelityEvaluation=self.sc_requiresFidelityEvaluation;
    return copy;
}
@end

/// 内部可写字段仅在构造不可变快照时赋值。
@interface SCImagePerformance ()
/// 原始实际字节，像素入口未知为 0。
@property (nonatomic, readwrite) unsigned long long inputBytes;
/// 本轮交付字节，失败不伪造结果。
@property (nonatomic, readwrite) unsigned long long outputBytes;
/// 图片阶段或 Live 最终是否交付成功。
@property (nonatomic, readwrite) BOOL succeeded;
/// 实际压缩写入尝试数。
@property (nonatomic, readwrite) NSUInteger encodingPassCount;
/// 按 UTI 区分的真实压缩次数。
@property (nonatomic, copy, readwrite) NSDictionary<NSString *,NSNumber *> *encodingCountsByFormat;
/// JPEG 配对重写尝试数，与普通编码分开。
@property (nonatomic, readwrite) NSUInteger pairingEncodingPassCount;
/// 不共享可变的计时字典。
@property (nonatomic, copy, readwrite) NSDictionary<NSString *,NSNumber *> *stageDurations;
@end
@implementation SCImagePerformance
@end

/// 四种互不重叠的计时类别，快照的公共名称只在此定义。
static NSString *const sc_ImageStageKeys[]={@"encode",@"evaluate",@"finish",@"pair"};
@interface SCImageMetrics ()
/// 保护计数和计时累加，不覆盖媒体处理或外部回调。
@property NSLock *sc_lock;
/// 单调时钟起点。
@property NSTimeInterval sc_started;
/// 本轮实际输入字节。
@property unsigned long long sc_inputBytes;
/// 压缩写入尝试数。
@property NSUInteger sc_encodes;
/// JPEG 配对重写尝试数。
@property NSUInteger sc_pairEncodes;
/// UTI 与压缩写入次数。
@property NSMutableDictionary<NSString *,NSNumber *> *sc_formats;
/// 已经测量的各阶段耗时。
@property NSMutableDictionary<NSString *,NSNumber *> *sc_durations;
@end
@implementation SCImageMetrics
/// 捕获单调起点及输入，内部配置复制不重新初始化。
/// @param bytes 原始实际字节，UIImage 为 0。
- (instancetype)sc_initWithInputBytes:(unsigned long long)bytes {
    if((self=[super init])){_sc_lock=[NSLock new];_sc_started=sc_ImageNow();_sc_inputBytes=bytes;_sc_formats=[NSMutableDictionary new];_sc_durations=[NSMutableDictionary new];}
    return self;
}
/// 记录实际写入开始，包含失败尝试；不在锁中调用 ImageIO。
/// @param type 本次真实编码格式 UTI。
/// @param pairing 是否为 JPEG 配对重写。
- (void)sc_beginEncodingType:(NSString *)type pairing:(BOOL)pairing {
    [self.sc_lock lock];
    if(pairing)self.sc_pairEncodes++;
    else {self.sc_encodes++;self.sc_formats[type]=@([self.sc_formats[type]unsignedIntegerValue]+1);}
    [self.sc_lock unlock];
}
/// 累加已经完成的阶段，非法时长不影响压缩决策。
/// @param seconds 已执行阶段的秒数。
/// @param stage 内部固定阶段类别。
- (void)sc_addDuration:(NSTimeInterval)seconds stage:(SCImagePerformanceStage)stage {
    [self.sc_lock lock];self.sc_durations[sc_ImageStageKeys[stage]]=@([self.sc_durations[sc_ImageStageKeys[stage]]doubleValue]+MAX(0,seconds));[self.sc_lock unlock];
}
/// 返回冻结值，余下时间归 prepare，包含识别/解码/缩放及参考像素准备。
/// @param bytes 真实结果字节，失败时不发布输出。
/// @param succeeded 是否交付本轮结果。
- (SCImagePerformance *)sc_snapshotWithOutputBytes:(unsigned long long)bytes succeeded:(BOOL)succeeded {
    // snapshot：新对象及不可变字典，不向调用方暴露累加器。
    SCImagePerformance *snapshot=[SCImagePerformance new];
    [self.sc_lock lock];
    snapshot.inputBytes=self.sc_inputBytes;snapshot.outputBytes=succeeded?bytes:0;snapshot.succeeded=succeeded;
    snapshot.encodingPassCount=self.sc_encodes;snapshot.pairingEncodingPassCount=self.sc_pairEncodes;snapshot.encodingCountsByFormat=[self.sc_formats copy];
    // durations：互不重叠的阶段，用单调时间核对总量。
    NSMutableDictionary *durations=[NSMutableDictionary new];
    // measured：已在实际操作边界测量的秒数。
    double measured=0;
    // i：固定阶段映射的索引。
    for(NSUInteger i=0;i<sizeof(sc_ImageStageKeys)/sizeof(sc_ImageStageKeys[0]);i++){
        // key：公共名称只取固定映射，避免跨模块复制。
        NSString *key=sc_ImageStageKeys[i];durations[key]=self.sc_durations[key]?:@0;measured+=[durations[key]doubleValue];
    }
    // total：总时长不小于已经完成的阶段之和。
    double total=MAX(measured,sc_ImageNow()-self.sc_started);durations[@"prepare"]=@(total-measured);durations[@"total"]=@(total);snapshot.stageDurations=durations;
    [self.sc_lock unlock];return snapshot;
}
@end

/// 单调时钟避免系统校时导致阶段为负。
NSTimeInterval sc_ImageNow(void) {return NSProcessInfo.processInfo.systemUptime;}
/// 真实写入尝试计数，回归探针不计入编码阶段耗时。
/// @param options 本轮独立配置和累加器。
/// @param type 实际编码 UTI。
/// @param quality 已决定的系统编码质量，不在此修改。
NSTimeInterval sc_BeginImageEncoding(SCImageCompressionOptions *options, NSString *type, double quality) {
    if(options.sc_imageEncodingHandler)options.sc_imageEncodingHandler(type,quality);
    [options.sc_metrics sc_beginEncodingType:type pairing:NO];return options.sc_metrics?sc_ImageNow():0;
}
/// 累加 ImageIO 已执行的写入时间。
/// @param options 本轮配置。
/// @param started 实际编码起点。
void sc_EndImageEncoding(SCImageCompressionOptions *options, NSTimeInterval started) {
    if(options.sc_metrics)[options.sc_metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStageEncode];
}
/// 合并 Live 的 JPEG 配对统计；不计入视频等待或 MOV 重封装时间。
/// @param base 配对前冻结的图片压缩快照，未启动图片处理时为 nil。
/// @param pairing JPEG 实际配对累加器，允许 nil 表示没有配对工作。
/// @param bytes 最终交付的 JPEG 字节。
/// @param succeeded 整组任务是否交付成功。
SCImagePerformance *sc_ImagePerformanceWithPairing(SCImagePerformance *base, SCImageMetrics *pairing, unsigned long long bytes, BOOL succeeded) {
    if(!base)return nil;
    // pair：只读取 JPEG 配对的实际计数与耗时，忽略其跨视频阶段的墙钟总时长。
    SCImagePerformance *pair=[pairing sc_snapshotWithOutputBytes:0 succeeded:NO];
    // snapshot：保留原始输入与编码次数，结果字段按最终交付更新。
    SCImagePerformance *snapshot=[SCImagePerformance new];snapshot.inputBytes=base.inputBytes;snapshot.outputBytes=succeeded?bytes:0;snapshot.succeeded=succeeded;snapshot.encodingPassCount=base.encodingPassCount;snapshot.encodingCountsByFormat=base.encodingCountsByFormat;
    snapshot.pairingEncodingPassCount=base.pairingEncodingPassCount+pair.pairingEncodingPassCount;
    // durations：增加真实 JPEG 配对时间，不重复累计之前的冻结快照。
    NSMutableDictionary *durations=[base.stageDurations mutableCopy];durations[@"pair"]=@([base.stageDurations[@"pair"]doubleValue]+[pair.stageDurations[@"pair"]doubleValue]);durations[@"total"]=@([base.stageDurations[@"total"]doubleValue]+[pair.stageDurations[@"pair"]doubleValue]);snapshot.stageDurations=durations;return snapshot;
}
