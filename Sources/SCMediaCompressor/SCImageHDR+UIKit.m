#import "SCImageHDR.h"
#import "SCInternal.h"
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
/// 检查 UIKit 图片真正携带的 HDR 信息，而不根据文件名或位深猜测。
/// @param image 原始 UIKit 图片。
BOOL sc_UIImageContainsHDR(UIImage *image) {
    if(sc_imageContainsHDR(image.CGImage))return YES;
    // space：CIImage 自身记录的色彩空间。
    CGColorSpaceRef space=image.CIImage.colorSpace;
    if(space&&(CGColorSpaceIsPQBased(space)||CGColorSpaceIsHLGBased(space)))return YES;
    if(@available(iOS 18.0,*))return image.CIImage.contentHeadroom>1;
    return NO;
}
/// 使用浮点 Core Image 路径缩放 HDR，不把 8 位 SDR 图误当作 HDR 输出。
/// @param image 实际携带 HDR 的 UIImage。
/// @param target 已计算的显示像素边界。
/// @param options 包含特殊格式许可的独立配置。
/// @param error 无法保留时的明确错误。
NSData *sc_preserveHDRUIImage(UIImage *image, CGSize target, SCImageCompressionOptions *options, NSError **error) {
    if(@available(iOS 18.0,*)) {
        // input：保留浮点范围的 Core Image 源。
        CIImage *input=image.CIImage ?: [CIImage imageWithCGImage:image.CGImage];
        // orientations：UIKit 方向到 EXIF 方向的固定映射。
        static const int orientations[]={1,3,8,6,2,4,5,7};
        input=[input imageByApplyingOrientation:orientations[image.imageOrientation]];
        // scale：在目标宽高内等比缩小，禁止放大。
        double scale=MIN(1,MIN(target.width/input.extent.size.width,target.height/input.extent.size.height));
        input=[input imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
        // context：只服务本次高精度转换的渲染上下文。
        CIContext *context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
        // space：承载超过 SDR 范围的线性 RGB 色彩空间。
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        // rendered：保持 HDR 的半精度浮点图像。
        CGImageRef rendered=[context createCGImage:input fromRect:input.extent format:kCIFormatRGBAh colorSpace:space];
        CGColorSpaceRelease(space);
        // headroom：原始图片实际声明的内容亮度范围。
        float headroom=MAX(input.contentHeadroom,image.CGImage ? CGImageGetContentHeadroom(image.CGImage) : 0);
        if(rendered&&headroom>1) {
            // described：像素不变，仅保留原始真实亮度声明。
            CGImageRef described=CGImageCreateCopyWithContentHeadroom(headroom,rendered);
            if(described){CGImageRelease(rendered);rendered=described;}
        }
        // data：能通过 HDR 保留检查才返回的编码数据。
        if(rendered)sc_SetImageFidelityReference(rendered,options,YES);
        // data：在同一浮点参考下编码并评估的真实 HDR 输出。
        NSData *data=rendered ? sc_encodeHDRImage(rendered,options,NO,error) : nil;
        if(rendered)CGImageRelease(rendered);return data;
    }
    if(error)*error=sc_hdrError(@"HDR UIImage scaling requires iOS 18 or later; use original HEIF data to preserve its gain map on older systems");return nil;
}
