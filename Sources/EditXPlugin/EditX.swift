import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXStepAudioEditX
import MLXToolKit

// gaea-plugin-step-audio-editx: StepFun's Step-Audio-EditX (Apache-2.0; the MLX port, mlx-step-audio-editx-swift, is
// MIT) on MES Audio 0.1's audio.edit_speech (media-engine-spec v0.7.0, Gaea AB-T-0397). One model, the speech editor:
// a take and its transcript come back saying the same words in the same voice, re-delivered once (Audio §3.3):
//
// - emotion: the MES labels onto upstream's fifteen (`neutral` is upstream's `remove`);
// - style: the MES styles onto upstream's (`normal` is `remove`, `narration` is `story`, `conversational` is `chat`);
// - add_cue: laugh, sigh, breath and hesitation as upstream's paralinguistic tags, at the start, at the end, or where a
//   transcript with the cue inline puts it. The take's new transcript is the `transcript` output;
// - denoise, and trim_silence (upstream's `vad`).
//
// The model regenerates the take, so its length changes (`keeps_length: false`), and it conditions on the transcript,
// which is required. Sampling is seeded by the package, so the same request gives the same WAV, here and in
// editx-inproc. Two lanes, the LM's quant: int8 (the default) and bf16, with the package's measured footprints.

public let modelID = "step-audio-editx"
public let sampleRate = 24000
/// The package's ceiling: the LM's 8 192-token window holds the prompt and a regeneration as long as the take.
public let maxInputSeconds = 90.0, minInputSeconds = 0.5
/// About what a 90 s take says, with room to spare.
public let maxTranscriptChars = 1500

/// MES emotion labels (§2.1) and upstream's.
public let emotionLabels: [(mes: String, upstream: String)] = [
    ("neutral", "remove"), ("happy", "happy"), ("sad", "sad"), ("angry", "angry"), ("afraid", "fear"),
    ("disgusted", "disgusted"), ("surprised", "surprised"), ("excited", "excited"), ("humorous", "humour"),
    ("confused", "confusion"), ("empathetic", "empathy"), ("embarrassed", "embarrass"), ("depressed", "depressed"),
    ("cold", "coldness"), ("admiring", "admiration"),
]
/// MES styles (§2.1) and upstream's. Upstream's other styles have no MES label.
public let styleLabels: [(mes: String, upstream: String)] = [
    ("normal", "remove"), ("whisper", "whisper"), ("shout", "shout"), ("gentle", "gentle"), ("serious", "serious"),
    ("warm", "warm"), ("narration", "story"), ("conversational", "chat"), ("news", "news"),
]
/// MES cues (§2.2) and upstream's paralinguistic tags.
public let cueTags: [(mes: String, upstream: String)] = [
    ("laugh", "[Laughter]"), ("sigh", "[Sigh]"), ("breath", "[Breathing]"), ("hesitation", "[Uhm]"),
]
/// The edit kinds the offer lists, the cheapest first: the conformance suite runs the first.
public let editKinds = ["emotion", "style", "add_cue", "denoise", "trim_silence"]
/// Every registered MES cue, so a transcript's other cues are recognised as cues, not words.
let registeredCues = ["laugh", "cough", "sigh", "breath", "pause", "gasp", "clear_throat", "hesitation", "sob", "sniff"]

// MARK: - Transcripts

/// A transcript in MES cue syntax (§2.2), in pieces.
public enum Segment: Equatable, Sendable {
    case text(String)
    case cue(String)
}

/// Splits MES text into words and cues: `[laugh]`, `[pause 1.5s]`; `\[` is a literal bracket, and bracketed text that
/// isn't cue-shaped is text.
public func segments(_ text: String) -> [Segment] {
    var out: [Segment] = []
    var words = ""
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "[" {
            words.append("[")
            i = text.index(i, offsetBy: 2)
            continue
        }
        if c == "[", let close = text[i...].firstIndex(of: "]") {
            let inner = String(text[text.index(after: i)..<close])
            let name = inner.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if registeredCues.contains(name), name == "pause" || inner == name {
                if !words.isEmpty { out.append(.text(words)); words = "" }
                out.append(.cue(name))
                i = text.index(after: close)
                continue
            }
        }
        words.append(c)
        i = text.index(after: i)
    }
    if !words.isEmpty { out.append(.text(words)) }
    return out
}

