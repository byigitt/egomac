# Contributing to EGO Mac

Thanks for the interest. EGO Mac is a personal-scale tool but PRs and issues are welcome.

## Development setup

```bash
git clone https://github.com/byigitt/egomac.git
cd egomac
swift build              # debug build (also runs from Xcode if you prefer)
bash build.sh            # release + .app bundle wrapping
open "EGO Mac.app"
```

Requirements: macOS 14+, Swift 5.9+ (Xcode 15.3 or Command Line Tools).

## Project layout

| Path | What |
| --- | --- |
| `Package.swift` | SwiftPM manifest. Single executable target `EGOMac`, depends on SwiftSoup. |
| `Sources/EGOMac/App.swift` | `NSApplication` + `NSStatusItem` + `NSPopover` setup. |
| `Sources/EGOMac/Models.swift` | `Bus`, `Line`, `LineStop`, `LineSchedule`, `RouteSamplePoint`, `StopProfile`, `EGOConfig` (v1→v2→v3 JSON migration). |
| `Sources/EGOMac/EGOClient.swift` | `actor` JSON client for `mblSrv14/service.asp` + HTML scrapers for `HatListesi` / `HareketSaatleri`. 24h disk cache for the line catalog. |
| `Sources/EGOMac/BusViewModel.swift` | `@MainActor` state container; polling, dedup, alerts, ad-hoc lookup, line catalog & schedule cache. |
| `Sources/EGOMac/RouteIndex.swift` | `actor` that records `(seq → stopNo)` from every `fetchLineBuses` call and persists per-line samples under `~/.ego-mac/route-cache/<line>.json`. |
| `Sources/EGOMac/PassTimePredictor.swift` | Tahmini geçiş saati. Live anchor → observed segment average → schedule heuristic, in priority order. |
| `Sources/EGOMac/PopoverView.swift` | Navigation stack (5 cases). Bus list, stop switcher, tap-to-expand schedule, header search/notif toggles. |
| `Sources/EGOMac/SearchView.swift` | Cross-search (lines + stops), 180 ms debounce, two-section result list. |
| `Sources/EGOMac/LineDetailView.swift` | Tabbed detail screen (Otobüsler / Duraklar / Saatler / Harita). Drives `LineStopRow` with predicted-pass-time column. |
| `Sources/EGOMac/StopDetailView.swift` | Read-only stop view with line jump + "durak kaydet" — reached via `SearchView`. |
| `Sources/EGOMac/LineMapView.swift` | SwiftUI `MapKit` view: numbered stops + polyline + heading-rotated bus markers. 20 s polling. |
| `Sources/EGOMac/MapWindowController.swift` | `NSPanel` host for `LineMapView`. Frame persistence in `UserDefaults`. |
| `Sources/EGOMac/SettingsView.swift` | Stops list (crash-safe id-binding), search, threshold, quiet hours, notification toggle. |
| `Sources/EGOMac/SearchIndex.swift` | Stops + lines search engine; OSM blob loader, EGO `HatListesiOtobus` fetch, Turkish fold. |
| `Sources/EGOMac/StopsBlob.swift` | Auto-generated. Embedded gzip+base64 OSM stop snapshot — avoids macOS Desktop TCC prompts. |
| `Sources/EGOMac/Notifier.swift` | UN + osascript fallback + `NSAlert` last-resort + DebugLog. |
| `Sources/EGOMac/Config.swift` | `~/.ego-mac/config.json` IO; auto-upgrades legacy schemas. |
| `Sources/EGOMac/VisualEffectView.swift` | `NSVisualEffectView` SwiftUI bridge. |
| `docs/api-discovery.md` | Reverse-engineered EGO endpoint catalog (live + dead) with sample `curl`s. |
| `scripts/probe-ego.sh` | Endpoint health check — run after EGO releases (CI-friendly exit code). |
| `assets/` | App icon master PNG + `AppIcon.icns`. |
| `scripts/make-icon.py` | Regenerates `icon-1024.png` from an EGO Cep'te source PNG. |
| `scripts/build-icon.sh` | Repackages the master PNG into a multi-size `.icns` via `sips` + `iconutil`. |
| `build.sh` | Release build → wrap into `EGO Mac.app` (LSUIElement, signed ad-hoc). |

## Code style

