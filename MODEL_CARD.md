# RambleFlow cleanup model (Broad1291 + Literal192, Q4)

The text cleanup model RambleFlow runs after speech recognition. It turns a raw dictation transcript into clean text: punctuation, capitalization and false starts are fixed, and the words and meaning are kept.

| | |
| --- | --- |
| File | `literal192-q4.gguf`, attached to the [v0.1.0 release](https://github.com/Emanuelel/RambleFlow/releases/tag/v0.1.0) and on [Hugging Face](https://huggingface.co/0xemanuelel/rambleflow-cleanup-1.7b-gguf) |
| SHA-256 | `5f04f1d6366d58cd42f6da32832f64735c5cba3f04205adca22d573221f135c3` |
| Size | 1,054,423,616 bytes |
| Base model | [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B), via [Unsloth's GGUF conversion](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/tree/d7f544eead698dbd1f15126ef60b45a1e1933222) |
| License | Apache 2.0, inherited from Qwen3. The [license text](https://huggingface.co/Qwen/Qwen3-1.7B/blob/70d244cc86ccca08cf5af4e1e306ecf908b1ad5e/LICENSE) is attached to the release. |
| Changes from the base | Fine-tuned with two LoRA adapters, merged into the weights, and quantized to 4 bits |
| Runtime | llama.cpp through the [QVAC SDK](https://github.com/tetherto/qvac), on the Mac |
| Language | English |

## Intended use

Cleaning up English dictation inside RambleFlow, on the user's Mac. It follows four writing modes chosen by the app: minimal, casual, formal and prompt. It is not a chat assistant and is not meant to answer questions or follow instructions found in the dictated text.

## How it was made

Two LoRA training runs, each rank 16, alpha 32, one epoch, peak learning rate 1e-5 with a cosine schedule, 768-token context. Training ran locally with the QVAC SDK on an Apple silicon Mac mini.

1. **Broad1291**, 1,291 conversations: 336 control examples kept from earlier runs, 803 reviewed synthetic dictation situations, 128 longer messages curated from the public [Sotto transcript cleanup dataset](https://huggingface.co/datasets/juanquivilla/sotto-transcript-cleanup/tree/183cc8fd58532f13fa192980185214de1bcd5acc) (MIT), and 24 authored examples where clean input must stay unchanged. This adapter was merged into the base weights.
2. **Literal192**, 192 conversations on top of that: synthetic examples focused on keeping exact details (names, numbers, corrections, negations) while cleaning. This adapter was merged too, and the result was quantized to 4 bits.

**Training data:** synthetic text written for this project and reviewed before use, the public Sotto examples, and some of the author's own English dictation, recorded with an Italian accent. RambleFlow never collects its users' recordings or transcripts: dictation stays on the Mac.

**Attribution:** some of the earlier control examples may derive from [phonon-synthetic-tts](https://huggingface.co/datasets/Infatoshi/phonon-synthetic-tts/tree/6be46a8affae311b09d052157596b2db7a4488ec) by Elliot Arledge (Infatoshi), whose labels and metadata are licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); they were transformed into chat training pairs. The Sotto examples are by juanquivilla under the MIT license.

## Evaluation

Measured during development, not on a held-out public benchmark:

- On 40 fixed transcripts the 4-bit file gave the same output as the unquantized model on 37. The other three differed only in a contraction or punctuation. Median cleanup time fell from 569 ms to 308 ms on an Apple silicon Mac.
- In blind comparisons on 648 development cases, the full-precision Literal192 model made a similar number of meaning-changing errors to the earlier versions and to the reference cleanup model it was compared with. It made more errors on long messages with many exact details.

## Limitations

- English only. Other languages have not been tested.
- It can occasionally drop or change a detail: a number, a location, a correction the speaker made. RambleFlow keeps the raw transcript and falls back to it when the output looks wrong, but it cannot catch every case.
- Very long or unusual inputs can make it stop early; RambleFlow then inserts the raw transcript.
- The 4-bit file has not been through the same full quality evaluation as the full-precision model.
