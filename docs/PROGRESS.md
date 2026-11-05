# Progress — Codex Desktop ↔ 9router

Catatan kerja, bukan dokumentasi produk. Ditulis supaya sesi berikutnya tidak mengulang
penyelidikan yang sama. Repo produk ada di `/home/rahman/projects/lara/codex-clone-placeholder`;
berkas ini soal setup mesin, bukan repo.

Terakhir diperbarui: 2026-11-05, setelah `bin/codex-instruct` (bagian 10) dan `bin/codex-doctor` (bagian 11).

## Status ringkas

| hal | status |
| --- | --- |
| Dua mode (ChatGPT asli / clone 9router) | ✅ jalan, terbukti terpisah |
| Isolasi home clone | ✅ **selesai & terverifikasi** — 0 junction, 0 kebocoran sesi |
| Clone dijalankan setelah swap | ✅ **terverifikasi** — 11 sesi di home clone, model default `cx/gpt-6.1-sol` |
| Tool calling di 9router | ✅ exec, apply_patch, MCP, parallel |
| Sub-agent di 9router | ✅ pakai `cx/gpt-6.1-sol` |
| Gambar/screenshot di 9router | ⚠️ hanya `cx/*`; `ctx/*` **tidak stabil** (1/3 run menjawab, sisanya berhenti tanpa jawaban). Mekanisme lama — swap ke kimi + base64 jadi teks — **tidak tereproduksi** (5i) |
| `Access is denied` plugin cache | ✅ **selesai** — `chrome@openai-bundled` dimatikan di clone (5g) |
| Browser in-app | ⛔ tak ada app host |
| Computer use | ⛔ butuh allowlist per-app di UI |
| Kunci model & sandbox terhadap overwrite app | ✅ **launcher re-assert tiap run** |
| Error "full access" | ✅ **selesai** — probe `danger-full-access` PASS 204ms (5e) |
| Banner "couldn't check Windows setup" | ⚠️ **kosmetik, sengaja dibiarkan** — registry ikat provisioning ke `.codex`; jangan disentuh (5c) |
| Thread lama beracun (`ping`) | ✅ di-archive; model per-thread menang atas config |

## 1. Dua mode, satu binary

Codex Desktop (MSIX `OpenAI.Codex 26.1029.7803.0`) membaca home dari `CODEX_HOME`, fallback
`homedir()/.codex`. Tiga hal wajib berpasangan:

| hal | fungsi |
| --- | --- |
| `CODEX_HOME` | di mana `config.toml`, sessions, sqlite dibaca |
| `CODEX_ELECTRON_USER_DATA_PATH` | user-data dir sendiri → `requestSingleInstanceLock` cakupan terpisah |
| `--user-data-dir=<dir>` | **wajib di command line** |

Tanpa `--user-data-dir`, `Start-Process` menabrak Chromium `ProcessSingleton` dan keluar
dalam ~0.15 s sambil meneruskan peluncuran ke instance lama — env var diabaikan total.
Dibuktikan, bukan dugaan.

## 2. Isolasi home clone — SELESAI

Desain pertama memakai 16 junction dari `~/.codex` ke `~/.codex-clone`. Itu **bug aktif**:
sesi clone masuk ke riwayat ChatGPT asli (terbukti, satu rollout `01a192a3` lahir di sana
22:46 saat clone jalan), sqlite bercampur, log saling baca.

Sekarang:

| hal | nilai |
| --- | --- |
| `~/.codex` (asli) | 193 rollout, 6 sqlite, 2031 file plugins, 2.3 GB — **utuh** |
| `~/.codex-clone` | 664 MB, **0 junction**, sesi & sqlite sendiri (3 masing-masing) |
| catalog | disalin ke dalam clone (5.0 MB), `oc/*` disembunyikan |
| config clone | `model = "ctx/conextlab/ollama/deepseek-v4.1-flash:cloud"`, `model_provider = "nine_router"`, `model_catalog_json` menunjuk **ke dalam** clone |

Yang disalin ke clone: `plugins` (2031 file), `skills`, `nine-router-models.json`.
Yang dibiarkan kosong: `sessions`, `sqlite`, `cache`, `tmp`, `browser` — itu state per-mode.

Swap dilakukan dengan `C:\Users\rahma\codex-clone-swap.ps1`, yang menghapus junction secara
non-rekursif (`[IO.Directory]::Delete($p,$false)`) lalu hard-assert nol reparse point sebelum
`Remove-Item -Recurse`. Target junction (home asli) tidak pernah ditelusuri. Backup launcher:
`AppData\Local\Temp\codex-iso\codex-launch.ps1.bak-20261031-224409`.

## 3. Kapabilitas terverifikasi

| kapabilitas | ChatGPT | 9router | catatan |
| --- | --- | --- | --- |
| chat | ✅ | ✅ | |
| exec / shell | ✅ | ✅ | |
| file write+read | ✅ | ✅ | |
| `apply_patch` | ✅ | ✅ | diverifikasi isi file, bukan klaim model |
| artifact HTML | ✅ | ✅ | skill `visualize`, bukan tool |
| parallel tools | ✅ | ✅ | ChatGPT `multi_tool_use.parallel`; 9router `Promise.allSettled` di `exec` |
| sub-agents | ✅ | ✅ | **hanya** kalau upstream OpenAI-native (`cx/*`) |
| web search | ✅ | ❌ | hosted tool, tak ada padanan |
| clock | ✅ | ❌ | namespace tool |
| browser in-app | ⛔ | ⛔ | `The browser access host is unavailable` — tak ada app host |
| computer use | ⛔ | ⛔ | CUA hidup, ditolak per-app ("not approved to use Notepad") |

## 4. Temuan teknis yang menentukan

**Namespace diratakan.** Translator Responses→Chat-Completions 9router mengubah seluruh
`collaboration` namespace menjadi satu fungsi opaque sebelum model melihatnya. Member asli
utuh di request (6 buah: `followup_task`, `interrupt_agent`, `list_agents`, `send_message`,
`spawn_agent`, `wait_agent`), tapi model tak pernah menerimanya. Model lalu memanggil
`collaboration` → `unsupported call: collaboration`.

Bukti: namespace sintetis satu member unik (`zz_echo`) ke tiga upstream di gateway sama.
`cx/gpt-6.1-sol` mengenali member; `ag/claude-opus-5-5` dan `ag/gemini-3.8-flash` tidak.

Titik gagal: `open-sse/translator/request/openai-responses.js` ~baris 183 — `type:"namespace"`
punya `name` tapi tak punya cabang `tools`, jadi jatuh ke jalur function dengan schema kosong;
`formats/gemini.js` `addPlaceholders` mengisi schema kosong itu dengan `{"reason":...}` —
persis argumen yang muncul di log.

**Dua field katalog yang menanggung tool calling:**

```json
"tool_mode": "code_mode_only",
"use_responses_lite": false
```

Tanpa itu, chat tetap jalan tapi semua tool mati.

**`--sandbox workspace-write` membunuh MCP.** Setiap panggilan jadi
`requires approval, but approval policy is never`. Profil harus `danger-full-access`.

**`oc/*` kuota habis.** Semua `oc/*` balas `429 FreeUsageLimitError`, `retry-after` ~30k detik.
Itu kuota akun OpenCode milik gateway, bukan kunci kita. `cx/*` dan `combo` normal (200).
Ketiganya kini `visibility: "hide"` di katalog.

**App bisa menulis ulang baris `model`.** Setelah satu peluncuran, app menimpa `model` di
`config.toml` sesuai pilihan UI terakhir. Config saja tidak cukup mengunci model — sudah
terjadi di home clone lama (jadi `ctx/ollama/deepseek-v4.1-flash:1017-cloud`).

**Katalog default = `priority: 0`.** Sebelumnya `ag/claude-opus-5-5` di prio 0 (mahal/rusak),
lalu `cx/gpt-6.1-sol`. Sejak 2026-11-01 prio 0 =
`ctx/conextlab/ollama/deepseek-v4.1-flash:cloud`, dipatok lewat `DEFAULT_MODEL` di
`codex-9router-catalog` supaya regen tidak menggesernya diam-diam.

**Unauth `GET /v1/models` = 401.** Middleware 9router 0.5.104 kini mewajibkan bearer untuk
semua path `/v1*`. Bukan regresi di sisi app.

## 5. Yang belum

1. ~~`codex-caps-quicktest` belum dijalankan penuh sejak katalog diubah.~~ **SELESAI 2026-11-01**
   — lihat 5h, dan 5i untuk probe gambar. Verdict `22 passed, 0 failed, 6 skipped`.
2. ~~`Access is denied (os error 5)` pada refresh plugin cache `chrome@openai-bundled`.~~
   **SELESAI** — akar dan perbaikannya di 5g.
3. Bearer token 9router masih plaintext di profil dan sudah muncul di transkrip — rotasi belum.
4. ~~Probe `codex-caps-quicktest` menulis ke home asli.~~ **SELESAI 2026-11-01** — sisi 9router
   kini pakai `~/.codex-probe`; sisi chatgpt tak bisa dipindah (5i).
5. **Turn bergambar lewat UI belum pernah diuji di `.codex-clone`.** Jalur CLI sudah terbukti
   dan punya probe sendiri (5i). Attach-gambar dari composer app belum. Config clone sudah
   kembali ke `cx/gpt-6.1-sol` (dicek 2026-11-01 21:26).
6. **Klaim 5f soal `ctx/*` perlu dianggap tidak stabil, bukan mutlak.** Lihat koreksi di 5i:
   `ctx/*` menerima gambar, tapi 2 dari 3 run gagal tanpa jawaban.

## 5h. `qcheck` penuh 2026-11-01 — verdict apa adanya

Dijalankan dari repo, log mentah: `parity-evidence/qcheck-2026-11-01.txt` (92 baris). Exit 0.

```
########## verdict ##########
  clone : ok
  codex : ok
  caps  : ok
```

| sisi | hasil |
| --- | --- |
| clone (`codex-clone-placeholder` @ `14fda46`) | 14 passed, 0 failed |
| codex real | 5 passed, 0 failed (chatgpt: chat+exec, mcp SKIP tanpa server) |
| caps | 20 passed, 0 failed, 6 skipped (22 after the image probe, 5i) |

Caps — run penuh pertama sejak katalog berubah:

| kapabilitas | ChatGPT | 9router |
| --- | --- | --- |
| chat, exec, file write+read, `apply_patch`, artifact html, parallel tools | PASS | PASS |
| sub-agents | PASS | **PASS** |
| web search, clock | PASS | SKIP (hosted / namespace) |
| browser in-app, computer use | SKIP | SKIP |

Assertion disk tetap yang menentukan, bukan ucapan model: `cap-patch.txt` = `CAP-PATCH-OK`,
`cap-visual.html` memuat `CAP-VISUAL-OK`. Sub-agent PASS di 9router konsisten dengan profil
`cx/gpt-6.1-sol` (5f) — bukan bukti baru soal gateway, hanya konfirmasi bahwa pin itu bertahan.

**Temuan sampingan, belum diperbaiki:** `.codex-clone/config.toml` baris 31 =
`model = "ctx/ollama/deepseek-v4.1-flash:1017-cloud"`, ditulis 10:57 — sesudah launcher terakhir
jalan 08:23. Launcher menegakkan `cx/gpt-6.1-sol` tiap run, jadi luncuran clone berikutnya
memulihkan sendiri. Tapi **sekarang** home clone sedang terpaku ke `ctx/*`; lihat 5i untuk apa
yang benar-benar rusak di jalur itu. `Set-CloneWindowsSandboxElevated` dan
`Set-ClonePluginDisabled` sudah benar sekarang (`sandbox = "elevated"`,
`chrome@openai-bundled enabled = false`).

**Launcher hidup ≠ launcher repo.** `C:\Users\rahma\OneDrive\Desktop\codex-launch.ps1` masih
hard-code `C:\Users\rahma\.codex` / `.codex-clone`; versi repo menerima `-RealHome`/`-CloneHome`.
Perilakunya identik, jadi tidak ada yang perlu diperbaiki — sudah tercatat di bagian Rollback
handover.

