#!/system/bin/sh
# ==============================================================================
# cereus_master_diag.sh v1.0
# Script diagnostik + benchmark + verifikasi tunggal untuk Xiaomi Redmi 6 (cereus)
# Rhael Diagnostic Suite | 2026-11-11
#
# Ini adalah PENGGANTI TUNGGAL untuk 4 script lama:
#   - cereus_diag.sh          -> dump statis lengkap (battery/CPU/GPU/dll)
#   - cereus_design_probe.sh  -> PPM/schedtune/touch-boost/karakter sentuhan/benchmark
#   - cereus_bench_fix.sh     -> SUDAH DIHAPUS, fungsinya adalah subset dari
#                                bench_pkg() di design_probe dan sudah tercakup
#                                penuh di sini (tidak ada yang hilang)
#   - freq_monitor.sh         -> dijadikan Bagian F (live monitor), parsing PPM
#                                diperbaiki agar sesuai format aktual kernel ini
#                                ("<cluster> <freq_khz>", bukan "min_freq_idx = N")
# Section "FDE.AI State" dari cereus_diag.sh dihapus (FDE.AI sudah di-uninstall
# 2026-10-31) dan digantikan verifikasi stack optimasi custom yang aktif sekarang
# (cereus_optimize, sim2_toggle) di Bagian E.
#
# TUJUAN DIAGNOSTIK INI (baca sebelum menjalankan):
#   Memetakan kondisi cereus saat ini secara akurat untuk 2 target yang berjalan
#   BERSAMAAN: (1) aplikasi smooth/stabil/tanpa frame drop & lag, (2) battery
#   se-efisien mungkin di screen-off, screen-on, maupun saat aktif dipakai.
#   Script ini TIDAK mengubah setelan apa pun kecuali di Bagian F (live monitor)
#   yang hanya mengamati, dan Bagian D (benchmark) yang hanya force-stop lalu
#   membuka ulang app target untuk pengukuran cold-start.
#
# CARA PAKAI:
#   1. Layar menyala, tidak terkunci, USB boleh tetap untuk transfer file nanti
#   2. Pastikan Termux TIDAK di-freeze Hail, baterai minimal 40%
#   3. Salin ke /sdcard/cereus_master_diag.sh lalu jalankan salah satu mode:
#
#        su -c "sh /sdcard/cereus_master_diag.sh full"      (default, ~10-12 menit)
#        su -c "sh /sdcard/cereus_master_diag.sh quick"     (statis saja, ~1-2 menit)
#        su -c "sh /sdcard/cereus_master_diag.sh nobench"   (statis+sentuhan, tanpa benchmark/monitor)
#        su -c "sh /sdcard/cereus_master_diag.sh monitor 90" (HANYA live freq monitor, durasi opsional detik)
#
#   4. Ikuti instruksi di layar (ada fase sentuh layar di mode full/nobench,
#      dan fase toggle layar mati-nyala di mode full/monitor)
#   5. Kirim file /sdcard/cereus_master_<timestamp>.txt
#
# CATATAN: Semua data disimpan lokal, tidak ada yang dikirim otomatis.
# ==============================================================================

MODE="${1:-full}"
MON_DURATION="${2:-120}"
TS=$(date +%Y%m%d_%H%M%S)
OUT="/sdcard/cereus_master_${TS}.txt"
TMP="/data/local/tmp/cmd_$$"
BATT="/sys/class/power_supply/battery"
S1="==============================================================================="
S2="-------------------------------------------------------------------------------"
mkdir -p "$TMP"

# Target/baseline yang sudah diputuskan & diterapkan sebelumnya (lihat Section 19)
EXP_FLOOR_ON=979000        # kHz, cluster0, screen ON (Opsi C, idx14)
EXP_CEIL_ON=1750000        # kHz, cluster0, screen ON (Opsi C)
EXP_SWAPPINESS=65
EXP_VFS_CACHE_PRESSURE=80

w()   { printf "%s\n" "$@" >> "$OUT"; }
nl()  { printf "\n" >> "$OUT"; }
s()   { nl; w "$S1"; w "### $1 ###"; w "$S1"; }
ss()  { nl; w "$S2"; w "-- $1 --"; w "$S2"; nl; }
run() { w "\$ $*"; eval "$@" >> "$OUT" 2>&1; nl; }
say() { echo "  [*] $1"; }
chk() { w "  [CHECK] $1 : $2"; }

if ! id 2>/dev/null | grep -q "uid=0"; then
    echo "  [!] Butuh root. Jalankan: su -c 'sh /sdcard/cereus_master_diag.sh'"
    exit 1
fi

case "$MODE" in
    quick)   DO_STATIC=1; DO_TOUCH=0; DO_BENCH=0; DO_MONITOR=0 ;;
    nobench) DO_STATIC=1; DO_TOUCH=1; DO_BENCH=0; DO_MONITOR=0 ;;
    monitor) DO_STATIC=0; DO_TOUCH=0; DO_BENCH=0; DO_MONITOR=1 ;;
    full|*)  DO_STATIC=1; DO_TOUCH=1; DO_BENCH=1; DO_MONITOR=1 ;;
esac

echo ""
echo "  +-----------------------------------------------------------+"
echo "  |   CEREUS MASTER DIAGNOSTIC v1.0  |  mode: ${MODE}"
echo "  +-----------------------------------------------------------+"
echo "  Output: $OUT"
echo ""

w "$S1"
w "  CEREUS MASTER DIAGNOSTIC REPORT v1.0"
w "  Xiaomi Redmi 6 (cereus) | mode: $MODE"
w "  Generated: $(date)"
w "$S1"

