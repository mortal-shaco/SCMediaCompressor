#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@class SCImageCompressionOptions;
NS_ASSUME_NONNULL_BEGIN
/// 保存已经取得的同域参考，在最后必要写入后评估真实候选。
FOUNDATION_EXPORT void sc_SetFidelityEvaluator(NSData *reference, CGSize size, SCImageCompressionOptions *options, BOOL hdr);
/// 在相同输出约束下比较实际完成文件；候选严格更小时才采用，否则交付基准。
FOUNDATION_EXPORT NSData * _Nullable sc_SizeGuard(NSData *output, NSData *baseline, BOOL original, SCImageCompressionOptions *options, NSNumber * _Nullable outputScore, NSNumber * _Nullable baselineScore);
/// 复用现有像素评分，同一候选只解码一次。
FOUNDATION_EXPORT BOOL sc_EvaluateJPEG(NSData *reference, NSData *jpeg, CGImageRef image, SCImageCompressionOptions *options, double * _Nullable score);
/// 对最终字节只核对格式描述和硬几何。
FOUNDATION_EXPORT BOOL sc_ValidFinalImage(NSData *data, SCImageCompressionOptions *options, BOOL live);
/// 交付已有质量评分与性能快照。
FOUNDATION_EXPORT void sc_ReportImageDiagnostics(SCImageCompressionOptions *options, NSData * _Nullable output);
NS_ASSUME_NONNULL_END
