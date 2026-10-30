#import "SCVideoCompressorInternal.h"

@implementation SCVideoCompressor (SCExport)
- (void)sc_startAttempt {
    self.sc_fidelityReferences=[NSMutableArray array];
    self.videoCompleted = NO;
    self.audioCompleted = NO;
    self.finishing = NO;
    self.liveMetadataOutputs = [NSMutableArray array];
    self.liveMetadataInputs = [NSMutableArray array];
    self.completedMetadataInputs = [NSMutableSet set];
    self.liveMetadataReaders = [NSMutableArray array];
    self.liveMetadataWriters = [NSMutableArray array];
    // assetDuration：素材时长。
    CMTime assetDuration = self.sc_processingAsset.duration;
    if (!CMTIME_IS_NUMERIC(assetDuration) || CMTimeCompare(assetDuration, kCMTimeZero) <= 0 ||
        [self.sc_processingAsset tracksWithMediaType:AVMediaTypeVideo].count == 0) {
        [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"No valid video track or duration")];
        return;
    }
    // range：范围。
    CMTimeRange range = self.timeRange;
    if (!CMTIME_IS_NUMERIC(range.start) || CMTimeCompare(range.start, kCMTimeZero) < 0) {
        [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Invalid export start time")];
        return;
    }
    if (CMTIME_IS_POSITIVE_INFINITY(range.duration)) {
        range.duration = CMTimeSubtract(assetDuration, range.start);
    }
    if (!CMTIMERANGE_IS_VALID(range) || !CMTIME_IS_NUMERIC(range.duration) ||
        CMTimeCompare(range.duration, kCMTimeZero) <= 0) {
        [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Invalid export duration")];
        return;
    }
    self.exportRange = CMTimeRangeGetIntersection(range, CMTimeRangeMake(kCMTimeZero, assetDuration));
    if (CMTimeCompare(self.exportRange.duration, kCMTimeZero) <= 0) {
        [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Export range is outside the asset")];
        return;
    }
    self.exportDuration = CMTimeGetSeconds(self.exportRange.duration);
    // error：错误。
    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:self.activeOutputURL.path]) {
        self.activeOutputURL = nil;
        error = sc_ExportError(@"Output already exists");
        [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:error];
        return;
    }
    @try {
        error = [self sc_prepareExportSession];
    // exception：格式解析或媒体处理异常。
    } @catch (NSException *exception) {
        error = sc_ExportError(exception.reason ?: @"Could not prepare export");
    }
    if (error) {
        [self sc_failAttempt:error];
        return;
    }
    self.encodingPassCount++;
    if(!self.sc_compressionStartedAt) self.sc_compressionStartedAt=CFAbsoluteTimeGetCurrent();
    self.status = AVAssetExportSessionStatusExporting;
    // generation：异步操作代数，用于隔离取消或复用后的旧回调。
    NSUInteger generation = self.generation;
    // weakSelf：避免异步块无意持有已结束会话。
    __weak typeof(self) weakSelf = self;
    [self.videoInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^{
        // session：会话。
        __strong typeof(weakSelf) session = weakSelf;
        if (session && session.generation == generation && !session.finishing && !session.videoCompleted) {
            [session sc_encodeReadySamplesFromOutput:session.videoOutput toInput:session.videoInput];
        }
    }];
    if (self.audioInput) {
        [self.audioInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^{
            // session：会话。
            __strong typeof(weakSelf) session = weakSelf;
            if (session && session.generation == generation && !session.finishing && !session.audioCompleted) {
                [session sc_encodeReadySamplesFromOutput:session.audioOutput toInput:session.audioInput];
            }
        }];
    }
    // input：输入。
    // index：索引。
    // stop：枚举提前结束标志。
    [self.liveMetadataInputs enumerateObjectsUsingBlock:^(AVAssetWriterInput *input, NSUInteger index, BOOL *stop) {
        // output：输出。
        AVAssetReaderTrackOutput *output = self.liveMetadataOutputs[index];
        [input requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^{
            // session：会话。
            __strong typeof(weakSelf) session = weakSelf;
            if (session && session.generation == generation && !session.finishing &&
                ![session.completedMetadataInputs containsObject:input]) {
                [session sc_encodeReadySamplesFromOutput:output toInput:input];
            }
        }];
    }];
}

