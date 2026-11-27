#import "SCVideoCompressorInternal.h"
#import "SCSizePolicy.h"

@implementation SCVideoExportResult
/// 防止未交付的高层结果留下私有目录。
- (void)dealloc {
    if (_stagedFolder) [NSFileManager.defaultManager removeItemAtURL:_stagedFolder error:nil];
}
@end

@implementation SCVideoExportConfiguration
@end

/// 位于完成回调动态作用域内的轮次结果，外层回调返回后恢复。
@interface SCVideoCallbackContext : NSObject
/// 当前执行回调的导出器。
@property (nonatomic, weak) SCVideoCompressor *session;
/// 当前回调对应的最终诊断。
@property (nonatomic, strong) SCVideoExportResult *result;
/// 同一线程上的外层回调。
@property (nonatomic, strong) SCVideoCallbackContext *previous;
@end

@implementation SCVideoCallbackContext
@end

/// 完成回调线程字典的内部键。
static NSString *const sc_VideoCallbackContextKey = @"io.github.mortal-shaco.scmedia.video.callback";

@implementation SCVideoCompressor

@synthesize outputURL = _outputURL;
@synthesize exportVideoQuality = _exportVideoQuality;

/// 只在当前完成回调内读取对应轮次的结果。
- (SCVideoExportResult *)sc_callbackResult {
    // context：支持调用方运行嵌套事件循环时恢复外层上下文。
    SCVideoCallbackContext *context = NSThread.currentThread.threadDictionary[sc_VideoCallbackContextKey];
    for (; context; context = context.previous) {
        if (context.session == self) return context.result;
    }
    return nil;
}

/// 在调用方读取公开属性时固定到这次交付结果。
- (void)sc_deliverResult:(SCVideoExportResult *)result handler:(dispatch_block_t)handler {
    // dictionary：作用域局限在实际执行回调的线程。
    NSMutableDictionary *dictionary = NSThread.currentThread.threadDictionary;
    // context：本轮回调的结果及外层作用域。
    SCVideoCallbackContext *context = [SCVideoCallbackContext new];
    context.session = self;
    context.result = result;
    context.previous = dictionary[sc_VideoCallbackContextKey];
    dictionary[sc_VideoCallbackContextKey] = context;
    @try {
        handler();
    } @finally {
        if (context.previous) dictionary[sc_VideoCallbackContextKey] = context.previous;
        else [dictionary removeObjectForKey:sc_VideoCallbackContextKey];
    }
}

/// 保持原有属性选择子，在完成块内切换到该轮诊断。
#define SC_VIDEO_GETTER(type, selector, value) \
    - (type)selector { SCVideoExportResult *result = self.sc_callbackResult; return value; }
#define SC_VIDEO_RESULT_GETTER(type, selector, property) \
    SC_VIDEO_GETTER(type, selector, (result ?: self.sc_result).property)

SC_VIDEO_RESULT_GETTER(AVAssetExportSessionStatus, status, status)
SC_VIDEO_RESULT_GETTER(NSError *, sc_error, error)
SC_VIDEO_RESULT_GETTER(float, sc_progress, progress)
/// KVO 通过公开键 progress 读取轮次进度。
SC_VIDEO_RESULT_GETTER(float, progress, progress)
SC_VIDEO_RESULT_GETTER(double, sc_requestedQuality, requestedQuality)
SC_VIDEO_RESULT_GETTER(unsigned long long, comparisonBytes, comparisonBytes)
SC_VIDEO_RESULT_GETTER(unsigned long long, conversionBytes, conversionBytes)
SC_VIDEO_RESULT_GETTER(NSUInteger, encodingPassCount, encodingPassCount)
SC_VIDEO_RESULT_GETTER(NSDictionary *, stageDurations, stageDurations)
SC_VIDEO_RESULT_GETTER(BOOL, usesConvertedBaseline, usesConvertedBaseline)
SC_VIDEO_RESULT_GETTER(NSTimeInterval, qualityEvaluationDuration, qualityEvaluationDuration)
SC_VIDEO_RESULT_GETTER(SCVideoQualityStatus, qualityStatus, qualityStatus)
SC_VIDEO_RESULT_GETTER(NSNumber *, fidelityScore, fidelityScore)
SC_VIDEO_RESULT_GETTER(NSNumber *, candidateFidelityScore, candidateFidelityScore)
SC_VIDEO_RESULT_GETTER(NSUInteger, qualitySampleCount, qualitySampleCount)

/// 完成块外仍返回调用方当前设定的输出路径。
SC_VIDEO_GETTER(NSURL *, outputURL, result ? result.outputURL : _outputURL)

#undef SC_VIDEO_RESULT_GETTER
#undef SC_VIDEO_GETTER

/// 根据对应轮次的请求质量计算统一门槛。
- (double)sc_effectiveQualityTarget { return sc_EffectiveFidelityTarget(self.requestedQuality); }

/// 更新导出队列的保真请求，供本轮编码和终态诊断共用。
- (void)sc_setExportVideoQuality:(double)quality {
    _exportVideoQuality = quality;
    self.sc_result.requestedQuality = quality;
}

+ (double)sc_defaultVideoQuality { return sc_DefaultVideoQuality; }

- (void)sc_setVideoQuality:(double)videoQuality {
    _videoQuality = isfinite(videoQuality) ? MIN(1, MAX(0, videoQuality)) : sc_DefaultVideoQuality;
}

+ (id)sc_exportSessionWithAsset:(AVAsset *)asset {
    return [[self alloc] sc_initWithAsset:asset];
}

- (id)sc_initWithAsset:(AVAsset *)asset {
    if ((self = [super init])) {
        _asset = asset;
        _videoQuality = sc_DefaultVideoQuality;
        _maximumSize = CGSizeMake(sc_VideoLongSide, sc_VideoLongSide);
        _livePhotoImageOptions = [SCImageCompressionOptions new];
        _maximumFrameRate = 30;
        _outputFileType=AVFileTypeMPEG4;
        _timeRange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
        _inputQueue = dispatch_queue_create("io.github.mortal-shaco.scmedia.video", DISPATCH_QUEUE_SERIAL);
        _sc_result = [SCVideoExportResult new];
    }
    return self;
}