## 5i. Turn bergambar — probe baru, dan koreksi atas 5f (2026-11-01)

### Probe

`codex-caps-quicktest` sekarang punya `probe_image`, dijalankan untuk kedua provider. Fixture
dibuat saat itu juga oleh `scripts/mk-probe-image.ps1`, bukan file yang di-commit:

| hal | nilai |
| --- | --- |
| ukuran | 1093 × 6000 px, ~1,05 MB |
| isi | 6000 px teks lorem + satu baris penanda 6 karakter acak, digambar sebagai piksel |
| klaim yang diuji | penanda tercetak `CAP-IMAGE: <6 char>` dan turn selesai |

Ukuran itu **load-bearing**, bukan hiasan. Percobaan pertama saya memakai PNG 900×300 (3 pita
warna); PNG kecil itu lolos di **semua** upstream, termasuk `ctx/*` yang di 5f disebut rusak.
Probe sekecil itu akan PASS tepat pada insiden yang seharusnya ia tangkap. Pita warna juga
bisa ditebak; penanda 6 karakter acak tidak.

Dua jebakan yang termakan waktu:

- `-i` bersifat variadic. Prompt tanpa `--` dimakan sebagai path gambar kedua, dan Codex lalu
  menunggu prompt dari stdin (`No prompt provided via stdin`, exit 1).
- `-c model=ctx/...` **tanpa** `-p 9router` tidak menguji gateway sama sekali: provider jatuh
  ke `openai`, lalu `ERROR: The 'ctx/...' model is not supported when using Codex with a
  ChatGPT account`. Override model harus selalu berpasangan dengan profil.

### Hasil, 3 run per model pada fixture yang sama

| model | hasil | token | catatan |
| --- | --- | --- | --- |
| `cx/gpt-6.1-sol` | **3/3 PASS** | ~17,3k | penanda benar |
| `ctx/...deepseek-v4.1-flash:cloud` | **1/3 PASS** | 10,9k gagal; 256k gagal | tidak deterministik |

Jadi probe ini gate yang sah untuk `cx/*` (default yang dikirim), dan smoke test di `ctx/*`.

Setelah probe ditambahkan, `codex-caps-quicktest` penuh: **22 passed, 0 failed, 6 skipped**
(log: `parity-evidence/caps-2026-11-01-images.txt`), yaitu 20 sebelumnya + `images (CLI -i)` di
kedua provider.

### Isolasi probe — 2026-11-01

Probe dulu menulis ke home asli: `~/.codex/sessions` naik 209 → 366 dalam satu sesi. Itu
melanggar CONTRACT §1 dan §13 (jangan sentuh akun asli saat menguji clone). Sekarang:

| sisi | `CODEX_HOME` | bisa diisolasi? |
| --- | --- | --- |
| 9router (`-p 9router`) | `~/.codex-probe` | **ya** — profil disalin saat pertama jalan |
| chatgpt | `~/.codex` | **tidak** — butuh `auth.json` home itu |

Sesudah perbaikan, 12 rollout baru semuanya `model_provider: openai` (sisi chatgpt); sisi 9router
pindah ke probe home (21 → 41 file). Jadi sisa kebocoran itu **hanya** sisi yang memang tak bisa
dipindah.

Dua jebakan yang muncul saat memindahkan home:

1. `CODEX_HOME` di-prefix sebagai `\$env:...` (backslash literal), jadi tidak pernah ter-set dan
   probe tetap menulis ke home asli. Sekarang di-`printf '%s'` dengan tanda kutip tunggal.
2. **`--sandbox workspace-write` diam-diam jadi `read-only`** kalau home bukan home terdaftar —
   persis konsekuensi 5c. Gejalanya `apply_patch` gagal dengan "writing is blocked by read-only
   sandbox", dan `apply_patch (on disk)` FAIL padahal model mengklaim sudah menulis. Karena itu
   sisi 9router memakai `danger-full-access` (sama seperti clone sebenarnya berjalan), sisi
   chatgpt tetap `workspace-write` karena home-nya memang yang terdaftar.

`codex-real-quicktest` **tidak** diubah: ia memang harus menguji profil asli, salinan akan
membuktikan hal lain. Konsekuensinya sisi itu tetap menambah riwayat akun asli.

### Koreksi 5f

5f menyatakan gambar di jalur non-OpenAI "model DIGANTI ke kimi" dan "base64 jadi teks". Kedua
klaim itu **tidak tereproduksi** di sini, dan yang kedua terbukti salah sebagaimana dirumuskan:

| klaim 5f | yang terukur sekarang |
| --- | --- |
| model diganti ke `kimi-k2.7-code` | `kimi` **0 kemunculan** di rollout; `model = ctx/...` bertahan |
| base64 ditokenisasi sebagai teks, ~2,63 juta token | tidak ada `prompt too long`; satu run justru 10,9k token |
| "gambar hilang bentuknya" | `input_image` **ada** di rollout (1–2 kemunculan), dan model bisa menyebut penanda |

Yang benar-benar terjadi, dan berulang:

- Run 1 (1093×6000): model memanggil `view_image` (fallback baca file dari disk), output tool
  1 karakter, `task_complete` dengan `last_agent_message: null` — **tidak menjawab sama sekali**.
  10.663 ms, 10.943 token.
- Run 2 (fixture sama, prompt sama): model **melihat** gambar dan menyebut `WRANG8` di
  penalarannya, lalu berputar-putar dan berhenti di **256.454 token** tanpa jawaban.
- Run 3: lolos biasa.

Pola yang konsisten: `ctx/*` **menerima** gambar, lalu kadang memburuk. Bukan penukaran model
diam-diam, bukan tokenisasi base64. Instabilitasnya sendiri adalah masalahnya.

Angka 5f yang tetap berdiri: `cx` ~17,2k vs 17,3k di sini, dan 11 gambar/12,5 MB → 30.361 token
di jalur yang benar. Kesimpulan praktisnya tidak berubah — **pakai `cx/*` untuk gambar** — tapi
alasannya harus ditulis ulang, bukan diwarisi.

### Yang masih belum

Attach gambar dari **composer app** tetap belum diuji; probe ini lewat CLI `-i`. Jalur CLI
terbukti, jalur UI belum. Kalau mau menguji itu, launch clone lewat launcher dulu supaya
config-nya kembali ke `cx/gpt-6.1-sol`.

## 5c. Banner "couldn't check Windows setup" — akar sebenarnya di REGISTRY

> Koreksi 2026-11-01. Versi pertama bagian ini menyimpulkan `[windows] sandbox = "unelevated"`
> adalah akar dua error UI. Itu **salah**. Nilai itu memang bug nyata dan sudah diperbaiki,
> tapi ia bukan penyebab banner. Akar sebenarnya ada di registry, lihat di bawah.

### Temuan 2026-11-01 — provisioning sandbox terikat satu home

```
HKLM\SOFTWARE\OpenAI\Codex\WindowsSandboxService
  ProvisionedInstallation = {"user_sid":"S-1-5-21-1652117246-2304113080-3517840931-1001",
                              "codex_home":"\\\\?\\C:\\Users\\rahma\\.codex",
                              "session_id":20,
                              "desktop_installation":{"cache_home":"C:\\Users\\rahma\\.cache"}}
```

Satu nilai, tanpa subkey, per user SID. Layanan `CodexSandboxService.OpenAI.Codex` mengikat
provisioning ke **satu** `CODEX_HOME`. Pemanggil dari home lain ditolak. String yang relevan
di `codex.exe`: `registered Core setup belongs to another Codex home`,
`belongs to another owner`, `managed runtime account changed; retry setup`.

**Mana yang putus, dengan bukti pemisah.** Log clone memuat:

```
23:41:07 TRACE app-server request: windowsSandbox/readiness request_id="...:176ab216"
23:41:07 TRACE app-server request: windowsSandbox/setupStart request_id="...:07669f68"
23:41:07 TRACE app-server event:   windowsSandbox/setupCompleted targeted_connections=1
23:48:27 TRACE app-server request: windowsSandbox/setupStart request_id="...:cd5c5f24"
23:48:27 TRACE app-server event:   windowsSandbox/setupCompleted targeted_connections=1
```

`setupCompleted` **ada**. Jadi `codex-windows-sandbox-setup.exe` jalan sampai selesai — bukan
exe-nya yang gagal. Yang menolak adalah `windowsSandbox/readiness` sesudahnya: layanan
membandingkan home pemanggil dengan home terdaftar, tak cocok, balas gagal. UI lalu merender
`codex.windowsSandboxBanner.readinessError` → "Couldn’t check Windows setup / Try again to
continue Windows setup". Home asli hanya memanggil `readiness` (17×) dan tak pernah
`setupStart`, karena home-nya yang terdaftar.

Bukan ACL: `Get-Acl` pada `.codex` dan `.codex-clone` identik (empat ACE sama).
Bukan `cap_sid`: strukturnya sama, isinya SID turunan per-home.
Bukan `[windows] sandbox`: `elevated` di kedua home sejak `Set-CloneWindowsSandboxElevated`.

### Keputusan: banner dibiarkan

Menulis `ProvisionedInstallation.codex_home` ke `.codex-clone` akan memindahkan provisioning
ke clone dan **mencabut sandbox dari Codex asli** — persis yang dilarang. Untuk banner yang
tidak menghalangi eksekusi, itu tidak sepadan. Registry **tidak disentuh**.

Banner ini kosmetik: ia menguji lapisan sandbox Windows, sedangkan clone berjalan dengan
`sandbox_mode = "danger-full-access"` yang tidak memakai lapisan itu. Kemampuannya sudah
dibuktikan terpisah, lihat 5e.

**Jangan coba lagi.** Jangan bedah `codex.exe` untuk mencari jalan memotong
`windowsSandbox/readiness`, jangan sentuh registry, jangan pindahkan provisioning. Jalur itu
sudah ditelusuri sampai dasar dan sengaja ditutup.

### Yang tetap diperbaiki dari versi pertama

App menambahkan `[windows] sandbox = "unelevated"` ke config clone sendiri; profil sumber
`~/.codex/9router.config.toml` tak punya blok `[windows]`. Nilai itu tetap harus `elevated`.
Perbaikannya di launcher, bukan sekali tulis di config, karena app akan menambahkannya lagi:

| fungsi launcher | yang dijaga |
| --- | --- |
| `Set-CloneWindowsSandboxElevated` | `[windows] sandbox = "elevated"` |
| `Set-CloneModel` | top-level `model = "ctx/conextlab/ollama/deepseek-v4.1-flash:cloud"` + `model_provider = "nine_router"` |

Keduanya idempoten, hanya menyentuh key-nya sendiri, tak pernah menulis ulang file utuh, dan
jadi **no-op senyap** kalau nilainya sudah benar. `-Mode real` tak pernah memanggilnya.
Model juga pernah tertimpa app, dan itu sudah tertutup oleh `Set-CloneModel`.

## 5d. Jebakan baru: model **per-thread** menang atas config

`state_5.sqlite` tabel `threads` menyimpan `model`, `reasoning_effort` dan `approval_mode`
**per thread**. Membuka thread lama memakai nilai yang tersimpan di baris itu, bukan config.

Kasus nyata: thread `01a192dd` ("ping") tersimpan dengan
`ctx/conextlab/ollama/deepseek-v4.1-flash:cloud` + approval granular. Setelah config
diperbaiki pun, app membuka thread itu lagi dan mengirim turn → `400 prompt too long;
exceeded max context length by 179437 tokens`. Config benar, sesi tetap gagal.

Artinya: memperbaiki config **tidak** memperbaiki thread lama. Yang benar:
arsipkan thread beracun (`archived = 1`), buat thread baru. Sudah dilakukan untuk `01a192dd`.

Verifikasi rantai penuh lewat CLI dengan `CODEX_HOME` clone — bukan lewat UI, supaya
deterministik:

```
model: cx/gpt-6.1-sol
provider: nine_router
codex
FRESH-CLONE-OK
tokens used 16,449
```