- (NSError *)sc_prepareExportSession {
    // error：错误。
    NSError *error = nil;
    self.reader = [AVAssetReader assetReaderWithAsset:self.sc_processingAsset error:&error];
    if (!self.reader) return error ?: sc_ExportError(@"Could not create reader");
    self.writer = [AVAssetWriter assetWriterWithURL:self.activeOutputURL fileType:self.outputFileType error:&error];
    if (!self.writer) return error ?: sc_ExportError(@"Could not create writer");
    self.reader.timeRange = self.exportRange;
    self.writer.shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse;
    // metadata：元数据。
    NSMutableArray *metadata = [self.metadata mutableCopy] ?: [NSMutableArray array];
    // Keep the Live Photo pairing ID; do not copy HDR/color metadata into the SDR output.
    if (![AVMetadataItem metadataItemsFromArray:metadata filteredByIdentifier:AVMetadataIdentifierQuickTimeMetadataContentIdentifier].count) {
        [metadata addObjectsFromArray:[AVMetadataItem metadataItemsFromArray:self.sc_processingAsset.metadata
            filteredByIdentifier:AVMetadataIdentifierQuickTimeMetadataContentIdentifier]];
    }
    self.writer.metadata = metadata;

    // settings：设置。
    NSMutableDictionary *settings = [(self.videoOutputSettings ?: [self sc_configVideoOutput]) mutableCopy];
    if(self.livePhoto || sc_IsLivePhotoAsset(self.asset)) {
        // shared：图片配置决定 Live 最大画幅，高级视频设置不能突破该上限或放大源。
        NSDictionary *shared=[self sc_configVideoOutput];
        if([settings[AVVideoWidthKey]doubleValue]>[shared[AVVideoWidthKey]doubleValue] || [settings[AVVideoHeightKey]doubleValue]>[shared[AVVideoHeightKey]doubleValue])return sc_VideoConfigurationError(@"Live video dimensions exceed the shared image configuration");
    }
    // 按实际策略转换像素并写入一致色彩；默认 SDR 路径保持原样。
    settings[AVVideoColorPropertiesKey] = self.sc_exportColorProperties;
    settings[AVVideoCodecKey] = self.exportCodec;
    if(self.sc_exportsHDR){
        // compression：显式配置未给 profile 时补足 Main10，不覆盖已校验的其他参数。
        NSMutableDictionary *compression=[settings[AVVideoCompressionPropertiesKey]mutableCopy] ?: [NSMutableDictionary dictionary];
        compression[AVVideoProfileLevelKey]=@"HEVC_Main10_AutoLevel";settings[AVVideoCompressionPropertiesKey]=compression;
    }
    if (![self.writer canApplyOutputSettings:settings forMediaType:AVMediaTypeVideo]) {
        return sc_ExportError(@"Unsupported video output settings");
    }
    // composition：方向缩放及本轮动态范围的视频合成配置。
    AVMutableVideoComposition *composition = self.videoComposition
        ? [self.videoComposition mutableCopy] : [self sc_buildVideoCompositionWithSettings:settings];
    composition.colorPrimaries = self.sc_exportColorProperties[AVVideoColorPrimariesKey];
    composition.colorTransferFunction = self.sc_exportColorProperties[AVVideoTransferFunctionKey];
    composition.colorYCbCrMatrix = self.sc_exportColorProperties[AVVideoYCbCrMatrixKey];
    // sourceTrack：仅在几何、帧率和动态范围无需合成时直连解码与写入器，缩放由既有写入设置执行。
    AVAssetTrack *sourceTrack=[self.sc_processingAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // format：编码画幅必须与显示画幅一致，特殊 aperture 仍走既有合成路径。
    CMFormatDescriptionRef format=(__bridge CMFormatDescriptionRef)sourceTrack.formatDescriptions.firstObject;
    // dimensions：真实编码尺寸。
    CMVideoDimensions dimensions=format?CMVideoFormatDescriptionGetDimensions(format):(CMVideoDimensions){0,0};
    // direct：不改变方向、裁剪、HDR 转换、自定义合成或帧率规则，只移除无必要的全帧 RGB 中转。
    BOOL direct=!self.videoComposition&&!self.delegate&&!self.fullFrameAsset&&[self.sc_processingAsset tracksWithMediaType:AVMediaTypeVideo].count==1&&
        CGAffineTransformIsIdentity(sourceTrack.preferredTransform)&&sourceTrack.nominalFrameRate<=self.exportMaximumFrameRate&&
        CMTimeGetSeconds(sourceTrack.minFrameDuration)+.0001>=1/self.exportMaximumFrameRate&&
        (self.sc_exportsHDR||![self.sc_processingAsset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count)&&
        dimensions.height>0&&fabs((double)dimensions.width/dimensions.height-[settings[AVVideoWidthKey]doubleValue]/[settings[AVVideoHeightKey]doubleValue])<.001&&
        CGRectEqualToRect(CMVideoFormatDescriptionGetCleanAperture(format,YES),CGRectMake(0,0,dimensions.width,dimensions.height))&&
        CGSizeEqualToSize(CMVideoFormatDescriptionGetPresentationDimensions(format,YES,YES),CGSizeMake(dimensions.width,dimensions.height));
    if(direct)self.videoOutput=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:sourceTrack outputSettings:self.videoInputSettings?:[self sc_configVideoInput]];
    else {
        // output：需要真实几何/方向/色彩处理的素材继续使用既有合成器。
        AVAssetReaderVideoCompositionOutput *output=[AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:[self.sc_processingAsset tracksWithMediaType:AVMediaTypeVideo] videoSettings:self.videoInputSettings?:[self sc_configVideoInput]];
        output.videoComposition=composition;self.videoOutput=output;
    }
    self.videoOutput.alwaysCopiesSampleData = NO;
    if (![self.reader canAddOutput:self.videoOutput]) return sc_ExportError(@"Could not add video reader output");
    [self.reader addOutput:self.videoOutput];
    self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    self.videoInput.expectsMediaDataInRealTime = NO;
    if (![self.writer canAddInput:self.videoInput]) return sc_ExportError(@"Could not add video writer input");
    [self.writer addInput:self.videoInput];
    if ([self.delegate respondsToSelector:@selector(sc_exportSession:renderFrame:withPresentationTime:toBuffer:)]) {
        // attributes：像素缓冲池格式与尺寸参数。
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferWidthKey : settings[AVVideoWidthKey],
            (__bridge NSString *)kCVPixelBufferHeightKey : settings[AVVideoHeightKey]
        };
        self.videoPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoInput sourcePixelBufferAttributes:attributes];
    }

    // audioTracks：音频轨道集合。
    NSArray *audioTracks = [self.sc_processingAsset tracksWithMediaType:AVMediaTypeAudio];
    self.audioCompleted = audioTracks.count == 0;
    if (audioTracks.count) {
        // audioTrack：音频轨道。
        AVAssetTrack *audioTrack = audioTracks.firstObject;
        // copyAudio：副本音频。
        BOOL copyAudio = audioTracks.count == 1 && [self sc_canCopyAudioTrack:audioTrack];
        if (copyAudio) {
            self.audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:nil];
        } else {
            // output：输出。
            AVAssetReaderAudioMixOutput *output = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:audioTracks
                audioSettings:self.audioInputSettings ?: [self sc_configAudioInput]];
            output.audioMix = self.audioMix;
            self.audioOutput = output;
        }
        self.audioOutput.alwaysCopiesSampleData = NO;
        if (![self.reader canAddOutput:self.audioOutput]) return sc_ExportError(@"Could not add audio reader output");
        [self.reader addOutput:self.audioOutput];
        // audioSettings：音频设置。
        NSDictionary *audioSettings = copyAudio ? nil : (self.audioOutputSettings ?: [self sc_configAudioOutput]);
        if (audioSettings && ![self.writer canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio]) {
            return sc_ExportError(@"Unsupported audio output settings");
        }
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings
            sourceFormatHint:copyAudio ? (__bridge CMFormatDescriptionRef)audioTrack.formatDescriptions.firstObject : NULL];
        self.audioInput.expectsMediaDataInRealTime = NO;
        if (![self.writer canAddInput:self.audioInput]) return sc_ExportError(@"Could not add audio writer input");
        [self.writer addInput:self.audioInput];
    }
    // Keep only Live Photo timing/alignment items, including tracks mixed with unrelated metadata.
    // Filtering individual items avoids either losing the key timestamp or copying HDR metadata to SDR.
    // allowedTypes：允许保留的Live元数据类型集合。
    NSDictionary *allowedTypes = sc_LiveMetadataTypes();
    // track：轨道。
    for (AVAssetTrack *track in [self.sc_processingAsset tracksWithMediaType:AVMediaTypeMetadata]) {
        // format：格式。
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        if (!format || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Metadata) continue;
        // identifiers：元数据类型标识集合。
        NSArray *identifiers = (__bridge NSArray *)CMMetadataFormatDescriptionGetIdentifiers(format);
        // specifications：元数据格式描述使用的键与数据类型。
        NSMutableArray *specifications = [NSMutableArray array];
        // identifier：标识。
        for (NSString *identifier in identifiers) {
            if (!allowedTypes[identifier]) continue;
            [specifications addObject:@{(__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: identifier,
                (__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: allowedTypes[identifier]}];
        }
        if (!specifications.count) continue;
        // filteredFormat：只包含需要保留的 Live 元数据的格式描述。
        CMFormatDescriptionRef filteredFormat = NULL;
        // result：本次系统操作或编码结果。
        OSStatus result = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault,
            kCMMetadataFormatType_Boxed, (__bridge CFArrayRef)specifications, &filteredFormat);
        if (result != noErr || !filteredFormat) return sc_ExportError(@"Could not describe Live Photo metadata");
        // output：输出。
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
        output.alwaysCopiesSampleData = NO;
        // input：输入。
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeMetadata outputSettings:nil sourceFormatHint:filteredFormat];
        CFRelease(filteredFormat);
        if (![self.reader canAddOutput:output] || ![self.writer canAddInput:input]) return sc_ExportError(@"Could not preserve Live Photo metadata");
        [self.reader addOutput:output];
        [self.writer addInput:input];
        [self.liveMetadataOutputs addObject:output];
        [self.liveMetadataInputs addObject:input];
        [self.liveMetadataReaders addObject:[AVAssetReaderOutputMetadataAdaptor assetReaderOutputMetadataAdaptorWithAssetReaderTrackOutput:output]];
        [self.liveMetadataWriters addObject:[AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:input]];
    }
    if (![self.writer startWriting]) return self.writer.error ?: sc_ExportError(@"Could not start writer");
    [self.writer startSessionAtSourceTime:self.exportRange.start];
    if (![self.reader startReading]) return self.reader.error ?: sc_ExportError(@"Could not start reader");
    return nil;
}

