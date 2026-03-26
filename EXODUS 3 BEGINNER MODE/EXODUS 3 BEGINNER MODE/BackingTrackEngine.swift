import AVFoundation

final class BackingTrackEngine {
    private let intendedLoopLengthInBeats: TimeInterval = 16
    private let engine = AVAudioEngine()
    private let keysSampler = AVAudioUnitSampler()
    private let bassSampler = AVAudioUnitSampler()
    private let drumsSampler = AVAudioUnitSampler()
    private lazy var sequencer = AVAudioSequencer(audioEngine: engine)
    private lazy var soundBankURL: URL? = BackingTrackEngine.locateSoundBank()
    private(set) var currentTrack: BackingTrack?
    private(set) var isPlaying: Bool = false
    private var currentArrangement: BackingArrangementPreset = .epDrumsPad
    private var currentTransposeSemitones: Int = 0
    private var isInitialized = false

    init() {
        engine.attach(keysSampler)
        engine.attach(bassSampler)
        engine.attach(drumsSampler)
        engine.connect(keysSampler, to: engine.mainMixerNode, format: nil)
        engine.connect(bassSampler, to: engine.mainMixerNode, format: nil)
        engine.connect(drumsSampler, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0.72
        configureAudioSession()
        reportSoundBankStatus()
        // Defer sampler loading until first play to avoid blocking startup
    }

    private func ensureInitialized() {
        guard !isInitialized else { return }
        guard let soundBankURL else {
            print("⚠️ Cannot initialize - no soundbank available")
            return
        }
        print("🎵 Initializing with soundbank: \(soundBankURL.lastPathComponent)")
        loadSamplerVoices(for: currentArrangement)
        applyArrangementMix()
        startEngineIfNeeded()
        isInitialized = true
    }

    func configure(arrangement: BackingArrangementPreset, transposeSemitones: Int) {
        let normalizedTranspose = max(-24, min(transposeSemitones, 24))
        guard arrangement != currentArrangement || normalizedTranspose != currentTransposeSemitones else { return }
        currentArrangement = arrangement
        currentTransposeSemitones = normalizedTranspose
        loadSamplerVoices(for: arrangement)
        applyArrangementMix()
        applyTranspose()
    }

    func togglePlayback(for track: BackingTrack) {
        if currentTrack == track, isPlaying {
            stop()
        } else {
            play(track: track)
        }
    }

    func play(track: BackingTrack) {
        print("🎵 BackingTrackEngine.play() called with: \(track.title)")
        
        guard let trackURL = track.resourceURL() else {
            print("❌ MIDI file missing from bundle: \(track.resourceName).\(track.fileExtension)")
            return
        }
        
        ensureInitialized()

        // Stop any existing playback
        if sequencer.isPlaying {
            sequencer.stop()
        }
        
        // Ensure engine is running
        if !engine.isRunning {
            do {
                try engine.start()
                print("✅ Audio engine started")
            } catch {
                print("❌ Failed to start audio engine: \(error)")
                return
            }
        }
        
        do {
            // Load MIDI file into sequencer
            sequencer = AVAudioSequencer(audioEngine: engine)
            try sequencer.load(from: trackURL, options: .smf_ChannelsToTracks)
            
            print("🎵 MIDI loaded with \(sequencer.tracks.count) tracks")

            routeTracksToSamplers()
            configureLooping()
            
            // Start playback
            sequencer.prepareToPlay()
            try sequencer.start()
            
            currentTrack = track
            isPlaying = true
            print("▶️ Playing: \(track.title)")
            
        } catch {
            print("❌ Failed to play MIDI: \(error)")
            isPlaying = false
        }
    }

    func stop() {
        stop(clearTrackSelection: true)
    }

    private func stop(clearTrackSelection: Bool) {
        if sequencer.isPlaying {
            sequencer.stop()
        }
        sequencer.currentPositionInBeats = 0
        keysSampler.reset()
        bassSampler.reset()
        drumsSampler.reset()
        if clearTrackSelection {
            currentTrack = nil
        }
        isPlaying = false
    }

    private func routeTracksToSamplers() {
        guard sequencer.tracks.count > 0 else {
            print("⚠️ No tracks to route")
            return
        }
        
        for track in sequencer.tracks {
            track.destinationAudioUnit = nil
            track.isMuted = false
        }

        if sequencer.tracks.count > 1 {
            sequencer.tracks[1].destinationAudioUnit = keysSampler
        }
        if sequencer.tracks.count > 2 {
            sequencer.tracks[2].destinationAudioUnit = bassSampler
        }
        if sequencer.tracks.count > 3 {
            sequencer.tracks[3].destinationAudioUnit = drumsSampler
        }
        print("🎵 Routed \(sequencer.tracks.count) tracks to samplers")
    }

    private func applyTranspose() {
        let cents = Float(currentTransposeSemitones * 100)
        keysSampler.globalTuning = cents
        bassSampler.globalTuning = cents
        drumsSampler.globalTuning = 0
    }

    private func configureLooping() {
        guard sequencer.tracks.count > 0 else { return }
        for track in sequencer.tracks {
            track.loopRange = AVBeatRange(start: 0, length: intendedLoopLengthInBeats)
            track.numberOfLoops = -1
            track.isLoopingEnabled = true
        }
    }

    private func applyArrangementMix() {
        let keysVolume: Float
        let bassVolume: Float
        let drumsVolume: Float

        switch currentArrangement {
        case .epDrumsPad:
            keysVolume = 0.82
            bassVolume = 0.72
            drumsVolume = 0.82
        case .keysDrumsStrings:
            keysVolume = 0.88
            bassVolume = 0.76
            drumsVolume = 0.8
        case .epDrumsOnly:
            keysVolume = 0.84
            bassVolume = 0
            drumsVolume = 0.86
        case .padDrumsOnly:
            keysVolume = 0.42
            bassVolume = 0
            drumsVolume = 0.84
        }

        keysSampler.volume = keysVolume
        bassSampler.volume = bassVolume
        drumsSampler.volume = drumsVolume

        if sequencer.tracks.count > 2 {
            sequencer.tracks[2].isMuted = bassVolume == 0
        }
    }

    private func loadSamplerVoices(for arrangement: BackingArrangementPreset) {
        guard let soundBankURL else {
            print("⚠️ No soundfont (.sf2/.dls) found — backing tracks will likely sound incorrect.")
            return
        }
        loadInstrument(
            on: keysSampler,
            program: keysProgram(for: arrangement),
            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
            bankLSB: 0,
            soundBankURL: soundBankURL
        )
        loadInstrument(
            on: bassSampler,
            program: 33,
            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
            bankLSB: 0,
            soundBankURL: soundBankURL
        )
        loadInstrument(
            on: drumsSampler,
            program: 0,
            bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
            bankLSB: 0,
            soundBankURL: soundBankURL
        )
        applyTranspose()
    }

    private func keysProgram(for arrangement: BackingArrangementPreset) -> UInt8 {
        switch arrangement {
        case .epDrumsPad:
            return 4
        case .keysDrumsStrings:
            return 48
        case .epDrumsOnly:
            return 4
        case .padDrumsOnly:
            return 89
        }
    }

    private func loadInstrument(on sampler: AVAudioUnitSampler, program: UInt8, bankMSB: UInt8, bankLSB: UInt8, soundBankURL: URL) {
        do {
            try sampler.loadSoundBankInstrument(
                at: soundBankURL,
                program: program,
                bankMSB: bankMSB,
                bankLSB: bankLSB
            )
        } catch {
            print("⚠️ Failed loading program \(program) from \(soundBankURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func reportSoundBankStatus() {
        if let soundBankURL {
            print("✅ Soundbank ready: \(soundBankURL.lastPathComponent)")
        } else {
            print("⚠️ Soundbank missing – add a General MIDI .sf2 (e.g., 'GeneralUser GS MuseScore.sf2') to the target for proper playback.")
        }
    }

    private static func locateSoundBank(in bundle: Bundle = .main) -> URL? {
        // Try the preferred GeneralUser GS MuseScore first
        if let preferred = bundle.url(forResource: "GeneralUser GS MuseScore", withExtension: "sf2") {
            return preferred
        }
        
        // Try the bundled GeneralUser GS v1.472
        if let bundledGS = bundle.url(forResource: "GeneralUser GS v1.472", withExtension: "sf2") {
            return bundledGS
        }
        
        // Try any SF2 file
        if let anySF2 = (bundle.urls(forResourcesWithExtension: "sf2", subdirectory: nil) ?? []).first {
            return anySF2
        }

        // Try bundled DLS
        if let bundledDLS = bundle.url(forResource: "gs_instruments", withExtension: "dls") {
            return bundledDLS
        }

        // Fallback to system DLS
        return URL(string: "file:///System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            print("✅ Audio session configured for playback")
        } catch {
            print("❌ Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            print("✅ Audio engine started")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            // Retry once after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, !self.engine.isRunning else { return }
                do {
                    try self.engine.start()
                    print("✅ Audio engine started on retry")
                } catch {
                    print("❌ Failed to start audio engine on retry: \(error)")
                }
            }
        }
    }
}
