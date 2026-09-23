# Paperclip kurulumu (magmarta fork)

Bu fork, Paperclip'i **kendi altyapımızda, dışarı veri sızdırmadan** çalıştırmak
için kullanılır. Uygulama konteyner içinde değil, doğrudan host üzerinde bir
systemd servisi olarak çalışır.

Gizlilik yamalarının gerekçeleri ayrı bir belgede:
[`.github/FORK-POLICY.md`](.github/FORK-POLICY.md).

---

## Ne kuruluyor

| Bileşen | Nerede |
|---|---|
| Paperclip sunucusu (Node.js 24) | `paperclip.service`, `/opt/paperclip` |
| Gömülü PostgreSQL | `/var/lib/paperclip/instances/default/db` — ayrı DB kurulumu gerekmez |
| Rust runner ikilisi | derleme sırasında üretilir (`rust-toolchain.toml` sürümü ile) |
| Ajan CLI'ları | `claude`, `codex`, `opencode`, `gemini`, `kimi` — global npm |
| Docker Engine | ajanların izole workspace/sandbox sağlayıcıları için (Paperclip'in kendisi Docker'da çalışmaz) |

## Gereksinimler

- Debian 12/13 veya Ubuntu 22.04+ , `amd64` veya `arm64`
- root erişimi, systemd
- İnternet (derleme sırasında npm + crates.io + nodejs.org)
- Öneri: 4 vCPU / 8 GB RAM / 40 GB disk. İlk derleme 4 çekirdekte **15–30 dk** sürer.

---

## Kurulum

```sh
scp install-paperclip.sh root@HEDEF:/root/
ssh root@HEDEF 'bash /root/install-paperclip.sh'
```

Betik depoda da var: `scripts/magmarta-install.sh`.

Betik yeniden çalıştırılabilir. Üretilmiş secret'ları ve veritabanını korur,
yalnızca eksikleri tamamlar.

Bittiğinde erişim adresini, veri dizinini ve servis komutlarını ekrana yazar.

### Seçenekler

| Seçenek | Varsayılan | Açıklama |
|---|---|---|
| `--repo URL` | `https://github.com/magmarta/paperclip.git` | Kaynak depo |
| `--ref REF` | `master` | Branch / tag / commit |
| `--port N` | `3100` | Dinlenecek port |
| `--public-url URL` | `http://<birincil-ip>:<port>` | Kullanıcıların eriştiği taban URL |
| `--app-dir DIZIN` | `/opt/paperclip` | Uygulama dizini |
| `--data-dir DIZIN` | `/var/lib/paperclip` | DB, workspace, yüklemeler |
| `--mode MOD` | `authenticated` | `authenticated` \| `local_trusted` |
| `--telemetry on\|off` | `off` | Birinci-taraf telemetri |
| `--allowed-hostnames L` | `*.c-prot.local,*.marta.tr` | Ek hostname listesi, wildcard kabul eder |
| `--allowed-signup-emails L` | _(boş)_ | Hesap açabilecek e-postalar; boş = kısıtlama yok |
| `--no-docker` | — | Docker Engine kurma |
| `--no-agent-clis` | — | Ajan CLI'larını kurma |
| `--update` | — | Sadece güncelle (aşağıya bakın) |

Her seçeneğin `PAPERCLIP_*` ortam değişkeni karşılığı da var
(`PAPERCLIP_PORT`, `PAPERCLIP_DATA_DIR`, `PAPERCLIP_ALLOWED_HOSTNAMES` …).

### Örnekler

```sh
# Kendi alan adıyla
bash install-paperclip.sh --public-url http://paperclip.marta.tr:3100

# Sandbox istemiyorsan Docker'sız
bash install-paperclip.sh --no-docker

# Hostname listesini daralt
bash install-paperclip.sh --allowed-hostnames "*.marta.tr"
```

---

## Kurulumdan sonra

### 1. İlk yönetici hesabı