Sesi baru mendarat di `.codex-clone\sessions`, home asli tetap 193 rollout.

## 5e. Probe `danger-full-access` — PASS (2026-11-01)

Banner Windows sandbox tidak menghalangi eksekusi. Dibuktikan lewat CLI dengan `CODEX_HOME`
clone, `danger-full-access`, tanpa approval:

```
$ CODEX_HOME=C:\Users\rahma\.codex-clone codex exec --skip-git-repo-check \
    -C C:\Users\rahma\Documents --sandbox danger-full-access \
    'Run the shell command: echo FULLACCESS-PROBE and report its output verbatim.'

model: ctx/conextlab/ollama/deepseek-v4.1-flash:cloud
provider: nine_router
approval: never
sandbox: danger-full-access
--------
exec
"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -Command 'echo FULLACCESS-PROBE'
 in C:\Users\rahma\Documents
 succeeded in 204ms:
FULLACCESS-PROBE
```

| bukti | nilai |
| --- | --- |
| exit eksekusi | `succeeded in 204ms` |
| stdout shell | `FULLACCESS-PROBE` |
| lapisan sandbox | tidak dipakai (`danger-full-access`) |
| approval | `never`, tak ada prompt |
| tokens | 32.296 |

Artinya rantai clone → gateway → model → shell → stdout utuh tanpa sandbox Windows. Yang
tersisa hanya banner kosmetik yang menguji lapisan yang memang tak dipakai.

**Jangan coba lagi** mengejar banner itu lewat registry, provisioning ulang, atau bedah
`codex.exe`. Jalur sudah ditutup di 5c.

## 5f. Gambar lewat gateway non-OpenAI — akar "prompt too long" (2026-11-01)

> Koreksi 2026-11-01 malam. Isi bagian ini **dipertahankan sebagai catatan sejarah**, bukan
> sebagai fakta terkini. Dua klaim intinya — model diganti ke `kimi-k2.7-code` dan base64
> ditokenisasi sebagai teks — **tidak tereproduksi** dan sudah dibatalkan di **5i**. Yang bertahan
> dari bagian ini hanyalah angkanya: `cx` ~17,2k token, 11 gambar/12,5 MB → 30.361 token.
> Kesimpulan praktisnya juga bertahan — **pakai `cx/*` untuk gambar** — tapi alasannya
> instabilitas `ctx/*`, bukan penukaran model. Jangan kutip mekanisme di bawah tanpa 5i.

Ini **bukan** context window dan **bukan** banner sandbox. Dua error `prompt too long` yang
muncul sesudah deepseek jadi default punya satu sebab: gambar di jalur translasi non-OpenAI.

### Mekanisme

| jalur | perlakuan gambar | token |
| --- | --- | --- |
| `cx/gpt-6.1-sol` (OpenAI-native) | `input_image` dipertahankan | 17.274 (screenshot 2,3 MB) |
| `ctx/conextlab/…deepseek-v4.1-flash:cloud` | base64 ditokenisasi **sebagai teks** | ~2.633.000 |

Angkanya pas: 7,82 MB base64 ÷ 3,11 char/token = 2,63 juta token, sama dengan
`exceeded max context length by 1633305 tokens` + window 1.000.000.

### Temuan yang lebih penting: model DIGANTI diam-diam — **DIBATALKAN, lihat 5i**

Uji langsung ke `router.antinrml.com/v1/responses`, request identik, hanya beda ada/tidaknya
gambar:

```
tanpa gambar  -> model = deepseek-v4.1-flash:cloud   input_tokens = 7.684
dengan gambar -> model = kimi-k2.7-code:cloud        input_tokens = 9.026   <-- DIGANTI
output_tokens = 0, output = []
```

Konsisten di semua bentuk payload (gambar di `message`, di `custom_tool_call_output`,
`detail` = original/high/auto/low). Combo `ctx/conextlab/...` melakukan failover ke kimi saat
ada gambar, dan di jalur translator gambar kehilangan bentuknya.

> **Dibatalkan 5i:** pada 2026-11-01 malam, `kimi` muncul **0 kali** di rollout probe 3 run,
> `model = ctx/...` bertahan, tidak ada error prompt-too-long, dan `input_image` ada. Blok di atas
> adalah pengamatan satu sesi yang tidak berulang, bukan mekanisme gateway.

Gateway **tidak** salah menangani gambar sebagai gambar: 11 gambar (12,5 MB) lewat jalur yang
benar menghasilkan 30.361 token. Jadi tokenisasi gambar sehat; yang rusak adalah pemilihan
upstream + translasi bentuk.

### Pemicu sesi QA

```
desktop-full.png  1093x6000 px, 2.3 MB -> base64 3.03 MB
11 gambar dalam satu turn, total 7.82 MB base64
```

Screenshot full-page 6000 px itulah yang membengkakkan request.

### Keputusan: default kembali ke `cx/gpt-6.1-sol`

Empat tempat dipatok ulang supaya tidak balik sendiri:

| tempat | nilai |
| --- | --- |
| `.codex/nine-router-models.json` | prio 0 `cx/gpt-6.1-sol` |
| `.codex-clone/nine-router-models.json` | sama |
| `codex-launch.ps1` | `Set-CloneModel … 'cx/gpt-6.1-sol'` |
| `codex-9router-catalog` | `DEFAULT_MODEL` default `cx/gpt-6.1-sol` |

Thread `01a19316` (QA, 8,8 MB) di-repoint ke `cx` supaya bisa dibuka lagi. Backup:
`/tmp/state5-before-repoint.bak`.

Bukti sesudah perubahan — screenshot yang sama, yang dulu meledak:

```
model: cx/gpt-6.1-sol
sandbox: danger-full-access
"A sleek black-and-white AICO learning website features a star-trail hero, …"
tokens used 17,274
```

Isolasi tetap utuh: 11 sesi clone di home sendiri, real tetap 193 rollout, `auth.json` 4.145 B.

Perbaikan sebenarnya ada di gateway (`open-sse`): jangan failover ke upstream tanpa vision,
dan pertahankan `input_image` saat translasi. Itu di luar repo ini — **debugging lanjutan
ditunda atas keputusan Rahman 2026-11-01.**

## 5g. `Access is denied` plugin cache — akar: `chrome@openai-bundled` di clone (2026-11-01)

Warning ini muncul tiap start clone:

```
WARN codex_core_plugins::manager
  failed to refresh configured plugin cache marketplace="openai-bundled"
  error=failed to refresh plugin cache for chrome@openai-bundled:
        failed to back up plugin cache entry: Access is denied. (os error 5)
```

### Rantai sebabnya

Chrome di mesin ini punya native messaging host yang menunjuk **ke dalam home**:

```
C:\Users\rahma\AppData\Local\OpenAI\extension\com.openai.codexextension.json
  "path": "...\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host.exe"
```

Karena `chrome@openai-bundled` **enabled** di config clone, `extension-host.exe` juga
diluncurkan dari salinan clone. Saat jalan, Windows mengunci satu file:

```
\extension-host\windows\x64\extension-host.exe
```

Itu binary yang sedang dieksekusi. App lalu mencoba **mem-backup** entri cache
`chrome@openai-bundled` sebelum refresh — rename folder yang isinya berisi exe terkunci →
`os error 5`. Jadi bukan izin folder: ACL `.codex` dan `.codex-clone` identik, dan
`chrome/latest` bisa di-rename dengan bebas. Yang gagal adalah file exe-nya.

Bukti pembeda: home asli **0** kemunculan, clone **15**.

### Perbaikan

`chrome@openai-bundled` → `enabled = false` di config clone saja. Home asli tetap
`enabled = true`.

Dijaga oleh launcher, karena app bisa menambah blok itu lagi:

| fungsi | yang dijaga |
| --- | --- |
| `Set-ClonePluginDisabled` | `[plugins."chrome@openai-bundled"] enabled = false` |
| `Stop-StaleCloneExtensionHosts` (inline) | matikan `extension-host.exe` yang exe-nya di bawah `$cloneHome` |

Keduanya hanya menyentuh clone. Penjaga ext-host memfilter lewat `ExecutablePath`, jadi
ext-host akun asli dan Chrome yang sedang jalan tidak pernah tersentuh.

### Hasil

| bukti | nilai |
| --- | --- |
| `back up plugin cache entry` sejak launch | **0** |
| `Access is denied` sejak launch | **0** |
| baris log baru saat itu | 375 |
| sesi clone sesudahnya | `FINAL-VERIFY-OK`, 16.285 token |
| home asli | 193 rollout, `auth.json` 4.145 B, `chrome` tetap enabled |

Warning `failed to warm featured plugin ids cache` **masih ada** dan itu wajar: clone tidak
punya auth ChatGPT, jadi endpoint `chatgpt.com/backend-api/plugins/featured` menolak. Bukan
bug, jangan dikejar.

## 5h. `codex-clone-quicktest` pernah hijau sambil membuang 4 assertion (2026-11-02)

**Cacat.** `[2/5] unit tests` menjalankan vitest dengan port mati yang di-hardcode:

```bash
CONVEX_URL="${CONVEX_URL:-http://127.0.0.1:9999}" npx vitest run --reporter=dot
```

`src/convex/deployment.spec.ts` memanggil `describe.skipIf(!live)`, dan `live` = tidak ada
yang menjawab `/version`. Port 9999 **mati**, jadi keempat test — termasuk
`queries refuse an anonymous caller` dan `mutations refuse an anonymous caller` — tidak
pernah jalan. Langkahnya tetap mencetak `PASS vitest`, dan `qcheck` tetap bilang
`clone : ok`. Jadi 2 dari 4 assertion keamanan berubah jadi skip permanen yang tak terlihat.
Ditambahkan `b1b7966` (2026-11-02) untuk mematikan kegagalan flaky: gejala hilang, buktinya
ikut hilang.

**Pengukuran hari ini**, bukan dugaan:

| probe | hasil |
| --- | --- |
| `curl /version` ke `127.0.0.1:3210` | `200`, body literal `unknown` — deployment hidup |
| `curl /version` ke `127.0.0.1:9999` | `000` — tak ada yang menjawab |
| `POST /api/query` `devices:list` ke `:3210` | `Could not find public function for 'devices:list'` — **nol fungsi ter-push** |
| `CONVEX_URL=:3210 npx vitest run` | `2 failed \| 229 passed (231)` — 2 gagal karena dapat `Server Error`, bukan penolakan auth |
| `CONVEX_URL=:9999` (versi lama) | 4 skip, langkah tetap `PASS` |

Artinya port mati itu bukan cuma menyembunyikan skip: ia menyembunyikan **kegagalan**.
Dengan deployment kosong yang benar-benar diprobe, spec justru merah.

**Perbaikan** di `bin/codex-clone-quicktest`:

| hal | sebelum | sesudah |
| --- | --- | --- |
| URL | hardcode `:9999` | `CONVEX_URL`, default `127.0.0.1:3210` |
| klasifikasi | tidak ada | `classify_convex` → `dead` / `empty` / `serving` |
| skip | tak terlihat, tampil `PASS` | baris `SKIP` sendiri + alasan |
| status akhir | `%d passed, %d failed` | `+ %d skipped`, dan `qcheck` cetak `ok (N skip)` |
| kegagalan spec convex saat deployment kosong | dianggap PASS | dihitung skip, **hanya** kalau seluruh FAIL milik spec itu |

`serving` tetap satu-satunya keadaan yang boleh jadi `PASS` untuk boundary auth. `--exclude
src/convex/**` **tidak dipakai**: `vite.config.ts` memakai `projects`, dan vitest 4.1.11
mengabaikan `--exclude` di mode itu (diukur: 39 file tetap terkumpul). Karena itu
kegagalan difilter dari log, bukan dari daftar file.

Yang **tidak** dikerjakan dengan sengaja: push schema ke deployment `:3210`. Itu mengubah
state bersama, dan bukan urusan gate repo.

## 5b. Uji isolasi pasca-swap — hasil