vmsnap() {
    grep -E "^(pgscan_kswapd|pgscan_direct|pgsteal_kswapd|pgsteal_direct|pswpin|pswpout|allocstall|pgmajfault)" /proc/vmstat
}
avg_file() {
    s=0; n=0
    while read v; do
        v=${v:-0}
        s=$((s + v)); n=$((n + 1))
    done < "$1"
    if [ "$n" -gt 0 ]; then echo $((s / n)); else echo NA; fi
}
sampler_start() {
    : > "$TMP/cur.log"
    ( while true; do cat $BATT/current_now >> "$TMP/cur.log" 2>/dev/null; sleep 1; done ) &
    SAMP=$!
}
sampler_stop() { kill $SAMP 2>/dev/null; wait $SAMP 2>/dev/null; }
swipe() { cmd input swipe "$@" >/dev/null 2>&1 || input swipe "$@" >/dev/null 2>&1; }

if [ "$DO_STATIC" = "1" ]; then

# =====================================================================
say "1/15: System Identity..."
s "1. SYSTEM IDENTITY"
# =====================================================================
ss "Build & OS Info"
run "uname -a"
for prop in ro.product.model ro.product.device ro.product.name \
            ro.build.version.release ro.build.version.sdk \
            ro.build.id ro.build.description ro.build.fingerprint \
            ro.product.cpu.abi; do
    w "$prop: $(getprop $prop 2>/dev/null || echo N/A)"
done >> "$OUT" 2>&1
nl
ss "Uptime & Load"
run "cat /proc/uptime"
run "uptime"
run "cat /proc/loadavg"

# =====================================================================
say "2/15: Battery & Power..."
s "2. BATTERY & POWER"
# =====================================================================
ss "Battery Sysfs Attributes"
run "ls $BATT"
nl
for attr in status capacity voltage_now current_now current_avg \
            charge_full charge_full_design charge_counter \
            health temp technology cycle_count input_current_max; do
    v=$(cat "$BATT/$attr" 2>/dev/null || echo "N/A")
    w "$attr: $v"
done >> "$OUT" 2>&1
nl
ss "Dumpsys Battery"
run "dumpsys battery"
ss "Power Manager Full State (Wakelocks + Status)"
run "dumpsys power"
ss "Kernel Wakeup Sources"
mount -t debugfs none /sys/kernel/debug 2>/dev/null
if [ -r "/sys/kernel/debug/wakeup_sources" ]; then
    run "cat /sys/kernel/debug/wakeup_sources"
elif [ -r "/d/wakeup_sources" ]; then
    run "cat /d/wakeup_sources"
elif [ -r "/proc/wakelocks" ]; then
    run "cat /proc/wakelocks"
else
    w "[wakeup_sources tidak dapat diakses via debugfs]"
    run "mount | grep -E '(debug|tracefs)'"
fi
ss "Battery Stats Ringkasan (Sejak Charge Terakhir)"
run "dumpsys batterystats --charged 2>/dev/null | grep -E '(Time on battery|Screen on|Wifi running|Mobile radio|CPU:|wake_lock|wakeup reason|#0:|#1:)' | head -150"
ss "Alarm Manager"
run "dumpsys alarm 2>/dev/null | head -250"
ss "Job Scheduler"
run "dumpsys jobscheduler 2>/dev/null | grep -E '(JOB|Running|Pending|package|tag|trigger)' | head -100"
ss "Device Idle (Doze) State"
run "dumpsys deviceidle 2>/dev/null | head -80"
run "getprop ro.vendor.mtk_doze_support 2>/dev/null"

# =====================================================================
say "3/15: CPU, Governor, PPM, SchedTune..."
s "3. CPU, GOVERNOR, PPM & SCHEDULER"
# =====================================================================
ss "CPU Info Dasar"
run "cat /proc/cpuinfo | grep -E 'processor|model name|Hardware' "
ss "Per-CPU Frequency & Governor"
for cpu_dir in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -d "$cpu_dir" ] || continue
    cpu_id=$(echo "$cpu_dir" | grep -oE 'cpu[0-9]+')
    w ""
    w "[$cpu_id]"
    for p in scaling_governor scaling_cur_freq cpuinfo_cur_freq \
              scaling_min_freq scaling_max_freq cpuinfo_min_freq cpuinfo_max_freq; do
        v=$(cat "$cpu_dir/$p" 2>/dev/null || echo "N/A")
        w "  $p: $v"
    done
done >> "$OUT" 2>&1
ss "Available Governors & Frequencies"
run "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
run "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies"
run "cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies"
ss "CPU Online/Offline"
for f in /sys/devices/system/cpu/cpu*/online; do
    [ -f "$f" ] && w "$f: $(cat $f 2>/dev/null)"
done >> "$OUT" 2>&1

ss "SchedTune (nilai aktual per cgroup)"
for g in "" top-app foreground background; do
    w "[stune/${g:-root}]"
    for f in boost prefer_idle uclamp_min capacity_min; do
        w "  $f: $(cat /dev/stune/$g/schedtune.$f 2>/dev/null || echo -)"
    done
done >> "$OUT" 2>&1

ss "PPM (kebijakan daya MediaTek) - Policy Status"
run "cat /proc/ppm/policy_status"
run "cat /proc/ppm/dump_policy_list"
for p in lcmoff_min_freq sysboost_freq sysboost_cluster_freq_limit \
         hard_userlimit_min_cpu_freq hard_userlimit_max_cpu_freq \
         userlimit_min_cpu_freq userlimit_max_cpu_freq \
         userlimit_freq_limit_by_others hard_userlimit_freq_limit_by_others \
         thermal_limit; do
    w "[$p]"
    w "$(cat /proc/ppm/policy/$p 2>/dev/null)"
