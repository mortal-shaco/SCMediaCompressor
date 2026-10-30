#import "SCCompressionTask.h"
#import "SCImageCompressionOptions.h"
#import "SCVideoCompressor.h"
#import "SCLivePhotoResourceWriter.h"
/// 图片按次配置与便捷入口共用的固定默认质量。
FOUNDATION_EXPORT const CGFloat sc_DefaultImageQuality;
/// 内部计时类别；名称只在快照构造模块定义，跨模块不复制诊断键。
typedef NS_ENUM(NSUInteger, SCImagePerformanceStage) {
    SCImagePerformanceStageEncode, ///< ImageIO 实际编码写入。
    SCImagePerformanceStageEvaluate, ///< 候选解码与原有质量检查。
    SCImagePerformanceStageFinish, ///< 字节比较和结果选择。
    SCImagePerformanceStagePair, ///< JPEG 配对或原字节复制。
};
/// 每次操作独立的线程安全累加器，递归配置副本共享本轮计数，不跨任务复用。
@interface SCImageMetrics : NSObject
/// 初始化输入实际字节及单调时钟。
- (instancetype)sc_initWithInputBytes:(unsigned long long)bytes __attribute__((objc_method_family(init)));
/// 仅在实际 ImageIO 写入开始时记录尝试，不推算编码次数。
- (void)sc_beginEncodingType:(NSString *)type pairing:(BOOL)pairing;
/// 累加一个已经执行的阶段耗时，不在锁内调用外部代码。
- (void)sc_addDuration:(NSTimeInterval)seconds stage:(SCImagePerformanceStage)stage;
/// 冻结快照，输出为 0 时表示本轮没有交付结果。
- (SCImagePerformance *)sc_snapshotWithOutputBytes:(unsigned long long)bytes succeeded:(BOOL)succeeded;
@end
/// 读取单调时钟，仅用于计时，不参与策略。
FOUNDATION_EXPORT NSTimeInterval sc_ImageNow(void);
/// 在图片实际编码处计数，同时保留回归独立探针，返回计时起点。
FOUNDATION_EXPORT NSTimeInterval sc_BeginImageEncoding(SCImageCompressionOptions *options, NSString *type, double quality);
/// 结束本次编码计时，不重新解码或扫描。
FOUNDATION_EXPORT void sc_EndImageEncoding(SCImageCompressionOptions *options, NSTimeInterval started);
/// 将图片阶段快照与 Live 的实际 JPEG 配对工作合并，原快照保持不变。
FOUNDATION_EXPORT SCImagePerformance *sc_ImagePerformanceWithPairing(SCImagePerformance *base, SCImageMetrics *pairing, unsigned long long bytes, BOOL succeeded);