| bukti | nilai |
| --- | --- |
| sesi clone | 3 rollout di `.codex-clone\sessions`, 0 di home asli |
| sqlite clone | 3 file di `.codex-clone\sqlite` |
| home asli | 193 rollout (tak bertambah karena clone) |
| model provider di sesi clone | `"model":"cx/gpt-6.1-sol"`, `"model_provider":"nine_router"` |
| baris `model` clone config | tetap `cx/gpt-6.1-sol`, tidak ditimpa app |
| junction di `.codex-clone` | **0** |
| auth ChatGPT asli | utuh, `tokens` masih ada |

Satu junction sempat tertinggal di `plugins\cache\openai-bundled\chrome\latest`. Ternyata ia
menunjuk **ke dalam clone sendiri** (bukan ke home asli), jadi tidak bocor — tapi sudah
diganti salinan agar invariant "nol junction" benar-benar nol. Ukuran clone naik 539 → 664 MB.

## 6. Berkas yang terlibat

| path | isi |
| --- | --- |
| `~/.codex/` | home asli, akun ChatGPT. **Jangan diubah.** |
| `~/.codex/9router.config.toml` | profil CLI `codex -p 9router` |
| `~/.codex/nine-router-models.json` | katalog 80 model, prio 0 `ctx/conextlab/ollama/deepseek-v4.1-flash:cloud` |
| `~/.codex-clone/` | home clone mandiri, 664 MB, nol junction, sesi sendiri |
| `~/OneDrive/Desktop/codex-launch.ps1` | launcher `-Mode real\|clone`; re-assert sandbox + model |
| `~/OneDrive/Desktop/Codex.lnk` | shortcut mode asli |
| `~/OneDrive/Desktop/Codex Clone.lnk` | shortcut mode clone |
| `~/codex-clone-swap.ps1` | skrip swap sekali pakai (sudah dijalankan) |
| `~/.local/bin/codex-9router-catalog` | regenerasi katalog |
| `~/.local/bin/codex-clone-quicktest` | uji repo (13/13 PASS) |
| `~/.local/bin/codex-real-quicktest` | uji Codex dua provider |
| `~/.local/bin/codex-caps-quicktest` | matriks kapabilitas |
| `~/.local/bin/qcheck` | pembungkus ketiganya |
| `~/.local/share/codex-9router/` | `PROGRESS.md`, `capture_proxy.py`, `mcp_echo.py`, `parity-evidence/` |

## 7. Jebakan yang sudah memakan waktu

- Jangan jalankan Codex dari `C:\Users\rahma` — `~/.codex/config.toml` ikut terbaca sebagai
  project-local config dan menimpa profil.
- `pkill -f "rea analyze"` membunuh shell-nya sendiri; polanya cocok dengan command line-nya.
- Assertion dari ucapan model bukan bukti. `apply_patch` pernah "PASS" padahal file masih
  `OLD`. Selalu cek disk.
- Base config ChatGPT `sandbox: read-only` → tool tulis "ada" tapi ditolak. Probe harus paksa
  `--sandbox workspace-write`, kecuali saat menguji MCP (yang justru butuh full-access).
- `Get-ChildItem -Recurse -File` berhenti di reparse point; `cmd /c dir /s /a-d` tidak. Dua
  angka berbeda untuk direktori yang sama bukan berarti korup.
- Menghitung reparse point pada `C:\Users\rahma\.codex-clone` akan menghasilkan 1 karena
  path-nya sendiri, bukan isinya. Hitung dengan `-Recurse` dan buang dir root.

## 8. `bin/isolation-check` — CONTRACT §13 jadi perintah (2026-11-02)

§13 bilang "catat PID yang sudah ada duluan, lalu buktikan semuanya selamat". Sampai
2026-11-02 itu hanya dikerjakan tangan, dan verifikasi tangan adalah verifikasi yang akan
dilewatkan. Sekarang jadi skrip.

```sh
bin/isolation-check snapshot   # sebelum probe
bin/isolation-check verify     # sesudah probe
```

Snapshot = jumlah file `sessions` di tiga home, md5 `config.toml` + `auth.json` home asli,
dan daftar PID (`ChatGPT|codex|extension-host` lewat `powershell.exe`) yang diurutkan.
`verify` mengukur ulang lalu mencetak satu baris PASS/FAIL per invariant:

| # | invariant | gagal bila |
| --- | --- | --- |
| 1 | sesi home asli tetap | jumlah berubah |
| 2 | md5 `config.toml` asli tetap | berubah |
| 3 | md5 `auth.json` asli tetap | berubah |
| 4 | sesi home clone tetap | jumlah berubah |
| 5 | semua PID lama hidup | ada yang hilang |
| 6 | sesi home probe | **tidak pernah gagal** — delta hanya dilaporkan |

Invariant 6 sengaja tidak bisa memerahkan hasil: probe memang menulis ke `~/.codex-probe`.
Menjadikannya kegagalan berarti menyuruh orang mematikan pemeriksaan.

Aturan yang sama seperti §11: **tak bisa diukur ≠ lulus.** Home asli hilang, snapshot tidak ada,
proses list tak terbaca, atau snapshot milik `USERPROFILE_WSL` lain → FAIL + exit non-zero.

### Baseline terukur 2026-11-02

| besaran | nilai |
| --- | --- |
| sesi home asli `.codex` | **443** |
| sesi home clone `.codex-clone` | **23** |
| sesi home probe `.codex-probe` | **76** |
| md5 `config.toml` | `72f9e8969dde6776d1a0c1d7443d109d` |
| md5 `auth.json` | `7f08dac46a32d2d458ea8cb9e4e18f66` |
| PID pra-ada | **25**, semuanya hidup setelah probe |

`snapshot` lalu `verify` pada sistem tenang: **5 PASS, 0 FAIL**, RC=0.

### Batasnya, dinyatakan

- Perbandingan proses **berdasarkan nama**, bukan PID, sejak 2026-11-02. Revisi pertama membandingkan
  PID persis dan melaporkan app yang sehat sebagai mati setiap kali sebuah renderer Chromium
  didaur ulang — terukur: satu probe penuh menghasilkan `FAIL pre-existing PIDs gone: 36600`
  sementara 17 proses ChatGPT masih hidup. Nama proses yang hilang seluruhnya tetap FAIL.
- PID reuse **masih** tidak terdeteksi; itu butuh waktu mulai proses, dan probe tidak berjalan
  cukup lama untuk peduli.
- Kalau tak ada proses cocok sama sekali, invariant 5 dilaporkan INFO, bukan PASS diam-diam —
  daftar kosong tidak membuktikan apa pun soal isolasi.
- Skrip **tidak menulis apa pun** ke `~/.codex*`: hanya `find`, `md5sum`, `powershell.exe`.
  Satu-satunya tulis adalah `$SNAPSHOT_FILE`.
- **Lubang revisi pertama, dan penutupnya (2026-11-02).** `SNAPSHOT_FILE` tidak divalidasi, jadi
  satu-satunya tulis skrip ini bisa diarahkan **ke dalam** home yang justru dijaga:
  `SNAPSHOT_FILE=/mnt/c/Users/rahma/.codex/canary.tsv … snapshot` → RC=0 dan file benar-benar
  dibuat di sana. Ketahuan dengan menyerang alatnya sendiri, bukan dengan membacanya; audit
  `xtrace` tidak bisa melihatnya karena redirection-nya memang sah, hanya tujuannya salah.
  Sekarang `guard_snapshot_path()` menolak path yang resolve ke `.codex`, `.codex-clone` atau
  `.codex-probe` sebelum kerja lain dimulai — di **kedua** subcommand, karena `verify` adalah
  pre-flight resmi dan harus mengajarkan pemakaian yang benar. `realpath -m` dipakai supaya
  symlink dan `..` ikut ternormalisasi sebelum dibandingkan (terbukti: `anything/../.codex/x.tsv`
  dan symlink `/tmp/symtest/link -> .codex` dua-duanya ditolak, file tidak dibuat). Perbandingan
  pakai garis miring di belakang, jadi sibling `.codex-backup` tidak ikut diblokir.
  Sisa batas yang jujur: guard membandingkan path, bukan inode — hardlink ke dalam home tak
  terdeteksi, dan itu memang di luar cakupan skrip sekecil ini.

## 9. `tests/shortcut-contract.sh` — "shortcut-nya sink dengan repo?" jadi perintah (2026-11-04)

Empat shortcut Desktop rusak dengan cara yang persis diperingatkan CONTRACT.md, dan tak ada
satu pun yang ketahuan karena tak ada yang memeriksanya. Yang terjadi:

| shortcut | rusak karena |
| --- | --- |
| `Codex.lnk` | `-File` menunjuk `C:\Users\rahma\Desktop\codex-launch.ps1` — salinan, bukan repo |
| `Codex Clone.lnk` | idem, plus ikon ke MSIX `26.1027.3384.0` yang sudah hilang |
| `Codex Real (repo).lnk` | skrip benar, ikon tetap di `26.1027.3384.0` |
| `Codex Clone (repo).lnk` | idem |

Store menaikkan app ke `26.1029.7803.0`; folder `OpenAI.Codex_<versi>_` ikut pindah, dan setiap
path yang menyebut versi ikut busuk. Ikon jadi halaman putih generik, bukan crash — karena itu
lama tak ketahuan.

Skrip membaca format `.lnk` langsung (Python, `struct`), bukan lewat `WScript.Shell`, supaya bisa
jalan di WSL/Linux/macOS. Hanya pertanyaan "file Windows ini ada?" yang butuh `powershell.exe`.

### Aturannya, dan alasan masing-masing

