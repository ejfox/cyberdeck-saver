# Cyberdeck Screensaver

A native macOS screensaver (`.saver` bundle) written in Swift + Metal. A 5×5 grid
of terminal-style panels types itself out with real-time data from personal APIs,
public OSINT feeds, and a personal scrapbook — all post-processed through a CRT
shader chain in the vulpes palette.

No fake data. Every byte on screen comes from an actual API or system call.

## Panels

25 panels across 5 rows. Each is independently config-driven; grid auto-scales to
the active panel count.

### Row 0 — airspace + threat intel
- **clock** — local time, date, uptime (local)
- **skywatch** — Hudson Valley airspace aggregate (`skywatch.tools.ejfox.com`)
- **ads-b** — live aircraft states via OpenSky Network
- **anomaly** — cross-source anomaly detection (`anomalywatch.tools.ejfox.com`)
- **urlhaus** — recent malicious URL reports (abuse.ch URLhaus)

### Row 1 — comms + geophysical
- **briefings** — daily intelligence briefings (`briefings.tools.ejfox.com`)
- **github** — commit/repo/follower stats via `/api/stats`
- **last.fm** — now playing + recent scrobbles
- **mastodon** — recent posts
- **usgs** — earthquakes ≥ 2.5 magnitude, last 24h

### Row 2 — personal telemetry + geospace
- **health** — Apple Health steps/exercise/stand
- **system** — host/darwin/arch/cpu/mem/thermal
- **rescuetime** — weekly category breakdown
- **stats** — weekly aggregate (productive hours, efficiency)
- **solar** — NOAA SWPC planetary K-index

### Row 3 — skills + orbit
- **chess** — chess.com ratings (rapid/blitz/bullet)
- **monkeytype** — typing stats
- **leetcode** — problems solved by difficulty
- **words** — monthly writing output
- **iss** — ISS position + distance from your configured location

### Row 4 — scrapbook
All five hit `config.apis.scraps` (defaults to `ejfox.com/api/scraps`) and share
one fetch across every panel and every display via the process-global cache.

- **archive** — latest scraps ingested (title + source marker)
- **entities** — top people/orgs/places from extracted relationships
- **facts** — recent claim triples (subject → predicate → object)
- **trending** — entities spiking in the last 50 scraps vs baseline
- **memory** — random dredge of one scrap, summary shown (rotates per refresh)

Optional scrapbook streams (implemented; edit config to slot them in):
- **places** — geocoded scraps sorted by proximity to you
- **concepts** — concept_tag frequency bars
- **intake** — freshest scrap from each of pinboard/arena/github/mastodon

## Config

One canonical path:
```
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/CyberdeckSaver/config.json
```

That's inside the sandbox container — don't navigate there manually. Instead:

```bash
make edit-config   # opens in $EDITOR, kills legacyScreenSaver on save
make config-path   # prints the absolute path
```

First run writes a defaults template. Key fields:

```json
{
  "location": { "lat": 41.93, "lon": -74.0, "label": "hudson valley" },
  "airspace": { "minLat": 41.0, "maxLat": 42.5, "minLon": -75.0, "maxLon": -73.0 },
  "apis": { "scraps": "https://ejfox.com/api/scraps", "...": "..." },
  "render": {
    "glitch": false,
    "forceMode": null,
    "fontSize": 12,
    "textRedrawHz": 60
  },
  "panels": [ /* 25 slots — edit names, streams, refreshInterval, rotation */ ]
}
```

