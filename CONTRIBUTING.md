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
| `Sources/EGOMac/Models.swift` | `Bus`, `StopProfile`, `EGOConfig` (with v1→v2→v3 JSON migration). |
| `Sources/EGOMac/EGOClient.swift` | `actor` HTTP client; cookie-priming, parallel multi-stop fetch, `SwiftSoup` parsing. |
| `Sources/EGOMac/BusViewModel.swift` | `@MainActor` state container; polling loop, dedup, alerts, ad-hoc lookup. |
| `Sources/EGOMac/PopoverView.swift` | EGO Cep'te–themed list view, stop switcher, tap-to-expand schedule. |
| `Sources/EGOMac/SettingsView.swift` | Stops list (crash-safe id-binding), search, threshold, quiet hours, notification toggle. |
| `Sources/EGOMac/SearchIndex.swift` | Stops + lines search engine; OSM blob loader, EGO `HatListesiOtobus` fetch, Turkish fold. |
| `Sources/EGOMac/StopsBlob.swift` | Auto-generated. Embedded gzip+base64 OSM stop snapshot — avoids macOS Desktop TCC prompts. |
| `Sources/EGOMac/Notifier.swift` | UN + osascript fallback + `NSAlert` last-resort + DebugLog. |
| `Sources/EGOMac/Config.swift` | `~/.ego-mac/config.json` IO; auto-upgrades legacy schemas. |
| `Sources/EGOMac/VisualEffectView.swift` | `NSVisualEffectView` SwiftUI bridge. |
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

## Reverse-engineered EGO endpoints (current as of 2026-05)

| Endpoint | Method | Use |
| --- | --- | --- |
| `https://www.ego.gov.tr/otobusnerede` | GET | Cookie-prime (`TS01df…` F5 BIG-IP cookie). |
| `https://www.ego.gov.tr/otobusnerede` | POST `durak_no=NNNNN` | Live buses + scheduled rows for a stop. HTML response, parse `div.bus-card`. |
| `https://www.ego.gov.tr/AjaxData/HatListesiOtobus` | POST | Full bus line list (`<option>` elements). Server ignores any body params. |

Dead endpoints (HTTP 410 / 504, do not rely on):
- `http://88.255.141.70/mobil/iphonenew/durak.asp?Fnc=DurakAra&...`
- `http://88.255.141.70/mobil/iphonenew/hat.asp?Fnc=HatAra&...`
- `https://www.ego.gov.tr/mobil/iphonenew/*`

If any of these return real data again, see `EGOClient.swift` for where to wire them in.

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
