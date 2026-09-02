# Local speech-to-text models, 2026

Date: 2026-09-02

## Recommendation

There is no single local model that is both the fastest and the most accurate. The 2024 default (Whisper large-v3) is no longer the English or Chinese winner. Pick by language and latency:

| You want | Use this | Why |
| --- | --- | --- |
| English, fastest high-quality offline | **NVIDIA Parakeet TDT 0.6B v2** | 6.05% Open ASR mean WER at ~3380× real-time. Best speed/quality ratio. |
| English + 25 European languages, still very fast | **NVIDIA Parakeet TDT 0.6B v3** | Same architecture, 6.32–6.34% English WER, auto language detect, timestamps, CC-BY-4.0. |
| English, highest local accuracy | **IBM Granite Speech 4.1 2B** or **NVIDIA Canary-Qwen 2.5B** | Granite ~5.33% Open ASR mean WER (Apr 2026 snapshot). Canary-Qwen 5.63% at 418×; NVIDIA's own "best English" pick. |
| Chinese / CJK, fastest on CPU or Mac | **SenseVoice-Small** (FunASR) | 234M, non-autoregressive. ~170× GPU / ~17× CPU. Mandarin CER ~7.8% vs Whisper ~20% on FunASR's long-form set. |
| Chinese, highest local accuracy | **FireRedASR2-AED** (compact) or **FireRedASR2-LLM** | Mandarin Avg-4 CER 3.05% (AED) / 2.89% (LLM). Beats Qwen3-ASR and Fun-ASR-Nano on those Mandarin sets. |
| One model for Chinese dialects + 50 languages | **Qwen3-ASR 1.7B** | 30 languages + 22 Chinese dialects, Apache 2.0. Open ASR ~5.6–5.8% English WER. 0.6B is the throughput variant (vendor: 2000× at concurrency 128). |
| Live dictation / streaming | **NVIDIA Nemotron 3.5 ASR Streaming 0.6B** | Cache-aware FastConformer-RNNT, 80 ms–1.12 s latency, 40 locales including zh-CN. English-only sibling: `nemotron-speech-streaming-en-0.6b`. |
| Tiny / Raspberry Pi / phone | **Moonshine Streaming Tiny/Medium** | 34M–245M, MIT, CPU-only. Medium: 6.65% Open ASR WER. |
| 99-language long tail | **Whisper large-v3-turbo** | Still the coverage default. English WER ~7.8%, slower than Parakeet. Use mlx-whisper / faster-whisper / whisper.cpp. |
| Speech-to-text *translation* (AST) | **NVIDIA Canary-1B-v2** or **Granite Speech 4.1** | Canary: 25 EU languages ASR + AST. Granite: bidirectional AST among EN/FR/DE/ES/PT/JA plus EN→IT/ZH. |

For a Mac running Bubble: **Parakeet v3 via `parakeet-mlx` / FluidAudio** for English and European languages; **SenseVoice-Small** for Mandarin / Cantonese / Japanese / Korean; **Qwen3-ASR 1.7B (MLX 8-bit)** if you need Chinese dialects plus a wide language list in one download.

## What "AST" means here

The query asked for local AST speech-to-text models. Two readings:

1. **ASR** (automatic speech recognition / 语音转文字). This is the usual intent.
2. **AST** as NVIDIA uses it: **automatic speech translation** (speech in language A → text in language B). Covered at the end.

This note treats local open-weight models only. Cloud APIs (ElevenLabs Scribe, Deepgram Nova-3, AssemblyAI, OpenAI) are out of scope except as a quality ceiling.

## English quality vs speed (Open ASR Leaderboard)

The shared English yardstick is the [Hugging Face Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard): eight short-form sets (AMI, Earnings-22, GigaSpeech, LibriSpeech clean/other, SPGISpeech, TED-LIUM, VoxPopuli). Lower mean WER is better. RTFx is audio-seconds transcribed per wall-clock second on the leaderboard's GPU job (higher is faster). Leaderboard RTFx is a *batched throughput* number, not dictation latency.

