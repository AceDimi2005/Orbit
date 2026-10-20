import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Presents the H.264/HEVC elementary stream through AVSampleBufferDisplayLayer, which decodes
/// with VideoToolbox. `submit` runs on the session's render thread; everything that touches the
/// layer tree happens on the main thread.
public final class MoonlightVideoRenderer: @unchecked Sendable {
    /// Called on the main thread when a failed layer had to be replaced; hosts must re-add it.
    public var onLayerReplaced: ((AVSampleBufferDisplayLayer) -> Void)?

    private let lock = NSLock()
    private var layer: AVSampleBufferDisplayLayer
    private var videoFormat: Int32 = 0
    private var frameRate = 60
    private var size = CGSize.zero
    private var parameterSets: [Data] = []
    private var formatDescription: CMFormatDescription?
    private var masteringDisplayColorVolume: Data?
    private var contentLightLevelInfo: Data?
    private var framePacing = false
    private var timebase: CMTimebase?
    private var timebasePrimed = false
    private var replacingLayer = false
    private var renderedFrames = 0

    public init() {
        layer = Self.makeLayer()
    }

    public var displayLayer: AVSampleBufferDisplayLayer { lock.lock(); defer { lock.unlock() }; return layer }
    /// Stream dimensions in pixels (zero until setup).
    public var videoSize: CGSize { lock.lock(); defer { lock.unlock() }; return size }
    public var hasRenderedFrame: Bool { lock.lock(); defer { lock.unlock() }; return renderedFrames > 0 }
    public var isHEVC: Bool { lock.lock(); defer { lock.unlock() }; return videoFormat & 0x0F00 != 0 }

    public var codecName: String {
        lock.lock(); defer { lock.unlock() }
        switch videoFormat {
        case 0x0001: return "H.264"
        case 0x0100: return "HEVC"
        case 0x0200: return "HEVC Main 10"
        case 0: return ""
        default: return String(format: "0x%X", videoFormat)
        }
    }

