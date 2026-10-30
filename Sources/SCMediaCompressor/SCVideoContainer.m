#import "SCVideoContainer.h"

// Live Photo playback aligns the encoded frame, including pixels outside the ordinary clean aperture.
// Expose that full frame to the system compositor on a private copy, without changing media samples,
// orientation, Live timing/alignment metadata, atom sizes or chunk offsets.
/// 在父 atom 边界内读取完整子 atom 并检查长度与溢出。
/// @param file 当前操作使用的文件句柄。
/// @param offset 偏移。
/// @param length 长度。
static NSData *sc_ReadAtomData(NSFileHandle *file, uint64_t offset, NSUInteger length) {
    [file seekToFileOffset:offset];
    // data：编码数据。
    NSData *data = [file readDataOfLength:length];
    if (data.length != length) [NSException raise:NSInvalidArgumentException format:@"Truncated movie atom"];
    return data;
}
/// 读取大端编码的 32 位整数。
/// @param file 当前操作使用的文件句柄。
/// @param offset 偏移。
static uint32_t sc_ReadBE32(NSFileHandle *file, uint64_t offset) {
    // value：值。
    uint32_t value; [sc_ReadAtomData(file, offset, 4) getBytes:&value length:4];
    return CFSwapInt32BigToHost(value);
}
/// 将 32 位整数写回大端容器字段，保持 atom 长度不变。
/// @param file 当前操作使用的文件句柄。
/// @param offset 偏移。
/// @param value 值。
static void sc_WriteBE32(NSFileHandle *file, uint64_t offset, uint32_t value) {
    value = CFSwapInt32HostToBig(value);
    [file seekToFileOffset:offset]; [file writeData:[NSData dataWithBytes:&value length:4]];
}
/// 校验并读取受父范围约束的媒体容器 atom。
/// @param file 当前操作使用的文件句柄。
/// @param position position。
/// @param end 当前 atom 或范围的结束偏移。
/// @param type 实际媒体或容器类型。
/// @param body atom 有效负载的起始偏移。
/// @param atomEnd atom结束。
BOOL sc_ReadAtom(NSFileHandle *file, uint64_t position, uint64_t end,
                         uint32_t *type, uint64_t *body, uint64_t *atomEnd) {
    if (end - position < 8) return NO; // Some visual sample entries end in four padding bytes.
    // size：尺寸。
    uint64_t size = sc_ReadBE32(file, position);
    *type = sc_ReadBE32(file, position + 4);
    // header：读写器或文件头回调。
    uint64_t header = 8;
    if (size == 1) {
        if (end - position < 16) [NSException raise:NSInvalidArgumentException format:@"Invalid extended atom"];
        // big：大端字节序整数缓冲。
        uint64_t big; [sc_ReadAtomData(file, position + 8, 8) getBytes:&big length:8];
        size = CFSwapInt64BigToHost(big); header = 16;
    } else if (size == 0) size = end - position;
    if (size < header || size > end - position) [NSException raise:NSInvalidArgumentException format:@"Invalid movie atom bounds"];
    *body = position + header; *atomEnd = position + size;
    return YES;
}
/// 检查 MP4 媒体索引是否位于数据块之前。
/// @param url URL。
BOOL sc_HasFastStart(NSURL *url) {
    // file：当前操作使用的文件句柄。
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!file) return NO;
    // result：本次系统操作或编码结果。
    BOOL result = NO;
    @try {
        // end：当前 atom 或范围的结束偏移。
        // cursor：容器内当前读取位置。
        uint64_t end = [file seekToEndOfFile], cursor = 0;
        while (cursor < end) {
            // type：实际媒体或容器类型。
            // body：atom 有效负载的起始偏移。
            // next：下一个atom的起始偏移。
            uint32_t type; uint64_t body, next;
            if (!sc_ReadAtom(file, cursor, end, &type, &body, &next) || type == 0x6d646174) break; // mdat
            if (type == 0x6d6f6f76) { result = YES; break; } // moov
            cursor = next;
        }
    // exception：格式解析或媒体处理异常。
    } @catch (NSException *exception) { result = NO; }
    [file closeFile];
    return result;
}
/// 从容器轨道头读取完整编码宽高，供私有 Live 画幅恢复使用。
/// @param file 当前操作使用的文件句柄。
/// @param start 起始。
/// @param end 当前 atom 或范围的结束偏移。
/// @param dimensions 轨道 ID 到原始完整编码尺寸的映射。
static CMVideoDimensions sc_DimensionsForMovieTrack(NSFileHandle *file, uint64_t start, uint64_t end,
                                                     NSDictionary<NSNumber *, NSValue *> *dimensions) {
    // cursor：容器内当前读取位置。
    for (uint64_t cursor = start; cursor < end;) {
        // type：实际媒体或容器类型。
        // body：atom 有效负载的起始偏移。
        // next：下一个atom的起始偏移。
        uint32_t type; uint64_t body, next;
        if (!sc_ReadAtom(file, cursor, end, &type, &body, &next)) break;
        if (type == 'tkhd') {
            // version：容器字段布局版本号。
            uint8_t version; [sc_ReadAtomData(file, body, 1) getBytes:&version length:1];
            // offset：偏移。
            uint64_t offset = version == 1 ? 20 : 12;
            if (version > 1 || next - body < offset + 4) break;
            // value：值。
            NSValue *value = dimensions[@(sc_ReadBE32(file, body + offset))];
            // size：尺寸。
            CMVideoDimensions size = {0, 0};
            if (value) [value getValue:&size size:sizeof(size)];
            return size;
        }
        cursor = next;
    }
    return (CMVideoDimensions){0, 0};
}
/// 只修正私有 Live 副本中的现有画幅字段，不移动媒体采样。
/// @param file 当前操作使用的文件句柄。
/// @param start 起始。
/// @param end 当前 atom 或范围的结束偏移。
/// @param dimensions 轨道 ID 到原始完整编码尺寸的映射。
/// @param trackSize 轨道尺寸。
/// @param depth 嵌套深度。
NSUInteger sc_ExposeFullLiveFrame(NSFileHandle *file, uint64_t start, uint64_t end,
                                          NSDictionary<NSNumber *, NSValue *> *dimensions,
                                          CMVideoDimensions trackSize, NSUInteger depth) {
    if (depth > 12) [NSException raise:NSInvalidArgumentException format:@"Movie atoms nested too deeply"];
    // changes：实际修正的画幅字段数量。
    NSUInteger changes = 0;
    // cursor：容器内当前读取位置。
    for (uint64_t cursor = start; cursor < end;) {
        // type：实际媒体或容器类型。
        // body：atom 有效负载的起始偏移。
        // next：下一个atom的起始偏移。
        uint32_t type; uint64_t body, next;
        if (!sc_ReadAtom(file, cursor, end, &type, &body, &next)) break;
        // size：尺寸。
        CMVideoDimensions size = type == 'trak' ? sc_DimensionsForMovieTrack(file, body, next, dimensions) : trackSize;
        // video：视频。
        BOOL video = size.width > 0 && size.height > 0 && size.width <= UINT16_MAX && size.height <= UINT16_MAX;
        if (video && type == 'clap') {
            if (next - body < 32) [NSException raise:NSInvalidArgumentException format:@"Invalid clean aperture atom"];
            // values：值集合。
            uint32_t values[] = {(uint32_t)size.width,1,(uint32_t)size.height,1,0,1,0,1};
            // i：当前循环索引。
            for (NSUInteger i = 0; i < 8; i++) sc_WriteBE32(file, body + 4 * i, values[i]);
            changes++;
        } else if (video && type == 'clef') {
            if (next - body < 12) [NSException raise:NSInvalidArgumentException format:@"Invalid track aperture atom"];
            sc_WriteBE32(file, body + 4, (uint32_t)size.width << 16);
            sc_WriteBE32(file, body + 8, (uint32_t)size.height << 16);
            changes++;
        }
        // skip：atom固定头部占用字节数。
        // container：atom是否包含可遍历的子容器。
        uint64_t skip = 0; BOOL container = YES;
        switch (type) {
            case 'moov': case 'trak': case 'mdia': case 'minf': case 'stbl': case 'tapt': break;
            case 'stsd': skip = 8; break;
            case 'avc1': case 'avc3': case 'hvc1': case 'hev1': skip = 78; break;
            default: container = NO; break;
        }
        if (container && skip <= next - body)
            changes += sc_ExposeFullLiveFrame(file, body + skip, next, dimensions, size, depth + 1);
        cursor = next;
    }
    return changes;
}
