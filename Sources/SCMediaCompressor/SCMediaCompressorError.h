#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// 本库公开错误域；系统 AVFoundation / Cocoa 取消错误仍保留原 domain。
FOUNDATION_EXPORT NSErrorDomain const SCMediaCompressorErrorDomain;
/// 本库可识别的错误码；数值与既有实现兼容。
typedef NS_ERROR_ENUM(SCMediaCompressorErrorDomain, SCMediaCompressorErrorCode) {
    /// 图片输入、边界、编码或动画约束失败。
    SCMediaCompressorErrorImageFailed = 1,
    /// 高层协调、Live 配对或视频导出走本库路径的一般失败。
    SCMediaCompressorErrorCoordinationFailed = 2,
    /// HDR / 输出格式 / 编码配置冲突，或系统能力不足。
    SCMediaCompressorErrorConfigurationConflict = 3,
};
NS_ASSUME_NONNULL_END
