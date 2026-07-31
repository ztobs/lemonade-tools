# lemonade-tools

Shell scripts for running [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` on AMD Strix Halo with ROCm, using the [Lemonade SDK](https://github.com/remixer-dec/lemonade) binary builds for `gfx1151`.

**Key features:**
- Router mode — models auto-discover from `~/.lmstudio/models`, load on first API request, LRU eviction
- Per-model configuration via `models-preset.ini`
- Speculative decoding (ngram, draft-mtp, draft-eagle3, draft-simple)
- One-command install/upgrade via `llm_install`
- Auto-detect mmproj (vision) files in model directories
- API key management
- systemd user service for persistent background operation

## Hardware requirements

- AMD Strix Halo APU (gfx1151) or other AMD GPU with ROCm support
- 128 GB unified memory (recommended)

For Strix Halo you also need this kernel boot parameter so the GPU can see system RAM as VRAM:

```
amdgpu.gttsize=131072
```

This gives llama-server ~120 GB of "VRAM" via the GTT aperture.

## Quick start (new system)

```bash
# 1. Clone
git clone https://github.com/YOUR_USER/lemonade-tools.git ~/AI/llama-server
cd ~/AI/llama-server

# 2. Install the binary + ROCm libraries (~2.5 GB)
./install-llama-server.sh

# 3. Create your API key
cp api-keys.example api-keys
# Edit api-keys with your own keys (one per line)

# 4. Install the systemd user service
mkdir -p ~/.config/systemd/user/
cp llama-server.service ~/.config/systemd/user/
systemctl --user daemon-reload

# 5. Add aliases to your .bashrc (or source them from this repo)
# See "Shell aliases" section below

# 6. Enable and start the service
systemctl --user enable llama-server
llm_start

# 7. Place GGUF models in ~/.lmstudio/models/
#    The server auto-discovers them. No config needed to get started.
```

## Shell aliases

These live in `~/.bashrc` and are the canonical way to interact with the LLM stack:

| Alias | Command | Purpose |
|---|---|---|
| `llm_start` | `systemctl --user start llama-server.service` | Start the server |
| `llm_stop` | `systemctl --user stop llama-server.service` | Stop the server |
| `llm_restart` | `systemctl --user restart llama-server.service` | Restart the server |
| `llm_status` | `~/AI/llama-server/model-status.sh` | Show loaded models / slot state |
| `llm_logs` | `journalctl --user -u llama-server.service -f` | Tail server logs |
| `llm_install` | `~/AI/llama-server/install-llama-server.sh` | Download / upgrade the binary |
| `llm_load` | `~/AI/llama-server/load-model-interactive.sh` | Interactively load a model |
| `llm_unload` | `~/AI/llama-server/unload-models.sh` | Evict loaded models |
| `llm_config` | `~/AI/llama-server/edit-model-config.sh` | Create/edit model configs |
| `llm_params` | `~/AI/llama-server/set-optimal-params.sh` | Set per-model inference params |

## Architecture overview

This repo contains only the scripts and configs. The full LLM stack spans several locations:

| Component | Location |
|---|---|
| **Scripts & config** | `~/AI/llama-server/` (this repo) |
| **Binary + ROCm libs** | `~/AI/llama-server/bin/` (downloaded by `llm_install`, gitignored) |
| **Shell aliases** | `~/.bashrc` (lines 53–62) |
| **systemd service** | `~/.config/systemd/user/llama-server.service` |
| **Model files** | `~/.lmstudio/models/` (GGUFs) |
| **mmproj (vision)** | `~/.lmstudio/models/mmproj/` |
| **Draft models** | `~/.lmstudio/models/draft/` |
| **API endpoint** | `http://0.0.0.0:1234/v1` |

### systemd service

```ini
[Unit]
Description=llama-server (Lemonade ROCm gfx1151) — router mode

[Service]
Environment=HSA_OVERRIDE_GFX_VERSION=11.5.1
Environment=ROCBLAS_USE_HIPBLASLT=1
Environment=RADV_PERFTEST=bfloat16
Environment=LD_LIBRARY_PATH=%h/AI/llama-server/bin
Environment=GGML_CUDA_ENABLE_UNIFIED_MEMORY=1
ExecStart=%h/AI/llama-server/bin/llama-server
    --models-dir %h/.lmstudio/models
    --models-preset %h/AI/llama-server/models-preset.ini
    --models-max 1
    --host 0.0.0.0 --port 1234
    -fa on --no-mmap
    --api-key-file %h/AI/llama-server/api-keys
    --jinja --log-file %h/AI/llama-server/llama-server.log
Restart=on-failure
```

Key details:
- Runs as a **user** service (`systemctl --user`), no sudo needed
- Router mode: no `-m` flag, all GGUFs in `--models-dir` are auto-discovered
- `--models-max 1` keeps one model hot at a time; LRU eviction on switch
- `HSA_OVERRIDE_GFX_VERSION=11.5.1` is critical for Strix Halo ROCm support
- Logs go to both journald (`llm_logs`) and `llama-server.log`

## Repository files

```
~/AI/llama-server/
├── bin/llama-server          # Binary + ROCm libs (gitignored, use llm_install)
├── install-llama-server.sh   # Downloads Lemonade release tarball
├── edit-model-config.sh      # Interactive ini editor (create/edit model configs)
├── load-model-interactive.sh # Load a model into a slot
├── unload-models.sh          # Evict all loaded models
├── model-status.sh           # Show loaded models and slot state
├── set-optimal-params.sh     # Apply inference parameter presets
├── models-preset.ini         # Per-model configuration
├── api-keys.example          # Template — copy to api-keys with your keys
├── api-keys                  # Active keys (gitignored)
├── llama-server.service      # systemd user unit (copy to ~/.config/systemd/user/)
├── llama-server.log          # Runtime log (gitignored)
└── README.md
```

## models-preset.ini

Each model gets a `[section]` matched by GGUF filename. Model-level settings override the `[*]` global defaults.

### Global defaults (`[*]`)

```ini
[*]
threads = 4
batch-size = 512
ubatch-size = 512
cache-type-k = q8_0
cache-type-v = q8_0
cache-reuse = 256
spec-type = ngram-simple
```

### Per-model keys

```
model                # Full path to GGUF file
ctx-size             # Context window size
n-gpu-layers         # Layers offloaded to GPU (999 = all)
parallel             # Number of parallel slots
batch-size           # Prompt batch size
ubatch-size          # Decode batch size
cache-type-k         # KV cache type for K (q8_0, q4_0, f16)
cache-type-v         # KV cache type for V
temperature          # Sampling temperature
top-k                # Top-K sampling
top-p                # Top-P (nucleus) sampling
min-p                # Min-P sampling
presence-penalty     # Presence penalty
repeat-penalty       # Repeat penalty
reasoning            # Thinking mode: off, on, auto
reasoning-budget     # Token budget for reasoning (-1 = unlimited)
chat-template-kwargs # Jinja template arguments (JSON)
mmproj               # Path to multimodal projector GGUF (vision models)
spec-type            # Speculative decoding type
spec-draft-n-max     # Max draft tokens per step (default: 16)
draft-p-min          # Min acceptance probability (default: 0.75)
model-draft          # Path to draft GGUF (required for eagle3/simple)
```

## Speculative decoding

| Spec Type | Needs draft model? | Notes |
|---|---|---|
| `ngram-simple` | No | Works on any model, zero setup |
| `ngram-map-k` | No | ngram variant |
| `ngram-map-k4v` | No | ngram variant |
| `ngram-mod` | No | ngram variant |
| `ngram-cache` | No | ngram variant |
| `draft-mtp` | No (uses built-in heads) | Qwen3.6/Qwopus, Gemma4, Step3.5+, GLM-4.5+, Hy3 |
| `draft-eagle3` | **Yes** | EAGLE3 head draft model (best quality) |
| `draft-simple` | **Yes** | Small standalone draft model |

**WARNING**: `draft-mtp` will crash the server if the model lacks MTP heads. Only enable it on known MTP-capable models.

### Setting up draft-eagle3

```bash
llm_config          # select model → option 6 (Speculative Decoding)
# Choose: draft-eagle3
# Enter draft model URL when prompted (downloads to ~/.lmstudio/models/draft/)
```

The script auto-downloads and configures the draft model.

## mmproj (Vision / multimodal)

Vision models often ship with a `mmproj-F32.gguf` in the same directory. When creating a new config via `llm_config`, the script auto-detects this and offers to use it.

Manual setup options:
- **URL download** — paste a download URL, saved to `~/.lmstudio/models/mmproj/`
- **Absolute path** — enter any filesystem path to an existing mmproj GGUF
- **Pick existing** — select from previously downloaded mmproj files

## Upgrading

```bash
llm_stop
llm_install          # downloads latest Lemonade release
llm_start
llm_status           # verify version and health
```

The `install-llama-server.sh` script has `RELEASE_TAG` pinned to a specific build. To upgrade to a newer release, update that variable first.

## API endpoint

`http://0.0.0.0:1234/v1` — OpenAI-compatible endpoint.

Auth: send your API key as a Bearer token in the `Authorization` header.

## Troubleshooting

**Model won't load (unknown architecture):**
The model uses an architecture not yet in the Lemonade build. Check the [Lemonade releases](https://github.com/lemonade-sdk/llamacpp-rocm/releases) for the latest build, and verify that upstream [llama.cpp](https://github.com/ggml-org/llama.cpp) has merged support for your model's architecture.

**OOM / server crashes:**
Run `llm_load` and pick a smaller context size, or unload other models first with `llm_unload`. Reduce `batch-size` and `ubatch-size` in `models-preset.ini`.

**Draft model doesn't speed things up:**
Check `draft-p-min` — if acceptance rate is low, the draft model might not match the main model's tokenizer distribution. Also verify `spec-draft-n-max` isn't too high.

**Service won't start after binary upgrade:**
Run `llm_logs` to check for errors. Common causes: wrong `HSA_OVERRIDE_GFX_VERSION`, missing ROCm libs in `LD_LIBRARY_PATH`, or incompatible binary architecture.

## License

MIT — do whatever you want.