/// 在入队前固定本轮的配置，顺序复用时允许下一轮设置不同参数。
- (SCVideoExportConfiguration *)sc_captureConfiguration {
    // configuration：每次调用独享的配置快照。
    SCVideoExportConfiguration *configuration = [SCVideoExportConfiguration new];
    configuration.defersPublication = self.sc_defersPublication;
    configuration.maximumSize = self.maximumSize;
    configuration.videoQuality = self.videoQuality;
    configuration.maximumFrameRate = self.maximumFrameRate;
    configuration.videoBitRate = self.videoBitRate;
    configuration.preservesHDR = self.preservesHDR;
    configuration.livePhoto = self.livePhoto;
    configuration.livePhotoImageOptions = self.livePhotoImageOptions;
    configuration.outputFileType = self.outputFileType;
    configuration.timeRange = self.timeRange;
    configuration.videoComposition = self.videoComposition;
    configuration.audioMix = self.audioMix;
    configuration.videoInputSettings = self.videoInputSettings;
    configuration.videoOutputSettings = self.videoOutputSettings;
    configuration.audioInputSettings = self.audioInputSettings;
    configuration.audioOutputSettings = self.audioOutputSettings;
    configuration.metadata = self.metadata;
    configuration.shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse;
    configuration.delegate = self.delegate;
    return configuration;
}

