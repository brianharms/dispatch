import Speech
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: transcribe <audio-file>\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
    fputs("Speech recognizer not available\n", stderr)
    exit(1)
}

let request = SFSpeechURLRecognitionRequest(url: url)
request.shouldReportPartialResults = false

var done = false

recognizer.recognitionTask(with: request) { result, error in
    if let result = result, result.isFinal {
        print(result.bestTranscription.formattedString)
        done = true
        CFRunLoopStop(CFRunLoopGetMain())
    } else if let error = error {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        done = true
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

// Run the main RunLoop so callbacks can fire
let timeout = Date(timeIntervalSinceNow: 15)
while !done && Date() < timeout {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
}

if !done {
    fputs("Timed out\n", stderr)
    exit(1)
}