Numbers below come from first-party model cards, the leaderboard eval YAML, NVIDIA's Canary/Parakeet paper, and the Open ASR paper ([arXiv:2510.06961](https://arxiv.org/abs/2510.06961)). Snapshots moved during 2026; treat ±0.1–0.3 WER as noise.

| Model | Params | English mean WER | RTFx (leaderboard) | Languages | License |
| --- | --- | --- | --- | --- | --- |
| IBM Granite Speech 4.1 2B | 2B | **~5.33** (Apr 2026 PwC/Open ASR snapshot) | ~231 | EN + FR/DE/ES/PT/JA (AST too) | Apache 2.0 |
| Cohere Labs Transcribe (Mar 2026) | — | 5.42 | 525 | 14 | open (leaderboard) |
| NVIDIA Canary-Qwen 2.5B | 2.5B | **5.63** | **418** | English ASR (+ LLM post-process) | CC-BY-4.0 |
| Qwen3-ASR-1.7B | 1.7B | 5.76 (full 8-set); **5.59** on 7-set HF-native card (no TED-LIUM) | ~148 | 52 langs/dialects | Apache 2.0 |
| IBM Granite Speech 3.3 8B / 2B | 8B / 2B | 5.74 / 6.00 | 145 / 271 | 5–6 | Apache 2.0 |
| Phi-4 Multimodal Instruct | ~6B | 6.02 | 151 | 8 | MIT |
| **Parakeet TDT 0.6B v2** | 0.6B | **6.05** | **~3386–3390** | English | CC-BY-4.0 |
| **Parakeet TDT 0.6B v3** | 0.6B | **6.32–6.34** | **~3330–3333** | 25 European | CC-BY-4.0 |
| Moonshine Streaming Medium | 245M | 6.65–6.66 | 448 | English | MIT |
| NVIDIA Canary 1B v2 | 1B | 7.15 | 749 | 25 EU + AST | CC-BY-4.0 |
| Whisper large-v3 | 1.55B | 7.44 | ~146 | 99 | MIT |
| Whisper large-v3-turbo | 809M | 7.83 | ~200 | 99 | MIT |

