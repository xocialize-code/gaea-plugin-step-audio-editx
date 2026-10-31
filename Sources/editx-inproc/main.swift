import EditXPlugin
import Foundation
import GaeaProtocol
import MLXServeCore
import MLXStepAudioEditX
import MLXToolKit

// The in-process reference for the plugin: Step-Audio-EditX loaded by MLXServeEngine in this process, with the lane
// configuration and the requests the worker builds (EditXPlugin). The edited take is written to --out, and one JSON line
// of timings and the plan is printed. Not part of the plugin bundle.
//
//   editx-inproc --take <wav> --transcript <text> --edit '<MES edit JSON>' [--seed 42] [--lane int8 | bf16]
//                [--models-root <dir>] [--out <wav>]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let laneID = option("--lane") ?? "int8"
let seed = UInt64(option("--seed") ?? "") ?? 42
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
guard let lane = lanes().first(where: { $0.id == laneID }) else { fatalError("no lane \(laneID)") }
guard let takePath = option("--take") else { fatalError("editx-inproc needs --take") }
let edit = try JSONDecoder().decode(JSONValue.self, from: Data((option("--edit") ?? #"{"kind":"denoise"}"#).utf8))
let plan = try editPlan(edit: edit, transcript: option("--transcript"), seed: seed)

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID)
_ = try await engine.register(StepAudioEditXPackage.registration, configuration: lane.configuration, id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.speechEdit, package: id)
var result: [String: Any] = ["model": modelID, "lane": laneID, "seed": seed, "prepare_s": seconds(since: clock),
                             "edit": upstreamName(plan.edit)]

clock = ContinuousClock.now
let take = try Data(contentsOf: URL(fileURLWithPath: takePath))
guard let response = try await engine.run(request(plan, take: take), package: id) as? SpeechEditResponse else {
    fatalError("Step-Audio-EditX returned no take")
}
if let out = option("--out") { try response.audio.data.write(to: URL(fileURLWithPath: out)) }
result["run_s"] = seconds(since: clock)
result["audio_s"] = EditXPlugin.seconds(response.audio.data) ?? 0
if let text = plan.newTranscript { result["transcript"] = text }
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
