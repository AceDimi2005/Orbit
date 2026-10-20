import AVFoundation
import Copus
import Foundation
import os

/// Decodes Opus multistream audio from the host and plays it through AVAudioEngine.
/// The library calls `initialize`/`decodeAndPlay`/`cleanup` on its audio thread.
final class MoonlightAudioRenderer {
    private var decoder: OpaquePointer?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var channelCount = 2
    private var samplesPerFrame = 240
    private var decodeBuffer: [Float] = []
    private let ring = MoonlightAudioRing()

    func initialize(_ configuration: OPUS_MULTISTREAM_CONFIGURATION) -> Int32 {
        cleanup()
        channelCount = max(1, Int(configuration.channelCount))
        samplesPerFrame = max(1, Int(configuration.samplesPerFrame))
        let sampleRate = Double(configuration.sampleRate)
        var mapping = configuration.mapping
        var error: Int32 = 0
        decoder = withUnsafeBytes(of: &mapping) { raw in
            opus_multistream_decoder_create(configuration.sampleRate, configuration.channelCount, configuration.streams,
                                            configuration.coupledStreams, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), &error)
        }
        guard decoder != nil, error == 0 else { decoder = nil; return -1 }
        decodeBuffer = [Float](repeating: 0, count: samplesPerFrame * channelCount * 2)
        ring.configure(channels: channelCount, capacityFrames: Int(sampleRate / 5))

        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        #endif

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)) else {
            cleanup(); return -1
        }
        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            ring.read(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(audioBufferList))
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanup()
            return -1
        }
        self.engine = engine
        sourceNode = node
        return 0
    }

    func start() {
        if let engine, !engine.isRunning { try? engine.start() }
    }

    func stop() {
        engine?.pause()
    }

    func cleanup() {
        if let engine {
            engine.stop()
            if let sourceNode { engine.detach(sourceNode) }
        }
        engine = nil
        sourceNode = nil
        if let decoder { opus_multistream_decoder_destroy(decoder) }
        decoder = nil
        ring.clear()
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func decodeAndPlay(_ data: UnsafeMutablePointer<CChar>?, length: Int32) {
        guard let decoder, let data, length > 0 else { return }
        // Drop audio when the library's queue falls behind rather than growing latency.
        if LiGetPendingAudioDuration() > 30 { return }
        let bytes = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
        let decoded = decodeBuffer.withUnsafeMutableBufferPointer { buffer in
            opus_multistream_decode_float(decoder, bytes, length, buffer.baseAddress!, Int32(samplesPerFrame), 0)
        }
        guard decoded > 0 else { return }
        ring.write(decodeBuffer, frames: Int(decoded))
    }
}

/// Interleaved float ring buffer shared between the decode thread and the audio render callback.
final class MoonlightAudioRing {
    private var storage: [Float] = []
    private var channels = 2
    private var capacityFrames = 0
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private let lock = OSAllocatedUnfairLock()

    func configure(channels: Int, capacityFrames: Int) {
        lock.withLock {
            self.channels = max(1, channels)
            self.capacityFrames = max(256, capacityFrames)
            storage = [Float](repeating: 0, count: self.capacityFrames * self.channels)
            readIndex = 0; writeIndex = 0; availableFrames = 0
        }
    }

    func clear() {
        lock.withLock { readIndex = 0; writeIndex = 0; availableFrames = 0 }
    }

    func write(_ samples: [Float], frames: Int) {
        lock.withLock {
            guard capacityFrames > 0 else { return }
            var frames = min(frames, capacityFrames)
            // Make room by dropping the oldest audio when the ring is full.
            let overflow = availableFrames + frames - capacityFrames
            if overflow > 0 {
                readIndex = (readIndex + overflow) % capacityFrames
                availableFrames -= overflow
            }
            var source = 0
            while frames > 0 {
                let chunk = min(frames, capacityFrames - writeIndex)
                for frame in 0..<chunk {
                    for channel in 0..<channels {
                        storage[(writeIndex + frame) * channels + channel] = samples[(source + frame) * channels + channel]
                    }
                }
                writeIndex = (writeIndex + chunk) % capacityFrames
                source += chunk
                frames -= chunk
                availableFrames += chunk
            }
        }
    }

    /// Fills a deinterleaved buffer list; missing data becomes silence.
    func read(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        lock.withLock {
            let channelBuffers = buffers.count
            for channel in 0..<channelBuffers {
                guard let data = buffers[channel].mData else { continue }
                let output = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    if frame < availableFrames, channel < channels {
                        output[frame] = storage[((readIndex + frame) % capacityFrames) * channels + channel]
                    } else {
                        output[frame] = 0
                    }
                }
            }
            let consumed = min(frames, availableFrames)
            if capacityFrames > 0 { readIndex = (readIndex + consumed) % capacityFrames }
            availableFrames -= consumed
        }
    }
}
