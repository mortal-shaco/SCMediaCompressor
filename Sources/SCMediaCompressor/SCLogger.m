#import "SCLogger.h"
/// 日志回调：仅由同步块读写，不与压缩配置混用。
static void (^sc_logHandler)(NSString *message);
/// 是否已明确配置日志，区分默认 stdout 与显式关闭。
static BOOL sc_logConfigured;
@implementation SCLogger
/// 同步替换日志接收器，不在锁内执行外部代码。
/// @param handler 新接收器；nil 表示关闭。
+ (void)sc_setLogHandler:(void (^)(NSString *))handler {
    @synchronized(self) { sc_logHandler = [handler copy]; sc_logConfigured = YES; }
}
/// 将消息交给快照回调，或使用默认 stdout。
/// @param message 本次统计消息。
+ (void)sc_logMessage:(NSString *)message {
    // handler：本次使用的日志回调快照。
    void (^handler)(NSString *);
    // configured：是否使用过日志配置入口。
    BOOL configured;
    @synchronized(self) { handler = sc_logHandler; configured = sc_logConfigured; }
    if (handler) handler(message);
    else if (!configured) { fprintf(stdout, "%s\n", message.UTF8String); fflush(stdout); }
}
@end

/// 统一格式化编码统计，避免图片与视频各自维护一份可变参数日志封装。
/// @param format printf 风格的 Foundation 格式字符串。
void sc_log(NSString *format, ...) {
    // arguments：本次格式化的可变参数列表。
    va_list arguments; va_start(arguments,format);
    // message：交给接收器的不可变文本。
    NSString *message=[[NSString alloc]initWithFormat:format arguments:arguments];
    va_end(arguments); [SCLogger sc_logMessage:message];
}
