# EGO Mac

Native macOS menu bar app to track Ankara EGO buses, with EGO Cep'te–themed UI and 5-minutes-before-arrival notifications. Built with Swift + AppKit/SwiftUI.

> Dock'ta yer kaplamayan, sağ üstte saatin yanında duran bir EGO Cep'te. Menü çubuğunda otobüsünün kaç dakika sonra geleceğini canlı görür, eşik altına düşünce bildirim alırsın.

[![Swift 5.9+](https://img.shields.io/badge/swift-5.9+-orange)]() [![macOS 14+](https://img.shields.io/badge/macOS-14+-blue)]() [![License: MIT](https://img.shields.io/badge/license-MIT-green)]()

## Özellikler

- **Çoklu durak**: her durak kendi adı, numarası, izlenen hatlarıyla. Üstte pill-tab switcher.
- **Canlı sayım**: menü çubuğunda en yakın izlenen otobüsün ETA'sını gösterir, ` 4'`.
- **Hızlı sorgu**: popover'ın üstündeki search'e 5 haneli durak numarası yaz → kaydetmeden anlık sonuç. "Durak olarak kaydet" ile tek tıkla profile ekle.
- **Search**: durak adı (`kızılay`, `güvenpark`) veya hat (`481`, `balgat`) ile ara, listeden tıkla → otomatik dolar. 2943 OSM Ankara durağı bundle'da, 657 EGO otobüs hattı canlı.
- **Tap-to-expand**: bus satırına tıkla → plaka, araç ID, hız, durak konumu, aynı hattan diğer canlı otobüsler, bu duraktan yaklaşan kalkışlar.
- **Bildirim ayarı**: master toggle (header'da çan ikonu / Settings'te switch) — bildirimleri tek tıkla sustur, menü çubuğundaki countdown çalışmaya devam etsin.
- **Akıllı polling**: ETA ≤ 8 dk → 20 sn, ≤ 15 dk → 30 sn, aksi 90 sn. 23:00–06:00 sessiz saatler.
- **Dedup**: aynı plaka için bir kez bildirim.
- **EGO Cep'te tema**: kırmızı header, yeşil/pembe satır arkaplanları (yaklaşıyor / "Gidiyor"), kare kırmızı badge.
- **Açılışta otomatik başlama**: Login Items'a ekleyince Mac her açıldığında menü çubuğunda hazır.

## Ekran görüntüsü

```
🍎 Helium  …                          🚌 4'  …
                                       ↓ tıkla
              ┌──────────────────────────────────┐
              │ ⟳   Otobüs Nerede?      🔔 ⚙ ⏻ │
              │     ANKARA BÜYÜKŞEHİR BELEDİYESİ │
              ├──────────────────────────────────┤
              │ 🔍 durak numarası ile sorgula …  │
              ├──────────────────────────────────┤
              │ 📍 12207  Güvenpark      🔔 2    │
              ├──────────────────────────────────┤
              │ [Ev (12207)] [İş (10940)] [+]    │
              ├──────────────────────────────────┤
              │ ┌──┐  UYANIŞ-KIZILAY-BALGAT      │
              │ │481│  06 DDT 110 · Hız:0  4 dk  │
              │ └──┘                       57/24 │
              │                                  │
              │ ┌──┐  ETLİK-BAKANLIK-BALGAT      │
              │ │263-7│ 06 HO 1137  · Hız:34  Gidiyor│
              │ └──┘                       57/57 │
              └──────────────────────────────────┘
```

## Kurulum

### Hazır build (önerilen)

```bash
git clone https://github.com/byigitt/egomac.git
cd egomac
bash build.sh
cp -R "EGO Mac.app" /Applications/
open "/Applications/EGO Mac.app"
```

İlk açılışta:

- Gatekeeper uyarısı → **Sistem Ayarları → Gizlilik ve Güvenlik → "Yine de Aç"**
- Bildirim izni isterse **İzin Ver**

Login Items'a ekle: **Sistem Ayarları → Genel → Giriş Öğeleri ve Eklentiler → "+" → /Applications/EGO Mac.app**

### Kaynaktan geliştirme

```bash
swift build      # debug
swift run        # çalıştırırken (.app değil, sadece binary)
```

`.app` paketleme `build.sh` ile.

## Yapılandırma

Tüm ayarlar uygulama içinden — **⚙ ikonuna tıkla**. Diskte: `~/.ego-mac/config.json`.

- **Duraklar**: aç/kapa, ad, durak numarası (search ile), izlenen hatlar (chip ekle/sil)
- **Bildirim**: master toggle, test butonu, "Sistem Ayarları"na deep-link
- **Eşik**: 1–30 dk, slider + ± step
- **Sessiz saatler**: 24h picker
- **Çoklu durak**: "+ Yeni durak ekle"

## Mimari

```
Sources/EGOMac/
├── App.swift              NSStatusItem + NSPopover entry
├── Models.swift           Bus / StopProfile / EGOConfig (v1→v2→v3 migration)
├── EGOClient.swift        Cookie-priming HTTP + parallel fetch + SwiftSoup parse
├── BusViewModel.swift     @MainActor; polling, dedup, alerts, ad-hoc lookup
├── PopoverView.swift      EGO Cep'te theme; tap-to-expand schedule; switcher
├── SettingsView.swift     Crash-safe stops list, search, threshold, quiet hours
├── SearchIndex.swift      OSM stops + EGO line list (Turkish-fold fuzzy match)
├── StopsBlob.swift        Auto-generated; embedded OSM snapshot
├── Notifier.swift         UN + osascript fallback + NSAlert + DebugLog
├── Config.swift           ~/.ego-mac/config.json IO
└── VisualEffectView.swift NSVisualEffectView SwiftUI bridge
```

Detaylı geliştirici notları için → [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Veri kaynakları

| Kaynak | Ne için |
| --- | --- |
| `POST https://www.ego.gov.tr/otobusnerede` `durak_no=…` | Canlı otobüs + planlı saatler |
| `POST https://www.ego.gov.tr/AjaxData/HatListesiOtobus` | Tüm bus hat listesi (search) |
| Embedded OSM snapshot (2943 durak) | Stop name/number search |

EGO mobile API (`88.255.141.70/mobil/iphonenew/*`) kalıcı olarak HTTP 410/504 dönüyor; OSM + HatListesiOtobus ile ilerliyoruz.

## Sorun giderme

**Menü ikonu 1 saniye görünüp kayboluyor** — Notch'lu MacBook'larda menü çubuğu doluysa ikon arka tarafa itilir. `⌘ + sürükle` ile sola çek.

**Bildirim gelmiyor** — Settings'te toggle açık mı kontrol et; "Test bildirim gönder" butonu ile dene; gelmezse "Bildirim izni kapalı" banner'ı çıkar, oradan Sistem Ayarları → Bildirimler'e tek tıkla.

**Desktop TCC izin penceresi** — `.app`'i Desktop'tan çalıştırırsan macOS dosya erişimi sorar. `/Applications`'a kopyala (Settings'te otomatik taşıma butonu var).

**Aynı otobüs için 2 bildirim** — EGO bazen vehicleId'yi rotate ediyor; dedup plate (kalıcı) anahtarına gore yapılıyor. Yine de olursa issue aç.

**Hat arama yavaş** — İlk arama 657 hattı çekerken bir kez ~1 sn sürer, sonrası anlık (in-memory cache).

## Yasal

Bu proje **resmi olmayan üçüncü taraf bir araçtır**. Ankara Büyükşehir Belediyesi veya EGO Genel Müdürlüğü ile bağlantısı yoktur, onaylı değildir. "EGO" ismi ve EGO Cep'te logosu sahiplerinin tescilli markalarıdır; burada yalnızca uygulamanın hangi toplu taşıma verisini kullandığını tanımlamak için (nominative fair use) yer almıştır.

Durak verisi OpenStreetMap (© OpenStreetMap contributors, ODbL).

Lisans: [MIT](LICENSE) — kişisel ve ticari kullanım serbest, garanti yok.

## Yazar

**Barış Cem Bayburtlu** — [@byigitt](https://github.com/byigitt)
