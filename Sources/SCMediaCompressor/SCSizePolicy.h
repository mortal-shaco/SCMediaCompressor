#pragma once
#import <Foundation/Foundation.h>
#import <errno.h>
#import <unistd.h>

/// 图片最大安全解码像素数，同时约束体积回退。
static const NSUInteger sc_MaximumDecodedPixels = 64000000;

/// 在交付目标所在文件系统创建本轮独占目录。
/// @param destination 调用方指定的最终文件路径。
/// @param error 创建失败时的系统错误。
static inline NSURL *sc_CreateOutputFolder(NSURL *destination, NSError **error) {
    // pattern：同卷私有目录模板，避免共享目标上的检查和写入竞态。
    NSURL *pattern = [destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:@".scmedia-XXXXXX"];
    // path：供 mkdtemp 原地写入的路径缓冲。
    char *path = strdup(pattern.fileSystemRepresentation);
    if (!path) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
        return nil;
    }
    // folder：创建成功后才由本轮负责清理的目录。
    NSURL *folder = nil;
    if (mkdtemp(path)) {
        folder = [NSURL fileURLWithFileSystemRepresentation:path isDirectory:YES relativeToURL:nil];
    } else if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    free(path);
    return folder;
}

/// 原子交付已完成的文件；目标已被占用时保留已有文件。
static inline BOOL sc_PublishOutput(NSURL *source, NSURL *destination, NSError **error) {
    if (link(source.fileSystemRepresentation, destination.fileSystemRepresentation) == 0) return YES;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return NO;
}
