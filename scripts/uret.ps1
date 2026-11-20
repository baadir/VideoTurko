# VideoTurko uret.ps1: tek komutla video (istem dosyasi + kare sayisi).  EN: one command text-to-video / image-to-video.
# Kullanim / usage:
#   powershell -NoProfile -File scripts\uret.ps1 -Istem istem.txt                       (209 kare, 8,7 sn)
#   powershell -NoProfile -File scripts\uret.ps1 -Istem istem.txt -Kare 141 -Cikti video.avi
#   powershell -NoProfile -File scripts\uret.ps1 -Istem istem.txt -InitImg onceki_son_kare.png   (parca zinciri)
#   powershell -NoProfile -File scripts\uret.ps1 -Istem istem.txt -InitImg ilk.png -EndImg son.png -Kare 107   (ilk + son kare / first + last frame)
#   powershell -NoProfile -File scripts\uret.ps1 -Istem istem.txt -W 384 -H 640 -Kare 56   (dikey / vertical; 32'nin kati, alan >= 640x384)
#   -Kuru : komutlari ve ortam degiskenlerini yazar, calistirmaz / print only, do not run
#   -TekAsama : iki asamayi elle kapatir (buyuk VRAM'li kartlar icin; 4 GB'da 108+ karede VAE bellege sigmaz) / force single process
# Sabitler (kalite): 6 adim, cfg 1, tohum 42, KAROSUZ VAE (--vae-tiling/--temporal-tiling HICBIR ZAMAN eklenmez).
# Cozunurluk: varsayilan 640x384 (olculen ve bayt kanitli tek boyut). -W/-H: 32'nin kati, alan en az 640x384 (kalite dusurulmez);
#   baska boyutlar 4 GB'da DENENMEDI ve kalite kapisi esikleri 640x384 icin kalibre (baska boyutta uyari basilir).
# -InitImg varken tavan $KareInit kare; ikisi de yokken $KareSabit. -EndImg: kucuk kartta (VRAM < $KucukKartMiB = 8192 MiB ya da okunamadi) HER ZAMAN iki asama ve tavan
#   $KareEnd4GB (175) [olctum 1050 Ti: ilk+son kare tek asamada 56 karede ve iki asamada 192'de sigmadi; iki asamada 56 ve 175 GECTI]; 8 GB ve ustu kartta tavan $KareInit (FLF orada bizce olculmedi).
#   -EndImg tek basina (-InitImg'siz) olculmedi.
# Kare sayisi 17k+5 olmali: 5, 22, 39, 56, 73, 90, 107, 124, 141, 158, 175, 192, 209 (209 = bilinen sinir; daha uzunu DENENMEDI; tavan: $KareSabit / VT_MAX_KARE).
# Not: VRAM tepe 209 karede 3777 MiB olculdu [olctum, tum kart]; daha uzun kareler icin VRAM/RAM verisi yok (denenmedi).
# Iki asama (1: DiT latent'i kaydeder, 2: AYRI surecte VAE cozer) jeton sayisina gore: jeton = (W/32)*(H/32)*latent_kare, latent_kare = ((Kare-5)/17)*5+2;
#   jeton > 7680 ise iki asama. 640x384'te bu "108 kare ve ustu" ile aynidir (107: 7680 tek surec, 124: 8880 iki asama).
# GPU compute capability >= 7.0 ise ve GGML_CUDA_CUBLAS_COMPUTE_TYPE ayarli degilse f32 yapilir (sm89'da >=141 karede fp16 tasmasi -> siyah video; issue #1).
#   GTX 1050 Ti (6.1) icin hicbir sey degismez.
# Ortam / environment: VT_ROOT (varsayilan: bu betigin ust klasoru), VT_ENGINE_BIN (sd-cli.exe klasoru), VT_MODEL_DIR (model dosyalari),
#   VT_CUDA_BIN (cudart/cublas DLL klasoru, istege bagli), VT_PYTHON (kalite kapisi icin python + opencv),
#   VT_MAX_JETON (4 GB kartta standart disi boyut icin jeton tavanini gecici ezer; sonuc garanti degil), VT_GPU_CC / VT_GPU_VRAM (compute capability / toplam VRAM MiB okumasini ezer, test icin).
# Deneysel / teshis anahtarlari (varsayilan KAPALI; ayarlanmazsa varsayilan davranis degismez; bkz. docs\RTX5060_SM120_DERLEME.md):
#   VT_ATTN_BUDGET (varsayilan 0.05), VT_IKI_ASAMA=1 (iki asamayi zorlar), VT_NO_FA=1 (--flash-attn off),
#   VT_TT_RULES (--tensor-type-rules), VT_DIT (alternatif DiT GGUF yolu), VT_MAX_VRAM (--max-vram), VT_CHUNK_MB (QKV/MLP chunk MB, varsayilan 64).
# Durdurma / stop: <VT_ROOT>\DUR dosyasi olusturun; betik DURDU yazar, sd-cli'yi kapatir (latent kaldiysa yeniden baslatinca devam etmez, bastan kosar).
param(
    [Parameter(Mandatory)][string]$Istem,
    [int]$Kare = 0,   # 0 = varsayilan: $KareSabit
    [string]$Cikti = "",
    [string]$InitImg = "",
    [int]$TavanDk = 0,
    [int]$Seed = 42,
    [string]$EndImg = "",
    [int]$W = 640,
    [int]$H = 384,
    [switch]$TekAsama,
    [switch]$Kuru,
    [switch]$Kontrol
)
$ErrorActionPreference = 'Stop'
$KareSabit = 209   # TEK SABIT SAYI: varsayilan -Kare VE kare tavani (yalniz bu satir degisir). Daha buyuk kare reddedilir (denenmedi).
$KareInit = 192   # TEK SABIT SAYI: -InitImg (resimden/onceki klipten devam) ile en fazla kare (192 / 24 fps = 8,0 sn). Tek GPU, tek sahne olculdu; baska GPU'larda denenmedi.
$KareEnd4GB = 175   # TEK SABIT SAYI: 4 GB kartta -EndImg ile en fazla kare (175 / 24 fps = 7,3 sn; iki asama). 192 sigmadi [olctum 1050 Ti, FLF192 ve FLF175].
$KucukKartMiB = 8192   # TEK SABIT SAYI: bu degerin altindaki (ya da VRAM'i okunamayan) kart 'kucuk' sayilir: -EndImg her zaman iki asama + tavan $KareEnd4GB, standart disi boyutta jeton tavani. 6/8 GB'da veri yok, temkinli taraf.
$KareVarsayilan = ($Kare -eq 0)
if ($Kare -eq 0) { $Kare = $(if ($InitImg -or $EndImg) { $KareInit } else { $KareSabit }) }
$Root = $(if ($env:VT_ROOT) { $env:VT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path })
$Motor = $(if ($env:VT_ENGINE_BIN) { $env:VT_ENGINE_BIN } else { Join-Path $Root 'engine\bin' })
$ModelDir = $(if ($env:VT_MODEL_DIR) { $env:VT_MODEL_DIR } else { Join-Path $Root 'model' })

