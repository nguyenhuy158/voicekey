#!/usr/bin/env swift
// Test Whisper with Vietnamese-accented English on macOS
// Usage: ./test_whisper.swift [duration_seconds]
//        ./test_whisper.swift 10 /path/to/model.bin
//        ./test_whisper.swift 5 ~/whisper.cpp/models/ggml-base.en.bin

import Foundation
import AVFoundation

// ===== Parse args =====
let args = Array(CommandLine.arguments.dropFirst())
let durationSeconds: Int = Int(args.first ?? "5") ?? 5
let customModel: String? = args.count >= 2 ? args[1] : nil

// ===== Locate model =====
let home = FileManager.default.homeDirectoryForCurrentUser.path
let homeBrewModels = "/opt/homebrew/share/whisper-cpp/models"

let modelCandidates = [
    customModel,
    "\(home)/whisper.cpp/models/ggml-base.en.bin",
    "\(home)/whisper.cpp/models/ggml-small.en.bin",
    "\(home)/whisper.cpp/models/ggml-medium.en.bin",
    "\(homeBrewModels)/ggml-base.en.bin",
    "\(homeBrewModels)/ggml-small.en.bin",
    "\(homeBrewModels)/ggml-medium.en.bin",
    "\(home)/models/ggml-base.en.bin",
    "\(home)/Documents/macos-app/whisper-test/ggml-base.en.bin",
    "./ggml-base.en.bin",
].compactMap { $0 }

let modelPath = modelCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })

// ===== Locate whisper binary =====
let binCandidates = [
    "/opt/homebrew/bin/whisper-cli",
    "/usr/local/bin/whisper-cli",
    "\(home)/whisper.cpp/build/bin/whisper-cli",
    "\(home)/whisper.cpp/build/bin/whisper",
    "\(home)/whisper.cpp/main",
]
let whisperBinary = binCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })

// ===== Pre-flight check =====
print("🔎  Looking for files...")
print("   Home: \(home)")
print("   Model candidates checked:")
for c in modelCandidates {
    let mark = FileManager.default.fileExists(atPath: c) ? "✅" : "  "
    print("   \(mark) \(c)")
}
print("   Whisper binary: \(whisperBinary ?? "❌ NOT FOUND")")

guard let modelPath else {
    print("""
    \n❌ Model not found. Either:
       1. Pass path:  ./test_whisper.swift 5 /path/to/model.bin
       2. Download:   cd ~/whisper.cpp && bash ./models/download-ggml-model.sh base.en
       3. Or symlink: ln -s ~/whisper.cpp/models/ggml-base.en.bin ./ggml-base.en.bin
    """)
    exit(1)
}
guard let whisperBinary else {
    print("\n❌ Whisper binary not found. Run: brew install whisper-cpp")
    exit(1)
}

print("\n   Using model: \(modelPath)")
print("   Using binary: \(whisperBinary)\n")

// ===== Step 1: Record mic =====
let wavPath = "/tmp/whisper-test-\(UUID().uuidString).wav"
print("🎙  Recording \(durationSeconds)s from default mic...")
print("   Speak English NOW (Vietnamese accent is fine)\n")

let recorder: AVAudioRecorder
do {
    recorder = try AVAudioRecorder(
        url: URL(fileURLWithPath: wavPath),
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
    )
} catch {
    print("❌ Failed to create recorder: \(error)")
    exit(1)
}

guard recorder.record(forDuration: TimeInterval(durationSeconds)) else {
    print("❌ Failed to start recording. Check mic permission in System Settings → Privacy & Security → Microphone.")
    exit(1)
}

for i in 1...durationSeconds {
    sleep(1)
    print("   \(i)/\(durationSeconds)s", terminator: "\r")
}
print("\n   Done recording.\n")

// ===== Step 2: Run whisper =====
print("🔍  Transcribing with Whisper...")
let process = Process()
process.executableURL = URL(fileURLWithPath: whisperBinary)
process.arguments = [
    "-m", modelPath,
    "-f", wavPath,
    "-l", "en",
    "--no-timestamps",
]

let stdoutPipe = Pipe()
let stderrPipe = Pipe()
process.standardOutput = stdoutPipe
process.standardError = stderrPipe

try process.run()
process.waitUntilExit()

let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
let output = String(data: outputData, encoding: .utf8) ?? ""

print("\n📝  Transcript:\n")
print(output)
print("")

// Cleanup
try? FileManager.default.removeItem(atPath: wavPath)

if process.terminationStatus != 0 {
    print("⚠️  Whisper stderr:")
    print(String(data: errData, encoding: .utf8) ?? "")
}