| # | aturan | gagal bila | kenapa ada |
| --- | --- | --- | --- |
| R1 | target ada dan memang `powershell.exe` sistem | target hilang, atau salinan di bawah `C:\Users\` | salinan = interpreter lain dari yang diuji repo; target hilang = tak ada yang jalan |
| R2 | `-File` menunjuk `scripts/codex-launch.ps1` **di repo ini** | file di Desktop, di luar git, atau byte-nya beda dari `$REPO/scripts/codex-launch.ps1` | perbaikan masuk git, shortcut tetap menjalankan file lama — kegagalan paling senyap dari empat ini |
| R3 | file `IconLocation` ada sekarang | tak ada | gejala visual dari R4, bukan kosmetik: ikon putih generik |
| R4 | tak ada path ber-`OpenAI.Codex_<versi>_` | ada di target/args/icon/workdir | versi MSIX pindah tiap update Store; path ber-versi busuk sendiri |
| R5 | tepat satu `-Mode`, isinya `real` atau `clone` | tak ada, dobel, atau nilai lain | launcher default ke `real`; shortcut clone yang salah ketik membuka akun asli tanpa tanda |
| R6 | tak ada dua shortcut dengan skrip+mode sama | ada | satu di antaranya tak terawat, dan mana yang diklik cuma keberuntungan |

Worktree lain dari repo yang sama **lolos** R2 (dibandingkan lewat `--git-common-dir`), tapi
byte-nya tetap harus sama dengan `$REPO/scripts/codex-launch.ps1` — path benar + isi basi tetap
FAIL. Itu kasus yang paling mungkin terjadi dengan beberapa agent di branch berbeda.

### Antarmuka

```sh
tests/shortcut-contract.sh                    # Desktop nyata
tests/shortcut-contract.sh --dir <path>       # direktori fixtures
tests/shortcut-contract.sh --repo <path>      # pin checkout yang diharapkan
tests/shortcut-contract.sh --selftest         # buktikan tiap aturan masih bisa gagal
bin/qcheck shortcut                           # satu perintah, satu verdict
```

Exit: `0` semua lolos, `1` ada FAIL, `2` tak ada FAIL tapi ada yang tak bisa dibuktikan.
Yang tak bisa dibuktikan dicetak `UNPROVEN` — **tidak pernah** `PASS`. Dua jalan ke sana:
tak ada `powershell.exe` di host, atau folder induk path itu tak bisa dibaca (WindowsApps
ACL-locked), sehingga "tidak ada" bukan fakta.

### Fixtures, dan buktinya

`--selftest` menulis `.lnk` asli byte per byte (bukan stub), semua di bawah `$TMPDIR`, dengan
path Windows berupa UNC `\\wsl.localhost\Ubuntu\...` ke tree sementara itu — jadi tak butuh
Windows dan tak menyentuh Desktop. `SHORTCUT_NO_WINDOWS=1` memaksa jalur posix.

| fixture | yang dilanggar | hasil |
| --- | --- | --- |
| `good` (kontrol) | — | lolos bersih, 0 FAIL 0 UNPROVEN |
| `icon-missing` | R3 | FAIL `R3 icon file does not exist` |
| `msix-pinned` | R4 | FAIL `R4 version-pinned MSIX path` |
| `desktop-copy` | R2 | FAIL `R2 runs a Desktop copy` |
| `duplicate` | R6 | FAIL `R6 duplicate shortcuts for mode` |
| `no-mode` | R5 | FAIL `R5 no -Mode argument` |
| `drift` | R2 byte | FAIL `R2 launcher drift` (dua worktree satu repo, isi beda) |

`--selftest`: **7 passed, 0 failed**.

### Batas yang dinyatakan

- Yang diperiksa adalah isi `.lnk`, bukan apa yang terjadi saat diklik. Argumen `-Profile`,
  `-Model`, `-RealHome` sengaja tidak divalidasi: launcher yang menolaknya, dan menebak di sini
  akan jadi aturan kedua yang bisa salah.
- R3 menerima ikon yang menunjuk target itu sendiri (`IconLocation == TargetPath`) tanpa cek
  keberadaan terpisah — R1 sudah membuktikan file itu ada. Urutannya karena itu R1 sebelum R3.
- Folder `WindowsApps` tak bisa dibaca dari WSL. Tanpa `powershell.exe`, setiap path MSIX jadi
  `UNPROVEN`; itu disengaja, karena "tidak terlihat" bukan "tidak ada".
- Shortcut yang bukan milik repo dilewati: hanya yang punya `codex-launch` di argumen atau
  berawalan `Codex` yang diperiksa.

## 10. `bin/codex-instruct` — instruksi & determinisme (2026-11-05)

Pertanyaan yang memicunya: "bisa tambahkan custom instruction, dan skrip untuk memotong
deterministik LLM?" Dua hal berbeda, dan yang kedua tidak bisa dijanjikan seperti yang
terdengar. Yang bisa dibuktikan diukur dulu.

### Yang terbukti bekerja di `26.1029.7803.0`

| klaim | cara | hasil |
| --- | --- | --- |
| `model_instructions_file` dihormati | profil membawa kunci itu, prompt `say hello` | `MANGO hello` |
| bisa juga per-run | `-c model_instructions_file=...` | `PINEAPPLE hello!` |
| `AGENTS.md` proyek dibaca | workspace berisi `AGENTS.md`, prompt `say hi` | instruksi terpakai |
| `AGENTS.override.md` menang | keduanya ada | `FROM-OVERRIDE` |

Kunci config yang **ada** di `app/resources/codex.exe` (355 MB): `model_instructions_file`,
`model_reasoning_effort`, `model_reasoning_summary`, `model_verbosity`,
`model_catalog_json`, `project_doc_max_bytes`, `project_doc_fallback_filenames`,
`AGENTS.override.md`.

Kunci yang **tidak ada**: `temperature`, `top_p`, `seed`. Yang muncul di biner adalah
anggota tipe SDK untuk request Chat-Completions, dan jalur Codex tidak membangun request
itu. Jadi menulis kunci itu ke profil = no-op yang tampak berhasil.

Event hook yang ada: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `SessionStart`,
`Stop`, `SubagentStop`, `PreCompact`, `Notification`.

### Dua kegagalan senyap yang harus ditutup

1. **Path `/mnt/c/...` disimpan apa adanya.** Codex proses Windows; path itu tidak ada
   baginya. Profil tetap termuat, instruksi tidak pernah terpakai, tidak ada error.
2. **Backslash tidak di-escape untuk TOML.** `C:\Users\rahma\x.md` jadi
   `C:Usersrahmax.md` — file yang tidak ada, lagi-lagi tanpa error.

Keduanya sekarang fungsi murni (`windows_path`, `toml_quote`) dan diuji dengan mutasi:
menghapus escape → 1 FAIL; mematikan translasi → 1 FAIL.

### Yang tidak dijanjikan

`determinism` sengaja melaporkan `temperature`/`top_p`/`seed` sebagai `not_pinnable`.
Yang deterministik adalah teks instruksi, aturan proyek, perintah hook, dan verifikasinya —
bukan token model. Provider tetap bisa membatch dan merutekan berbeda antar run.

## 11. `bin/codex-doctor` — satu verdict (2026-11-05)

Tujuh skrip di `bin/` masing-masing menjawab satu pertanyaan, dan pengguna baru tidak tahu
mana yang dijalankan lebih dulu. `codex-doctor` menjalankan yang murah dan tanpa efek
samping, berurutan, lalu mencetak satu verdict:

`app → home → profiles → endpoint → model → catalog → writable → selftests`

Dua bug ditemukan saat membuatnya, keduanya karena memeriksa dengan asumsi salah:

| bug | gejala | sebab |
| --- | --- | --- |
| `endpoint` melaporkan "no base_url" | profil valid dianggap kosong | mencari `model_provider` di `config.toml`, padahal `-p <name>` mengambilnya dari profil |
| `selftests` FAIL | repo tampak rusak | memanggil `tests/shortcut-contract-selftest.sh` langsung; ia butuh `$WORK` yang disiapkan induknya lewat `--selftest` |

Keduanya hanya ketahuan karena dijalankan pada home nyata, bukan fixture.

### Batas

- Read-only: satu-satunya tulisan adalah file probe `.doctor-probe` yang langsung dihapus.
- Token dibaca untuk autentikasi, tidak pernah dicetak.
- `--fast` melewati probe jaringan, untuk dipakai offline atau di CI.
- Exit 0 sehat, 1 ada yang gagal, 2 tidak bisa jalan.

## 12. Default pindah ke `deepseek-v4.1-flash-free` — diukur, bukan diasumsikan (2026-11-05)

Permintaan: jadikan mesin ini default deepseek 4.1 flash, dan pastikan perilakunya tidak
kalah dari `cx/gpt-6.1-sol`. Urutan kerjanya: ukur dulu, baru ubah.

### Empat slug "deepseek 4.1 flash" di gateway, dan bedanya

| slug | `/chat/completions` | jalur Codex | catatan |
| --- | --- | --- | --- |
| `deepseek-v4.1-flash-free` | ✅ | ✅ | **dipakai** |
| `oc/deepseek-v4.1-flash-free` | ✅ | ❌ `Reconnecting... 1/5` | menjawab di curl, **tidak pernah tersambung** di Codex |
| `ctx/ollama/deepseek-v4.1-flash:cloud` | ✅ | ✅ | jalan, token lebih boros |
| `ctx/conextlab/ollama/deepseek-v4.1-flash:cloud` | ✅ | ✅ | idem |

Yang menentukan pilihan bukan `/v1/models` (keempatnya hidup) melainkan jalur Codex.
`oc/...` adalah kegagalan paling berbahaya: lolos semua uji HTTP, lalu diam total di app.

### Matriks perilaku, deepseek vs cx

| probe | `deepseek-v4.1-flash-free` | `cx/gpt-6.1-sol` |
| --- | --- | --- |
| chat | PASS | PASS |
| exec / shell | PASS | PASS |
| MCP (`echo_text`) | PASS | PASS |
| **sub-agent** | PASS (`collab: Wait` → benar) | PASS |
| **gambar (`view_image`)** | PASS (`Red`) | PASS |
| **edit kode 3 fungsi** | PASS (42 / 3.5 / None) | PASS (42 / 3.5 / None) |
| tool calling mentah | `get_weather{"city":"Jakarta"}` | sama |
| vision mentah `/chat/completions` | `Red.` | `Red` |
| token sub-agent | **50.452 → 37.926** setelah instruksi | **17.726** |

Dua koreksi atas catatan lama: sub-agent **bukan** lagi `unsupported call` untuk deepseek,
dan gambar **bukan** hanya `cx/*`. Keduanya berubah sejak catatan 2026-10-31.

### Selisih yang tetap ada: kebocoran reasoning

Tanpa instruksi, deepseek menulis deliberasinya ke stdout:

```
We need must report exact answer. "Report its answer" could simply say SUBAGENT-OK? ...
```

Ini bukan kosmetik: 50k token untuk tugas yang cx selesaikan dengan 17,7k, dan output
kotor. `model_instructions_file` menutupnya — 37,9k, jawaban bersih:

```
Sub-agent answer: SUBAGENT-OK
```

Karena itu default sekarang **selalu** membawa `9router.instructions.md`. Tanpa berkas itu,
deepseek lebih boros daripada cx meski hasil akhirnya sama.

### Yang diubah

| berkas | perubahan |
| --- | --- |
| `9router.config.toml` (mesin ini) | `model = "deepseek-v4.1-flash-free"` + `model_instructions_file` |
| `scripts/codex-launch.ps1` | default clone model |
| `bin/codex-9router-catalog` | `DEFAULT_MODEL` default, supaya regenerate tidak mengembalikan cx ke prioritas 0 |
| catalog | diregenerasi: 99 model, deepseek priority 0, `tool_mode=code_mode_only`, `lite=False` |

`cx/gpt-6.1-sol` tetap ada di catalog dan tetap berfungsi — ia fallback bila jalur gambar
upstream regresi. `-Model cx/gpt-6.1-sol` per launch tidak diubah perilakunya.

### Batas yang dinyatakan

- Satu mesin, satu gateway. Angka di atas bukan klaim universal.
- Token diukur dari `tokens used` milik Codex, yang mencakup konteks, bukan hanya jawaban;
  dua run dengan tugas sama bisa beda karena cache konteks (terlihat: 16.988 vs 3.804).
- Instruksi menentukan **gaya keluaran**, bukan kualitas penalaran. Pada tugas yang lebih
  sulit dari probe di atas, selisih cx vs deepseek belum diukur dan tidak diklaim.

## 13. Default jadi BYOK (clone), plus empat sebab "kerja cuma sebentar" (2026-11-05)

Permintaan: "tetapkan semua kecuali 3, defaultnya byok, defaultnya deepseek". Nomor 3 di
daftar analisis adalah "pindah ke `cx/gpt-6.1-sol`" — itu **tidak** dilakukan. Sisanya ya.

### Apa yang menetap

| berkas | perubahan | efek |
| --- | --- | --- |
| `scripts/codex-launch.ps1` | `-Mode` default `clone` | luncuran tanpa flag = BYOK/9router, bukan akun ChatGPT |
| `scripts/install-shortcuts.ps1` | `Codex Clone` lebih dulu di daftar | shortcut pertama yang terlihat = default |
| `bin/codex-9router-catalog` | `truncation_policy.limit` 10.000 → 40.000 | baca file besar tidak lagi buta 94% |
| idem | `default_verbosity` `low` → `medium` | jawaban tidak lagi terasa tipis |
| idem | `oc/*` → `visibility: "hide"` | entri yang balas 429 tak lagi ditawarkan |
| `scripts/clone-AGENTS.md` (baru) | aturan WSL/UNC, batching, batas 3 agent, `wait_agent` 600 s | klon tidak lagi berhenti karena timeout 60 s |
| `scripts/codex-launch.ps1` | seed `AGENTS.md` klon kalau kosong; `Set-CloneTopLevel` untuk `model_instructions_file` | klon punya aturan yang sama dengan home asli |
| `app/tests/test-toplevel.ps1` (baru) | 3 assert: insert, no-op, rewrite | fungsi edit-konfigurasi terbukti tidak merusak byte lain |

### Bukti, bukan klaim

| probe | hasil |
| --- | --- |
| `codex exec` dengan `CODEX_HOME` klon | `provider nine_router`, `model deepseek-v4.1-flash-free`, `effort high` (dibaca dari `turn_context` rollout baru) |
| pertanyaan batas agent | dijawab "max 3 sub-agents; wait_agent timeout_ms 600000" — `AGENTS.md` klon terbaca |
| `tests/isolation-check.sh` | 12 passed |
| `tests/instruct-contract.sh` | 12 passed |
| `app/tests/run-tests.mjs` | 5/5 |
| `tests/shortcut-contract.sh` (+ `--selftest`) | 11 passed / 7 passed |
| `app/tests/test-toplevel.ps1` | 3/3 PASS |

Catatan probe: `CODEX_HOME` yang diekspor dari bash **tidak** terbawa ke `codex.exe` (proses
Windows). Dua run pertama saya salah sasaran dan tercatat di home asli (`provider openai`,
`gpt-6.1-sol`). Probe yang benar menyetel `$env:CODEX_HOME` di dalam PowerShell.

### Yang sengaja dibiarkan

- `model_reasoning_effort = "high"` di klon: effort bukan penyebabnya, dan sudah terbukti
  sampai ke upstream (probe `/v1/responses`: low 5.5k vs high 21.8k token output).
- Translator 9router (`type:"namespace"`, `encrypted_content`): perbaikan gateway, bukan repo
  ini. Tanpa itu, penalaran antar-turn tetap tidak terbawa untuk upstream non-OpenAI.
- `cx/gpt-6.1-sol` tetap ada sebagai fallback gambar.

## 14. Dua probe yang mengukur dirinya sendiri, bukan app (2026-11-05)

Ditemukan saat memverifikasi §13. Keduanya **bukan** akibat perubahan default, tapi keduanya
membuat verifikasi jadi mustahil, jadi diperbaiki dulu.

### 14a. `codex-caps-quicktest` pin hash CLI yang sudah tidak ada

`CODEX_EXE` di-hardcode ke `bin/22cfb1d302613eae/codex.exe`. Setelah Store menaruh
`a159911ff70742e9`, direktori itu hilang. Hasilnya **22 dari 22 pengukuran FAIL**, termasuk
yang tidak ada hubungannya dengan gateway:

```
& : The term '...\bin\22cfb1d302613eae\codex.exe' is not recognized ...
```

`codex-real-quicktest` sudah punya resolver "newest staged CLI"; caps tidak pernah ikut.
Sekarang satu resolver: `bin/codex-exe` (CONTRACT §5: salinan kedua aturan = defect).

### 14b. Skrip `bin/` dijalankan lewat symlink `~/.local/bin`

`~/.local/bin/{qcheck,codex-real-quicktest,codex-caps-quicktest}` **bukan** symlink — itu
salinan beku dari 30 Okt – 2 Nov. `qcheck` karenanya menjalankan kode lama, bukan repo:
`qcheck codex` melaporkan `exe: ...22cfb1d302613eae...` padahal repo sudah memakai resolver.

Setelah dijadikan symlink, muncul bug kedua: `dirname "$0"` menunjuk `~/.local/bin`, jadi
`$SELF_DIR/codex-exe` tidak ada dan caps gagal lagi dengan pesan lain. Perbaikan:
`readlink -f "${BASH_SOURCE[0]}"` sebelum path sibling dibangun. Salinan asli disimpan di
`/tmp/opencode/bin-bak`.

### Bukti setelah perbaikan

| probe | hasil |
| --- | --- |
| `qcheck codex` (dari `/tmp`, lewat symlink) | 5 passed + **22 passed, 0 failed** |
| `qcheck shortcut` | ok |
| `app/tests/run-tests.mjs` | 7/7 (kini termasuk dua `.ps1`) |

### 14c. `install-shortcuts.ps1` menulis ikon yang version-pinned

Installer punya resolver sendiri yang mengembalikan path **di dalam**
`OpenAI.Codex_26.1029.7803.0_...`, lalu `tests/shortcut-contract.sh` R4 menolaknya — benar,
karena folder itu pindah tiap update Store. Repo sudah punya `scripts/resolve-codex-icon.ps1`
yang menyalin ikon ke `%LOCALAPPDATA%\codex-desktop\icon.ico`; installer tidak memakainya.
Sekarang memakai, dan path paket hanya jadi fallback berperingatan.

Catatan jujur: saya sendiri yang menulis ikon rusak itu ke dua shortcut saat menjalankan
installer untuk pertama kali (sebelum memperbaiki installernya). Sudah ditimpa ulang lewat
installer yang benar; `R4` PASS untuk kedua shortcut.

## 15. Akar sebenarnya "kurang effort": `model_instructions_file` MENGGANTI prompt (2026-11-05)

Ini temuan terpenting hari ini, dan penyebab paling langsung dari keluhan "kerjanya sebentar
sekali, sering tidak menyelesaikan tugas, seperti kurang effort".

### Yang terukur

`session_meta.base_instructions` di setiap rollout menyimpan prompt sistem yang benar-benar
dipakai. Panjangnya:

| profil | `model_instructions_file` | `base_instructions` |
| --- | --- | --- |
| klon, sebelum | tidak ada | **21.546** char |
| klon, sesudah saya tambahkan | ada (4 baris) | **388** char |
| ChatGPT asli (`openai`) | tidak ada | 21.524 char |

Jadi berkas itu **mengganti** seluruh prompt Codex, bukan menambahkan. Prompt asli berisi
"collaborate with them until their intended goal is completely handled", aturan batching tool,
aturan verifikasi, dan seterusnya. Yang tersisa setelah ditimpa:

```
You are a local coding agent. Work inside the workspace only.
- Reply with the final answer only. One or two short sentences.
```

"One or two short sentences" adalah instruksi yang saya tulis sendiri di
`~/.codex/9router.instructions.md` untuk mencegah kebocoran reasoning. Efek sampingnya:
agent berhenti setelah satu-dua kalimat, karena begitulah yang diperintahkan.

### Kronologi yang cocok dengan keluhan

| waktu | `base_instructions` di profil 9router |
| --- | --- |
| sebelum 2026-11-05 03:30 | 21.546 — normal |
| sejak 03:30 (berkas dibuat) | **388** — agent jadi pendek |

Sesi 03:44 (yang berhenti setelah `wait_agent` timeout tanpa menyentuh satu berkas) **masih**
21.546; sesi 04:41 ke atas sudah 388. Jadi keduanya masalah berbeda, dan §13/§16 menangani
yang lain. Yang ini yang membuat semua percobaan sesudahnya terasa "kurang effort".

### Perbaikan

| tempat | tindakan |
| --- | --- |
| `9router.config.toml` (home asli) | `model_instructions_file` **dihapus**, diganti komentar yang menjelaskan sebabnya |
| `~/.codex/AGENTS.md` (baru) | aturan yang sama, di permukaan yang **menambahkan**, bukan mengganti |
| `scripts/codex-launch.ps1` | tidak lagi menyetel berkas itu; `Set-CloneTopLevelRemove` menghapusnya kalau config lama masih membawanya |
| `scripts/clone-AGENTS.md` | diperluas: aturan output + shell + sub-agent |
| `docs/INSTRUCTIONS.md` | baris "it REPLACES the prompt" masuk tabel terukur |

### Bukti

| probe | hasil |
| --- | --- |
| klon, `model_instructions_file` dihapus | `base_instructions` = **21.638** char |
| idem, tanpa tool | dijawab "max 3 sub-agents; wait_agent timeout_ms 600000; wsl.exe -d Ubuntu --cd ..." — artinya `AGENTS.md` tetap terbaca |
| `app/tests/test-removekey.ps1` | 4/4: top-level hilang, key di dalam `[table]` utuh, idempoten |
| `app/tests/run-tests.mjs` | 8/8 |

### Pelajaran yang berlaku umum

`model_instructions_file` bukan tempat menaruh "beberapa aturan tambahan". Ia adalah
pengganti prompt penuh. Untuk menambah aturan: `AGENTS.md`. Untuk mengganti agent sepenuhnya:
baru `model_instructions_file`.

## 16. Verifikasi akhir §13–§15, di klon, setelah semua perubahan

| hal | nilai terbaca | bukti |
| --- | --- | --- |
| prompt Codex utuh | `base_instructions` **21.638** char | `session_meta` rollout klon terakhir |
| provider | `nine_router` | idem |
| model | `deepseek-v4.1-flash-free` | `turn_context` + `config.toml` |
| effort | `high` | `turn_context` |
| `AGENTS.md` terbaca | "max 3 sub-agents, wait_agent 600000, wsl.exe -d Ubuntu --cd ..." | jawaban tanpa tool |
| `model_instructions_file` | tidak ada di kedua home | `grep` |
| catalog | 99 model, trunc 40.000, verbosity medium, 3 `oc/*` disembunyikan | `nine-router-models.json` (asli & klon identik) |
| suite | 8/8 (`run-tests`), 12 (`isolation`), 11 (`instruct`), 11 (`shortcut`) | dijalankan |
| `qcheck codex` | 5 passed + 22 passed, 0 failed | dijalankan lewat symlink dari `/tmp` |

## 13. Gateway mati = "model rusak", dan tidak ada yang mengatakannya (2026-11-05)

### Gejalanya

Setelah default dipindah ke deepseek, `~/.9router` dikarantina ke
`~/.local/share/9router-cleanup-20261105/` (16:56) dan port 20128 tutup. Semua model di
profil `nine_router` jadi tidak menjawab, dengan gejala yang sama persis untuk semuanya:

```
ERROR: Reconnecting... 1/5
ERROR: Reconnecting... waiting for network
```

Tidak ada satu pun pesan yang menyebut gateway. Yang disalahkan model.

### Kesalahan yang terjadi karena itu

`ctx/ollama/deepseek-v4.1-flash:1017-cloud` diuji saat gateway mati, gagal, lalu dicap
"tidak bisa dipakai". Pengukuran itu **tidak sah** — bukan modelnya yang menolak, tapi tidak
ada yang mendengarkan di port itu. Sampai sekarang model itu **belum pernah benar-benar
diukur**; jangan mengutip verdict apa pun tentangnya.

### Dua klaim pengguna, keduanya benar

| klaim | bukti |
| --- | --- |
| "semua default itu deepseek 1017" | `~/.codex-clone/config.toml` memang `ctx/ollama/deepseek-v4.1-flash:1017-cloud`, bukan default repo — sisa seed lama sebelum `model_instructions_file` ada |
| "tidak ada fallbacknya" | `combos` di gateway: slug `deepseek-v4.1-flash-free` **adalah** combo → `["ctx/ollama/deepseek-v4.1-flash:cloud","ag/gemini-3.8-flash","cx/gpt-6.1-sol"]`. `ctx/...:1017-cloud` dan `oc/...` **bukan** combo, jadi tidak punya rantai fallback sama sekali |

Jadi fallback itu milik *slug polos*, bukan milik model. Menulis slug `ctx/...` atau `oc/...`
ke profil membuang rantai fallback yang sudah ada di gateway.

### Perbaikan

1. **Clone dikembalikan ke slug polos**: `model = "deepseek-v4.1-flash-free"`, sama dengan
   profil utama. Fallback gateway jadi berlaku lagi.
2. **Launcher punya preflight** (`Test-GatewayReachable`): provider loopback diprobe sebelum
   window dibuka. Kalau tidak menjawab:

   ```
   gateway not answering: http://127.0.0.1:20128/v1
     nothing that needs nine_router would answer; the model is not the problem.
     start it:  9router start          (or: systemctl --user start 9router)
     use the real account instead:  codex-launch.ps1 -Mode real
   ```

   Aturannya sengaja konservatif: **hanya loopback** yang diprobe. Provider remote tidak
   pernah diprobe — outage remote bukan sesuatu yang bisa diperbaiki skrip ini, dan verdict
   yang salah di sana akan memblokir launch yang sebenarnya jalan. `-Mode real` tidak
   tersentuh (diverifikasi: tetap membuka `CODEX_HOME=C:\Users\rahma\.codex`).

### Bug yang ditemukan oleh tesnya sendiri

Versi pertama preflight memperlakukan `WebException` sebagai "mati". Sebuah TCP listener yang
mendengar tapi tidak berbicara HTTP juga melempar itu — jadi gateway yang hidup akan dilaporkan
mati dan **setiap launch diblokir**. `test-gateway-preflight.ps1` menangkapnya dengan listener
mentah di port 20998. Sekarang: ada respons HTTP → hidup; connect berhasil → hidup; hanya
kegagalan connect yang dihitung mati.

### Batas

- Preflight memeriksa "ada yang mendengarkan", bukan "model ini dilayani". Model yang tidak
  ada di `/v1/models` tetap lolos preflight dan tetap gagal di app. Itu tugas `codex-doctor`.
- Gateway bisa hidup lalu mati di tengah sesi. Preflight tidak menolong kasus itu.

## 17. Desktop tinggal satu ikon: aplikasi asli itu ChatGPT, bukan Codex (2026-11-05)

Keputusan pemilik: **Codex = repo klon ini. Aplikasi asli namanya ChatGPT.** Jadi ikon
`Codex` (mode real) di Desktop dihapus; `Codex Clone` tetap.

Sebabnya bukan kosmetik. MSIX `OpenAI.Codex` sudah memasang Start Menu entry bernama
`ChatGPT.lnk` (`app\ChatGPT.exe`, home default `~/.codex`). Shortcut `-Mode real` adalah
nama kedua untuk launch yang sama — persis pola duplikasi yang dulu melahirkan empat ikon.
Nama `Codex` di desktop lalu dibaca sebagai "codex kedua", padahal yang klon juga bernama Codex.

Batas: `codex-launch.ps1 -Mode real` **tidak dihapus**. Ia satu-satunya jalan mendapat
re-assert config (model, sandbox) untuk akun asli; yang dihapus hanya shortcut Desktop-nya.

| berkas | perubahan |
| --- | --- |
| `scripts/install-shortcuts.ps1` | `$Shortcuts` = 1 entri (`Codex Clone`); prune menghapus `Codex.lnk` |
| `bin/shortcut-check` | "expected 1" bukan "expected 2 (one per mode)" |
| `README.md` | "Create the desktop shortcut (clone mode only)" + sebabnya |
| `docs/DESKTOP.md` | tabel 18 shortcut, `Codex` baris hilang, `Codex Clone` menunjuk repo utama |

Bukti: `bin/shortcut-check` → 8 PASS 0 FAIL; `tests/shortcut-contract.sh` → 6 PASS (INFO
"no shortcut for mode 'real'" memang diharapkan); `--selftest` 7/7; `bin/desktop-audit` →
18 shortcut, 0 rusak; `app/tests/run-tests.mjs` 9/9.

## 18. Gateway pindah ke 9router VPS, bukan loopback (2026-11-05)

Keputusan pemilik: pakai `https://router.antinrml.com/v1` (9router di `ssh antinrml`), bukan
gateway lokal yang sudah dikarantina.

### Kenapa lokal tidak dipakai lagi

`~/.9router` dikarantina 16:33 (§13) dan unit systemd-nya ikut hilang, jadi
`http://127.0.0.1:20128/v1` mati permanen sampai dipulihkan manual. VPS sudah hidup tanpa
campur tangan: container `decolua/9router@sha256:5fc7020f…` (0.5.104), traefik mengekspos
**hanya `/v1`**, dashboard tidak terbuka.

### Yang diukur, bukan diasumsikan

| probe | hasil |
| --- | --- |
| `GET /v1/models` dengan kunci VPS | **200**, 76 model |
| `POST /v1/responses` `deepseek-v4.1-flash-free` | `PONG` |
| `POST /v1/responses` + tool `exec` | `function_call {"cmd":"echo hi"}` |
| kunci lokal `sk-cb52…` ke VPS | **401** — kunci VPS beda (`~/.config/opencode/9router-vps.key`) |
| `codex exec` nyata di klon | jawaban `PONGPONG`; tool `exec` `echo VPS-TOOL-OK` jalan, 34k token |

Katalog diregenerasi dari VPS: **76 entri** (bukan 99). 23 entri hilang karena model itu
(`cx/gpt-5.6-*`, `ag/gemini-4-argon-low/medium`) hanya ada di gateway lokal.

Batas: `cx/gpt-6.1-sol` sedang kena kuota upstream (`429`, reset 30 menit), jadi jatuh ke
`deepseek-v4.1-flash-free` → `gemini-3.8-flash` lewat combo. Itu rantai fallback yang memang
diharapkan, bukan kegagalan.

### Dua bug yang muncul justru karena gateway sekarang menjawab

1. **`parse_profile` menyimpan section dengan kurung siku.** Semua lookup
   `model_providers.<id>.base_url` dan `…experimental_bearer_token` meleset. Saat gateway lokal
   mati, gejalanya "connection refused" sehingga bug ini tidak kelihatan; begitu endpoint
   ber-key, hasilnya **HTTP 401 pada gateway yang sehat**. Sekarang kurung dibuang saat parse.
2. **Home klon tidak punya `<nama>.config.toml`.** Launcher menulis satu `config.toml` yang
   sudah menyebut providernya sendiri, dan `codex-doctor` melaporkan itu sebagai
   `profiles: none` + hint `bin/codex-onboard`. Sekarang dikenali sebagai
   `inline (config.toml names nine_router)`.

Regresi dikunci `app/tests/test-doctor-parse.py` (9 assert: bracket, token, inline home, empty
home). `app/tests/test-gateway-preflight.ps1` juga berhenti memaku URL hidup — fixture sementara
untuk nilai, dan assertion terpisah bahwa profil nyata punya `base_url` apa pun isinya.

Gate: `app/tests/run-tests.mjs` **10/10**; `tests/instruct-contract.sh` 12/12;
`bin/codex-doctor` (real + klon) 9 PASS 0 FAIL; `bin/shortcut-check` 8 PASS.

## 19. Screenshot ditagih sebagai teks base64, dan context window 1 juta itu bohong (2026-11-06)

Gejala yang dilaporkan: `[400]: The prompt is too long: 1177971, model maximum context
length: 1048576`. Ternyata bukan satu bug, tapi tiga, dan dua di antaranya menjelaskan
kenapa satu sesi bisa membakar 52 juta token input untuk 172 ribu token output.

### 19a. Gambar di tool output = teks base64

Translator Responses→Chat yang **benar-benar jalan** ada di bundle, bukan di `open-sse/`:

```
/app/.next/server/chunks/8499.js
  e.messages.push({role:g.z7.TOOL,tool_call_id:a.call_id,
                   content:"string"==typeof a.output?a.output:JSON.stringify(a.output)})
```

`JSON.stringify` membuat part `input_image` jadi teks. Base64 ikut terhitung sebagai token
teks. Diukur ke gateway yang sama, PNG 1440×1000 yang sama:

| posisi gambar | delta token SEBELUM | SESUDAH |
| --- | --- | --- |
| di user message (`image_url`, jalur benar) | +1.839 | +1.839 |
| di `custom_tool_call_output` (bug) | +15.791 | **+1.835** |
| di tool output, PNG high-entropy (5,76 jt char b64) | +323.809 | **+1.835** |

Probe: `/tmp/opencode/probe_gw.py`. Angka "sesudah" diukur ulang dari container yang sudah
di-recreate dari image commit, bukan dari container sementara.

Konsekuensi di sesi nyata (`rollout-2026-11-05T04-43-34-…`): 13 screenshot = **19.096.537**
dari 52.287.140 token input (**37%**), dan diulang tiap turn sesudahnya. Kalau ditagih wajar,
13 gambar itu ~19.500 token.

Jalur Anthropic di bundle yang sama **sudah benar** — bukti bahwa bentuk yang dipakai patch
memang diterima provider:

```js
e.push({role:h.z7.TOOL,tool_call_id:c.tool_use_id,content:a}),
d.length&&(b.push({type:h.x4.TEXT,text:`[Image from tool result ${c.tool_use_id}]`}),b.push(...d))
```

Patch meniru bentuk itu: teks tetap di pesan `tool`, gambar diangkat ke pesan `user`
berikutnya. String output tidak berubah perilakunya.

### 19b. `context_window` di katalog memaksa compact terlambat

Katalog menulis `context_window = 1000000`, `effective_context_window_percent = 95`. Codex
karena itu baru compact di ~950.000 — sementara upstream menolak di 1.048.576. Dalam sesi
yang sama ada tiga lompatan yang tidak pernah di-compact:

```
286.524 -> 696.451   (+409.927)
172.190 -> 841.074   (+668.884)
190.575 -> 1.004.836 (+814.261)
```

Dari 78 sesi klon, **nol** event compaction. Sekarang launcher memaku dua key numerik
top-level tiap run klon:

```toml
model_context_window = 200000
model_auto_compact_token_limit = 150000
```

Terverifikasi di sesi nyata setelah perubahan: `token_count.info.model_context_window` =
**190000** (Codex menerapkan faktor 95% yang sama) dan `model = deepseek-v4.1-flash-free`.

⚠️ Dua jebakan saat menulis key ini, keduanya kena waktu dikerjakan:
- `Set-CloneTopLevel` menulis `key = "nilai"` bertanda kutip → tidak bisa dipakai untuk angka.
  Karena itu ada `Set-CloneNumber`.
- Key yang di-append ke akhir file jatuh ke dalam tabel terakhir (`[memories]`), dan Codex
  melaporkannya sebagai `memories.model_auto_compact_token_limit is ignored`. Key harus
  disisipkan **sebelum** header `[tabel]` pertama.

### 19c. Slug polos punya fallback, slug upstream tidak

`deepseek-v4.1-flash-free` adalah combo:
`ctx/ollama/deepseek-v4.1-flash:cloud` → `ag/gemini-3.8-flash` → `cx/gpt-6.1-sol`.
`ctx/ollama/deepseek-v4.1-flash:1017-cloud` **bukan** combo, jadi error pertama langsung
mematikan turn tanpa lompat ke upstream lain. Itu sebabnya 400 di laporan tidak pernah
diselamatkan fallback.

`bin/codex-doctor` sekarang menandai ini:

```
FAIL  model  ctx/ollama/deepseek-v4.1-flash:1017-cloud (no fallback chain)
             switch to combo deepseek-v4.1-flash-free; bare upstream slug dies on first error
```

### 19d. Prompt cache: `ctx/*` tidak punya, `cx/*` punya

| model | turns | input | cached |
| --- | --- | --- | --- |
| `ctx/conextlab/ollama/deepseek-v4.1-flash:cloud` | 1.267 | 247.171.913 | **0** |
| `ctx/ollama/deepseek-v4.1-flash:1017-cloud` | 136 | 24.293.175 | **0** |
| `cx/gpt-6.1-sol` | 48 | 2.091.228 | 1.594.880 (**76%**) |

Semua sesi: 0,58% cache hit. Tidak diperbaiki di sini — itu sifat upstream, bukan sesuatu
yang bisa dipaksa dari klien. Dicatat supaya biaya `ctx/*` tidak lagi dibandingkan apple-to-apple
dengan `cx/*`.

### Berkas

| berkas | perubahan |
| --- | --- |
| `scripts/clone-AGENTS.md` | section `## Images`: larang tool screenshot, sebut harga terukurnya |
| `scripts/codex-launch.ps1` | `Set-CloneNumber` + pin `model_context_window`/`model_auto_compact_token_limit` |
| `bin/codex-doctor` | `fetch_models` mengembalikan combo; model non-combo → FAIL + hint |
| `app/tests/test-context-keys.ps1` (baru) | 4 assert: sisip sebelum tabel, rewrite in-place, no-op byte-identik, CRLF, integer tanpa kutip |
| **VPS** `9router:patched-20261106` | bundle `8499.js` + `open-sse/.../openai-responses.js`: gambar di tool output jadi `image_url`, bukan teks |

### Gate

`app/tests/run-tests.mjs` **11/11**; `tests/shortcut-contract.sh` 6 PASS; `instruct-contract`
12 PASS; `bin/codex-doctor` (asli + klon) 9 PASS; `secret-scan` bersih; `codex exec` di klon
menjalankan tool `echo E2E-AFTER-PATCH`.

Rollback gateway: image lama `5fc7020f3cf1` masih ada; config container tercatat di
`~/9router-patch/container-config.txt` (VPS), backup kedua berkas di direktori yang sama.

## 20. Bukan context window-nya yang salah: prompt cache 0% itu akar biayanya (2026-11-06)

Permintaan: "jangan cuma perbesar context, cari tahu kenapa seboros ini". Diukur, bukan
diduga. Ternyata memperbesar/memperkecil context window nyaris tidak berpengaruh; yang
menentukan adalah **cache hit**.

### Angka dasar, satu sesi klon

```
turns                 248
input tokens     52.287.140
output tokens       172.503
input : output        303 : 1
cache hit                0%
```

Input 303x output. Itu bukan tanda model bodoh, itu tanda setiap turn membayar ulang
seluruh prefix.

### Ke mana token-nya pergi: biaya re-send, bukan ukuran

Item yang bertahan di riwayat dikirim ulang di **setiap** turn berikutnya, jadi biaya
sebenarnya sebuah item = ukuran x jumlah turn sesudahnya. Itu kuadratik, dan tidak
kelihatan di total mentah.

| kategori | bagian dari token re-sent |
| --- | --- |
| tool output (`custom_tool_call_output` + `function_call_output`) | **72,8%** |
| reasoning | 11,2% |
| message | 10,6% |
| tool call args | 5,4% |

Total re-send = **75%** dari seluruh input, 118 sesi: 209.969.683 dari 278.811.969 token.

Alat: `bin/codex-cost` (`--home`, `--all`, `--top N`). Dikunci `app/tests/test-cost.py`
(13 assert), termasuk bug yang alat itu sendiri pernah punya: whitelist ekstraksi teks
cocok ke `content: null` sebelum `summary`, sehingga reasoning dilaporkan 0%. Angka
pertama yang keluar dari alat ini **salah** dan sudah dikoreksi.

### Tuas yang diuji dan hasilnya

| hipotesis | hasil |
| --- | --- |
| context window kecil memotong biaya | 950k→200k hanya **98%→71%** dari total; di bawah 60k **mendatar di 52%**. Compaction terbukti menyala (8x dalam satu uji, reset ke ~13,4k), tapi ia mengubah bentuk biaya, bukan besarnya |
| `tool_output_token_limit` memotong | cap 8.000 hanya menyelamatkan **1,3%**; cap 2.000 pun cuma 8,0%. 246 tool output, hanya 4 yang >8k |
| effort `high` mahal | effort high 183.264 vs low 182.952 token, reasoning 1.516 vs 1.343 char. **Bukan tuas** |
| `model_reasoning_summary = "none"` | tidak mengecilkan; justru 465 char vs 101. Efeknya acak, bukan knob biaya |
| **prompt cache** | **ini tuasnya** |

### Cache: 0% vs 90%, terukur dua kali

Tugas 11 langkah identik, dua model, dua run masing-masing:

| model | input | cached | hit |
| --- | --- | --- | --- |
| `deepseek-v4.1-flash-free` (combo, `ctx/*` dulu) | 155.309 | 0 | **0,0%** |
| `cx/gpt-6.1-sol` | 214.460 | 196.992 | **91,9%** |
| `deepseek-v4.1-flash-free` | 155.983 | 0 | **0,0%** |
| `cx/gpt-6.1-sol` | 214.586 | 197.120 | **91,9%** |

Perhatikan: `cx` punya token **mentah lebih banyak** (214k vs 155k) tapi dengan cache
seharga sepersepuluh, biaya efektifnya ~**17%** dari `ctx`. Jadi mengejar jumlah token
mentah justru menyesatkan.

Sebabnya struktural: combo `deepseek-v4.1-flash-free` dimulai dengan
`ctx/ollama/deepseek-v4.1-flash:cloud`, dan **setiap** upstream `ctx/*` melaporkan cache 0.
Seluruh prefix dibayar ulang tiap turn selamanya.

Tambahan: `cx` juga memakai tokenizer lebih hemat — payload 25.000 char identik jadi
**7.490** token di `cx` vs **9.824** di `deepseek` (24% lebih sedikit).

### Yang diterapkan

1. **Combo `cache-first`** dibuat di gateway:
   `["cx/gpt-6.1-sol", "cx/gpt-6-luna", "ag/gemini-3.8-flash"]` — OpenAI-native dulu (cache
   kena), `ag/*` sebagai jalan terakhir kalau sisi OpenAI tumbang. Default klon pindah ke
   slug ini.
2. **Verifikasi di jalur Codex nyata**, bukan cuma curl: sesi 9 turn dengan combo baru →
   **cache hit 89,6%** (295.296 dari 329.746 token).
3. `bin/codex-cost` + tesnya.
4. `app/tests/test-launcher-defaults.ps1` sekarang menuntut default berupa **combo**, bukan
   slug upstream telanjang — slug telanjang tidak punya rantai fallback *dan* tidak punya cache.

### Yang TIDAK bisa diklaim

- **Kualitas di bawah compaction belum terbukti.** Uji codeword sempat memberi hasil
  "compaction lebih baik" (1 compaction, recall benar, vs tanpa compaction yang lupa), lalu
  A/B 4 run berikutnya memberi hasil campur: 3 run tanpa compaction pun recall benar, dan
  model kadang berhenti sebelum langkah final karena alasan yang tidak ada hubungannya
  dengan context. **Jangan mengutip hasil kualitas apa pun dari sesi ini.** Yang reproducible
  hanya cache. Uji kualitas butuh tugas dengan jawaban yang bisa diverifikasi mesin dan
  beberapa ulangan; itu belum dikerjakan.
- Cache 90% hanya untuk `cx/*` dan `codex-all` (69,7%). `ctx/*` tetap 0% — itu sifat
  upstream, tidak bisa dipaksa dari klien. `prompt_cache_key`/`store` sudah dicoba: tidak
  mengubah apa pun.

### Gate

`app/tests/run-tests.mjs` **12/12**; `tests/shortcut-contract.sh` 6 PASS;
`instruct-contract` 12 PASS; `secret-scan` bersih; `codex-doctor` (asli + klon) PASS dengan
77 model; `codex exec` di klon jalan pada combo `cache-first`.

## 21. Model dipaku ke DeepSeek 1017, dan Linear MCP ternyata 18,5k token/turn (2026-11-06)

Keputusan pemilik: pakai **Ollama Cloud · DeepSeek V4.1 Flash (1017)** lewat gateway VPS/SSOT
saja — `ctx/ollama/deepseek-v4.1-flash:1017-cloud`. Bukan combo.

### Harga dari keputusan itu, supaya tidak jadi teka-teki nanti

Slug ini `owned_by: "ctx"` — bare upstream, bukan combo. Dua konsekuensi terukur:

| hal | angka |
| --- | --- |
| prompt cache | **0%** (136 turn historis, 24.293.175 token input, 0 cached; diukur ulang: tetap 0) |
| rantai fallback | tidak ada — error pertama mengakhiri turn |
| tokenizer | lebih mahal: body 25.000 char identik → **10.825** token vs **8.490** di `cx` |

Bandingkan `cache-first` (combo `cx` dulu): 84–92% cache. Dengan cache sepersepuluh harga,
kerja yang sama di `cx` ~17% biaya `ctx`. Jadi pilihan ini **sengaja** lebih mahal; dicatat
di `codex-launch.ps1` dan di `bin/codex-doctor` sebagai INFO, bukan FAIL — launchnya jalan,
yang tidak boleh senyap adalah harganya.

### Temuan besar: `linear@openai-api-curated` menyuntik 18.537 token ke SETIAP turn

Ini bukan soal model. Deskripsi tool `exec` yang dikirim Codex berisi **seluruh permukaan MCP**
plugin yang aktif. Dengan Linear aktif:

```
exec tool            93.960 byte
  mcp__linear        74.150 char  ~18.537 token   (80% dari deskripsi)
  preamble           15.035 char   ~3.758 token
  mcp__node_repl      1.888 char     ~472 token
```

`say OK` biasa = **38.779 token input**. Setelah Linear dimatikan = **18.150 token**.
**Hemat 53% di setiap turn, setiap sesi**, untuk plugin yang klon ini tidak pakai.

Dibuktikan dari request body asli (proxy capture), bukan dari dugaan: `exec` 93.960 → 17.646
byte, `linear present: False`.

Sekarang `codex-launch.ps1` mematikan `linear@openai-api-curated` tiap run, dikunci
`app/tests/test-plugin-off.ps1` (3 assert, termasuk idempoten byte-safe). Real home tidak
disentuh.

### Sisa lantai biaya klon (setelah Linear mati)

`~18.150 token/turn`, terurai:

| komponen | token |
| --- | --- |
| base prompt Codex | ~5.381 |
| `AGENTS.md` | ~657 |
| memory block | ~6.061 |
| skills instructions | ~2.169–3.259 |
| tools (exec + wait + collab + cua_repl + dll) | ~5.062–8.040 |

Memory dimatikan menghemat ~2,5k (18.150 → 15.646) tapi `AGENTS.md` ikut naik karena versi
project-scoped memuat lebih banyak, jadi bersihnya ~2,5k saja. **Belum diterapkan** — menunggu
keputusan, karena memory punya fungsi nyata sedangkan Linear tidak.

### Gate

`app/tests/run-tests.mjs` **13/13**; klon menjalankan 5 shell call terpisah dengan benar pada
model 1017; `bin/codex-doctor --home ~/.codex-clone` PASS + INFO fallback.

## 22. Plugin/MCP cuma dipanggil kalau disebut (2026-11-06)

Aturan pemilik: *"hanya panggil plugin atau mcp kalau memang di mention atau disebutkan"*.

### Kenapa ini bukan sekadar aturan perilaku

Ini soal biaya. Permukaan tool sebuah plugin **disuntik ke deskripsi tool `exec`** dan dikirim
ulang tiap turn. Dua kali diukur dari request body asli, bukan dari dokumentasi:

| plugin aktif | floor `say` turn |
| --- | --- |
| linear saja | 38.779 token |
| linear mati | 18.150 |
| + computer-use, chrome/browser, codex-app-tools mati | **15.870** |

`mcp__cua_repl` sendiri 6.601 byte / ~1.650 token per turn; `exec` juga menyuntik bagian
`mcp__node_repl`. Menghapus blok `[mcp_servers.node_repl]` dari config **tidak** menghilangkan
`cua_repl` — datangnya dari plugin, bukan dari config. Jadi yang dimatikan adalah pluginnya.

### Yang diterapkan

1. `scripts/clone-AGENTS.md` dapat bagian **Plugins and MCP**: jangan panggil `mcp__*`
   spekulatif, jangan buka plugin yang tidak disebut, utamakan shell, sebut namanya kalau
   memang butuh lalu jalan tanpa itu.
2. `codex-launch.ps1` mematikan 5 plugin tiap run klon: `linear@openai-api-curated`,
   `unified-computer-use`, `computer-use`, `codex-app-tools`, `browser` (semua `@openai-bundled`),
   plus `chrome@openai-bundled` yang sudah lebih dulu.
3. `app/tests/test-plugin-off.ps1` menuntut kelimanya tetap di daftar.

### Yang hilang, dan kenapa itu tidak masalah di sini

Browser in-app, kontrol Chrome, computer use, dan API thread codex-app-tools. Ketiganya memang
tidak pernah bekerja di klon ini: browser butuh app host (PROGRESS 13), computer use butuh
allowlist per-app yang diputuskan di UI ChatGPT. Shell adalah jalur yang didukung.

Real home (ChatGPT asli) **tidak disentuh** — semua perubahan hanya di klon.

### Verifikasi perilaku, bukan cuma config

Sesi nyata setelah perubahan: hanya **satu** tool call, `exec`. Nol `mcp__*`. Floor per-turn
15.870 token (input 9.480 + tools 6.389).

### Sisa lantai

| komponen | token |
| --- | --- |
| base prompt Codex | ~5.381 |
| memory block | ~2.216 |
| tools (exec/wait/collab/request_user_input) | ~6.389 |
| skills + AGENTS.md | ~2.000 |

Memory masih aktif. Mematikannya hemat ~2.216 token/turn lagi, tapi belum diterapkan —
menunggu keputusan.
