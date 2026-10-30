#import <Foundation/Foundation.h>
#import "SCImageCompressionOptions.h"
#import "SCVideoCompressor.h"
NS_ASSUME_NONNULL_BEGIN
/// 高层任务处理的媒体种类，用于解释 outcome 字段口径。
typedef NS_ENUM(NSInteger, SCCompressionMediaKind) {
    SCCompressionMediaKindImage = 0, ///< 单张图片。
    SCCompressionMediaKindVideo, ///< 普通视频。
    SCCompressionMediaKindLivePhoto, ///< Live 整组 JPEG/MOV。
};
/// 一次高层压缩结束后的只读摘要；优先用它判断体积与质量，不必拼多个 task 字段。
@interface SCCompressionOutcome : NSObject
/// 本轮媒体种类。
@property (nonatomic, readonly) SCCompressionMediaKind mediaKind;
/// 是否交付了结果。
@property (nonatomic, readonly) BOOL succeeded;
/// 实际比较基线字节；0 表示未知，不能计算节省。
@property (nonatomic, readonly) unsigned long long baselineBytes;
/// 实际交付字节；失败为 0。Live 为配对 JPEG 与 MOV 合计。
@property (nonatomic, readonly) unsigned long long outputBytes;
/// 是否交付了合规基线（含等大回退）；基线未知时为 NO。
@property (nonatomic, readonly) BOOL usedBaseline;
/// 相对基线的节省比例，范围可到负值以外由实现保证；基线未知或失败为 nil。
@property (nonatomic, copy, readonly, nullable) NSNumber *savedRatio;
/// 图片保真状态；纯视频任务为未评估。
@property (nonatomic, readonly) SCImageQualityStatus imageQualityStatus;
/// 图片评分；未评估为 nil。
@property (nonatomic, copy, readonly, nullable) NSNumber *imageFidelityScore;
/// 视频保真状态；纯图片任务为未评估。
@property (nonatomic, readonly) SCVideoQualityStatus videoQualityStatus;
/// 视频最终评分；未评估为 nil。
@property (nonatomic, copy, readonly, nullable) NSNumber *videoFidelityScore;
/// 图片 ImageIO 编码尝试次数；无图片阶段为 0。
@property (nonatomic, readonly) NSUInteger imageEncodingPassCount;
/// 视频编码次数；无视频阶段为 0。
@property (nonatomic, readonly) NSUInteger videoEncodingPassCount;
@end
NS_ASSUME_NONNULL_END