- (void)sc_exportAsynchronouslyWithCompletionHandler:(void (^)(void))handler {
    // destination：公开 setter 的最新请求，避免从旧回调的结果视图捕获目标。
    NSURL *destination = _outputURL;
    // configuration：在调用线程捕获本轮设置。
    SCVideoExportConfiguration *configuration = [self sc_captureConfiguration];
    // callbackQueue：固定本轮结果和进度的交付位置。
    dispatch_queue_t callbackQueue = self.callbackQueue;
    // progressHandler：固定本轮进度接收器。
    void (^progressHandler)(float) = self.progressHandler;
    dispatch_async(self.inputQueue, ^{
        if (self.runningSession) {
            [self sc_completeWithStatus:AVAssetExportSessionStatusCancelled error:nil];
        }
        self.generation++;
        // generation：异步操作代数，用于隔离取消或复用后的旧回调。
        NSUInteger generation = self.generation;
        self.completionHandler = handler;
        self.runningSession = self;
        // result：先填充固定值，再发布本轮诊断对象。
        SCVideoExportResult *result = [SCVideoExportResult new];
        result.outputURL = destination;
        result.stageDurations = @{};
        self.sc_result = result;
        self.sc_configuration = configuration;
        self.sc_hasCallbackQueue = callbackQueue != nil;
        self.sc_exportProgressHandler = progressHandler;
        self.sc_deliveryQueue = (callbackQueue || progressHandler) ?
            dispatch_queue_create_with_target("io.github.mortal-shaco.scmedia.video.delivery", DISPATCH_QUEUE_SERIAL,
                                              callbackQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0)) : nil;
        self.activeOutputURL = destination;
        self.retryCount = 0;
        self.sc_compressionStartedAt=0; self.sc_compressionFinishedAt=0;
        self.sc_sourceBaselineURL=nil; self.sc_requiresEncodingConversion=NO;

        self.exportVideoQuality = self.sc_configuration.videoQuality;
        self.exportMaximumSize = self.sc_configuration.maximumSize;
        self.exportLivePhotoImageOptions = [self.sc_configuration.livePhotoImageOptions copy] ?: [SCImageCompressionOptions new];
        self.exportCodec = AVVideoCodecTypeH264;
        self.sc_exportPreservesHDR=self.sc_configuration.preservesHDR;self.sc_exportsHDR=NO;self.sc_exportColorProperties=sc_SDRColorProperties();
        self.exportMaximumFrameRate = isfinite(self.sc_configuration.maximumFrameRate) && self.sc_configuration.maximumFrameRate > 0 ? self.sc_configuration.maximumFrameRate : 30;
        self.exportBitRate = MAX(0, self.sc_configuration.videoBitRate);

        [self sc_setProgress:0];
        [self sc_setStatus:AVAssetExportSessionStatusWaiting];
        self.logIdentifier = [NSUUID.UUID.UUIDString substringToIndex:8];
        self.exportStartedAt = CFAbsoluteTimeGetCurrent();
        // inputURL：输入URL。
        NSURL *inputURL = [self.asset isKindOfClass:AVURLAsset.class] ? [(AVURLAsset *)self.asset URL] : nil;
        // inputBytes：输入字节。
        NSNumber *inputBytes = inputURL.isFileURL ? [NSFileManager.defaultManager attributesOfItemAtPath:inputURL.path error:nil][NSFileSize] : nil;
        self.inputFileBytes = inputBytes.unsignedLongLongValue;
        sc_log(@"[SCVideoCompressor][%@] before inputBytes=%@ inputKB=%@ inputMB=%@", self.logIdentifier,
            inputBytes ?: @"unknown(composition/remote)", inputBytes ? [NSString stringWithFormat:@"%.2f", inputBytes.doubleValue / 1024.0] : @"n/a",
            inputBytes ? [NSString stringWithFormat:@"%.3f", inputBytes.doubleValue / (1024.0 * 1024.0)] : @"n/a");
        if (inputURL.isFileURL && [inputURL.URLByResolvingSymlinksInPath.URLByStandardizingPath.path isEqualToString:self.activeOutputURL.URLByResolvingSymlinksInPath.URLByStandardizingPath.path]) {
            self.activeOutputURL = nil;
            [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Output must not overwrite source")];
            return;
        }
        if (!self.asset || !self.activeOutputURL.isFileURL) {
            [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Missing source asset or invalid output file URL")];
            return;
        }
        if ([NSFileManager.defaultManager fileExistsAtPath:self.activeOutputURL.path]) {
            self.activeOutputURL = nil;
            [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Output already exists")]; return;
        }
        // directoryError：创建同卷私有目录的真实系统错误。
        NSError *directoryError = nil;
        self.sc_outputFolder = sc_CreateOutputFolder(self.activeOutputURL, &directoryError);
        if (!self.sc_outputFolder) {
            [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:directoryError];
            return;
        }
        self.activeOutputURL=[self.sc_outputFolder URLByAppendingPathComponent:destination.lastPathComponent];
        [self.asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ] completionHandler:^{
            dispatch_async(self.inputQueue, ^{
                if (generation != self.generation || !self.runningSession) return;
                // error：错误。
                NSError *error = nil;
                if ([self.asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded ||
                    [self.asset statusOfValueForKey:@"duration" error:&error] != AVKeyValueStatusLoaded) {
                    [self sc_completeWithStatus:AVAssetExportSessionStatusFailed
                                       error:error ?: sc_ExportError(@"Could not load media")];
                    return;
                }
                [self sc_captureLivePhotoOptions];
                // rangeError：在启动任何编码前校验源动态范围和输出组合。
                NSError *rangeError=[self sc_prepareDynamicRange];
                if(rangeError){[self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:rangeError];return;}
                // normalizationError：normalization错误。
                NSError *normalizationError = [self sc_prepareFullFrameSource];
                if (normalizationError) { [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:normalizationError]; return; }
                if (!self.fullFrameAsset) { [self sc_prepareCompressionBaseline]; return; }
                // normalized：归一化。
                AVAsset *normalized = self.fullFrameAsset;
                [normalized loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
                    dispatch_async(self.inputQueue, ^{
                        if (generation != self.generation || !self.runningSession) return;
                        // loadError：load错误。
                        NSError *loadError = nil;
                        if ([normalized statusOfValueForKey:@"tracks" error:&loadError] != AVKeyValueStatusLoaded ||
                            [normalized statusOfValueForKey:@"duration" error:&loadError] != AVKeyValueStatusLoaded) {
                            [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:loadError ?: sc_ExportError(@"Could not load full Live Photo frame")];
                            return;
                        }
                        [self sc_prepareCompressionBaseline];
                    });
                }];
            });
        }];
    });
}

/// Live 的共享尺寸、质量和 HDR 以静态图配置为准；视频专属参数继续独立。
- (void)sc_captureLivePhotoOptions {
    self.sc_exportsLivePhoto = self.sc_configuration.livePhoto || sc_IsLivePhotoAsset(self.asset);
    if (!self.sc_exportsLivePhoto) return;
    self.exportMaximumSize=self.exportLivePhotoImageOptions.maximumSize;
    // quality：只统一请求数值，不改变视频预算算法。
    double quality=self.exportLivePhotoImageOptions.quality;
    self.exportVideoQuality=isfinite(quality)?MIN(1,MAX(0,quality)):sc_DefaultVideoQuality;
    self.sc_exportPreservesHDR=self.exportLivePhotoImageOptions.preservesHDR;
}

/// 固定 HDR/SDR 输出策略，保留 HDR 时拒绝不支持的 8-bit 或自定义像素处理。
- (NSError *)sc_prepareDynamicRange {
    // colors：只在要求保留时读取 HDR 色彩，普通 SDR 始终使用 H264。
    NSDictionary *colors=self.sc_exportPreservesHDR?sc_HDRVideoColorProperties(self.asset):nil;
    self.exportCodec=colors?AVVideoCodecTypeHEVC:AVVideoCodecTypeH264;
    // explicitCodec：高级设置不能绕过源动态范围与 HDR 开关决定的编码格式。
    NSString *explicitCodec=self.sc_configuration.videoOutputSettings[AVVideoCodecKey];
    if(explicitCodec && ![explicitCodec isEqual:self.exportCodec])return sc_VideoConfigurationError(@"Explicit codec conflicts with source range: SDR uses H264; retained HDR uses HEVC");
    if (!self.sc_exportPreservesHDR) return nil;
    if (!colors) return [self.asset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count ? sc_VideoConfigurationError(@"Unsupported source HDR color description") : nil;
    if (![self.sc_configuration.outputFileType isEqual:AVFileTypeMPEG4] && ![self.sc_configuration.outputFileType isEqual:AVFileTypeQuickTimeMovie]) return sc_VideoConfigurationError(@"HDR video supports MP4 or MOV containers");
    if (self.sc_configuration.delegate || self.videoPixelBufferAdaptor || self.sc_configuration.videoComposition.customVideoCompositorClass) return sc_VideoConfigurationError(@"HDR preservation does not support BGRA render delegates or custom compositors");
    if (self.sc_configuration.videoInputSettings && [self.sc_configuration.videoInputSettings[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey]unsignedIntValue]!=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) return sc_VideoConfigurationError(@"HDR preservation requires 10-bit video-range pixel buffers");
    // profile：显式 8-bit 编码设置不能被静默覆盖。
    NSString *profile=self.sc_configuration.videoOutputSettings[AVVideoCompressionPropertiesKey][AVVideoProfileLevelKey];
    if (profile && ![profile isEqual:@"HEVC_Main10_AutoLevel"]) return sc_VideoConfigurationError(@"HDR preservation requires the HEVC Main10 profile");
    // explicitColors：显式色彩必须与源 HDR 一致。
    NSDictionary *explicitColors=self.sc_configuration.videoOutputSettings[AVVideoColorPropertiesKey];
    if (explicitColors && ![explicitColors isEqual:colors]) return sc_VideoConfigurationError(@"Explicit video color settings conflict with source HDR");
    self.sc_exportsHDR=YES;self.sc_exportColorProperties=colors;
    return nil;
}

/// 在压缩前确定实际基准。普通格式保留源字节；只为必要转换启动编码。
- (void)sc_prepareCompressionBaseline {
    if(![self.asset isKindOfClass:AVURLAsset.class] || ![(AVURLAsset *)self.asset URL].isFileURL) { [self sc_startAttempt]; return; }
    // sourceURL：原始文件，不覆盖或移动。
    NSURL *sourceURL=[(AVURLAsset *)self.asset URL];
    // track：输入视频实际编码格式。
    AVAssetTrack *track=[self.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // format：输入编解码标识。
    CMFormatDescriptionRef format=(__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    // targetCodec：实际请求的编码类型。
    NSString *targetCodec=self.sc_configuration.videoOutputSettings[AVVideoCodecKey] ?: self.exportCodec;
    // requiresEncoding：特殊编码或 HDR 需要真实转换；普通几何压缩不单独生成基准。
    BOOL requiresEncoding=!format || CMFormatDescriptionGetMediaSubType(format)!=([targetCodec isEqual:AVVideoCodecTypeHEVC] ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264) || ([self.asset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count>0 && !self.sc_exportsHDR);
    // audioTrack：非 AAC 音频必须预先转换为当前支持的音频格式。
    for(AVAssetTrack *audioTrack in [self.asset tracksWithMediaType:AVMediaTypeAudio]) {
        // audioFormat：原音轨的实际编码标识。
        CMAudioFormatDescriptionRef audioFormat=(__bridge CMAudioFormatDescriptionRef)audioTrack.formatDescriptions.firstObject;
        if(audioFormat && CMFormatDescriptionGetMediaSubType(audioFormat)!=kAudioFormatMPEG4AAC) requiresEncoding=YES;
    }
    // generation：预处理不能完成已取消或复用的旧任务。
    NSUInteger generation=self.generation;
    if(requiresEncoding) {
        // 首次转换按请求质量编码；复用已完成结果，不以源文件大小追加编码。
        self.sc_requiresEncodingConversion=YES; self.sc_sourceBaselineURL=sourceURL;
        [self sc_startAttempt]; return;
    }
    // repack：仅变更容器/网络文件头，不解码和重编码视频；兼容容器仍以源文件为基准。
    BOOL mp4=[self.sc_configuration.outputFileType isEqual:AVFileTypeMPEG4];
    // prefix：识别真实容器标记，而不是仅相信扩展名。
    NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:sourceURL error:nil];
    // prefix：文件头的真实主品牌字段。
    NSData *prefix=[file readDataOfLength:12]; [file closeFile];
    // brand：QuickTime 与 MP4 的主兼容品牌。
    NSString *brand=prefix.length==12 ? [[NSString alloc]initWithBytes:(const uint8_t *)prefix.bytes+8 length:4 encoding:NSASCIIStringEncoding] : nil;
    if(((mp4 && [@[@"isom",@"iso2",@"mp41",@"mp42",@"avc1"]containsObject:brand]) || (!mp4 && [brand isEqual:@"qt  "])) && (!self.sc_configuration.shouldOptimizeForNetworkUse || sc_HasFastStart(sourceURL))) {
        self.sc_sourceBaselineURL=sourceURL; [self sc_startAttempt]; return;
    }
    // repackURL：生命周期仅属于本轮的无损容器转换结果。
    NSURL *repackURL=[self.activeOutputURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:mp4 ? @"mp4" : @"mov"]];
    self.sc_repackSession=[[AVAssetExportSession alloc]initWithAsset:self.asset presetName:AVAssetExportPresetPassthrough];
    self.sc_repackSession.outputURL=repackURL; self.sc_repackSession.outputFileType=self.sc_configuration.outputFileType;
    self.sc_repackSession.shouldOptimizeForNetworkUse=self.sc_configuration.shouldOptimizeForNetworkUse;
    self.sc_repackSession.metadata=[AVMetadataItem metadataItemsFromArray:self.asset.metadata filteredByIdentifier:AVMetadataIdentifierQuickTimeMetadataContentIdentifier];
    [self.sc_repackSession exportAsynchronouslyWithCompletionHandler:^{dispatch_async(self.inputQueue,^{
        if(self.generation!=generation || !self.runningSession) { [NSFileManager.defaultManager removeItemAtURL:repackURL error:nil]; return; }
        // success：容器转换必须实际完成才能建立基准。
        BOOL success=self.sc_repackSession.status==AVAssetExportSessionStatusCompleted;
        // error：保留系统转换错误用于终态报告。
        NSError *error=self.sc_repackSession.error; self.sc_repackSession=nil;
        if(!success) { [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:error ?: sc_ExportError(@"Required container conversion failed")]; return; }
        self.sc_sourceBaselineURL=repackURL; self.sc_result.usesConvertedBaseline=YES; self.sc_result.conversionBytes=[NSFileManager.defaultManager attributesOfItemAtPath:repackURL.path error:nil].fileSize; [self sc_startAttempt];
    });}];
}

/// 回退仍需满足本次几何、编辑和格式约束；不能用大尺寸或未编辑源绕过配置。
- (BOOL)sc_canReturnCompressionBaseline {
    if(!self.sc_sourceBaselineURL) return NO;
    if(self.sc_requiresEncodingConversion)return [self.sc_sourceBaselineURL isEqual:self.activeOutputURL];
    if(self.sc_configuration.shouldOptimizeForNetworkUse && !sc_HasFastStart(self.sc_sourceBaselineURL)) return NO;
    if(self.sc_configuration.delegate || self.videoPixelBufferAdaptor || self.sc_configuration.videoComposition || self.sc_configuration.audioMix || self.sc_configuration.metadata || self.sc_configuration.videoInputSettings || self.sc_configuration.audioInputSettings || self.sc_configuration.videoOutputSettings || self.sc_configuration.audioOutputSettings || self.exportBitRate>0 || CMTimeCompare(self.exportRange.start,kCMTimeZero)!=0 || CMTimeCompare(self.exportRange.duration,self.asset.duration)!=0) return NO;
    // baseline：待回退文件的真实媒体描述。
    AVAsset *baseline=[AVAsset assetWithURL:self.sc_sourceBaselineURL];
    if([baseline tracksWithMediaType:AVMediaTypeVideo].count!=1 || [baseline tracksWithMediaType:AVMediaTypeAudio].count>1) return NO;
    // 普通顶层元数据不是输出硬约束；只有显式 metadata 编辑才阻止原文件回退。
    // track：回退视频需要符合尺寸、方向、帧率和 SDR 要求。
    AVAssetTrack *track=[baseline tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // allowedTypes：回退不能重新引入压缩路径会移除的无关定时元数据。
    NSDictionary *allowedTypes=sc_LiveMetadataTypes();
    // metadataTrack：回退素材中实际保留的定时元数据轨道。
    for(AVAssetTrack *metadataTrack in [baseline tracksWithMediaType:AVMediaTypeMetadata]) {
        // description：定时元数据轨道的字段说明。
        for(id description in metadataTrack.formatDescriptions) {
            // identifiers：真实元数据标识，不读取私人内容。
            NSArray *identifiers=(__bridge NSArray *)CMMetadataFormatDescriptionGetIdentifiers((__bridge CMFormatDescriptionRef)description);
            // identifier：不允许回退时重新引入无关字段。
            for(NSString *identifier in identifiers) if(!allowedTypes[identifier]) return NO;
        }
    }
    // settings：现有压缩算法计算的目标尺寸。
    NSDictionary *settings=[self sc_configVideoOutput];
    // size：源文件的实际显示尺寸。
    CGSize size=track?sc_PresentationSize(track):CGSizeZero;
    return track && !self.fullFrameAsset && CGAffineTransformIsIdentity(track.preferredTransform) && size.width<=[settings[AVVideoWidthKey]doubleValue] && size.height<=[settings[AVVideoHeightKey]doubleValue] && track.nominalFrameRate>0 && track.nominalFrameRate<=self.exportMaximumFrameRate && (self.sc_exportsHDR ? sc_HDRVideoMatches(baseline,self.sc_exportColorProperties) : ![baseline tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count);
}

- (AVAsset *)sc_processingAsset { return self.fullFrameAsset ?: self.asset; }

- (BOOL)sc_canCopyAudioTrack:(AVAssetTrack *)track {
    if (self.sc_configuration.audioMix || self.sc_configuration.audioInputSettings || self.sc_configuration.audioOutputSettings ||
        CMTimeCompare(self.exportRange.start, kCMTimeZero) != 0 ||
        CMTimeCompare(self.exportRange.duration, self.sc_processingAsset.duration) != 0 ||
        !isfinite(track.estimatedDataRate) || track.estimatedDataRate <= 0 ||
        !track.formatDescriptions.count) return NO;
    // description：说明。
    for (id description in track.formatDescriptions) {
        // audio：音频。
        const AudioStreamBasicDescription *audio = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMFormatDescriptionRef)description);
        if (!audio || audio->mFormatID != kAudioFormatMPEG4AAC || audio->mChannelsPerFrame < 1 ||
            audio->mChannelsPerFrame > 2 || !isfinite(audio->mSampleRate) || audio->mSampleRate < 8000 || audio->mSampleRate > 48000 ||
            audio->mSampleRate != track.naturalTimeScale) return NO;
    }
    return YES;
}

- (NSError *)sc_prepareFullFrameSource {
    if (!self.sc_exportsLivePhoto || self.sc_configuration.videoComposition || ![self.asset isKindOfClass:AVURLAsset.class]) return nil;
    // sourceURL：原始URL。
    NSURL *sourceURL = [(AVURLAsset *)self.asset URL];
    if (!sourceURL.isFileURL) return nil;
    // dimensions：轨道 ID 到原始完整编码尺寸的映射。
    // cropped：是否存在不满幅的 clean aperture。
    NSMutableDictionary *dimensions = [NSMutableDictionary dictionary]; BOOL cropped = NO;
    // track：轨道。
    for (AVAssetTrack *track in [self.asset tracksWithMediaType:AVMediaTypeVideo]) {
        // format：格式。
        CMVideoFormatDescriptionRef format = (__bridge CMVideoFormatDescriptionRef)track.formatDescriptions.firstObject;
        if (!format) continue;
        // size：尺寸。
        CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format);
        if (size.width < 1 || size.height < 1) continue;
        dimensions[@(track.trackID)] = [NSValue valueWithBytes:&size objCType:@encode(CMVideoDimensions)];
        // clean：有效显示区。
        CGRect clean = CMVideoFormatDescriptionGetCleanAperture(format, YES);
        if (!CGRectEqualToRect(clean, CGRectMake(0, 0, size.width, size.height))) cropped = YES;
    }
    if (!cropped) return nil;
    // copy：副本。
    NSURL *copy = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"sdav-live-full-frame-" stringByAppendingString:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mov"]]]];
    // error：错误。
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:sourceURL toURL:copy error:&error]) return error;
    self.fullFrameSourceURL = copy;
    // PhotoKit/cache sources may be read-only; only the isolated copy must be writable.
    if (![NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:copy.path error:&error]) return error;
    // file：当前操作使用的文件句柄。
    NSFileHandle *file = [NSFileHandle fileHandleForUpdatingURL:copy error:&error];
    if (!file) return error ?: sc_ExportError(@"Could not normalize Live Photo aperture");
    @try {
        // length：长度。
        uint64_t length = [file seekToEndOfFile];
        // changes：实际修正的画幅字段数量。
        NSUInteger changes = sc_ExposeFullLiveFrame(file, 0, length, dimensions, (CMVideoDimensions){0, 0}, 0);
        [file closeAndReturnError:nil];
        if (!changes) return sc_ExportError(@"Unsupported Live Photo aperture layout");
        self.fullFrameAsset = [AVURLAsset URLAssetWithURL:copy options:nil];
    // exception：格式解析或媒体处理异常。
    } @catch (NSException *exception) {
        [file closeAndReturnError:nil];
        return sc_ExportError(@"Invalid Live Photo aperture layout");
    }
    return nil;
}
- (void)sc_completeWithStatus:(AVAssetExportSessionStatus)status error:(NSError *)error {
    self.generation++;
    if (status == AVAssetExportSessionStatusCompleted && self.sc_outputFolder && !self.sc_configuration.defersPublication &&
        !sc_PublishOutput(self.activeOutputURL, self.sc_result.outputURL, &error)) {
        status = AVAssetExportSessionStatusFailed;
    }
    [self.sc_repackSession cancelExport]; self.sc_repackSession=nil;
    // now：当前唯一终态的计时终点。
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    // prepare：格式/容器处理和压缩写入器准备时间。
    double prepare=(self.sc_compressionStartedAt ?: now)-self.exportStartedAt;
    // compress：压缩编码时间，包含有界瞬态错误重试。
    double compress=self.sc_compressionStartedAt ? (self.sc_compressionFinishedAt ?: now)-self.sc_compressionStartedAt : 0;
    // total：本次操作的完整耗时，不含调用方下载。
    double total=now-self.exportStartedAt;
    self.sc_result.stageDurations=@{@"prepare":@(MAX(0,prepare)),@"compress":@(MAX(0,compress)),@"finish":@(MAX(0,total-prepare-compress)),@"total":@(MAX(0,total))};
    sc_log(@"[SCVideoCompressor][%@] passes=%lu stages=%@",self.logIdentifier,(unsigned long)self.sc_result.encodingPassCount,self.sc_result.stageDurations);
    // outputBytes：输出字节。
    NSNumber *outputBytes = status == AVAssetExportSessionStatusCompleted ? [NSFileManager.defaultManager attributesOfItemAtPath:self.activeOutputURL.path error:nil][NSFileSize] : nil;
    // saved：本次输出相对输入节省的字节比例。
    NSString *saved = self.sc_result.comparisonBytes && outputBytes ? [NSString stringWithFormat:@"%.2f%%", (1 - outputBytes.doubleValue / self.sc_result.comparisonBytes) * 100] : @"n/a";
    sc_log(@"[SCVideoCompressor][%@] comparisonBytes=%llu converted=%@",self.logIdentifier,self.sc_result.comparisonBytes,self.sc_result.usesConvertedBaseline ? @"yes" : @"no");
    sc_log(@"[SCVideoCompressor][%@] after status=%@ inputBytes=%@ outputBytes=%@ outputKB=%@ outputMB=%@ saved=%@ elapsed=%.3fs", self.logIdentifier,
        sc_StatusName(status), self.inputFileBytes ? @(self.inputFileBytes) : @"unknown", outputBytes ?: @"unavailable", outputBytes ? [NSString stringWithFormat:@"%.2f", outputBytes.doubleValue / 1024.0] : @"n/a",
        outputBytes ? [NSString stringWithFormat:@"%.3f", outputBytes.doubleValue / (1024.0 * 1024.0)] : @"n/a", saved, CFAbsoluteTimeGetCurrent() - self.exportStartedAt);
    [self sc_releaseAttempt];self.sc_fidelityReferences=nil;
    if(status!=AVAssetExportSessionStatusCompleted){self.sc_result.fidelityScore=nil;self.sc_result.qualityStatus=SCVideoQualityStatusNotEvaluated;self.sc_result.qualitySampleCount=0;}
    self.fullFrameAsset = nil;
    if (self.fullFrameSourceURL) [NSFileManager.defaultManager removeItemAtURL:self.fullFrameSourceURL error:nil];
    self.fullFrameSourceURL = nil;
    self.sc_result.error = error;
    if (status == AVAssetExportSessionStatusCompleted) [self sc_setProgress:1];
    // 只删除独占目录，不根据最终路径是否存在推断所有权。
    if (status == AVAssetExportSessionStatusCompleted && self.sc_configuration.defersPublication) {
        self.sc_result.stagedFolder = self.sc_outputFolder;
        self.sc_result.stagedFile = self.activeOutputURL;
    } else if (self.sc_outputFolder) {
        [NSFileManager.defaultManager removeItemAtURL:self.sc_outputFolder error:nil];
    }
    self.sc_outputFolder = nil;
    [self sc_setStatus:status];
    // handler：本轮唯一的完成回调。
    dispatch_block_t handler = self.completionHandler;
    // result：与后续轮次分离的终态对象。
    SCVideoExportResult *result = self.sc_result;
    // delivery：先交付本轮之前入队的进度，再交付完成。
    dispatch_queue_t delivery = self.sc_deliveryQueue;
    // configuredQueue：自定义队列直接负责回调，默认完成返回导出队列。
    BOOL configuredQueue = self.sc_hasCallbackQueue;
    self.sc_deliveryQueue = nil;
    self.sc_exportProgressHandler = nil;
    self.completionHandler = nil;
    self.sc_configuration = nil;
    self.runningSession = nil;
    if (!handler) return;

    // complete：即使内部已开始下一轮，回调仍读取它自己的结果。
    dispatch_block_t complete = ^{ [self sc_deliverResult:result handler:handler]; };
    if (configuredQueue) dispatch_async(delivery, complete);
    else if (delivery) dispatch_async(delivery, ^{ dispatch_async(self.inputQueue, complete); });
    else complete();
}

