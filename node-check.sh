#!/usr/bin/env bash
# node-check.sh — диагностика ноды Xray/Remnawave + автотюнинг сети
#
#   bash node-check.sh            отчёт; если BBR/fq не включены — включает и тюнит
#   bash node-check.sh --fix      принудительно применить тюнинг (даже если BBR уже есть)
#   bash node-check.sh --no-speed без спидтеста (быстрее)
#   bash node-check.sh --dry-run  только отчёт, ничего не менять
#
# Отчёт сохраняется в /root/node-report-<host>-<дата>.txt

set -u
export LC_ALL=C

FORCE_FIX=0; NO_SPEED=0; DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --fix) FORCE_FIX=1 ;;
    --no-speed) NO_SPEED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) printf '%s\n' "node-check.sh [--dry-run] [--fix] [--no-speed]" \
      "  без флагов   отчёт; если BBR/fq не включены, включает и тюнит" \
      "  --dry-run    только отчёт, ничего не менять" \
      "  --fix        применить тюнинг принудительно" \
      "  --no-speed   без спидтеста"; exit 0 ;;
    *) echo "Неизвестный аргумент: $a"; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Запустите от root"; exit 1; }

HOST=$(hostname)
REPORT="/root/node-report-${HOST}-$(date +%Y%m%d-%H%M).txt"
TUNE_FILE="/etc/sysctl.d/99-xray-tuning.conf"
exec > >(tee "$REPORT") 2>&1

sec()  { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
sc()   { sysctl -n "$1" 2>/dev/null || echo "n/a"; }

# ---------------------------------------------------------------- система
sec "СИСТЕМА"
echo "Host:     $HOST"
echo "Date:     $(date -u '+%Y-%m-%d %H:%M UTC')"
. /etc/os-release 2>/dev/null && echo "OS:       ${PRETTY_NAME:-?}"
echo "Kernel:   $(uname -r)"
echo "Virt:     $(systemd-detect-virt 2>/dev/null || echo '?')"
echo "CPU:      $(nproc) x $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "Uptime:   $(uptime -p 2>/dev/null)"
echo "Load:     $(cut -d' ' -f1-3 /proc/loadavg)"
echo "NTP sync: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')  (yes = часы синхронизированы)"

sec "ПАМЯТЬ И ДИСК"
free -h
echo
df -h / | tail -n +1
if have docker; then
  echo
  echo "Docker logs (размер json-логов контейнеров):"
  du -sh /var/lib/docker/containers 2>/dev/null || true
fi

sec "CPU STEAL / IO (vmstat 1 5)"
vmstat 1 5
echo "Подсказка: st > 5-10% стабильно = хостер перепродаёт CPU"

# ---------------------------------------------------------------- сеть
sec "TCP / BBR"
CC=$(sc net.ipv4.tcp_congestion_control)
QD=$(sc net.core.default_qdisc)
AVAIL=$(sc net.ipv4.tcp_available_congestion_control)
echo "congestion_control: $CC"
echo "default_qdisc:      $QD"
echo "available:          $AVAIL"
IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
echo "Внешний интерфейс:  ${IFACE:-?}"
IQD=""
[ -n "${IFACE:-}" ] && IQD=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
[ -n "${IFACE:-}" ] && echo "qdisc на $IFACE:     $(tc qdisc show dev "$IFACE" 2>/dev/null | head -1)"
[ -n "${IFACE:-}" ] && echo "MTU $IFACE:          $(cat /sys/class/net/"$IFACE"/mtu 2>/dev/null)"

sec "SYSCTL (ключевые)"
for k in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
         net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog \
         net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle \
         net.ipv4.tcp_notsent_lowat net.ipv4.ip_local_port_range fs.file-max \
         net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count; do
  printf '%-38s %s\n' "$k" "$(sc "$k")"
done
echo
echo "conntrack в dmesg:"
{ dmesg 2>/dev/null; journalctl -k --since "7 days ago" --no-pager 2>/dev/null; } | grep -i 'conntrack.*full' | tail -3 || true
CT_MAX=$(sc net.netfilter.nf_conntrack_max)
case "$CT_MAX" in ''|*[!0-9]*) ;; *) [ "$CT_MAX" -lt 65536 ] && echo "ВНИМАНИЕ: nf_conntrack_max=$CT_MAX слишком мал, при пиках пакеты будут дропаться";; esac
echo "(пусто = таблица не переполнялась)"

sec "СОЕДИНЕНИЯ"
ss -s
echo
echo "Слушают 443/80:"
ss -tlnp 2>/dev/null | awk 'NR==1 || /:443 |:80 /'

if have docker; then
  sec "DOCKER"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}'
  if docker ps --format '{{.Names}}' | grep -qx remnanode; then
    echo
    echo "Ошибки remnanode (последние 300 строк, без ежедневного рестарта):"
    docker logs remnanode --tail 300 2>&1 | grep -aiE 'error|fail|reject|panic' \
      | grep -avE 'StatsService|Failed to stop Xray' | tail -10
    echo "(пусто = ошибок нет)"
  fi
fi

sec "ПИНГ"
for t in 1.1.1.1 8.8.8.8 77.88.8.8; do
  p=$(ping -c 5 -q -W 2 "$t" 2>/dev/null)
  r=$(printf '%s\n' "$p" | awk -F'/' '/rtt|round-trip/{print "avg " $5 " ms"}')
  l=$(printf '%s\n' "$p" | grep -o '[0-9.]*% packet loss')
  printf '%-12s %s, %s\n' "$t" "${r:-нет ответа}" "${l:-?}"