- (void)sc_encodeReadySamplesFromOutput:(AVAssetReaderOutput *)output toInput:(AVAssetWriterInput *)input {
    // metadataIndex：元数据轨道在并行读写器中的索引。
    NSUInteger metadataIndex = [self.liveMetadataInputs indexOfObjectIdenticalTo:input];
    if (metadataIndex != NSNotFound) { [self sc_encodeLiveMetadataAtIndex:metadataIndex]; return; }
    // samples：采样集合。
    NSUInteger samples = 0;
    while (self.runningSession && !self.finishing && input.isReadyForMoreMediaData) {
        @autoreleasepool {
            // sample：采样。
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) {
                if (self.reader.status == AVAssetReaderStatusFailed || self.writer.status == AVAssetWriterStatusFailed) {
                    [self sc_failAttempt:self.writer.error ?: self.reader.error];
                    return;
                }
                [input markAsFinished];
                if (output == self.videoOutput) self.videoCompleted = YES;
                else if (output == self.audioOutput) self.audioCompleted = YES;
                else [self.completedMetadataInputs addObject:input];
                if (self.videoCompleted && self.audioCompleted && self.completedMetadataInputs.count == self.liveMetadataInputs.count) [self sc_finish];
                return;
            }
            // presentationTime：显示时间。
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
            // relativeTime：裁剪后的相对呈现时间。
            CMTime relativeTime = CMTimeSubtract(presentationTime, self.exportRange.start);
            // appended：写入器是否接受当前采样。
            BOOL appended = NO;
            if (output == self.videoOutput && self.videoPixelBufferAdaptor) {
                // rendered：渲染后的缓冲。
                CVPixelBufferRef rendered = NULL;
                // result：本次系统操作或编码结果。
                CVReturn result = CVPixelBufferPoolCreatePixelBuffer(NULL, self.videoPixelBufferAdaptor.pixelBufferPool, &rendered);
                if (result == kCVReturnSuccess && rendered) {
                    [self.delegate sc_exportSession:self renderFrame:CMSampleBufferGetImageBuffer(sample)
                            withPresentationTime:relativeTime toBuffer:rendered];
                    // The writer session starts at exportRange.start, so append the original source PTS.
                    [self sc_captureFidelityReference:rendered time:relativeTime];
                    appended = [self.videoPixelBufferAdaptor appendPixelBuffer:rendered withPresentationTime:presentationTime];
                    CVPixelBufferRelease(rendered);
                }
            } else {
                if(output==self.videoOutput)[self sc_captureFidelityReference:CMSampleBufferGetImageBuffer(sample) time:relativeTime];
                appended = [input appendSampleBuffer:sample];
            }
            CFRelease(sample);
            if (!appended) {
                [self sc_failAttempt:self.writer.error ?: self.reader.error ?: sc_ExportError(@"Could not append media sample")];
                return;
            }
            if (output == self.videoOutput) {
                // fraction：本轮已发布的单调进度。
                double fraction = fmin(1, fmax(0, CMTimeGetSeconds(relativeTime) / self.exportDuration));
                self.progress = fmaxf(self.progress, self.usesConvertedBaseline ? .3+.65*fraction : .95*fraction);
            }
            if (++samples >= sc_SampleBatchSize) {
                // generation：异步操作代数，用于隔离取消或复用后的旧回调。
                NSUInteger generation = self.generation;
                dispatch_async(self.inputQueue, ^{
                    if (self.generation == generation && self.runningSession && !self.finishing &&
                        !((output == self.videoOutput && self.videoCompleted) || (output == self.audioOutput && self.audioCompleted) ||
                          [self.completedMetadataInputs containsObject:input])) {
                        [self sc_encodeReadySamplesFromOutput:output toInput:input];
                    }
                });
                return;
            }
        }
    }
    if (self.writer.status == AVAssetWriterStatusFailed) [self sc_failAttempt:self.writer.error];
}

