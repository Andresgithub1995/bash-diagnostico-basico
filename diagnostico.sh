#!/usr/bin/env bash
# diagnostico.sh - Diagnóstico básico (seguro) para PCs Linux
# Autor: Andres
# Uso:
#   ./diagnostico.sh --all
#   ./diagnostico.sh --system
#   ./diagnostico.sh --network
#   ./diagnostico.sh --menu
#   ./diagnostico.sh --all --export-txt --out reporte.txt

set -u  # (No uso -e para que una sección no mate todo el script)

# ----------------------------
# Helpers
# ----------------------------

hr() { printf "\n%s\n" "======================================================================" ; }
section() { hr; echo "$1"; hr; }

have() { command -v "$1" >/dev/null 2>&1; }

safe_run() {
  # safe_run "NombreSeccion" comando...
  local name="$1"; shift
  if "$@" 2>/tmp/diag_err.$$; then
    rm -f /tmp/diag_err.$$
    return 0
  else
    echo "[ERROR] $name: $(cat /tmp/diag_err.$$)"
    rm -f /tmp/diag_err.$$
    return 1
  fi
}

default_out="reporte_diagnostico.txt"
OUT_PATH=""
EXPORT_TXT=0

# Flags
DO_SYSTEM=0
DO_PERF=0
DO_DISK=0
DO_NETWORK=0
DO_CONNECT=0
DO_DNS=0
DO_SERVICES=0
DO_LOGS=0
DO_HW=0

# ----------------------------
# 1) Sistema
# ----------------------------
system_summary() {
  section "SYSTEM"
  echo "Hostname: $(hostname 2>/dev/null || echo "N/A")"
  echo "User: ${USER:-N/A}"
  echo "Date: $(date -Is 2>/dev/null || date)"
  echo

  if [ -f /etc/os-release ]; then
    echo "OS:"
    cat /etc/os-release | sed -n 's/^PRETTY_NAME=//p' | tr -d '"'
  else
    echo "OS: N/A"
  fi

  echo "Kernel: $(uname -srmo 2>/dev/null || uname -a)"
  echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
  echo

  if have lscpu; then
    echo "CPU (lscpu):"
    lscpu | sed -n '1,20p'
  else
    echo "CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')"
  fi
}

# ----------------------------
# 2) Performance (CPU/RAM + procesos)
# ----------------------------
perf_snapshot() {
  section "PERFORMANCE"
  echo "Load average:"
  if [ -f /proc/loadavg ]; then
    cat /proc/loadavg
  else
    uptime
  fi
  echo

  echo "Memory (free -h):"
  if have free; then
    free -h
  else
    cat /proc/meminfo | head -n 15
  fi
  echo

  echo "Top processes (CPU):"
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 11 || true
  echo

  echo "Top processes (MEM):"
  ps -eo pid,comm,%cpu,%mem --sort=-%mem 2>/dev/null | head -n 11 || true
}

# ----------------------------
# 3) Disco
# ----------------------------
disk_summary() {
  section "DISK"
  echo "Filesystem usage (df -h):"
  df -h 2>/dev/null || true
  echo

  echo "Block devices (lsblk):"
  if have lsblk; then
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null || lsblk
  else
    echo "lsblk not found."
  fi
}

# ----------------------------
# 4) Red: IP, interfaces, rutas, DNS
# ----------------------------
network_summary() {
  section "NETWORK"
  if have ip; then
    echo "Interfaces (ip -br addr):"
    ip -br addr 2>/dev/null || true
    echo

    echo "Routes (ip route):"
    ip route 2>/dev/null || true
  else
    echo "ip command not found. Trying ifconfig/route..."
    have ifconfig && ifconfig || true
    have route && route -n || true
  fi

  echo
  echo "DNS (/etc/resolv.conf):"
  [ -f /etc/resolv.conf ] && sed 's/^/  /' /etc/resolv.conf || echo "  N/A"
}

# ----------------------------
# 5) Conectividad: gateway, ping, puerto
# ----------------------------
connectivity_tests() {
  section "CONNECTIVITY"

  local gw=""
  if have ip; then
    gw="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
  fi

  echo "Default gateway: ${gw:-N/A}"
  echo

  if have ping; then
    if [ -n "$gw" ]; then
      echo "Ping gateway ($gw):"
      ping -c 2 -W 2 "$gw" 2>/dev/null && echo "OK" || echo "FAILED"
      echo
    fi

    echo "Ping public (1.1.1.1):"
    ping -c 2 -W 2 1.1.1.1 2>/dev/null && echo "OK" || echo "FAILED"
  else
    echo "ping not found."
  fi

  echo
  echo "TCP test (google.com:443):"
  if have nc; then
    nc -vz -w 3 google.com 443 2>&1 | tail -n 2
  elif have bash; then
    # Bash built-in TCP test
    (echo > /dev/tcp/google.com/443) >/dev/null 2>&1 && echo "TCP OK" || echo "TCP FAILED"
  else
    echo "No method to test TCP (nc not found)."
  fi
}

# ----------------------------
# 6) DNS: resolver nombres con fallback
# ----------------------------
dns_diagnostics() {
  section "DNS"
  local names=("google.com" "cloudflare.com" "microsoft.com")

  echo "DNS servers:"
  if have resolvectl; then
    resolvectl status 2>/dev/null | sed -n '1,80p'
  elif have systemd-resolve; then
    systemd-resolve --status 2>/dev/null | sed -n '1,80p'
  else
    [ -f /etc/resolv.conf ] && grep -E '^\s*nameserver' /etc/resolv.conf || echo "N/A"
  fi
  echo

  for n in "${names[@]}"; do
    echo "Resolve: $n"
    if have dig; then
      dig +short "$n" | head -n 5
    elif have nslookup; then
      nslookup "$n" 2>/dev/null | sed -n '1,12p'
    else
      getent ahosts "$n" 2>/dev/null | head -n 5 || echo "No resolver tool found."
    fi
    echo
  done
}

