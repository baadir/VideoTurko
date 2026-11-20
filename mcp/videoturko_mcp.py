"""VideoTurko MCP sunucusu: yerel MiniMax H3 (sd-cli) metinden/resimden video uretimi.

Araclar: status, generate_video, job_status, cancel_job, list_jobs.
Uretim uzun surer (RTX 5060: 56 kare ~2 dk, 209 kare ~6 dk); generate_video isi ayri surecte baslatir ve job_id dondurur.
Tek GPU: ayni anda yalniz bir is calisir.
"""
import codecs, csv, io, json, os, re, subprocess, time, uuid
from pathlib import Path
from mcp.server.fastmcp import FastMCP

ROOT = Path(os.environ.get("VT_ROOT", Path(__file__).resolve().parent.parent))
MODEL = Path(os.environ.get("VT_MODEL_DIR", ROOT / "model"))
JOBS = ROOT / "runs" / "mcp_jobs"
if (ROOT / "engine" / "bin_sm120" / "sd-cli.exe").exists():  # RTX 5060 (sm_120) yerel derleme varsa otomatik sec
    os.environ.setdefault("VT_ENGINE_BIN", str(ROOT / "engine" / "bin_sm120"))
JOBS.mkdir(parents=True, exist_ok=True)
FILES = ["minimax_h3_fl2va_hyperflow_flash_14b-Q4_K_M.gguf", "qwen3vl_32b_minimax_h3-Q4_K_M.gguf",
         "minimax_h3_sol_vae_fp16.safetensors", "minimax_h3_audio_vae_fp32.safetensors"]
MAX_FRAMES = int(os.environ.get("VT_MCP_MAX_FRAMES", "209"))  # Varsayilan ust sinir 209 kare (init_image <= 192)
VALID = [5 + 17 * k for k in range(13) if 5 + 17 * k <= MAX_FRAMES]

mcp = FastMCP("videoturko")


JID = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{6}$")
LOCK = JOBS / ".lock"


def _meta(jid):
    if not JID.match(jid or ""):
        return None
    p = JOBS / jid / "job.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def _alive(pid):
    r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"], capture_output=True, text=True)
    for row in csv.reader(io.StringIO(r.stdout)):
        if len(row) > 1 and row[1] == str(pid) and row[0].lower() == "powershell.exe":
            return True
    return False


def _state(m):
    d = JOBS / m["id"]
    if (d / "video.avi").exists() and not _alive(m["pid"]):
        return "done"
    if _alive(m["pid"]):
        return "running"
    return "cancelled" if m.get("cancelled") else "failed"


@mcp.tool()
def status() -> dict:
    """Motor, model dosyalari ve GPU durumunu raporlar; uretime hazir mi soyler."""
    files = {f: (MODEL / f).exists() for f in FILES}
    sd = (Path(os.environ.get("VT_ENGINE_BIN", ROOT / "engine" / "bin")) / "sd-cli.exe").exists()
    try:
        gpu = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.used,memory.total", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception as e:
        gpu = f"okunamadi: {e}"
    running = [m["id"] for m in map(_meta, os.listdir(JOBS)) if m and _state(m) == "running"]
    return {"ready": sd and all(files.values()), "engine": sd, "models": files, "gpu": gpu,
            "running_jobs": running, "valid_frames": VALID, "fps": 24, "resolution": "640x384"}


@mcp.tool()
def generate_video(prompt: str, frames: int = 209, seed: int = 42, init_image: str = "") -> dict:
    """Metinden (veya init_image ile resimden/onceki klipten) video uretimini baslatir.
    frames 17k+5 (5..209; init_image ile en fazla 192). 24 fps, 640x384.
    Hemen job_id doner; ilerlemeyi job_status ile izleyin (RTX 5060: 56 kare ~2 dk, 209 kare ~6 dk)."""
    if frames not in VALID:
        return {"error": f"frames {VALID} icinden olmali"}
    if init_image and os.environ.get("VT_MCP_ALLOW_INIT", "1") != "1":
        return {"error": "init_image VT_MCP_ALLOW_INIT ayari ile kapatildi"}
    if init_image and frames > 192:
        return {"error": "init_image ile en fazla 192 kare"}
    if init_image and not Path(init_image).exists():
        return {"error": f"init_image yok: {init_image}"}
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        if time.time() - LOCK.stat().st_mtime < 120:
            return {"error": "baska bir baslatma suruyor"}
        LOCK.unlink(missing_ok=True)
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    os.close(fd)
    try:
        return _start(prompt, frames, seed, init_image)
    finally:
        LOCK.unlink(missing_ok=True)