- Swift 6 strict concurrency (`@MainActor` on UI types, `actor` for the HTTP client). Don't sprinkle `@unchecked Sendable`.
- Two-space indent, 110-col soft wrap.
- Keep dependencies tiny — only SwiftSoup right now. Bundle parsing > network for fixed data.
- All UI text in Turkish (the user-facing language).
- No emojis in user-visible strings outside of UI affordances. SF Symbols for iconography.

## Reverse-engineered EGO endpoints

Full catalog: [`docs/api-discovery.md`](docs/api-discovery.md). Quick reference:

| Endpoint | Method | Use |
| --- | --- | --- |
| `egocptsrvand.ego.gov.tr/mblSrv14/service.asp?FNC=Otobusler&DURAK=N` | GET | Live + scheduled rows for a stop (JSON). |
| `egocptsrvand.ego.gov.tr/mblSrv14/service.asp?FNC=Otobus&HAT=X&DURAK=N` | GET | Every live bus on a line, ETA-sorted. |
| `www.ego.gov.tr/AjaxData/HatListesi` | POST | Full bus line catalog (`<option>` elements). |
| `www.ego.gov.tr/HareketSaatleri` | POST `hat_no1=X` | Schedule + line metadata page (~80 KB HTML). |

**Dead** endpoints (Android APK references them but the live server returns `200 OK + Content-Length: 0`):
- `egocptsrvand.ego.gov.tr/hibrit/action.asp?FNC=Duraklar|HatAra|DuraktanGecenHatlar|...`
- `egocptsrvand.ego.gov.tr/hibrit/act.asp?FNC=Hat|HatBilgileri|...`
- `egocptsrvand.ego.gov.tr/hibrit/connect/iosConn.asp` (POST returns 411 Length Required)
- Old IP `88.255.141.66/mblSrv*/service.asp` (504 Gateway Timeout, server gone).

`scripts/probe-ego.sh` confirms the live ones still work AND warns when a dead one starts returning data again. Re-run it after every EGO app update.

To rediscover endpoints from a fresh APK:

```bash
# Get current APK url (Aptoide — change package version as needed):
curl -s 'https://ws75.aptoide.com/api/7/app/get?package_name=com.ego.android' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["nodes"]["meta"]["data"]["file"]["path"])'
# Then: download → unzip → strings on lib/x86_64/libapp.so → grep for service.asp / FNC=
```

## Stop name data

The bundled OSM snapshot in `Sources/EGOMac/StopsBlob.swift` is regenerated
from OpenStreetMap via Overpass:

```bash
curl -G "https://overpass-api.de/api/interpreter" \
  --data-urlencode 'data=[out:json][timeout:25];area["name"="Ankara"]->.a;(node["highway"="bus_stop"]["ref"](area.a););out body;' \
  > /tmp/ankara_stops.json

python3 - <<'PY'
import json, gzip, base64
raw = json.load(open('/tmp/ankara_stops.json'))
out = []
for e in raw['elements']:
    t = e.get('tags', {})
    ref, name = t.get('ref', '').strip(), t.get('name', '').strip()
    if ref.isdigit() and len(ref) == 5:
        out.append({'r': ref, 'n': name})
out = list({s['r']: s for s in out}.values())
out.sort(key=lambda x: x['r'])
payload = json.dumps({'stops': out}, ensure_ascii=False).encode()
gz = gzip.compress(payload, 9)
b64 = base64.b64encode(gz).decode('ascii')
chunks = [b64[i:i+78] for i in range(0, len(b64), 78)]
with open('Sources/EGOMac/StopsBlob.swift', 'w') as f:
    f.write('enum StopsBlob {\n    static let base64: String = """\n')
    for c in chunks: f.write('        ' + c + '\n')
    f.write('        """\n}\n')
print(f'wrote {len(out)} stops')
PY
```

Then `swift build` to verify the embedded blob still decodes.

## Testing

There is no formal test suite (yet). Smoke checklist:

- `swift build` clean
- `bash build.sh` produces a runnable `EGO Mac.app`
- Add 2 stops, delete one — must not crash
- Search "kızılay" → results appear
- Search "481" → line appears
- Threshold notification fires (set threshold high to force one)

Verbose runtime log lives at `~/.ego-mac/debug.log` — `tail -f` it while testing.

## Sending PRs

- Open an issue first for non-trivial work.
- Keep PRs focused; one logical change per PR.
- Describe what you tested manually.

## License

By contributing, you agree your contributions are licensed under the project's MIT license.
