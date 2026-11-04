# Desktop: isinya apa, mana yang rusak

Catatan: **desktop ini berubah saat dokumen ini ditulis.** Sesi lain merapikan shortcut Codex
secara paralel. Angka di bawah adalah keadaan **akhir**, dan bagian "Apa yang bergeser" mencatat
urutannya. Kalau ragu, jalankan `bin/desktop-audit` — itu yang otoritatif, bukan berkas ini.

**Sekarang: 19 shortcut, semuanya sehat.** 0 ikon rusak, 0 target hilang. Di tengah penulisan
sempat ada 21 shortcut dengan 4 ikon mati; dua dihapus, dua diperbaiki.

`C:\Users\rahma\Desktop` bukan folder biasa, tapi **junction ke
`C:\Users\rahma\OneDrive\Desktop`**. Jadi menghitung dua-duanya = menghitung berkas yang sama
dua kali. Shell Windows sendiri menunjuk ke `OneDrive\Desktop`.

---

## Tabel lengkap

`ICON` = berkas ikon masih ada? `SINCE` = tanggal `.lnk` terakhir ditulis.

| # | Shortcut | Lokasi | SINCE | Target | ICON |
|---|---|---|---|---|---|
| 1 | antirnrml | User | 2026-10-17 | `chrome_proxy.exe --profile-directory="Profile 5" --app-id=mkgkfabjmjfingffgfnnjeadjgjgbocp` | ok |
| 2 | Antigravity | User | 2026-10-17 | `%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe` | ok |
| 3 | Google Docs | User | 2026-10-28 | `Drive File Stream\launch.bat -open_gdocs_root` | ok |
| 4 | Google Drive | User | 2026-10-28 | `Drive File Stream\launch.bat` | ok |
| 5 | Google Sheets | User | 2026-10-28 | `Drive File Stream\launch.bat -open_gsheets_root` | ok |
| 6 | Google Slides | User | 2026-10-28 | `Drive File Stream\launch.bat -open_gslides_root` | ok |
| 7 | grokbot-local | User | 2026-11-03 | `C:\grokbot-local\launch.cmd` | ok |
| 8 | Laya NPU | User | 2026-11-03 | `%LOCALAPPDATA%\Programs\Laya NPU\Laya NPU.exe` | ok |
| 9 | Orca | User | 2026-10-17 | `%LOCALAPPDATA%\Programs\orca\Orca.exe` | ok |
| 10 | T3 Code (Nightly) | User | 2026-10-22 | `%LOCALAPPDATA%\Programs\t3code\T3 Code (Nightly).exe` | ok |
| 11 | Wonder | User | 2026-10-31 | `%LOCALAPPDATA%\Programs\wonder-client\Wonder.exe` | ok |
| 12 | **Codex** | User | 2026-11-04 20:21 | `powershell.exe` → `\\wsl.localhost\...\cd-d1\scripts\codex-launch.ps1 -Mode real` | ok |
| 13 | **Codex Clone** | User | 2026-11-04 20:22 | `powershell.exe` → `\\wsl.localhost\...\cd-d1\scripts\codex-launch.ps1 -Mode clone` | ok |
| 14 | Comet | Public | 2026-10-30 | `C:\Program Files\Perplexity\Comet\Application\comet.exe` | ok |
| 15 | Google Chrome | Public | 2026-11-04 | `chrome.exe` | ok |
| 16 | Grok Bot | Public | 2026-10-19 | `C:\Program Files\Grok Bot\Grok Bot.exe` | ok |
| 17 | Linear | Public | 2026-10-17 | `C:\Program Files\Linear\Linear.exe` | ok |
| 18 | Microsoft Edge | Public | 2026-11-01 | `msedge.exe` | ok |
| 19 | Pen | Public | 2026-11-01 | `C:\Program Files\Pen\Pen.exe` | ok |

### Temuan lain, di luar Codex

- **Duplikat tujuan:** #3–#6 semuanya `launch.bat` yang sama, hanya beda argumen. Itu wajar
  (Google Drive membuatnya begitu), bukan sampah.
- **`antirnrml.lnk`** ikonnya ada di dalam folder `Web Applications` Chrome Profile 5. Kalau
  profil Chrome itu dihapus, ikonnya ikut hilang. Targetnya sendiri tetap aman — tapi ini satu-
  satunya shortcut non-Codex yang ikonnya bergantung pada sesuatu yang bisa dipindah/dihapus.
- **Bukan shortcut, tapi numpuk:** `proof.html` (770 KB) di Desktop. Artefak, bukan aplikasi.

Dari 15 shortcut non-Codex, **0 ikon rusak** — bahkan saat keempat ikon Codex mati, yang lain
tidak tersentuh. Yang paling rapuh cuma `antirnrml` (lihat di atas).

