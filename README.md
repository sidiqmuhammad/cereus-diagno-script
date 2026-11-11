# cereus-diagno-script

> All-in-one diagnostic suite for Xiaomi Redmi 6 (`cereus` / `certus`) —
> battery efficiency profiling, performance analysis, and optimization
> stack verification in a single POSIX shell script.

---

## Overview

The Xiaomi Redmi 6 running unofficial Android 12L ROMs presents a unique
diagnostic challenge: MediaTek's PPM power policy layer sits above the
standard cpufreq sysfs interface, the `schedplus` governor exposes
non-AOSP tunables, and the PowerVR GPU has no public devfreq governor.
Off-the-shelf tools either miss these paths entirely or report incorrect
values.

This script addresses that gap. It collects a complete hardware and
software snapshot — CPU, GPU, memory, thermal, I/O, root stack, running
processes, wakelock sources, and touch event characteristics — then runs
a reproducible cold-start and scroll benchmark with simultaneous battery
current sampling. A summary section at the end auto-validates key
configuration values against their expected targets, flagging any drift
without requiring manual inspection of thousands of lines of output.

**Primary design goals:**
- Smooth, stable UI rendering — no frame drops, no jank, no ANR
- Maximum battery efficiency at all screen states: off, idle-on, and
  active use
- Both goals satisfied simultaneously, not traded against each other

---

## Compatibility

Developed and tested on:

| Component | Detail |
|-----------|--------|
| Device | Xiaomi Redmi 6 (`cereus` / `certus`) |
| ROM | CipherOS 3.0 GRAVITY (cipher_cactus port, Android 12L — SP2A.220305.012) |
| Kernel | 4.9.200-TsukiNoHikari-EOL+ |
| CPU | MediaTek MT6761 (Helio A22), 8× Cortex-A53, governor: `schedplus` |
| GPU | PowerVR Rogue GE8320, OpenGL ES 3.2 |
| RAM | 2.8 GB |
| Root | Magisk 30.7 |

The script runs gracefully on other rooted MediaTek Android devices.
Paths under `/proc/ppm/`, `/proc/perfmgr/`, and `/proc/gpufreq/` are
MT6761-specific; unresolvable paths are skipped silently.

---

## Requirements

- Root access (Magisk or KernelSU)
- `su` available from Termux or adb shell
- Screen **on and unlocked** during execution (required for touch capture and benchmark phases)
- Battery **≥ 40%** (benchmark samples battery current)
- Termux must **not be frozen** by Hail or similar freeze managers

---

## Usage

```bash
# Full run — all 19 sections — approx. 10–12 min
su -c "sh /sdcard/cereus_diagno_v1.0.sh full"

# Static dump only — no interaction — approx. 1–2 min
su -c "sh /sdcard/cereus_diagno_v1.0.sh quick"

# Static dump + touch characterization, no benchmark/monitor — approx. 5–6 min
su -c "sh /sdcard/cereus_diagno_v1.0.sh nobench"

# Live CPU frequency vs. screen state monitor only (default: 120 s)
su -c "sh /sdcard/cereus_diagno_v1.0.sh monitor 90"
```

The script writes no configuration changes to the system in any mode.
The benchmark phase force-stops then relaunches target apps for cold-start
measurement; no other system state is modified.

---

## Output

Primary report (all modes except `monitor`-only):
```
/sdcard/cereus_master_<YYYYMMDD_HHMMSS>.txt
```

Raw touch event captures (modes `full` and `nobench`):
```
/sdcard/cereus_touch_tap_<timestamp>.txt
/sdcard/cereus_touch_scroll_<timestamp>.txt
```

---

## Diagnostic Sections

