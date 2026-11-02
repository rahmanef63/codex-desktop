# Progress — Codex Desktop ↔ 9router

Catatan kerja, bukan dokumentasi produk. Ditulis supaya sesi berikutnya tidak mengulang
penyelidikan yang sama. Repo produk ada di `/home/rahman/projects/lara/codex-clone-placeholder`;
berkas ini soal setup mesin, bukan repo.

Terakhir diperbarui: 2026-11-02, setelah `bin/isolation-check` (bagian 8).

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

Codex Desktop (MSIX `OpenAI.Codex 26.1027.3384.0`) membaca home dari `CODEX_HOME`, fallback
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