done >> "$OUT" 2>&1

# -- Capture nilai mentah untuk perbandingan di Bagian 19 (ringkasan) --
PPM_MIN_RAW=$(cat /proc/ppm/policy/hard_userlimit_min_cpu_freq 2>/dev/null | head -1)
PPM_MAX_RAW=$(cat /proc/ppm/policy/hard_userlimit_max_cpu_freq 2>/dev/null | head -1)
PPM_MIN_C0=$(echo "$PPM_MIN_RAW" | awk '{print $2}')
PPM_MAX_C0=$(echo "$PPM_MAX_RAW" | awk '{print $2}')
CPU0_MIN_AVAIL=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null | tr ' ' '\n' | sort -n | head -1)
nl
w "[Snapshot untuk ringkasan] hard_userlimit_min_cpu_freq cluster0 = ${PPM_MIN_C0:-N/A} kHz"
w "[Snapshot untuk ringkasan] hard_userlimit_max_cpu_freq cluster0 = ${PPM_MAX_C0:-N/A} kHz"
w "[Snapshot untuk ringkasan] frekuensi minimum tersedia cluster0  = ${CPU0_MIN_AVAIL:-N/A} kHz"
w "(Catatan: snapshot ini diambil saat layar MENYALA, jadi hanya relevan untuk"
w " verifikasi floor screen-ON. Floor screen-OFF cek di Bagian F / live monitor,"
w " atau dari policy 'lcmoff_min_freq' di atas kalau device pakai jalur native MTK.)"

ss "Governor schedplus (tunables)"
for d in /sys/devices/system/cpu/cpufreq/* \
         /sys/devices/system/cpu/cpu0/cpufreq/schedplus \
         /sys/devices/system/cpu/cpu4/cpufreq/schedplus; do
    [ -d "$d" ] || continue
    w "[$d]"
    for f in "${d%/}"/*; do
        [ -f "$f" ] && w "  $(basename $f): $(cat $f 2>/dev/null)"
    done
done >> "$OUT" 2>&1
run "cat /sys/devices/system/cpu/eas/enable 2>/dev/null"

ss "CPUSET & App Foreground"
for c in /dev/cpuset/cpus /dev/cpuset/*/cpus; do
    [ -f "$c" ] && w "$c: $(cat $c 2>/dev/null)"
done >> "$OUT" 2>&1
nl
w "[PID di stune/top-app]"
for p in $(head -8 /dev/stune/top-app/cgroup.procs 2>/dev/null); do
    w "  $p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)"
done >> "$OUT" 2>&1

ss "Kernel Scheduler Parameters (sched_*)"
for f in /proc/sys/kernel/sched_*; do
    [ -f "$f" ] && w "$(basename $f): $(cat $f 2>/dev/null)"
done >> "$OUT" 2>&1
ss "CPU Stat"
run "cat /proc/stat | head -10"

# =====================================================================
say "4/15: GPU, DRAM, Touch-Boost, FPSGO..."
s "4. GPU, DRAM & JALUR BOOST MEDIATEK"
# =====================================================================
ss "GPU Properties"
for prop in ro.hardware.egl ro.opengles.version debug.egl.hw debug.sf.hw; do
    w "$prop: $(getprop $prop 2>/dev/null || echo N/A)"
done >> "$OUT" 2>&1
ss "GPU Freq (gpufreq)"
run "ls -la /proc/gpufreq/ 2>/dev/null"
if [ -d /proc/gpufreq ]; then
    for f in /proc/gpufreq/*; do
        [ -f "$f" ] || continue
        w "[$f]"
        w "$(head -c 1500 "$f" 2>/dev/null)"
    done >> "$OUT" 2>&1
fi
ss "GED / FPSGO / DevFreq / DVFSRC"
run "ls /sys/kernel/gpu /sys/kernel/ged /sys/module/ged/parameters 2>&1 | head -40"
run "ls /sys/kernel/fpsgo 2>&1 | head -20"
run "ls /sys/devices/platform/10012000.dvfsrc/ 2>/dev/null"
for devfreq_dir in /sys/class/devfreq/*/; do
    [ -d "$devfreq_dir" ] || continue
    w ""
    w "[$(basename $devfreq_dir)]"
    for p in governor cur_freq min_freq max_freq available_frequencies load; do
        v=$(cat "${devfreq_dir}$p" 2>/dev/null || echo "N/A")
        w "  $p: $v"
    done
done >> "$OUT" 2>&1
ss "Perfmgr (touch boost tchbst, CPU Freq Prediction, boost_ctrl)"
run "find /proc/perfmgr -maxdepth 3 2>/dev/null | head -80"
if [ -d /proc/perfmgr ]; then
    for f in $(find /proc/perfmgr/tchbst /proc/perfmgr/boost_ctrl /proc/perfmgr/cfp -maxdepth 3 -type f 2>/dev/null | head -60); do
        w "[$f]"
        w "$(head -c 400 "$f" 2>/dev/null)"
    done >> "$OUT" 2>&1
fi
run "ls /proc/mtk_perf* /proc/mtkpower* 2>/dev/null"

# =====================================================================
say "5/15: Memory & Reclaim..."
s "5. MEMORY & RECLAIM"
# =====================================================================
ss "Memory Overview"
run "free -h"
run "grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Cached)' /proc/meminfo"
ss "PSI (Pressure Stall Information)"
run "ls /proc/pressure 2>/dev/null"
for f in cpu memory io; do
    w "[psi $f] $(cat /proc/pressure/$f 2>/dev/null || echo tidak-ada)"
