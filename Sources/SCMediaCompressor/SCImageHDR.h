#import <ImageIO/ImageIO.h>
#import "SCImageCompressionOptions.h"
@class UIImage;
/// 检查源文件是否携带 Apple/ISO 增益图或 HDR 像素色彩空间。
FOUNDATION_EXPORT BOOL sc_sourceContainsHDR(CGImageSourceRef source);
/// 检查已解码图片实际携带的 HDR 像素，不推断已丢失的原文件增益图。
FOUNDATION_EXPORT BOOL sc_imageContainsHDR(CGImageRef image);
/// 按目标尺寸解码同一源的 HDR 浮点参考；不支持时为 NULL，调用方负责 CGImageRelease。
FOUNDATION_EXPORT CGImageRef sc_decodeHDRReference(CGImageSourceRef source, CGSize target) CF_RETURNS_RETAINED;
/// 在允许的特殊输出中保留 HDR，无法保留时返回明确错误而不退化为 SDR。
FOUNDATION_EXPORT NSData *sc_preserveHDRSource(CGImageSourceRef source, CGSize target, SCImageCompressionOptions *options, BOOL livePhoto, NSError **error);
/// 编码已携带 HDR 像素的图片，要求 iOS 18 的系统 HDR 编码支持。
FOUNDATION_EXPORT NSData *sc_encodeHDRImage(CGImageRef image, SCImageCompressionOptions *options, BOOL livePhoto, NSError **error);
/// 检测 UIImage 实际携带的 CGImage/CIImage HDR 像素。
FOUNDATION_EXPORT BOOL sc_UIImageContainsHDR(UIImage *image);
/// 按 UIImage 方向及目标边界缩放 HDR 浮点像素，避免经过 8 位 SDR 绘制上下文。
FOUNDATION_EXPORT NSData *sc_preserveHDRUIImage(UIImage *image, CGSize target, SCImageCompressionOptions *options, NSError **error);

/// 构造 HDR 配置冲突或系统能力不足错误。
FOUNDATION_EXPORT NSError *sc_hdrError(NSString *message);
