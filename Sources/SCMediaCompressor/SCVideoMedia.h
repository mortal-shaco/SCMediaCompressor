#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
/// 有界系统瞬态错误的最大重试次数。
static const NSInteger sc_MaximumRetryCount = 1;
/// 写入器一次拉取的样本批次上限。
static const NSUInteger sc_SampleBatchSize = 16;
/// 瞬态错误后的固定重试间隔（秒）。
static const NSTimeInterval sc_RetryDelay = 0.3;
/// 自动候选为最高档预留的码率空间系数。
static const double sc_VideoCompressionHeadroom = .85;
/// 自动 AAC 目标码率上限。
static const NSInteger sc_MaximumAudioBitRate = 96000;
/// 自动 AAC 采样率上限。
static const double sc_MaximumAudioSampleRate = 44100;
/// 普通视频自动码率上限。
static const NSInteger sc_MaximumVideoBitRate = 2496000;
/// 普通视频默认长边像素边界。
static const CGFloat sc_VideoLongSide = 1280;
/// 默认视频保真请求。
static const double sc_DefaultVideoQuality = .8;
/// 构建统一 BT.709 色彩信号，防止 HDR 标记残留到 SDR 输出。
FOUNDATION_EXPORT NSDictionary *sc_SDRColorProperties(void);
/// 输出策略或共享配置不能满足时明确失败，不静默覆盖冲突。
FOUNDATION_EXPORT NSError *sc_VideoConfigurationError(NSString *message);
/// 从真实轨道描述提取 HLG/PQ 色彩，不根据 HEVC 编码或扩展名推断 HDR。
FOUNDATION_EXPORT NSDictionary * _Nullable sc_HDRVideoColorProperties(AVAsset *asset);
/// 完成写入后核对真实 HEVC Main10、位深与 HDR 色彩；同样约束源文件回退。
FOUNDATION_EXPORT BOOL sc_HDRVideoMatches(AVAsset *asset, NSDictionary *colors);
/// 读取 clean aperture 与像素宽高比后的实际显示尺寸。
FOUNDATION_EXPORT CGSize sc_PresentationSize(AVAssetTrack *track);
/// 根据 still-image-time 元数据识别 Live 配对视频。
FOUNDATION_EXPORT BOOL sc_IsLivePhotoAsset(AVAsset *asset);
/// 将系统导出状态映射为稳定统计文本。
FOUNDATION_EXPORT NSString *sc_StatusName(AVAssetExportSessionStatus status);
/// 集中列出必须透传的 Live 关键帧时间与对齐元数据类型。
FOUNDATION_EXPORT NSDictionary *sc_LiveMetadataTypes(void);
/// 构造可交付给调用方的视频导出错误。
FOUNDATION_EXPORT NSError *sc_ExportError(NSString *message);
NS_ASSUME_NONNULL_END