Arayüzü aç (`--public-url` ile verdiğin adres) ve ilk hesabı oluştur.
Bu yapılana kadar `/api/health` `bootstrapStatus: bootstrap_pending` döner.

### 2. Model bağlama

**Connect a model → Claude → Subscription** ekranında **Sign in from this
browser** kutusunu kullan:

1. `Start sign-in` → sunucu CLI'ı kendisi başlatır ve bir link verir
2. Linki aç, yetkilendir, dönen kodu kopyala
3. Kodu web'deki kutuya yapıştır → `Verify`
4. `Connect`

SSH gerekmez. Kimlik dosyaları servis kullanıcısı adına oluşur.

**Alternatif — terminalden:** tarayıcı sunucuya ulaşamıyorsa

```sh
ssh root@HEDEF
paperclip-login            # Claude
paperclip-login codex      # OpenAI Codex
paperclip-login grok       # Grok
```

Terminalin CLI'ın tam ekran arayüzüne yapıştırmaya izin vermiyorsa iki adımlı
modu kullan:

```sh
paperclip-login --start        # linki basar, kodu bekler
paperclip-login --code <KOD>   # kodu normal kabuk satırına yapıştırırsın
paperclip-login --cancel       # bekleyen girişi iptal eder
```

> `claude auth login` komutunu **elle root ile çalıştırma**. Kimlik dosyaları
> root sahipli kalır, servis onları silemez ve akış `Internal server error`
> verir. Yukarıdaki iki yol da bunu yapısal olarak engeller; olmuşsa servisi
> yeniden başlatmak (`systemctl restart paperclip`) sahipliği onarır.

### 3. Kimler hesap açabilir

İnternete açık bir panelde kayıt varsayılan olarak **herkese** açıktır. Yalnızca
belirli adreslerin hesap açabilmesi için allowlist'i doldurun:

```sh
paperclip-allow-email list
paperclip-allow-email add 'hasan@marta.tr'
paperclip-allow-email add '*@martateknoloji.com.tr'   # tüm alan adı
paperclip-allow-email remove hasan@marta.tr
paperclip-allow-email clear                            # kısıtlamayı kaldır
```

Komut hem `/etc/paperclip-install.conf` hem `/etc/paperclip.env` dosyasını
günceller ve servisi yeniden başlatır. Listede olmayan bir adresle kayıt
denemesi `403 SIGNUP_EMAIL_NOT_ALLOWED` döner.

`*@marta.tr` → `a@marta.tr` geçer; `a@alt.marta.tr` ve `a@sahte-marta.tr`
geçmez. Alt alan adını ayrıca ekleyin.

> Davet akışı kayıt gerektirir: davetli kişi önce hesap açar, sonra daveti
> kabul eder. Bu yüzden `PAPERCLIP_AUTH_DISABLE_SIGN_UP=true` kullanmayın —
> davetlileri de kilitler. Doğru araç bu allowlist'tir.
> Gerekçe: [`.github/FORK-POLICY.md`](.github/FORK-POLICY.md) **(i)**.

### 4. Alan adıyla erişim

`PAPERCLIP_ALLOWED_HOSTNAMES` listesinde olmayan bir hostname `403 This
hostname is not allowed` döner. Liste `/etc/paperclip.env` içindedir ve
`*.suffix` wildcard kabul eder:

```
PAPERCLIP_ALLOWED_HOSTNAMES=10.0.0.5,sunucu,localhost,127.0.0.1,*.c-prot.local,*.marta.tr
```

`*.marta.tr` → `panel.marta.tr` ve `a.b.marta.tr` geçer; apex `marta.tr` ve
benzer görünen `marta.tr.baska.com` geçmez. Apex'i ayrıca ekle.

Değişiklikten sonra: `systemctl restart paperclip`.

### 5. Projeleri alan adıyla yayınlama (preview)