/// 终态锁定后提交高层视频，只清理与该次结果绑定的目录。
- (BOOL (^)(BOOL, NSError **))sc_deferredPublication {
    // result：捕获当前完成块所属的轮次，允许在主队列交付。
    SCVideoExportResult *result = self.sc_callbackResult;
    // deliver、error：终态是否交付，以及实际文件系统错误。
    return ^BOOL(BOOL deliver, NSError **error) {
        // success：链接失败时保留目标和真实系统错误。
        BOOL success = deliver && sc_PublishOutput(result.stagedFile, result.outputURL, error);
        if (result.stagedFolder) [NSFileManager.defaultManager removeItemAtURL:result.stagedFolder error:nil];
        result.stagedFolder = nil;
        result.stagedFile = nil;
        return success;
    };
}

/// 状态 KVO 仍由导出队列发布。
- (void)sc_setStatus:(AVAssetExportSessionStatus)status {
    [self willChangeValueForKey:@"status"];
    self.sc_result.status = status;
    [self didChangeValueForKey:@"status"];
}

/// 进度由导出队列发布，调用者回调由本轮串行交付队列执行。
- (void)sc_setProgress:(float)progress {
    [self willChangeValueForKey:@"progress"];
    self.sc_result.progress = progress;
    [self didChangeValueForKey:@"progress"];
    // callback：本轮固定的接收器，后台修改下一轮配置不会替换它。
    void (^callback)(float) = self.sc_exportProgressHandler;
    if (callback) dispatch_async(self.sc_deliveryQueue, ^{ callback(progress); });
}