done >> "$OUT" 2>&1
ss "VM Kernel Parameters (lengkap)"
for f in /proc/sys/vm/*; do
    [ -f "$f" ] && w "$(basename $f): $(cat $f 2>/dev/null)"
done >> "$OUT" 2>&1
VM_SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null)
VM_VFS_PRESSURE=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
ss "ZRAM / Swap"
run "cat /proc/swaps"
for zram in /sys/block/zram*; do
    [ -d "$zram" ] || continue
    w ""
    w "[$zram]"
    for attr in disksize mem_used_total compr_data_size orig_data_size comp_algorithm \
                zero_pages num_reads num_writes failed_reads failed_writes; do
        v=$(cat "$zram/$attr" 2>/dev/null || echo "N/A")
        w "  $attr: $v"
    done
done >> "$OUT" 2>&1
ZRAM_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -oE '\[[a-z0-9_-]*\]' | tr -d '[]')
ss "Low Memory Killer"
run "cat /sys/module/lowmemorykiller/parameters/minfree 2>/dev/null || echo 'LMK minfree tidak ada (mungkin LMKD userspace)'"
run "getprop ro.config.low_ram"
run "cat /proc/sys/vm/min_free_kbytes"
ss "Dalvik/ART Heap Config"
for prop in heapsize heapgrowthlimit heapstartsize heaptargetutilization heapminfree heapmaxfree; do
    w "dalvik.vm.$prop: $(getprop dalvik.vm.$prop 2>/dev/null || echo N/A)"
done >> "$OUT" 2>&1
ss "Top Memory Consumers"
run "dumpsys meminfo 2>/dev/null | head -120"
ss "VM Stat Snapshot (baseline, sebelum benchmark)"
w "[vmstat sebelum]"
vmsnap >> "$OUT"

# =====================================================================
say "6/15: Storage..."
s "6. STORAGE"
# =====================================================================
run "df -h"
ss "I/O Scheduler & Queue Parameters"
IO_SCHED_C=""
for blk_dir in /sys/block/mmcblk*/queue; do
    [ -d "$blk_dir" ] || continue
    blk=$(echo "$blk_dir" | grep -oE 'mmcblk[0-9]+')
    w ""
    w "[$blk Queue]"
    for p in scheduler read_ahead_kb nr_requests rotational add_random discard_granularity; do
        v=$(cat "$blk_dir/$p" 2>/dev/null || echo "N/A")
        w "  $p: $v"
        [ "$p" = "scheduler" ] && [ -z "$IO_SCHED_C" ] && IO_SCHED_C="$v"
    done
done >> "$OUT" 2>&1

# =====================================================================
say "7/15: Thermal..."
s "7. THERMAL"
# =====================================================================
ss "Thermal Zones"
for zone_dir in /sys/class/thermal/thermal_zone*/; do
    [ -d "$zone_dir" ] || continue
    type=$(cat "${zone_dir}type" 2>/dev/null || echo "?")
    temp=$(cat "${zone_dir}temp" 2>/dev/null || echo "N/A")
    mode=$(cat "${zone_dir}mode" 2>/dev/null || echo "N/A")
    trip0=$(cat "${zone_dir}trip_point_0_temp" 2>/dev/null || echo "N/A")
    w "$(basename $zone_dir) [${type}]: temp=${temp}, trip0=${trip0}, mode=${mode}"
done >> "$OUT" 2>&1
ss "Cooling Devices"
for cool_dir in /sys/class/thermal/cooling_device*/; do
    [ -d "$cool_dir" ] || continue
    type=$(cat "${cool_dir}type" 2>/dev/null || echo "?")
    cur=$(cat "${cool_dir}cur_state" 2>/dev/null || echo "N/A")
    max=$(cat "${cool_dir}max_state" 2>/dev/null || echo "N/A")
    w "$(basename $cool_dir) [${type}]: cur_state=${cur}, max_state=${max}"
done >> "$OUT" 2>&1

# =====================================================================
say "8/15: Running Processes..."
s "8. RUNNING PROCESSES"
# =====================================================================
ss "Process Snapshot (CPU)"
run "top -bn1 2>/dev/null | head -50"
ss "Dumpsys CPUInfo (per-app)"
run "dumpsys cpuinfo 2>/dev/null | head -80"
ss "Highlight: mtkfusionrild (RIL daemon, pernah 23% CPU)"
run "dumpsys cpuinfo 2>/dev/null | grep -i mtkfusionrild"
run "top -bn1 2>/dev/null | grep -i mtkfusionrild"
ss "Activity Manager - Processes"
run "dumpsys activity processes 2>/dev/null | head -150"
ss "Activity Manager - Services"
run "dumpsys activity services 2>/dev/null | head -150"
ss "App Kill / Trim Events"
run "dumpsys activity 2>/dev/null | grep -iE '(Killing|kill|OOM|lowmem|trim|ANR|am_kill)' | head -50"

