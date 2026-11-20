# VideoTurko MCP Sunucusu / MCP Server (TR + EN)

Yerel MiniMax H3 (`sd-cli`, CUDA) metinden/resimden video üretimini **stdio** tabanlı MCP (Model Context Protocol) araçları olarak sunar.

Exposes local MiniMax H3 (`sd-cli`, CUDA) text-to-video and image-to-video generation over a **stdio** MCP server.

---

## Özellikler / Highlights
- **Otomatik `sm_120` seçimi / Auto `bin_sm120` detection:** `<ROOT>/engine/bin_sm120/sd-cli.exe` mevcutsa (ve `VT_ENGINE_BIN` elle ayarlanmadıysa) RTX 5060 / Blackwell yerel derlemesini otomatik seçer.
- **Kare sınırları / Frame limits:** `17k+5` ızgarasında metinden en fazla **209 kare (8.7 s)**, `init_image` ile en fazla **192 kare (8.0 s)**.
- **Tek GPU kilidi / Single-GPU lock:** Aynı anda tek üretim işi çalıştırır; uzun işler ayrı PowerShell sürecinde arka planda koşar ve hemen `job_id` döner.
- **Ölçülen RTX 5060 (`sm_120`) süreleri / Measured RTX 5060 timings:** 56 kare ≈ 2 dk, 192 kare (`init_image`) ≈ 6.3–7.0 dk, 209 kare ≈ 6 dk (640×384, 24 fps).

---

## Kurulum ve Çalıştırma / Setup & Usage

Gereksinim: Python 3.10+ ve `mcp` paketi (`pip install mcp`).

```json
{
  "mcpServers": {
    "videoturko": {
      "command": "python",
      "args": ["mcp/videoturko_mcp.py"],
      "cwd": "<ROOT>"
    }
  }
}
```

### Ortam Değişkenleri / Environment Variables
| Değişken / Variable | Varsayılan / Default | Açıklama / Description |
|---|---|---|
| `VT_ROOT` | `<repo root>` | VideoTurko kök klasörü / repository root |
| `VT_ENGINE_BIN` | `engine/bin_sm120` (varsa) veya `engine/bin` | `sd-cli.exe` klasörü / engine binary folder |
| `VT_MODEL_DIR` | `<VT_ROOT>/model` | Model ağırlıklarının klasörü / model weights directory |
| `VT_MCP_MAX_FRAMES` | `209` | İzin verilen en yüksek kare sayısı / max allowed frames |
| `VT_MCP_ALLOW_INIT` | `1` | `0` yapılırsa `init_image` kapatılır / set `0` to disable `init_image` |

---

## Araçlar / Tools
- `status()`: Motor (`sd-cli.exe`), 4 model dosyası, GPU (`nvidia-smi`), çalışan işler ve geçerli kare listesini döner.
- `generate_video(prompt, frames=209, seed=42, init_image="")`: Arka planda üretim başlatır, `job_id` ve çıktı yolunu (`runs/mcp_jobs/<job_id>/video.avi`) döner.
- `job_status(job_id, log_lines=15)`: İş durumunu (`running` / `done` / `failed` / `cancelled`), çıkış kodunu, kalite kapısı sonucunu ve son log satırlarını döner.
- `cancel_job(job_id)`: `DUR` dosyası + süreç ağacı sonlandırma ile çalışan işi durdurur.
- `list_jobs(limit=10)`: Son işleri listeler.

---

## İlgili Belgeler / Related Docs
- Derleme tarifi / Build recipe: [`../docs/RTX5060_SM120_DERLEME.md`](../docs/RTX5060_SM120_DERLEME.md)
- Kök neden ve ölçümler / Root cause & benchmarks: [`../docs/RTX5060_TEST_RAPORU.md`](../docs/RTX5060_TEST_RAPORU.md)
- Klip zincirleme / Clip chaining: [`../docs/KLIP_ZINCIRI.md`](../docs/KLIP_ZINCIRI.md)
- Model lisansı / Model license: MiniMax H3 Community License (`../docs/LISANS_UYARISI.md`)
