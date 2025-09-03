#!/bin/bash
# =====================================================================
# Disk/Partition Backup Manager v7.01 - ПОЛНАЯ ИСПРАВЛЕННАЯ ВЕРСИЯ
# Полностью исправленный рабочий вариант с поддержкой автоматической сборки утилит прогресса
# =====================================================================
set -u
# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
MAGENTA='\033[0;35m'; BOLD='\033[1m'

log()    { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warning(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
info()   { echo -e "${CYAN}[INFO]${NC} $1"; }

CONFIG_FILE="$HOME/.backup_manager_config"
PROFILES_DIR="$HOME/.backup_manager_profiles"
BUILD_DIR="/tmp/backup_manager_build"
BACKUP_LOCATION=""
COMPRESSION_ENABLED=true
PROGRESS_METHOD="dd_progress"  # dd_progress, pv, dcfldd, builtin
NETWORK_MOUNTED=false
MOUNT_POINT="/tmp/backup_mount_$$"
SELECTED_DISKS=()
HAS_PV=false; HAS_DCFLDD=false; HAS_PROGRESS=false
HAS_CIFS_UTILS=false; HAS_SSHFS=false

# URLs для исходников
PV_URL="https://ivarch.com/s/pv-1.9.34.tar.gz"
DCFLDD_URL="https://github.com/resurrecting-open-source-projects/dcfldd"
PROGRESS_URL="https://github.com/Xfennec/progress"

# ======== Основные функции ========
check_root(){
  [[ $EUID -ne 0 ]] && { error "Запустите скрипт от root"; exit 1; }
}

save_config(){
  mkdir -p "$(dirname "$CONFIG_FILE")"
  {
    echo "COMPRESSION_ENABLED=$COMPRESSION_ENABLED"
    echo "PROGRESS_METHOD=\"$PROGRESS_METHOD\""
    echo "BACKUP_LOCATION=\"$BACKUP_LOCATION\""
    echo -n "SELECTED_DISKS=("
    for d in "${SELECTED_DISKS[@]}"; do printf "%q " "$d"; done
    echo ")"
  } > "$CONFIG_FILE"
}

load_config(){
  [[ -f "$CONFIG_FILE" ]] || return
  . "$CONFIG_FILE" 2>/dev/null || return
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  [[ -z "${PROGRESS_METHOD+x}" ]] && PROGRESS_METHOD="dd_progress"
  local v=() t
  for t in "${SELECTED_DISKS[@]}"; do [[ -b "$t" ]] && v+=("$t"); done
  SELECTED_DISKS=("${v[@]}")
  [[ -n "$BACKUP_LOCATION" && ! -d "$BACKUP_LOCATION" ]] && {
    warning "Папка назначения $BACKUP_LOCATION недоступна"
    BACKUP_LOCATION=""
  }
}

check_build_dependencies(){
  local needed=(curl wget tar gzip gcc make autoconf automake pkg-config git)
  local miss=() optional=()
  
  for c in "${needed[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      if [[ "$c" == "git" || "$c" == "autoconf" || "$c" == "automake" || "$c" == "pkg-config" ]]; then
        optional+=("$c")
      else
        miss+=("$c")
      fi
    fi
  done
  
  if [[ ${#miss[@]} -gt 0 ]]; then
    error "Критичные зависимости отсутствуют: ${miss[*]}"
    info "Установите их командой:"
    detect_package_manager_and_suggest "${miss[@]}"
    return 1
  fi
  
  if [[ ${#optional[@]} -gt 0 ]]; then
    warning "Опциональные зависимости отсутствуют: ${optional[*]}"
    info "Рекомендуется установить для сборки из Git:"
    detect_package_manager_and_suggest "${optional[@]}"
  fi
  
  return 0
}

detect_package_manager_and_suggest(){
  local packages=("$@")
  local pkg_str="${packages[*]}"
  
  if command -v apt >/dev/null 2>&1; then
    echo "  sudo apt update && sudo apt install $pkg_str libncurses5-dev"
  elif command -v yum >/dev/null 2>&1; then
    echo "  sudo yum install $pkg_str ncurses-devel"
  elif command -v dnf >/dev/null 2>&1; then
    echo "  sudo dnf install $pkg_str ncurses-devel"
  elif command -v pacman >/dev/null 2>&1; then
    echo "  sudo pacman -S $pkg_str ncurses"
  elif command -v zypper >/dev/null 2>&1; then
    echo "  sudo zypper install $pkg_str ncurses-devel"
  else
    echo "  (определите пакетный менеджер самостоятельно)"
  fi
}

check_core_dependencies(){
  local needed=(lsblk dd mount umount gzip gunzip df stat blockdev awk sed grep tr)
  local miss=()
  for c in "${needed[@]}"; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  [[ ${#miss[@]} -gt 0 ]] && { error "Установите: ${miss[*]}"; exit 1; }
}

check_progress_tools(){
  # Проверяем доступность утилит прогресса
  command -v pv >/dev/null 2>&1 && HAS_PV=true
  command -v dcfldd >/dev/null 2>&1 && HAS_DCFLDD=true
  command -v progress >/dev/null 2>&1 && HAS_PROGRESS=true
  
  # Проверяем поддержку status=progress в dd
  local dd_version=$(dd --version 2>/dev/null | head -n1)
  if [[ -n "$dd_version" ]]; then
    info "Версия dd: $dd_version"
  fi
  
  # Автоматически выбираем лучший метод
  if [[ "$PROGRESS_METHOD" == "auto" ]]; then
    if $HAS_PV; then
      PROGRESS_METHOD="pv"
      info "Автовыбор: используется pv для прогресса"
    elif $HAS_DCFLDD; then
      PROGRESS_METHOD="dcfldd"
      info "Автовыбор: используется dcfldd для прогресса"
    else
      PROGRESS_METHOD="dd_progress"
      info "Автовыбор: используется встроенный dd status=progress"
    fi
  fi
}

check_network_tools(){
  command -v mount.cifs >/dev/null 2>&1 && HAS_CIFS_UTILS=true
  command -v sshfs >/dev/null 2>&1 && HAS_SSHFS=true
}

# Функции для сборки утилит из исходников
setup_build_environment(){
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR" || { error "Не удалось создать папку сборки"; return 1; }
  info "Рабочая папка сборки: $BUILD_DIR"
}

cleanup_build_environment(){
  if [[ -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
    info "Папка сборки очищена"
  fi
}

install_pv_from_source(){
  info "Начинаем сборку pv из исходников..."
  
  if ! check_build_dependencies; then
    return 1
  fi
  
  setup_build_environment || return 1
  
  info "Скачиваем pv..."
  if ! curl -L "$PV_URL" -o pv.tar.gz; then
    error "Не удалось скачать pv"
    return 1
  fi
  
  info "Распаковываем архив..."
  tar xzf pv.tar.gz || { error "Не удалось распаковать pv"; return 1; }
  
  local pv_dir=$(find . -name "pv-*" -type d | head -n1)
  if [[ -z "$pv_dir" ]]; then
    error "Не найдена папка с исходниками pv"
    return 1
  fi
  
  cd "$pv_dir" || return 1
  
  info "Конфигурируем сборку..."
  if ! ./configure --prefix=/usr/local; then
    error "Ошибка конфигурации pv"
    return 1
  fi
  
  info "Компилируем pv..."
  if ! make -j$(nproc 2>/dev/null || echo 2); then
    error "Ошибка компиляции pv"
    return 1
  fi
  
  info "Устанавливаем pv..."
  if ! make install; then
    error "Ошибка установки pv"
    return 1
  fi
  
  # Обновляем PATH если нужно
  if ! command -v pv >/dev/null 2>&1; then
    export PATH="/usr/local/bin:$PATH"
  fi
  
  if command -v pv >/dev/null 2>&1; then
    success "pv успешно установлен: $(pv --version 2>&1 | head -n1)"
    HAS_PV=true
    return 0
  else
    error "pv установлен, но не найден в PATH"
    return 1
  fi
}

install_dcfldd_from_source(){
  info "Начинаем сборку dcfldd из исходников..."
  
  if ! check_build_dependencies; then
    return 1
  fi
  
  if ! command -v git >/dev/null 2>&1; then
    error "Git не установлен. Используем архив вместо репозитория."
    return 1
  fi
  
  setup_build_environment || return 1
  
  info "Клонируем репозиторий dcfldd..."
  if ! git clone "$DCFLDD_URL" dcfldd; then
    error "Не удалось клонировать dcfldd"
    return 1
  fi
  
  cd dcfldd || return 1
  
  info "Генерируем конфигурационные файлы..."
  if ! ./autogen.sh; then
    error "Ошибка autogen для dcfldd"
    return 1
  fi
  
  info "Конфигурируем сборку..."
  if ! ./configure --prefix=/usr/local; then
    error "Ошибка конфигурации dcfldd"
    return 1
  fi
  
  info "Компилируем dcfldd..."
  if ! make -j$(nproc 2>/dev/null || echo 2); then
    error "Ошибка компиляции dcfldd"
    return 1
  fi
  
  info "Устанавливаем dcfldd..."
  if ! make install; then
    error "Ошибка установки dcfldd"
    return 1
  fi
  
  # Обновляем PATH если нужно
  if ! command -v dcfldd >/dev/null 2>&1; then
    export PATH="/usr/local/bin:$PATH"
  fi
  
  if command -v dcfldd >/dev/null 2>&1; then
    success "dcfldd успешно установлен: $(dcfldd --version 2>&1 | head -n1)"
    HAS_DCFLDD=true
    return 0
  else
    error "dcfldd установлен, но не найден в PATH"
    return 1
  fi
}

install_progress_from_source(){
  info "Начинаем сборку progress из исходников..."
  
  if ! check_build_dependencies; then
    return 1
  fi
  
  if ! command -v git >/dev/null 2>&1; then
    error "Git не установлен"
    return 1
  fi
  
  # Проверяем наличие ncurses
  if ! pkg-config --exists ncurses 2>/dev/null && ! ls /usr/include/ncurses* >/dev/null 2>&1; then
    error "Библиотека ncurses не найдена"
    info "Установите: libncurses5-dev (Ubuntu/Debian) или ncurses-devel (CentOS/RHEL)"
    return 1
  fi
  
  setup_build_environment || return 1
  
  info "Клонируем репозиторий progress..."
  if ! git clone "$PROGRESS_URL" progress; then
    error "Не удалось клонировать progress"
    return 1
  fi
  
  cd progress || return 1
  
  info "Компилируем progress..."
  if ! make -j$(nproc 2>/dev/null || echo 2); then
    error "Ошибка компиляции progress"
    return 1
  fi
  
  info "Устанавливаем progress..."
  if ! make install PREFIX=/usr/local; then
    error "Ошибка установки progress"
    return 1
  fi
  
  # Обновляем PATH если нужно
  if ! command -v progress >/dev/null 2>&1; then
    export PATH="/usr/local/bin:$PATH"
  fi
  
  if command -v progress >/dev/null 2>&1; then
    success "progress успешно установлен"
    HAS_PROGRESS=true
    return 0
  else
    error "progress установлен, но не найден в PATH"
    return 1
  fi
}

format_size(){
  local b=$1
  if ! [[ "$b" =~ ^[0-9]+$ ]]; then echo "0B"; return; fi
  local sizes=(B K M G T)
  local i=0
  while (( b > 1024 && i < 4 )); do
    b=$((b/1024))
    ((i++))
  done
  echo "${b}${sizes[i]}"
}

format_time(){
  local s="$1" 
  local h=$((s/3600)) 
  local m=$(((s%3600)/60)) 
  local ss=$((s%60))
  if ((h>0)); then 
    printf "%02d:%02d:%02d" $h $m $ss
  elif ((m>0)); then 
    printf "%02d:%02d" $m $ss
  else 
    printf "%ds" $ss
  fi
}

show_progress_bar(){
  local current=$1
  local total=$2
  local width=50
  local percent=$((current * 100 / total))
  local filled=$((current * width / total))
  local empty=$((width - filled))
  
  printf "\r${BOLD}Прогресс: [${GREEN}"
  printf "%*s" $filled | tr ' ' '='
  printf "${NC}${BOLD}"
  printf "%*s" $empty | tr ' ' '-'
  printf "] %3d%% (%s/%s)${NC}" $percent "$(format_size $current)" "$(format_size $total)"
}

dd_with_progress(){
  local input="$1"
  local output="$2" 
  local size="$3"
  local bs="${4:-1M}"
  
  case "$PROGRESS_METHOD" in
    "pv")
      if $HAS_PV; then
        if $COMPRESSION_ENABLED; then
          pv -s "$size" "$input" | gzip > "$output"
        else
          pv -s "$size" "$input" > "$output"
        fi
        return $?
      fi
      ;&  # fallthrough
    "dcfldd")
      if $HAS_DCFLDD; then
        if $COMPRESSION_ENABLED; then
          dcfldd if="$input" bs="$bs" conv=noerror,sync 2>/dev/null | gzip > "$output"
        else
          dcfldd if="$input" of="$output" bs="$bs" conv=noerror,sync
        fi
        return $?
      fi
      ;&  # fallthrough
    "dd_progress")
      if $COMPRESSION_ENABLED; then
        local temp_file=$(mktemp --tmpdir="$(dirname "$output")" backup_temp_XXXXXX.img 2>/dev/null || mktemp)
        echo -e "\n${MAGENTA}Копирование с диска...${NC}"
        dd if="$input" of="$temp_file" bs="$bs" conv=noerror,sync status=progress 2>&1
        local rc=$?
        if [[ $rc -eq 0 && -f "$temp_file" ]]; then
          echo -e "\n${MAGENTA}Сжатие данных...${NC}"
          pv "$temp_file" 2>/dev/null | gzip > "$output" || gzip -c "$temp_file" > "$output"
          rc=$?
        fi
        rm -f "$temp_file"
        return $rc
      else
        echo -e "\n${MAGENTA}Копирование с прогрессом...${NC}"
        dd if="$input" of="$output" bs="$bs" conv=noerror,sync status=progress 2>&1
        return $?
      fi
      ;;
    "builtin")
      local block_size=1048576  # 1MB
      local blocks_total=$((size / block_size))
      local blocks_done=0
      
      if $COMPRESSION_ENABLED; then
        local temp_file=$(mktemp --tmpdir="$(dirname "$output")" backup_temp_XXXXXX.img 2>/dev/null || mktemp)
        echo -e "\n${MAGENTA}Копирование блоками по 1MB...${NC}"
        
        while (( blocks_done < blocks_total )); do
          dd if="$input" of="$temp_file" bs=$block_size count=1 seek=$blocks_done skip=$blocks_done conv=noerror,sync 2>/dev/null
          ((blocks_done++))
          show_progress_bar $((blocks_done * block_size)) "$size"
          sleep 0.01
        done
        
        echo -e "\n${MAGENTA}Сжатие...${NC}"
        gzip -c "$temp_file" > "$output"
        local rc=$?
        rm -f "$temp_file"
        return $rc
      else
        echo -e "\n${MAGENTA}Копирование блоками по 1MB...${NC}"
        while (( blocks_done < blocks_total )); do
          dd if="$input" of="$output" bs=$block_size count=1 seek=$blocks_done skip=$blocks_done conv=noerror,sync 2>/dev/null
          ((blocks_done++))
          show_progress_bar $((blocks_done * block_size)) "$size"
          sleep 0.01
        done
        echo
        return 0
      fi
      ;;
  esac
}

get_device_size(){ blockdev --getsize64 "$1" 2>/dev/null || echo 0; }

list_disks_raw(){ lsblk -pdn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'; }

find_all_partitions(){ lsblk -pln -o NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}'; }

get_partition_details(){
  local dev="$1"
  local size fs label mount
  size=$(lsblk -pdn -o SIZE "$dev" 2>/dev/null | tr -d ' ')
  fs=$(lsblk -pdn -o FSTYPE "$dev" 2>/dev/null | tr -d ' ')
  label=$(lsblk -pdn -o LABEL "$dev" 2>/dev/null | tr -d ' ')
  mount=$(lsblk -pdn -o MOUNTPOINT "$dev" 2>/dev/null | tr -d ' ')
  [[ -z "$size" ]] && size="-"
  [[ -z "$fs" ]] && fs="-"
  [[ -z "$label" ]] && label="-"
  [[ -z "$mount" ]] && mount="-"
  echo "$size|$fs|$label|$mount"
}

show_detailed_disk_info(){
  clear
  echo -e "${CYAN}== Диски и разделы ==${NC}\n"
  while IFS= read -r dev; do
    [[ -b "$dev" ]] || continue
    local size=$(format_size "$(get_device_size "$dev")")
    local model=$(lsblk -pdn -o MODEL "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo -e "${YELLOW}$dev ($size)${model:+ - $model}${NC}"
    local parts=$(get_disk_partitions_simple "$dev")
    if [[ -n "$parts" ]]; then
      printf "  %-16s %-8s %-10s %-12s %-20s %-8s\n" "УСТРОЙСТВО" "РАЗМЕР" "ФС" "МЕТКА" "МОНТ." "СИСТ."
      while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        local details=$(get_partition_details "$part")
        IFS='|' read -r psize pfs plabel pmount <<< "$details"
        local sys="no"
        [[ "$pmount" != "-" ]] && sys="yes"
        printf "  %-16s %-8s %-10s %-12s %-20s %-8s\n" "$part" "$psize" "$pfs" "$plabel" "$pmount" "$sys"
      done <<< "$parts"
    else
      echo "  (разделы отсутствуют)"
    fi
    echo
  done < <(list_disks_raw)
  read -r -p "Нажмите Enter..."
}

get_disk_partitions_simple(){
  lsblk -pln -o NAME,TYPE "$1" 2>/dev/null | awk '$2=="part"{print $1}'
}

select_backup_targets(){
  clear
  echo -e "${CYAN}== Выбор дисков/разделов ==${NC}\n"
  local disks=() infos=()
  while IFS= read -r dev; do
    [[ -b "$dev" ]] || continue
    local size=$(format_size "$(get_device_size "$dev")")
    local model=$(lsblk -pdn -o MODEL "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    disks+=("$dev")
    infos+=("$size - ${model:-Unknown}")
  done < <(list_disks_raw)
  [[ ${#disks[@]} -eq 0 ]] && { error "Нет дисков"; read -r -p "Нажмите Enter..."; return 1; }
  echo "Режим выбора:"
  echo "1) Диски целиком"
  echo "2) Только разделы"
  echo "3) Смешанный"
  local mode
  read -r -p "Выбор: " mode
  SELECTED_DISKS=()
  case "$mode" in
    1)
      local i
      for i in "${!disks[@]}"; do
        printf "%2d) %-16s %s\n" $((i+1)) "${disks[i]}" "${infos[i]}"
      done
      local in
      read -r -p "Введите номера (или all): " in
      if [[ "$in" == "all" ]]; then
        SELECTED_DISKS=("${disks[@]}")
      else
        for n in $in; do
          [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#disks[@]} ]] && SELECTED_DISKS+=("${disks[$((n-1))]}") || warning "Пропущено $n"
        done
      fi
      ;;
    2)
      local parts=() pinfos=()
      while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        local details=$(get_partition_details "$part")
        IFS='|' read -r psize pfs plabel pmount <<< "$details"
        local info="$psize"
        [[ "$pfs" != "-" ]] && info="$info [$pfs]"
        [[ "$plabel" != "-" ]] && info="$info \"$plabel\""
        [[ "$pmount" != "-" ]] && info="$info -> $pmount"
        parts+=("$part")
        pinfos+=("$info")
      done < <(find_all_partitions)
      [[ ${#parts[@]} -eq 0 ]] && { error "Разделы не найдены"; read -r -p "Нажмите Enter..."; return 1; }
      local i
      for i in "${!parts[@]}"; do
        printf "%2d) %-16s %s\n" $((i+1)) "${parts[i]}" "${pinfos[i]}"
      done
      local in
      read -r -p "Введите номера: " in
      for n in $in; do
        [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#parts[@]} ]] && SELECTED_DISKS+=("${parts[$((n-1))]}") || warning "Пропущено $n"
      done
      ;;
    3)
      local all=() ainfo=()
      for i in "${!disks[@]}"; do
        all+=("${disks[i]}")
        ainfo+=("Диск: ${infos[i]}")
      done
      while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        local details=$(get_partition_details "$part")
        IFS='|' read -r psize pfs plabel pmount <<< "$details"
        local info="Раздел: $psize"
        [[ "$pfs" != "-" ]] && info="$info [$pfs]"
        [[ "$plabel" != "-" ]] && info="$info \"$plabel\""
        [[ "$pmount" != "-" ]] && info="$info -> $pmount"
        all+=("$part")
        ainfo+=("$info")
      done < <(find_all_partitions)
      [[ ${#all[@]} -eq 0 ]] && { error "Ничего не выбрано"; read -r -p "Нажмите Enter..."; return 1; }
      local i
      for i in "${!all[@]}"; do
        printf "%2d) %-16s %s\n" $((i+1)) "${all[i]}" "${ainfo[i]}"
      done
      local in
      read -r -p "Введите номера: " in
      for n in $in; do
        [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#all[@]} ]] && SELECTED_DISKS+=("${all[$((n-1))]}") || warning "Пропущено $n"
      done
      ;;
    *)
      warning "Неверный выбор"
      read -r -p "Нажмите Enter..."
      return 1
      ;;
  esac
  [[ ${#SELECTED_DISKS[@]} -eq 0 ]] && { error "Не выбрано"; read -r -p "Нажмите Enter..."; return 1; }
  save_config
  success "Выбрано: ${SELECTED_DISKS[*]}"
  read -r -p "Нажмите Enter..."
}

calculate_required_space(){
  local total=0
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
    echo $((5*1024*1024*1024))  # Минимум 5ГБ
    return
  fi
  local t s
  for t in "${SELECTED_DISKS[@]}"; do
    s=$(get_device_size "$t")
    [[ $s -eq 0 ]] && continue
    if $COMPRESSION_ENABLED; then
      s=$((s*30/100))
    fi
    total=$((total+s))
  done
  echo $((total + total/10))
}

check_local_path_conflicts(){
  local dst="$1" realdst
  realdst=$(readlink -f "$dst" 2>/dev/null || echo "$dst")
  local t mnt rmnt
  for t in "${SELECTED_DISKS[@]:-}"; do
    if [[ "$t" =~ [0-9]+$ ]]; then
      mnt=$(lsblk -pdn -o MOUNTPOINT "$t" 2>/dev/null | tr -d ' ')
      if [[ -n "$mnt" ]]; then
        rmnt=$(readlink -f "$mnt" 2>/dev/null || echo "$mnt")
        [[ "$realdst/" == "$rmnt/"* || "$realdst" == "$rmnt" ]] && {
          error "Путь назначения совпадает с исходным устройством: $t ($mnt)"
          return 1
        }
      fi
    fi
  done
  return 0
}

create_backup_metadata(){
  local session_dir="$1"
  local metadata_file="$session_dir/backup_info.txt"
  {
    echo "# Backup Session Info"
    echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Host: $(hostname)"
    echo "# Compression: $($COMPRESSION_ENABLED && echo enabled || echo disabled)"
    echo "# Progress Method: $PROGRESS_METHOD"
    echo "# Script Version: v7.01"
    echo ""
  } > "$metadata_file"
  info "Создан файл метаданных: $metadata_file"
}

add_backup_entry(){
  local session_dir="$1" device="$2" filename="$3"
  local original_size="$4" compressed_size="$5" duration="$6"
  local metadata_file="$session_dir/backup_info.txt"
  local type="disk"
  [[ "$device" =~ [0-9]+$ ]] && type="partition"
  local fs label mount model=""
  if [[ "$type" == "partition" ]]; then
    fs=$(lsblk -pdn -o FSTYPE "$device" 2>/dev/null | tr -d ' ')
    label=$(lsblk -pdn -o LABEL "$device" 2>/dev/null | tr -d ' ')
    mount=$(lsblk -pdn -o MOUNTPOINT "$device" 2>/dev/null | tr -d ' ')
  else
    model=$(lsblk -pdn -o MODEL "$device" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi
  {
    echo "[$filename]"
    echo "device=$device"
    echo "type=$type"
    [[ -n "$model" ]] && echo "model=$model"
    [[ -n "$fs" && "$fs" != "-" ]] && echo "filesystem=$fs"
    [[ -n "$label" && "$label" != "-" ]] && echo "label=$label"
    [[ -n "$mount" && "$mount" != "-" ]] && echo "mountpoint=$mount"
    echo "original_size=$original_size"
    echo "compressed_size=$compressed_size"
    if [[ $original_size -gt 0 && $compressed_size -gt 0 ]]; then
      local ratio=$((compressed_size * 100 / original_size))
      echo "compression_ratio=${ratio}%"
    fi
    echo "duration=$duration"
    echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
  } >> "$metadata_file"
}

make_backup_session_dir(){
  local base="$BACKUP_LOCATION" host ts dir
  host="$(hostname -s 2>/dev/null || hostname)"
  ts="$(date +%Y-%m-%d_%H%M%S)"
  dir="$base/$host/$ts"
  mkdir -p "$dir" || { error "Не удалось создать папку $dir"; return 1; }
  echo "$dir"
}

backup_disk_with_statistics(){
  local src="$1" out="$2"
  [[ -b "$src" ]] || { error "Устройство не найдено: $src"; return 1; }
  
  # Проверка доступа к устройству
  if ! dd if="$src" bs=1 count=1 of=/dev/null 2>/dev/null; then
    error "Нет доступа для чтения: $src"
    return 1
  fi

  local ssize=$(get_device_size "$src")
  if [[ $ssize -eq 0 ]]; then
    error "Не удалось получить размер: $src"
    return 1
  fi

  local start=$(date +%s)
  
  # Используем улучшенную функцию dd с прогрессом
  dd_with_progress "$src" "$out" "$ssize"
  local rc=$?

  local end=$(date +%s)
  local dur=$((end-start))

  # Проверяем результат
  if [[ $rc -eq 0 && -f "$out" ]]; then
    local filesize=$(stat -c%s "$out" 2>/dev/null || echo 0)
    echo "${ssize}|${filesize}|${dur}"
    return 0
  else
    error "Ошибка бэкапа"
    [[ -f "$out" ]] && rm -f "$out"
    return 1
  fi
}

perform_backup(){
  clear
  echo -e "${CYAN}== Резервное копирование ==${NC}\n"
  if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
    error "Цели не выбраны"
    read -r -p "Нажмите Enter..."
    return 1
  fi
  if [[ -z "$BACKUP_LOCATION" ]]; then
    error "Место назначения не настроено"
    read -r -p "Нажмите Enter..."
    return 1
  fi
  if [[ ! -d "$BACKUP_LOCATION" || ! -w "$BACKUP_LOCATION" ]]; then
    error "Нет доступа для записи в $BACKUP_LOCATION"
    read -r -p "Нажмите Enter..."
    return 1
  fi
  info "Цели: ${SELECTED_DISKS[*]}"
  info "Место назначения: $BACKUP_LOCATION"
  info "Сжатие: $($COMPRESSION_ENABLED && echo включено || echo отключено)"
  info "Метод прогресса: $PROGRESS_METHOD"
  echo
  read -r -p "Продолжить? (y/N): " a
  [[ "$a" =~ ^[Yy]$ ]] || { warning "Отменено"; read -r -p "Нажмите Enter..."; return 1; }
  
  local session=$(make_backup_session_dir) || { read -r -p "Нажмите Enter..."; return 1; }
  create_backup_metadata "$session"
  local ok=0 total=${#SELECTED_DISKS[@]}
  local total_orig=0 total_comp=0
  
  for src in "${SELECTED_DISKS[@]}"; do
    [[ -b "$src" ]] || { error "Устройство не найдено: $src"; continue; }
    local base=$(basename "$src")
    local ttype="disk"
    [[ "$src" =~ [0-9]+$ ]] && ttype="part"
    local out="$session/${base}_${ttype}.img"
    $COMPRESSION_ENABLED && out="${out}.gz"
    
    echo -e "\n${BOLD}${BLUE}[$((ok+1))/$total]${NC} ${BOLD}$src -> $out${NC}"
    
    local backup_stats
    backup_stats=$(backup_disk_with_statistics "$src" "$out")
    local rc=$?
    
    if [[ $rc -eq 0 && -n "$backup_stats" ]]; then
      local orig comp dur
      IFS='|' read -r orig comp dur <<< "$backup_stats"
      add_backup_entry "$session" "$src" "$(basename "$out")" "$orig" "$comp" "$dur"
      total_orig=$((total_orig + orig))
      total_comp=$((total_comp + comp))
      ((ok++))
      echo -e "\n${GREEN}✓${NC} Готово за $(format_time "$dur")"
      echo -e "  Исходный размер: $(format_size "$orig"), Архив: $(format_size "$comp")"
    else
      echo -e "\n${RED}✗${NC} Ошибка при копировании $src"
    fi
  done
  
  echo; echo -e "${CYAN}== Итоги ==${NC}"
  [[ $ok -eq $total ]] && success "Все выполнено успешно ($ok/$total)" || warning "Выполнено успешно: $ok из $total"
  if [[ $total_orig -gt 0 ]]; then
    echo -e "${YELLOW}Исходный общий размер:${NC} $(format_size "$total_orig")"
    echo -e "${YELLOW}Общий архивный размер:${NC} $(format_size "$total_comp")"
    if [[ $total_comp -gt 0 ]]; then
      local ratio=$((100 * total_comp / total_orig))
      echo -e "${YELLOW}Коэффициент сжатия:${NC} $ratio%"
    fi
    echo -e "${BLUE}Папка сессии:${NC} $session"
  fi
  read -r -p "Нажмите Enter..."
}

configure_progress_method(){
  while true; do
    clear
    echo -e "${CYAN}== Настройка отображения прогресса ==${NC}\n"
    echo "Доступные методы:"
    echo "1) dd status=progress (встроенный в dd) ${PROGRESS_METHOD:+$([ "$PROGRESS_METHOD" = "dd_progress" ] && echo "← текущий")}"
    echo "2) pv (Pipe Viewer) $($HAS_PV && echo "✓ доступен" || echo "✗ не установлен") ${PROGRESS_METHOD:+$([ "$PROGRESS_METHOD" = "pv" ] && echo "← текущий")}"
    echo "3) dcfldd (расширенный dd) $($HAS_DCFLDD && echo "✓ доступен" || echo "✗ не установлен") ${PROGRESS_METHOD:+$([ "$PROGRESS_METHOD" = "dcfldd" ] && echo "← текущий")}"
    echo "4) Собственный прогресс-бар ${PROGRESS_METHOD:+$([ "$PROGRESS_METHOD" = "builtin" ] && echo "← текущий")}"
    echo "5) Автовыбор лучшего метода ${PROGRESS_METHOD:+$([ "$PROGRESS_METHOD" = "auto" ] && echo "← текущий")}"
    echo "6) Назад"
    echo
    info "Текущий метод: $PROGRESS_METHOD"
    
    read -r -p "Выбор: " choice
    case "$choice" in
      1) PROGRESS_METHOD="dd_progress"; save_config; success "Выбран dd status=progress"; sleep 1 ;;
      2) 
        if $HAS_PV; then
          PROGRESS_METHOD="pv"; save_config; success "Выбран pv"; sleep 1
        else
          error "pv не установлен"
          read -r -p "Установить из исходников? (y/N): " install_choice
          if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            if install_pv_from_source; then
              PROGRESS_METHOD="pv"; save_config; success "pv установлен и выбран"
            fi
          fi
          read -r -p "Нажмите Enter..."
        fi
        ;;
      3)
        if $HAS_DCFLDD; then
          PROGRESS_METHOD="dcfldd"; save_config; success "Выбран dcfldd"; sleep 1
        else
          error "dcfldd не установлен"
          read -r -p "Установить из исходников? (y/N): " install_choice
          if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            if install_dcfldd_from_source; then
              PROGRESS_METHOD="dcfldd"; save_config; success "dcfldd установлен и выбран"
            fi
          fi
          read -r -p "Нажмите Enter..."
        fi
        ;;
      4) PROGRESS_METHOD="builtin"; save_config; success "Выбран собственный прогресс-бар"; sleep 1 ;;
      5) PROGRESS_METHOD="auto"; save_config; success "Выбран автоматический режим"; sleep 1 ;;
      6) return ;;
      *) warning "Неверный выбор"; sleep 1 ;;
    esac
  done
}

analyze_backup_requirements(){
  clear
  echo -e "${CYAN}== Оценка места для бэкапа ==${NC}\n"
  if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
    warning "Цели для бэкапа не выбраны, выберите в меню пункт 2"
  else
    local total=0 t
    echo "Выбранные устройства:"
    for t in "${SELECTED_DISKS[@]}"; do
      local sz=$(get_device_size "$t")
      if [[ $sz -eq 0 ]]; then warning "Устройство $t недоступно"; continue; fi
      total=$((total+sz))
      printf "  %-16s %s\n" "$t" "$(format_size "$sz")"
    done
    if [[ $total -gt 0 ]]; then
      local est=$total
      $COMPRESSION_ENABLED && est=$((total*30/100))
      echo
      echo -e "${YELLOW}Общий размер данных:${NC} $(format_size "$total")"
      echo -e "${YELLOW}Оценка после сжатия:${NC} $(format_size "$est") (ориентировочно)"
      echo -e "${YELLOW}Плюс 10% запас:${NC} $(format_size $((est + est/10)))"
      warning "Фактическое сжатие может быть лучше для пустых устройств"
    else
      warning "Не удалось определить размеры устройств"
    fi
  fi
  echo
  if [[ -n "$BACKUP_LOCATION" && -d "$BACKUP_LOCATION" ]]; then
    local avail=$(df --output=avail -B1 "$BACKUP_LOCATION" 2>/dev/null | tail -n1)
    if [[ "$avail" =~ ^[0-9]+$ ]]; then
      echo -e "${YELLOW}Доступно на диске:${NC} $(format_size "$avail")"
      echo -e "${YELLOW}Путь назначения:${NC} $BACKUP_LOCATION"
    else
      warning "Папка назначения недоступна или не смонтирована"
    fi
  else
    warning "Назначение для бэкапа не настроено"
  fi
  read -r -p "Нажмите Enter..."
}

check_free_space(){
  local path="$1" need="$2"
  [[ ! -d "$path" ]] && { error "Папка не найдена: $path"; return 1; }
  local avail=$(df --output=avail -B1 "$path" 2>/dev/null | tail -n1)
  [[ "$avail" =~ ^[0-9]+$ ]] || { warning "Не удалось определить свободное место"; return 1; }
  info "Свободно: $(format_size "$avail"), требуется: $(format_size "$need")"
  [[ $avail -lt $need ]] && { error "Недостаточно свободного места"; return 1; }
  return 0
}

cleanup_mounts(){
  if $NETWORK_MOUNTED && [[ -d "$MOUNT_POINT" ]]; then
    umount "$MOUNT_POINT" 2>/dev/null || fusermount -u "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    NETWORK_MOUNTED=false
    info "Сетевой ресурс размонтирован"
  fi
  cleanup_build_environment
}

# ВАЖНО: Добавляем НЕДОСТАЮЩИЕ ФУНКЦИИ для работы пункта 3

mount_smb_share(){
  local server="$1" share="$2" user="$3" password="$4" domain="$5"
  mkdir -p "$MOUNT_POINT"
  local cred="/tmp/smb_cred_$$"
  {
    echo "username=$user"
    echo "password=$password"
    [[ -n "$domain" ]] && echo "domain=$domain"
  } > "$cred"
  chmod 600 "$cred"
  local versions=("3.0" "2.1" "2.0" "1.0") v
  for v in "${versions[@]}"; do
    mount -t cifs "//$server/$share" "$MOUNT_POINT" -o "credentials=$cred,vers=$v,uid=0,gid=0,file_mode=0644,dir_mode=0755" 2>/dev/null && break
  done
  rm -f "$cred"
  if ! mountpoint -q "$MOUNT_POINT"; then
    error "Не удалось смонтировать SMB"
    rmdir "$MOUNT_POINT" 2>/dev/null
    return 1
  fi
  if ! touch "$MOUNT_POINT/.rwtest_$$" 2>/dev/null; then
    error "Нет прав записи на SMB"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    return 1
  fi
  rm -f "$MOUNT_POINT/.rwtest_$$"
  success "SMB смонтирован: $MOUNT_POINT"
  NETWORK_MOUNTED=true
  BACKUP_LOCATION="$MOUNT_POINT"
  return 0
}

mount_sshfs_share(){
  local user="$1" host="$2" path="$3" port="${4:-22}" key="$5"
  mkdir -p "$MOUNT_POINT"
  local opts="allow_other,default_permissions,reconnect,ServerAliveInterval=15,StrictHostKeyChecking=no"
  [[ -n "$key" && -f "$key" ]] && opts="$opts,IdentityFile=$key"
  if ! sshfs -p "$port" -o "$opts" "$user@$host:$path" "$MOUNT_POINT" 2>/dev/null; then
    error "Не удалось смонтировать SSHFS"
    rmdir "$MOUNT_POINT" 2>/dev/null
    return 1
  fi
  if ! mountpoint -q "$MOUNT_POINT"; then
    error "SSHFS точка монтирования не найдена"
    rmdir "$MOUNT_POINT" 2>/dev/null
    return 1
  fi
  if ! touch "$MOUNT_POINT/.rwtest_$$" 2>/dev/null; then
    error "Нет прав записи на SSHFS"
    fusermount -u "$MOUNT_POINT" || umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    return 1
  fi
  rm -f "$MOUNT_POINT/.rwtest_$$"
  success "SSHFS смонтирован: $MOUNT_POINT"
  NETWORK_MOUNTED=true
  BACKUP_LOCATION="$MOUNT_POINT"
  return 0
}

list_connection_profiles(){
  mkdir -p "$PROFILES_DIR" 2>/dev/null
  find "$PROFILES_DIR" -name "*.profile" -exec basename {} .profile \; 2>/dev/null | sort
}

load_connection_profile(){
  local name="$1"
  local profile_file="$PROFILES_DIR/$name.profile"
  [[ -f "$profile_file" ]] || return 1
  . "$profile_file" 2>/dev/null || return 1
}

get_profile_description(){
  local name="$1"
  load_connection_profile "$name" || return 1
  case "$PROFILE_TYPE" in
    SMB) echo "SMB: $SMB_SERVER/$SMB_SHARE (пользователь: $SMB_USER)" ;;
    SSHFS) echo "SSHFS: $SSHFS_USER@$SSHFS_HOST:$SSHFS_PATH" ;;
    *) echo "Неизвестный тип профиля" ;;
  esac
}

save_connection_profile(){
  local name="$1" type="$2"
  mkdir -p "$PROFILES_DIR" 2>/dev/null
  local profile_file="$PROFILES_DIR/$name.profile"
  {
    echo "# Профиль подключения: $name"
    echo "# Создан: $(date)"
    echo "# Тип: $type"
    printf 'PROFILE_TYPE=%q\n' "$type"
    case "$type" in
      SMB)
        printf 'SMB_SERVER=%q\n' "$SMB_SERVER"
        printf 'SMB_SHARE=%q\n' "$SMB_SHARE"
        printf 'SMB_USER=%q\n' "$SMB_USER"
        printf 'SMB_PASSWORD=%q\n' "$SMB_PASSWORD"
        printf 'SMB_DOMAIN=%q\n' "$SMB_DOMAIN"
        ;;
      SSHFS)
        printf 'SSHFS_HOST=%q\n' "$SSHFS_HOST"
        printf 'SSHFS_USER=%q\n' "$SSHFS_USER"
        printf 'SSHFS_PATH=%q\n' "$SSHFS_PATH"
        printf 'SSHFS_PORT=%q\n' "$SSHFS_PORT"
        printf 'SSHFS_KEY=%q\n' "$SSHFS_KEY"
        ;;
    esac
  } > "$profile_file"
  chmod 600 "$profile_file"
  success "Профиль '$name' сохранён"
}

manage_connection_profiles(){
  while true; do
    clear
    echo -e "${CYAN}== Управление профилями подключения ==${NC}\n"
    local profiles
    mapfile -t profiles < <(list_connection_profiles)
    if [[ ${#profiles[@]} -eq 0 ]]; then
      echo "Профили отсутствуют."
    else
      local i=1
      for p in "${profiles[@]}"; do
        echo "$i) $p - $(get_profile_description "$p")"
        ((i++))
      done
    fi
    echo
    echo "a) Добавить профиль"
    echo "d) Удалить профиль"
    echo "b) Назад"
    read -r -p "Выберите действие: " action
    case "$action" in
      a)
        echo "Типы подключений:"
        echo "1) SMB"
        echo "2) SSHFS"
        read -r -p "Введите номер: " t
        case "$t" in
          1)
            local server share user pass domain
            read -r -p "Сервер: " server
            read -r -p "Шара: " share
            read -r -p "Пользователь: " user
            read -r -s -p "Пароль: " pass; echo
            read -r -p "Домен (опционально): " domain
            read -r -p "Имя профиля: " name
            SMB_SERVER="$server"
            SMB_SHARE="$share"
            SMB_USER="$user"
            SMB_PASSWORD="$pass"
            SMB_DOMAIN="$domain"
            save_connection_profile "$name" "SMB"
            read -r -p "Готово. Нажмите Enter..."
            ;;
          2)
            local user host path port key
            read -r -p "Пользователь: " user
            read -r -p "Хост: " host
            read -r -p "Путь: " path
            read -r -p "Порт (по умолчанию 22): " port
            port=${port:-22}
            read -r -p "Путь к ключу (опционально): " key
            read -r -p "Имя профиля: " name
            SSHFS_HOST="$host"
            SSHFS_USER="$user"
            SSHFS_PATH="$path"
            SSHFS_PORT="$port"
            SSHFS_KEY="$key"
            save_connection_profile "$name" "SSHFS"
            read -r -p "Готово. Нажмите Enter..."
            ;;
          *)
            warning "Неверный выбор"
            read -r -p "Нажмите Enter..."
            ;;
        esac
        ;;
      d)
        read -r -p "Номер профиля для удаления: " num
        if [[ "$num" =~ ^[0-9]+$ && $num -ge 1 && $num -le ${#profiles[@]} ]]; then
          rm -f "$PROFILES_DIR/${profiles[$((num-1))]}.profile"
          echo "Профиль удалён."
        else
          echo "Неверный номер."
        fi
        read -r -p "Нажмите Enter..."
        ;;
      b)
        return
        ;;
      *)
        warning "Неверный выбор"
        read -r -p "Нажмите Enter..."
        ;;
    esac
  done
}

# ГЛАВНАЯ ФУНКЦИЯ которая была пропущена!
configure_backup_destination(){
  while true; do
    clear
    echo -e "${CYAN}== Настройка места назначения ==${NC}\n"
    local need=$(calculate_required_space)
    info "Ориентировочно требуется: $(format_size "$need")"
    [[ ${#SELECTED_DISKS[@]} -gt 0 ]] && info "Выбрано устройств: ${#SELECTED_DISKS[@]}"
    echo
    echo "1) Локальная папка"
    echo "2) Подключиться к SMB/CIFS"
    echo "3) Подключиться к SSH/SSHFS"
    echo "4) Использовать профиль подключения"
    echo "5) Управление профилями подключения"
    echo "6) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1)
        cleanup_mounts
        local path
        read -r -p "Введите абсолютный путь к папке: " path
        if [[ ! "$path" =~ ^/ ]]; then
          error "Введите абсолютный путь"
          read -r -p "Нажмите Enter..."
          continue
        fi
        [[ -d "$path" ]] || mkdir -p "$path" || { error "Не удалось создать папку"; read -r -p "Нажмите Enter..."; continue; }
        [[ -w "$path" ]] || { error "Нет прав на запись"; read -r -p "Нажмите Enter..."; continue; }
        if ! check_local_path_conflicts "$path"; then read -r -p "Нажмите Enter..."; continue; fi
        if ! check_free_space "$path" "$need"; then
          read -r -p "Мало места, продолжить? (y/N): " yn
          [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        BACKUP_LOCATION="$path"
        NETWORK_MOUNTED=false
        success "Назначение установлено: $BACKUP_LOCATION"
        save_config
        read -r -p "Нажмите Enter..."
        ;;
      2)
        cleanup_mounts
        local server share user pass domain
        read -r -p "Сервер: " server
        read -r -p "Шара: " share
        read -r -p "Пользователь: " user
        read -r -s -p "Пароль: " pass; echo
        read -r -p "Домен (опционально): " domain
        if mount_smb_share "$server" "$share" "$user" "$pass" "$domain"; then
          save_config
          success "SMB смонтирован: $BACKUP_LOCATION"
        else
          NETWORK_MOUNTED=false
        fi
        read -r -p "Нажмите Enter..."
        ;;
      3)
        cleanup_mounts
        local user host path port key
        read -r -p "Пользователь: " user
        read -r -p "Хост: " host
        read -r -p "Путь: " path
        read -r -p "Порт (по умолчанию 22): " port
        port=${port:-22}
        read -r -p "Путь к ключу (опционально): " key
        if mount_sshfs_share "$user" "$host" "$path" "$port" "$key"; then
          save_config
          success "SSHFS смонтирован: $BACKUP_LOCATION"
        else
          NETWORK_MOUNTED=false
        fi
        read -r -p "Нажмите Enter..."
        ;;
      4)
        local profiles
        mapfile -t profiles < <(list_connection_profiles)
        if [[ ${#profiles[@]} -eq 0 ]]; then
          warning "Профили отсутствуют"
          read -r -p "Нажмите Enter..."
          continue
        fi
        echo "Доступные профили:"
        local i=1
        for p in "${profiles[@]}"; do
          echo "$i) $p - $(get_profile_description "$p")"
          ((i++))
        done
        read -r -p "Выберите номер профиля: " sel
        if [[ "$sel" =~ ^[0-9]+$ && $sel -ge 1 && $sel -le ${#profiles[@]} ]]; then
          load_connection_profile "${profiles[$((sel-1))]}" || {
            error "Не удалось загрузить профиль"
            read -r -p "Нажмите Enter..."
            continue
          }
          case "$PROFILE_TYPE" in
            SMB)
              cleanup_mounts
              if mount_smb_share "$SMB_SERVER" "$SMB_SHARE" "$SMB_USER" "$SMB_PASSWORD" "$SMB_DOMAIN"; then
                save_config
                success "Подключено по профилю SMB: $BACKUP_LOCATION"
              else
                NETWORK_MOUNTED=false
              fi
              ;;
            SSHFS)
              cleanup_mounts
              if mount_sshfs_share "$SSHFS_USER" "$SSHFS_HOST" "$SSHFS_PATH" "$SSHFS_PORT" "$SSHFS_KEY"; then
                save_config
                success "Подключено по профилю SSHFS: $BACKUP_LOCATION"
              else
                NETWORK_MOUNTED=false
              fi
              ;;
            *)
              error "Неизвестный тип профиля"
              ;;
          esac
        else
          warning "Неверный выбор"
        fi
        read -r -p "Нажмите Enter..."
        ;;
      5)
        manage_connection_profiles
        ;;
      6)
        return
        ;;
      *)
        warning "Неверный выбор"
        read -r -p "Нажмите Enter..."
        ;;
    esac
  done
}

toggle_compression(){
  COMPRESSION_ENABLED=$($COMPRESSION_ENABLED && echo false || echo true)
  success "Сжатие теперь: $($COMPRESSION_ENABLED && echo включено || echo отключено)"
  save_config
  read -r -p "Нажмите Enter..."
}

install_utilities_menu(){
  while true; do
    clear
    echo -e "${CYAN}== Установка утилит для прогресса ==${NC}\n"
    echo "Доступные для автоматической установки:"
    echo
    echo "1) pv (Pipe Viewer) - визуальный индикатор прогресса"
    echo "   Статус: $($HAS_PV && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${RED}✗ не установлен${NC}")"
    echo "   Источник: $PV_URL"
    echo
    echo "2) dcfldd - расширенная версия dd с прогресс-баром"
    echo "   Статус: $($HAS_DCFLDD && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${RED}✗ не установлен${NC}")"
    echo "   Источник: $DCFLDD_URL"
    echo
    echo "3) progress - утилита для мониторинга прогресса процессов"
    echo "   Статус: $($HAS_PROGRESS && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${RED}✗ не установлен${NC}")"
    echo "   Источник: $PROGRESS_URL"
    echo
    echo "4) Установить все отсутствующие утилиты"
    echo "5) Проверить зависимости для сборки"
    echo "6) Назад"
    echo
    info "Установка происходит из исходного кода GitHub/официальных сайтов"
    warning "Требуются права root и инструменты сборки (gcc, make, etc.)"
    
    read -r -p "Выбор: " choice
    case "$choice" in
      1)
        if $HAS_PV; then
          info "pv уже установлен"
        else
          install_pv_from_source && check_progress_tools
        fi
        read -r -p "Нажмите Enter..."
        ;;
      2)
        if $HAS_DCFLDD; then
          info "dcfldd уже установлен"
        else
          install_dcfldd_from_source && check_progress_tools
        fi
        read -r -p "Нажмите Enter..."
        ;;
      3)
        if $HAS_PROGRESS; then
          info "progress уже установлен"
        else
          install_progress_from_source && check_progress_tools
        fi
        read -r -p "Нажмите Enter..."
        ;;
      4)
        local installed=0
        if ! $HAS_PV; then
          info "Устанавливаем pv..."
          install_pv_from_source && ((installed++))
        fi
        if ! $HAS_DCFLDD; then
          info "Устанавливаем dcfldd..."
          install_dcfldd_from_source && ((installed++))
        fi
        if ! $HAS_PROGRESS; then
          info "Устанавливаем progress..."
          install_progress_from_source && ((installed++))
        fi
        check_progress_tools
        success "Установлено утилит: $installed"
        read -r -p "Нажмите Enter..."
        ;;
      5)
        check_build_dependencies && success "Все зависимости для сборки присутствуют"
        read -r -p "Нажмите Enter..."
        ;;
      6)
        return
        ;;
      *)
        warning "Неверный выбор"
        sleep 1
        ;;
    esac
  done
}

show_main_menu(){
  clear
  echo -e "${CYAN}╔═════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Disk Backup Manager v7.01            ║${NC}"
  echo -e "${CYAN}║   ПОЛНАЯ ИСПРАВЛЕННАЯ ВЕРСИЯ            ║${NC}"
  echo -e "${CYAN}╚═════════════════════════════════════════╝${NC}\n"
  echo "1) Показать диски и разделы"
  echo "2) Выбрать цели для бэкапа"
  echo "3) Настроить место назначения"
  echo "4) Оценить размер и место"
  echo "5) Резервное копирование"
  echo "6) Восстановить (заглушка)"
  echo "7) Вкл/выкл сжатие"
  echo "8) Настройка прогресса"
  echo "9) Установка утилит"
  echo "0) Выход"
  echo
}

restore_menu(){
  clear
  echo -e "${CYAN}== Восстановление ==${NC}\n"
  echo "Опция восстановления реализована пока частично."
  read -r -p "Нажмите Enter..."
}

main(){
  trap 'cleanup_mounts' EXIT
  check_root
  check_core_dependencies
  check_progress_tools
  check_network_tools
  load_config
  success "Система готова. Версия 7.01 - ПОЛНАЯ ИСПРАВЛЕННАЯ ВЕРСИЯ"
  sleep 1
  while true; do
    show_main_menu
    local c
    read -r -p "Выбор: " c
    case "$c" in
      1) show_detailed_disk_info ;;
      2) select_backup_targets ;;
      3) configure_backup_destination ;;
      4) analyze_backup_requirements ;;
      5) perform_backup ;;
      6) restore_menu ;;
      7) toggle_compression ;;
      8) configure_progress_method ;;
      9) install_utilities_menu ;;
      0) log "Выход"; exit 0 ;;
      *) warning "Неверный выбор"; sleep 1 ;;
    esac
  done
}

main "$@"