/// MES text as the model reads it: each cue it performs as upstream's tag, and the others removed (`cue_unsupported`,
/// once per cue).
public func modelText(_ text: String, param: String) -> (text: String, warnings: [Warning]) {
    var out = ""
    var dropped: [String] = []
    for segment in segments(text) {
        switch segment {
        case .text(let words): out += words
        case .cue(let name):
            if let tag = cueTags.first(where: { $0.mes == name })?.upstream {
                out += tag
            } else if !dropped.contains(name) {
                dropped.append(name)
            }
        }
    }
    let squeezed = out.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let warnings = dropped.map {
        Warning(code: "cue_unsupported", message: "Step-Audio-EditX can't read [\($0)]; it was removed from the \(param).", param: param)
    }
    return (squeezed, warnings)
}

// MARK: - Planning

/// What an edit job asks of the package, validated.
public struct EditPlan: Sendable, Equatable {
    public var edit: SpeechEditOperation
    /// The take's transcript as the model reads it.
    public var transcript: String
    /// The take's new transcript, in MES syntax, when the edit changes it (`add_cue`).
    public var newTranscript: String?
    public var seed: UInt64
    public var warnings: [Warning]
    public var effective: [String: JSONValue]
}

func refuse(_ message: String, _ param: String = "edit") -> GPPError {
    GPPError(.invalidRequest, message, detail: ["param": .string(param)])
}

public func editPlan(edit: JSONValue?, transcript: String?, seed: UInt64) throws -> EditPlan {
    guard let edit, let kind = edit["kind"]?.stringValue else { throw refuse("audio.edit_speech needs an edit with its kind.") }
    guard let said = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty else {
        throw refuse("Step-Audio-EditX needs the take's transcript: it re-says those words.", "transcript")
    }
    guard said.count <= maxTranscriptChars else {
        throw refuse("A transcript is at most \(maxTranscriptChars) characters.", "transcript")
    }
    let (text, warnings) = modelText(said, param: "transcript")
    guard !text.isEmpty else { throw refuse("The transcript has no words.", "transcript") }
    var effective: [String: JSONValue] = ["seed": .int(Int64(seed)), "edit": edit]
    var plan = EditPlan(edit: .denoise, transcript: text, newTranscript: nil, seed: seed, warnings: warnings, effective: effective)
    switch kind {
    case "emotion":
        let label = edit["emotion"]?.stringValue ?? ""
        guard let upstream = emotionLabels.first(where: { $0.mes == label })?.upstream else {
            throw refuse("Step-Audio-EditX can't re-deliver as \(label).")
        }
        plan.edit = .emotion(upstream)
    case "style":
        let label = edit["style"]?.stringValue ?? ""
        guard let upstream = styleLabels.first(where: { $0.mes == label })?.upstream else {
            throw refuse("Step-Audio-EditX has no style \(label).")
        }
        plan.edit = .style(upstream)
    case "add_cue":
        let cue = edit["cue"]?.stringValue ?? ""
        guard let tag = cueTags.first(where: { $0.mes == cue })?.upstream else {
            throw refuse("Step-Audio-EditX can't add [\(cue)].")
        }
        if let placed = edit["text"]?.stringValue {
            // The new transcript, with the cue where it goes.
            guard segments(placed).contains(.cue(cue)) else {
                throw refuse("An add_cue edit's text is the transcript with [\(cue)] inline.")
            }
            let (target, more) = modelText(placed, param: "edit")
            plan.edit = .paralinguistic(targetTranscript: target)
            plan.newTranscript = placed
            plan.warnings += more.filter { !plan.warnings.contains($0) }
        } else {
            let at = edit["at"]?.stringValue ?? "end"
            switch at {
            case "start":
                plan.edit = .paralinguistic(targetTranscript: tag + text)
                plan.newTranscript = "[\(cue)] " + said
            case "end":
                plan.edit = .paralinguistic(targetTranscript: text + tag)
                plan.newTranscript = said + " [\(cue)]"
            default:
                throw refuse("An add_cue edit's 'at' is start or end.")
            }
        }
    case "denoise":
        plan.edit = .denoise
    case "trim_silence":
        plan.edit = .trimSilence
    default:
        throw refuse("Step-Audio-EditX doesn't make \(kind) edits.")
    }
    effective["x-stepfun.edit"] = .string(upstreamName(plan.edit))
    plan.effective = effective
    return plan
}

/// The edit as upstream names it, for `effective`.
public func upstreamName(_ edit: SpeechEditOperation) -> String {
    switch edit {
    case .emotion(let label): "emotion:\(label)"
    case .style(let label): "style:\(label)"
    case .paralinguistic(let target): "paralinguistic:\(target)"
    case .denoise: "denoise"
    case .trimSilence: "vad"
    @unknown default: "unknown"
    }
}

