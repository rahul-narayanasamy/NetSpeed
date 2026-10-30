# NetSpeed

A tiny, native macOS menu bar app that shows your live internet speed.

```
↓ 12M ↑ 840K
```

One Swift file, no dependencies, no Dock icon, ~12 MB of memory and effectively zero battery cost.

## Features

- **Live download / upload speed** in the menu bar, updated every second
- **Bytes or bits**: `12M` (MB/s) or ` 96Mb` (Mbps), switchable from the menu
- **Download only** mode for a narrower menu bar item
- **Pause / Resume**: while paused the app does no work at all
- **Launch at Login**: one click, using the native macOS login item API
- **Fixed-width display**, so the menu bar doesn't jump around as numbers change
- Hover the item to see which interface is being measured (e.g. `Measuring en0`)

## Requirements

- macOS 11 Big Sur or later (Launch at Login needs macOS 13+)
- Apple Silicon Mac
- Xcode Command Line Tools (`xcode-select --install`) to build

## Install

```bash
git clone https://github.com/rahul-narayanasamy/NetSpeed.git
cd NetSpeed
./build.sh
```

`build.sh` compiles the app, signs it, runs a self-test, installs it to `/Applications/NetSpeed.app`, and launches it. Run it again any time to rebuild and restart.

### Start automatically after reboot

Click the speed in the menu bar → **Launch at Login**. If macOS asks, approve it in
**System Settings → General → Login Items** (it shows up under *Allow in the Background*).

## How it works

- **Which traffic is counted:** only the *primary* interface, the one macOS currently uses for the internet (Wi-Fi, Ethernet, or a full-tunnel VPN). It follows network changes automatically via `SCDynamicStore` notifications. Counting a single interface means traffic forwarded through Internet Sharing, bridges, or VPN tunnels isn't counted twice.
- **Where the numbers come from:** exact 64-bit byte counters from `sysctl(IFMIB_IFDATA)`, the same source as `netstat -ib`. (The more common `getifaddrs` / `NET_RT_IFLIST2` give regular apps counters truncated to 32 bits, which wrap every 4 GB, about every 30 seconds at gigabit speed.)
- **Accurate timing:** each delta is divided by elapsed time on a monotonic clock that includes sleep, so waking from sleep or a clock change never shows a fake spike.
- **Units** are decimal (1 K = 1000), matching Activity Monitor and how ISPs quote speeds.

## Performance

| | |
|---|---|
| Memory | ~12 MB (the baseline for any AppKit app) |
| CPU while visible | ~0.3% of one core, one `sysctl` call per second (< 1 µs) |
| Screen off, locked, another user active, or paused | timer stopped, no wakeups |
| Energy impact (Activity Monitor) | ~0.3 |

The menu bar is only redrawn when the displayed text actually changes.

## Security & privacy

- **App Sandbox** and **Hardened Runtime** enabled, with **no extra entitlements**: no network access, no file access outside its own container.
- Makes **no network connections**. It reads only the interface byte counters the kernel exposes; it never sees packet contents, destinations, or which apps are talking.
- Stores only three on/off preferences (`paused`, `downloadOnly`, `bitsMode`) in its sandbox container.
- Ad-hoc signed by `build.sh` on your own machine, so there's no third-party binary to trust: you build exactly the source you read.

## Project layout

| File | Purpose |
|---|---|
| `main.swift` | The whole app |
| `Info.plist` | Bundle metadata (`LSUIElement` = menu bar only) |
| `NetSpeed.entitlements` | App Sandbox entitlement |
| `build.sh` | Build, sign, self-test, install, relaunch |

Run the self-test on its own (after a build):

```bash
build/NetSpeed.app/Contents/MacOS/NetSpeed --selftest
```

## Limitations

- Traffic on a secondary interface (e.g. a NAS on Ethernet while the internet is on Wi-Fi) isn't shown.
- While offline the item shows `↓ … ↑ …` (the tooltip says *Offline*).
- Not notarized: it's meant to be built from source with `build.sh`. A copy downloaded from elsewhere would be blocked by Gatekeeper.

## Uninstall

1. Turn off **Launch at Login** in the menu (if on), then choose **Quit NetSpeed**.
2. Remove the app and its preferences:

```bash
rm -rf /Applications/NetSpeed.app ~/Library/Containers/local.netspeed.app
```