Ajanların geliştirdiği bir uygulamayı gerçek bir adresten açmak için
`paperclip-preview` kullanılır. Komut üç şeyi birlikte yönetir: Cloudflare DNS
kaydı, Cloudflare Access politikası ve nginx vhost'u. Üçünü elle kurmayın —
elle yazılmış bir vhost ezilir, elle açılmış bir DNS kaydı da silinmez.

```sh
PORT=$(sudo paperclip-preview port my-app)   # projeye sabit port ayır
# ... uygulamayı 127.0.0.1:$PORT üzerinde başlat ...
sudo paperclip-preview add my-app            # yayına al

sudo paperclip-preview add my-app 8080       # zaten çalışan bir portu bağla
sudo paperclip-preview list                  # hepsi + dinleniyor mu
sudo paperclip-preview status my-app
sudo paperclip-preview rm my-app             # DNS + Access + vhost sil
```

İsim→port haritası kalıcıdır: aynı proje her zaman aynı portu alır. Panelin ve
veritabanının portları (`3100`, `54329`, …) preview'a bağlanamaz, `asistan`
gibi altyapı isimleri rezervedir.

**Her preview Cloudflare Access arkasındadır.** Ziyaretçi, istek sunucuya
ulaşmadan önce izin listesindeki bir e-postayı doğrular. Geliştirme sunucularının
çoğunda kimlik doğrulama olmadığı, debug uçları ve veritabanı arayüzleri açıkta
kaldığı için varsayılan budur. İzinli adresler `/etc/paperclip-preview.conf`
içindeki `ACCESS_EMAILS` listesindedir; liste **boşsa Access kurulmaz ve preview
herkese açık olur**.

Yapılandırma (mod `600`, Cloudflare token'ı burada durur):

```
/etc/paperclip-preview.conf
```

Gereken Cloudflare token yetkileri: `Zone:DNS:Edit`, `Zone:Zone:Read`,
`Account:Access Apps and Policies:Edit`, `Account:Account Settings:Read`.
Ayrıca `*.<alanadı>` ve `<alanadı>` kapsayan bir **Origin CA sertifikası**
gerekir (`PREVIEW_CERT` / `PREVIEW_KEY`).

Ajan bu komutu `sudo` ile çağırabilir (yalnızca bu komut için, parolasız).
Token'ı görmesi gerekmez.

> **Statik siteler için bunu kullanmayın.** Derleme gerektirmeyen HTML/CSS/JS
> bir site Cloudflare Workers'a `wrangler deploy` ile çıkılır: sunucu, nginx,
> port ve sertifika gerekmez, `custom_domain` route'u DNS kaydını kendisi açar.
> `paperclip-preview` backend'i, dev server'ı ya da Docker servisi olan işler
> içindir. Ajan tarafındaki anlatımı `publish-preview` skill'inde.

---

## Güncelleme

```sh
ssh root@HEDEF 'bash /root/install-paperclip.sh --update'
```

`git pull` + yeniden derleme + servis restart. Secret'lar ve veritabanı korunur.
Sunucu kodu değişmediyse derleme artımlıdır ve kısa sürer.

Fork'un upstream ile senkronizasyonu **otomatiktir**: her gün 03:00 UTC'de
`.github/workflows/sync-upstream.yml` çalışır, `paperclipai/paperclip`'i merge
eder ve tüm fork yamalarının yerinde olduğunu doğrular. Elle tetiklemek için:

```sh
gh workflow run sync-upstream.yml -R magmarta/paperclip
```

> `gh repo sync` **kullanma**. Fork kendi commit'lerini taşıdığı için
> fast-forward reddedilir, `--force` ise tam da korunması gereken yamaları siler.

Senkronizasyon `.github/workflows/**` dosyalarına dokunan bir merge push
edeceği için repoda `SYNC_PAT` secret'ı gerekir (`repo` + `workflow` yetkili
PAT). Yoksa merge yapılır ama push reddedilir ve workflow bunu job summary'de
raporlar.

