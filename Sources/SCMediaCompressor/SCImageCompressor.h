#import <UIKit/UIKit.h>
#import "SCImageCompressionOptions.h"
NS_ASSUME_NONNULL_BEGIN
/// 同步图片编码核心。候选严格小于合规基线时采用，否则返回基线，允许零体积收益。
/// UIImage 无原文件字节，不能验证此上限。大图请用异步入口或自行切换工作队列。
@interface SCImageCompressor : NSObject
/// 检查原始编码数据是否携带 HDR 增益图或 HDR 像素声明。
/// @param data 原始编码图片；无法识别时返回 NO。
+ (BOOL)sc_containsHDRInData:(NSData *)data;
/// 使用默认配置压缩原始图片数据。
/// @param data JPEG、PNG、HEIC 等 ImageIO 可解码的数据；输出不透传 HEIC。
+ (nullable NSData *)sc_compressData:(NSData *)data;
/// 使用默认配置压缩 UIImage，按照真实像素及方向归一化。
/// @param image 待处理图片，支持 CGImage 或 CIImage 支持的 UIImage。
+ (nullable NSData *)sc_compressImage:(UIImage *)image;
/// 指定本次图片保真目标，不修改全局默认值。
/// @param data 原始编码图片数据。
/// @param quality 0…1 的校准目标，非有限值使用默认质量。
+ (nullable NSData *)sc_compressData:(NSData *)data quality:(CGFloat)quality;
/// 指定 UIImage 的本次保真目标。
/// @param image 待压缩的图片。
/// @param quality 本次校准目标。
+ (nullable NSData *)sc_compressImage:(UIImage *)image quality:(CGFloat)quality;
/// 通用入口：独立配置边界和 JPEG/PNG 输出格式，0 轴不限制；最大解码像素为 6400 万。
/// @param data 原始图片数据；超过配置边界的动画 GIF 会返回错误，避免隐式丢帧。
/// @param options 本次配置，nil 使用默认值；处理前复制。
/// @param error 可选错误输出。
+ (nullable NSData *)sc_compressData:(NSData *)data options:(nullable SCImageCompressionOptions *)options error:(NSError * _Nullable * _Nullable)error;
/// 通用 UIImage 入口；格式、边界与质量由本次配置决定。
/// @param image 待处理 UIImage。
/// @param options 本次独立配置。
/// @param error 可选错误输出。
+ (nullable NSData *)sc_compressImage:(UIImage *)image options:(nullable SCImageCompressionOptions *)options error:(NSError * _Nullable * _Nullable)error;
/// Live 静态图默认入口，强制 JPEG 并保留可用配对标识。
/// @param data 原始静态图片数据。
+ (nullable NSData *)sc_compressLivePhotoData:(NSData *)data;
/// Live UIImage 默认入口。
/// @param image 需要输出为 Live 静态图的图片。
+ (nullable NSData *)sc_compressLivePhotoImage:(UIImage *)image;
/// Live 数据入口，按次指定保真目标。
/// @param data 原始静态图片数据。
/// @param quality 本次保真目标。
+ (nullable NSData *)sc_compressLivePhotoData:(NSData *)data quality:(CGFloat)quality;
/// Live UIImage 入口，按次指定保真目标。
/// @param image 原始图片。
/// @param quality 本次保真目标。
+ (nullable NSData *)sc_compressLivePhotoImage:(UIImage *)image quality:(CGFloat)quality;
/// Live 数据配置入口，格式固定 JPEG；maximumSize 同时用于 Live 视频。
/// @param data 原始静态图片数据。
/// @param options 包含尺寸与质量的独立配置。
/// @param error 可选错误输出。
+ (nullable NSData *)sc_compressLivePhotoData:(NSData *)data options:(nullable SCImageCompressionOptions *)options error:(NSError * _Nullable * _Nullable)error;
/// 根据实际图片编码推导扩展名；无法识别时返回空字符串。
/// @param data 需要识别的编码数据。
+ (NSString *)sc_fileExtensionForData:(NSData *)data;
/// 根据实际编码推导 MIME；无法识别时返回 application/octet-stream。
/// @param data 需要识别的编码数据。
+ (NSString *)sc_mimeTypeForData:(NSData *)data;
@end
NS_ASSUME_NONNULL_END
