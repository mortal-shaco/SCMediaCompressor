#import "SCFidelity.h"
/// sc_QualityTileSide：质量分块边。
static const NSUInteger sc_QualityTileSide = 16;
/// 有界视频空间滤波的单轴采样点数，避免最近邻单点受相位和振铃干扰。
static const NSUInteger sc_FidelityFilterSide = 4;

/// 计算各质量档相同定义的有效目标。
/// @param quality 归一化请求值。
double sc_EffectiveFidelityTarget(double quality) { return .95 * fmin(1,fmax(0,quality)); }
/// 为单次编码留出实际压缩空间，不把该参数当成最终保真分数。
/// @param quality 归一化保真请求。
double sc_FidelityEncodingQuality(double quality) {return .6*sc_EffectiveFidelityTarget(quality);}

/// 根据 RGB 分量计算像素亮度。
/// @param pixel 像素。
static double sc_Luma(const uint8_t *pixel) {
    return 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2];
}

/// Compare every full-resolution pixel, including local high-frequency tiles and RGB color error.
/// This is a conservative objective gate, not a claim of perceptual equivalence for all possible images.
/// 检查局部结构、纹理与 RGB 误差是否满足保真目标。
/// @param reference 参考图像。
/// @param candidate 候选结果。
/// @param width 宽度。
/// @param height 高度。
/// @param quality 质量。
/// @param fidelityScore fidelityScore。
BOOL sc_PassesFidelity(NSData *reference, NSData *candidate, size_t width, size_t height, CGFloat quality, double *fidelityScore) {
    if (!reference.length || reference.length != candidate.length) return NO;
    // a：参考像素缓冲。
    // b：候选像素缓冲。
    const uint8_t *a = reference.bytes, *b = candidate.bytes;
    // sumSSIM：局部结构相似度累计值。
    // colorError：RGB 绝对误差累计值。
    // minDetail：细节块中最小相似度。
    double sumSSIM = 0, colorError = 0, minDetail = 1;
    // tiles：已经比较的局部分块数量。
    NSUInteger tiles = 0;
    // y：纵向像素坐标。
    for (size_t y = 0; y < height; y += sc_QualityTileSide) {
        // x：横向像素坐标。
        for (size_t x = 0; x < width; x += sc_QualityTileSide) {
            // sx：参考亮度累计值。
            // sy：候选亮度累计值。
            // sxx：参考亮度平方累计值。
            // syy：候选亮度平方累计值。
            // sxy：参考与候选亮度乘积累计值。
            double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
            // count：数量。
            NSUInteger count = 0;
            // yy：分块内纵坐标。
            for (size_t yy = y; yy < MIN(y + sc_QualityTileSide, height); yy++) {
                // xx：分块内横坐标。
                for (size_t xx = x; xx < MIN(x + sc_QualityTileSide, width); xx++) {
                    // offset：偏移。
                    size_t offset = (yy * width + xx) * 4;
                    // u：参考亮度值。
                    // v：候选亮度值。
                    double u = sc_Luma(a + offset), v = sc_Luma(b + offset);
                    sx += u; sy += v; sxx += u*u; syy += v*v; sxy += u*v; count++;
                    // channel：当前RGB通道索引。
                    for (NSUInteger channel = 0; channel < 3; channel++) colorError += abs(a[offset+channel] - b[offset+channel]);
                    if (a[offset+3] != b[offset+3]) return NO;
                }
            }
            // mx：参考分块亮度均值。
            // my：候选分块亮度均值。
            double mx = sx/count, my = sy/count;
            // vx：参考分块亮度方差。
            // vy：候选分块亮度方差。
            double vx = MAX(0, sxx/count - mx*mx), vy = MAX(0, syy/count - my*my);
            // covariance：参考与候选亮度协方差。
            double covariance = sxy/count - mx*my;
            // ssim：当前局部结构相似度。
            double ssim = ((2*mx*my + 6.5025) * (2*covariance + 58.5225)) /
                ((mx*mx + my*my + 6.5025) * (vx + vy + 58.5225));
            sumSSIM += ssim; tiles++;
            if (vx >= 100) minDetail = MIN(minDetail, ssim);
        }
    }
    if (!tiles) return NO;
    // colorAgreement：RGB 平均绝对误差相对通道范围归一化后的一致度。
    double colorAgreement=1-colorError/(width*height*3*255.0);
    // score：结构、局部细节和颜色一致度的最差项；不再用二次误差放大重映射。
    double score=fmin(1,fmax(0,MIN(MIN(sumSSIM/tiles,minDetail),colorAgreement)));
    if (fidelityScore) *fidelityScore = score;
    return score + 1e-9 >= sc_EffectiveFidelityTarget(quality);
}

