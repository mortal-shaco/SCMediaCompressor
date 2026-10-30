#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
NS_ASSUME_NONNULL_BEGIN
/// 校验并读取受父范围约束的媒体容器 atom。
FOUNDATION_EXPORT BOOL sc_ReadAtom(NSFileHandle *file, uint64_t position, uint64_t end,
                                   uint32_t *type, uint64_t *body, uint64_t *atomEnd);
/// 检查 MP4 媒体索引是否位于数据块之前。
FOUNDATION_EXPORT BOOL sc_HasFastStart(NSURL *url);
/// 只修正私有 Live 副本中的现有画幅字段，不移动媒体采样。
FOUNDATION_EXPORT NSUInteger sc_ExposeFullLiveFrame(NSFileHandle *file, uint64_t start, uint64_t end,
                                                    NSDictionary<NSNumber *, NSValue *> *dimensions,
                                                    CMVideoDimensions trackSize, NSUInteger depth);
NS_ASSUME_NONNULL_END
