#import <Foundation/Foundation.h>
#import "SCImageCompressionOptions.h"
#import "SCImageCompressor.h"
#import "SCVideoCompressor.h"
#import "SCCompressionTask.h"
#import "SCCompressionOutcome.h"
#import "SCMediaCompressorError.h"
#import "SCLivePhotoResourceWriter.h"

NS_ASSUME_NONNULL_BEGIN
/// 公共日志入口；消息只包含编码统计，不包含相册位置、文件路径或用户素材。
@interface SCMediaCompressor : NSObject
/// 异步图片入口，完成与进度回调均在主队列；取消后不交付编码数据。
/// @param data 原始编码图片，操作期间以不可变副本持有。
/// @param options 独立图片配置，nil 使用默认值。
/// @param progress 可选阶段进度，不代表逐像素完成百分比。
/// @param completion 唯一终态回调，成功时返回图片数据，失败或取消返回错误。
+ (SCCompressionTask *)sc_compressImageData:(NSData *)data options:(nullable SCImageCompressionOptions *)options progress:(nullable void (^)(double progress))progress completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;
/// 异步 UIImage 入口，按真实像素与方向处理。
/// @param image 原始 UIImage。
/// @param options 独立配置。
/// @param progress 可选阶段进度。
/// @param completion 主队列唯一完成回调。
+ (SCCompressionTask *)sc_compressImage:(UIImage *)image options:(nullable SCImageCompressionOptions *)options progress:(nullable void (^)(double progress))progress completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;
/// 异步视频入口，返回可取消任务；默认 H264/MP4、30fps、普通视频 1280 像素边界。
/// @param asset 原始视频或组合素材。
/// @param outputURL 未占用的本地输出路径，调用方负责成功后的文件生命周期。
/// @param configure 开始前配置编码器；输出路径由 outputURL 参数决定。
/// @param progress 主队列进度回调。
/// @param completion 主队列唯一完成回调。
+ (SCCompressionTask *)sc_compressVideoAsset:(AVAsset *)asset outputURL:(NSURL *)outputURL configure:(nullable void (^)(SCVideoCompressor *compressor))configure progress:(nullable void (^)(double progress))progress completion:(void (^)(NSURL * _Nullable outputURL, NSError * _Nullable error))completion;
/// 完整 Live Photo 压缩与配对，不选择相册、不申请权限、不上传、不自动保存。
/// @param imageURL 原始静态图片的本地 URL。
/// @param videoURL 原始配对视频的本地 URL。
/// @param directory 输出父目录；每次创建独立子目录，取消或失败只清理该子目录。
/// @param options 图片配置；Live 视频复用尺寸上限、quality 和 preservesHDR，尺寸各自等比且不放大。
/// @param configure 可选视频专属码率、帧率、音频等设置；不能覆盖图片决定的 Live 尺寸、质量和 HDR。
/// @param progress 主队列分阶段进度。
/// @param completion 主队列唯一完成回调；成功返回配对 JPEG/MOV，调用方负责后续清理。
+ (SCCompressionTask *)sc_compressLivePhotoImageURL:(NSURL *)imageURL videoURL:(NSURL *)videoURL outputDirectory:(NSURL *)directory imageOptions:(nullable SCImageCompressionOptions *)options configureVideo:(nullable void (^)(SCVideoCompressor *compressor))configure progress:(nullable void (^)(double progress))progress completion:(void (^)(NSURL * _Nullable imageURL, NSURL * _Nullable videoURL, NSError * _Nullable error))completion;
/// 设置日志接收器；nil 关闭日志。默认按 printf 风格输出统计，方便现有应用调试。
/// @param handler 在产生消息的工作队列调用；接收器需要自行保证线程安全。
+ (void)sc_setLogHandler:(nullable void (^)(NSString *message))handler;
/// 发送一条统计消息，供内部编码器和自定义诊断使用。
/// @param message 已格式化、不包含私人媒体信息的日志文本。
+ (void)sc_logMessage:(NSString *)message;
@end
NS_ASSUME_NONNULL_END