# --- GPU bilgisi (yalniz okuma; okunamazsa -1 ve hicbir sey degismez) ---
$GpuTop = -1; $GpuCc = -1.0; $GpuSayi = 0
$Inv = [Globalization.CultureInfo]::InvariantCulture; $Flt = [Globalization.NumberStyles]::Float
if (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue) {
    # Birden cok GPU: sd-cli CUDA 0'i kullanir, nvidia-smi sirasi farkli olabilir. Temkinli taraf: EN KUCUK toplam VRAM ve EN KUCUK compute capability
    #   (f32 yalniz tum kartlar >= 7.0 ise). Herhangi bir kartin cc'si okunamazsa cc okunamadi (-1) sayilir. Yalniz tek GPU ile olculdu.
    try { foreach ($qm in @(& nvidia-smi.exe --query-gpu=memory.total --format=csv,noheader,nounits 2>$null)) { $tmpM = 0; if ([int]::TryParse(("$qm").Trim(), [ref]$tmpM) -and $tmpM -gt 0) { $GpuSayi++; if ($GpuTop -lt 0 -or $tmpM -lt $GpuTop) { $GpuTop = $tmpM } } } } catch { }
    try { $ccIlk = $true; foreach ($qc in @(& nvidia-smi.exe --query-gpu=compute_cap --format=csv,noheader,nounits 2>$null)) { $tmpC = 0.0; if ([double]::TryParse(("$qc").Trim(), $Flt, $Inv, [ref]$tmpC)) { if ($ccIlk -or $tmpC -lt $GpuCc) { $GpuCc = $tmpC }; $ccIlk = $false } else { $GpuCc = -1.0; break } } } catch { $GpuCc = -1.0 }
}
# Test ezmeleri: ondalik virgul de kabul (7,5 = 7.5); okunamazsa acik uyari, yok sayilir.
if ($env:VT_GPU_CC) { $tmpC = 0.0; if ([double]::TryParse($env:VT_GPU_CC.Trim().Replace(',', '.'), $Flt, $Inv, [ref]$tmpC)) { $GpuCc = $tmpC } else { Write-Output ("UYARI: VT_GPU_CC='{0}' sayi olarak okunamadi, yok sayildi (ornek: 8.9 ya da 8,9)" -f $env:VT_GPU_CC) } }
if ($env:VT_GPU_VRAM) { $tmpV = 0.0; if ([double]::TryParse($env:VT_GPU_VRAM.Trim().Replace(',', '.'), $Flt, $Inv, [ref]$tmpV) -and $tmpV -gt 0) { $GpuTop = [int][Math]::Floor($tmpV) } else { Write-Output ("UYARI: VT_GPU_VRAM='{0}' sayi (MiB) olarak okunamadi, yok sayildi (ornek: 12282)" -f $env:VT_GPU_VRAM) } }
if ($GpuSayi -gt 1) { Write-Output ("bilgi: {0} GPU goruldu; sd-cli CUDA 0'i kullanir. Betik temkinli tarafla karar verir: en kucuk VRAM {1} MiB, en kucuk compute capability {2} (f32 yalniz tum kartlar >= 7.0 ise). Yalniz tek GPU ile olculdu; karti CUDA_VISIBLE_DEVICES ile secebilirsiniz." -f $GpuSayi, $GpuTop, $(if ($GpuCc -lt 0) { 'okunamadi' } else { $GpuCc.ToString($Inv) })) }
$KucukKart = ($GpuTop -lt $KucukKartMiB)   # VRAM okunamadiysa (-1) kucuk sayilir (temkinli)
$KareEndTavan = $(if ($KucukKart) { $KareEnd4GB } else { $KareInit })
if ($EndImg -and $KareVarsayilan) { $Kare = $KareEndTavan }

