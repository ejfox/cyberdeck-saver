# Cyberdeck Screensaver

A native macOS screensaver (.saver bundle) built with Swift + Metal that displays real-time data from personal APIs and OSINT feeds in a cyberpunk command center aesthetic.

## What It Does

16 data panels type themselves out independently across a 4x4 grid, each pulling from a real data source. No fake data — every byte on screen comes from an actual API or system call.

### Data Sources

**VPS OSINT Feeds** (from tools.ejfox.com):
- **SKYWATCH** — Hudson Valley airspace surveillance (134K+ tracked flights, military aircraft detection)
- **ANOMALY** — Cross-source anomaly detection (10K+ signals, active investigations)
- **BRIEFING** — Daily intelligence briefings (investigations, local governance, pattern analysis)
- **OVERWATCH** — Facility monitoring and activity tracking

**Personal APIs** (from ejfox.com/api):
- **SIGINT** — GitHub activity (commits, repos, recent events via /api/stats)
- **ACINT** — Last.fm music feed (now playing, recent tracks, 147K+ scrobbles)
- **BIOMETRIC** — Apple Health data (steps, exercise, stand hours, HRV)
- **COMINT** — Mastodon posts from @ejfox@mastodon.social
- **PRODINT** — RescueTime productivity tracking (weekly categories, hours)
- **METRICS** — Aggregated weekly summary (productive hours, efficiency)
- **GAMEINT** — Chess.com ratings (rapid, blitz, bullet, win rate)
- **KEYINT** — MonkeyType stats (WPM, accuracy, tests completed)
- **CODEINT** — LeetCode progress (problems solved by difficulty)
- **OSINT-W** — Written output tracking (words this month)

**Local System Data:**
- **CMD** — Real-time clock, uptime, session status (refreshes every second)
- **SYSINFO** — Hostname, OS version, CPU cores, memory, thermal state

### Visual Effects (Metal Shaders)

All shaders ported from EJ's Ghostty terminal vulpes shader stack:

- **Bloom** — Red-selective neon glow using 24-point Fibonacci sphere sampling. Only blooms pink/red pixels (#e60067) for that cyberpunk neon bleed. *Apple Silicon only.*
- **TFT** — LCD subpixel simulation at 3px resolution, 26% strength. *Apple Silicon only.*
- **Vignette** — Subtle edge darkening (15% strength, 1.2 radius) like an old CRT bezel.
- **Scanline Flicker** — Gentle CRT warmth with slow drift + fast pulse.
- **Glitch** — Chromatic aberration + analog distortion (available but off by default).

### Performance Modes

The renderer auto-detects the GPU:

| GPU | Mode | FPS | Shader Chain |
|-----|------|-----|-------------|
| Apple Silicon | Full | 30 | Bloom → TFT → Vignette → Scanline |
| Intel/AMD | Lite | 20 | Vignette → Scanline only |

The bloom shader (24 texture samples per pixel at retina resolution) is skipped on Intel to prevent fan spin.

### Colors (Vulpes Palette)

| Color | Hex | Usage |
|-------|-----|-------|
| Hot Pink | #e60067 | Headers, cursors, alerts — glows under bloom |
| Teal | #6eedf7 | Primary data labels |
| Light Pink | #f2cfdf | Data values |
| Muted Magenta | #73264a | Separators, dates |
| Muted | #735865 | Secondary text |

## Building

Requires Xcode with Metal Toolchain:

```bash
# First time only — download Metal command-line compiler
xcodebuild -downloadComponent MetalToolchain

# Build universal binary (arm64 + x86_64)
make

# Build and install locally
make install

# Build zip for AirDrop to another Mac
make zip

# Rebuild everything
make reinstall
```

## Installing

### Local
```bash
make install
```
Then: System Settings → Screen Saver → scroll to "Other" → select **Cyberdeck**.

### Another Mac (AirDrop)
```bash
make zip
# AirDrop build/CyberdeckSaver.saver.zip
# On target: unzip → double-click .saver → Install
```

## Architecture

```
Sources/
├── CyberdeckSaverView.swift  — ScreenSaverView subclass, Metal layer setup
├── Renderer.swift             — Metal pipeline, shader chain, GPU detection
├── TextEngine.swift           — Text buffer, typewriter animation, Core Text → texture
└── Streams.swift              — All data stream implementations (API fetching + formatting)

Shaders/
└── Shaders.metal              — All Metal fragment shaders (bloom, tft, vignette, scanline, glitch)

Resources/
└── Info.plist                 — Bundle metadata (NSPrincipalClass, identifier)
```

### Rendering Pipeline

1. Each panel independently fetches data and types characters at its own speed
2. Text is drawn into a CGContext (Core Text) backed by a shared memory buffer
3. The buffer is uploaded to a Metal texture
4. Metal shader chain applies post-processing effects
5. Final result presented to CAMetalLayer drawable

Only redraws when content changes (new characters typed or data fetched). The Metal shaders run every frame for animation (scanline flicker), but the expensive CPU text rendering is skipped when idle.

### macOS Compatibility

- Requires macOS 14.0+
- Handles Sonoma/Sequoia `stopAnimation()` bug via `com.apple.screensaver.willstop` distributed notification
- Uses `Bundle(for: type(of: self))` for resource loading (not `Bundle.main`, which points to System Preferences)
- Ad-hoc signed with sealed resources

## License

Personal project by EJ Fox.