| # | Section | What it collects |
|---|---------|-----------------|
| 1 | System Identity | Build fingerprint, kernel version, uptime, load average |
| 2 | Battery & Power | Sysfs attributes, `dumpsys battery/power`, kernel wakeup sources, `batterystats`, alarm manager, job scheduler, Doze state |
| 3 | CPU / Governor / PPM / Scheduler | Per-core frequency and governor state, `schedplus` tunables, SchedTune cgroup values, **full PPM hard and user limit policy**, EAS enable, `sched_*` kernel parameters |
| 4 | GPU / DRAM / MediaTek Boost Paths | `gpufreq` proc entries, GED, FPSGO, DVFSRC, **`perfmgr` touch boost (`tchbst`)**, CPU Freq Prediction (`cfp`), `boost_ctrl` |
| 5 | Memory & Reclaim | PSI, all `vm.*` kernel parameters, ZRAM algorithm and stats, LMK thresholds, Dalvik heap config, top memory consumers, `vmstat` snapshot |
| 6 | Storage | `df`, I/O scheduler and block queue parameters |
| 7 | Thermal | All thermal zones and cooling devices with current state |
| 8 | Running Processes | `top`, `dumpsys cpuinfo` (per-app), `mtkfusionrild` highlight, AM process and service list, kill/trim events |
| 9 | Root / Magisk / Optimization Stack | Module list and `module.prop`, `cereus_optimize` service and loop script, `sim2_toggle`, FDE.AI residue check, Zygisk Next config, Integrity Box, Tricky Store, fingerprint HAL process check |
| 10 | Packages & Freeze State | Hail-frozen package list, WebView provider status, critical system component states |
| 11 | Network & Dual SIM / RIL | Interface stats, Wi-Fi state, **SIM2 preferred network mode** (2G-only verification), per-UID data usage |
| 12 | Display & Rendering | Display config, SurfaceFlinger FPS/jank counters, HWUI gfxinfo |
| 13 | Logcat | Priority-E errors, power/wakelock/Doze events, LMK/OOM kills, crash/ANR log, Magisk/Zygisk/integrity events, **regression check** for known crash-loop services (fingerprint HAL, AdbDebuggingManager, KernelWakelockReader) |
| 14 | Kernel Debug | Loaded modules, `dmesg` power/suspend/thermal events, IRQ statistics |
| 15 | System Properties | MTK perf/power props, Dalvik/memory props, full `getprop` dump |
| 16 | Touch Event Characterization | Captures tap (60 events) and continuous scroll (800 events) from `/dev/input`, reports event rate, duration, touch-down count, and first 25 raw lines |
| 17 | Benchmark Baseline | 3× cold-start per app + 16 programmatic swipes + battery current sampling (Settings and Play Store) |
| 18 | Live CPU Freq Monitor | 3-second polling, screen on/off transition detection, PPM floor change detection — **PPM parsing corrected** to `<cluster> <freq_kHz>` format (not the `min_freq_idx` pattern used in older scripts) |
| 19 | Summary / Quick Status Check | **Auto-validates** measured values against expected targets — CPU floor/ceiling, `vm.swappiness`, `vm.vfs_cache_pressure`, I/O scheduler, ZRAM algorithm, `cpu_floor_loop.sh` PID, fingerprint HAL state — outputs `OK` / `MISMATCH` / `INFO` per item |

---

## Notes on Specific Design Decisions

**PPM over cpufreq sysfs.**
On MT6761 with `schedplus`, writing to `/sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq` has no persistent effect — PPM overrides it. Effective frequency limits must be applied via `/proc/ppm/policy/hard_userlimit_min_cpu_freq` and `userlimit_min_cpu_freq` using the format `<cluster> <freq_kHz>`.

**Screen-aware CPU floor.**
The script captures PPM state while the screen is on. Screen-off floor behavior is observable via Section 18 (`monitor` mode): trigger screen transitions during the monitoring window and watch for PPM floor changes in the log.

**Benchmark validity.**
Swipes in Section 17 are injected via `cmd input` (shell-side), not through `/dev/input`. Results are only meaningful for A/B comparisons using the same method — not as absolute performance figures.

---

## License

MIT — see [LICENSE](LICENSE).