# --- dogrulamalar ---
if ($Kare -lt 5 -or (($Kare - 5) % 17) -ne 0) { throw "Kare sayisi 17k+5 olmali (5, 22, 39, ... 17k+5; en fazla $KareSabit). Verilen: $Kare" }
if ($InitImg -and $Kare -gt $KareInit) { throw "-InitImg ile en fazla $KareInit kare (8,0 sn) desteklenir: bu GPU'da $KareSabit kare -InitImg ile bellege sigmadi; baska GPU'larda denenmedi. -Kare $KareInit ya da daha kucugunu verin. Verilen: $Kare" }
if ($EndImg -and $KucukKart -and $Kare -gt $KareEnd4GB) { throw "-EndImg ile bu kartta (VRAM $(if ($GpuTop -lt 0) { 'okunamadi, 8 GB alti sayildi' } else { "$GpuTop MiB; 8 GB alti" })) en fazla $KareEnd4GB kare (7,3 sn): 192 bu kartta sigmadi, 175 olculdu (GTX 1050 Ti, iki asama). -Kare $KareEnd4GB ya da daha kucugunu verin. Verilen: $Kare" }
if ($EndImg -and $Kare -gt $KareInit) { throw "-EndImg ile en fazla $KareInit kare (8,0 sn) desteklenir (-InitImg ile ayni tavan; 8 GB ve ustu kartta FLF bizce olculmedi). -Kare $KareInit ya da daha kucugunu verin. Verilen: $Kare" }
# Kare tavani = $KareSabit (dogrulanan en uzun kare). VT_MAX_KARE ile gecici ezilir (sonuc garanti degil).
$KareTavan = $(if ($env:VT_MAX_KARE) { [int]$env:VT_MAX_KARE } else { $KareSabit })
if ($Kare -gt $KareTavan) { throw "Kare sayisi $KareTavan degerinden buyuk desteklenmiyor (denenmedi). Verilen: $Kare" }
# Cozunurluk: motor W/H'yi 32'nin katina YUKARI yuvarlar (720 -> 736); sessiz degisiklik olmasin diye burada reddedilir.
if ($PSBoundParameters.ContainsKey('W') -xor $PSBoundParameters.ContainsKey('H')) { throw "-W ve -H birlikte verilmeli (yalniz biri verilirse oteki 640/384 kalir ve beklenmedik boyut cikar). Dikey: -W 384 -H 640. Verilen: ${W}x${H}" }
if ($W -le 0 -or $H -le 0 -or ($W % 32) -ne 0 -or ($H % 32) -ne 0) { throw "-W ve -H 32'nin kati olmali (motor yukari yuvarlar: 720 -> 736). Ornek: 640x384, 384x640, 832x480, 1280x736. Verilen: ${W}x${H}" }
if (($W * $H) -lt (640 * 384)) { throw "-W x -H alani en az 640x384 (245760 piksel) olmali: kalite dusurulmez. Dikey icin -W 384 -H 640. Verilen: ${W}x${H}" }
$Standart = ($W -eq 640 -and $H -eq 384)
$LatKare = $(if ($Kare -le 5) { 2 } else { [int][Math]::Floor(($Kare - 5) / 17) * 5 + 2 })
$Jeton = [int](($W / 32) * ($H / 32) * $LatKare)
# Kucuk kart (VRAM < $KucukKartMiB ya da okunamadi): standart disi boyutta jeton tavani = 640x384'te olculen en buyuk (209 kare 14880; -InitImg ile 192 kare 13680; -EndImg ile 175 kare 12480).
$JetonTavan = $(if ($EndImg) { 12480 } elseif ($InitImg) { 13680 } else { 14880 })
if ($env:VT_MAX_JETON) { $JetonTavan = [int]$env:VT_MAX_JETON }
if (-not $Standart -and ($KucukKart -or $env:VT_MAX_JETON) -and $Jeton -gt $JetonTavan) {
    throw ("{0}x{1} ve {2} kare = {3} jeton; bu kartta tavan {4} jeton (4 GB'da olculen en buyuk is; VRAM {5}). Daha kisa -Kare ya da daha kucuk boyut verin; VT_MAX_JETON ile gecici ezilir (sonuc garanti degil){6}." -f $W, $H, $Kare, $Jeton, $JetonTavan, $(if ($GpuTop -lt 0) { 'okunamadi, 8 GB alti sayildi' } else { "$GpuTop MiB" }), $(if ($GpuTop -lt 0) { '; nvidia-smi VRAM okuyamadi: buyuk kartiniz varsa VT_GPU_VRAM=<MiB> ile toplam VRAM verilebilir (test amacli, sonuc garanti degil)' } else { '' }))
}
if (-not (Test-Path -LiteralPath $Istem)) { throw "istem dosyasi yok: $Istem" }
if ($InitImg -and -not (Test-Path -LiteralPath $InitImg -PathType Leaf)) { throw "-InitImg dosyasi bulunamadi: $InitImg (ilk kare gorseli, PNG/JPG; video boyutunda verin)" }
if ($EndImg -and -not (Test-Path -LiteralPath $EndImg -PathType Leaf)) { throw "-EndImg dosyasi bulunamadi: $EndImg (son kare gorseli, PNG/JPG; video boyutunda verin, motor farkli boyutu esnetir)" }
$sd = Join-Path $Motor 'sd-cli.exe'
$DiT = Join-Path $ModelDir 'minimax_h3_fl2va_hyperflow_flash_14b-Q4_K_M.gguf'
if ($env:VT_DIT) { $DiT = $env:VT_DIT }
$TE = Join-Path $ModelDir 'qwen3vl_32b_minimax_h3-Q4_K_M.gguf'
$VAE = Join-Path $ModelDir 'minimax_h3_sol_vae_fp16.safetensors'
$AVAE = Join-Path $ModelDir 'minimax_h3_audio_vae_fp32.safetensors'
if (-not $Kuru) {
    foreach ($f in @($sd, $DiT, $TE, $VAE, $AVAE)) { if (-not (Test-Path -LiteralPath $f)) { throw "dosya yok: $f (once scripts\kur.ps1 calistirin)" } }
    if ($InitImg -and -not (Test-Path -LiteralPath $InitImg)) { throw "InitImg yok: $InitImg" }
}

