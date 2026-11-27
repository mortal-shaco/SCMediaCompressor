#import "SCVideoCompressor.h"
#import "SCVideoMedia.h"
#import "SCVideoContainer.h"
#import "SCFidelity.h"
#import "SCLogger.h"
/// 一轮导出的诊断；终态后作为该轮完成回调的只读结果使用。
@interface SCVideoExportResult : NSObject
/// 已捕获的交付目标。
@property (nonatomic, copy) NSURL *outputURL;
/// 只有高层视频终态才交付的本轮独占目录。
@property (nonatomic, strong) NSURL *stagedFolder;
/// 已完成、等待高层发布的私有文件。
@property (nonatomic, strong) NSURL *stagedFile;
/// 当前轮次的进度和终态。
@property (atomic) float progress;
/// 当前轮次的公开导出状态。
@property (atomic) AVAssetExportSessionStatus status;
/// 最终系统或配置错误。
@property (atomic, strong) NSError *error;
/// 真实可交付基准的字节。
@property (atomic) unsigned long long comparisonBytes;
/// 首次必要转换的字节。
@property (atomic) unsigned long long conversionBytes;
/// 本轮实际启动的编码次数。
@property (atomic) NSUInteger encodingPassCount;
/// 不可变阶段时长。
@property (atomic, copy) NSDictionary<NSString *, NSNumber *> *stageDurations;
/// 比较基准是否经过必要处理。
@property (atomic) BOOL usesConvertedBaseline;
/// 捕获后归一化的请求质量。
@property (atomic) double requestedQuality;
/// 实际保真评估耗时。
@property (atomic) NSTimeInterval qualityEvaluationDuration;
/// 最终资源的保真状态。
@property (atomic) SCVideoQualityStatus qualityStatus;
/// 选定结果和候选的实际评分。
@property (atomic, copy) NSNumber *fidelityScore;
/// 回退前候选的实际评分。
@property (atomic, copy) NSNumber *candidateFidelityScore;
/// 最终资源的有效评估样本数。
@property (atomic) NSUInteger qualitySampleCount;
@end

/// 在导出入口捕获本轮读取的公开配置，导出队列独占其使用。
@interface SCVideoExportConfiguration : NSObject
/// 高层普通视频由任务终态发布。
@property (nonatomic) BOOL defersPublication;
/// 快照中的目标尺寸。
@property (nonatomic) CGSize maximumSize;
/// 捕获的普通视频保真请求。
@property (nonatomic) double videoQuality;
/// 正常视频配置的帧率上限。
@property (nonatomic) double maximumFrameRate;
/// 显式视频码率。
@property (nonatomic) NSInteger videoBitRate;
/// 请求保留 HDR。
@property (nonatomic) BOOL preservesHDR;
/// 显式声明为 Live 配对视频。
@property (nonatomic) BOOL livePhoto;
/// Live 图片与视频共享的配置。
@property (nonatomic, copy) SCImageCompressionOptions *livePhotoImageOptions;
/// 已选输出容器。
@property (nonatomic, copy) AVFileType outputFileType;
/// 剪辑的源时间范围。
@property (nonatomic) CMTimeRange timeRange;
/// 可选自定义视频合成。
@property (nonatomic, copy) AVVideoComposition *videoComposition;
/// 可选自定义混音。
@property (nonatomic, copy) AVAudioMix *audioMix;
/// 视频解码设置。
@property (nonatomic, copy) NSDictionary *videoInputSettings;
/// 视频写入设置。
@property (nonatomic, copy) NSDictionary *videoOutputSettings;
/// 音频解码设置。
@property (nonatomic, copy) NSDictionary *audioInputSettings;
/// 音频写入设置。
@property (nonatomic, copy) NSDictionary *audioOutputSettings;
/// 顶层元数据编辑。
@property (nonatomic, copy) NSArray<AVMetadataItem *> *metadata;
/// 优化交付文件的头部布局。
@property (nonatomic) BOOL shouldOptimizeForNetworkUse;
/// 由调用方持有的渲染代理。
@property (nonatomic, weak) id<SCVideoCompressorDelegate> delegate;
@end