    private static func makeLayer() -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.isOpaque = true
        return layer
    }

    // MARK: Library callbacks (render thread / library threads)

    func setup(videoFormat: Int32, width: Int32, height: Int32, frameRate: Int32, framePacing: Bool) {
        lock.lock()
        self.videoFormat = videoFormat
        self.frameRate = max(1, Int(frameRate))
        size = CGSize(width: Int(width), height: Int(height))
        parameterSets.removeAll()
        formatDescription = nil
        self.framePacing = framePacing
        timebasePrimed = false
        renderedFrames = 0
        var created: CMTimebase?
        if framePacing, CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created) == noErr {
            timebase = created
        } else {
            timebase = nil
        }
        let currentLayer = layer
        let currentTimebase = timebase
        lock.unlock()
        DispatchQueue.main.async {
            currentLayer.controlTimebase = currentTimebase
        }
    }

    func reset() {
        lock.lock()
        parameterSets.removeAll()
        formatDescription = nil
        videoFormat = 0
        renderedFrames = 0
        let currentLayer = layer
        lock.unlock()
        DispatchQueue.main.async {
            currentLayer.flushAndRemoveImage()
            currentLayer.controlTimebase = nil
        }
    }

    /// Returns DR_OK (0) or DR_NEED_IDR (-1).
    func submit(_ unit: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        let du = unit.pointee
        var picture = [UInt8]()
        picture.reserveCapacity(Int(max(du.fullLength, 0)))
        var entry = du.bufferList
        while let node = entry {
            let item = node.pointee
            if let data = item.data, item.length > 0 {
                let bytes = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
                if item.bufferType == 0 { // BUFFER_TYPE_PICDATA
                    picture.append(contentsOf: UnsafeBufferPointer(start: bytes, count: Int(item.length)))
                } else if du.frameType == 1 { // FRAME_TYPE_IDR: SPS/PPS/VPS
                    let startLength = item.length > 3 && bytes[2] == 0x01 ? 3 : 4
                    if Int(item.length) > startLength {
                        parameterSets.append(Data(bytes: bytes + startLength, count: Int(item.length) - startLength))
                    }
                }
            }
            entry = item.next
        }

        if du.frameType == 1 {
            if let description = makeFormatDescription() { formatDescription = description }
            parameterSets.removeAll()
        }
        guard let formatDescription else { return -1 }
        guard layerIsHealthy() else { return -1 }
        guard let (buffer, length) = Self.lengthPrefixed(picture) else { return -1 }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: buffer, blockLength: length,
                                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: length, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { free(buffer); return -1 }

        let presentation = CMTime(value: CMTimeValue(du.presentationTimeUs), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        var sampleSize = length
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return -1 }

        lock.lock()
        let pacing = framePacing
        let currentTimebase = timebase
        let primed = timebasePrimed
        let currentLayer = layer
        if pacing && !primed { timebasePrimed = true }
        renderedFrames += 1
        lock.unlock()

        if pacing, let currentTimebase {
            if !primed {
                // Start the clock one frame behind the first frame so jitter is absorbed.
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                CMTimebaseSetTime(currentTimebase, time: presentation - frameDuration)
                CMTimebaseSetRate(currentTimebase, rate: 1)
            }
        } else if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        currentLayer.enqueue(sample)
        return 0
    }

    /// HDR metadata from the host, applied to the next format description (mirrors moonlight-ios).
    func setHDR(enabled: Bool) {
        var metadata = SS_HDR_METADATA()
        let hasMetadata = enabled && LiGetHdrMetadata(&metadata)
        // SS_HDR_METADATA is a packed run of UInt16 fields: primaries R,G,B (x,y), white point,
        // max/min display luminance, max content light level, max frame-average light level.
        let fields: [UInt16] = withUnsafeBytes(of: &metadata) { raw in
            (0..<13).map { raw.load(fromByteOffset: $0 * 2, as: UInt16.self) }
        }
        var changed = false
        lock.lock()
        if hasMetadata, fields[0] != 0, fields[8] != 0 {
            var mdcv = Data()
            func append16(_ value: UInt16) { var big = value.bigEndian; mdcv.append(Data(bytes: &big, count: 2)) }
            func append32(_ value: UInt32) { var big = value.bigEndian; mdcv.append(Data(bytes: &big, count: 4)) }
            // The box stores primaries in GBR order while the host reports RGB.
            append16(fields[2]); append16(fields[3])
            append16(fields[4]); append16(fields[5])
            append16(fields[0]); append16(fields[1])
            append16(fields[6]); append16(fields[7])
            append32(UInt32(fields[8]) * 10_000)
            append32(UInt32(fields[9]))
            if mdcv != masteringDisplayColorVolume { masteringDisplayColorVolume = mdcv; changed = true }
        } else if masteringDisplayColorVolume != nil {
            masteringDisplayColorVolume = nil; changed = true
        }
        if hasMetadata, fields[10] != 0, fields[11] != 0 {
            var cll = Data()
            var maxContent = fields[10].bigEndian
            var maxAverage = fields[11].bigEndian
            cll.append(Data(bytes: &maxContent, count: 2)); cll.append(Data(bytes: &maxAverage, count: 2))
            if cll != contentLightLevelInfo { contentLightLevelInfo = cll; changed = true }
        } else if contentLightLevelInfo != nil {
            contentLightLevelInfo = nil; changed = true
        }
        lock.unlock()
        if changed { LiRequestIdrFrame() }
    }

    // MARK: Helpers

    private func layerIsHealthy() -> Bool {
        let current = displayLayer
        if current.status == .failed {
            replaceLayer()
            return false
        }
        if current.requiresFlushToResumeDecoding {
            current.flush()
            return false
        }
        return true
    }

    private func replaceLayer() {
        lock.lock()
        if replacingLayer { lock.unlock(); return }
        replacingLayer = true
        let currentTimebase = framePacing ? timebase : nil
        lock.unlock()
        DispatchQueue.main.async { [self] in
            let fresh = Self.makeLayer()
            fresh.controlTimebase = currentTimebase
            lock.lock()
            layer = fresh
            replacingLayer = false
            lock.unlock()
            onLayerReplaced?(fresh)
            LiRequestIdrFrame()
        }
    }

    private func makeFormatDescription() -> CMFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let buffers = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = parameterSets.map(\.count)
        var description: CMFormatDescription?
        if videoFormat & 0x000F != 0 { // VIDEO_FORMAT_MASK_H264
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                                                                             parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                             nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            return status == noErr ? description : nil
        }
        if videoFormat & 0x0F00 != 0 { // VIDEO_FORMAT_MASK_H265
            var extensions: [CFString: Any] = [:]
            if let contentLightLevelInfo { extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLightLevelInfo }
            if let masteringDisplayColorVolume { extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplayColorVolume }
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                                                                             parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                             nalUnitHeaderLength: 4,
                                                                             extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
                                                                             formatDescriptionOut: &description)
            return status == noErr ? description : nil
        }
        return nil
    }

    /// Rewrites Annex B start codes (00 00 01) as 4-byte big-endian NAL lengths, the layout
    /// VideoToolbox expects. Returns a malloc'd buffer the CMBlockBuffer takes ownership of.
    private static func lengthPrefixed(_ annexB: [UInt8]) -> (UnsafeMutableRawPointer, Int)? {
        let count = annexB.count
        guard count > 3 else { return nil }
        var starts: [Int] = []
        annexB.withUnsafeBufferPointer { bytes in
            var index = 0
            while index + 2 < count {
                if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                    starts.append(index)
                    index += 3
                } else {
                    index += 1
                }
            }
        }
        guard let first = starts.first else { return nil }
        let outputLength = count - first + starts.count
        guard let output = malloc(outputLength) else { return nil }
        var offset = 0
        annexB.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress else { return }
            for (position, start) in starts.enumerated() {
                let end = position + 1 < starts.count ? starts[position + 1] : count
                let nalLength = end - start - 3
                output.storeBytes(of: UInt32(nalLength).bigEndian, toByteOffset: offset, as: UInt32.self)
                memcpy(output + offset + 4, base + start + 3, nalLength)
                offset += 4 + nalLength
            }
        }
        return (output, offset)
    }
}