/// 仅供库内部使用的配置钩子，不随公共头文件发布。
@interface SCImageCompressionOptions ()
/// 本轮累加器，仅入口创建一次，内部递归副本共享。
@property (nonatomic, strong) SCImageMetrics *sc_metrics;
/// 高层复制性能快照到 task，外部回调不会参与统计。
@property (nonatomic, copy) void (^sc_performanceHandler)(SCImagePerformance *);
/// 回归在真实 ImageIO 编码开始处计数；不参与决策，不发布全局状态。
@property (nonatomic, copy) void (^sc_imageEncodingHandler)(NSString *, double);
/// 有损格式必须完成真实评估，能力不足时不能把 nil 分数当作达标。
@property BOOL sc_requiresFidelityEvaluation;
/// 本轮最终输出必须满足的实际目标几何。
@property CGSize sc_targetSize;
/// 目标是否必须保留源 HDR，不能把 SDR 输出当作保留成功。
@property BOOL sc_expectsHDR;
/// 最终可交付基线已有评分，Live 改选基线时复用。
@property (nonatomic, copy) NSNumber *sc_baselineFidelityScore;
/// 为 HEIC/HDR 或 Live 最后一次写入建立的有界保真评估器。
@property (nonatomic, copy) NSNumber *(^sc_fidelityEvaluator)(NSData *);
/// 所选候选已有评分；未评分为 nil。
@property (nonatomic, copy) NSNumber *sc_fidelityScore;
/// 内部终态诊断，包含失败时清空；不增加编码或质量扫描。
@property (nonatomic, copy) void (^sc_qualityHandler)(SCImageQualityStatus, CGFloat, NSNumber *);
/// 像素入口没有可比较的实际压缩前文件。
@property (nonatomic) BOOL sc_unknownSourceBytes;
/// Live 在图片择定前生成最终配对 JPEG，计数进入本轮图片统计并复用结果。
@property (nonatomic, copy) NSData *(^sc_imageFinalizer)(NSData *, SCImageMetrics *);
/// 在 JPEG 候选边界检查取消，避免引入全局任务状态。
@property (nonatomic, copy) BOOL (^sc_cancellationCheck)(void);
/// 将比较基准传回异步任务，不暴露图片内容。
@property (nonatomic, copy) void (^sc_comparisonHandler)(unsigned long long, BOOL);
/// Live 封装阶段需要实际的同格式基准数据，避免只按配对前字节数比较。
@property (nonatomic, copy) void (^sc_baselineDataHandler)(NSData *);
@end
/// Live 封装阶段需要保留实际视频基准，普通导出不额外留下文件。
@interface SCVideoCompressor (SCComparison)
/// 仅移除本轮已发布且身份未被替换的文件。
- (void)sc_removePublishedOutput;
/// 调用方提供的未占用基准路径，生命周期由 Live 任务目录管理。
@property (nonatomic, copy) NSURL *sc_comparisonOutputURL;
/// 最终 MOV 改选原内容基线时同步最终保真诊断。
- (void)sc_useBaselineQuality;
/// 基准是否可在当前视频输出约束下回退。
@property BOOL sc_comparisonBaselineReusable;
@end
/// 高层 Live 调度使用的带性能统计 JPEG 配对入口。
@interface SCLivePhotoResourceWriter (SCPerformance)
/// 内部 JPEG 配对计入性能并直接返回失败原因。
+ (void)sc_writePairedJPEGAtURL:(NSURL *)source toURL:(NSURL *)output identifier:(NSString *)identifier metrics:(SCImageMetrics *)metrics completion:(void (^)(BOOL,NSError *))completion;
@end
/// 任务内部的状态协调接口；外部只持有 SCCompressionTask 的只读状态。
@interface SCCompressionTask (SCInternal)
/// 保存不可变图片性能快照，成功和失败均保留真实已执行工作。
- (void)sc_recordImagePerformance:(SCImagePerformance *)performance;
/// 保存所选最终静态资源的已有评分，不继承落选候选状态。
- (void)sc_recordImageQuality:(SCImageQualityStatus)status requested:(CGFloat)quality score:(NSNumber *)score;
/// 保存视频分段统计及实际编码次数；durations 可以包含 Live 图像和配对耗时。
- (void)sc_recordVideoStatistics:(SCVideoCompressor *)session durations:(NSDictionary<NSString *, NSNumber *> *)durations;
/// 独立记录图片资源基准，不能被后续视频或 Live 整组统计覆盖。
- (void)sc_recordImageComparisonBytes:(unsigned long long)bytes converted:(BOOL)converted;
/// 记录编码器最终选用的体积基准。
- (void)sc_recordComparisonBytes:(unsigned long long)bytes converted:(BOOL)converted;
/// 在终态回调前发布 outcome 摘要。
- (void)sc_publishOutcomeWithKind:(SCCompressionMediaKind)kind outputBytes:(unsigned long long)bytes succeeded:(BOOL)succeeded;
/// 构造异步任务的回调状态。
+ (instancetype)sc_taskWithProgress:(void (^)(double))progress;
/// 安装当前阶段的取消钩子；若已经取消，立即执行该钩子。
- (void)sc_setCancellationHandler:(void (^)(void))handler;
/// 上报单调进度，在主队列通知调用方。
- (void)sc_reportProgress:(double)progress;
/// 原子安排唯一终态回调，在主队列执行，返回本次是否成功取得终态。
- (BOOL)sc_finish:(void (^)(void))completion;
@end
/// 任务内部组装 outcome。
@interface SCCompressionOutcome (SCInternal)
/// 组装终态摘要。
+ (instancetype)sc_outcomeWithKind:(SCCompressionMediaKind)kind succeeded:(BOOL)succeeded baselineBytes:(unsigned long long)baseline outputBytes:(unsigned long long)output imageQuality:(SCImageQualityStatus)imageQuality imageScore:(NSNumber *)imageScore videoQuality:(SCVideoQualityStatus)videoQuality videoScore:(NSNumber *)videoScore imageEncodes:(NSUInteger)imageEncodes videoEncodes:(NSUInteger)videoEncodes;
@end

/// 为已经取得的目标参考像素建立有界评估器，不增加图片编码。
FOUNDATION_EXPORT void sc_SetImageFidelityReference(CGImageRef image, SCImageCompressionOptions *options, BOOL hdr);
