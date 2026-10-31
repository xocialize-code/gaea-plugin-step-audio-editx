# gaea-plugin-step-audio-editx

StepFun's **Step-Audio-EditX** (Apache-2.0) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: a speech editor on
MES Audio 0.1's `audio.edit_speech`. Give it a spoken take and its transcript, and it says the same words again in the
same voice, delivered differently. It is built on [GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[mlx-step-audio-editx-swift](https://github.com/xocialize/mlx-step-audio-editx-swift), runs in its own process, and
speaks the Gaea Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-step-audio-editx
```

## What it offers

One model, `step-audio-editx`, on `audio.edit_speech`. One job makes one edit (`edit: {kind, …}`):

| `kind` | Fields | What it does |
|---|---|---|
| `emotion` | `emotion` | Re-delivers the take with that feeling; `neutral` removes one |
| `style` | `style` | Re-delivers it in that style; `normal` removes one |
| `add_cue` | `cue`, and `at` (`start` or `end`, the default) or `text` | Adds a laugh, sigh, breath or hesitation |
| `denoise` | — | Removes background noise |
| `trim_silence` | — | Removes leading and trailing silence |

- **Emotions:** `neutral`, `happy`, `sad`, `angry`, `afraid`, `disgusted`, `surprised`, `excited`, `humorous`,
  `confused`, `empathetic`, `embarrassed`, `depressed`, `cold` and `admiring`. MES's aliases resolve, so `fearful`
  runs as `afraid`.
- **Styles:** `normal`, `whisper`, `shout`, `gentle`, `serious`, `warm`, `narration`, `conversational` and `news`.
- **Cues:** `laugh`, `sigh`, `breath` and `hesitation`, written as MES cues (`[laugh]`).
  - `at: start` or `at: end` places the cue.
  - `text` is the transcript with the cue where it goes: `"Okay [breath] let's go."`.
  - The take's new transcript comes back as the `transcript` output, `{text}`.
- **The transcript is required.** The model conditions on the take's words. Its cues are read as the model's tags, and
  a cue it can't read is removed with `cue_unsupported`.
- **The take is said again, not filtered.** Its length changes (`keeps_length: false`), and a consumer that must keep
  the words should check them with speech-to-text.
- **Takes** are 0.5 to 90 s, in any format Gaea reads (WAV at any depth, FLAC, MP3, AAC). English and Chinese.
- **Output:** a 24 kHz mono 16-bit WAV, converted by Gaea to the request's `output`.
- **Seeds:** the package seeds its own sampling with the job's seed, so the same request gives the same WAV.
  `effective` reports the seed and upstream's own name for the edit (`x-stepfun.edit`, e.g. `emotion:fear`).

On an M5 Max at int8, warm, an edit of a 4 s take takes about 2.5 s. The first job also loads the model and runs a
one-second warm-up edit, so its kernels are compiled before it counts.

## Lanes and memory

Two lanes, the LM's quant: `int8` (the default, 7.0 GB resident) and `bf16` (10.3 GB), with up to 2 GB more while
editing. These are the package's measured footprints.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default). The lanes read
`mlx-community/Step-Audio-EditX-8bit` (4.4 GB) and `mlx-community/Step-Audio-EditX-bf16` (8.0 GB) there, and download
them on `prepare` or `materialize` when they're missing. The CAM++ speaker encoder ships inside the package.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` makes one edit over GPP on the signed bundle (`Tests/Fixtures/take.wav`, made happy), with every
`.build` folder hidden. It then shows that the bare worker, outside the bundle, finds no metallib.

`scripts/release.sh` builds, checks, notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release.
The release workflow does the same in CI when a `v<version>` tag is pushed.

`editx-inproc` (its header lists the options) is not part of the plugin. It runs the same lanes in-process through
MLXServeEngine, with the worker's requests: the reference Gaea's runs are compared against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` runs seeded edits over GPP on the signed bundle and through `editx-inproc`, and needs each pair to be the
same WAV byte for byte. The cases:
- angry, afraid, whisper and narration;
- a laugh at the end, a breath inline and a sigh at the start, each with its new transcript;
- denoise on a noisy take, and trim_silence on a take padded with silence.

The takes in `Tests/Fixtures` were spoken by Kokoro-82M (Apache-2.0). `noisy.wav` adds white noise and `padded.wav`
adds 1.5 s of silence at each end.

## CI secrets

The release workflow signs with Developer ID and notarizes. It reads four organization secrets on xocialize-code:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD` (Gaea's
`Docs/Signing secrets.md`).

## Licence

The plugin is Apache-2.0 (Gaea G-21). Step-Audio-EditX's weights and code are Apache-2.0 (StepFun). Its Paraformer
tokenizer encoder is under the FunASR model licence, and the CAM++ speaker encoder is Apache-2.0 (Alibaba). The port,
mlx-step-audio-editx-swift, is MIT; see its THIRD_PARTY_NOTICES.md.
