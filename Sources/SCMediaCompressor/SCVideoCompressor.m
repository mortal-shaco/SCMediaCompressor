#import "SCVideoCompressorInternal.h"
#import <unistd.h>
#import <errno.h>

@implementation SCVideoCompressor
/// 读取本轮捕获的保真请求，不受后续复用配置影响。
- (double)sc_requestedQuality {return self.exportVideoQuality;}
/// 读取与图片相同语义的有效门槛。
- (double)sc_effectiveQualityTarget {return sc_EffectiveFidelityTarget(self.exportVideoQuality);}

@synthesize progress = _progress;

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
        _status = AVAssetExportSessionStatusUnknown;
    }
    return self;
}

- (void)sc_exportAsynchronouslyWithCompletionHandler:(void (^)(void))handler {
    dispatch_async(self.inputQueue, ^{
        if (self.runningSession) {
            [self sc_completeWithStatus:AVAssetExportSessionStatusCancelled error:nil];
        }
        self.generation++;
        // generation：异步操作代数，用于隔离取消或复用后的旧回调。
        NSUInteger generation = self.generation;
        self.completionHandler = handler;
        self.runningSession = self;
        self.activeOutputURL = self.outputURL;
        self.sc_destinationURL=self.outputURL; self.sc_publishedIdentity=nil;
        self.retryCount = 0;
        self.comparisonBytes = 0; self.usesConvertedBaseline = NO;
        self.encodingPassCount=0; self.stageDurations=@{};
        self.sc_compressionStartedAt=0; self.sc_compressionFinishedAt=0;
        self.sc_sourceBaselineURL=nil; self.sc_requiresEncodingConversion=NO;
        self.conversionBytes=0;self.fidelityScore=nil;self.candidateFidelityScore=nil;self.qualityStatus=SCVideoQualityStatusNotEvaluated;self.qualitySampleCount=0;self.qualityEvaluationDuration=0;

        self.exportVideoQuality = self.videoQuality;
        self.exportMaximumSize = self.maximumSize;
        self.exportLivePhotoImageOptions = [self.livePhotoImageOptions copy] ?: [SCImageCompressionOptions new];
        self.exportCodec = AVVideoCodecTypeH264;
        self.sc_exportPreservesHDR=self.preservesHDR;self.sc_exportsHDR=NO;self.sc_exportColorProperties=sc_SDRColorProperties();
        self.exportMaximumFrameRate = isfinite(self.maximumFrameRate) && self.maximumFrameRate > 0 ? self.maximumFrameRate : 30;
        self.exportBitRate = MAX(0, self.videoBitRate);




        self.progress = 0;
        self.exportError = nil;
        self.status = AVAssetExportSessionStatusWaiting;
        self.logIdentifier = [NSUUID.UUID.UUIDString substringToIndex:8];
        self.exportStartedAt = CFAbsoluteTimeGetCurrent();
        // inputURL：输入URL。
        NSURL *inputURL = [self.asset isKindOfClass:AVURLAsset.class] ? [(AVURLAsset *)self.asset URL] : nil;
        // inputBytes：输入字节。
        NSNumber *inputBytes = inputURL.isFileURL ? [NSFileManager.defaultManager attributesOfItemAtPath:inputURL.path error:nil][NSFileSize] : nil;
        self.inputFileBytes = inputBytes.unsignedLongLongValue;
        self.comparisonBytes = 0;
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
        // template：在目标所在文件系统上独占创建工作目录，避免共享目标的先检查后写入竞态。
        char *template=strdup([[self.activeOutputURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@".scmedia-XXXXXX"].path fileSystemRepresentation]);
        if (!mkdtemp(template)) {
            // directoryError：保留目录创建失败的系统原因。
            NSError *directoryError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            free(template); [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:directoryError]; return;
        }
        self.sc_outputFolder=[NSURL fileURLWithFileSystemRepresentation:template isDirectory:YES relativeToURL:nil]; free(template);
        self.activeOutputURL=[self.sc_outputFolder URLByAppendingPathComponent:self.sc_destinationURL.lastPathComponent];
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
    if (!self.livePhoto && !sc_IsLivePhotoAsset(self.asset)) return;
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
    NSString *explicitCodec=self.videoOutputSettings[AVVideoCodecKey];
    if(explicitCodec && ![explicitCodec isEqual:self.exportCodec])return sc_VideoConfigurationError(@"Explicit codec conflicts with source range: SDR uses H264; retained HDR uses HEVC");
    if (!self.sc_exportPreservesHDR) return nil;
    if (!colors) return [self.asset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count ? sc_VideoConfigurationError(@"Unsupported source HDR color description") : nil;
    if (![self.outputFileType isEqual:AVFileTypeMPEG4] && ![self.outputFileType isEqual:AVFileTypeQuickTimeMovie]) return sc_VideoConfigurationError(@"HDR video supports MP4 or MOV containers");
    if (self.delegate || self.videoPixelBufferAdaptor || self.videoComposition.customVideoCompositorClass) return sc_VideoConfigurationError(@"HDR preservation does not support BGRA render delegates or custom compositors");
    if (self.videoInputSettings && [self.videoInputSettings[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey]unsignedIntValue]!=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) return sc_VideoConfigurationError(@"HDR preservation requires 10-bit video-range pixel buffers");
    // profile：显式 8-bit 编码设置不能被静默覆盖。
    NSString *profile=self.videoOutputSettings[AVVideoCompressionPropertiesKey][AVVideoProfileLevelKey];
    if (profile && ![profile isEqual:@"HEVC_Main10_AutoLevel"]) return sc_VideoConfigurationError(@"HDR preservation requires the HEVC Main10 profile");
    // explicitColors：显式色彩必须与源 HDR 一致。
    NSDictionary *explicitColors=self.videoOutputSettings[AVVideoColorPropertiesKey];
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
    NSString *targetCodec=self.videoOutputSettings[AVVideoCodecKey] ?: self.exportCodec;
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
    BOOL mp4=[self.outputFileType isEqual:AVFileTypeMPEG4];
    // prefix：识别真实容器标记，而不是仅相信扩展名。
    NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:sourceURL error:nil];
    // prefix：文件头的真实主品牌字段。
    NSData *prefix=[file readDataOfLength:12]; [file closeFile];
    // brand：QuickTime 与 MP4 的主兼容品牌。
    NSString *brand=prefix.length==12 ? [[NSString alloc]initWithBytes:(const uint8_t *)prefix.bytes+8 length:4 encoding:NSASCIIStringEncoding] : nil;
    if(((mp4 && [@[@"isom",@"iso2",@"mp41",@"mp42",@"avc1"]containsObject:brand]) || (!mp4 && [brand isEqual:@"qt  "])) && (!self.shouldOptimizeForNetworkUse || sc_HasFastStart(sourceURL))) {
        self.sc_sourceBaselineURL=sourceURL; [self sc_startAttempt]; return;
    }
    // repackURL：生命周期仅属于本轮的无损容器转换结果。
    NSURL *repackURL=[self.activeOutputURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:mp4 ? @"mp4" : @"mov"]];
    self.sc_repackSession=[[AVAssetExportSession alloc]initWithAsset:self.asset presetName:AVAssetExportPresetPassthrough];
    self.sc_repackSession.outputURL=repackURL; self.sc_repackSession.outputFileType=self.outputFileType;
    self.sc_repackSession.shouldOptimizeForNetworkUse=self.shouldOptimizeForNetworkUse;
    self.sc_repackSession.metadata=[AVMetadataItem metadataItemsFromArray:self.asset.metadata filteredByIdentifier:AVMetadataIdentifierQuickTimeMetadataContentIdentifier];
    [self.sc_repackSession exportAsynchronouslyWithCompletionHandler:^{dispatch_async(self.inputQueue,^{
        if(self.generation!=generation || !self.runningSession) { [NSFileManager.defaultManager removeItemAtURL:repackURL error:nil]; return; }
        // success：容器转换必须实际完成才能建立基准。
        BOOL success=self.sc_repackSession.status==AVAssetExportSessionStatusCompleted;
        // error：保留系统转换错误用于终态报告。
        NSError *error=self.sc_repackSession.error; self.sc_repackSession=nil;
        if(!success) { [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:error ?: sc_ExportError(@"Required container conversion failed")]; return; }
        self.sc_sourceBaselineURL=repackURL; self.usesConvertedBaseline=YES; self.conversionBytes=[NSFileManager.defaultManager attributesOfItemAtPath:repackURL.path error:nil].fileSize; [self sc_startAttempt];
    });}];
}

/// 回退仍需满足本次几何、编辑和格式约束；不能用大尺寸或未编辑源绕过配置。
- (BOOL)sc_canReturnCompressionBaseline {
    if(!self.sc_sourceBaselineURL) return NO;
    if(self.sc_requiresEncodingConversion)return [self.sc_sourceBaselineURL isEqual:self.activeOutputURL];
    if(self.shouldOptimizeForNetworkUse && !sc_HasFastStart(self.sc_sourceBaselineURL)) return NO;
    if(self.delegate || self.videoPixelBufferAdaptor || self.videoComposition || self.audioMix || self.metadata || self.videoInputSettings || self.audioInputSettings || self.videoOutputSettings || self.audioOutputSettings || self.exportBitRate>0 || CMTimeCompare(self.exportRange.start,kCMTimeZero)!=0 || CMTimeCompare(self.exportRange.duration,self.asset.duration)!=0) return NO;
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
    if (self.audioMix || self.audioInputSettings || self.audioOutputSettings ||
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
    // live：是否按Live配对视频处理。
    BOOL live = self.livePhoto || sc_IsLivePhotoAsset(self.asset);
    if (!live || self.videoComposition || ![self.asset isKindOfClass:AVURLAsset.class]) return nil;
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
    if (status==AVAssetExportSessionStatusCompleted && self.sc_outputFolder) {
        // identity：发布前保存实际写入文件的身份；link 不覆盖已存在的目标或符号链接。
        NSDictionary *identity=[NSFileManager.defaultManager attributesOfItemAtPath:self.activeOutputURL.path error:nil];
        if (link(self.activeOutputURL.fileSystemRepresentation,self.sc_destinationURL.fileSystemRepresentation)!=0) {
            status=AVAssetExportSessionStatusFailed; error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        } else self.sc_publishedIdentity=identity;
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
    self.stageDurations=@{@"prepare":@(MAX(0,prepare)),@"compress":@(MAX(0,compress)),@"finish":@(MAX(0,total-prepare-compress)),@"total":@(MAX(0,total))};
    sc_log(@"[SCVideoCompressor][%@] passes=%lu stages=%@",self.logIdentifier,(unsigned long)self.encodingPassCount,self.stageDurations);
    // outputBytes：输出字节。
    NSNumber *outputBytes = status == AVAssetExportSessionStatusCompleted ? [NSFileManager.defaultManager attributesOfItemAtPath:self.activeOutputURL.path error:nil][NSFileSize] : nil;
    // saved：本次输出相对输入节省的字节比例。
    NSString *saved = self.comparisonBytes && outputBytes ? [NSString stringWithFormat:@"%.2f%%", (1 - outputBytes.doubleValue / self.comparisonBytes) * 100] : @"n/a";
    sc_log(@"[SCVideoCompressor][%@] comparisonBytes=%llu converted=%@",self.logIdentifier,self.comparisonBytes,self.usesConvertedBaseline ? @"yes" : @"no");
    sc_log(@"[SCVideoCompressor][%@] after status=%@ inputBytes=%@ outputBytes=%@ outputKB=%@ outputMB=%@ saved=%@ elapsed=%.3fs", self.logIdentifier,
        sc_StatusName(status), self.inputFileBytes ? @(self.inputFileBytes) : @"unknown", outputBytes ?: @"unavailable", outputBytes ? [NSString stringWithFormat:@"%.2f", outputBytes.doubleValue / 1024.0] : @"n/a",
        outputBytes ? [NSString stringWithFormat:@"%.3f", outputBytes.doubleValue / (1024.0 * 1024.0)] : @"n/a", saved, CFAbsoluteTimeGetCurrent() - self.exportStartedAt);
    [self sc_releaseAttempt];self.sc_fidelityReferences=nil;
    if(status!=AVAssetExportSessionStatusCompleted){self.fidelityScore=nil;self.qualityStatus=SCVideoQualityStatusNotEvaluated;self.qualitySampleCount=0;}
    self.fullFrameAsset = nil;
    if (self.fullFrameSourceURL) [NSFileManager.defaultManager removeItemAtURL:self.fullFrameSourceURL error:nil];
    self.fullFrameSourceURL = nil;
    self.exportError = error;
    self.status = status;
    if (status == AVAssetExportSessionStatusCompleted) self.progress = 1;
    // 只删除独占目录，不根据最终路径是否存在推断所有权。
    if (self.sc_outputFolder) [NSFileManager.defaultManager removeItemAtURL:self.sc_outputFolder error:nil];
    self.sc_outputFolder=nil;
    // handler：当前阶段的回调快照。
    void (^handler)(void) = self.completionHandler;
    self.completionHandler = nil;
    self.runningSession = nil;
    if (handler) { if (self.callbackQueue) dispatch_async(self.callbackQueue, handler); else handler(); }
}

/// 高层在交付前取消时仅移除仍属于本轮的发布文件。
- (void)sc_removePublishedOutput {
    // current：目标可能已被调用方替换，核对设备号和 inode 后才允许清理。
    NSDictionary *current=[NSFileManager.defaultManager attributesOfItemAtPath:self.sc_destinationURL.path error:nil];
    if (self.sc_publishedIdentity && [current[NSFileSystemNumber]isEqual:self.sc_publishedIdentity[NSFileSystemNumber]] && [current[NSFileSystemFileNumber]isEqual:self.sc_publishedIdentity[NSFileSystemFileNumber]]) {
        [NSFileManager.defaultManager removeItemAtURL:self.sc_destinationURL error:nil];
    }
}

- (float)sc_progress { @synchronized(self) { return _progress; } }

- (void)sc_setProgress:(float)progress {
    [self willChangeValueForKey:@"progress"];
    @synchronized(self) { _progress = progress; }
    [self didChangeValueForKey:@"progress"];
    if (self.progressHandler) {
        // callback：回调。
        void (^callback)(float) = self.progressHandler;
        dispatch_async(self.callbackQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ callback(progress); });
    }
}

- (NSError *)sc_error {
    return self.exportError;
}

- (void)sc_cancelExport {
    dispatch_async(self.inputQueue, ^{
        if (self.runningSession) [self sc_completeWithStatus:AVAssetExportSessionStatusCancelled error:nil];
    });
}

/// Default video is bounded at 1280; paired Live video independently preserves up to 1920.
- (CGSize)sc_formatTargetSize:(CGSize)targetSize {
    // Restoring a camera Live Photo's complete encoded aperture is for composition only.
    // Bound the full frame by the ORIGINAL displayed width/height so normalization cannot upscale output.
    if ((self.livePhoto || sc_IsLivePhotoAsset(self.sc_processingAsset)) && targetSize.width > 0 && targetSize.height > 0) {
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
    CGSize limits = (self.livePhoto || sc_IsLivePhotoAsset(self.sc_processingAsset)) ? (self.exportLivePhotoImageOptions ?: self.livePhotoImageOptions).maximumSize : (self.runningSession ? self.exportMaximumSize : self.maximumSize);
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
    double livePixels = (self.livePhoto || sc_IsLivePhotoAsset(self.sc_processingAsset)) ? MAX(1, numPixels/(1280.0*720)) : 1;
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
            [NSNumber numberWithUnsignedInt:self.sc_exportsHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : ((self.delegate||[self.sc_processingAsset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count) ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
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