/// 一条 Live 定时元数据的匹配读写通路。
@interface SCVideoMetadataTrack : NSObject
/// 只读取当前轨道的元数据分组。
@property (nonatomic, strong) AVAssetReaderOutputMetadataAdaptor *reader;
/// 向对应的 writer 输入写入保留分组。
@property (nonatomic, strong) AVAssetWriterInputMetadataAdaptor *writer;
/// 当前轨道标记结束后不再取样。
@property (nonatomic) BOOL finished;
@end

@interface SCVideoCompressor ()
/// 活动或最近一轮的公开诊断。
@property (atomic, strong) SCVideoExportResult *sc_result;
/// 导出队列使用的配置快照。
@property (nonatomic, strong) SCVideoExportConfiguration *sc_configuration;
/// 本轮串行回调交付队列。
@property (nonatomic, strong) dispatch_queue_t sc_deliveryQueue;
/// 调用方是否指定了回调队列，默认完成仍在导出队列。
@property (nonatomic) BOOL sc_hasCallbackQueue;
/// 捕获的进度接收器。
@property (nonatomic, copy) void (^sc_exportProgressHandler)(float);
/// 由导出队列更新公开进度及 KVO。
- (void)sc_setProgress:(float)progress;
/// 发布本轮状态并保持公开属性的 KVO 通知。
- (void)sc_setStatus:(AVAssetExportSessionStatus)status;
/// 高层视频在任务终态锁定后才发布最终文件。
@property (nonatomic) BOOL sc_defersPublication;
/// fullFrameAsset：完整帧素材。
@property (nonatomic, strong) AVAsset *fullFrameAsset;
/// fullFrameSourceURL：完整帧原始URL。
@property (nonatomic, strong) NSURL *fullFrameSourceURL;
/// reader：读取器。
@property (nonatomic, strong) AVAssetReader *reader;
/// writer：写入器。
@property (nonatomic, strong) AVAssetWriter *writer;
/// videoInput：视频输入。
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
/// audioInput：音频输入。
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
/// videoOutput：视频输出。
@property (nonatomic, strong) AVAssetReaderOutput *videoOutput;
/// audioOutput：音频输出。
@property (nonatomic, strong) AVAssetReaderOutput *audioOutput;
/// videoPixelBufferAdaptor：视频像素缓冲Adaptor。
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *videoPixelBufferAdaptor;
/// inputQueue：输入队列。
@property (nonatomic, strong) dispatch_queue_t inputQueue;
/// completionHandler：完成回调回调。
@property (nonatomic, copy) void (^completionHandler)(void);
// Keep an asynchronous export alive even when the caller only retains its completion block.
/// runningSession：运行期间对会话自身的持有，防止提前释放。
@property (nonatomic, strong) SCVideoCompressor *runningSession;
/// 本轮私有目录中的实际写入路径；校验阶段暂指向请求目标。
@property (nonatomic, strong) NSURL *activeOutputURL;
/// mkdtemp 独占创建的目录，失败、取消与重试仅清理其中资源。
@property (nonatomic, strong) NSURL *sc_outputFolder;
/// generation：异步操作代数，用于隔离取消或复用后的旧回调。
@property (nonatomic, assign) NSUInteger generation;
/// retryCount：重试数量。
@property (nonatomic, assign) NSInteger retryCount;
/// videoCompleted：视频Completed。
@property (nonatomic, assign) BOOL videoCompleted;
/// audioCompleted：音频Completed。
@property (nonatomic, assign) BOOL audioCompleted;
/// finishing：写入器是否已开始收尾。
@property (nonatomic, assign) BOOL finishing;
/// 本轮各条保留的 Live 元数据轨道负责自己的读写与完成状态。
@property (nonatomic, strong) NSMutableArray<SCVideoMetadataTrack *> *liveMetadataTracks;
/// 尚未完成写入的 Live 元数据轨道数量。
@property (nonatomic) NSUInteger pendingMetadataTracks;
/// 本轮从显式设置或原素材识别出的 Live 标记。
@property (nonatomic) BOOL sc_exportsLivePhoto;
/// exportDuration：导出时长。
@property (nonatomic, assign) NSTimeInterval exportDuration;
/// exportRange：导出范围。
@property (nonatomic, assign) CMTimeRange exportRange;
/// logIdentifier：log标识。
@property (nonatomic, copy) NSString *logIdentifier;
/// inputFileBytes：输入文件字节。
@property (nonatomic, assign) unsigned long long inputFileBytes;
/// exportStartedAt：导出开始位置。
@property (nonatomic, assign) CFAbsoluteTime exportStartedAt;
/// exportVideoQuality：导出视频质量。
@property (nonatomic, assign, setter=sc_setExportVideoQuality:) double exportVideoQuality;
/// exportMaximumSize：导出最大尺寸。
@property (nonatomic) CGSize exportMaximumSize;
/// exportLivePhotoImageOptions：导出Live静态图图片配置。
@property (nonatomic, copy) SCImageCompressionOptions *exportLivePhotoImageOptions;
/// exportCodec：导出编码格式。
@property (nonatomic, copy) AVVideoCodecType exportCodec;
/// 本轮捕获的 HDR 保留请求，避免异步准备时读取后续配置。
@property BOOL sc_exportPreservesHDR;
/// 仅源为 HDR 且要求保留时启用 10-bit 路径。
@property BOOL sc_exportsHDR;
/// 本轮实际输出色彩，SDR 与 HDR 均固定后供合成、写入与回退校验共用。
@property (nonatomic, copy) NSDictionary *sc_exportColorProperties;
/// exportMaximumFrameRate：导出最大帧速率。
@property (nonatomic) double exportMaximumFrameRate;
/// exportBitRate：导出比特速率。
@property (nonatomic) NSInteger exportBitRate;
/// 是否需要真实编码转换；首次完成结果同时成为合法比较基线。
@property BOOL sc_requiresEncodingConversion;
/// 第一次压缩写入器准备完成的时间。
@property CFAbsoluteTime sc_compressionStartedAt;
/// 压缩写入完成的时间。
@property CFAbsoluteTime sc_compressionFinishedAt;
/// 压缩前的实际原文件或预处理文件。
@property NSURL *sc_sourceBaselineURL;
/// 仅容器变化时使用无损重封装，不重新编码视频。
@property AVAssetExportSession *sc_repackSession;
/// 仅供 Live 最终封装选择时检查基准是否满足输出约束。
@property BOOL sc_comparisonBaselineReusable;
/// Live 操作要求保留的配对前基准路径。
@property (nonatomic, copy) NSURL *sc_comparisonOutputURL;
/// 编码流中取得的有界参考，不重新播放渲染、合成或混音。
@property NSMutableArray<NSDictionary *> *sc_fidelityReferences;
/// 发布唯一终态并清理本轮私有文件。
- (void)sc_completeWithStatus:(AVAssetExportSessionStatus)status error:(NSError *)error;
/// 计算当前策略下的目标像素尺寸。
- (CGSize)sc_formatTargetSize:(CGSize)targetSize;
/// 生成自动视频编码设置。
- (NSDictionary *)sc_configVideoOutput;
/// 生成自动音频编码设置。
- (NSDictionary *)sc_configAudioOutput;
/// 生成视频解码像素格式设置。
- (NSDictionary *)sc_configVideoInput;
/// 生成音频解码设置。
- (NSDictionary *)sc_configAudioInput;
/// 当前实际处理素材，优先完整画幅副本。
- (AVAsset *)sc_processingAsset;
/// 判断兼容 AAC 是否可压缩采样透传。
- (BOOL)sc_canCopyAudioTrack:(AVAssetTrack *)track;
/// 判断合规基线是否可回退。
- (BOOL)sc_canReturnCompressionBaseline;
@end
/// Reader/Writer 导出流水线；实现见 SCVideoCompressor+Export.m。
@interface SCVideoCompressor (SCExport)
/// 启动一次真实 Reader/Writer 导出尝试。
- (void)sc_startAttempt;
/// 准备 Reader/Writer、轨道与 Live 元数据通路。
- (NSError *)sc_prepareExportSession;
@end
/// 保真抽样、体积择小与有界重试；实现见 SCVideoCompressor+Guard.m。
@interface SCVideoCompressor (SCGuard)
/// 完成体积择小、保真评估与交付闸门。
- (void)sc_finishWithSizeGuard;
/// 记录编码输入中的有界保真参考帧。
- (void)sc_captureFidelityReference:(CVPixelBufferRef)buffer time:(CMTime)time;
/// 评估已完成候选的有界保真抽样。
- (void)sc_assessFidelity;
/// 释放本轮 Reader/Writer 资源。
- (void)sc_releaseAttempt;
/// 在瞬态错误边界决定重试或终态失败。
- (void)sc_failAttempt:(NSError *)error;
@end