# --- cikti yeri ---
if (-not $Cikti) { $Cikti = Join-Path $Root ("runs\{0}_{1}kare\video.avi" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Kare) }
if (-not [IO.Path]::IsPathRooted($Cikti)) { $Cikti = Join-Path (Get-Location).Path $Cikti }
if ([IO.Path]::GetExtension($Cikti) -ne '.avi') { $Cikti = [IO.Path]::ChangeExtension($Cikti, '.avi') }
$Dizin = Split-Path -Parent $Cikti
$Ad = [IO.Path]::GetFileNameWithoutExtension($Cikti)
$Latent = Join-Path $Dizin ($Ad + '_latent.bin')
$Istem = (Resolve-Path -LiteralPath $Istem).Path
if ($InitImg) { $InitImg = (Resolve-Path -LiteralPath $InitImg).Path }
if ($EndImg) { $EndImg = (Resolve-Path -LiteralPath $EndImg).Path }
$AlanKat = ($W * $H) / 245760.0   # 640x384 = 1,0 (varsayilanda tavan degismez)
if ($TavanDk -le 0) { $TavanDk = [int][Math]::Max(30, [Math]::Ceiling(80.0 * $Kare / 209 * $AlanKat)) }   # 209 kare = 80 dk (olculen ~48 dk DiT + VAE, x1,4 pay); alanla olceklenir

function Ortak-Arg([string]$Out) {
    $faVal = $(if ($env:VT_NO_FA -eq '1') { 'off' } else { 'off,diffusion=on' })
    $attnBudget = $(if ($env:VT_ATTN_BUDGET) { $env:VT_ATTN_BUDGET } else { '0.05' })
    $a = @('-M', 'vid_gen', '--diffusion-model', $DiT, '--llm', $TE, '--vae', $VAE, '--audio-vae', $AVAE,
        '--prompt-file', $Istem, '-W', "$W", '-H', "$H", '--video-frames', "$Kare", '--fps', '24',
        '--steps', '6', '--sampling-method', 'euler', '--sigmas', 'hyperflow-h3-flash-6', '--cfg-scale', '1.0',
        '--rng', 'cpu', '--seed', "$Seed", '-t', '4', '--flash-attn', $faVal,   # varsayilan: eski --diffusion-fa ile ayni ayar
        '--model-args', "minimax_h3_attn_chunk_budget=$attnBudget",
        '--offload-to-cpu', '--mmap', '--backend', 'te=cpu')
    if ($env:VT_TT_RULES) { $a += @('--tensor-type-rules', $env:VT_TT_RULES) }
    if ($env:VT_MAX_VRAM) { $a += @('--max-vram', $env:VT_MAX_VRAM) }
    if ($InitImg) { $a += @('--init-img', $InitImg) }
    if ($EndImg) { $a += @('--end-img', $EndImg) }
    $a += @('--log-level', 'debug', '-o', $Out)
    return $a
}
# Ortam: jeton > 7680 iki asama (640x384'te 108+ kare ile ayni; dogrulanmis tarif: 209 icin DiT asamasi + ayri VAE asamasi; 141 icin ayri VAE kare+ses md5 bayt aynisi).
# -TekAsama: elle tek surec (buyuk VRAM'li kart); varsayilan degismez.
# -EndImg kucuk kartta (< $KucukKartMiB) her zaman iki asama: tek asamada 56 karede bile sigmadi [olctum 1050 Ti FLF56; iki asamada FLF56b GECTI].
$IkiAsama = (($Jeton -gt 7680) -or ($EndImg -and $KucukKart) -or ($env:VT_IKI_ASAMA -eq '1')) -and -not $TekAsama
$Env1 = [ordered]@{}
$Env2 = [ordered]@{}
$ChunkMB = $(if ($env:VT_CHUNK_MB) { $env:VT_CHUNK_MB } else { '64' })
if ($IkiAsama) {
    $Env1['SD_VRAM_MARGIN_MB'] = '1'; $Env1['SD_H3_EMBED_CUT'] = '1'; $Env1['SD_H3_DROP_QUEUED'] = '1'; $Env1['SD_H3_EVICT_PAST'] = '1'
    $Env1['SD_ATTN_SET_OUT'] = '1'; $Env1['SD_QKV_CHUNK_MB'] = $ChunkMB; $Env1['SD_QKV_SET_OUT'] = '1'; $Env1['SD_MLP_CHUNK_MB'] = $ChunkMB
    $Env1['SD_VIDEO_LATENT_SAVE'] = $Latent   # F209b/F209V2 tarifi; MLP_SET_OUT KAPALI (bellegi artirir)
    $Env2['SD_VRAM_MARGIN_MB'] = '256'; $Env2['SD_VAE_VRAM_MARGIN_MB'] = '256'; $Env2['SD_CUT_CACHE_HOST_MB'] = '100'
    $Env2['SD_VAE_NO_TILING_FALLBACK'] = '1'; $Env2['SD_VAE_EMBED_CUT'] = '1'; $Env2['SD_VIDEO_LATENT_LOAD'] = $Latent
} else {
    $Env1['SD_VAE_NO_TILING_FALLBACK'] = '1'
}
# cuBLAS f32: compute capability >= 7.0 ve kullanici ayarlamadiysa (sm89'da fp16 >=141 karede tasiyor: siyah video, issue #1). 6.1 (1050 Ti) ve okunamayan cc: dokunulmaz.
if ($GpuCc -ge 7.0 -and -not $env:GGML_CUDA_CUBLAS_COMPUTE_TYPE) { $Env1['GGML_CUDA_CUBLAS_COMPUTE_TYPE'] = 'f32'; $Env2['GGML_CUDA_CUBLAS_COMPUTE_TYPE'] = 'f32' }