- (void)sc_cancelExport {
    dispatch_async(self.inputQueue, ^{
        if (self.runningSession) [self sc_completeWithStatus:AVAssetExportSessionStatusCancelled error:nil];
    });
}

/// 导出时复用本轮检测结果，编码预算探针仍可以在导出前查询默认策略。
- (BOOL)sc_usesLivePhotoGeometry {
    return self.runningSession ? self.sc_exportsLivePhoto : (self.livePhoto || sc_IsLivePhotoAsset(self.asset));
}

/// 普通视频和 Live 按各自配置限制实际显示尺寸。
- (CGSize)sc_formatTargetSize:(CGSize)targetSize {
    // Restoring a camera Live Photo's complete encoded aperture is for composition only.
    // Bound the full frame by the ORIGINAL displayed width/height so normalization cannot upscale output.
    // live：导出期间复用捕获的检测结果，独立查询仍根据当前配置计算。
    BOOL live = [self sc_usesLivePhotoGeometry];
    if (live && targetSize.width > 0 && targetSize.height > 0) {
        // original：原始资源。
        AVAssetTrack *original = [self.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        // bounds：边界。
        CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, sc_PresentationSize(original)}, original.preferredTransform);
        // width：宽度。
        // height：高度。
        double width = fabs(bounds.size.width), height = fabs(bounds.size.height);
        if (isfinite(width) && isfinite(height) && width > 0 && height > 0) {
            // scale：比例。
            double scale = MIN(1, MIN(width / targetSize.width, height / targetSize.height));
            targetSize = CGSizeMake(targetSize.width * scale, targetSize.height * scale);
        }
    }
    if (!isfinite(targetSize.width) || !isfinite(targetSize.height) || targetSize.width < 2 || targetSize.height < 2) return CGSizeZero;
    //尺寸过大才压缩，否则不更改targetSize
    CGSize limits = self.runningSession ? self.exportMaximumSize : (live ? self.livePhotoImageOptions.maximumSize : self.maximumSize);
    if (!isfinite(limits.width) || !isfinite(limits.height) || limits.width < 0 || limits.height < 0) return CGSizeZero;
    // multiple：源尺寸相对配置的缩小倍数。
    double multiple = MAX(limits.width > 0 ? targetSize.width / limits.width : 0,
                          limits.height > 0 ? targetSize.height / limits.height : 0);
    if (multiple > 1) targetSize = CGSizeMake(targetSize.width / multiple, targetSize.height / multiple);
    return targetSize;
}