# ----------------------------
# 7) Servicios (systemd si existe)
# ----------------------------
services_health() {
  section "SERVICES"
  if ! have systemctl; then
    echo "systemctl not found (maybe not systemd). Skipping."
    return 0
  fi

  local services=("NetworkManager" "systemd-resolved" "ssh" "cron" "cups")
  for s in "${services[@]}"; do
    echo "Service: $s"
    systemctl is-enabled "$s" 2>/dev/null | sed 's/^/  enabled: /' || true
    systemctl is-active  "$s" 2>/dev/null | sed 's/^/  active:  /' || true
    echo
  done
}

# ----------------------------
# 8) Logs recientes
# ----------------------------
logs_recent() {
  section "LOGS"
  if have journalctl; then
    echo "journalctl (last 50 lines, warnings+errors if possible):"
    journalctl -p warning -n 50 --no-pager 2>/dev/null || journalctl -n 50 --no-pager 2>/dev/null || true
  else
    echo "journalctl not found. Showing common logs (if exist):"
    for f in /var/log/syslog /var/log/messages /var/log/dmesg; do
      if [ -f "$f" ]; then
        echo "--- $f (last 40) ---"
        tail -n 40 "$f"
        echo
      fi
    done
  fi
}

# ----------------------------
# 9) Hardware / Drivers / dmesg
# ----------------------------
hardware_info() {
  section "HARDWARE"
  echo "PCI devices (lspci):"
  have lspci && lspci | head -n 40 || echo "lspci not found."
  echo

  echo "USB devices (lsusb):"
  have lsusb && lsusb | head -n 40 || echo "lsusb not found."
  echo

  echo "dmesg (last 50 lines):"
  have dmesg && dmesg | tail -n 50 || echo "dmesg not found."
}

# ----------------------------
# 10) Reporte exportable (TXT)
# ----------------------------
run_selected() {
  # Ejecuta secciones según flags
  [ "$DO_SYSTEM"   -eq 1 ] && system_summary
  [ "$DO_PERF"     -eq 1 ] && perf_snapshot
  [ "$DO_DISK"     -eq 1 ] && disk_summary
  [ "$DO_NETWORK"  -eq 1 ] && network_summary
  [ "$DO_CONNECT"  -eq 1 ] && connectivity_tests
  [ "$DO_DNS"      -eq 1 ] && dns_diagnostics
  [ "$DO_SERVICES" -eq 1 ] && services_health
  [ "$DO_LOGS"     -eq 1 ] && logs_recent
  [ "$DO_HW"       -eq 1 ] && hardware_info
}

show_menu() {
  echo
  echo "diagnostico.sh - Menu"
  echo "1) System"
  echo "2) Performance"
  echo "3) Disk"
  echo "4) Network"
  echo "5) Connectivity"
  echo "6) DNS"
  echo "7) Services"
  echo "8) Logs"
  echo "9) Hardware"
  echo "A) All"
  echo "Q) Quit"
  echo
  read -r -p "Choose: " choice

  case "${choice^^}" in
    1) DO_SYSTEM=1 ;;
    2) DO_PERF=1 ;;
    3) DO_DISK=1 ;;
    4) DO_NETWORK=1 ;;
    5) DO_CONNECT=1 ;;
    6) DO_DNS=1 ;;
    7) DO_SERVICES=1 ;;
    8) DO_LOGS=1 ;;
    9) DO_HW=1 ;;
    A) DO_SYSTEM=1; DO_PERF=1; DO_DISK=1; DO_NETWORK=1; DO_CONNECT=1; DO_DNS=1; DO_SERVICES=1; DO_LOGS=1; DO_HW=1 ;;
    Q) exit 0 ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: ./diagnostico.sh [options]

Options:
  --all              Run all sections
  --system           System summary
  --performance      CPU/RAM + processes
  --disk             Disk usage / devices
  --network          Interfaces / routes / DNS config
  --connectivity     Ping + TCP test
  --dns              DNS diagnostics
  --services         Basic service health (systemd)
  --logs             Recent logs
  --hardware         Hardware summary
  --menu             Interactive menu
  --export-txt        Save output to a TXT file
  --out <path>        Output file path for --export-txt
  -h, --help          Show help
EOF
}

# ----------------------------
# Parse args
# ----------------------------
if [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) DO_SYSTEM=1; DO_PERF=1; DO_DISK=1; DO_NETWORK=1; DO_CONNECT=1; DO_DNS=1; DO_SERVICES=1; DO_LOGS=1; DO_HW=1 ;;
    --system) DO_SYSTEM=1 ;;
    --performance) DO_PERF=1 ;;
    --disk) DO_DISK=1 ;;
    --network) DO_NETWORK=1 ;;
    --connectivity) DO_CONNECT=1 ;;
    --dns) DO_DNS=1 ;;
    --services) DO_SERVICES=1 ;;
    --logs) DO_LOGS=1 ;;
    --hardware) DO_HW=1 ;;
    --menu) show_menu ;;
    --export-txt) EXPORT_TXT=1 ;;
    --out) shift; OUT_PATH="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift || true
done

# ----------------------------
# Run + optional export
# ----------------------------
if [ "$EXPORT_TXT" -eq 1 ]; then
  out="${OUT_PATH:-$default_out}"
  run_selected | tee "$out"
  echo
  echo "Saved TXT report to: $out"
else
  run_selected
fi
