// Derived from HXPhotoPicker; Copyright (c) 2017 LoveZYForever. See THIRD_PARTY_NOTICES.md.
#import "SCLivePhotoResourceWriter.h"
#import "SCImageHDR.h"
#import "SCInternal.h"
#import "SCMediaCompressorError.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
/// sc_FigAppleMakerNote_AssetIdentifier：FigAppleMakerNote素材标识。
static NSString *const sc_FigAppleMakerNote_AssetIdentifier = @"17";
/// sc_KeySpaceQuickTimeMetadata：键空间Quick时间元数据。
static NSString *const sc_KeySpaceQuickTimeMetadata = @"mdta";
/// sc_KeyStillImageTime：键静态帧图片时间。
static NSString *const sc_KeyStillImageTime = @"com.apple.quicktime.still-image-time";
/// sc_KeyContentIdentifier：键内容标识。
static NSString *const sc_KeyContentIdentifier = @"com.apple.quicktime.content.identifier";
/// 保留系统原始错误；ImageIO 未提供错误对象时给出可读的本库失败。
/// @param message 无系统错误时的失败说明。
/// @param underlying 系统实际返回的错误，不伪造底层原因。
static NSError *sc_PairingError(NSString *message,NSError *underlying) {
    return underlying ?: [NSError errorWithDomain:SCMediaCompressorErrorDomain code:SCMediaCompressorErrorCoordinationFailed userInfo:@{NSLocalizedDescriptionKey:message}];
}
/// 在清理 Reader/Writer 前捕获失败原因，避免被取消清理覆盖。
/// @param writer 当前写入器。
/// @param reader 当前读取器。
static NSError *sc_MoviePairingError(AVAssetWriter *writer,AVAssetReader *reader) {
    if(writer.error || reader.error)return writer.error ?: reader.error;
    if(writer.status==AVAssetWriterStatusCancelled || reader.status==AVAssetReaderStatusCancelled)return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    return sc_PairingError(@"Could not rewrap Live Photo movie",nil);
}
@implementation SCLivePhotoResourceWriter
+ (void)sc_writePairedMovieAtURL:(NSURL *)source toURL:(NSURL *)output identifier:(NSString *)identifier completion:(void (^)(BOOL,NSError *))completion {
    [self sc_writePairedMovieAtURL:source toURL:output identifier:identifier header:nil completion:completion];
}
+ (AVAssetWriterInputMetadataAdaptor *)sc_metadataSetAdapter {
    // identifier：标识。
    NSString *identifier = [sc_KeySpaceQuickTimeMetadata stringByAppendingFormat:@"/%@", sc_KeyStillImageTime];
    // spec：元数据格式描述的配置字典。
    const NSDictionary *spec = @{
        (__bridge_transfer NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier : identifier,
        (__bridge_transfer NSString *)
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType : @"com.apple.metadata.datatype.int8"
    };
    // desc：系统创建的元数据格式描述。
    CMFormatDescriptionRef desc;
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault, kCMMetadataFormatType_Boxed,
                                                                (__bridge CFArrayRef) @[ spec ], &desc);
    // input：输入。
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeMetadata
                                                                   outputSettings:nil
                                                                 sourceFormatHint:desc];
    CFRelease(desc);
    return [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:input];
}
+ (NSString *)sc_livePhotoIdentifierForImageURL:(NSURL *)url {
    // source：原始素材或像素缓冲。
    CGImageSourceRef source = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL) : NULL;
    // properties：属性字典。
    NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
    if (source) CFRelease(source);
    // identifier：标识。
    id identifier = properties[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary][sc_FigAppleMakerNote_AssetIdentifier];
    return [identifier isKindOfClass:NSString.class] && [identifier length] ? identifier : nil;
}



+ (void)sc_writePairedJPEGAtURL:(NSURL *)sourceURL toURL:(NSURL *)outputURL identifier:(NSString *)assetIdentifier completion:(void (^)(BOOL success,NSError *error))completion {
    // success、error：直接交付配对结果与原始失败原因。
    [self sc_writePairedJPEGAtURL:sourceURL toURL:outputURL identifier:assetIdentifier metrics:nil completion:completion];
}