# =====================================================================
say "9/15: Root, Magisk Modules & Optimization Stack..."
s "9. ROOT, MAGISK MODULES & OPTIMIZATION STACK"
# =====================================================================
ss "Magisk Version"
run "magisk -v 2>/dev/null || echo 'magisk binary tidak ada di PATH'"
ss "Module List"
run "ls -la /data/adb/modules/"
ss "Module Details (semua module)"
for mod_dir in /data/adb/modules/*/; do
    [ -d "$mod_dir" ] || continue
    mod_name=$(basename "$mod_dir")
    w ""
    w "+-- Module: $mod_name"
    [ -f "${mod_dir}disable" ] && w "|   [STATUS: DISABLED]"
    [ -f "${mod_dir}remove" ]  && w "|   [STATUS: MARKED_REMOVE]"
    if [ -f "${mod_dir}module.prop" ]; then
        w "|   module.prop:"
        while IFS= read -r line; do w "|     $line"; done < "${mod_dir}module.prop" 2>/dev/null
    fi
done >> "$OUT" 2>&1

ss "cereus_optimize (floor-lock CPU custom) - isi service.sh"
run "cat /data/adb/modules/cereus_optimize/service.sh 2>/dev/null || echo 'module cereus_optimize tidak ditemukan'"
run "cat /data/adb/modules/cereus_optimize/cpu_floor_loop.sh 2>/dev/null"
ss "cereus_optimize - apakah loop polling benar-benar berjalan?"
run "ps -ef 2>/dev/null | grep -i cpu_floor_loop | grep -v grep"
CPU_LOOP_RUNNING=$(ps -ef 2>/dev/null | grep -i cpu_floor_loop | grep -v grep | wc -l)

ss "sim2_toggle (SIM2 2G-only) - isi script"
run "cat /data/adb/modules/sim2_toggle/service.sh 2>/dev/null"
run "cat /data/adb/modules/sim2_toggle/action.sh 2>/dev/null"

ss "Verifikasi FDE.AI (seharusnya SUDAH TIDAK ADA, di-uninstall 2026-10-31)"
run "pm list packages 2>/dev/null | grep -iE '(fde|feravolt)'"
run "find /sdcard -iname '*fde*' -maxdepth 4 2>/dev/null | head -10"
FDE_LEFTOVER=$(pm list packages 2>/dev/null | grep -icE '(fde|feravolt)')

ss "Zygisk Next Config"
run "cat /data/adb/modules/zygisksu/zygisk-config.json 2>/dev/null || echo 'config tidak ditemukan'"
ss "Integrity Box (Box-Brain)"
run "ls -la /data/adb/Box-Brain/ 2>/dev/null || echo 'Box-Brain dir tidak ada'"
run "cat /data/adb/Box-Brain/spoof-selinux-boot 2>/dev/null && echo '[FILE EXISTS]' || echo '[spoof-selinux-boot TIDAK ADA]'"
ss "Play Integrity Fix Module"
run "ls -la /data/adb/modules/playintegrityfix/ 2>/dev/null"
run "cat /data/adb/modules/playintegrityfix/module.prop 2>/dev/null"
ss "Tricky Store"
run "cat /data/adb/modules/tricky_store/module.prop 2>/dev/null"
ss "Magisk DenyList"
run "magisk --denylist ls 2>/dev/null || echo 'denylist tidak bisa diakses'"

ss "Fingerprint HAL (seharusnya sudah di-stop, tidak crash-loop lagi)"
run "ps -ef 2>/dev/null | grep -i fingerprint | grep -v grep"
FP_RUNNING=$(ps -ef 2>/dev/null | grep -i fingerprint | grep -v grep | wc -l)

# =====================================================================
say "10/15: Packages & Hail Freeze..."
s "10. PACKAGES & HAIL FREEZE"
# =====================================================================
w "Total packages   : $(pm list packages 2>/dev/null | wc -l)"
w "Enabled packages : $(pm list packages -e 2>/dev/null | wc -l)"
w "Disabled packages: $(pm list packages -d 2>/dev/null | wc -l)"
ss "Semua Package Disabled (Hail Frozen)"
run "pm list packages -d 2>/dev/null | sort"
ss "WebView Status [kritis untuk performa]"
run "cmd webviewupdate get-current-webview-package 2>/dev/null || dumpsys webviewupdate 2>/dev/null | head -20"
for pkg in com.google.android.webview com.android.webview; do
    w ""
    w "[$pkg]"
    w "$(pm dump "$pkg" 2>/dev/null | grep -E 'enabled=|stopped=|hidden=|installed=' | head -6)"
done >> "$OUT" 2>&1
ss "Critical System Components Status"
w "Format: [package] -> enabled | stopped | hidden"
for pkg in com.google.android.gms com.android.vending com.google.android.webview \
    com.android.webview com.android.providers.downloads com.android.documentsui \
    com.android.packageinstaller com.android.inputmethod.latin com.android.systemui; do
    state=$(pm dump "$pkg" 2>/dev/null | grep -E 'enabled=|stopped=|hidden=' | head -3 | tr '\n' ' | ')
    w "$(printf '%-50s' "$pkg") -> $state"
done >> "$OUT" 2>&1

# =====================================================================
say "11/15: Network & Dual SIM..."
s "11. NETWORK & DUAL SIM / RIL"
# =====================================================================
run "ip link show"
ss "WiFi State"
run "dumpsys wifi 2>/dev/null | grep -E '(mWifiState|ConnectedState|mNetworkInfo|SSID|mIsScanningEnabled)' | head -30"
ss "Dual SIM / Preferred Network Mode (verifikasi SIM2 masih 2G-only)"
run "getprop | grep -iE 'sim|gsm.network.type|telephony.preferred'"
run "dumpsys telephony.registry 2>/dev/null | grep -iE 'mDataConnectionState|mServiceState|NetworkType' | head -30"
ss "Network Data Usage per UID (teratas)"
run "cat /proc/net/xt_qtaguid/stats 2>/dev/null | awk 'NR>1 && \$4>0 {print \$4, \$6, \$8}' | sort -k2 -rn | head -25 || echo 'xt_qtaguid tidak tersedia'"

# =====================================================================
say "12/15: Display & Rendering..."
s "12. DISPLAY & RENDERING"
# =====================================================================
run "dumpsys display 2>/dev/null | head -80"
ss "SurfaceFlinger (FPS/Jank)"
run "dumpsys SurfaceFlinger 2>/dev/null | grep -iE '(fps|refresh|jank|frame|present|latency|hwc|swap)' | head -50"
ss "HWUI / GFX Info"
run "dumpsys gfxinfo 2>/dev/null | head -80"

# =====================================================================
say "13/15: Logcat..."
s "13. LOGCAT"
# =====================================================================
ss "Recent Errors (Priority E)"
run "logcat -d -b main,system 2>/dev/null | grep -E ' E ' | tail -100"
ss "Power / Wakelock / Doze"
run "logcat -d -b main,system 2>/dev/null | grep -iE '(wakelock|doze|DeviceIdle|BatteryService|BatteryStats|PowerManagerService|suspend|resume)' | tail -80"
ss "LMK / OOM Kill"
run "logcat -d -b events,main 2>/dev/null | grep -iE '(am_kill|lowmem|oom_adj|killed)' | tail -50"
ss "Crash & ANR"
run "logcat -d -b crash 2>/dev/null | tail -80"
ss "Magisk / Zygisk / Integrity"
run "logcat -d -b main,system 2>/dev/null | grep -iE '(magisk|zygisk|zygote|tricky|playintegrity|integrity box)' | tail -50"
ss "Regresi check: fingerprint HAL / AdbDebuggingManager / KernelWakelockReader (harusnya BERSIH sekarang)"
run "logcat -d -b main,system 2>/dev/null | grep -iE '(fingerprint|AdbDebuggingManager|KernelWakelockReader)' | tail -40"
LOGCAT_REGRESSION=$(logcat -d -b main,system 2>/dev/null | grep -icE '(fingerprint|AdbDebuggingManager|KernelWakelockReader)')

# =====================================================================
say "14/15: Kernel Debug..."
s "14. KERNEL DEBUG"
# =====================================================================
run "cat /proc/modules 2>/dev/null | head -60"
ss "dmesg (Power/Suspend/Battery/Thermal)"
run "dmesg 2>/dev/null | grep -iE '(suspend|resume|wakeup|wakelock|battery|thermal|pm_noirq|cpu_pm|freeze)' | tail -120"
ss "IRQ Statistics"
run "cat /proc/interrupts 2>/dev/null | head -80"

# =====================================================================
say "15/15: System Properties..."
s "15. SYSTEM PROPERTIES"
# =====================================================================
ss "MTK Performance & Power Props"
run "getprop 2>/dev/null | grep -iE '(mtk|perf|power|thermal|boost|governor|cpu|gpu|pvr|gralloc|hwui|sf\.|mali|render|schedtune)'"
ss "Memory & Dalvik Props"
for prop in ro.config.low_ram ro.product.ram dalvik.vm.heapsize dalvik.vm.heapgrowthlimit \
            dalvik.vm.heapstartsize dalvik.vm.dex2oat-filter persist.sys.purgeable_assets \
            ro.vendor.mtk_perf_simple_start_win ro.mtk_perfservice_support; do
    w "$prop: $(getprop $prop 2>/dev/null || echo N/A)"
done >> "$OUT" 2>&1
ss "All System Properties (Full Dump)"
run "getprop"

fi  # end DO_STATIC

# =====================================================================
if [ "$DO_TOUCH" = "1" ]; then
say "Fase Sentuhan: Karakter Event Sentuh..."
s "16. KARAKTER EVENT SENTUH"
# =====================================================================
TSDEV=$(getevent -pl 2>/dev/null | grep -E "^add device|ABS_MT_POSITION_X" | grep -B1 ABS_MT_POSITION_X | head -1 | sed 's/.*: //')
w "Perangkat sentuh: ${TSDEV:-TIDAK-DITEMUKAN}"
[ -n "$TSDEV" ] && run "getevent -pl $TSDEV 2>&1 | head -40"

capture() {
    F="$TMP/$1.txt"
    echo ""
    echo "  >>> $3"
    echo "  >>> Siap dalam 3 detik..."
    sleep 3
    echo "  >>> MULAI SEKARANG"
    getevent -t -c "$2" "$TSDEV" > "$F" 2>/dev/null &
    GP=$!
    ( sleep 25; kill $GP 2>/dev/null ) &
    WD=$!
    wait $GP 2>/dev/null
    kill $WD 2>/dev/null
    echo "  >>> Selesai."
    total=$(wc -l < "$F" | tr -d ' ')
    if [ -z "$total" ] || [ "$total" -lt 2 ]; then
        w "[$1] GAGAL: event tertangkap kurang (total=${total:-0})."
        return
    fi
    t1=$(head -1 "$F" | sed 's/^\[ *\([0-9]*\)\.\([0-9]*\)\].*/\1\2/')
    t2=$(tail -1 "$F" | sed 's/^\[ *\([0-9]*\)\.\([0-9]*\)\].*/\1\2/')
    dur_ms=$(( (t2 - t1) / 1000 ))
    downs=$(grep -c "0001 014a 00000001" "$F")
    rate=0
    [ "$dur_ms" -gt 0 ] && rate=$(( total * 1000 / dur_ms ))
    w "[$1] baris=$total durasi=${dur_ms}ms laju=${rate} baris/dtk touch_down=$downs"
    w "  25 baris pertama:"
    head -25 "$F" | sed 's/^/    /' >> "$OUT"
    nl
    cp "$F" "/sdcard/cereus_touch_${1}_${TS}.txt"
}