/// 编码视频
- (NSDictionary *)sc_configVideoOutput {
    // videoTracks：视频轨道集合。
    NSArray *videoTracks = [self.sc_processingAsset tracksWithMediaType:AVMediaTypeVideo];
    // videoTrack：视频轨道。
    AVAssetTrack *videoTrack = [videoTracks objectAtIndex:0];
    // realSize：real尺寸。
    CGSize realSize = CGSizeApplyAffineTransform(sc_PresentationSize(videoTrack), videoTrack.preferredTransform);
    // videoSize：视频尺寸。
    CGSize videoSize = [self sc_formatTargetSize:CGSizeMake(fabs(realSize.width), fabs(realSize.height))];
    // videoWidth：视频宽度。
    NSInteger videoWidth = ((NSInteger)videoSize.width) / 2 * 2;
    // videoHeight：视频高度。
    NSInteger videoHeight = ((NSInteger)videoSize.height) / 2 * 2;
    if (videoWidth < 2 || videoHeight < 2) return @{};
    videoSize = CGSizeMake(videoWidth, videoHeight);

    // frameRate：帧速率。
    double frameRate = videoTrack.nominalFrameRate;
    if (frameRate > self.exportMaximumFrameRate) {
        frameRate = self.exportMaximumFrameRate;
    } else if (!isfinite(frameRate) || frameRate < 1) {
        frameRate = 24;
    }

    //写入视频大小
    float numPixels = videoSize.width * videoSize.height;
    //每像素比特
    CGFloat bitsPerPixel = 0.0;
    if (numPixels < (640 * 480)) {
        bitsPerPixel =
            4.05;  // This bitrate approximately matches the quality produced by AVCaptureSessionPresetMedium or Low.
    } else {
        bitsPerPixel = 10.1;  // This bitrate approximately matches the quality produced by AVCaptureSessionPresetHigh.
    }
    // bitRate：比特速率。
    NSInteger bitRate = numPixels * bitsPerPixel;
    // livePixels：Live像素缓冲。
    double livePixels = [self sc_usesLivePhotoGeometry] ? MAX(1, numPixels/(1280.0*720)) : 1;
    bitRate = MIN(bitRate, sc_MaximumVideoBitRate * livePixels);
    // quality：质量。
    double quality = self.runningSession ? self.exportVideoQuality : self.videoQuality;
    // qualityMultiplier：自动候选预算与保真门槛分开，最高档也留出压缩空间。
    double qualityMultiplier = sc_VideoCompressionHeadroom*quality;
    bitRate = MAX(1, (NSInteger)(bitRate * qualityMultiplier));
    {
        // Source-aware budget: never promote a small compressed source to the pixel-area ceiling.
        // 最高档也低于源参考预算，较低档按比例生成候选；质量由实测一致度判断。
        // HEVC转H264不承诺同码率等画质；此预算避免压缩输出成倍增长。
        CGSize sourceSize = sc_PresentationSize(videoTrack);
        // sourcePixels：原始像素缓冲。
        double sourcePixels = fabs(sourceSize.width * sourceSize.height);
        // sourceRate：原始速率。
        double sourceRate = videoTrack.estimatedDataRate;
        if (isfinite(sourceRate) && sourceRate > 0 && isfinite(sourcePixels) && sourcePixels > 0) {
            // scale：比例。
            double scale = sqrt(MIN(1, numPixels / sourcePixels));
            bitRate = MAX(1, (NSInteger)MIN(bitRate, sourceRate * scale * qualityMultiplier));
        }
    }
    if (self.exportBitRate > 0) bitRate = self.exportBitRate;
    // compressProperties：编码属性字典。
    NSDictionary *compressProperties = @{
        AVVideoAverageBitRateKey : @(bitRate),
        AVVideoExpectedSourceFrameRateKey : @(frameRate),
        AVVideoProfileLevelKey : [self.exportCodec isEqualToString:AVVideoCodecTypeHEVC] ? (self.sc_exportsHDR ? @"HEVC_Main10_AutoLevel" : @"HEVC_Main_AutoLevel") : AVVideoProfileLevelH264HighAutoLevel
    };
    // compressSetting：编码设置。
    NSDictionary *compressSetting = @{
        AVVideoCodecKey : self.exportCodec ?: AVVideoCodecTypeH264,
        AVVideoWidthKey : @(videoSize.width),
        AVVideoHeightKey : @(videoSize.height),
        AVVideoCompressionPropertiesKey : compressProperties,
        AVVideoColorPropertiesKey : self.sc_exportColorProperties ?: sc_SDRColorProperties(),
        AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill
    };
    return compressSetting;
}