/// 生成固定成本的空间采样尺寸，最小一轴为一个像素。
/// @param size 原始参考尺寸。
CGSize sc_FidelitySampleSize(CGSize size) {
    // scale：只用于评估，不参与媒体几何。
    double scale=fmin(1,128.0/fmax(size.width,size.height));
    return CGSizeMake(MAX(1,floor(size.width*scale)),MAX(1,floor(size.height*scale)));
}
/// 从统一色域生成参考和候选的采样像素，缓存只包含系统绘制上下文。
/// @param image 原始或候选实际像素。
/// @param width 采样宽度。
/// @param height 采样高度。
/// @param hdr 是否保留并比较扩展亮度。
NSData *sc_FidelityPixels(CIImage *image,size_t width,size_t height,BOOL hdr) {
    if(!image||!width||!height||width*height>128*128)return nil;
    // context：跨任务复用线程安全绘制资源，不保留媒体结果。
    static CIContext *context;
    // once：初始化系统绘制上下文。
    static dispatch_once_t once;dispatch_once(&once,^{context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];});
    // extent：实际像素范围。
    CGRect extent=image.extent;
    if(CGRectIsEmpty(extent)||CGRectIsInfinite(extent))return nil;
    // resized：同一几何归一化，不重新调用业务渲染代理。
    CIImage *resized=[[image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x,-extent.origin.y)] imageByApplyingTransform:CGAffineTransformMakeScale(width/extent.size.width,height/extent.size.height)];
    // data：统一 RGBA8 数据。
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4];
    // colors：HDR 在扩展线性 BT.2020 中比较，SDR 在 sRGB 中比较。
    CGColorSpaceRef colors=CGColorSpaceCreateWithName(hdr?kCGColorSpaceExtendedLinearITUR_2020:kCGColorSpaceSRGB);
    if(hdr){
        // linear：保留大于 1 的高光参考，不在采样前裁成 SDR。
        NSMutableData *linear=[NSMutableData dataWithLength:width*height*4*sizeof(float)];
        [context render:resized toBitmap:linear.mutableBytes rowBytes:width*4*sizeof(float) bounds:CGRectMake(0,0,width,height) format:kCIFormatRGBAf colorSpace:colors];
        // values：扩展线性源数据。
        const float *values=linear.bytes;
        // bytes：映射后的有界比较数据。
        uint8_t *bytes=data.mutableBytes;
        // i：采样通道索引。
        for(NSUInteger i=0;i<width*height*4;i++){if(i%4==3){bytes[i]=255;continue;}bytes[i]=(uint8_t)lrint(255*fmax(0,values[i])/(1+fmax(0,values[i])));}
    }else [context render:resized toBitmap:data.mutableBytes rowBytes:width*4 bounds:CGRectMake(0,0,width,height) format:kCIFormatRGBA8 colorSpace:colors];
    CGColorSpaceRelease(colors);return data;
}

