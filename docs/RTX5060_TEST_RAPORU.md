# RTX 5060 Laptop 8 GB (`sm_120`) Kök Neden ve Test Raporu / Root Cause & Test Report (TR + EN)

**Donanım / Hardware:** NVIDIA GeForce RTX 5060 Laptop GPU (8 GB / 8151 MiB VRAM, Blackwell, compute capability `12.0` / `sm_120`), Windows 11 x64.  
**Tarih / Date:** 2026-11-20  
**Taban / Base:** `stable-diffusion.cpp` `32d516c` (`master-1088`), `ggml` `d803c238`, `patches/SERIES.txt` (24 yama / 24 patches), NVIDIA CUDA Toolkit 12.8.1.

---

## 1. Sorun ve Kök Neden / Issue & Root Cause

### Türkçe
- Upstream `engine/bin` ikilisi (`v0.1.0`) RTX 5060 Laptop (`sm_120`) üzerinde metinden **5 / 22 / 39 kare** videoları düzgün üretirken, **56 kare ve üstünde** (ve `--init-img` ile **22 / 39 karede**) DiT örneklemesi sonrası latent tensörünün ~%97'si `NaN` dönerek tamamen siyah video (`gurultu=0`, `orta_akis=0`) üretiyordu.
- **Elenen hipotezler** (56 karede eski `engine/bin` ile denendi, hepsi siyah/NaN):
  - `--flash-attn off` ve `--diffusion-fa`
  - `minimax_h3_attn_chunk_budget`: `0`, `0.05`, `1.0`
  - `SD_QKV_CHUNK_MB` / `SD_MLP_CHUNK_MB`: `1024` MB
  - İki aşamalı VAE (`VT_IKI_ASAMA=1`)
  - `GGML_CUDA_FORCE_CUBLAS`, `GGML_CUDA_FORCE_MMQ`, `GGML_CUDA_DISABLE_GRAPHS`
  - BF16 tensörleri F32'ye çevrilmiş DiT kopyası
  - `--max-vram 3.5` (4 GB kart taklidi) ve farklı `--seed` değerleri
- **Kök neden (`cuobjdump` doğrulaması):** Eski `engine/bin/ggml-cuda.dll` dosyası yalnızca `sm_61` ELF ve `compute_61` PTX içeriyordu (yerel `sm_120` kodu yoktu). RTX 5060 sürücüsü `compute_61` PTX'i çalışma zamanında JIT derlerken kısa dizilerde (40×24×12 latent, 39 kare) sorun çıkarmasa da daha uzun dizilerde (40×24×17 latent, 56+ kare veya `--init-img` ek yükü) sayısal taşma/`NaN` üretiyordu.
- **Çözüm:** Motorun CUDA 12.8.1 ve `CMAKE_CUDA_ARCHITECTURES=120` ile yerel `sm_120` olarak `engine/bin_sm120/` altına derlenmesi (`docs/RTX5060_SM120_DERLEME.md`).
- **Not (upstream v0.1.1):** Upstream `v0.1.1` sürümünde Turing/Ada (`sm_75`–`sm_89`) siyah video sorunu için `GGML_CUDA_CUBLAS_COMPUTE_TYPE=f32` eklendi. Blackwell (`sm_120`) kartlarda ise yerel `sm_120` derlemesi hem `NaN` sorununu kökünden çözer hem de tam Blackwell hızını (209 kare ≈ 6 dk) sağlar.

### English
- On an RTX 5060 Laptop GPU (`sm_120`, 8 GB), the upstream `engine/bin` (`v0.1.0`) produced valid text-to-video clips at **5 / 22 / 39 frames**, but produced solid black video (`gurultu=0`, `orta_akis=0`; ~97% `NaN` in DiT latents) at **56+ frames** and at **22 / 39 frames with `--init-img`**.
- **Eliminated hypotheses** (all tested at 56 frames on the `sm_61`-only binary, all yielded black/NaN): `--flash-attn off` / `--diffusion-fa`, `attn_chunk_budget` (`0`, `0.05`, `1.0`), 1024 MB QKV/MLP chunks, two-stage VAE, `GGML_CUDA_FORCE_CUBLAS` / `FORCE_MMQ` / `DISABLE_GRAPHS`, BF16→F32 DiT weights, `--max-vram 3.5`, and alternate seeds.
- **Root cause (`cuobjdump` verified):** The upstream `engine/bin/ggml-cuda.dll` contained only `sm_61` ELF and `compute_61` PTX (no native `sm_120` code). Driver JIT compilation of `compute_61` PTX on Blackwell (`sm_120`) worked for short sequences (40×24×12 latent) but produced `NaN` on longer sequences (40×24×17+ latent or with `--init-img`).
- **Fix:** Building `sd-cli` natively with CUDA 12.8.1 and `CMAKE_CUDA_ARCHITECTURES=120` into `engine/bin_sm120/` (see `docs/RTX5060_SM120_DERLEME.md`).

---

## 2. Kabul Ölçümleri / Acceptance Measurements (`engine/bin_sm120`)

Tüm koşular 640×384, 24 fps, 6 adım, `cfg=1.0`, karosuz VAE, varsayılan kalite kapısı (`scripts/uretim_kapi.ps1`) ile çalıştırıldı / All runs at 640×384, 24 fps, 6 steps, `cfg=1.0`, non-tiled VAE, default quality gate:

| Koşu / Run | Kare / Frames | Mod / Mode | Süre / Duration | Tepe VRAM / Peak VRAM | Gürültü / Noise (≤1.5) | Orta Akış / Flow (>0.05) | Sonuç / Gate |
|---|---:|---|---:|---|---:|---:|---|
| `k39` | 39 (1.6 s) | Metinden / T2V (referans) | 114 s | — | 0.70 | 1.42 | **KAPI GECTI** |
| `k39_init` | 39 (1.6 s) | `--init-img` (I2V) | 208 s | — | 0.47 | 1.43 | **KAPI GECTI** |
| `k56` | 56 (2.3 s) | Metinden / T2V | 117 s | — | 1.10 | 1.70 | **KAPI GECTI** |
| `k209` | 209 (8.7 s) | Metinden / T2V (2 aşama) | 356 s (~5.9 dk) | **7438 / 8151 MiB** | 1.02 | 1.40 | **KAPI GECTI** |
| MCP `56` | 56 (2.3 s) | MCP T2V | ~120 s | — | 0.91 | 1.64 | **KAPI GECTI** |
| MCP `192+init` (×8) | 192 (8.0 s) | MCP `--init-img` (2 aşama) | **~6.3–7.0 dk** | < 8151 MiB | 0.51–0.82 | 0.57–5.27 | **8/8 KAPI GECTI** |

**39 kare görsel tutarlılık / 39-frame visual parity (`bin_sm120` vs `bin`):** Aynı istem ve tohumda aynı sahne üretildi (PSNR `23.26 dB`, MAE `9.64 / 255`; farklı mimari kayan nokta yuvarlaması beklendiği gibidir).

---

## 3. `runs/olaylar.txt` Kayıt Satırları / Gate Log Excerpts

Yollar nötr `<ROOT>` yer tutucusuyla temizlenmiştir / Paths sanitized with `<ROOT>`:

```text
# Eski sm_61 ikilisi (RTX 5060'ta siyah / NaN ornekleri):
17:05:34 | KAPI GECTI: kare=39 gurultu=0.69 orta_akis=1.66 pafta=<ROOT>\runs\teshis\k39\pafta_video.png
17:08:23 | KAPI RED: kare=56 (beklenen 56) gurultu=0 (<=1,5) orta_akis=0 (>0,05); gonderim gitmez; pafta=<ROOT>\runs\teshis\k56_faoff\pafta_video.png
17:40:41 | KAPI RED: kare=39 (beklenen 39) gurultu=0 (<=1,5) orta_akis=0 (>0,05); gonderim gitmez; pafta=<ROOT>\runs\teshis\k39_zincir2\pafta_video.png

# Yeni yerel sm_120 derlemesi (engine/bin_sm120) kabul kosulari:
18:20:36 | KAPI GECTI: kare=39 gurultu=0.7 orta_akis=1.42 pafta=<ROOT>\runs\kabul_sm120\k39\pafta_video.png
18:24:05 | KAPI GECTI: kare=39 gurultu=0.47 orta_akis=1.43 pafta=<ROOT>\runs\kabul_sm120\k39_init\pafta_video.png
18:26:03 | KAPI GECTI: kare=56 gurultu=1.1 orta_akis=1.7 pafta=<ROOT>\runs\kabul_sm120\k56\pafta_video.png
18:32:23 | KAPI GECTI: kare=209 gurultu=1.02 orta_akis=1.4 pafta=<ROOT>\runs\kabul_sm120\k209\pafta_video.png

# MCP uzerinden 56 kare ve 192 kare init_image kosulari:
18:36:36 | KAPI GECTI: kare=56 gurultu=0.91 orta_akis=1.64 pafta=<ROOT>\runs\mcp_jobs\20261120-183435-4bd0d2\pafta_video.png
19:23:53 | KAPI GECTI: kare=192 gurultu=0.81 orta_akis=1.61 pafta=<ROOT>\runs\mcp_jobs\20261120-191746-5c09e1\pafta_video.png
19:32:50 | KAPI GECTI: kare=192 gurultu=0.8 orta_akis=0.89 pafta=<ROOT>\runs\mcp_jobs\20261120-192606-6ce23d\pafta_video.png
19:42:04 | KAPI GECTI: kare=192 gurultu=0.57 orta_akis=0.57 pafta=<ROOT>\runs\mcp_jobs\20261120-193528-9efede\pafta_video.png
20:16:47 | KAPI GECTI: kare=192 gurultu=0.63 orta_akis=1.38 pafta=<ROOT>\runs\mcp_jobs\20261120-201021-0cd7d8\pafta_video.png
20:27:22 | KAPI GECTI: kare=192 gurultu=0.68 orta_akis=3.86 pafta=<ROOT>\runs\mcp_jobs\20261120-202030-e00c37\pafta_video.png
20:36:27 | KAPI GECTI: kare=192 gurultu=0.58 orta_akis=2.06 pafta=<ROOT>\runs\mcp_jobs\20261120-202947-1e8e32\pafta_video.png
20:45:03 | KAPI GECTI: kare=192 gurultu=0.82 orta_akis=5.27 pafta=<ROOT>\runs\mcp_jobs\20261120-203900-1c46ee\pafta_video.png
20:52:11 | KAPI GECTI: kare=192 gurultu=0.51 orta_akis=1.89 pafta=<ROOT>\runs\mcp_jobs\20261120-204544-f7f03b\pafta_video.png
```
