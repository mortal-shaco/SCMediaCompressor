#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
@class SCImageCompressionOptions;
NS_ASSUME_NONNULL_BEGIN
/// 截断有限质量参数并为非有限输入提供回退。
FOUNDATION_EXPORT CGFloat sc_NormalizedQuality(CGFloat quality, CGFloat fallback);
/// 计算像素边界内且不放大的目标尺寸。
FOUNDATION_EXPORT CGSize sc_TargetSize(CGSize source, CGSize bounds);
/// 在固定源 RGB 色域与几何中提取参考/候选，非 RGB 回退 sRGB。
FOUNDATION_EXPORT NSData * _Nullable sc_ImagePixels(CGImageRef image, CGSize size, CGColorSpaceRef _Nullable referenceSpace);
/// 将参考图转换为源 RGB 色域中的完整 RGBA 像素数据。
FOUNDATION_EXPORT NSData * _Nullable sc_Pixels(CGImageRef image);
/// 使用 ImageIO 缩略解码并按可用系统接口转换为 SDR。
FOUNDATION_EXPORT CGImageRef _Nullable sc_Decode(CGImageSourceRef source, NSUInteger longestSide) CF_RETURNS_RETAINED;
/// 使用 ImageIO 生成指定格式的图片编码数据。
FOUNDATION_EXPORT NSData * _Nullable sc_Encode(CGImageRef image, CFStringRef type, double quality, NSDictionary * _Nullable metadata, SCImageCompressionOptions * _Nullable options);
/// 使用 libwebp 编码同域 RGBA 并封装源 ICC，透明度不铺底。
FOUNDATION_EXPORT NSData * _Nullable sc_EncodeWebP(CGImageRef image, NSData *pixels, double quality, SCImageCompressionOptions *options);
NS_ASSUME_NONNULL_END
