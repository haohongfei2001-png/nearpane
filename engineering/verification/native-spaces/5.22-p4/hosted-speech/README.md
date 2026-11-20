# P4 Chinese local speech files

This experiment reads synthetic Mandarin WAV files through Apple's `SpeechAnalyzer` with `SpeechTranscriber` and `SpeechDetector`, the modules used by the local replay probe. The six inputs use three fixed unprimed phrases, each clean and with independent seeded noise at +10 dB source SNR. Each file gets a fresh process. The only outside connection requested by the probe is Apple's model installation through `AssetInventory` on one disposable standard macOS runner. [Apple asset installation](https://developer.apple.com/documentation/speech/assetinventory) · [GitHub standard runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

## Hosted result

**BLOCKED** on the single standard arm64 runner, macOS 26.7.2 (25G332), image 20261117.0516.1. All six WAVs were generated, and the background probe compiled and passed code-signature verification. Apple's public API resolved `zh_CN`, returned `SpeechTranscriber.isAvailable == false`, reported the module assets `unsupported`, and found no installed locale. The probe exited with code 3 after 0.217 seconds, before an installation request could be made. The CI step exited with code 1. All six cases remain NOT_RUN with undefined first-character rate and CER. [Run 44730039447](https://github.com/haohongfei2001-png/nearpane/actions/runs/44730039447) · [Raw JSON from the runner](hosted-speech.json) · [Artifact verification](ci-run.json)

The three clean runner files contained 24,046, 23,535, and 30,501 frames. The three quantized noisy variants measured 9.999982–10.000015 dB. The OS versions produced different clean PCM hashes, which are retained per environment. The framework result describes this hosted runner and probe identity. The local test-runner identity on macOS 27 had previously reported the locale supported and the asset absent. [Earlier local inventory](../voice-apple-file.json)

## Inputs and scoring

`say -v Tingting -r 165 -o` generates each clean reference once per host with direct WAV output. Both conditions use that reference. Every receipt records its 16 kHz mono PCM frame count, clean and mixed hashes, and first clean sample above amplitude 32. The noisy rows also record seed, gain and measured signal-to-noise ratio after quantization. The files live in a temporary directory for the duration of the run. A second local generation reproduced all six WAV hashes. [Local fixture receipt](local-fixtures.json)

For each confirmed framework final, the scorer normalizes NFKC, removes punctuation and spaces, compares the first character, and divides Levenshtein edits by the expected character count. The aggregate CER divides total edits by the number of reference characters in scored cases. A missing final has no score. One explicit empty final counts as deletion of all reference characters. The reported file accuracy applies to the recorded voice and acoustic conditions.

## Earlier signed Host evidence

| Historical source | Preferred finals | Correct first character | Character edits / scored reference characters |
| --- | ---: | ---: | ---: |
| `00efb8b` ordinary cold run | 3/3 | 2/3 | 9/20 |
| `00efb8b` counterbalanced run | 2/2 | 2/2 | 0/12 |
| `0777130` later signed run | 2/3 | 2/2 | 0/12 |

The third round in the later run remains UNKNOWN. These figures were recomputed in memory from existing signed-Host receipts. Each published mask represents one character outside the entire fixture alphabet, so masking preserves equality with every reference character and the resulting edit distance. The receipts retain their original process outcomes. [Source hashes and per-phrase results](archived-finals.json)

## Reproduction

From `scripts/acceptance/native-spaces`, run `python3 p4_apple_file.py fixtures /tmp/fixture-receipt.json` for file-only generation or `python3 p4_apple_file.py archive /tmp/archive-receipt.json` for rescoring historical synthetic finals. The five in-memory scoring regressions run with `python3 -m unittest test_p4_apple_file`. The signed probe exits with code 7 if local execution attempts to prepare the model.

The installed Nearpane 5.22 (90) microphone contract still requires 60 independent Host starts and durable UI, WAV and final readbacks. These file tests add zero installed trials. Reverting the dedicated probe and workflow removes this experiment. Production binaries, settings, permissions and provider selection use the existing P4 baseline.