if [ -n "$TSDEV" ]; then
    capture "tap" 60 "FASE 1: ketuk layar berkali-kali (sekitar 7 ketukan terpisah)"
    capture "scroll" 800 "FASE 2: gesek layar naik-turun terus-menerus tanpa berhenti"
fi
fi  # end DO_TOUCH

# =====================================================================
if [ "$DO_BENCH" = "1" ]; then
say "Fase Benchmark: Baseline cold-start + scroll + arus baterai..."
s "17. BENCHMARK BASELINE (jangan sentuh layar sampai selesai)"
# =====================================================================
w "Catatan: swipe disuntik via shell (tidak lewat /dev/input)."
w "Hasil hanya valid untuk perbandingan A/B dengan metode yang sama."
nl
w "[Kondisi PPM saat benchmark]"
w "min : $(cat /proc/ppm/policy/hard_userlimit_min_cpu_freq 2>/dev/null | tr '\n' ' ')"
w "max : $(cat /proc/ppm/policy/hard_userlimit_max_cpu_freq 2>/dev/null | tr '\n' ' ')"
nl

input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
input keyevent KEYCODE_HOME >/dev/null 2>&1
sleep 4
say "C1: arus layar nyala diam (20 detik)..."
sampler_start
sleep 20
sampler_stop
w "[IDLE layar nyala di home] arus rata-rata (uA): $(avg_file $TMP/cur.log) (negatif = discharge)"
nl