Sources: [Canary-Qwen card](https://huggingface.co/nvidia/canary-qwen-2.5b), [Parakeet v2 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), [Parakeet v3 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [eval YAML](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/blob/main/.eval_results/open_asr_leaderboard.yaml), [Qwen3-ASR-1.7B-hf eval](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf), [Granite Speech 4.1 card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b), [Moonshine Streaming Medium card](https://huggingface.co/moonshine-ai/moonshine-streaming-medium), [Open ASR paper Table](https://arxiv.org/html/2510.06961), [Papers with Code Open ASR](https://paperswithcode.co/benchmark/open-asr-leaderboard?eval=4360), [Canary-1B-v2 & Parakeet-v3 report](https://arxiv.org/html/2509.14128v1).

### How to read that table

- **Fastest among strong models:** Parakeet TDT. Transducer decode does not pay Whisper's per-token autoregressive cost. On the official H200 jobs it is about **20× faster than Canary-Qwen** and **~16× faster than Whisper turbo**, at a WER that is still better than Whisper large-v3.
- **Most accurate local English:** speech-LLM hybrids (Granite 4.1, Canary-Qwen, Qwen3-ASR). They are 5–15× slower than Parakeet. NVIDIA's own chooser still says: *best English accuracy → Canary-Qwen 2.5B; very fast with almost SOTA → Parakeet TDT v2/v3* ([NeMo Speech docs](https://docs.nvidia.com/nemo/speech/nightly/starthere/choosing_a_model.html)).
- **Qwen3-ASR-1.7B** is the best *multilingual* quality pick that still sits near the English top. The 0.6B sibling is the vendor's throughput SKU.

## Chinese / CJK

English Open ASR is the wrong ranking for Mandarin. Whisper large-v3 is about **9.9% CER** on AISHELL-1 and **~20% CER** on FunASR's 184-file long-form Mandarin set. Dedicated Chinese models cut that in half or better.

| Model | Size | Mandarin quality | Speed | Languages | Notes |
| --- | --- | --- | --- | --- | --- |
| **FireRedASR2-LLM** | ~8B | Avg-Mandarin-4 **2.89% CER** | slower (LLM decode) | zh + 20+ dialects, EN, code-switch | Vendor claim: beats Doubao-ASR, Qwen3-ASR-1.7B, Fun-ASR-Nano on those sets |
| **FireRedASR2-AED** | ~1B+ | Avg-Mandarin-4 **3.05% CER** | faster than the LLM variant | same | Practical local SOTA. TensorRT-LLM: 12.7× vs PyTorch on AISHELL-1 (H20) |
| FireRedASR-AED-L (2025) | 1.1B | AISHELL-1 0.55 / Avg-4 3.18 | offline AED | zh dialects + EN | Older family; still strong |
| **Qwen3-ASR-1.7B** | 1.7B | FireRedASR2 paper: Mandarin-4 3.76, dialect-19 11.85 | 9–10× realtime on M5 Air (third-party MLX) | 52 langs/dialects | Best "one checkpoint" for dialects + many languages |
| **Fun-ASR-Nano** | 800M | FunASR long-form CER **8.06–8.20%** | **340×** with vLLM | zh/en/ja + dialects | GPU server, not a tiny model |
| **SenseVoice-Small** | 234M | FunASR long-form CER **7.81%**; AISHELL-era paper beats Whisper on zh/yue | **170× GPU, 17× CPU**; M4 Pro 27 min Chinese in 13.8 s | zh, en, ja, ko, yue + emotion/events | Fastest practical CJK local model |
| Paraformer-zh | 220M | FunASR long-form 10.18% CER | 120× GPU / 15× CPU | zh, en | Streaming sibling exists |
| Whisper large-v3 / turbo | 1.55B / 809M | FunASR long-form **20.0 / 21.7% CER** | 13× / 46× GPU | 99 | Do not use as the Chinese default |

Sources: [FireRedASR paper](https://arxiv.org/html/2501.14350v1), [FireRedASR2 README](https://huggingface.co/FireRedTeam/FireRedPunc/resolve/main/README.md?download=true) (family announcement), [FunASR GitHub benchmark](https://github.com/modelscope/FunASR), [FunASR vs Whisper blog](https://www.funasr.com/en/blog/funasr-vs-whisper-benchmark.html), [SenseVoice llama.cpp BENCHMARKS](https://github.com/FunAudioLLM/SenseVoice/blob/main/runtime/llama.cpp/BENCHMARKS.md), [Whisper Notes M4 Pro CJK bench](https://whispernotes.app/blog/sensevoice-fastest-cjk-transcription), [Qwen3-ASR GitHub](https://github.com/QwenLM/Qwen3-ASR).

Third-party Mac numbers (Whisper Notes, M4 Pro / M5 Air, not official):

- Parakeet v3: 5 min English in 2.91 s (**103×**). No Chinese.
- SenseVoice Small: 5 min English 5.8 s (52×); 27 min Chinese 13.83 s (**118×**).
- Whisper large-v3-turbo: 5 min English 20.9 s (14×); 27 min Chinese 2 min 4 s (13×).
- Qwen3-ASR 1.7B MLX 8-bit (M5 Air, FLEURS): **9.6×** realtime, 2.43 GiB peak. Wins vs turbo on Cantonese (6.4 vs 36.8), Hindi, Thai, Vietnamese, French, German, English; loses on Finnish/Hungarian/Greek and several European languages.

## Streaming and dictation

Offline RTFx is not live latency.

| Model | Latency knob | Languages | Local runtimes |
| --- | --- | --- | --- |
| **Nemotron 3.5 ASR Streaming 0.6B** | 80 / 160 / 320 / 560 / 1120 ms | 40 locales (zh-CN is "broad-coverage", not the top tier) | NeMo, CoreML, MLX, GGUF |
| Nemotron Speech Streaming EN 0.6B | same | English | same family |
| Parakeet TDT (chunked) | ~2 s chunks typical | 25 EU | NeMo streaming script, ONNX, MLX |
| Moonshine Streaming Tiny/Small/Medium | ~80 ms feed, ~107 ms on MacBook Pro for Medium (vendor) | English | Transformers, transcribe.cpp, iOS/Android packages |
| Qwen3-ASR | streaming via vLLM backend | 52 | official `qwen-asr[vllm]` |
| Paraformer-zh-streaming | ~600 ms chunk configs | zh, en | FunASR |

NVIDIA's chooser for realtime is Nemotron, not Parakeet ([docs](https://docs.nvidia.com/nemo/speech/nightly/starthere/choosing_a_model.html)). Mandarin streaming quality on Nemotron 3.5 is weaker than SenseVoice/FireRed/Qwen3 (FLEURS zh CER around 19–23% in the card's broad-coverage table). For Chinese live captions, prefer FunASR Paraformer streaming or Qwen3-ASR streaming.

## Apple Silicon and consumer hardware

| Stack | Models | Comment |
| --- | --- | --- |
| `parakeet-mlx` / sonic-speech MLX | Parakeet TDT v3 | M3 Max INT8: ~95×, ~1.3 GB peak, no WER drop vs BF16 on their LibriSpeech slice |
| FluidAudio CoreML | Parakeet TDT v3 | Fastest Mac dictation path in several app benches |
| mlx-whisper | Whisper turbo / large-v3 | Still the easiest 99-language path on Mac |
| FunASR / sherpa-onnx / llama.cpp FunASR | SenseVoice, Paraformer | SenseVoice q8 ~254 MB; CPU CER ~8% on FunASR's Mandarin set |
| Qwen3-ASR MLX 8-bit | 1.7B | ~2.5 GB download, ~2.4 GiB peak |
| mlx-audio | Granite Speech 4.1 2B | Official Granite card lists `mlx-audio` |
| llama.cpp | Granite Speech GGUF | `llama-cli -st -hf ibm-granite/granite-speech-4.1-2b-GGUF:Q8_0` |
| whisper.cpp / faster-whisper | Whisper family | Mature; lose on English speed vs Parakeet and on Chinese vs FunASR |
| NeMo-Speech.cpp | Parakeet GGUF q8 | NVIDIA's own C++ runtime |

VRAM-ish rule of thumb: Parakeet ~2 GB, SenseVoice <1 GB, Whisper turbo ~2–6 GB, Qwen3-ASR 1.7B ~3–6 GB fp16, Canary-Qwen 2.5B and Granite 2B need a comfortable 8 GB class GPU or unified memory.

## Model notes

### NVIDIA Parakeet TDT 0.6B v2 / v3

FastConformer encoder + Token-and-Duration Transducer. Punctuation, capitalization, word/segment timestamps, long-form (full attention up to ~24 min on A100 80GB; local attention up to ~3 h). v2 is English-only and slightly more accurate (6.05 vs 6.32). v3 adds 25 European languages with auto LID. No Chinese, Arabic, Korean, Thai, Hindi, etc.

### NVIDIA Canary-Qwen 2.5B

SALM: FastConformer encoder + frozen Qwen3-1.7B decoder + LoRA. English only for reliable ASR. Two modes: transcribe, or disable the speech adapter and use the LLM on the transcript. 418 RTFx. Trained on 234k hours.

### NVIDIA Canary-1B-v2

The AST model. FastConformer + Transformer decoder. 25 European languages, ASR and speech-to-text translation, RTFx 749, English Open ASR 7.15% (worse than Parakeet, faster than Whisper, and it *translates*). Paper: [arXiv:2509.14128](https://arxiv.org/abs/2509.14128).

### Qwen3-ASR 0.6B / 1.7B

Released Jan 2026, Apache 2.0, Transformers-native from Jun 2026 (`Qwen/Qwen3-ASR-*-hf`). Language ID, hotwords, timestamps via `Qwen3-ForcedAligner-0.6B`, singing/BGM robustness. 0.6B vendor claim: 92 ms TTFT, 2000× at concurrency 128. Paper: [arXiv:2601.21337](https://arxiv.org/abs/2601.21337).

### IBM Granite Speech 4.1 2B

Apache 2.0, Apr 2026. Dual-head CTC encoder + Granite 4.0 LLM. ASR + bidirectional AST. Keyword biasing, punctuation/truecasing. Variants: `-plus` (speaker-attributed ASR, word timestamps), `-nar` (non-autoregressive, higher throughput). Runs in transformers, vLLM, llama.cpp, mlx-audio.

### SenseVoice-Small / Fun-ASR-Nano / Paraformer

Alibaba FunAudioLLM / FunASR. SenseVoice is encoder-only CTC: one forward pass, emotion + audio events, five languages. Fun-ASR-Nano is an 800M LLM-ASR for zh/en/ja + dialects; use Fun-ASR-MLT-Nano for 31 languages. Toolkit is MIT; model licenses vary (SenseVoice Apache 2.0).

### FireRedASR / FireRedASR2

Xiaohongshu FireRed Team. Mandarin specialist. AED (~1B) for local deploy, LLM (~8B) for max accuracy. FireRedASR2 (early 2026) reports beating Qwen3-ASR-1.7B on Mandarin-4 and dialect-19. Apache 2.0.

### Moonshine / Moonshine Streaming

Useful Sensors. Tiny English models for CPU and phones. Streaming Medium (245M) matches Whisper large-v3 WER with 6× fewer parameters. MIT. Not a multilingual system.

### Whisper large-v3 / turbo / Distil-Whisper

Still the best *tooling* (whisper.cpp, faster-whisper, WhisperKit, mlx-whisper) and the only local model that credibly covers ~99 languages plus translation-to-English. Lose on English WER and throughput to Parakeet, and on Chinese CER to FunASR/FireRed/Qwen3.

## Practical pick for this repo

Bubble is a macOS overlay. If speech-to-text is added locally:

1. Default English / European: **Parakeet TDT 0.6B v3** through `parakeet-mlx` or FluidAudio.
2. Default Chinese: **SenseVoice-Small** (speed) with an optional upgrade path to **Qwen3-ASR 1.7B** (dialects) or **FireRedASR2-AED** (Mandarin accuracy).
3. Do not ship Whisper large-v3 as the only engine. Keep turbo only as the 99-language fallback.

## Sources

- Hugging Face Open ASR Leaderboard: https://huggingface.co/spaces/hf-audio/open_asr_leaderboard
- Leaderboard code / eval method (H200 jobs as of 24 Jul 2026): https://github.com/huggingface/open_asr_leaderboard
- Open ASR paper: https://arxiv.org/abs/2510.06961
- NVIDIA model chooser: https://docs.nvidia.com/nemo/speech/nightly/starthere/choosing_a_model.html
- nvidia/parakeet-tdt-0.6b-v2: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- nvidia/parakeet-tdt-0.6b-v3: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- nvidia/canary-qwen-2.5b: https://huggingface.co/nvidia/canary-qwen-2.5b
- Canary-1B-v2 & Parakeet-v3 report: https://arxiv.org/abs/2509.14128
- nvidia/nemotron-3.5-asr-streaming-0.6b: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- Qwen/Qwen3-ASR-1.7B and -hf: https://huggingface.co/Qwen/Qwen3-ASR-1.7B · https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf
- Qwen3-ASR paper: https://arxiv.org/abs/2601.21337
- ibm-granite/granite-speech-4.1-2b: https://huggingface.co/ibm-granite/granite-speech-4.1-2b
- FunASR: https://github.com/modelscope/FunASR
- SenseVoice: https://www.modelscope.cn/models/iic/sensevoicesmall
- FireRedASR: https://arxiv.org/abs/2501.14350 · https://github.com/FireRedTeam/FireRedASR
- Moonshine Streaming Medium: https://huggingface.co/moonshine-ai/moonshine-streaming-medium
- Useful Sensors announcement: https://huggingface.co/blog/UsefulSensors/announcing-moonshine-voice
