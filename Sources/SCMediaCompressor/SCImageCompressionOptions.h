#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@class UIColor;
NS_ASSUME_NONNULL_BEGIN
/// 相对目标参考像素的实际评估状态；未评分结果不推断达标。
typedef NS_ENUM(NSInteger, SCImageQualityStatus) {
    SCImageQualityStatusNotEvaluated = 0, ///< 未执行评分，或没有可交付结果。
    SCImageQualityStatusMet, ///< 已评分且达到本次目标。
    SCImageQualityStatusNotMet, ///< 已评分未达目标，必要处理后尽力交付可用资源。
};
/// 静态图片输出格式；Automatic 的 SDR 路径保留透明 PNG，其余选择 JPEG/更小的合格 PNG。
/// 保留 HDR 时 Automatic 在实际支持的 HEIC/增益图 JPEG 中按保真和真实字节择优；Live 固定 JPEG。
typedef NS_ENUM(NSInteger, SCImageFormat) {
    SCImageFormatAutomatic = 0, ///< 按透明度、动画与实际编码体积自动选择。
    SCImageFormatJPEG, ///< 输出 JPEG；透明内容使用 backgroundColor 合成。
    SCImageFormatPNG, ///< 输出无损 PNG；动画输入不自动降为单帧。
    SCImageFormatHEIC, ///< 输出 HEIC，是否保留 HDR 由 preservesHDR 决定。
    SCImageFormatWebP, ///< 输出静态 SDR WebP，保留透明度；HDR 开关开启时仍输出 SDR，不支持动画重编码。
};
/// 一次图片处理的不可变性能快照；仅记录真实操作，不参与压缩策略。
@interface SCImagePerformance : NSObject
/// 实际输入字节；UIImage 无原始编码文件时为 0（未知）。
@property (nonatomic, readonly) unsigned long long inputBytes;
/// 实际交付图片字节；失败或取消为 0，Live 完成时为最终配对 JPEG 字节。
@property (nonatomic, readonly) unsigned long long outputBytes;
/// 是否交付图片；配置回调描述图片阶段，Live 最终状态以 task 为准。
@property (nonatomic, readonly) BOOL succeeded;
/// 图片压缩的 ImageIO/libwebp 编码/写入尝试次数，包含未被选中的候选和失败尝试。
@property (nonatomic, readonly) NSUInteger encodingPassCount;
/// 压缩编码按实际 UTI 分组，例如 public.jpeg、public.png、public.heic、org.webmproject.webp；不含配对重写。
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *encodingCountsByFormat;
/// Live 的 JPEG 配对重写尝试次数；相同 ID 的原字节复制不计入编码。
@property (nonatomic, readonly) NSUInteger pairingEncodingPassCount;
/// 秒：prepare、encode、evaluate、finish、pair、total。total 为这些图片阶段之和。
/// prepare 含识别、解码、缩放、参考像素及其余流程开销；evaluate 含候选解码与已有质量评分。
/// pair 仅含 JPEG 配对处理，排除视频编码、MOV 封装、取源及质量/性能完成回调。
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *stageDurations;
@end

/// 每次压缩独立复制的配置。Live 图片和视频共用 maximumSize、quality 与 preservesHDR。
@interface SCImageCompressionOptions : NSObject <NSCopying>
/// 像素边界，默认 1920×1920；0 轴不限制，始终等比缩小，不放大。
@property (nonatomic) CGSize maximumSize;
/// 源画质保真要求，范围 0…1，默认 0.8；各档有效目标为 0.95×quality，值越高越严格。
/// 分数取结构、局部细节、颜色一致度三项最小值，最高档要求各项均至少 0.95。
/// 所有档位都尝试压缩，1 也在容差内搜索更小结果；不等于编码器参数。
/// 必要尺寸/格式/HDR 处理继续执行且尽力保真，不保证转换无损或主观画质百分比。
/// 在合规候选与实际基线中择小，不为小于源文件追加编码；未达目标按真实评分报告。
@property (nonatomic) CGFloat quality;
/// 本次请求对应的有效保真门槛，包含各档统一的相对容差。
@property (nonatomic, readonly, getter=sc_effectiveQualityTarget) CGFloat effectiveQualityTarget;
/// 输出格式，默认 Automatic；普通图片显式格式优先于 HDR 偏好，Live 图片始终要求 JPEG。
@property (nonatomic) SCImageFormat format;
/// 是否开启 HDR 保留，默认 NO：输出 SDR 并去除增益图；YES 时才尽力保留输入 HDR，不把 SDR 提升为 HDR。
/// Automatic 开启时要求保留 HDR 并在实际支持格式中择优；显式 JPEG/HEIC 尽力保留，能力不足转同格式 SDR。
/// 显式 PNG/WebP 始终输出 SDR；真实输入/编码错误仍失败。Live 继续要求共享 HDR 约束。
@property (nonatomic) BOOL preservesHDR;
/// 是否保留动画，默认 YES；不执行动画重编码或静默丢帧。
/// 保帧 GIF 符合尺寸与 Automatic 格式时返回原始动画，需要不支持的重编码时明确失败。
@property (nonatomic) BOOL preservesAnimation;
/// 显式 JPEG 输出时合成透明内容使用的背景色，默认白色。
@property (nonatomic, strong, nullable) UIColor *backgroundColor;
/// 成功图片的质量诊断；在实际处理队列同步调用，不保证主线程，不得修改正在运行的配置。
/// 评分描述所选资源；Live/HEIC/HDR 使用有界空间采样，普通 JPEG/WebP 使用目标尺寸像素。
/// requestedQuality 为归一化目标；未评估时 fidelityScore 为 nil；达标与 effectiveQualityTarget 比较，不把编码参数作为分数。
@property (nonatomic, copy, nullable) void (^qualityAssessmentHandler)(SCImageQualityStatus status, CGFloat requestedQuality, NSNumber * _Nullable fidelityScore);
/// 图片阶段结束时交付性能快照，成功和失败均调用；实际处理队列，不保证主线程。
/// 不持有像素或媒体内容；Live 此回调包含体积判定前的 JPEG 配对，后续基线配对再由 task 合并。
@property (nonatomic, copy, nullable) void (^performanceHandler)(SCImagePerformance *performance);
@end
NS_ASSUME_NONNULL_END
