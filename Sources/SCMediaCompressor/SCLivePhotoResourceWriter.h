#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
NS_ASSUME_NONNULL_BEGIN
/// 独立 Live Photo 配对工具，不依赖 HXPhotoPicker、相册权限或界面。
/// 目标路径必须未占用；图片使用 JPEG，视频无二次编码地重新封装为 MOV。
/// 成功时 error 为 nil；失败返回系统实际错误或本库配对阶段错误。
@interface SCLivePhotoResourceWriter : NSObject
/// 读取 JPEG 中已有的 Apple 配对标识。
/// @param url 可读取的静态图片文件。
+ (nullable NSString *)sc_livePhotoIdentifierForImageURL:(NSURL *)url;
/// 写入配对 JPEG，已有相同配对标识时按原字节复制。
/// @param source 原始 JPEG 文件。
/// @param output 未占用的目标 JPEG 路径。
/// @param identifier 图片和视频共用的配对标识。
/// @param completion 当前工作队列上的写入结果回调。
+ (void)sc_writePairedJPEGAtURL:(NSURL *)source toURL:(NSURL *)output identifier:(NSString *)identifier completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
/// 直接封装已有的视频/音频采样，并保留 Live 关键时间和对齐元数据。
/// @param source 已完成必要压缩的视频文件。
/// @param output 未占用的目标 MOV 路径。
/// @param identifier 与 JPEG 相同的配对标识。
/// @param completion 写入完成回调；缺少原关键时间的旧素材才回退为中间帧。
+ (void)sc_writePairedMovieAtURL:(NSURL *)source toURL:(NSURL *)output identifier:(NSString *)identifier completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
/// 视频封装的高级入口，可在读写启动后注册取消处理。
/// @param source 原始视频文件。
/// @param output 未占用的输出 MOV 路径。
/// @param identifier 与静态 JPEG 相同的配对标识。
/// @param header 可选的读写器回调；可取消当前封装。
/// @param completion 唯一完成回调。
+ (void)sc_writePairedMovieAtURL:(NSURL *)source toURL:(NSURL *)output identifier:(NSString *)identifier header:(nullable void (^)(AVAssetWriter *writer, AVAssetReader *reader))header completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
