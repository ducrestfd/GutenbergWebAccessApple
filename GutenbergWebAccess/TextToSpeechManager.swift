//
//  TextToSpeechManager.swift
//  GutenbergWebAccess
//
//  Created by ducrestfd on 1/26/26.
//

/*
Gutenberg Web Access's raison d'être is to provide simple access to
the Gutenberg Project website of 70,000 plus books to both
sighted and blind users.  It is provided without charge under the
agpl-3.0 license.

    Copyright (C) 2025 Frank D. Ducrest

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, either version 3 of the License, or
any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import AVFoundation
import Combine
import NaturalLanguage
import SwiftUI

class TextToSpeechManager: NSObject, ObservableObject,
    AVSpeechSynthesizerDelegate
{
    var currentFileRecord: DownloadedFile?
    
    let session = AVAudioSession.sharedInstance()

    @Published var isSpeaking = false
    @Published var isPaused: Bool = false
    @Published var totalLength: Int = 0
    @Published var currentPosition: Int = 1
    @Published var currentSentenceIndex: Int = 0
    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published var selectedVoiceIdentifier: String? = nil

    @Published var sleepTimerRemaining: TimeInterval? = nil
    private var sleepTimer: Timer? = nil

    private let synthesizer = AVSpeechSynthesizer()
    private var wasSpeakingBeforeInterruption = false
    private var currentCharacterIndex: Int = 0

    private var sentences: [String] = []
    private var currentRate: Float = 0.5
    private var currentPitch: Float = 1.0
    private var isUpdatingSettings = false
    private var language: NLLanguage?

    private var selectedSavedBook: LinkItem?
    var fileDataAccess: FileDataAccess?
    private var fdaFile: DownloadedFile?

    override init() {
        super.init()
        synthesizer.delegate = self  // Set the manager as the delegate

        
        do {
            // Set category to .playback which ignores the silent switch and continues on lock
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
        
        do {
            // .playback: Plays even if the silent switch is on
            // .duckOthers: Lowers the volume of other apps (like music) while speaking
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
            try session.setActive(true)
        } catch {
           //print(//"Failed to set up audio session: \(error)")
        }

        //self.availableVoices = AVSpeechSynthesisVoice.speechVoices()
        
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        
        let systemLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        
        self.availableVoices = allVoices.filter { $0.language.contains(systemLanguage) }
        
        if let defaultVoice = AVSpeechSynthesisVoice(language: "en-US") {
            self.selectedVoiceIdentifier = defaultVoice.identifier
        }

        setupInterruptionObserver()
    }

    func factorySetup(
        selectedSavedBook: LinkItem,
        fileDataAccess: FileDataAccess,
        sentences: [String],
        language: NLLanguage
    ) -> Bool {

        if self.selectedSavedBook?.label == "" {
            return false
        }

        self.selectedSavedBook = selectedSavedBook
        self.fileDataAccess = fileDataAccess
        self.sentences = sentences
        self.language = language

        self.availableVoices = AVSpeechSynthesisVoice.speechVoices().filter {            $0.language.contains(language.rawValue) }
        
        if let firstVoice = self.availableVoices.first {
            self.selectedVoiceIdentifier = firstVoice.identifier
        }

        fdaFile = self.fileDataAccess?.fetchFile(
            named: self.selectedSavedBook?.label ?? ""
        )

        if fdaFile == nil {
            fdaFile = self.fileDataAccess?.addFile(
                fileName: self.selectedSavedBook?.label ?? ""
            )

            self.currentRate =
                UserDefaults.standard.object(forKey: "defaultReadingSpeed")
                    == nil
                ? 0.5
                : UserDefaults.standard.float(forKey: "defaultReadingSpeed")
            self.currentPitch =
                UserDefaults.standard.object(forKey: "defaultReadingPitch")
                    == nil
                ? 1.25
                : UserDefaults.standard.float(forKey: "defaultReadingPitch")
            self.currentSentenceIndex = 0

        } else {
            self.currentRate = fdaFile!.readingSpeed
            self.currentPitch = fdaFile!.readingPitch
            self.currentSentenceIndex = fdaFile!.location
        }

        self.sentences = sentences

        for v in AVSpeechSynthesisVoice.speechVoices() {
              print("\(v.language) - \(v.name) - \(v.identifier)")
          }
        
        
        return true
    }

    func setupAudioSession() {

    }
    
    func getNumberSentences() -> Int {
        sentences.count
    }

    func speak() {
       //print(//"speak")
        synthesizer.stopSpeaking(at: .immediate)
        isPaused = false
        isSpeaking = true
        speakCurrentSentence()
    }

    private func speakCurrentSentence() {
        guard currentSentenceIndex < sentences.count else {
            isSpeaking = false
            return
        }
        let sentence = sentences[currentSentenceIndex]
        let utterance = AVSpeechUtterance(string: sentence)
        if let selId = selectedVoiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: selId) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: language?.rawValue)
        }
        utterance.rate = currentRate
        utterance.pitchMultiplier = currentPitch
        synthesizer.speak(utterance)
    }

    func reset() {
        synthesizer.stopSpeaking(at: .immediate)
        isPaused = true
        isSpeaking = false
        currentSentenceIndex = 0
        self.fdaFile?.location = self.currentSentenceIndex
    }
    
   
    func rateUp() {
        isUpdatingSettings = true
        synthesizer.stopSpeaking(at: .immediate)
        currentRate = currentRate + 0.02 < 0.8 ? currentRate + 0.02 : 0.8
        self.fdaFile?.readingSpeed = self.currentRate
        let sentence = sentences[currentSentenceIndex]
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = currentRate
        utterance.pitchMultiplier = currentPitch
        synthesizer.speak(utterance)
    }

    func rateDown() {
        isUpdatingSettings = true
        synthesizer.stopSpeaking(at: .immediate)
        currentRate = currentRate - 0.02 > 0.2 ? currentRate - 0.02 : 0.2
        self.fdaFile?.readingSpeed = self.currentRate
        let sentence = sentences[currentSentenceIndex]
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = currentRate
        utterance.pitchMultiplier = currentPitch
        synthesizer.speak(utterance)
    }

    func getRate() -> Float {
        currentRate as Float
    }

    func getPitch() -> Float {
        currentPitch as Float
    }

    func pitchUp() {
        isUpdatingSettings = true
        synthesizer.stopSpeaking(at: .immediate)
        currentPitch = currentPitch + 0.05 <= 2.0 ? currentPitch + 0.05 : 2.0
        self.fdaFile?.readingPitch = self.currentPitch
        let sentence = sentences[currentSentenceIndex]
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = currentRate
        utterance.pitchMultiplier = currentPitch
        synthesizer.speak(utterance)
    }

    func pitchDown() {
        isUpdatingSettings = true
        synthesizer.stopSpeaking(at: .immediate)
        currentPitch = currentPitch - 0.05 >= 0.5 ? currentPitch - 0.05 : 0.5
        self.fdaFile?.readingPitch = self.currentPitch
        let sentence = sentences[currentSentenceIndex]
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = currentRate
        utterance.pitchMultiplier = currentPitch
        synthesizer.speak(utterance)
    }

    func jumpForward10Sentences() {
        jumpToSentence(jump: 10)
    }

    func jumpForward30Sentences() {
        jumpToSentence(jump: 30)
    }
    
    func jumpForward100Sentences() {
        jumpToSentence(jump: 100)
    }

    func jumpBackward10Sentences() {
        jumpToSentence(jump: -10)
    }

    func jumpBackward30Sentences() {
        jumpToSentence(jump: -30)
    }

    private func jumpToSentence(jump: Int) {
        var newIndex = currentSentenceIndex + jump
        if newIndex < 0 {
            newIndex = 0
        } else if newIndex >= sentences.count {
            newIndex = sentences.count - 1
        }
        currentSentenceIndex = newIndex
        self.fdaFile?.location = self.currentSentenceIndex
        speakCurrentSentence()
    }

    // --- Delegate Methods ---

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async {
            if self.isUpdatingSettings {
                self.isUpdatingSettings = false
                // Don't advance to next sentence
                return
            }
            if !self.isPaused
                && self.currentSentenceIndex + 1 < self.sentences.count
            {
                self.currentSentenceIndex += 1
                self.speakCurrentSentence()
            } else {
                self.isSpeaking = false
                self.currentSentenceIndex = 0
                // self.sentences = []
            }
            self.fdaFile?.location = self.currentSentenceIndex
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    func pausePlayback() {
       //print(//
       //     "pause 1: paused - \(synthesizer.isPaused), speaking - \(synthesizer.isSpeaking)"
       // )
        if isPaused {
            isPaused = false
            synthesizer.continueSpeaking()
        } else {
            isPaused = true
            synthesizer.pauseSpeaking(at: .word)
            self.fdaFile?.location = self.currentSentenceIndex
        }
       //print(//
       //     "pause 2: paused - \(synthesizer.isPaused), speaking - \(synthesizer.isSpeaking)"
       // )
    }

    func speakingIsPaused() -> Bool {
        isPaused
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey]
                as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .began {
            // System interrupted us (e.g., incoming call)
            wasSpeakingBeforeInterruption = synthesizer.isSpeaking
            // The synthesizer pauses automatically, but you can update UI here
        } else if type == .ended {
            // Interruption ended (e.g., call declined/finished)
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey]
                as? UInt
            {
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: optionsValue
                )

                if options.contains(.shouldResume)
                    && wasSpeakingBeforeInterruption
                {
                    // Reactivate session and resume
                    try? AVAudioSession.sharedInstance().setActive(true)
                    synthesizer.continueSpeaking()
                }
            }
        }
    }

    func resumeSpeech() {
        if isPaused {
            isPaused = false
            speakCurrentSentence()
        }

    }

    // This triggers every time a word is spoken
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // Store the starting location of the current word
        self.currentCharacterIndex = characterRange.location

        // The total character count of the entire text block
        totalLength = utterance.speechString.count
        // The current progress (index)
        currentPosition = characterRange.location
       //print(//"Progress: \(currentPosition) / \(totalLength)")

        // Optional: Save to persistent storage periodically
        UserDefaults.standard.set(
            characterRange.location,
            forKey: "savedSpeechIndex"
        )
    }

    func startSleepTimer(duration: TimeInterval) {
        sleepTimerRemaining = duration
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sleepTimerTick()
        }
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemaining = nil
    }

    private func sleepTimerTick() {
        guard let remaining = sleepTimerRemaining, remaining > 0 else {
            sleepTimer?.invalidate()
            sleepTimer = nil
            sleepTimerRemaining = nil
            self.pausePlayback()
            return
        }
        sleepTimerRemaining = max(0, remaining - 1)
    }
}
