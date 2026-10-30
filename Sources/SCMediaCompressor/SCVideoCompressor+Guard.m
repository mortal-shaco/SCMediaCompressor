#import "SCVideoCompressorInternal.h"

@implementation SCVideoCompressor (SCGuard)
- (void)sc_captureFidelityReference:(CVPixelBufferRef)buffer time:(CMTime)time {
    // count：短片三帧，长片五帧，覆盖头部、中段和接近结尾。
    NSUInteger count=self.exportDuration<8?3:5;
    if(!buffer||self.sc_fidelityReferences.count>=count)return;
    // target：本次固定的等距采样时刻。
    double target=self.exportDuration*.95*self.sc_fidelityReferences.count/(count-1);
    if(CMTimeGetSeconds(time)+.0001<target)return;
    // started：仅在实际取得样本时计时。
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    // size：仅评估使用的小像素参考。
    CGSize size=sc_FidelitySampleSize(CGSizeMake(CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer)));
    // pixels：实际写入参考，渲染代理不会被第二次调用。
    NSData *pixels=sc_FidelityBufferPixels(buffer,size.width,size.height,self.sc_exportsHDR);
    if(pixels)[self.sc_fidelityReferences addObject:@{@"time":[NSValue valueWithCMTime:time],@"pixels":pixels,@"width":@(size.width),@"height":@(size.height)}];
    self.qualityEvaluationDuration+=NSProcessInfo.processInfo.systemUptime-started;
}

/// 只解码候选的有界时间片，保留最差抽样分数，不用平均值掩盖明显坏帧。
- (void)sc_assessFidelity {
    // started：输出抽样解码与评分的实际耗时。
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    @try {
    self.fidelityScore=nil;self.qualityStatus=SCVideoQualityStatusNotEvaluated;self.qualitySampleCount=0;
    if(!self.sc_fidelityReferences.count)return;
    // asset：真实完成的编码结果。
    AVAsset *asset=[AVAsset assetWithURL:self.activeOutputURL];
    // track：实际候选视频轨道。
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if(!track)return;
    // references：本轮不可变的参考数组，原始渲染不会被再次执行。
    NSArray<NSDictionary *> *references=self.sc_fidelityReferences.copy;
    // scores：每个时间点独立保存结果，未知保持 NSNull。
    NSMutableArray *scores=[NSMutableArray array];for(NSUInteger i=0;i<references.count;i++)[scores addObject:NSNull.null];
    // limit：最多两个候选解码器并行，约束峰值内存并减少串行初始化等待。
    dispatch_semaphore_t limit=dispatch_semaphore_create(2);
    // group：仅等待固定数量的代表性时间片，不扫描全片。
    dispatch_group_t group=dispatch_group_create();
    // hdr：捕获固定配置，不在并行解码中读取可变调用方设置。
    BOOL hdr=self.sc_exportsHDR;
    // maximumRate：时间配对的帧间隔容差。
    double maximumRate=self.exportMaximumFrameRate;
    // quality：共享的请求目标。
    double quality=self.exportVideoQuality;
    // index：固定样本下标。
    for(NSUInteger index=0;index<references.count;index++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        dispatch_semaphore_wait(limit,DISPATCH_TIME_FOREVER);
        @try {
            // reference：已经捕获的同一实际写入参考。
            NSDictionary *reference=references[index];
            // time：裁剪后对应的输出时间。
            CMTime time=[reference[@"time"]CMTimeValue];
            // reader：只读取有界短时间片，HDR 保留 10-bit HLG/PQ 信号。
            AVAssetReader *reader=[AVAssetReader assetReaderWithAsset:asset error:nil];
            // target、windowStart：向前留出两帧，避免首帧被系统裁剪成请求起点而伪装成精确匹配。
            double target=CMTimeGetSeconds(time),windowStart=MAX(0,target-MAX(.05,2/maximumRate));
            reader.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(windowStart,60000),CMTimeMakeWithSeconds(MAX(.2,4/maximumRate),60000));
            // output：候选与输入使用同一视频范围的解码像素。
            AVAssetReaderTrackOutput *output=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:@(hdr?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
            if(!reader||![reader canAddOutput:output])return;
            [reader addOutput:output];if(![reader startReading])return;
            // sample：跳过可能改写时间戳的区间首帧，保留真实 PTS 最近的帧。
            CMSampleBufferRef sample=NULL;
            // nearest：当前最佳帧与目标时间的距离。
            double nearest=INFINITY;
            // position：每个时间片最多读取八帧，避免无界扫描。
            for(NSUInteger position=0;position<8;position++){
                // current：只保留当前最佳帧，不为时序匹配扫描像素或整段视频。
                CMSampleBufferRef current=[output copyNextSampleBuffer];
                if(!current)break;
                if(windowStart>0 && position==0){CFRelease(current);continue;}
                // actual、distance：容器时间刻度量化后，对齐最近的真实输出时间。
                double actual=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(current)),distance=fabs(actual-target);
                if(distance<nearest){if(sample)CFRelease(sample);sample=current;nearest=distance;}
                else CFRelease(current);
                if(actual>=target)break;
            }
            // candidate：与参考完全一致的信号域与空间采样。
            NSData *candidate=sample?sc_FidelityBufferPixels(CMSampleBufferGetImageBuffer(sample),[reference[@"width"]unsignedIntegerValue],[reference[@"height"]unsignedIntegerValue],hdr):nil;
            // difference：时间错误时不产生虚假评分。
            double difference=sample?fabs(CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample),time))):INFINITY;
            if(sample)CFRelease(sample);[reader cancelReading];
            if(!candidate||difference>MAX(.002,1/maximumRate))return;
            // score：结构、局部细节和色差的共享评分。
            double score=-1;sc_PassesFidelity(reference[@"pixels"],candidate,[reference[@"width"]unsignedIntegerValue],[reference[@"height"]unsignedIntegerValue],quality,&score);
            if(score>=0)@synchronized(scores){scores[index]=@(score);}
        }@finally{dispatch_semaphore_signal(limit);}
    }});
    dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
    // worst：不能用平均值掩盖坏帧。
    double worst=1;
    // score：只在全部有效时发布达标结论。
    for(id score in scores){if(![score isKindOfClass:NSNumber.class])return;worst=MIN(worst,[score doubleValue]);}
    self.qualitySampleCount=scores.count;
    self.fidelityScore=@(worst);self.candidateFidelityScore=self.fidelityScore;
    self.qualityStatus=worst+1e-9>=sc_EffectiveFidelityTarget(self.exportVideoQuality)?SCVideoQualityStatusMet:SCVideoQualityStatusNotMet;
    } @finally {self.qualityEvaluationDuration+=NSProcessInfo.processInfo.systemUptime-started;}
}