/// 在指定工作色域直接提取同位置采样，不对视频应用额外伽马转换。
/// @param image 源或候选像素。
/// @param width 采样宽度。
/// @param height 采样高度。
/// @param name 工作色域名称。
static NSData *sc_FidelityDrawImage(CGImageRef image,size_t width,size_t height,CFStringRef name) {
    if(!image)return nil;
    // data：直接在 sRGB 中绘制评估采样。
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4];
    // space：参考和候选共享工作色域。
    CGColorSpaceRef space=CGColorSpaceCreateWithName(name);
    // context：只绘制小范围采样，不分配完整图像像素副本。
    CGContextRef context=CGBitmapContextCreate(data.mutableBytes,width,height,8,width*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);if(!context)return nil;
    CGContextSetBlendMode(context,kCGBlendModeCopy);CGContextSetInterpolationQuality(context,kCGInterpolationHigh);
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);return data;
}
/// 在 sRGB 或扩展 HDR 中提取图片样本。
/// @param image 实际参考或候选图像。
/// @param width 采样宽度。
/// @param height 采样高度。
/// @param hdr 是否保留扩展亮度。
NSData *sc_FidelityImagePixels(CGImageRef image,size_t width,size_t height,BOOL hdr) {
    if(!image)return nil;
    return hdr?sc_FidelityPixels([CIImage imageWithCGImage:image],width,height,YES):sc_FidelityDrawImage(image,width,height,kCGColorSpaceSRGB);
}
/// 参考和候选使用相同的实际像素及最终缩放，避免解码器预缩放引入测量偏差。
/// @param source 真实已完成编码的图片源。
/// @param width 采样宽度。
/// @param height 采样高度。
/// @param hdr 是否保留扩展亮度。
NSData *sc_FidelitySourcePixels(CGImageSourceRef source,size_t width,size_t height,BOOL hdr) {
    if(!source||!width||!height)return nil;
    // settings：原输入仍受内核像素安全上限约束，按需解码后仅绘制有界采样缓冲。
    NSMutableDictionary *settings=[@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately:@NO}mutableCopy];
    if(hdr){settings[(__bridge NSString *)kCGImageSourceShouldAllowFloat]=@YES;if(@available(iOS 17.0,*))settings[(__bridge NSString *)kCGImageSourceDecodeRequest]=(__bridge NSString *)kCGImageSourceDecodeToHDR;}
    // decoded：真实候选的一次按需解码，不采用另一套缩略滤波。
    CGImageRef decoded=CGImageSourceCreateImageAtIndex(source,0,(__bridge CFDictionaryRef)settings);
    // pixels：与参考共用最终色域和缩放滤波。
    NSData *pixels=nil;
    if(decoded&&hdr){
        // properties：HDR 原始参考可能带 EXIF 方向，候选通常已归一化为 1。
        NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
        // value：仅在确实需要方向变换时使用定向的浮点参考。
        int value=[properties[(__bridge NSString *)kCGImagePropertyOrientation]intValue];
        pixels=value>1&&value<=8?sc_FidelityPixels([[CIImage imageWithCGImage:decoded]imageByApplyingOrientation:value],width,height,YES):sc_FidelityImagePixels(decoded,width,height,YES);
    }else if(decoded)pixels=sc_FidelityImagePixels(decoded,width,height,NO);
    if(decoded)CGImageRelease(decoded);return pixels;
}
/// 对同一编码域下的实际视频帧采样，HLG/PQ 保留高光信号而不转 SDR。
/// @param buffer 实际输入或候选解码缓冲。
/// @param width 采样宽度。
/// @param height 采样高度。
/// @param hdr 是否使用 BT.2020 的 10-bit 编码域。
NSData *sc_FidelityBufferPixels(CVPixelBufferRef buffer,size_t width,size_t height,BOOL hdr) {
    if(!buffer)return nil;
    // format：实际平面格式，其他显式缓冲沿用 Core Image 兼容处理。
    OSType format=CVPixelBufferGetPixelFormatType(buffer);
    if(format==kCVPixelFormatType_32BGRA){
        if(CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return nil;
        // source：业务渲染后的实际 BGRA 缓冲，不额外调用代理。
        const uint8_t *source=CVPixelBufferGetBaseAddress(buffer);
        // stride：真实行跨度。
        size_t stride=CVPixelBufferGetBytesPerRow(buffer);
        // data：保持相同视频信号的 RGBA 采样。
        NSMutableData *data=[NSMutableData dataWithLength:width*height*4];
        // bytes：目标采样缓冲。
        uint8_t *bytes=data.mutableBytes;
        // y：每个输出区域使用固定网格平均，不对细纹理做最近邻抽点。
        for(size_t y=0;y<height;y++){
            // x：同一归一化区域的采样列。
            for(size_t x=0;x<width;x++){
                // channels：有界区域内的真实颜色累计值。
                double channels[3]={0,0,0};
                // iy、ix：固定滤波网格，不随源分辨率增加采样次数。
                for(NSUInteger iy=0;iy<sc_FidelityFilterSide;iy++)for(NSUInteger ix=0;ix<sc_FidelityFilterSide;ix++){
                    // sy、sx：区域内归一化源像素位置。
                    size_t sy=MIN(CVPixelBufferGetHeight(buffer)-1,(size_t)((y+(iy+.5)/sc_FidelityFilterSide)*CVPixelBufferGetHeight(buffer)/height)),sx=MIN(CVPixelBufferGetWidth(buffer)-1,(size_t)((x+(ix+.5)/sc_FidelityFilterSide)*CVPixelBufferGetWidth(buffer)/width));
                    // pixel：实际渲染结果，不重新调用业务代理。
                    const uint8_t *pixel=source+sy*stride+sx*4;
                    channels[0]+=pixel[2];channels[1]+=pixel[1];channels[2]+=pixel[0];
                }
                // c：各通道采用相同的空间滤波。
                for(NSUInteger c=0;c<3;c++)bytes[(y*width+x)*4+c]=(uint8_t)lrint(channels[c]/(sc_FidelityFilterSide*sc_FidelityFilterSide));
                bytes[(y*width+x)*4+3]=255;
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);return data;
    }
    if(format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange&&format!=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)return sc_FidelityPixels([CIImage imageWithCVPixelBuffer:buffer],width,height,hdr);
    if(CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return nil;
    // ten：10-bit 像素以高位对齐的 16-bit 通道存放。
    BOOL ten=format==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    // luma、chroma：原始只读视频平面。
    const uint8_t *luma=CVPixelBufferGetBaseAddressOfPlane(buffer,0),*chroma=CVPixelBufferGetBaseAddressOfPlane(buffer,1);
    // lumaStride、chromaStride：每个平面真实行跨度。
    size_t lumaStride=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),chromaStride=CVPixelBufferGetBytesPerRowOfPlane(buffer,1);
    // sourceWidth、sourceHeight：原始编码参考的实际像素范围。
    size_t sourceWidth=CVPixelBufferGetWidth(buffer),sourceHeight=CVPixelBufferGetHeight(buffer);
    // data：同几何位置的 RGBA8 保真采样。
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4];
    // bytes：映射后的采样，不改变真实写入缓冲。
    uint8_t *bytes=data.mutableBytes;
    // y：在有界区域内平均编码域亮度及色度，避免单点相位偏差。
    for(size_t y=0;y<height;y++){
        // x：采样列。
        for(size_t x=0;x<width;x++){
            // yy、cb、cr：区域内的亮度和色度累计值。
            double yy=0,cb=0,cr=0;
            // iy、ix：固定滤波网格，参考与候选使用相同归一化区域。
            for(NSUInteger iy=0;iy<sc_FidelityFilterSide;iy++)for(NSUInteger ix=0;ix<sc_FidelityFilterSide;ix++){
                // sx、sy：同归一化位置的真实像素。
                size_t sx=MIN(sourceWidth-1,(size_t)((x+(ix+.5)/sc_FidelityFilterSide)*sourceWidth/width)),sy=MIN(sourceHeight-1,(size_t)((y+(iy+.5)/sc_FidelityFilterSide)*sourceHeight/height));
                yy+=ten?((const uint16_t *)(luma+sy*lumaStride))[sx]/256.0:luma[sy*lumaStride+sx];
                cb+=ten?((const uint16_t *)(chroma+(sy/2)*chromaStride))[(sx/2)*2]/256.0:chroma[(sy/2)*chromaStride+(sx/2)*2];
                cr+=ten?((const uint16_t *)(chroma+(sy/2)*chromaStride))[(sx/2)*2+1]/256.0:chroma[(sy/2)*chromaStride+(sx/2)*2+1];
            }
            yy/=sc_FidelityFilterSide*sc_FidelityFilterSide;cb/=sc_FidelityFilterSide*sc_FidelityFilterSide;cr/=sc_FidelityFilterSide*sc_FidelityFilterSide;
            yy=(yy-16)*255/219;cb=(cb-128)*255/224;cr=(cr-128)*255/224;
            // channels：保留真实 BT.709 或 BT.2020 信号域，不应用 SDR 色调映射。
            double channels[3]={yy+(hdr?1.4746:1.5748)*cr,yy-(hdr?.16455:.187324)*cb-(hdr?.57135:.468124)*cr,yy+(hdr?1.8814:1.8556)*cb};
            // c：采样颜色通道。
            for(NSUInteger c=0;c<3;c++)bytes[(y*width+x)*4+c]=(uint8_t)lrint(fmin(255,fmax(0,channels[c])));
            bytes[(y*width+x)*4+3]=255;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);return data;
}