+ (void)sc_writePairedJPEGAtURL:(NSURL *)sourceURL toURL:(NSURL *)outputURL identifier:(NSString *)assetIdentifier metrics:(SCImageMetrics *)metrics completion:(void (^)(BOOL,NSError *))completion {
    // error：文件读取或复制的真实系统错误。
    NSError *error=nil;
    // started：仅计入 JPEG 配对/复制，不包含前后的 MOV 或视频等待。
    NSTimeInterval started=metrics?sc_ImageNow():0;
    // finished：所有成功/失败分支共用实际耗时的收口。
    void (^finished)(BOOL,NSError *)=^(BOOL success,NSError *failure){if(metrics)[metrics sc_addDuration:sc_ImageNow()-started stage:SCImagePerformanceStagePair];if(completion)completion(success,success?nil:sc_PairingError(@"Could not write paired Live Photo JPEG",failure));};
    if (!sourceURL.isFileURL || !outputURL.isFileURL ||
        [sourceURL.URLByResolvingSymlinksInPath.path isEqualToString:outputURL.URLByResolvingSymlinksInPath.path] ||
        [NSFileManager.defaultManager fileExistsAtPath:outputURL.path]) { finished(NO,nil); return; }
    // source：原始素材或像素缓冲。
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, NULL);
    if (source && CGImageSourceGetType(source) && CFEqual(CGImageSourceGetType(source), (__bridge CFStringRef)UTTypeJPEG.identifier) &&
        [[self sc_livePhotoIdentifierForImageURL:sourceURL] isEqualToString:assetIdentifier]) {
        // The business JPEG already carries the desired ID. Copy its exact bytes, without re-encoding.
        CFRelease(source);
        // data：编码数据。
        NSData *data = [NSData dataWithContentsOfURL:sourceURL options:NSDataReadingMappedIfSafe error:&error];
        // success：本次写入是否成功。
        BOOL success = data.length && [data writeToURL:outputURL options:NSDataWritingAtomic error:&error];
        finished(success,error);
        return;
    }
    // destination：本次输出的 ImageIO 目标。
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)outputURL, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
    // success：本次写入是否成功。
    BOOL success = NO;
    if (source && CGImageSourceGetCount(source) > 0 && destination && assetIdentifier.length) {
        // properties：属性字典。
        NSMutableDictionary *properties = [CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) mutableCopy] ?: [NSMutableDictionary dictionary];
        // maker：Apple MakerNote字典的可写副本。
        NSMutableDictionary *maker = [properties[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
        maker[sc_FigAppleMakerNote_AssetIdentifier] = assetIdentifier;
        properties[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary] = maker;
        properties[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] = @1;
        properties[(__bridge NSString *)kCGImageDestinationPreserveGainMap]=@YES;
        if(@available(iOS 18.0,*)) {
            if(sc_sourceContainsHDR(source))properties[(__bridge NSString *)kCGImageDestinationEncodeRequest]=(__bridge NSString *)kCGImageDestinationEncodeToISOGainmap;
        }
        [metrics sc_beginEncodingType:UTTypeJPEG.identifier pairing:YES];
        CGImageDestinationAddImageFromSource(destination, source, 0, (__bridge CFDictionaryRef)properties);
        success = CGImageDestinationFinalize(destination);
    }
    if (source) CFRelease(source);
    if (destination) CFRelease(destination);
    if (!success) [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
    finished(success,error);
}



+ (void)sc_writePairedMovieAtURL:(NSURL *)sourceURL toURL:(NSURL *)outputURL identifier:(NSString *)assetIdentifier header:(void (^)(AVAssetWriter *,AVAssetReader *))header completion:(void (^)(BOOL,NSError *))completion {
    [self sc_writePairedMovieAtURL:sourceURL toURL:outputURL identifier:assetIdentifier header:header cancellation:nil completion:completion];
}

+ (void)sc_writePairedMovieAtURL:(NSURL *)sourceURL toURL:(NSURL *)outputURL identifier:(NSString *)assetIdentifier cancellation:(void (^)(dispatch_block_t))cancellation completion:(void (^)(BOOL,NSError *))completion {
    [self sc_writePairedMovieAtURL:sourceURL toURL:outputURL identifier:assetIdentifier header:nil cancellation:cancellation completion:completion];
}

/// 所有系统读写与终态处理均由本次封装的串行队列拥有。
+ (void)sc_writePairedMovieAtURL:(NSURL *)sourceURL toURL:(NSURL *)outputURL identifier:(NSString *)assetIdentifier header:(void (^)(AVAssetWriter *,AVAssetReader *))header cancellation:(void (^)(dispatch_block_t))cancellation completion:(void (^)(BOOL,NSError *))completion {
    // queue：隔离当前封装的 Reader、Writer 和清理操作。
    dispatch_queue_t queue = dispatch_queue_create("io.github.mortal-shaco.scmedia.live.rewrap", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        if (!sourceURL.isFileURL || !outputURL.isFileURL ||
            [sourceURL.URLByResolvingSymlinksInPath.path isEqualToString:outputURL.URLByResolvingSymlinksInPath.path] ||
            [NSFileManager.defaultManager fileExistsAtPath:outputURL.path]) { if (completion) completion(NO,sc_PairingError(@"Invalid or occupied Live Photo movie destination",nil)); return; }
        // Business compression already produced the desired video. Rewrap without a second video/audio encode.
        // asset：素材。
        AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];
        // error：错误。
        NSError *error = nil;
        // reader：读取器。
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
        // writer：写入器。
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
        // outputs：按轨道排序的读取器输出集合。
        NSMutableArray<AVAssetReaderTrackOutput *> *outputs = [NSMutableArray array];
        // inputs：与读取器对应的写入器输入集合。
        NSMutableArray<AVAssetWriterInput *> *inputs = [NSMutableArray array];
        // hasVideo：has视频。
        // hasStillTime：素材是否带有 Live 关键静态帧时间。
        BOOL hasVideo = NO, hasStillTime = NO;
        if (reader && writer && assetIdentifier.length) {
            // track：轨道。
            for (AVAssetTrack *track in asset.tracks) {
                if (![@[AVMediaTypeVideo, AVMediaTypeAudio, AVMediaTypeMetadata] containsObject:track.mediaType]) continue;
                // format：格式。
                CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
                if (!format) { error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorFileFormatNotRecognized userInfo:nil]; break; }
                // output：输出。
                AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
                output.alwaysCopiesSampleData = NO;
                // input：输入。
                AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:nil sourceFormatHint:format];
                input.expectsMediaDataInRealTime = NO;
                input.transform = track.preferredTransform;
                input.metadata = track.metadata;
                if (![reader canAddOutput:output] || ![writer canAddInput:input]) {
                    error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorExportFailed userInfo:nil]; break;
                }
                [reader addOutput:output]; [writer addInput:input];
                [outputs addObject:output]; [inputs addObject:input];
                if ([track.mediaType isEqualToString:AVMediaTypeVideo]) hasVideo = YES;
                if ([track.mediaType isEqualToString:AVMediaTypeMetadata]) {
                    // identifiers：元数据类型标识集合。
                    NSArray *identifiers = (__bridge NSArray *)CMMetadataFormatDescriptionGetIdentifiers(format);
                    if ([identifiers containsObject:@"mdta/com.apple.quicktime.still-image-time"]) hasStillTime = YES;
                }
            }
        }
        // fallback：缺少关键时间时的元数据写入器。
        AVAssetWriterInputMetadataAdaptor *fallback = nil;
        if (!hasStillTime && writer && !error) {
            // Legacy files may have lost their capture timestamp. Use a middle frame only for that fallback.
            fallback = [self sc_metadataSetAdapter];
            if ([writer canAddInput:fallback.assetWriterInput]) [writer addInput:fallback.assetWriterInput];
            else error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorExportFailed userInfo:nil];
        }
        // metadata：元数据。
        NSMutableArray *metadata = [NSMutableArray array];
        // item：项目。
        for (AVMetadataItem *item in asset.metadata) {
            if (![item.identifier isEqualToString:AVMetadataIdentifierQuickTimeMetadataContentIdentifier]) [metadata addObject:item];
        }
        [metadata addObject:[self sc_metaDataSet:assetIdentifier]];
        writer.metadata = metadata;
        if (!reader || !writer || error || !hasVideo || ![writer startWriting]) {
            // failure：取消清理之前的真实失败原因。
            NSError *failure=error ?: sc_MoviePairingError(writer,reader);
            [reader cancelReading]; [writer cancelWriting];
            [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
            if (completion) completion(NO,failure);
            return;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];
        if (![reader startReading]) {
            // failure：读取器启动失败的原始原因。
            NSError *failure=sc_MoviePairingError(writer,reader);
            [writer cancelWriting]; [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
            if (completion) completion(NO,failure);
            return;
        }
        if (header) header(writer, reader);
        if (writer.status != AVAssetWriterStatusWriting || reader.status != AVAssetReaderStatusReading) {
            // failure：取消清理之前的真实失败原因。
            NSError *failure=sc_MoviePairingError(writer,reader);
            [reader cancelReading]; [writer cancelWriting];
            [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
            if (completion) completion(NO,failure);
            return;
        }
        if (fallback) {
            // item：项目。
            AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
            item.key = sc_KeyStillImageTime; item.keySpace = sc_KeySpaceQuickTimeMetadata;
            item.value = @0; item.dataType = @"com.apple.metadata.datatype.int8";
            // time：时间。
            CMTime time = CMTimeMultiplyByFloat64(asset.duration, 0.5);
            // range：范围。
            CMTimeRange range = CMTimeRangeMake(time, CMTimeMake(1, 30));
            // appended：写入器是否接受当前采样。
            BOOL appended = [fallback appendTimedMetadataGroup:[[AVTimedMetadataGroup alloc] initWithItems:@[item] timeRange:range]];
            [fallback.assetWriterInput markAsFinished];
            if (!appended) {
                // failure：取消清理之前的真实失败原因。
                NSError *failure=sc_MoviePairingError(writer,reader);
                [reader cancelReading]; [writer cancelWriting]; [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
                if (completion) completion(NO,failure);
                return;
            }
        }
        // completed、finishing：队列内唯一终态及系统异步收尾状态。
        __block BOOL completed = NO, finishing = NO;
        // cancellationLock、cancelled：跨线程仅传递取消请求，不操作系统读写器。
        NSLock *cancellationLock = [NSLock new];
        // cancelled：受锁保护的取消请求。
        __block BOOL cancelled = NO;
        // isCancelled：在每个采样边界观察取消，避免轨道持续就绪时饿死取消队列。
        BOOL (^isCancelled)(void) = ^BOOL {
            [cancellationLock lock];
            // value：锁内读取的状态快照。
            BOOL value = cancelled;
            [cancellationLock unlock];
            return value;
        };
        // finish：停止后才删除文件并交付一次，防止高层提前清理输入目录。
        void (^finish)(BOOL,NSError *) = ^(BOOL success,NSError *failure) {
            if (completed) return;
            completed = YES;
            if (!success) {
                if (reader.status == AVAssetReaderStatusReading) [reader cancelReading];
                if (writer.status == AVAssetWriterStatusWriting) [writer cancelWriting];
                [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
            }
            if (completion) completion(success,failure);
        };
        // cancel：可从任意线程调用；finishWriting 已启动时等待其回调后清理。
        dispatch_block_t cancel = ^{
            [cancellationLock lock]; cancelled = YES; [cancellationLock unlock];
            dispatch_async(queue, ^{
                if (!finishing) finish(NO,[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
            });
        };
        if (cancellation) cancellation(cancel);
        // remaining：全部轨道标记完成后才能调用系统异步收尾。
        __block NSUInteger remaining = inputs.count;
        // input、index、stop：当前轨道及对应读取输出。
        [inputs enumerateObjectsUsingBlock:^(AVAssetWriterInput *input, NSUInteger index, BOOL *stop) {
            // output：只在当前封装队列读取的轨道。
            AVAssetReaderTrackOutput *output = outputs[index];
            // inputFinished：避免重复标记轨道终态。
            __block BOOL inputFinished = NO;
            [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
                if (completed || inputFinished || finishing) return;
                while (input.readyForMoreMediaData) {
                    if (isCancelled()) {
                        finish(NO,[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
                        return;
                    }
                    if (writer.status != AVAssetWriterStatusWriting || reader.status == AVAssetReaderStatusFailed || reader.status == AVAssetReaderStatusCancelled) {
                        finish(NO,sc_MoviePairingError(writer,reader));
                        return;
                    }
                    // sample：生命周期完全落在封装队列上的压缩采样。
                    CMSampleBufferRef sample = reader.status == AVAssetReaderStatusReading ? [output copyNextSampleBuffer] : NULL;
                    if (sample) {
                        // appended：保留实际写入错误，释放当前采样后再收尾。
                        BOOL appended = [input appendSampleBuffer:sample];
                        CFRelease(sample);
                        if (appended) continue;
                        finish(NO,sc_MoviePairingError(writer,reader));
                        return;
                    }
                    if (reader.status == AVAssetReaderStatusFailed || reader.status == AVAssetReaderStatusCancelled || writer.status != AVAssetWriterStatusWriting) {
                        finish(NO,sc_MoviePairingError(writer,reader));
                        return;
                    }
                    inputFinished = YES;
                    [input markAsFinished];
                    if (--remaining == 0) {
                        finishing = YES;
                        [writer finishWritingWithCompletionHandler:^{
                            dispatch_async(queue, ^{
                                // failure：优先保留系统错误；取消请求只在系统收尾结束后交付。
                                NSError *failure = writer.status == AVAssetWriterStatusCompleted ? nil : sc_MoviePairingError(writer,reader);
                                if (!failure && isCancelled()) failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
                                finish(failure == nil,failure);
                            });
                        }];
                    }
                    return;
                }
                if (!completed && (writer.status != AVAssetWriterStatusWriting || reader.status == AVAssetReaderStatusFailed || reader.status == AVAssetReaderStatusCancelled)) finish(NO,sc_MoviePairingError(writer,reader));
            }];
        }];
    });
}

+ (AVMetadataItem *)sc_metaDataSet:(NSString *)assetIdentifier {
    // item：项目。
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.key = sc_KeyContentIdentifier;
    item.keySpace = sc_KeySpaceQuickTimeMetadata;
    item.value = assetIdentifier;
    item.dataType = @"com.apple.metadata.datatype.UTF-8";
    return item;
}


@end