def _start(prompt, frames, seed, init_image):
    st = status()
    if not st["ready"]:
        return {"error": "hazir degil", "status": st}
    if st["running_jobs"]:
        return {"error": "GPU mesgul", "running_jobs": st["running_jobs"]}
    jid = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
    d = JOBS / jid
    d.mkdir()
    (d / "istem.txt").write_text(prompt, encoding="utf-8")
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "scripts" / "uret.ps1"),
           "-Istem", str(d / "istem.txt"), "-Kare", str(frames), "-Seed", str(seed), "-Cikti", str(d / "video.avi")]
    if init_image:
        cmd += ["-InitImg", init_image]
    # MCP surecinden bagimsiz yasasin: is basina run.ps1, Start-Process ile ayri surec agaci
    q = lambda a: "'" + a.replace("'", "''") + "'"
    args = " ".join(a if a.startswith("-") else q(a) for a in cmd[6:])
    lines = [f"Set-Location {q(str(ROOT))}",
             f"& {q(cmd[5])} {args} *> {q(str(d / 'log.txt'))}",
             f"Set-Content -LiteralPath {q(str(d / 'exit.txt'))} $LASTEXITCODE"]
    (d / "run.ps1").write_text("\r\n".join(lines) + "\r\n", encoding="utf-8-sig")
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
                          f"(Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList "
                          f"'-NoProfile -ExecutionPolicy Bypass -File \"{d / 'run.ps1'}\"').Id"],
                         capture_output=True, text=True, timeout=60).stdout
    pid = int(out.strip().splitlines()[-1])
    m = {"id": jid, "pid": pid, "frames": frames, "seed": seed, "init_image": init_image,
         "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "output": str(d / "video.avi")}
    (d / "job.json").write_text(json.dumps(m, ensure_ascii=False, indent=1), encoding="utf-8")
    return {"job_id": jid, "state": "running", "output": m["output"], "seconds": round(frames / 24, 2)}


@mcp.tool()
def job_status(job_id: str, log_lines: int = 15) -> dict:
    """Isin durumu (running/done/failed/cancelled), cikti yolu ve log sonu."""
    m = _meta(job_id)
    if not m:
        return {"error": "is yok"}
    lp = JOBS / job_id / "log.txt"
    tail = []
    if lp.exists():
        b = lp.read_bytes()
        enc = "utf-16" if b[:2] in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE) or b[1:2] == bytes(1) else "utf-8"
        tail = [l for l in b.decode(enc, errors="replace").splitlines() if l.strip()][-log_lines:]
    ex = JOBS / job_id / "exit.txt"
    code = ex.read_text(encoding="utf-8-sig").strip() if ex.exists() else None
    return {**m, "state": _state(m), "exit_code": code,
            "gate": None if code is None else ("GECTI" if code == "0" else "RED/HATA (runs/olaylar.txt)"),
            "log_tail": tail}


@mcp.tool()
def cancel_job(job_id: str) -> dict:
    """Calisan isi durdurur (uret.ps1 DUR dosyasi + surec agaci sonlandirma)."""
    m = _meta(job_id)
    if not m:
        return {"error": "is yok"}
    if _state(m) != "running":
        return {"job_id": job_id, "state": _state(m), "note": "calismiyor; islem yapilmadi"}
    (ROOT / "DUR").write_text("mcp", encoding="utf-8")
    time.sleep(5)
    subprocess.run(["taskkill", "/PID", str(m["pid"]), "/T", "/F"], capture_output=True)
    (ROOT / "DUR").unlink(missing_ok=True)
    m["cancelled"] = True
    (JOBS / job_id / "job.json").write_text(json.dumps(m, ensure_ascii=False, indent=1), encoding="utf-8")
    return {"job_id": job_id, "state": "cancelled"}


@mcp.tool()
def list_jobs(limit: int = 10) -> list:
    """Son isleri listeler."""
    out = []
    for jid in sorted(os.listdir(JOBS), reverse=True)[:limit]:
        m = _meta(jid)
        if m:
            out.append({"job_id": jid, "state": _state(m), "frames": m["frames"], "output": m["output"]})
    return out


if __name__ == "__main__":
    mcp.run()
