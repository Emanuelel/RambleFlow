# Third-party notices

RambleFlow’s optional timed speech recognition runs NVIDIA Parakeet through the local ASR sidecar from [Phonon by Infatoshi](https://github.com/Infatoshi/phonon). The tested sidecar comes from [Phonon v1.0.1](https://github.com/Infatoshi/phonon/releases/tag/v1.0.1), with [source at commit 5351cd2](https://github.com/Infatoshi/phonon/tree/5351cd29d7eece21f4168676fd262b0b469ea0f3) under the [GNU GPL version 3](https://github.com/Infatoshi/phonon/blob/5351cd29d7eece21f4168676fd262b0b469ea0f3/LICENSE).

The tested ASR weights are [MLX Community’s conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/tree/8ae155301e23d820d82aa60d24817c900e69e487) of [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), listed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

RambleFlow’s Literal192 refiner derives from [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B/blob/70d244cc86ccca08cf5af4e1e306ecf908b1ad5e/LICENSE) via [Unsloth’s GGUF conversion](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/tree/d7f544eead698dbd1f15126ef60b45a1e1933222). RambleFlow fine-tuned, merged and quantized the weights used in the fast setup. The upstream Qwen weights are licensed under Apache 2.0.

The app includes the [QVAC SDK](https://github.com/tetherto/qvac) and [Node.js](https://github.com/nodejs/node). Keep third-party license files accompanying the corresponding binaries and packages.