# Kalite kapisi on kontrolu, GPU isinden ONCE: python + opencv + numpy calistirilarak denenir (Windows'ta python kurulu degilken bile
#   Microsoft Store kisayolu WindowsApps\python.exe bulunur ve 9009 ile cikar; Get-Command yetmez). Basarisizsa video uretilmez, cikis 6.
#   -Kontrol (kur.ps1 kontrol uretimi, kapi yok): atlanir. -Kuru: yalniz bilgi satiri.
if (-not $Kontrol) {
    $pyK = $(if ($env:VT_PYTHON) { $env:VT_PYTHON } else { 'python' }); $pyTamam = $false; $pyKod = 'bulunamadi'
    if (Get-Command $pyK -ErrorAction SilentlyContinue) {
        $eapP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $null = & $pyK -I -c "import cv2, numpy" 2>&1; $pyKod = "$LASTEXITCODE"; $pyTamam = ($LASTEXITCODE -eq 0) } catch { $pyKod = 'calistirilamadi' } finally { $ErrorActionPreference = $eapP }
    }
    if (-not $pyTamam) {
        $pyMesaj = "KAPI CALISAMAZ: python + opencv-python + numpy hazir degil ($pyK, sonuc $pyKod; 9009 = Windows Store kisayolu, python kurulu degil). Python 3 kurun (python.org), sonra 'py -3 -m pip install opencv-python numpy'; ya da VT_PYTHON ile python.exe yolunu verin."
        if ($Kuru) { Write-Output "bilgi: $pyMesaj (-Kuru: yalniz bilgi)" }
        else { Write-Output "$pyMesaj Video uretilmedi: GPU isi baslamadan durduruldu (cikis 6)."; exit 6 }
    }
}

