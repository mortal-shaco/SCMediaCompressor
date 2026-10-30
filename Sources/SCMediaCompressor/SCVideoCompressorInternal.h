#import "SCVideoCompressor.h"
#import "SCVideoMedia.h"
#import "SCVideoContainer.h"
#import "SCFidelity.h"
#import "SCLogger.h"
@interface SCVideoCompressor ()
/// progress：进度。
@property (atomic, assign, readwrite, getter=sc_progress, setter=sc_setProgress:) float progress;
/// fullFrameAsset：完整帧素材。
@property (nonatomic, strong) AVAsset *fullFrameAsset;
/// fullFrameSourceURL：完整帧原始URL。
@property (nonatomic, strong) NSURL *fullFrameSourceURL;
/// status：状态。
@property (atomic, assign, readwrite) AVAssetExportSessionStatus status;
/// exportError：导出错误。
@property (atomic, strong) NSError *exportError;
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
/// 本轮最终交付路径，只在成功时以不覆盖的原子链接发布。
@property (nonatomic, strong) NSURL *sc_destinationURL;
/// mkdtemp 独占创建的目录，失败、取消与重试仅清理其中资源。
@property (nonatomic, strong) NSURL *sc_outputFolder;
/// 已发布文件的设备号和 inode，用于高层取消时核对文件所有权。
@property (nonatomic, copy) NSDictionary *sc_publishedIdentity;
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
/// liveMetadataOutputs：Live元数据Outputs。
@property (nonatomic, strong) NSMutableArray<AVAssetReaderTrackOutput *> *liveMetadataOutputs;
/// liveMetadataInputs：Live元数据Inputs。
@property (nonatomic, strong) NSMutableArray<AVAssetWriterInput *> *liveMetadataInputs;
/// completedMetadataInputs：completed元数据Inputs。
@property (nonatomic, strong) NSMutableSet<AVAssetWriterInput *> *completedMetadataInputs;
/// liveMetadataReaders：Live元数据Readers。
@property (nonatomic, strong) NSMutableArray<AVAssetReaderOutputMetadataAdaptor *> *liveMetadataReaders;
/// liveMetadataWriters：Live元数据Writers。
@property (nonatomic, strong) NSMutableArray<AVAssetWriterInputMetadataAdaptor *> *liveMetadataWriters;
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
@property (nonatomic, assign) double exportVideoQuality;
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
/// 首次必要转换的实际字节；只记录首个完成结果，不随重试漂移。
@property (atomic, readwrite) unsigned long long conversionBytes;
/// 最终比较基准的体积。
@property (atomic, readwrite) unsigned long long comparisonBytes;
/// 是否采用必要转换或无损重封装后实际产出的文件作为基准。
@property (atomic, readwrite) BOOL usesConvertedBaseline;
/// 本轮实际启动的编码次数。
@property (atomic, readwrite) NSUInteger encodingPassCount;
/// 结束时发布的分段耗时。
@property (atomic, copy, readwrite) NSDictionary<NSString *, NSNumber *> *stageDurations;
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
/// 本轮抽样最差保真评分，未知保持 nil。
@property (atomic, copy, readwrite) NSNumber *fidelityScore;
/// 落选前的实际候选评分，用于区分回退与候选达标。
@property (atomic, copy, readwrite) NSNumber *candidateFidelityScore;
/// 本轮实际保真捕获与评估耗时，已包含在完整阶段总耗时中。
@property (atomic, readwrite) NSTimeInterval qualityEvaluationDuration;
/// 最终交付资源的保真状态。
@property (atomic, readwrite) SCVideoQualityStatus qualityStatus;
/// 最终资源实际采用的抽样帧数，原内容回退时为 0。
@property (atomic, readwrite) NSUInteger qualitySampleCount;
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
