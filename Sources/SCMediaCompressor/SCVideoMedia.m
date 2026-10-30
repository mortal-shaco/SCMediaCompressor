#import "SCVideoMedia.h"
#import "SCMediaCompressorError.h"

/// 构建统一 BT.709 色彩信号，防止 HDR 标记残留到 SDR 输出。
NSDictionary *sc_SDRColorProperties(void) {
    return @{
        AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2
    };
}

/// 输出策略或共享配置不能满足时明确失败，不静默覆盖冲突。
/// @param message 不兼容原因。
NSError *sc_VideoConfigurationError(NSString *message) {
    return [NSError errorWithDomain:SCMediaCompressorErrorDomain code:SCMediaCompressorErrorConfigurationConflict userInfo:@{NSLocalizedDescriptionKey:message}];
}

/// 从真实轨道描述提取 HLG/PQ 色彩，不根据 HEVC 编码或扩展名推断 HDR。
/// @param asset 已加载轨道的输入或输出素材。
NSDictionary *sc_HDRVideoColorProperties(AVAsset *asset) {
    // track：可能含 HDR 的视频轨道。
    for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeVideo]) {
        // description：真实的压缩格式描述。
        for (id description in track.formatDescriptions) {
            // extensions：传递函数与色彩矩阵声明。
            NSDictionary *extensions=(__bridge NSDictionary *)CMFormatDescriptionGetExtensions((__bridge CMFormatDescriptionRef)description);
            // transfer：只保留当前支持的 HLG 或 PQ，不为未知动态范围猜测标签。
            NSString *transfer=extensions[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction];
            // primaries：源色域。
            NSString *primaries=extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries];
            // matrix：源 YCbCr 变换。
            NSString *matrix=extensions[(__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix];
            if (([transfer isEqual:AVVideoTransferFunction_ITU_R_2100_HLG] || [transfer isEqual:AVVideoTransferFunction_SMPTE_ST_2084_PQ]) && primaries.length && matrix.length)
                return @{AVVideoColorPrimariesKey:primaries,AVVideoTransferFunctionKey:transfer,AVVideoYCbCrMatrixKey:matrix};
        }
    }
    return nil;
}

/// 完成写入后核对真实 HEVC Main10、位深与 HDR 色彩；同样约束源文件回退。
/// @param asset 待交付文件，不读取完整帧。
/// @param colors 本轮固定的 HDR 色彩目标。
BOOL sc_HDRVideoMatches(AVAsset *asset, NSDictionary *colors) {
    if (![sc_HDRVideoColorProperties(asset) isEqual:colors]) return NO;
    // track：输出的实际视频轨道。
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // format：HEVC 格式描述。
    CMFormatDescriptionRef format=(__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    if (!format || CMFormatDescriptionGetMediaSubType(format)!=kCMVideoCodecType_HEVC) return NO;
    // atoms：编码配置记录，不依赖扩展名或请求值判断位深。
    NSDictionary *atoms=(__bridge NSDictionary *)CMFormatDescriptionGetExtension(format,kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    // configuration：HEVCDecoderConfigurationRecord 的 Main10 与 luma/chroma 位深字段。
    NSData *configuration=atoms[@"hvcC"];
    if (configuration.length<23) return NO;
    // bytes：配置记录在固定字段范围内读取。
    const uint8_t *bytes=configuration.bytes;
    return (bytes[1]&31)==2 && (bytes[17]&7)>=2 && (bytes[18]&7)>=2;
}

// Compositor coordinates follow the displayed clean aperture and pixel aspect ratio.
/// 读取 clean aperture 与像素宽高比后的实际显示尺寸。
/// @param track 轨道。
CGSize sc_PresentationSize(AVAssetTrack *track) {
    // format：格式。
    CMVideoFormatDescriptionRef format = (__bridge CMVideoFormatDescriptionRef)track.formatDescriptions.firstObject;
    // size：尺寸。
    CGSize size = format ? CMVideoFormatDescriptionGetPresentationDimensions(format, YES, YES) : CGSizeZero;
    if (size.width <= 0 || size.height <= 0 || !isfinite(size.width) || !isfinite(size.height)) size = track.naturalSize;
    return size;
}

// Identify the paired video by its timed still-image marker, not by a filename or caller's preview size.
/// 根据 still-image-time 元数据识别 Live 配对视频。
/// @param asset 素材。
BOOL sc_IsLivePhotoAsset(AVAsset *asset) {
    // track：轨道。
    for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeMetadata]) {
        // description：说明。
        for (id description in track.formatDescriptions) {
            // format：格式。
            CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)description;
            if (format && CMFormatDescriptionGetMediaType(format) == kCMMediaType_Metadata &&
                [(__bridge NSArray *)CMMetadataFormatDescriptionGetIdentifiers(format)
                    containsObject:@"mdta/com.apple.quicktime.still-image-time"]) return YES;
        }
    }
    return NO;
}

/// 将系统导出状态映射为稳定统计文本。
/// @param status 状态。
NSString *sc_StatusName(AVAssetExportSessionStatus status) {
    switch (status) {
        case AVAssetExportSessionStatusCompleted: return @"completed";
        case AVAssetExportSessionStatusCancelled: return @"cancelled";
        case AVAssetExportSessionStatusFailed: return @"failed";
        default: return @"unfinished";
    }
}

/// 集中列出必须透传的 Live 关键帧时间与对齐元数据类型。
NSDictionary *sc_LiveMetadataTypes(void) {
    return @{@"mdta/com.apple.quicktime.still-image-time": (__bridge NSString *)kCMMetadataBaseDataType_SInt8,
        (__bridge NSString *)kCMMetadataIdentifier_QuickTimeMetadataLivePhotoStillImageTransform: (__bridge NSString *)kCMMetadataBaseDataType_PerspectiveTransformF64,
        (__bridge NSString *)kCMMetadataIdentifier_QuickTimeMetadataLivePhotoStillImageTransformReferenceDimensions: (__bridge NSString *)kCMMetadataBaseDataType_DimensionsF32};
}

/// 构造可交付给调用方的视频导出错误。
/// @param message 面向调用方的说明或统计文本。
NSError *sc_ExportError(NSString *message) {
    return [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorExportFailed
                          userInfo:@{NSLocalizedDescriptionKey : message}];
}
