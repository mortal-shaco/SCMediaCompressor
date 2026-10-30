#import "SCInternal.h"
#import "SCFidelity.h"
#import "SCCompressionOutcome.h"
@interface SCCompressionTask ()
/// 终态体积与质量摘要。
@property (atomic, strong, readwrite) SCCompressionOutcome *outcome;
/// 原子交付不可变图片统计，视频任务不填充。
@property (atomic, strong, readwrite) SCImagePerformance *imagePerformance;
/// 只复制候选搜索的质量状态，不重新读取像素。
@property (atomic, readwrite) SCImageQualityStatus imageQualityStatus;
/// 本轮归一化目标。
@property (atomic, readwrite) CGFloat imageRequestedQuality;
/// 图片本轮有效门槛。
@property (atomic, readwrite) CGFloat imageEffectiveQualityTarget;
/// 所选候选的已有评分。
@property (atomic, copy, readwrite) NSNumber *imageFidelityScore;
/// 状态锁；只在短状态读写期间持有，不在锁内调用外部代码。
@property NSLock *stateLock;
/// 已发布的进度快照。
@property double fraction;
/// 已请求取消的状态。
@property BOOL cancellationRequested;
/// 终态闸门，防止取消与异步完成重复通知。
@property BOOL terminal;
/// 比较基准的线程安全快照。
@property (atomic, readwrite) unsigned long long comparisonBytes;
/// 基准是否包含必要的转换。
@property (atomic, readwrite) BOOL usesConvertedBaseline;
/// 视频首次转换字节的完成快照，不能用它推断图片转换。
@property (atomic, readwrite) unsigned long long videoConversionBytes;
/// 实际编码次数的完成快照。
@property (atomic, readwrite) NSUInteger encodingPassCount;
/// 分段耗时的不可变完成快照。
@property (atomic, copy, readwrite) NSDictionary<NSString *, NSNumber *> *stageDurations;
/// 图片资源的独立实际基准。
@property (atomic, readwrite) unsigned long long imageComparisonBytes;
/// 图片实际发生必要转换的独立标记。
@property (atomic, readwrite) BOOL imageUsesConvertedBaseline;
/// 当前阶段的取消动作。
@property (copy) void (^cancelHandler)(void);
/// 主队列进度接收器。
@property (copy) void (^progressHandler)(double);
/// 本轮请求与有效门槛。
@property (atomic, readwrite) double videoRequestedQuality;
/// 统一容差后的门槛。
@property (atomic, readwrite) double videoEffectiveQualityTarget;
/// 视频评估状态及分数的最终快照。
@property (atomic, readwrite) SCVideoQualityStatus videoQualityStatus;
/// 最终视频分数。
@property (atomic, copy, readwrite) NSNumber *videoFidelityScore;
/// 回退前视频候选分数。
@property (atomic, copy, readwrite) NSNumber *videoCandidateFidelityScore;
/// 视频评估实际耗时，包含在完整总耗时中。
@property (atomic, readwrite) NSTimeInterval videoQualityEvaluationDuration;
/// 最终评估样本数。
@property (atomic, readwrite) NSUInteger videoQualitySampleCount;
@end
@implementation SCCompressionTask
/// 保存已经冻结的计数与耗时，不访问图片或文件。
/// @param performance 图片压缩或 Live 最终统计。
- (void)sc_recordImagePerformance:(SCImagePerformance *)performance {self.imagePerformance=performance;}
/// 保存图片质量快照，终态完成回调前写入。
/// @param status 已达标、未达标或未评估。
/// @param quality 本次目标。
/// @param score 所选候选的已有评分。
- (void)sc_recordImageQuality:(SCImageQualityStatus)status requested:(CGFloat)quality score:(NSNumber *)score {
    self.imageEffectiveQualityTarget=sc_EffectiveFidelityTarget(quality);
    self.imageRequestedQuality=quality; self.imageFidelityScore=score; self.imageQualityStatus=status;
}
/// 复制结束时的诊断统计，不产生额外编码。
/// @param session 已完成的视频会话。
/// @param durations 视频或 Live 的实际分段秒数。
- (void)sc_recordVideoStatistics:(SCVideoCompressor *)session durations:(NSDictionary<NSString *,NSNumber *> *)durations {
    self.videoQualityEvaluationDuration=session.qualityEvaluationDuration;
    self.videoRequestedQuality=session.requestedQuality;self.videoEffectiveQualityTarget=session.effectiveQualityTarget;
    self.videoQualityStatus=session.qualityStatus;self.videoFidelityScore=session.fidelityScore;self.videoCandidateFidelityScore=session.candidateFidelityScore;self.videoQualitySampleCount=session.qualitySampleCount;
    self.videoConversionBytes=session.conversionBytes; self.encodingPassCount=session.encodingPassCount; self.stageDurations=durations ?: @{};
}
/// 保存图片资源统计；后续 Live 整组基准不会覆盖这两个字段。
/// @param bytes 图片资源的实际基准字节，0 表示未知。
/// @param converted 图片资源是否实际经过必要转换。
- (void)sc_recordImageComparisonBytes:(unsigned long long)bytes converted:(BOOL)converted {
    self.imageComparisonBytes=bytes; self.imageUsesConvertedBaseline=converted;
}
/// 保存统计数据，供主队列完成回调和 Demo 读取。
/// @param bytes 基准字节数。
/// @param converted 是否经过转换。
- (void)sc_recordComparisonBytes:(unsigned long long)bytes converted:(BOOL)converted {
    self.comparisonBytes=bytes; self.usesConvertedBaseline=converted;
}
/// 汇总已有统计，供完成回调优先读取。
/// @param kind 本轮媒体种类。
/// @param bytes 实际交付字节。
/// @param succeeded 是否交付成功。
- (void)sc_publishOutcomeWithKind:(SCCompressionMediaKind)kind outputBytes:(unsigned long long)bytes succeeded:(BOOL)succeeded {
    self.outcome=[SCCompressionOutcome sc_outcomeWithKind:kind succeeded:succeeded baselineBytes:self.comparisonBytes outputBytes:bytes imageQuality:self.imageQualityStatus imageScore:self.imageFidelityScore videoQuality:self.videoQualityStatus videoScore:self.videoFidelityScore imageEncodes:self.imagePerformance.encodingPassCount videoEncodes:self.encodingPassCount];
}
/// 明确视频编码次数别名。
- (NSUInteger)videoEncodingPassCount { return self.encodingPassCount; }
/// 创建带锁的异步状态容器。
- (instancetype)init { if ((self=[super init])) { _stateLock=[NSLock new]; _stageDurations=@{}; } return self; }
/// 创建任务并捕获进度回调。
/// @param progress 主队列进度回调。
+ (instancetype)sc_taskWithProgress:(void (^)(double))progress {
    // task：本轮独立状态，不与其他压缩共享。
    SCCompressionTask *task=[self new]; task.progressHandler=progress; return task;
}
/// 读取受锁保护的进度。
- (double)sc_progress { [self.stateLock lock]; double value=self.fraction; [self.stateLock unlock]; return value; }
/// 读取取消请求快照。
- (BOOL)sc_isCancelled { [self.stateLock lock]; BOOL value=self.cancellationRequested; [self.stateLock unlock]; return value; }
/// 读取唯一终态闸门。
- (BOOL)sc_isFinished { [self.stateLock lock]; BOOL value=self.terminal; [self.stateLock unlock]; return value; }
/// 请求当前阶段取消，外部动作始终在锁外执行。
- (void)sc_cancel {
    [self.stateLock lock];
    if (self.terminal || self.cancellationRequested) { [self.stateLock unlock]; return; }
    self.cancellationRequested=YES;
    // handler：当前阶段的取消动作快照。
    void (^handler)(void)=self.cancelHandler;
    [self.stateLock unlock]; if (handler) handler();
}
/// 更新阶段取消动作并处理取消先到达的情况。
/// @param handler 新阶段的取消动作。
- (void)sc_setCancellationHandler:(void (^)(void))handler {
    [self.stateLock lock];
    // cancelled：新阶段是否需要立即停止。
    BOOL cancelled=self.cancellationRequested && !self.terminal;
    if (!self.terminal) self.cancelHandler=handler;
    [self.stateLock unlock]; if (cancelled && handler) handler();
}
/// 发布单调进度并在主队列交付。
/// @param progress 0…1 的阶段累计进度。
- (void)sc_reportProgress:(double)progress {
    [self.stateLock lock];
    if (self.terminal || self.cancellationRequested) { [self.stateLock unlock]; return; }
    self.fraction=MAX(self.fraction,MIN(1,MAX(0,progress)));
    // value：这次交付的单调进度快照。
    double value=self.fraction;
    // callback：调用方提供的进度接收器。
    void (^callback)(double)=self.progressHandler;
    if (callback) dispatch_async(dispatch_get_main_queue(),^{ callback(value); });
    [self.stateLock unlock];
}
/// 原子取得终态，释放取消钩子，避免任务与编码器循环持有。
/// @param completion 主队列唯一终态回调。
- (BOOL)sc_finish:(void (^)(void))completion {
    [self.stateLock lock];
    if (self.terminal) { [self.stateLock unlock]; return NO; }
    self.terminal=YES; self.cancelHandler=nil; self.progressHandler=nil;
    dispatch_async(dispatch_get_main_queue(),completion); [self.stateLock unlock]; return YES;
}
@end
