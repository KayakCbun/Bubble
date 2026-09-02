import AVFoundation
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func sineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, phase: Double) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let channels = Int(format.channelCount)
    for frame in 0..<Int(frames) {
        let sample = Float(sin((Double(frame) + phase) * 2 * Double.pi * 440 / format.sampleRate) * 0.25)
        if format.isInterleaved, let data = abl[0].mData?.assumingMemoryBound(to: Float.self) {
            for channel in 0..<channels {
                data[frame * channels + channel] = sample
            }
        } else if let data = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
            data[frame] = sample
            if channels > 1, abl.count > 1, let right = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                right[frame] = sample
            }
        }
    }
    return buffer
}

@main
enum RecordAudioCheck {
    static func main() {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = RecordAudioConvert.converter(from: inputFormat, to: outputFormat) else {
            FileHandle.standardError.write(Data("FAIL: could not build test converter\n".utf8))
            exit(1)
        }

        var produced = 0
        var lastFrames: AVAudioFrameCount = 0
        for index in 0..<8 {
            let input = sineBuffer(format: inputFormat, frames: 480, phase: Double(index) * 480)
            let output = RecordAudioConvert.convertPacket(input, to: outputFormat, converter: converter)
            if let output, output.frameLength > 0, RecordAudioConvert.peak(output) > 0.01 {
                produced += 1
                lastFrames = output.frameLength
            }
        }
        expect(
            produced == 8,
            "streaming convert keeps producing after the first packet (got \(produced)/8)"
        )
        expect(lastFrames > 0, "later packets still have frames")
        expect(
            RecordAudioConvert.formatsMatch(outputFormat, outputFormat),
            "identical formats match"
        )
        expect(
            !RecordAudioConvert.formatsMatch(inputFormat, outputFormat),
            "48 kHz stereo does not match 16 kHz mono"
        )
        print("record audio convert checks passed packets=\(produced) lastFrames=\(lastFrames)")
    }
}
