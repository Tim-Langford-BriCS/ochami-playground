# Appendix G — choosing a model to test with

*(Reference and argument. Nothing here is a step. §14 already picks a model and works; this is why that one, what the alternatives cost, and what changes when the PTR has accelerators. Surveyed 10 Aug 2026.)*

The model is the smallest decision in this tutorial and the easiest to get wrong in an expensive direction. Choose a gated one and you have inherited a secret to manage; choose one sized for a GPU and it will not load on a CPU node; choose one that vLLM does not recognise and the pod will not start at all. None of those failures look like a model problem when you hit them.

🛑 **The single most useful thing on this page.** On CPU, and on 30 GB nodes, **the model is not the constraint — the vLLM container image is.** Every model in the "small" table below fits in about a gigabyte, while the vLLM CPU image is several times that. So "the disk is tight" is never solved by dropping from 0.5 B to 135 M. It is solved by a bigger flavor, or by pruning images ([DL-005](DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal)). Choosing a smaller model to save space costs you the demo and fixes nothing.

## The five things to check before choosing

In the order that they will bite you:

| # | Check | Why, and how to check it |
|---|---|---|
| 1 | **Gated or open?** | A gated repo needs a Hugging Face token, which needs a Kubernetes Secret, which needs SOPS (§12.4). This is the difference between a one-line change and an afternoon. Anything from Meta or Google is gated; Qwen and SmolLM2 are Apache 2.0 |
| 2 | **Does vLLM know the architecture?** | `curl -s https://huggingface.co/<repo>/raw/main/config.json` and read `architectures`. If it is `LlamaForCausalLM`, `Qwen2ForCausalLM` or `Qwen3ForCausalLM`, vLLM has supported it for a long time. An unrecognised architecture fails at load with `ValueError`, not with anything about models |
| 3 | **Does it have a chat template?** | Without one, `/v1/chat/completions` will not work — only `/v1/completions`. Base models (no `-Instruct`/`-it` suffix) generally lack one, which is why §14's smoke test would return an error rather than a reply |
| 4 | **Will the weights plus the KV cache fit?** | See the arithmetic below. The weights are the number people quote; the KV cache is the one that surprises them, because it scales with context length and with how many requests you serve at once |
| 5 | **Context length** | `max_position_embeddings`. Long contexts are the main way a small model runs you out of memory — and vLLM will reserve cache for the full context unless you cap it with `--max-model-len` |

## Memory arithmetic, both backends

**Weights.** `bytes ≈ params × bytes-per-parameter`. BF16 and FP16 are 2 bytes; FP32 is 4; 8-bit quantisation is 1; 4-bit is ~0.5 plus overhead. So a 0.5 B model at BF16 is ~1 GB, and the same model in FP32 is ~2 GB — which matters, because **not every CPU does BF16 well** and falling back to FP32 doubles the figure.

**KV cache**, per token, per request:

```
bytes ≈ 2 × num_hidden_layers × num_key_value_heads × (hidden_size / num_attention_heads) × bytes_per_element
```

The `2` is one each for keys and values. Note it uses `num_key_value_heads`, **not** `num_attention_heads` — every model in the table below uses grouped-query attention, which is precisely an optimisation to shrink this number. For SmolLM2-360M that works out at about 20 KB per 1000 tokens per request: negligible. For an 8 B model at 32 K context it is gigabytes, and it is the reason a model whose weights "fit" still fails to serve.

⚠ **On CPU the KV cache comes out of system RAM, and vLLM pre-allocates it.** There is no separate VRAM budget to run out of — vLLM takes a block of RAM up front, so an over-generous `--max-model-len` shows up as the pod being OOM-killed at startup rather than as a slow response later.

## Candidates, smallest first

Verified from each repository's `config.json` on **10 Aug 2026**. "Weights" is the BF16 figure.

| Model | Params | Weights | Licence / gated | Architecture | Context | Verdict for this tutorial |
|---|---|---|---|---|---|---|
| `HuggingFaceTB/SmolLM2-135M-Instruct` | 135 M | ~270 MB | Apache 2.0, open | `LlamaForCausalLM` | 8 192 | **Plumbing only.** 30 layers × 576 hidden. Fastest thing that will answer at all, and its answers frequently fail to cohere. Use it to prove KServe → vLLM → HTTP, never to demo |
| `HuggingFaceTB/SmolLM2-360M-Instruct` | 360 M | ~720 MB | Apache 2.0, open | `LlamaForCausalLM` | 8 192 | **The useful floor.** 32 layers × 960 hidden, 15 heads over 5 KV heads. Summarises and chats; weak at reasoning. The right choice if 0.5 B feels slow |
| **`Qwen/Qwen2.5-0.5B-Instruct`** | 0.5 B | ~1 GB | Apache 2.0, open | `Qwen2ForCausalLM` | 32 768 | **What §14 uses, and the recommendation.** Smallest size that reliably holds a conversation. Cap the context with `--max-model-len` — the 32 K default is far more cache than a POC needs |
| `Qwen/Qwen3-0.6B` | 0.6 B | ~1.2 GB | Apache 2.0, open | `Qwen3ForCausalLM` | **40 960** | Newer and a little better. Two cautions: the long default context wants capping even more firmly, and `Qwen3ForCausalLM` needs a reasonably recent vLLM — check the runtime image before swapping |
| `microsoft/Phi-4-mini-instruct` | ~3.8 B | ~7.6 GB | MIT, open | — | — | The largest thing worth attempting on CPU. Verify the figures before relying on them; not checked on 10 Aug 2026 |
| `google/gemma-3-1b-it` | 1 B | ~2 GB | **gated** — licence acceptance | — | — | The design slide's suggestion. Costs you §12.4's SOPS work for a model barely better than Qwen 0.5 B on CPU |
| `meta-llama/Llama-3.2-1B-Instruct` | 1 B | ~2 GB | **gated** — licence acceptance | — | — | as above |
| `meta-llama/Meta-Llama-3-8B-Instruct` | 8 B | ~16 GB | **gated** | — | — | GPU territory. Will not fit a 30 GB node alongside the vLLM image, and would be painfully slow on CPU if it did |