done

if [ "$NO_SPEED" -eq 0 ]; then
  sec "СПИДТЕСТ"
  if have python3; then
    curl -fsSL --max-time 20 https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py \
      | python3 -W ignore - --simple --secure 2>&1 || echo "Спидтест не удался"
  else
    echo "python3 не найден, пропуск"
  fi
fi

# ---------------------------------------------------------------- тюнинг
# не уменьшаем значения, которые уже выше наших
keepmax() { local cur; cur=$(sc "$1" | awk '{print $NF}'); case "$cur" in ''|*[!0-9]*) echo "$2";; *) [ "$cur" -gt "$2" ] && echo "$cur" || echo "$2";; esac; }

apply_tuning() {
  sec "ПРИМЕНЯЮ ТЮНИНГ"
  modprobe tcp_bbr 2>/dev/null || true
  if ! sc net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
    echo "Ядро $(uname -r) не поддерживает BBR (нужно 4.9+ с модулем tcp_bbr). Тюнинг без BBR."
    BBR_LINE="# bbr недоступен в этом ядре"
  else
    BBR_LINE="net.ipv4.tcp_congestion_control = bbr"
    echo tcp_bbr > /etc/modules-load.d/bbr.conf
  fi

  # conntrack: ~64 записи на 1 МБ RAM, минимум 65536, максимум 1048576
  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  CT=$(( MEM_MB * 64 )); [ "$CT" -lt 65536 ] && CT=65536; [ "$CT" -gt 1048576 ] && CT=1048576

  RMAX=$(keepmax net.core.rmem_max 16777216); WMAX=$(keepmax net.core.wmem_max 16777216)
  TRMAX=$(keepmax net.ipv4.tcp_rmem 16777216); TWMAX=$(keepmax net.ipv4.tcp_wmem 16777216)
  SOMAX=$(keepmax net.core.somaxconn 8192); NDB=$(keepmax net.core.netdev_max_backlog 16384)
  SYNB=$(keepmax net.ipv4.tcp_max_syn_backlog 8192); FMAX=$(keepmax fs.file-max 1048576)
  CT=$(keepmax net.netfilter.nf_conntrack_max "$CT")

  [ -f "$TUNE_FILE" ] && cp "$TUNE_FILE" "$TUNE_FILE.bak.$(date +%s)"
  cat > "$TUNE_FILE" <<EOF
# node-check.sh: тюнинг под Xray ($(date -u '+%Y-%m-%d'))
net.core.default_qdisc = fq
$BBR_LINE

# буферы: до 16 МБ на сокет, хватает для гигабита на длинных маршрутах
net.core.rmem_max = $RMAX
net.core.wmem_max = $WMAX
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 $TRMAX
net.ipv4.tcp_wmem = 4096 65536 $TWMAX
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# очереди под пики соединений
net.core.somaxconn = $SOMAX
net.core.netdev_max_backlog = $NDB
net.ipv4.tcp_max_syn_backlog = $SYNB

# стабильность на плохих маршрутах (РФ, мобильные сети)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3

# быстрее освобождаем мёртвые соединения
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# лимиты
fs.file-max = $FMAX
net.netfilter.nf_conntrack_max = $CT
EOF
  # conntrack-ключ существует только при загруженном модуле
  # без модуля при загрузке sysctl не применит conntrack-ключ
  [ -e /proc/sys/net/netfilter/nf_conntrack_max ] && echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf
  if [ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
    sed -i 's/^net.netfilter.nf_conntrack_max/# &/' "$TUNE_FILE"
  fi

  # лимит открытых файлов для systemd-сервисов (в т.ч. docker)
  mkdir -p /etc/systemd/system.conf.d
  printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/99-nofile.conf

  sysctl --system >/dev/null 2>&1
  [ -n "${IFACE:-}" ] && tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true

  echo "Записано: $TUNE_FILE"
  echo "congestion_control: $(sc net.ipv4.tcp_congestion_control)"
  echo "default_qdisc:      $(sc net.core.default_qdisc)"
  [ -n "${IFACE:-}" ] && echo "qdisc на $IFACE:     $(tc qdisc show dev "$IFACE" 2>/dev/null | head -1)"
  echo "Новые соединения уже идут с новыми настройками, перезагрузка не нужна."
  echo "Откат: rm $TUNE_FILE /etc/systemd/system.conf.d/99-nofile.conf && sysctl --system"
}

sec "ИТОГ"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "--dry-run: ничего не меняю. BBR=$CC, qdisc=$QD"
elif [ "$FORCE_FIX" -eq 1 ] || [ "$CC" != "bbr" ] || [ "$QD" != "fq" ] || { [ -n "$IQD" ] && [ "$IQD" != "fq" ]; } \
     || { case "${CT_MAX:-x}" in *[!0-9]*) false;; *) [ "$CT_MAX" -lt 65536 ];; esac; }; then
  [ "$FORCE_FIX" -eq 0 ] && echo "Нужен тюнинг (cc=$CC, default_qdisc=$QD, qdisc интерфейса=${IQD:-?}, conntrack_max=${CT_MAX:-?}) — применяю."
  apply_tuning
else
  echo "BBR и fq включены (в том числе на интерфейсе), conntrack в норме. Принудительно: --fix"
fi

echo
echo "Отчёт сохранён: $REPORT"
