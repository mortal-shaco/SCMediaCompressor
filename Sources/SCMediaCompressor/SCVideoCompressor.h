#import <AVFoundation/AVFoundation.h>
#import "SCImageCompressionOptions.h"

NS_ASSUME_NONNULL_BEGIN
@class SCVideoCompressor;

/// 可选逐帧渲染接口。实现者负责填满目标 BGRA 像素缓冲，不得释放传入的缓冲。
@protocol SCVideoCompressorDelegate <NSObject>
/// 在导出工作队列处理一帧；时间为裁剪后的相对时间。
/// @param session 当前导出会话。
/// @param pixelBuffer 原始画面缓冲，生命周期仅限本次回调。
/// @param time 裁剪后相对时间。
/// @param outputBuffer 调用方需要写入的目标缓冲。
- (void)sc_exportSession:(SCVideoCompressor *)session renderFrame:(CVPixelBufferRef)pixelBuffer
   withPresentationTime:(CMTime)time toBuffer:(CVPixelBufferRef)outputBuffer;
@end

/// H264/HEVC 视频导出器，默认 SDR，可显式保留 HEVC 的 HLG/PQ HDR。无第三方运行时依赖；一份实例可顺序复用。
/// 导出前配置参数；开始时快照尺寸、质量、格式等默认编码配置。运行时不要修改配置。
/// 真实候选抽样或原内容回退的保真状态，不把码率预算当作评分。
typedef NS_ENUM(NSInteger, SCVideoQualityStatus) {
    SCVideoQualityStatusNotEvaluated=0, ///< 没有完整有效抽样或任务失败。
    SCVideoQualityStatusMet, ///< 达到有效保真目标，或回退到未新增损失的原内容。
    SCVideoQualityStatusNotMet, ///< 必要处理尽力结果没有达到保真目标。
};
@interface SCVideoCompressor : NSObject
/// 自定义像素渲染代理；由调用方持有，默认 nil。
@property (nonatomic, weak, nullable) id<SCVideoCompressorDelegate> delegate;
/// 初始化时传入的原始素材，永不修改或移动。
@property (nonatomic, strong, readonly) AVAsset *asset;
/// 输出文件 URL；必须是未占用的本地路径，禁止与源路径相同。
@property (nonatomic, copy) NSURL *outputURL;
/// 输出封装，默认 AVFileTypeMPEG4；可选择 AVFileTypeQuickTimeMovie（MOV），扩展名应与容器一致。
@property (nonatomic, copy) AVFileType outputFileType;
/// 普通视频的像素边界，默认 1280×1280，单轴为 0 表示该轴不限制；永不放大原画面。
@property (nonatomic) CGSize maximumSize;
/// Live 的 maximumSize、quality、preservesHDR 均取此图片配置；高于视频对应参数，默认 1920×1920、0.8、NO。
@property (nonatomic, copy) SCImageCompressionOptions *livePhotoImageOptions;
/// 明确指定本素材为 Live 配对视频，默认 NO；否则通过 still-image-time 元数据自动识别。
@property (nonatomic) BOOL livePhoto;
/// 是否保留源 HLG/PQ HDR，默认 NO（转 SDR BT.709）；SDR 输入不会变成 HDR。
/// SDR 源始终 H264；HDR 源开启保留时使用 HEVC Main10，否则转 H264/SDR，支持 MP4/MOV；不支持 BGRA 渲染代理或自定义合成器。
/// 保留 10-bit HLG/PQ 像素和色彩，不承诺保留 Dolby Vision 的逐帧动态元数据。
@property (nonatomic) BOOL preservesHDR;
/// 源画质保真要求，范围 0…1，默认 0.8；有效门槛为 0.95×quality，越高要求越严格。
/// 各档均尝试压缩，以结构、局部细节、颜色一致度的最差抽样分数判断，不把编码码率作为保真评分。
/// 自动码率按目标线性缩放，不额外提高源码率；必须转换时尽力保真，不保证转换无损。
/// 不为小于源文件追加降码率编码，属性值不因体积比较改写。
@property (nonatomic, setter=sc_setVideoQuality:) double videoQuality;
/// 默认视频质量 0.8；只读常量，不引入全局可变的视频编码状态。
@property (class, nonatomic, readonly, getter=sc_defaultVideoQuality) double defaultVideoQuality;
/// 显式视频码率，单位 bit/s；0 使用源码率与目标像素面积预算的较小值。
@property (nonatomic) NSInteger videoBitRate;
/// 最大输出帧率，默认 30；不主动提高低帧率素材的帧率。
@property (nonatomic) double maximumFrameRate;
/// 需要导出的源时间段，默认导出全部；同时作用于视频、音频与 Live 时间元数据。
@property (nonatomic) CMTimeRange timeRange;
/// 可选系统视频合成；沿用调用方几何，色彩由 preservesHDR 与源动态范围决定。
@property (nonatomic, copy, nullable) AVVideoComposition *videoComposition;
/// 可选系统音频混音；提供后不透传原始 AAC。
@property (nonatomic, copy, nullable) AVAudioMix *audioMix;
/// 可选视频解码设置；nil 时普通 SDR 使用 NV12，渲染/HDR 转 SDR 使用 BGRA，保留 HDR 使用 10-bit 双平面；HDR 不接受 8-bit 设置。
@property (nonatomic, copy, nullable) NSDictionary *videoInputSettings;
/// 可选完整视频编码设置；尺寸与码率可覆盖自动预算，编码必须与源动态范围和 HDR 策略决定的格式一致。
@property (nonatomic, copy, nullable) NSDictionary *videoOutputSettings;
/// 可选音频解码设置；nil 使用适合现有音频的 PCM 参数。
@property (nonatomic, copy, nullable) NSDictionary *audioInputSettings;
/// 可选音频编码设置；nil 保留兼容 AAC 或使用源声道、采样率转 AAC。
@property (nonatomic, copy, nullable) NSDictionary *audioOutputSettings;
/// 可选顶层元数据；Live 配对所需元数据独立保留。
@property (nonatomic, copy, nullable) NSArray<AVMetadataItem *> *metadata;
/// 是否优化文件头以支持网络播放；不影响上传实现，默认 NO。
@property (nonatomic) BOOL shouldOptimizeForNetworkUse;
/// 可选回调队列；nil 时完成回调在导出工作队列，进度在全局工作队列。
@property (nonatomic, strong, nullable) dispatch_queue_t callbackQueue;
/// 可选单调进度回调，范围 0…1；完成、失败或取消只产生一次终态回调。
@property (nonatomic, copy, nullable) void (^progressHandler)(float progress);
/// 实际比较基线：原文件或必要转换的实际结果；无原文件素材为 0。
/// 候选严格更小时采用，否则返回合规基线；转换允许比源文件大。
@property (atomic, readonly) unsigned long long comparisonBytes;
/// 首次完成的必要转换实际字节，包含当次请求质量的压缩；无转换为 0。
@property (atomic, readonly) unsigned long long conversionBytes;
/// 本轮视频编码次数，包含必要转换及有界系统错误重试；普通编码通常为 1。
@property (atomic, readonly) NSUInteger encodingPassCount;
/// 分段秒数：prepare、compress、finish、total；结束时发布，不包含相册下载。
@property (atomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *stageDurations;
/// 是否使用实际转换或必要处理后的基线，不根据相对源文件是否增长决定。
@property (atomic, readonly) BOOL usesConvertedBaseline;
/// 当前进度，支持 KVO；成功完成后为 1。
@property (atomic, readonly, getter=sc_progress) float progress;
/// 与系统 AVAssetExportSessionStatus 相同的导出状态。
@property (atomic, readonly) AVAssetExportSessionStatus status;
/// 最近一次失败的错误；取消时可以为 nil，应结合 status 判断。
@property (nonatomic, strong, readonly, nullable, getter=sc_error) NSError *error;
/// 创建指定素材的导出会话。
/// @param asset 可读取的视频素材，允许本地 AVURLAsset 或 AVComposition。
+ (instancetype)sc_exportSessionWithAsset:(AVAsset *)asset;
/// 初始化指定素材；使用显式 init 方法族，保证 ARC 对实例所有权的正确处理。
/// @param asset 需要导出的视频素材。
- (instancetype)sc_initWithAsset:(AVAsset *)asset __attribute__((objc_method_family(init)));
/// 异步开始导出，重复使用正在运行的实例会先取消上一轮。
/// @param handler 唯一终态回调；通过 status、error 与 outputURL 读取结果。
- (void)sc_exportAsynchronouslyWithCompletionHandler:(void (^)(void))handler;
/// 请求取消当前导出，清理本次临时文件与未完成输出，不删除源文件。
- (void)sc_cancelExport;
/// 本轮捕获的请求质量，只在导出开始后读取；Live 使用图片配置。
@property (nonatomic, readonly, getter=sc_requestedQuality) double requestedQuality;
/// 本轮统一容差后的有效门槛。
@property (nonatomic, readonly, getter=sc_effectiveQualityTarget) double effectiveQualityTarget;
/// 实际参考采样与输出评估耗时（秒），已包含在 stageDurations，不可重复相加。
@property (atomic, readonly) NSTimeInterval qualityEvaluationDuration;
/// 最终交付资源的保真状态；视频为代表性空间/时间抽样，不是全帧保证。
@property (atomic, readonly) SCVideoQualityStatus qualityStatus;
/// 最终最差抽样分数；未知为 nil，原内容基线回退为 1 且抽样数为 0。
@property (atomic, copy, readonly, nullable) NSNumber *fidelityScore;
/// 压缩候选在回退前的评分，避免把回退成功误认为候选达标。
@property (atomic, copy, readonly, nullable) NSNumber *candidateFidelityScore;
/// 最终交付资源的有效抽样帧数；原内容基线为 0。
@property (atomic, readonly) NSUInteger qualitySampleCount;
@end
NS_ASSUME_NONNULL_END