📌 **The gated column is the one that changes your workload, not the size column.** Swapping between any two *open* models is one line of `storageUri`. Swapping to a gated one means a Hugging Face account, accepting a licence, minting a token, encrypting it with SOPS, and committing it — a genuinely different piece of work, and one §12.4 exists to make possible rather than easy.

## CPU versus GPU — what actually differs

This tutorial runs on CPU because the Digital Labs flavors have no accelerator (DL-001's substrate). The PTR will have accelerators, so it is worth being clear about which of §14's choices are CPU artefacts and which carry over.

| | CPU (here) | GPU (the PTR) |
|---|---|---|
| **vLLM backend** | the CPU backend, which vLLM's own documentation describes as for prototyping and **not optimised**. Supports FP32, BF16, FP16 | the CUDA/ROCm path, which is what vLLM is actually built for |
| **Where the KV cache lives** | system RAM, pre-allocated. Competes with everything else on the node | VRAM, and the binding constraint. `--gpu-memory-utilization` becomes the knob that matters |
| **Realistic model size** | up to ~1 B comfortable, ~4 B painful | 8 B trivially; 70 B with tensor parallelism across cards |
| **Throughput** | single-digit to low-tens of tokens/sec. Fine for one person chatting, hopeless for benchmarking | orders of magnitude more, and batching starts to pay |
| **Quantisation** | limited and often not faster — dequantisation costs CPU cycles you do not have spare | AWQ/GPTQ/FP8 well supported and usually a straight win |
| **What §16 has to add** | nothing | device plugins, `nvidia.com/gpu` resources, node labels and taints, a Talos system extension for the driver, and a `ServingRuntime` per accelerator family |
| **Carries over unchanged** | the `InferenceService`, the model choice, the `storageUri`, the Flux plumbing, the OpenAI-compatible endpoint | — |

✅ **The reassuring part: almost everything transfers.** The `ServingRuntime` is the one object that is genuinely CPU-shaped, and §14 has you write it by hand precisely so that writing a GPU one in §16 is a known exercise rather than a new one. The model, the `InferenceService` and the endpoint are identical.

⚠ **Do not size the PTR from this tutorial's numbers.** A CPU POC tells you the *plumbing* works. It tells you nothing useful about tokens per second, batching behaviour, or how much VRAM a real model wants — and a benchmark taken here would be actively misleading if anyone quoted it later.

## Choosing by purpose

| If you are trying to… | Use | Because |
|---|---|---|
| prove the chain works at all | `SmolLM2-135M-Instruct` | loads in seconds; failures are unambiguous rather than slow |
| **follow §14 as written** | `Qwen2.5-0.5B-Instruct` | already tested, ungated, coherent |
| show someone a chatbot | `Qwen2.5-0.5B-Instruct`, or `Qwen3-0.6B` | the smallest that will not embarrass you |
| test the secret-management path | any gated 1 B model | the point is exercising §12.4's SOPS work, not the model |
| benchmark anything | **none of these, and not on this substrate** | see the warning above |

## Open questions

1. **How large is the vLLM CPU image really?** The number that decides DL-005, and nobody has measured it. It arrives for free the first time §14 pulls.
2. **What accelerators does the PTR have?** Governs §16's device plugin, the Talos extension, and how much of this page survives contact. Not yet known to us.
3. **Is a 0.5 B chatbot the agreed target for step −1?** Recorded in DL-005 as a question for the project. It satisfies "an endpoint you can talk to", which is what step −1 promised.

## Related

- [§14 — vLLM inference](14-vllm-inference.md) — the section this appendix backs, including the `ServingRuntime`
- [§16 — heterogeneous hardware](16-heterogeneous-hardware.md) — labels, taints, and where accelerators enter
- [DL-005](DECISION-LOG.md#dl-005--is-30-gb-of-node-disk-enough-for-the-inference-goal) — whether 30 GB nodes can hold the goal
- [vLLM issue #14576](https://github.com/vllm-project/vllm/issues/14576) — a vLLM maintainer confirming SmolLM2 needs no special support, being `LlamaForCausalLM`
