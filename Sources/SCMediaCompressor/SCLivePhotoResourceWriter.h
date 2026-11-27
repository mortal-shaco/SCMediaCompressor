#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
NS_ASSUME_NONNULL_BEGIN
/// 独立 Live Photo 配对工具，不依赖 HXPhotoPicker、相册权限或界面。
/// 目标路径必须未占用；配对完成后原子交付，保留其他任务已占用的目标。图片使用 JPEG，视频无二次编码地重新封装为 MOV。
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
/// @param header 在封装队列同步调用；仅可在回调内操作读写器，跨线程取消使用 cancellation 入口。
/// @param completion 唯一完成回调。
+ (void)sc_writePairedMovieAtURL:(NSURL *)source toURL:(NSURL *)output identifier:(NSString *)identifier header:(nullable void (^)(AVAssetWriter *writer, AVAssetReader *reader))header completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
/// 注册线程安全的取消动作，读取及异步收尾停止后才交付唯一完成回调。
/// @param source 已压缩的视频文件。
/// @param output 未占用的 MOV 目标。
/// @param identifier 配对标识。
/// @param cancellation 在封装队列接收取消动作，可保存后从任意线程重复调用；终态后的调用直接返回。
/// @param completion 封装队列上的唯一完成回调；取消时输出已经清理。
+ (void)sc_writePairedMovieAtURL:(NSURL *)source toURL:(NSURL *)output identifier:(NSString *)identifier cancellation:(nullable void (^)(dispatch_block_t cancel))cancellation completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
