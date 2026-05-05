import Foundation
import AVFoundation

@MainActor
final class AudioCues {
    static let shared = AudioCues()

    private var engine: AVAudioEngine?
    private var sessionConfigured = false

    private func configureSession() {
        guard !sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        // .playback + .mixWithOthers so cues are audible over the user's
        // music in the foreground without ducking it. Beeps only fire while
        // the app is foregrounded — no `audio` background mode is declared.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        sessionConfigured = true
    }

    /// Plays a sine-wave beep using AVAudioEngine + a source node.
    func beep(frequency: Double, duration: TimeInterval, volume: Float = 0.4) {
        configureSession()
        let sampleRate: Double = 44_100

        let engine = AVAudioEngine()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        var phase: Double = 0
        let phaseIncrement = 2 * .pi * frequency / sampleRate

        let totalFrames = AVAudioFrameCount(sampleRate * duration)
        var framesGenerated: AVAudioFrameCount = 0

        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buf = abl[0].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frameCount) {
                let totalSoFar = framesGenerated + AVAudioFrameCount(frame)
                if totalSoFar >= totalFrames {
                    buf[frame] = 0
                } else {
                    // Linear fade-out over last 10ms to avoid click.
                    let remaining = Int(totalFrames) - Int(totalSoFar)
                    let fade: Float = remaining < 441 ? Float(remaining) / 441.0 : 1.0
                    buf[frame] = Float(sin(phase)) * volume * fade
                    phase += phaseIncrement
                    if phase > 2 * .pi { phase -= 2 * .pi }
                }
            }
            framesGenerated += frameCount
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            return
        }
        self.engine = engine

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            engine.stop()
        }
    }

    func countdownTick(secondsRemaining: Int) {
        if secondsRemaining > 0 {
            beep(frequency: 800, duration: 0.15, volume: 0.4)
        } else {
            beep(frequency: 1200, duration: 0.4, volume: 0.5)
        }
    }

    func intervalWarning(secondsRemaining: Int) {
        if secondsRemaining > 0 {
            beep(frequency: 600, duration: 0.12, volume: 0.3)
        } else {
            beep(frequency: 1000, duration: 0.3, volume: 0.4)
        }
    }
}