/// 编码音频
- (NSDictionary *)sc_configAudioOutput {
    // tracks：轨道集合。
    NSArray<AVAssetTrack *> *tracks = [self.sc_processingAsset tracksWithMediaType:AVMediaTypeAudio];
    // channels：目标声道数量。
    UInt32 channels = 0;
    // sourceRate：原始速率。
    // sourceBitRate：原始比特速率。
    double sourceRate = 0, sourceBitRate = 0;
    // knownBitRates：源音轨是否都有可读取的码率。
    BOOL knownBitRates = tracks.count > 0;
    // track：轨道。
    for (AVAssetTrack *track in tracks) {
        // description：说明。
        for (id description in track.formatDescriptions) {
            // audio：音频。
            const AudioStreamBasicDescription *audio = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMFormatDescriptionRef)description);
            if (audio) {
                channels = MAX(channels, MIN(2, audio->mChannelsPerFrame));
                if (isfinite(audio->mSampleRate)) sourceRate = MAX(sourceRate, audio->mSampleRate);
            }
        }
        if (isfinite(track.estimatedDataRate) && track.estimatedDataRate > 0) sourceBitRate += track.estimatedDataRate;
        else knownBitRates = NO;
    }
    if (!channels) channels = 2;
    // sampleRate：采样速率。
    double sampleRate = sc_MaximumAudioSampleRate;
    if (sourceRate > 0) {
        // rates：AAC允许的采样率集合。
        static const double rates[] = {8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100};
        sampleRate = rates[0];
        // i：当前循环索引。
        for (NSUInteger i = 0; i < sizeof(rates)/sizeof(rates[0]); i++) {
            if (rates[i] <= sourceRate) sampleRate = rates[i];
        }
    }
    // bitRate：比特速率。
    NSInteger bitRate = knownBitRates ? MIN(sc_MaximumAudioBitRate, MAX(8000 * channels, (NSInteger)sourceBitRate)) : sc_MaximumAudioBitRate;
    // layout：音频声道布局描述。
    AudioChannelLayout layout = {
        .mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo,
        .mChannelBitmap = 0, .mNumberChannelDescriptions = 0};
    // data：编码数据。
    NSData *data = [NSData dataWithBytes:&layout length:offsetof(AudioChannelLayout, mChannelDescriptions)];
    // compressSettings：编码设置。
    NSDictionary *compressSettings = @{
        AVFormatIDKey : @(kAudioFormatMPEG4AAC),
        AVEncoderBitRateKey : @(bitRate),
        AVSampleRateKey : @(sampleRate),
        AVChannelLayoutKey : data,
        AVNumberOfChannelsKey : @(channels)
    };
    return compressSettings;
}

///视频解码
- (NSDictionary *)sc_configVideoInput {
    // SDR 使用 NV12；业务渲染和 HDR 转 SDR 保留原 BGRA 路径；保留 HDR 使用 10-bit。
    NSDictionary *videoInputSetting = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
            [NSNumber numberWithUnsignedInt:self.sc_exportsHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : ((self.sc_configuration.delegate||[self.sc_processingAsset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count) ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
    };
    return videoInputSetting;
}

///音频解码
- (NSDictionary *)sc_configAudioInput {
    // audioInputSetting：音频输入设置。
    NSDictionary *audioInputSetting = @{AVFormatIDKey : @(kAudioFormatLinearPCM)};
    return audioInputSetting;
}

@end