Environment override for dev/testing (requires `launchctl setenv` since screensavers don't inherit shell env):
```bash
launchctl setenv CYBERDECK_CONFIG /path/to/alt.json
launchctl setenv CYBERDECK_DEBUG 1
```

## Panel rotation

Any slot can rotate through multiple streams:

```json
{
  "name": "intel",
  "streams": ["briefings", "anomaly", "urlhaus"],
  "typingSpeed": 1200,
  "refreshInterval": 60,
  "rotationInterval": 90
}
```

Streams cycle every `rotationInterval` seconds with a 0.5s fade at each
boundary. `rotationInterval: 0` (default) disables rotation.

## Hero terminal panels

Two dynamic-id forms for real terminal output:

- `"shell:top -l 1 -n 10 -o cpu"` — runs a local command via `Process`
- `"term:vps@https://vps.example.com/api/top"` — polls a URL for plain text

Both strip ANSI and render in the vulpes palette. Note: `shell:` is restricted
inside the `legacyScreenSaver` sandbox — system binaries like `/usr/bin/top` or
`/bin/ps` work; arbitrary paths may silently fail and render "failed to run".

## Shaders

All ported from the vulpes Ghostty shader stack:

- **bloom** — red-selective neon glow (24-point Fibonacci sphere sampling)
- **tft** — LCD subpixel mask (3px grid, 26% strength)
- **vignette** — 15% edge darkening
- **scanline** — CRT flicker (slow drift + fast pulse)
- **glitch** — chromatic aberration + analog distortion (opt-in via config)

Auto-detects GPU. Apple Silicon runs the full chain at 60fps; Intel runs
vignette + scanline only at 30fps (bloom is the expensive one). Override with
`render.forceMode` = `"full"` or `"lite"`.

## Building

```bash
# Xcode Metal toolchain, first time only
xcodebuild -downloadComponent MetalToolchain

# Universal (arm64 + x86_64)
make

# Build + install to ~/Library/Screen Savers
make install

# Edit your config
make edit-config

# Zip for AirDrop
make zip
```

Then System Settings → Screen Saver → scroll to "Other" → **Cyberdeck**.

## Perf monitoring

Every 5s the saver emits a perf line to the unified log:

```
perf: 59.8 fps | CT 24.0hz avg 2.1ms | GPU avg 1.3ms max 3.8ms | dirty avg 1.8
```

View with:
```bash
log show --predicate 'eventMessage CONTAINS "perf:"' --last 5m --info
```

- **fps** — display link tick rate (should be ~60 on Apple Silicon)
- **CT hz / avg ms** — Core Text redraw rate + mean duration per pass
- **GPU avg / max ms** — Metal command buffer round-trip
- **dirty avg** — mean number of panels redrawn per CT pass. Idle = ~1-2.

## Architecture

```
Sources/
├── CyberdeckSaverView.swift   — ScreenSaverView, lifecycle, display link host
├── DisplayLink.swift          — NSView.displayLink wrapper (macOS 14+)
├── Renderer.swift             — Metal pipeline + shader chain
├── TextEngine.swift           — panels, typing, rotation, partial rasterization
├── PanelLayout.swift          — grid math (count → cols/rows)
├── Vulpes.swift               — palette + DataStream protocol + helpers
├── Config.swift               — JSON schema + loader
├── ApiClient.swift            — shared URLSession + error classification
├── StreamCache.swift          — process-global fetch dedup
├── StreamFactory.swift        — string IDs → DataStream instances
├── Diag.swift                 — log helpers, debug gate
├── PerfMonitor.swift          — fps/CT/GPU timing aggregation
├── SystemStreams.swift        — clock, system (local, no network)
├── PersonalStreams.swift      — github, last.fm, chess, monkeytype, etc.
├── OSINTStreams.swift         — skywatch, anomaly, briefings
├── RealtimeStreams.swift      — usgs, solar, iss, urlhaus, ads-b
├── ScrapbookStreams.swift     — archive, entities, facts, trending, memory, places, concepts, intake
└── TerminalStreams.swift      — shell: and term: dynamic streams

Shaders/
└── Shaders.metal              — bloom, tft, vignette, scanline, glitch
```

### Rendering pipeline

1. Each panel independently fetches data and types characters at its own speed
2. Only panels marked dirty (typing progress, fetch result, cursor pulse, rotation) re-rasterize
3. Each dirty panel's rect is cleared and redrawn in the shared CGContext bitmap
4. The bitmap region is uploaded to a double-buffered Metal texture as a partial region (not full-screen)
5. Metal shader chain applies post-processing every vsync
6. Final result presented to CAMetalLayer drawable

Idle cost ~0: panels that haven't changed aren't redrawn; their pixels persist from prior frames.

### Multi-display

- Separate `CyberdeckSaverView` per screen, each with its own renderer + display link
- Per-display refresh rates respected (60Hz external + 120Hz ProMotion independently)
- Network fetches coalesce across displays via `StreamCache` — one actual request per URL per refresh window
- `willstop` distributed notification + force-teardown of all live views + `exit(0)` to clean up `legacyScreenSaver`

### Colors (vulpes)

| Color | Hex | Usage |
|-------|-----|-------|
| hot pink | #e60067 | Headers, cursors, alerts — glows under bloom |
| teal | #6eedf7 | Primary data labels |
| light pink | #f2cfdf | Data values |
| muted magenta | #73264a | Separators, dates |
| muted | #735865 | Secondary text |

### macOS

Requires macOS 14.0+. Tested on 15.7.2 (Sequoia). Handles the Sonoma/Sequoia
`stopAnimation` bug via `com.apple.screensaver.willstop` distributed
notification.

## License

Personal project by EJ Fox.