- (void)sc_encodeLiveMetadataAtIndex:(NSUInteger)index {
    // input：输入。
    AVAssetWriterInput *input = self.liveMetadataInputs[index];
    // reader：读取器。
    AVAssetReaderOutputMetadataAdaptor *reader = self.liveMetadataReaders[index];
    // writer：写入器。
    AVAssetWriterInputMetadataAdaptor *writer = self.liveMetadataWriters[index];
    // allowedTypes：允许保留的Live元数据类型集合。
    NSDictionary *allowedTypes = sc_LiveMetadataTypes();
    // count：数量。
    NSUInteger count = 0;
    while (self.runningSession && !self.finishing && input.readyForMoreMediaData) {
        @autoreleasepool {
            // group：当前定时元数据分组。
            AVTimedMetadataGroup *group = nil;
            @try { group = [reader nextTimedMetadataGroup]; }
            // exception：格式解析或媒体处理异常。
            @catch (NSException *exception) { [self sc_failAttempt:sc_ExportError(@"Could not decode Live Photo metadata")]; return; }
            if (!group) {
                if (self.reader.status == AVAssetReaderStatusFailed || self.writer.status == AVAssetWriterStatusFailed) {
                    [self sc_failAttempt:self.writer.error ?: self.reader.error]; return;
                }
                [input markAsFinished]; [self.completedMetadataInputs addObject:input];
                if (self.videoCompleted && self.audioCompleted && self.completedMetadataInputs.count == self.liveMetadataInputs.count) [self sc_finish];
                return;
            }
            // items：项目集合。
            NSMutableArray *items = [NSMutableArray array];
            // item：项目。
            for (AVMetadataItem *item in group.items) if (item.identifier.length && allowedTypes[item.identifier]) [items addObject:item];
            if (items.count) {
                // appended：写入器是否接受当前采样。
                BOOL appended = NO;
                @try { appended = [writer appendTimedMetadataGroup:[[AVTimedMetadataGroup alloc] initWithItems:items timeRange:group.timeRange]]; }
                // exception：格式解析或媒体处理异常。
                @catch (NSException *exception) { [self sc_failAttempt:sc_ExportError(@"Invalid Live Photo metadata")]; return; }
                if (!appended) { [self sc_failAttempt:self.writer.error ?: sc_ExportError(@"Could not append Live Photo metadata")]; return; }
            }
            if (++count >= sc_SampleBatchSize) {
                // generation：异步操作代数，用于隔离取消或复用后的旧回调。
                NSUInteger generation = self.generation;
                dispatch_async(self.inputQueue, ^{
                    if (self.generation == generation && self.runningSession && !self.finishing &&
                        ![self.completedMetadataInputs containsObject:input]) [self sc_encodeLiveMetadataAtIndex:index];
                });
                return;
            }
        }
    }
    if (self.writer.status == AVAssetWriterStatusFailed) [self sc_failAttempt:self.writer.error];
}