bench_pkg() {
    pkg="$1"; label="$2"
    if ! pm list packages 2>/dev/null | grep -q "package:$pkg\$"; then
        w "--- $label ($pkg) tidak terpasang, dilewati ---"; return
    fi
    comp=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$pkg" 2>/dev/null | tail -1)
    case "$comp" in
        */*) ;;
        *) w "--- $label: komponen launcher tidak ditemukan ---"; return ;;
    esac
    w "--- $label ($pkg) ---"
    say "$label cold-start x3..."
    i=1
    while [ $i -le 3 ]; do
        am force-stop "$pkg" >/dev/null 2>&1
        sleep 3
        r=$(am start -W -n "$comp" 2>/dev/null | grep -E "TotalTime|WaitTime" | tr '\n' ' ')
        w "  cold-start #$i: $r"
        sleep 5
        i=$((i + 1))
    done
    say "$label scroll 16 swipe..."
    dumpsys gfxinfo "$pkg" reset >/dev/null 2>&1
    sampler_start
    n=0
    while [ $n -lt 8 ]; do
        swipe 360 1100 360 400 300
        swipe 360 400 360 1100 300
        n=$((n + 1))
    done
    sleep 1
    sampler_stop
    w "  arus rata-rata saat scroll (uA): $(avg_file $TMP/cur.log)"
    dumpsys gfxinfo "$pkg" 2>/dev/null | grep -E "Total frames rendered|Janky frames:|50th|90th|95th|99th|Missed Vsync" | head -8 | sed 's/^/    /' >> "$OUT"
    nl
    input keyevent KEYCODE_HOME >/dev/null 2>&1
    sleep 2
}

bench_pkg com.android.settings "Settings"
bench_pkg com.android.vending "Play Store"

w "[vmstat sesudah benchmark]"
vmsnap >> "$OUT"
w "[load average akhir] $(cat /proc/loadavg)"
am start -n com.termux/com.termux.app.TermuxActivity >/dev/null 2>&1
fi  # end DO_BENCH

# =====================================================================
if [ "$DO_MONITOR" = "1" ]; then
say "Fase Monitor: CPU freq vs screen state (${MON_DURATION}s)..."
s "18. LIVE MONITOR: CPU FREQ vs SCREEN STATE"
# =====================================================================
w "Tujuan: verifikasi floor CPU benar-benar turun saat layar OFF dan naik ke"
w "        ${EXP_FLOOR_ON} kHz saat layar ON (sesuai keputusan Opsi C)."
w "Durasi : ${MON_DURATION} detik, poll tiap 3 detik."
w "ACTION : matikan & nyalakan layar beberapa kali selama fase ini berjalan."
nl
echo ""
echo "  >>> MONITOR DIMULAI (${MON_DURATION}s). Matikan-nyalakan layar sekarang."
echo ""

BRIGHT="/sys/class/leds/lcd-backlight/brightness"
CPU0_CUR="/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
CPU0_MIN="/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq"
CPU4_CUR="/sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq"
PPM_HARD="/proc/ppm/policy/hard_userlimit_min_cpu_freq"

START=$(date +%s)
PREV_SCREEN=""
PREV_PPM=""
while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    [ $ELAPSED -ge $MON_DURATION ] && break
    TS2=$(date +%H:%M:%S)
    BRT=$(cat "$BRIGHT" 2>/dev/null || echo "1")
    [ "$BRT" = "0" ] && SCREEN="OFF" || SCREEN="ON "
    C0_CUR=$(cat "$CPU0_CUR" 2>/dev/null || echo "0")
    C0_MIN=$(cat "$CPU0_MIN" 2>/dev/null || echo "0")
    C4_CUR=$(cat "$CPU4_CUR" 2>/dev/null || echo "0")
    # Format PPM device ini: "<cluster> <freq_khz>" per baris (bukan min_freq_idx)
    PPM_NOW=$(cat "$PPM_HARD" 2>/dev/null | head -1 | awk '{print $2}')
    [ -z "$PPM_NOW" ] && PPM_NOW="?"
    LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")
    C0_CUR_M=$((C0_CUR / 1000)); C0_MIN_M=$((C0_MIN / 1000)); C4_CUR_M=$((C4_CUR / 1000))
    PPM_M="?"
    case "$PPM_NOW" in ''|*[!0-9]*) ;; *) PPM_M=$((PPM_NOW / 1000)) ;; esac
    LINE="[$TS2] layar:$SCREEN cpu0:${C0_CUR_M}MHz floor_sys:${C0_MIN_M}MHz cpu4:${C4_CUR_M}MHz PPM_floor:${PPM_M}MHz load:${LOAD}"
    if [ "$SCREEN" != "$PREV_SCREEN" ] || [ "$PPM_NOW" != "$PREV_PPM" ]; then
        w ""
        w ">>> PERUBAHAN TERDETEKSI <<<"
        PREV_SCREEN="$SCREEN"; PREV_PPM="$PPM_NOW"
    fi
    w "$LINE"
    echo "$LINE"
    sleep 3
done
w ""
w "[Live monitor selesai: $(date)]"
fi  # end DO_MONITOR

# =====================================================================
s "19. RINGKASAN & STATUS CEK CEPAT"
# =====================================================================
w "Legenda: OK = sesuai target | MISMATCH = perlu re-apply | INFO = butuh cek manual"
nl
if [ "$DO_STATIC" = "1" ]; then
    case "$PPM_MIN_C0" in
        '') chk "CPU floor cluster0 (screen ON)" "TIDAK TERBACA (cek /proc/ppm/policy/hard_userlimit_min_cpu_freq manual)" ;;
        "$EXP_FLOOR_ON") chk "CPU floor cluster0 (screen ON)" "OK - $PPM_MIN_C0 Hz sesuai target Opsi C ($EXP_FLOOR_ON Hz)" ;;
        *) chk "CPU floor cluster0 (screen ON)" "MISMATCH - terbaca $PPM_MIN_C0 Hz, target $EXP_FLOOR_ON Hz -> perlu re-apply" ;;
    esac
    case "$PPM_MAX_C0" in
        '') chk "CPU ceiling cluster0 (screen ON)" "TIDAK TERBACA" ;;
        "$EXP_CEIL_ON") chk "CPU ceiling cluster0 (screen ON)" "OK - $PPM_MAX_C0 Hz sesuai target ($EXP_CEIL_ON Hz)" ;;
        *) chk "CPU ceiling cluster0 (screen ON)" "MISMATCH - terbaca $PPM_MAX_C0 Hz, target $EXP_CEIL_ON Hz" ;;
    esac
    case "$VM_SWAPPINESS" in
        "$EXP_SWAPPINESS") chk "vm.swappiness" "OK - $VM_SWAPPINESS" ;;
        *) chk "vm.swappiness" "MISMATCH - terbaca ${VM_SWAPPINESS:-N/A}, target $EXP_SWAPPINESS" ;;
    esac
    case "$VM_VFS_PRESSURE" in
        "$EXP_VFS_CACHE_PRESSURE") chk "vm.vfs_cache_pressure" "OK - $VM_VFS_PRESSURE" ;;
        *) chk "vm.vfs_cache_pressure" "MISMATCH - terbaca ${VM_VFS_PRESSURE:-N/A}, target $EXP_VFS_CACHE_PRESSURE" ;;
    esac
    case "$IO_SCHED_C" in
        *'[deadline]'*) chk "I/O scheduler mmcblk" "OK - deadline aktif" ;;
        *) chk "I/O scheduler mmcblk" "MISMATCH - terbaca: ${IO_SCHED_C:-N/A}" ;;
    esac
    case "$ZRAM_ALGO" in
        lz4*) chk "ZRAM compression" "OK - lz4" ;;
        *) chk "ZRAM compression" "INFO - terbaca: ${ZRAM_ALGO:-N/A}" ;;
    esac
    if [ "$CPU_LOOP_RUNNING" -gt 0 ] 2>/dev/null; then
        chk "cpu_floor_loop.sh (polling screen-aware)" "OK - proses berjalan"
    else
        chk "cpu_floor_loop.sh (polling screen-aware)" "MISMATCH - proses TIDAK ditemukan, floor screen-off/on bisa tidak ter-enforce"
    fi
    if [ "$FP_RUNNING" -gt 0 ] 2>/dev/null; then
        chk "Fingerprint HAL" "MISMATCH - proses fingerprint terdeteksi lagi (cek apakah service.sh masih stop dia)"
    else
        chk "Fingerprint HAL" "OK - tidak berjalan"
    fi
    if [ "$FDE_LEFTOVER" -gt 0 ] 2>/dev/null; then
        chk "Sisa FDE.AI" "INFO - masih ada jejak paket/file, cek Section 9"
    else
        chk "Sisa FDE.AI" "OK - tidak ditemukan"
    fi
    if [ "$LOGCAT_REGRESSION" -gt 0 ] 2>/dev/null; then
        chk "Regresi logcat (fingerprint/adb/wakelock loop)" "INFO - ada $LOGCAT_REGRESSION baris, cek Section 13"
    else
        chk "Regresi logcat (fingerprint/adb/wakelock loop)" "OK - bersih"
    fi
    chk "Play Integrity verdict" "INFO - tidak bisa dicek via shell, buka Play Store > Settings > About > tap versi 7x > Developer options > Check integrity"
else
    w "(Mode '$MODE' tidak menjalankan dump statis, ringkasan konfigurasi dilewati.)"
fi

nl
w "$S1"
w "  SELESAI: $(date)"
w "  File   : $OUT"
w "  Ukuran : $(du -h "$OUT" 2>/dev/null | cut -f1)"
w "$S1"

rm -rf "$TMP"
echo ""
echo "  +-----------------------------------------------------------+"
echo "  |   DIAGNOSTIK SELESAI"
echo "  +-----------------------------------------------------------+"
echo "  | File  : $OUT"
echo "  | Ukuran: $(du -h "$OUT" 2>/dev/null | cut -f1)"
[ "$DO_TOUCH" = "1" ] && echo "  | Touch raw: /sdcard/cereus_touch_*_${TS}.txt"
echo "  +-----------------------------------------------------------+"
echo "  | Kirim file .txt tersebut ke Rhael untuk analisis."
echo "  +-----------------------------------------------------------+"
echo ""
