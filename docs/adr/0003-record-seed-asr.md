# Record captions stream through Seed ASR when credentials exist

Record already had a transcriber protocol so the capture path could stay put while the recognizer changed. Apple Speech stays the local fallback. When `~/.bubble/record.json` or `ARK_API_KEY` / `VOLC_ASR_API_KEY` is present, Record streams 16 kHz PCM live to Doubao Seed ASR 2.0 (`volc.seedasr.sauc.duration`) and uses definite/indefinite utterances as live captions. We rejected file-after-stop REST: that would drop the live card, and Agent Plan Small already bills by audio hours either way.
