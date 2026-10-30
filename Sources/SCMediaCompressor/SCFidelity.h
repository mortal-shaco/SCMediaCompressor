#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
/// 请求保真目标允许固定 5% 相对容差，所有档位采用同一映射，不是主观百分比。
FOUNDATION_EXPORT double sc_EffectiveFidelityTarget(double quality);
/// 单次 HEIC/HDR 编码的候选初值，留出压缩空间；是否达标仍由实际输出评估。
FOUNDATION_EXPORT double sc_FidelityEncodingQuality(double quality);
/// 使用结构、细节和颜色误差评分；输入为同尺寸 RGBA8 参考与候选。
FOUNDATION_EXPORT BOOL sc_PassesFidelity(NSData *reference, NSData *candidate, size_t width, size_t height, CGFloat quality, double *score);
/// 在相同工作色域采样参考和候选；HDR 使用扩展线性亮度映射，避免 SDR 截断高光。
FOUNDATION_EXPORT NSData *sc_FidelityPixels(CIImage *image, size_t width, size_t height, BOOL hdr);
/// 有界空间采样的最大长边，不改变实际媒体输出尺寸。
FOUNDATION_EXPORT CGSize sc_FidelitySampleSize(CGSize size);

/// 从已解码 CGImage 直接取同几何采样，SDR 不需要 Core Image 中转。
FOUNDATION_EXPORT NSData *sc_FidelityImagePixels(CGImageRef image,size_t width,size_t height,BOOL hdr);
/// 用与参考相同的缩放方式提取真实候选，避免缩略图预滤波及解码补齐产生错误分数。
FOUNDATION_EXPORT NSData *sc_FidelitySourcePixels(CGImageSourceRef source,size_t width,size_t height,BOOL hdr);
/// 从实际视频像素缓冲直接取得有界亮度/色度采样，避免全帧 RGB 中转。
FOUNDATION_EXPORT NSData *sc_FidelityBufferPixels(CVPixelBufferRef buffer,size_t width,size_t height,BOOL hdr);
