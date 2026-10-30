#import <Foundation/Foundation.h>
#import "SCImageCompressionOptions.h"
#import "SCVideoCompressor.h"
#import "SCCompressionOutcome.h"
NS_ASSUME_NONNULL_BEGIN
/// 高层异步入口返回的可取消任务。取消为协作式，系统解码调用返回后再结束清理。
@interface SCCompressionTask : NSObject
/// 线程安全的进度快照；成功时为 1，失败或取消不伪造成功进度。
@property (nonatomic, readonly, getter=sc_progress) double progress;
/// 是否请求过取消，不等于任务已清理完成。
@property (nonatomic, readonly, getter=sc_isCancelled) BOOL cancelled;
/// 是否已经安排唯一终态回调。
@property (nonatomic, readonly, getter=sc_isFinished) BOOL finished;
/// 终态后的体积/质量摘要；完成回调前可读。优先用它判断节省与达标，不必拼多个字段。
@property (atomic, strong, readonly, nullable) SCCompressionOutcome *outcome;
/// 所选图片的实际保真状态；失败/取消、未评分原文件/PNG 为未评估。
/// Live/HEIC/HDR 为有界空间采样，评分描述最终择小前已完成必要写入的资源。
@property (atomic, readonly) SCImageQualityStatus imageQualityStatus;
/// 本次归一化图片质量目标，只在图片处理后读取；视频任务不使用。
@property (atomic, readonly) CGFloat imageRequestedQuality;
/// 图片统一容差后的有效门槛。
@property (atomic, readonly) CGFloat imageEffectiveQualityTarget;
/// 已有候选评分，未评估时为 nil；不是主观画质百分比。
@property (atomic, copy, readonly, nullable) NSNumber *imageFidelityScore;
/// 图片性能快照；未进入图片处理时为 nil。Live 完成后包含 JPEG 配对，不含视频/MOV 工作。
@property (atomic, strong, readonly, nullable) SCImagePerformance *imagePerformance;
/// 本轮实际视频保真请求（Live 取图片配置）。
@property (atomic, readonly) double videoRequestedQuality;
/// 视频统一容差后的有效保真门槛。
@property (atomic, readonly) double videoEffectiveQualityTarget;
/// 最终视频抽样保真状态，不代表逐帧保证。
@property (atomic, readonly) SCVideoQualityStatus videoQualityStatus;
/// 最终视频实际保真评分，未知为 nil；原内容回退为 1、抽样数为 0。
@property (atomic, copy, readonly, nullable) NSNumber *videoFidelityScore;
/// 视频压缩候选在回退前的真实评分，未知为 nil。
@property (atomic, copy, readonly, nullable) NSNumber *videoCandidateFidelityScore;
/// 视频实际保真评估耗时（秒），已计入 stageDurations，不可重复相加。
@property (atomic, readonly) NSTimeInterval videoQualityEvaluationDuration;
/// 视频最终保真评估采用的样本数。
@property (atomic, readonly) NSUInteger videoQualitySampleCount;
/// 视频首次必要转换的实际字节；与图片转换、Live 最终配对基线分开，未转换为 0。
@property (atomic, readonly) unsigned long long videoConversionBytes;
/// 视频实际编码次数，包括必要转换与有界系统重试，不包含无损容器重封装。
/// 不统计图片；图片次数见 imagePerformance.encodingPassCount 或 outcome.imageEncodingPassCount。
@property (atomic, readonly) NSUInteger encodingPassCount;
/// 与 encodingPassCount 相同，名称明确为视频口径。
@property (atomic, readonly) NSUInteger videoEncodingPassCount;
/// 视频分段耗时（秒）；Live 额外包含 image、pair，total 为整个操作，不含下载。
@property (atomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *stageDurations;
/// 实际文件比较基线；视频必要编码转换取真实合规转换结果，Live 为最终配对基线。
/// UIImage/无文件组合素材为 0（未知），不能计算节省比例。
@property (atomic, readonly) unsigned long long comparisonBytes;
/// 图片资源自身的实际预处理前/后基准字节，不包含 Live 视频与配对体积；0 表示未知。
@property (atomic, readonly) unsigned long long imageComparisonBytes;
/// 图片使用已处理基线时为 YES，可包含格式/HDR/几何处理；不独立证明格式变化。
/// 视频转换和 Live 整组配对不改变此图片标记。
@property (atomic, readonly) BOOL imageUsesConvertedBaseline;
/// 是否使用实际处理后的可交付基线；不独立证明格式改变，允许零体积收益。
@property (atomic, readonly) BOOL usesConvertedBaseline;
/// 请求取消，取消后的唯一完成回调返回 NSUserCancelledError。
- (void)sc_cancel;
@end
NS_ASSUME_NONNULL_END