- (AVMutableVideoComposition *)sc_buildVideoCompositionWithSettings:(NSDictionary *)settings {
    // track：轨道。
    AVAssetTrack *track = [self.sc_processingAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // composition：方向缩放及本轮动态范围的视频合成配置。
    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    // transform：变换。
    CGAffineTransform transform = track.preferredTransform;
    // bounds：边界。
    CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, sc_PresentationSize(track)}, transform);
    // target：目标。
    CGSize target = CGSizeMake([settings[AVVideoWidthKey] doubleValue], [settings[AVVideoHeightKey] doubleValue]);
    if (CGRectIsEmpty(bounds) || !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
        target.width < 2 || target.height < 2) {
        [NSException raise:NSInvalidArgumentException format:@"Invalid video dimensions"];
    }
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(-bounds.origin.x, -bounds.origin.y));
    // scale：比例。
    CGFloat scale = MIN(target.width / fabs(bounds.size.width), target.height / fabs(bounds.size.height));
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale, scale));
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(
        (target.width - fabs(bounds.size.width) * scale) / 2, (target.height - fabs(bounds.size.height) * scale) / 2));
    composition.renderSize = target;
    composition.colorPrimaries = self.sc_exportColorProperties[AVVideoColorPrimariesKey];
    composition.colorTransferFunction = self.sc_exportColorProperties[AVVideoTransferFunctionKey];
    composition.colorYCbCrMatrix = self.sc_exportColorProperties[AVVideoYCbCrMatrixKey];
    // frameRate：帧速率。
    double frameRate = track.nominalFrameRate;
    // requestedRate：requested速率。
    NSNumber *requestedRate = settings[AVVideoCompressionPropertiesKey][AVVideoExpectedSourceFrameRateKey];
    if (requestedRate) frameRate = requestedRate.doubleValue;
    if (!isfinite(frameRate) || frameRate < 1) frameRate = 30;
    frameRate = MIN(frameRate, self.exportMaximumFrameRate);
    composition.frameDuration = CMTimeMakeWithSeconds(1.0 / frameRate, 60000);
    // instruction：覆盖导出范围的视频合成指令。
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = self.exportRange;
    // layer：绑定视频轨道的图层变换指令。
    AVMutableVideoCompositionLayerInstruction *layer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [layer setTransform:transform atTime:self.exportRange.start];
    instruction.layerInstructions = @[ layer ];
    composition.instructions = @[ instruction ];
    return composition;
}

- (void)sc_finish {
    if (self.finishing || !self.runningSession) return;
    self.finishing = YES;
    // generation：异步操作代数，用于隔离取消或复用后的旧回调。
    NSUInteger generation = self.generation;
    // writer：写入器。
    AVAssetWriter *writer = self.writer;
    [writer finishWritingWithCompletionHandler:^{
        dispatch_async(self.inputQueue, ^{
            if (self.generation != generation || !self.runningSession || self.writer != writer) return;
            if (writer.status == AVAssetWriterStatusCompleted) {
                [self sc_finishWithSizeGuard];
            } else {
                [self sc_failAttempt:writer.error ?: self.reader.error ?: sc_ExportError(@"Could not sc_finish export")];
            }
        });
    }];
}

@end