---

## Servis yönetimi

```sh
systemctl status paperclip
systemctl restart paperclip
journalctl -u paperclip -f
```

| Dosya | İçerik |
|---|---|
| `/etc/paperclip.env` | Tüm ortam ayarları ve secret'lar (mod `640`, `root:paperclip`) |
| `/etc/paperclip-install.conf` | Kurulum seçenekleri; `--update` bunları korur (mod `600`) |
| `/etc/systemd/system/paperclip.service` | Unit dosyası |
| `/var/lib/paperclip` | Veritabanı, workspace'ler, yüklemeler, model kimlikleri |
| `/usr/local/bin/paperclip-login` | Model giriş yardımcısı |
| `/usr/local/bin/paperclip-allow-email` | Kayıt allowlist'i yönetimi |
| `/usr/local/bin/paperclip-preview` | Preview yayınlama (DNS + Access + nginx) |
| `/etc/paperclip-preview.conf` | Cloudflare token'ı ve preview ayarları (mod `600`) |
| `/var/lib/paperclip-preview/ports.map` | Proje→port haritası, kalıcı |
| `/usr/local/bin/paperclip-repair-perms` | Her serviste izin onarımı (`ExecStartPre`) |

### Yedekleme

İki şey yeterli:

```sh
systemctl stop paperclip
tar czf paperclip-backup.tgz /var/lib/paperclip /etc/paperclip.env
systemctl start paperclip
```

`BETTER_AUTH_SECRET` kaybolursa tüm oturumlar geçersiz olur, o yüzden
`/etc/paperclip.env` yedeği veritabanı kadar önemlidir.

---

## Gizlilik

Bu fork'ta beş dış veri yolu **kaynak kodda kalıcı olarak kapalıdır**; ortam
değişkeniyle geri açılamaz:

| | Kapatılan | Hedef |
|---|---|---|
| a | Telemetri | `telemetry.paperclip.ing` |
| b | Feedback trace paylaşımı | `telemetry.paperclip.ing` |
| c | Duyuru akışı | `pages.paperclip.ing` |
| d | Sentry hata raporlama | Sentry |
| e | Paperclip Cloud connector | `my.paperclip.app` |

Doğrulama:

```sh
ss -tnp | grep -E 'paperclip\.(ing|app)'   # çıktı olmamalı
```

**Kapsam dışı:** ajan CLI'ları (`claude`, `codex`, `gemini` …) çalıştıklarında
prompt'ları ve kod bağlamını kendi model sağlayıcılarına gönderir. Bu ürünün
işleyişidir, sızıntı değildir — asıl karar hangi ajana hangi repo'yu verdiğindir.

Gerekçeler ve `(f)`, `(g)` operasyonel yamaları için
[`.github/FORK-POLICY.md`](.github/FORK-POLICY.md).

---

## Sorun giderme

| Belirti | Sebep / çözüm |
|---|---|
| `403 This hostname is not allowed` | Hostname listede yok → `PAPERCLIP_ALLOWED_HOSTNAMES` düzelt, restart |
| Model bağlarken `Internal server error` | Veri dizininde root sahipli dosya → `systemctl restart paperclip` onarır |
| Kodu terminale yapıştıramıyorum | Tarayıcı akışını kullan, ya da `paperclip-login --start` / `--code` |
| `Start sign-in` link vermiyor | CLI PATH'te değil → `--no-agent-clis` ile kurulmuş olabilir; `npm i -g @anthropic-ai/claude-code` |
| Servis açılmıyor | `journalctl -u paperclip -n 80 --no-pager` |
| Derleme belleği yetmiyor | Betik `NODE_OPTIONS=--max-old-space-size=4096` kullanır; 8 GB altı RAM'de swap ekleyin |
| Sync workflow kırmızı | Job summary'de çakışan dosyalar listelenir; yamayı koruyarak elle merge edin |
