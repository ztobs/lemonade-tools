# lemonade-tools

Shell scripts for running [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` on AMD Strix Halo with ROCm, using the [Lemonade SDK](https://github.com/remixer-dec/lemonade) binary builds for `gfx1151`.

**Key features:**
- Router mode — models auto-discover from `~/.lmstudio/models`, load on first API request, LRU eviction
- Per-model optimal parameters via `models-preset.ini`
- Speculative decoding (ngram, draft-eagle3, draft-mtp)
- One-command install/upgrade via `llm_install`

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
# Edit api-keys with your own keys (one per line, hex or sk-lm-* format)

# 4. Install the systemd user service
mkdir -p ~/.config/systemd/user/
cp llama-server.service ~/.config/systemd/user/

# 5. Add aliases to your .bashrc
cat >> ~/.bashrc << 'ALIASES'
alias llm_config='~/AI/llama-server/edit-model-config.sh'
alias llm_install='~/AI/llama-server/install-llama-server.sh'
alias llm_load='~/AI/llama-server/load-model-interactive.sh'
alias llm_logs='journalctl --user -u llama-server.service -f'
alias llm_params='~/AI/llama-server/set-optimal-params.sh'
alias llm_restart='systemctl --user restart llama-server.service && echo "llama-server restarted"'
alias llm_start='systemctl --user start llama-server.service && echo "llama-server started"'
alias llm_status='~/AI/llama-server/model-status.sh'
alias llm_stop='systemctl --user stop llama-server.service && echo "llama-server stopped"'
alias llm_unload='~/AI/llama-server/unload-models.sh'
ALIASES
source ~/.bashrc

# 6. Enable and start the service
systemctl --user enable llama-server
llm_start

# 7. Place GGUF models in ~/.lmstudio/models/
#    The server auto-discovers them. No config needed to get started.
```

## Commands

| Alias | What it does |
|---|---|
| `llm_start` | Start the server |
| `llm_stop` | Stop the server |
| `llm_restart` | Restart the server |
| `llm_status` | Show loaded models and slot state |
| `llm_logs` | Tail server logs |
| `llm_load` | Interactively load a model |
| `llm_unload` | Evict all loaded models |
| `llm_config` | Edit `models-preset.ini` (add/configure models) |
| `llm_params` | Set optimal parameters for a model |
| `llm_install` | Download/upgrade the binary |

## Key files

```
~/AI/llama-server/
├── bin/llama-server          # Binary + ROCm libs (ignored by git, use llm_install)
├── install-llama-server.sh   # Downloads Lemonade release tarball
├── edit-model-config.sh      # Interactive ini editor for models-preset.ini
├── load-model-interactive.sh # Load model into slot, sets ctx_size auto
├── unload-models.sh          # POST /slots/{id}?action=unload
├── model-status.sh           # Parses llama-server logs for slot state
├── set-optimal-params.sh     # Sets cache_type, n_gpu_layers, etc. per model
├── models-preset.ini         # Per-model configuration (see below)
├── api-keys.example          # Template — copy to api-keys with your keys
└── llama-server.service      # systemd user unit
```

## models-preset.ini

Each model gets a `[section]` matched by filename prefix (stem match). Model-level settings override the `[*]` defaults.

Supported keys per model:
```
ctx-size          # context window (default: auto-detect)
n-gpu-layers      # layers offloaded to GPU (default: max)
flash-attn        # on / off (default: on)
cache-type         # q8_0 / q4_0 / f16 (default: q8_0)
defrag-thold       # defrag threshold (default: 0.1)
batch-size         # ubatch size (default: 2048)
gpu-cache-size     # GPU cache percentage (default: 0.90)
spec-type          # Speculative decoding: none, ngram-simple, ngram-complex,
                   #   draft-simple, draft-complex, draft-mtp, draft-eagle3, lookahead
spec-draft-n-max   # Max draft tokens per step (default: 16)
draft-p-min        # Min acceptance probability (default: 0.75)
model-draft        # Path to draft GGUF (required for draft-eagle3/draft-simple)
mmproj             # Path to multimodal projector GGUF
```

### Speculative decoding

`ngram-simple` is the default (`[*]` section). It works with every model with zero setup.

For faster draft-based decoding, you need a draft GGUF file. **EAGLE3** gives the best speedup (70-85% acceptance rate) for models that have one available:

```bash
llm_config          # select your model, option 6
# Choose: draft-eagle3
# Paste the draft model URL when prompted
```

The script downloads the draft to `~/.lmstudio/models/draft/` and sets `model-draft` in your config automatically.

### MTP (Multi-Token Prediction)

Some models (Qwopus, DeepSeek-V4) have built-in MTP heads. Use `draft-mtp` instead of a separate draft file:

```
spec-type = draft-mtp
spec-draft-n-max = 1
```

## Upgrading

```bash
llm_stop
llm_install          # downloads latest Lemonade release
llm_start
llm_status           # verify
```

## API endpoint

`http://0.0.0.0:1234/v1` — OpenAI-compatible endpoint.

Auth: send your API key as a Bearer token or in the `Authorization` header.

## Troubleshooting

**Model won't load (unknown architecture):**
The model uses an architecture not yet in the Lemonade build. Check if upstream llama.cpp has merged the PR. DeepSeek-V4 (`deepseek4`) is a known case — waiting on PR #24162.

**OOM / server crashes:**
Run `llm_load` and pick a smaller context size, or unload other models first with `llm_unload`.

**Draft model doesn't speed things up:**
Check `draft-p-min` — if acceptance rate is low, the draft model might not match the main model's tokenizer distribution. Also verify `spec-draft-n-max` isn't set too high.

## License

MIT — do whatever you want.