if ($Kuru) {
    Write-Output "KURU: kare=$Kare iki_asama=$IkiAsama tavan=${TavanDk}dk cikti=$Cikti"
    Write-Output ("KURU bilgi: cozunurluk={0}x{1} jeton={2} tek_asama_elle={3} gpu_cc={4} gpu_vram={5} MiB f32={6}" -f $W, $H, $Jeton, [bool]$TekAsama, $GpuCc.ToString([Globalization.CultureInfo]::InvariantCulture), $GpuTop, $Env1.Contains('GGML_CUDA_CUBLAS_COMPUTE_TYPE'))
    Write-Output ("ASAMA 1 ortam: " + (($Env1.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
    Write-Output ("ASAMA 1 komut: sd-cli.exe " + ((Ortak-Arg $Cikti) -join ' '))
    if ($IkiAsama) {
        Write-Output ("ASAMA 2 ortam: " + (($Env2.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
        Write-Output ("ASAMA 2 komut: sd-cli.exe " + ((Ortak-Arg $Cikti) -join ' '))
    }
    exit 0
}

New-Item -ItemType Directory -Force $Dizin | Out-Null
$DurDosya = Join-Path $Root 'DUR'
$Kilit = Join-Path $Root 'runs\gpu.kilit'
New-Item -ItemType Directory -Force (Split-Path -Parent $Kilit) | Out-Null
if (Test-Path -LiteralPath $Kilit) {
    $eskiPid = 0; [int]::TryParse((Get-Content -LiteralPath $Kilit -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$eskiPid) | Out-Null
    if ($eskiPid -gt 0 -and (Get-Process -Id $eskiPid -ErrorAction SilentlyContinue)) { throw "GPU baska bir uret.ps1 tarafindan kullaniliyor (PID $eskiPid). Tek GPU isi calistirin." }
}
Set-Content -LiteralPath $Kilit -Value $PID -Encoding ASCII

function Asama-Kos([string]$Etiket, $EnvHash) {
    $out = Join-Path $Dizin ("ham_out_{0}{1}.txt" -f $Ad, $Etiket); $err = Join-Path $Dizin ("ham_err_{0}{1}.txt" -f $Ad, $Etiket)
    $eski = @{}
    foreach ($k in $EnvHash.Keys) { $eski[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $EnvHash[$k]) }
    $eskiPath = $env:PATH
    if ($env:VT_CUDA_BIN) { $env:PATH = "$($env:VT_CUDA_BIN);$Motor;$env:PATH" } else { $env:PATH = "$Motor;$env:PATH" }
    try {
        $argStr = (Ortak-Arg $Cikti | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $sp = Start-Process -FilePath $sd -ArgumentList $argStr -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $sp.Handle   # PS 5.1: tutamaci hemen al, yoksa ExitCode bos gelir
        $t0 = Get-Date; $kod = $null
        while (-not $sp.HasExited) {
            Start-Sleep -Seconds 5
            $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
            if ($smi) { $m = 0; if ([int]::TryParse((& nvidia-smi.exe --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1), [ref]$m) -and $m -gt $script:VramTepe) { $script:VramTepe = $m } }
            if (Test-Path -LiteralPath $DurDosya) { & taskkill.exe /T /F /PID $sp.Id | Out-Null; Write-Output "DURDU (DUR dosyasi) asama$Etiket"; exit 2 }
            if (((Get-Date) - $t0).TotalMinutes -gt $TavanDk) { & taskkill.exe /T /F /PID $sp.Id | Out-Null; throw "TAVAN: asama$Etiket $TavanDk dk'yi asti, kesildi (uzun kosu icin -TavanDk arttirin)" }
        }
        $sp.WaitForExit(); $kod = $sp.ExitCode
    } finally {
        foreach ($k in $EnvHash.Keys) { [Environment]::SetEnvironmentVariable($k, $eski[$k]) }
        $env:PATH = $eskiPath
    }
    return $kod
}
function Log-Temiz([string]$Etiket) {
    # Karolu VAE geri-dususu, bellek yetmedi satirlari, [E] hata satiri => gecersiz
    foreach ($n in @(("ham_out_{0}{1}.txt" -f $Ad, $Etiket), ("ham_err_{0}{1}.txt" -f $Ad, $Etiket))) {
        $p = Join-Path $Dizin $n
        if ((Test-Path -LiteralPath $p) -and (Select-String -LiteralPath $p -Pattern 'temporal tiling|retrying with|ALLOC_FAILED|cannot make enough memory' -Quiet)) { return $false }
    }
    return $true
}

function Avi-KareSayisi([string]$Yol) {
    # AVI ana baslik (avih) dwTotalFrames, dosya ofseti 48. Okunamazsa -1. [tasarim, gercek kosuda gorulecek]
    try {
        $fs = [IO.File]::Open($Yol, 'Open', 'Read', 'ReadWrite'); try { $b = New-Object byte[] 56; [void]$fs.Read($b, 0, 56) } finally { $fs.Close() }
        if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'RIFF' -or [Text.Encoding]::ASCII.GetString($b, 8, 4) -ne 'AVI ' -or [Text.Encoding]::ASCII.GetString($b, 24, 4) -ne 'avih') { return -1 }
        $n = [BitConverter]::ToUInt32($b, 48); if ($n -le 0) { return -1 }
        return [int]$n
    } catch { return -1 }
}

function Vram-Ipucu {
    # Yalniz hata YORUMLAMA: kalite ayari/komut degismez. Kesin degil: "olabilir".
    $bulundu = $false
    foreach ($n in @("ham_out_${Ad}_a1.txt", "ham_err_${Ad}_a1.txt", "ham_out_${Ad}_a2.txt", "ham_err_${Ad}_a2.txt")) {
        $p = Join-Path $Dizin $n
        if ((Test-Path -LiteralPath $p) -and (Select-String -LiteralPath $p -Pattern 'failed during weight preparation|ALLOC_FAILED|cannot make enough memory|out of memory|vae decode compute failed' -Quiet)) { $bulundu = $true }
    }
    if ($bulundu) {
        Write-Output 'VRAM yetmedi olabilir (kesin degil): logda bellek ayirma/agirlik hazirlama hatasi var.'
        Write-Output '  Once: diger uygulamalari ve ikinci ekrani kapatin, yeniden deneyin (ekran yuku VRAM tepesini artirir).'
        if ($Kare - 17 -ge 56) { Write-Output ("  Olmazsa daha kisa deneyin: -Kare {0} (56..$KareSabit, 17k+5 gridi). Ayrinti: docs\SIK_HATALAR.md A.1" -f ($Kare - 17)) }
        else { Write-Output '  Ayrinti: docs\SIK_HATALAR.md A.1 (bu kare sayisindan daha kisasi onerilmiyor)' }
    }
}

$script:VramTepe = 0; $script:VramBas = -1; $script:VramTop = -1
$smi0 = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($smi0) {   # baslangic kullanimi (ekrani GPU'ya bagli kartta bosta dolu olabilir) ve toplam; yalniz bilgi
    $q0 = (& nvidia-smi.exe --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if ($q0) { $f0 = @($q0 -split ',' | ForEach-Object { $_.Trim() }); $u0 = 0; $m0 = 0; if ($f0.Count -ge 2 -and [int]::TryParse($f0[0], [ref]$u0) -and [int]::TryParse($f0[1], [ref]$m0)) { $script:VramBas = $u0; $script:VramTop = $m0 } }
}
$t00 = Get-Date
try {
    Write-Output ("uret: {0} kare, {1}x{2}, {3} asama, cikti {4}" -f $Kare, $W, $H, $(if ($IkiAsama) { 2 } else { 1 }), $Cikti)
    if ($Env1.Contains('GGML_CUDA_CUBLAS_COMPUTE_TYPE')) { Write-Output ("bilgi: compute capability {0} >= 7.0: GGML_CUDA_CUBLAS_COMPUTE_TYPE=f32 (uzun videoda siyah kare onlemi; kendiniz ayarlarsaniz dokunulmaz)" -f $GpuCc.ToString([Globalization.CultureInfo]::InvariantCulture)) }
    if ($GpuCc -lt 0 -and $Kare -ge 141 -and -not $env:GGML_CUDA_CUBLAS_COMPUTE_TYPE) { Write-Output 'bilgi: GPU compute capability okunamadi (eski surucu ya da nvidia-smi yok): f32 ayari yapilmadi. RTX 20xx ve ustu kartta 141+ karede video siyah cikarsa GGML_CUDA_CUBLAS_COMPUTE_TYPE=f32 ayarlayip yeniden deneyin (docs\SIK_HATALAR.md).' }
    if ($TekAsama -and $EndImg -and $KucukKart) { Write-Output 'UYARI: -TekAsama + -EndImg 8 GB alti kartta: ilk+son kare tek asamada 56 karede bile VRAM''e sigmadi [olctum 1050 Ti]; -TekAsama olmadan calistirin (iki asama 56 ve 175 karede gecti).' }
    if ($TekAsama -and $Jeton -gt 7680) { Write-Output 'bilgi: -TekAsama: iki asama elle kapatildi; 4 GB kartta bu uzunlukta VAE bellege sigmayabilir (log karolu geri-dususu gosterirse cikti GECERSIZ sayilir).' }
    if (-not $Standart) { Write-Output ("bilgi: {0}x{1} standart disi boyut (olculen ve bayt kanitli tek boyut 640x384; bu boyut 4 GB'da denenmedi)" -f $W, $H) }
    if (Test-Path -LiteralPath $Cikti) { Remove-Item -LiteralPath $Cikti -Force }   # eski avi basari sayilmasin
    $k1 = Asama-Kos '_a1' $Env1
    if ($IkiAsama) {
        if (-not (Test-Path -LiteralPath $Latent) -or (Get-Item -LiteralPath $Latent).Length -lt 1MB) { throw "asama 1 latent yazmadi (cikis $k1); ham_err_${Ad}_a1.txt'e bakin" }
        Write-Output ("asama 1 tamam (latent {0:N1} MB), asama 2 (ayri surec VAE) basliyor" -f ((Get-Item -LiteralPath $Latent).Length / 1MB))
        if (Test-Path -LiteralPath $Cikti) { Remove-Item -LiteralPath $Cikti -Force }
        $k2 = Asama-Kos '_a2' $Env2
        if ($k2 -ne 0) { Write-Output "UYARI: asama 2 cikis kodu '$k2' (tek basina basari olcutu degil; avi + kare sayisi + log denetlenir)" }
        if (-not (Log-Temiz '_a2')) { throw "asama 2 logunda karolu VAE geri-dususu ya da bellek hatasi: cikti GECERSIZ" }
    } else {
        if ($k1 -ne 0) { Write-Output "UYARI: sd-cli cikis kodu '$k1' (tek basina basari olcutu degil; avi + kare sayisi + log denetlenir)" }
        if (-not (Log-Temiz '_a1')) { throw "logda karolu VAE geri-dususu ya da bellek hatasi: cikti GECERSIZ" }
    }
    if (-not (Test-Path -LiteralPath $Cikti) -or (Get-Item -LiteralPath $Cikti).Length -lt 10KB) { throw "cikti dosyasi yok ya da cok kucuk: $Cikti" }
    # BASARI OLCUTU (birlikte): avi var + kare sayisi + log temiz (+ VRAM tepe uyarisi); cikis kodu tek basina olcut degil. [tasarim, gercek kosuda gorulecek]
    $ffprobe = $null; foreach ($c in @((Join-Path $Motor 'ffprobe.exe'), 'ffprobe')) { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g) { $ffprobe = $g.Source; break } }
    $n = -1
    if ($ffprobe) { try { $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $r = & $ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $Cikti 2>$null; $tmp = 0; if ([int]::TryParse(("$r").Trim(), [ref]$tmp)) { $n = $tmp } } catch { } finally { $ErrorActionPreference = $eap } }
    $kaynak = 'ffprobe'
    if ($n -lt 0) { $n = Avi-KareSayisi $Cikti; $kaynak = 'avi basligi' }
    if ($n -ge 0) {
        if ($n -ne $Kare) { throw "kare sayisi $n ($kaynak), beklenen ${Kare}: cikti GECERSIZ" }
        Write-Output "kare sayisi dogrulandi: $n ($kaynak)"
    } else { Write-Output "UYARI: kare sayisi okunamadi (ffprobe yok, avi basligi okunamadi); dogrulanmadi" }
    if ($script:VramTepe -gt 0) {
        if ($script:VramTop -gt 0) { Write-Output ("VRAM tepe (nvidia-smi, tum kart, 5 sn ornek): tepe {0} / toplam {1} MiB, bos {2} MiB, baslangic kullanimi {3} MiB (ekrani GPU'ya bagliysa baslangicta dolu olabilir)" -f $script:VramTepe, $script:VramTop, ($script:VramTop - $script:VramTepe), $script:VramBas) }
        else { Write-Output ("VRAM tepe (nvidia-smi, tum kart, 5 sn ornek): {0} MiB" -f $script:VramTepe) }
        # Esik: bos VRAM <= 296 MiB (4096 MiB kartta eski "tepe >= 3800" ile ayni); toplam okunamazsa eski kural.
        $incemarj = $(if ($script:VramTop -gt 0) { ($script:VramTop - $script:VramTepe) -le 296 } else { $script:VramTepe -ge 3800 })
        if ($incemarj) { Write-Output 'UYARI: bos VRAM 296 MiB ya da alti: ince marj, baska ekran/uygulama yuku varsa sonraki kosu dusebilir (docs\SIK_HATALAR.md A.1)' }
    }
    # ses akisi: model ses uretir (olculen cikti: video + pcm_s16le ses); ffprobe akis listesini okuyabildi ve ses yoksa GECERSIZ. [tasarim, gercek kosuda gorulecek]
    if ($ffprobe) {
        try { $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $tur = @(& $ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $Cikti 2>$null) } catch { $tur = @() } finally { $ErrorActionPreference = $eap }
        $tur = @($tur | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($tur -contains 'video') {
            if ($tur -contains 'audio') { Write-Output 'ses akisi var' } else { throw 'ses akisi yok: cikti GECERSIZ (model ses uretir; ham_out logunu ve istemdeki audio: cumlesini kontrol edin)' }
        } else { Write-Output 'UYARI: ffprobe akis listesini okuyamadi, ses akisi dogrulanmadi' }
    }
    # kalite kapisi: sonuc basari olcutune DAHIL. TAMAM yalniz kapi gecince. Esiklere dokunulmaz (docs\KAPILAR.md). Cikis: 5 = KAPI RED, 6 = kapi calismadi.
    if (-not $Kontrol) {
        $py = $(if ($env:VT_PYTHON) { $env:VT_PYTHON } else { 'python' })
        if (-not (Get-Command $py -ErrorAction SilentlyContinue)) {
            Write-Output ("VIDEO URETILDI ama KAPI CALISMADI (python yok; VT_PYTHON ayarlayin, opencv-python gerekir): klip kabul edilmedi sayilir: {0}" -f $Cikti)
            exit 6
        }
        & powershell.exe -NoProfile -File (Join-Path $PSScriptRoot 'uretim_kapi.ps1') -Dizin $Dizin -Ad $Ad -Kare $Kare -DokuNorm
        $kapiKod = $LASTEXITCODE
        if (-not $Standart) { Write-Output ("UYARI: kalite kapisi esikleri 640x384 icin kalibre; {0}x{1} boyutunda gurultu/N degerleri karsilastirilamaz (yuksek cozunurlukte gurultu dogal olarak dusuk okunur). Videoyu gozle izleyin (docs\KAPILAR.md)." -f $W, $H) }
        if ($kapiKod -eq 6) {
            Write-Output ("VIDEO URETILDI ama KAPI CALISMADI (python'da opencv-python/numpy yok ya da python calismadi; 'py -3 -m pip install opencv-python numpy', VT_PYTHON): klip kabul edilmedi sayilir: {0}" -f $Cikti)
            exit 6
        }
        if ($kapiKod -ne 0) {
            Write-Output 'KAPI RED: klip kabul edilmez, karar kullanicinindir; nedenini docs\KAPILAR.md ve runs\olaylar.txt icinde okuyun (dokulu sahnede sigma-HH ile de bakin).'
            Write-Output 'Kalite kapisi lisans uygunlugunu denetlemez; cikti kullanimi (bolge V.4, AI etiketi A-12, ticari IV) sizin sorumlulugunuzdadir: docs\LISANS_UYARISI.md'
            Write-Output "This gate does not check motion consistency (object scale or position jumps): watch the whole video before accepting it."
            Write-Output 'Bu kapi hareket tutarliligini (nesne olcegi/konum sicramasi) denetlemez: kabul etmeden once videonun tamamini izleyin.'
            exit 5
        }
        Write-Output 'KAPI GECTI'
        Write-Output 'Kalite kapisi lisans uygunlugunu denetlemez; cikti kullanimi (bolge V.4, AI etiketi A-12, ticari IV) sizin sorumlulugunuzdadir: docs\LISANS_UYARISI.md'
        Write-Output "This gate does not check motion consistency (object scale or position jumps): watch the whole video before accepting it."
        Write-Output 'Bu kapi hareket tutarliligini (nesne olcegi/konum sicramasi) denetlemez: kabul etmeden once videonun tamamini izleyin.'
    }
    Write-Output ("TAMAM {0:N0} sn: {1}" -f ((Get-Date) - $t00).TotalSeconds, $Cikti)
    exit 0
} catch {
    Vram-Ipucu
    throw
} finally {
    Remove-Item -LiteralPath $Kilit -Force -ErrorAction SilentlyContinue
}