/// 返回原内容基线时清空落选采样口径，不继承候选的未达标状态。
- (void)sc_useBaselineQuality {
    self.fidelityScore=@1;self.qualityStatus=SCVideoQualityStatusMet;self.qualitySampleCount=0;
}

/// 最后一次选择后核对实际文件描述，不启动额外编码或全片扫描。
- (NSError *)sc_validateFinalVideo {
    // asset：最终选中资源，而不是已被回退替换的候选。
    AVAsset *asset=[AVAsset assetWithURL:self.activeOutputURL];
    // track：交付视频必须真实存在且满足写入几何。
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // settings：本次实际写入器设置，兼容显式输出配置。
    NSDictionary *settings=self.videoInput.outputSettings;
    // size：真实解码显示尺寸。
    CGSize size=track?sc_PresentationSize(track):CGSizeZero;
    if(!track || size.width!=[settings[AVVideoWidthKey]doubleValue] || size.height!=[settings[AVVideoHeightKey]doubleValue] ||
       !CGAffineTransformIsIdentity(track.preferredTransform) || !isfinite(track.nominalFrameRate) || track.nominalFrameRate>self.exportMaximumFrameRate+2/MAX(.01,self.exportDuration) ||
       fabs(CMTimeGetSeconds(track.timeRange.duration)-self.exportDuration)>MAX(.15,2/self.exportMaximumFrameRate))return sc_ExportError([NSString stringWithFormat:@"Final video violates geometry or timing constraints: actual=%gx%g expected=%@x%@ fps=%g duration=%g requested=%g",size.width,size.height,settings[AVVideoWidthKey],settings[AVVideoHeightKey],track.nominalFrameRate,CMTimeGetSeconds(track.timeRange.duration),self.exportDuration]);
    if(self.sc_exportsHDR ? !sc_HDRVideoMatches(asset,self.sc_exportColorProperties) : [asset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count>0)return sc_VideoConfigurationError(@"Final video violates dynamic-range constraints");
    if(self.shouldOptimizeForNetworkUse&&!sc_HasFastStart(self.activeOutputURL))return sc_ExportError(@"Final video is not optimized for network playback");
    return nil;
}

/// 按实际完成文件择小；不符合输出约束的原文件不能覆盖合规编码结果。
- (void)sc_finishWithSizeGuard {
    self.sc_compressionFinishedAt=CFAbsoluteTimeGetCurrent();
    if(self.sc_exportsHDR && !sc_HDRVideoMatches([AVAsset assetWithURL:self.activeOutputURL],self.sc_exportColorProperties)){[self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_VideoConfigurationError(@"Encoded output did not retain 10-bit HDR pixels and color properties")];return;}
    // outputBytes：写入完成的真实字节，不以估算码率替代。
    unsigned long long outputBytes=[NSFileManager.defaultManager attributesOfItemAtPath:self.activeOutputURL.path error:nil].fileSize;
    if(!outputBytes){[self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Encoded output is empty")];return;}
    // candidate：编码成功也必须有真实视频轨道；文件损坏不能伪装为无收益回退。
    AVAsset *candidate=[AVAsset assetWithURL:self.activeOutputURL];
    if(![candidate tracksWithMediaType:AVMediaTypeVideo].count){[self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:sc_ExportError(@"Encoded file has no readable video track")];return;}
    [self sc_assessFidelity];
    if(self.sc_requiresEncodingConversion){
        self.conversionBytes=outputBytes;self.sc_sourceBaselineURL=self.activeOutputURL;self.usesConvertedBaseline=YES;
    }
    self.comparisonBytes=self.sc_sourceBaselineURL?[NSFileManager.defaultManager attributesOfItemAtPath:self.sc_sourceBaselineURL.path error:nil].fileSize:0;
    self.sc_comparisonBaselineReusable=[self sc_canReturnCompressionBaseline];
    // error：只报告真实文件读写失败，不因缺少体积收益产生错误。
    NSError *error=nil;
    if(self.comparisonBytes && !self.sc_comparisonBaselineReusable){
        // 原基线不满足几何或编辑约束时，复用本次已经完成的合法处理结果作为基线。
        self.sc_sourceBaselineURL=self.activeOutputURL;self.comparisonBytes=outputBytes;self.usesConvertedBaseline=YES;self.sc_comparisonBaselineReusable=YES;
    }
    if(self.sc_comparisonOutputURL && self.sc_sourceBaselineURL && ![NSFileManager.defaultManager copyItemAtURL:self.sc_sourceBaselineURL toURL:self.sc_comparisonOutputURL error:&error]){[self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:error];return;}
    if(self.sc_comparisonBaselineReusable && self.comparisonBytes && (outputBytes>=self.comparisonBytes || self.qualityStatus!=SCVideoQualityStatusMet) && ![self.sc_sourceBaselineURL isEqual:self.activeOutputURL]){
        if(![NSFileManager.defaultManager removeItemAtURL:self.activeOutputURL error:&error] || ![NSFileManager.defaultManager copyItemAtURL:self.sc_sourceBaselineURL toURL:self.activeOutputURL error:&error]){[self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:error];return;}
        [self sc_useBaselineQuality];
    }
    // validation：只对最后选中的文件执行一次交付闸门。
    NSError *validation=[self sc_validateFinalVideo];
    [self sc_completeWithStatus:validation?AVAssetExportSessionStatusFailed:AVAssetExportSessionStatusCompleted error:validation];
}

- (void)sc_failAttempt:(NSError *)error {
    // underlying：系统错误中携带的底层错误。
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ((error.code == -12915 || underlying.code == -12915) && self.retryCount < sc_MaximumRetryCount) {
        self.retryCount++;
        self.finishing = YES;
        self.generation++;
        // generation：异步操作代数，用于隔离取消或复用后的旧回调。
        NSUInteger generation = self.generation;
        if (self.writer) [NSFileManager.defaultManager removeItemAtURL:self.activeOutputURL error:nil];
        [self sc_releaseAttempt];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sc_RetryDelay * NSEC_PER_SEC)), self.inputQueue, ^{
            if (self.generation == generation && self.runningSession) [self sc_startAttempt];
        });
    } else {
        [self sc_completeWithStatus:AVAssetExportSessionStatusFailed error:error ?: sc_ExportError(@"Export failed")];
    }
}

- (void)sc_releaseAttempt {
    if (self.reader.status == AVAssetReaderStatusReading) [self.reader cancelReading];
    if (self.writer.status == AVAssetWriterStatusWriting) [self.writer cancelWriting];
    self.liveMetadataOutputs = nil;
    self.liveMetadataInputs = nil;
    self.completedMetadataInputs = nil;
    self.liveMetadataReaders = nil;
    self.liveMetadataWriters = nil;
    self.videoOutput = nil;
    self.audioOutput = nil;
    self.videoInput = nil;
    self.audioInput = nil;
    self.videoPixelBufferAdaptor = nil;
    self.reader = nil;
    self.writer = nil;
}

@end
