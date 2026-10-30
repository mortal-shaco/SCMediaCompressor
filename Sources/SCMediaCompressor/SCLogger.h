#import <Foundation/Foundation.h>
/// 内部日志分发器，隔离视频核心与 UIKit。
@interface SCLogger : NSObject
/// 设置统计消息接收器；nil 关闭日志。
+ (void)sc_setLogHandler:(void (^)(NSString *message))handler;
/// 分发统计消息，不输出媒体路径或位置。
+ (void)sc_logMessage:(NSString *)message;
@end

/// 格式化后交给唯一日志分发器；不持有消息中的外部对象。
FOUNDATION_EXPORT void sc_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