---

## Kenapa dulu ada empat Codex

Ini pertanyaan aslinya, dan jawabannya masih berlaku sebagai penjelasan: **satu aplikasi, empat
pintu masuk** — dua pasang dari dua percobaan, bukan empat aplikasi.

| Generasi | Pasangan | Launcher yang dipakai |
|---|---|---|
| Pertama, 31 Okt | `Codex.lnk` + `Codex Clone.lnk` | salinan di `C:\Users\rahma\Desktop\codex-launch.ps1` — 13.808 byte, versi 1 Nov 08:23 |
| Kedua, 2 Nov | `Codex Real (repo).lnk` + `Codex Clone (repo).lnk` | `\\wsl.localhost\...\codex-desktop\scripts\codex-launch.ps1` — 16.330 byte |

Generasi kedua ada karena launcher di Desktop ketinggalan: versi repo punya `-Profile`, `-Model`,
`-RealHome`, `-CloneHome`; versi Desktop tidak (dibuktikan `diff`: beda di blok `param` dan di
pemilihan model). Suffix `(repo)` dipakai supaya tidak menimpa pasangan lama — **itu sebabnya
yang lama tidak pernah terhapus.** Nama beda = Windows tidak menganggapnya update.

Mtime membuktikan urutannya: 31 Okt → 2 Nov. Lalu `Codex Clone.lnk` disentuh lagi 4 Nov (masih
menunjuk launcher Desktop yang lama).

Yang benar-benar berbeda antar pintu:

- `Codex.lnk` vs `Codex Real (repo)` → tujuan sama (mode real, `CODEX_HOME=~/.codex`), beda
  launcher. **Redundan.**
- `Codex Clone.lnk` vs `Codex Clone (repo)` → tujuan sama (mode clone, `CODEX_HOME=~/.codex-clone`,
  model `cx/gpt-6.1-sol` lewat 9router). **Redundan.**
- Pasangan lama pakai `-WindowStyle Hidden`; yang `(repo)` tidak. Bedanya cuma jendela PowerShell
  sempat berkedip.

### Set minimal

| Kebutuhan | Shortcut |
|---|---|
| Dua-duanya dipakai (akun asli **dan** BYOK/9router) | **2**: `Codex` + `Codex Clone` |
| Hanya clone/BYOK | **1**: `Codex Clone` |

Sekarang desktop sudah menyusut ke set ini: `Codex Real (repo)` dan `Codex Clone (repo)` sudah
tidak ada. **Tapi `Codex Clone.lnk` sekarang menunjuk launcher di `cd-d1`, bukan `codex-desktop`.**
`cd-d1` adalah worktree lain dari repo yang sama (`scripts/codex-launch.ps1` isinya identik, md5
`a2597153…` sama dengan `cd-d11`). Itu bukan kesalahan — tapi artinya **shortcut ini menunjuk ke
salinan repo, bukan ke repo utama**, dan ikut mati kalau `cd-d1` dihapus.

Launcher di `C:\Users\rahma\Desktop\codex-launch.ps1` (13.808 byte) kini **tidak dipakai siapa
pun**: dua shortcut lama yang memakainya sudah hilang. Boleh dihapus, atau disimpan sebagai
arsip versi lama.

### Apa yang bergeser saat dokumen ini ditulis

Terukur langsung, bukan dugaan — sesi lain mengerjakannya bersamaan:

| Waktu | Kejadian | Bukti |
|---|---|---|
| 20:0x | 21 shortcut, 4 ikon Codex mati | audit: `21 shortcuts \| 4 missing icon` |
| 20:21–20:22 | `Codex Real (repo)` + `Codex Clone (repo)` dihapus; sisa dua diarahkan ke `cd-d1` | mtime kedua `.lnk` = 20:21 / 20:22 |
| 20:2x | `Codex Clone` masih mati, `Codex` sudah hidup | audit: `ICON-MISSING` hanya di `Codex Clone` |
| akhir | keduanya hidup | audit: `19 shortcuts \| 0 missing icon`, `verdict: healthy` |

Yang **tidak** ikut berubah: `Codex Clone.lnk` tetap menunjuk `cd-d1`, bukan `cd-d11` tempat
dokumen ini ditulis.

---

## Kenapa ikonnya sempat hilang

Keempat shortcut lama menunjuk ke:

```
C:\Program Files\WindowsApps\OpenAI.Codex_26.1027.3384.0_x64__2p2nqsd0c76g0\...
```

Versi yang terpasang sekarang **26.1029.7803.0**. Folder lama sudah tidak ada. MSIX menaruh versi
**di dalam nama folder**, jadi setiap update Store memindahkan seluruh isinya dan setiap ikon yang
menunjuk ke sana langsung mati. Itu yang terjadi 4 Nov: keempat ikon mati serentak.