/// The engine request for a plan.
public func request(_ plan: EditPlan, take: Data) -> SpeechEditRequest {
    SpeechEditRequest(audio: Audio(format: .wav, data: take, sampleRate: nil, channels: nil), transcript: plan.transcript,
                      edit: plan.edit, seed: plan.seed)
}

/// A take's length in seconds, from a canonical PCM WAV's header (Gaea sends every audio input as one).
public func seconds(_ wav: Data) -> Double? {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8) else { return nil }
    func u16(_ at: Int) -> Int { Int(wav[wav.startIndex + at]) | Int(wav[wav.startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    let channels = u16(22), rate = u32(24), bits = u16(34)
    guard channels > 0, rate > 0, bits > 0 else { return nil }
    return Double(wav.count - 44) / Double(channels * bits / 8) / Double(rate)
}

public func seed(_ job: Job) -> UInt64 { job.seed.map { $0 & 0xFFFF_FFFF } ?? UInt64.random(in: 0..<(1 << 32)) }

let editOperation = EngineOperation("audio.edit_speech") { job, session in
    guard let takeURL = job.input("audio") else { throw refuse("audio.edit_speech needs the take.", "audio") }
    let take = try Data(contentsOf: takeURL)
    if let length = seconds(take) {
        guard length >= minInputSeconds else { throw refuse("The take is shorter than \(minInputSeconds) s.", "audio") }
        guard length <= maxInputSeconds else {
            throw refuse(String(format: "The take is %.1f s; Step-Audio-EditX edits at most %.0f s.", length, maxInputSeconds), "audio")
        }
    }
    let plan = try editPlan(edit: job.param("edit"), transcript: try job.text("transcript"), seed: seed(job))
    guard let response = try await session.run(request(plan, take: take)) as? SpeechEditResponse else {
        throw GPPError(.modelError, "Step-Audio-EditX returned no take.")
    }
    let url = session.outputDir.appending(path: "audio-0.wav")
    try response.audio.data.write(to: url)
    var outputs: [Output] = [.file("audio", url, mediaType: "audio/wav")]
    if let text = plan.newTranscript { outputs.append(.value("transcript", ["text": .string(text)])) }
    return RunResult(outputs: outputs, effective: plan.effective, warnings: plan.warnings)
}

// MARK: - The plugin

public func lanes() -> [LaneDefinition] {
    [LaneDefinition(id: "int8", default: true, configuration: StepAudioEditXConfiguration(quant: .int8)),
     LaneDefinition(id: "bf16", configuration: StepAudioEditXConfiguration(quant: .bf16))]
}

let editModel = ModelDefinition.engine(StepAudioEditXPackage.self, id: modelID, title: "Step-Audio-EditX",
                                       lanes: lanes(), operations: [editOperation])

let editOffer = PluginManifest.Offer(
    operation: "audio.edit_speech", profile: "audio",
    model: [
        "id": .string(modelID), "title": "Step-Audio-EditX",
        "license": ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://huggingface.co/stepfun-ai/Step-Audio-EditX"],
        "memory_class": "medium", "speed_class": "standard", "quality_tiers": ["standard", "best"],
        "notes": "Re-delivers a spoken take in the same voice: another emotion or style, a laugh, sigh, breath or hesitation added, background noise removed, or silences trimmed. Send the take's transcript. The take is said again, so its length changes; check the words if they must survive. English and Chinese, up to 90 s.",
        "supports": [
            "edits": .array(editKinds.map { .string($0) }),
            "emotions": .array(emotionLabels.map { .string($0.mes) }),
            "styles": .array(styleLabels.map { .string($0.mes) }),
            "cues": .array(cueTags.map { .string($0.mes) }),
            "transcript": "required", "keeps_length": false, "languages": ["en", "zh"],
            "sample_rate": .int(Int64(sampleRate)), "channels": 1,
        ],
        "limits": ["max_duration_s": .double(maxInputSeconds), "max_text_chars": .int(Int64(maxTranscriptChars))],
    ])

public let editXPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.step-audio-editx", version: "0.1.0", minGaea: "0.9.2", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-step-audio-editx", title: "Step-Audio-EditX",
    summary: "Step-Audio-EditX: edits a spoken take in its own voice (MES audio.edit_speech): another emotion or speaking style, an added laugh, sigh, breath or hesitation, denoised, or with its silences trimmed.",
    license: "Apache-2.0", executable: "gaea-step-audio-editx-worker",
    models: [editModel], offers: [editOffer])
