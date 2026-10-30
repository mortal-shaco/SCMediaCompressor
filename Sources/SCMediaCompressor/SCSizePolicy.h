#import <Foundation/Foundation.h>
/// 图片最大安全解码像素数，同时约束体积回退。
static const NSUInteger sc_MaximumDecodedPixels = 64000000;
/// 统一体积比较口径：只使用实际文件字节；未知基准不能推断节省比例。
/// @param outputBytes 已编码结果的实际字节数。
/// @param baselineBytes 已确认的实际文件比较基线，0 表示未知。
static inline BOOL sc_OutputExceedsBaseline(unsigned long long outputBytes, unsigned long long baselineBytes) {
    return baselineBytes>0 && outputBytes>baselineBytes;
}