- Launcher **selamat**: kalau path hard-code-nya meleset, ia bertanya ke `Get-AppxPackage` dan
  pakai `InstallLocation` yang baru.
- Ikon **tidak selamat**: `.lnk` hanya menyimpan string path mati. Tidak ada fallback.

Sekarang keduanya sudah diperbaiki ke `26.1029.7803.0`. **Itu benar hari ini, dan akan rusak lagi
di update Codex berikutnya** — karena masih menempel ke folder berversi:

| Shortcut | IconLocation sekarang |
|---|---|
| `Codex` | `...26.1029.7803.0...\app\ChatGPT.exe,0` |
| `Codex Clone` | `...26.1029.7803.0...\app\resources\chatgpt-app-light.ico,0` |

Itu juga jawaban "kenapa tidak ada shortcut `.exe` dengan ikon": **tidak ada satu pun shortcut yang
menunjuk `.exe` Codex langsung.** Semuanya lewat `powershell.exe` + launcher, karena app MSIX butuh
`CODEX_HOME` dan `CODEX_ELECTRON_USER_DATA_PATH` diset sebelum jendelanya dibuka — klik
`ChatGPT.exe` langsung membuka jendela dengan home yang salah. Jadi pintu masuk berupa launcher itu
wajar; yang salah cuma **ikonnya ditempel ke folder berversi**.

### Perbaikan yang tahan update (sekali saja)

Salin ikon **keluar** dari `WindowsApps` ke path yang tidak berubah. Sumber terbaik sudah ada di
repo: `app/build/icon.png` (1024×1024).

```powershell
Add-Type -AssemblyName System.Drawing
$png = '\\wsl.localhost\Ubuntu\home\rahman\projects\manef\cd-d11\app\build\icon.png'
$dir = "$env:USERPROFILE\.codex-shortcuts"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$ico = Join-Path $dir 'codex.ico'
$tmp = [System.Drawing.Image]::FromFile($png)
$bmp = New-Object System.Drawing.Bitmap 256, 256
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = 'HighQualityBicubic'
$g.DrawImage($tmp, 0, 0, 256, 256)
$g.Dispose(); $tmp.Dispose()
$h = $bmp.GetHicon()
$i = [System.Drawing.Icon]::FromHandle($h)
$fs = [System.IO.File]::Create($ico)
$i.Save($fs); $fs.Close()
$bmp.Dispose()
"icon: $ico"
```

Sudah diuji: menghasilkan `codex.ico` 41.086 byte, terbaca balik 256×256. Lalu arahkan
`IconLocation` ke `%USERPROFILE%\.codex-shortcuts\codex.ico,0`. Setelah itu update Codex tidak
akan menyentuhnya lagi.

`.ico` bawaan app juga ada, tapi tetap di dalam `WindowsApps`, jadi tetap akan rusak di update
berikutnya. Yang tersedia di versi sekarang (sudah diukur): `chatgpt-app-light.ico` 96×96,
`chatgpt-app-dark.ico` 96×96, `icon-chatgpt.ico` 64×64, `chatgpt-tray-light.ico` 64×64. Tidak ada
yang 256×256 — itu sebabnya PNG repo lebih baik sebagai sumber.

### Setelah update Codex

```powershell
$app = Get-AppxPackage -Name OpenAI.Codex
$app.InstallLocation
```

Kalau tetap mau ikon dari app, perbarui `IconLocation` ke
`"$($app.InstallLocation)\app\resources\chatgpt-app-light.ico,0"` setiap kali versi berubah.
Kalau ikon sudah disalin ke `.codex-shortcuts`, **tidak ada yang perlu dikerjakan**.

Launcher tidak perlu diubah: `scripts/codex-launch.ps1` sudah resolve lewat `Get-AppxPackage`.

---

## `bin/desktop-audit`

```bash
bin/desktop-audit            # tabel + verdict
bin/desktop-audit --json     # data mentah
```

Per shortcut ia memeriksa tiga hal, bukan satu: **ikon** ada, **target** ada, dan **skrip** yang
disebut di argumen ada. Yang ketiga penting karena target semua shortcut Codex adalah
`powershell.exe` — selalu "ada" — sementara launcher yang benar-benar dipanggil bisa saja sudah
tidak ada. Tanpa cek ketiga, shortcut yang mati total akan tampak sehat.

Exit `0` = semua resolve. Exit `1` = ada yang rusak, path-nya dicetak. Exit `2` = tidak bisa
mengukur (bukan Windows / `powershell.exe` tidak ada) — bukan PASS.

Read-only: hanya membaca `.lnk`. Tidak pernah menulis shortcut, tidak pernah menjalankan apa pun.
