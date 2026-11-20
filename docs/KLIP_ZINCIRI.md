# Klip Zincirleme Rehberi / Clip Chaining Guide (TR + EN)

> **TR:** Upstream VideoTurko tek geçişli (≤209 kare, 8.7 sn) kliplere odaklanır. Bu rehber, RTX 5060 (`sm_120`) üzerinde `--init-img` ile ardışık 8 saniyelik klipleri üretip `ffmpeg` ile dikişsiz birleştirmek için pratik kuralları özetler.
>
> **EN:** Upstream VideoTurko focuses on single-pass clips (≤209 frames, 8.7 s). This guide summarizes practical rules for generating sequential 8-second clips via `--init-img` on RTX 5060 (`sm_120`) and stitching them cleanly with `ffmpeg`.

---

## 1. Motor Sınırları / Engine Limits
- **Kare ızgarası / Frame grid:** `17k + 5` (5, 22, 39, 56 … 192, 209).
- **Üst sınırlar / Maximums:** Metinden en fazla **209 kare (8.7 s)**; `--init-img` ile en fazla **192 kare (8.0 s)**.
- **Biçim / Format:** 640×384, 24 fps, gömülü ses (ayrı TTS yok).
- **RTX 5060 (`sm_120`) süreleri / Timings:** 56 kare ≈ 2 dk, 192 kare (`init_image`) ≈ 6.3–7.0 dk, 209 kare ≈ 6 dk. Tek GPU → aynı anda tek iş.

---

## 2. Sıralı Üretim Akışı / Sequential Workflow
1. **Klipleri sırayla üretin / Generate sequentially:** Bir klip tamamlanıp kalite kapısını (`KAPI GECTI`) ve kare paftasını (`pafta_video.png`) gözle kontrol etmeden sonraki klibi başlatmayın.
2. **Sahne sığmazsa / If the action does not finish in one clip:** Aynı klibin uygun bir son karesinden ikinci parça üretip devam edin.
3. **Resimden video hazırlığı / Image-to-video prep:** Kaynak görseli 5:3 oranına kırpıp 640×384 ölçekleyin; yüzleri ve ana öğeleri kadrajda tutun, kırpımı gözle doğrulayın:
   ```powershell
   ffmpeg -i in.png -vf "crop=W:H:x:y,scale=640:384" ref.png
   ```
   Önce 56 karelik hızlı deneme yapın, uygunsa 192 kareye geçin. Telifli görsel ve gerçek kişi yüzlerinin sorumluluğu kullanıcıdadır.

---

## 3. Devir Karesi (`init_image`) Seçimi / Handoff Frame Selection
- **Varsayılan / Default:** Önceki klibin son karesi:
  ```powershell
  ffmpeg -sseof -0.05 -i klip1.avi -frames:v 1 -update 1 son.png
  ```
- **Son kare kötüyse / If the last frame is poor** (yüz kadraj dışında, karakter kameraya yapışmış vb.): Daha erken temiz bir kare seçin (`-ss <t>`), aday kareleri gözle karşılaştırın ve montajda önceki klibi tam o saniyede kesin.

---

## 4. İstem ve Ses Kuralları / Prompt & Audio Rules
- Her klipte sahneyi, karakter tarifini, ışığı ve kamera dilini tekrarlayın; **yalnızca olayı ilerletin**.
- Uzun kamera hareketlerini adım adım yazın (örn. yükselir → aşağı bakar → hedefe süzülür).
- Kadrajı açıkça belirtin (örn. geniş plan, iki figür de kadrajda).
- Konuşma/müzik istenmiyorsa her klipte ses cümlesini ekleyin:
  ```text
  Audio: <ambient sounds> only, no dialogue, no speech, no voices, no music.
  ```
- Aynı `seed` ile tutarlılık koruyun; etkileşim tutmazsa farklı `seed` deneyin veya hareketi iki parçaya bölün.

---

## 5. `ffmpeg` ile Birleştirme / Stitching with `ffmpeg`
- **İlk kareyi at / Drop duplicate first frame:** Devam klibi önceki klibin son karesiyle başlar; video için `trim=start_frame=1`, ses için `atrim=start=0.0417` (1/24 sn) uygulayın.
- **Bağlama / Concat & audio crossfade:** Videoyu `concat`, sesi `acrossfade=d=0.25` (veya `0.3`) ile bağlayın. Tüm akışlarda `setpts=PTS-STARTPTS`, gerekirse `fps=24,settb=1/24` ve `aresample=48000` kullanın.
- **Model ilk karede atlarsa / First-frame jump recovery:** Model `init_image`'ı sürdürmeyip başka bir açıdan başlarsa, yeni klipte önceki klibin son karesine en yakın kareyi (`N`) bulun; klibi `trim=start_frame=N` / `atrim=start=N/24` ile kesip `xfade=transition=fade:duration=0.333` ile bağlayın ve ek noktasını ±1 sn kare dizisiyle doğrulayın.
- **İsteğe bağlı hız rampası / Optional speed ramp:** Model hızlanmayı zayıf yaptıysa:
  ```text
  setpts='if(lt(T,2),T,2+(log(1+(T-2)/6)*6))/TB',fps=24
  ```
  (2. saniyeden sonra kademeli 2× hızlanma; sesi hızlandırmayın, yeni uzunluğa kırpıp sonunda `afade` ile kısın.)
- **Ses seviyesi ve çıkış / Loudness & export:** Tüm birleşik sese tek seferde `loudnorm=I=-23:TP=-2:LRA=11` uygulayın; standart çıkış:
  ```powershell
  -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -b:a 160k -ar 48000
  ```

---

## 6. Doğrulama Kontrol Listesi / Verification Checklist
- **Kalite kapısı / Gate:** `runs/olaylar.txt` son satırı `KAPI GECTI` (`gurultu <= 1.5`, `orta_akis > 0.05`). `gurultu=0` ve `orta_akis=0` siyah video demektir.
- **Ek noktası paftası / Seam contact sheet:**
  ```powershell
  ffmpeg -ss <t> -t 1.6 -i final.mp4 -vf "fps=10,scale=160:96,tile=8x2" -frames:v 1 ek.png
  ```
- **Süre / Duration:** `ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 final.mp4`
- **Ses seviyesi / Loudness:** `ffmpeg -i final.mp4 -af ebur128=peak=true -f null -` (hedef ≈ −23 LUFS, tepe < −2 dBFS).
- **İstenmeyen konuşma kontrolü (isteğe bağlı) / Optional speech check:** `faster_whisper` (`tiny`, CPU, `vad_filter=True`) ile konuşmasız sahnelerde 0 segment doğrulaması.
