#!/bin/bash
# =====================================================================
# Disk/Partition Backup Manager v6.7 (Astra/Linux)
# =====================================================================

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log(){ echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1" >&2; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warning(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
info(){ echo -e "${CYAN}[INFO]${NC} $1"; }

CONFIG_FILE="$HOME/.backup_manager_config"
NET_CONFIG_DIR="$HOME/.backup_manager_destinations"
BACKUP_LOCATION=""
COMPRESSION_ENABLED=true
PROGRESS_METHOD="builtin"
NETWORK_MOUNTED=false
MOUNT_POINT="/tmp/backup_mount_$$"
SELECTED_DISKS=()

# Массивы для множественных назначений
declare -A DEVICE_DESTINATIONS  # Массив: устройство -> назначение
declare -A MOUNTED_POINTS       # Массив: имя_конфига -> точка_монтирования

HAS_PV=false; HAS_DCFLDD=false; HAS_PROGRESS=false
HAS_CIFS_UTILS=false; HAS_SSHFS=false

check_root(){ [[ $EUID -ne 0 ]] && { error "Run as root"; exit 1; }; }

save_config(){
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
  {
    echo "# config v6.7 $(date)"
    echo "COMPRESSION_ENABLED=$COMPRESSION_ENABLED"
    if [[ -n "$BACKUP_LOCATION" && $NETWORK_MOUNTED = false ]]; then
      printf 'BACKUP_LOCATION=%q\n' "$BACKUP_LOCATION"
    else
      echo 'BACKUP_LOCATION=""'
    fi
    echo -n "SELECTED_DISKS=("
    local i
    for i in "${SELECTED_DISKS[@]}"; do printf "%q " "$i"; done
    echo ")"
    
    # Сохраняем назначения для устройств
    echo "# Device destinations"
    for dev in "${!DEVICE_DESTINATIONS[@]}"; do
      printf 'DEVICE_DESTINATIONS[%q]=%q\n' "$dev" "${DEVICE_DESTINATIONS[$dev]}"
    done
  } > "$CONFIG_FILE" && success "Saved: $CONFIG_FILE" || error "Cannot save config"
}

load_config(){
  [[ -f "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_FILE" 2>/dev/null || return 0
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  local v=() t
  for t in "${SELECTED_DISKS[@]}"; do 
    [[ -b "$t" ]] && v+=("$t") || warning "Missing device from config: $t"
  done
  SELECTED_DISKS=("${v[@]}")
  [[ -n "$BACKUP_LOCATION" && ! -d "$BACKUP_LOCATION" ]] && { 
    warning "Dest not available: $BACKUP_LOCATION"
    BACKUP_LOCATION=""
  }
}

# Функции для работы с множественными сетевыми конфигурациями
save_network_destination(){
  local name="$1" type="$2"
  mkdir -p "$NET_CONFIG_DIR" 2>/dev/null
  local config_file="$NET_CONFIG_DIR/$name.conf"
  
  {
    echo "# Network destination: $name"
    echo "# Created: $(date)"
    printf 'NET_TYPE=%q\n' "$type"
    case "$type" in
      SMB)
        printf 'NET_SERVER=%q\n' "$NET_SERVER"
        printf 'NET_SHARE=%q\n' "$NET_SHARE"
        printf 'NET_USER=%q\n' "$NET_USER"
        printf 'NET_PASSWORD=%q\n' "$NET_PASSWORD"
        printf 'NET_DOMAIN=%q\n' "$NET_DOMAIN"
        ;;
      SSHFS)
        printf 'NET_SSH_HOST=%q\n' "$NET_SSH_HOST"
        printf 'NET_SSH_USER=%q\n' "$NET_SSH_USER"
        printf 'NET_SSH_PATH=%q\n' "$NET_SSH_PATH"
        printf 'NET_SSH_PORT=%q\n' "$NET_SSH_PORT"
        printf 'NET_SSH_KEY=%q\n' "$NET_SSH_KEY"
        ;;
    esac
  } > "$config_file"
  chmod 600 "$config_file"
}

load_network_destination(){
  local name="$1"
  local config_file="$NET_CONFIG_DIR/$name.conf"
  [[ -f "$config_file" ]] || return 1
  # shellcheck disable=SC1090
  . "$config_file" 2>/dev/null || return 1
}

list_network_destinations(){
  mkdir -p "$NET_CONFIG_DIR" 2>/dev/null
  find "$NET_CONFIG_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

get_destination_description(){
  local name="$1"
  load_network_destination "$name" || return 1
  case "$NET_TYPE" in
    SMB) echo "SMB: $NET_SERVER/$NET_SHARE" ;;
    SSHFS) echo "SSHFS: $NET_SSH_USER@$NET_SSH_HOST:$NET_SSH_PATH" ;;
    *) echo "Unknown" ;;
  esac
}

# Остальные helper-функции без изменений...
get_device_size(){ local dev="$1"; blockdev --getsize64 "$dev" 2>/dev/null || echo 0; }

format_size(){
  local b="$1"
  if command -v numfmt >/dev/null 2>&1; then 
    numfmt --to=iec "$b"
  else
    local u=(B K M G T) i=0
    while [[ $b -ge 1024 && $i -lt 4 ]]; do 
      b=$((b/1024))
      ((i++))
    done
    echo "${b}${u[$i]}"
  fi
}

format_time(){
  local s="$1"
  local h=$((s/3600)) m=$(((s%3600)/60)) ss=$((s%60))
  if [[ $h -gt 0 ]]; then 
    printf "%02d:%02d:%02d" "$h" "$m" "$ss"
  elif [[ $m -gt 0 ]]; then 
    printf "%02d:%02d" "$m" "$ss"
  else 
    printf "%ds" "$ss"
  fi
}

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

get_disk_partitions_simple(){
  local disk="$1"
  lsblk -pln -o NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}'
}

# Функции проверки зависимостей (без изменений)
check_core_dependencies(){
  local need=(lsblk dd mount umount gzip gunzip df stat blockdev awk sed grep tr)
  local miss=() d
  for d in "${need[@]}"; do 
    command -v "$d" >/dev/null 2>&1 || miss+=("$d")
  done
  [[ ${#miss[@]} -gt 0 ]] && { error "Install: ${miss[*]}"; exit 1; }
}

check_progress_tools(){
  command -v pv >/dev/null 2>&1 && HAS_PV=true
  command -v dcfldd >/dev/null 2>&1 && HAS_DCFLDD=true
  command -v progress >/dev/null 2>&1 && HAS_PROGRESS=true
  if $HAS_PV; then PROGRESS_METHOD="pv"
  elif $HAS_DCFLDD; then PROGRESS_METHOD="dcfldd"
  else PROGRESS_METHOD="builtin"; fi
  info "Progress method: $PROGRESS_METHOD"
}

check_network_tools(){
  command -v mount.cifs >/dev/null 2>&1 && HAS_CIFS_UTILS=true
  command -v sshfs >/dev/null 2>&1 && HAS_SSHFS=true
}

show_detailed_disk_info(){
  clear
  echo -e "${CYAN}== Диски и разделы ==${NC}\n"
  
  while IFS= read -r dev; do
    [[ -b "$dev" ]] || continue
    local size model
    size=$(format_size "$(get_device_size "$dev")")
    model=$(lsblk -pdn -o MODEL "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo -e "${YELLOW}$dev ($size) ${model:+- $model}${NC}"
    
    local partitions
    partitions=$(get_disk_partitions_simple "$dev")
    
    if [[ -n "$partitions" ]]; then
      printf "  %-16s %-8s %-10s %-12s %-20s %-8s\n" \
        "УСТРОЙСТВО" "РАЗМЕР" "ФС" "МЕТКА" "МОНТ." "СИСТ."
      
      while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        local details psize pfs plabel pmount sys
        details=$(get_partition_details "$part")
        IFS='|' read -r psize pfs plabel pmount <<< "$details"
        sys="no"
        [[ "$pmount" != "-" ]] && sys="yes"
        printf "  %-16s %-8s %-10s %-12s %-20s %-8s\n" \
          "$part" "$psize" "$pfs" "$plabel" "$pmount" "$sys"
      done <<< "$partitions"
    else
      echo "  (нет разделов)"
    fi
    echo
  done < <(list_disks_raw)
  read -r -p "Enter..."
}

select_backup_targets(){
  clear
  echo -e "${CYAN}== Выбор дисков/разделов ==${NC}\n"
  
  local disks=() infos=()
  while IFS= read -r dev; do
    [[ -b "$dev" ]] || continue
    local size model
    size=$(format_size "$(get_device_size "$dev")")
    model=$(lsblk -pdn -o MODEL "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    disks+=("$dev")
    infos+=("$size - ${model:-Unknown}")
  done < <(list_disks_raw)
  
  [[ ${#disks[@]} -eq 0 ]] && { 
    error "Нет дисков"
    read -r -p "Enter..."
    return 1
  }

  echo "Режим:"
  echo "1) Диски целиком"
  echo "2) Только разделы"
  echo "3) Смешанный (диски+разделы)"
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
          [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#disks[@]} ]] && \
            SELECTED_DISKS+=("${disks[$((n-1))]}") || warning "skip $n"
        done
      fi
      ;;
    2)
      local parts=() pinfos=()
      while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        local details psize pfs plabel pmount
        details=$(get_partition_details "$part")
        IFS='|' read -r psize pfs plabel pmount <<< "$details"
        
        local info="$psize"
        [[ "$pfs" != "-" ]] && info="$info [$pfs]"
        [[ "$plabel" != "-" ]] && info="$info \"$plabel\""
        [[ "$pmount" != "-" ]] && info="$info -> $pmount"
        
        parts+=("$part")
        pinfos+=("$info")
      done < <(find_all_partitions)
      
      if [[ ${#parts[@]} -eq 0 ]]; then
        error "Нет доступных разделов"
        read -r -p "Enter..."
        return 1
      fi
      
      local i
      for i in "${!parts[@]}"; do
        printf "%2d) %-16s %s\n" $((i+1)) "${parts[i]}" "${pinfos[i]}"
      done
      local in
      read -r -p "Введите номера: " in
      for n in $in; do
        [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#parts[@]} ]] && \
          SELECTED_DISKS+=("${parts[$((n-1))]}") || warning "skip $n"
      done
      ;;
    3)
      local all=() ainfo=() i
      for i in "${!disks[@]}"; do
        all+=("${disks[i]}")
        ainfo+=("ДИСК: ${infos[i]}")
      done
      while IFS= read -r part; do
        [[ -b "$part" ]] || continue
        local details psize pfs plabel pmount
        details=$(get_partition_details "$part")
        IFS='|' read -r psize pfs plabel pmount <<< "$details"
        
        local info="РАЗДЕЛ: $psize"
        [[ "$pfs" != "-" ]] && info="$info [$pfs]"
        [[ "$plabel" != "-" ]] && info="$info \"$plabel\""
        [[ "$pmount" != "-" ]] && info="$info -> $pmount"
        
        all+=("$part")
        ainfo+=("$info")
      done < <(find_all_partitions)
      
      local i
      for i in "${!all[@]}"; do
        printf "%2d) %-16s %s\n" $((i+1)) "${all[i]}" "${ainfo[i]}"
      done
      local in
      read -r -p "Введите номера: " in
      for n in $in; do
        [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#all[@]} ]] && \
          SELECTED_DISKS+=("${all[$((n-1))]}") || warning "skip $n"
      done
      ;;
    *)
      warning "Неверный выбор"
      read -r -p "Enter..."
      return 1
      ;;
  esac

  [[ ${#SELECTED_DISKS[@]} -eq 0 ]] && { 
    error "Не выбрано"
    read -r -p "Enter..."
    return 1
  }
  save_config
  success "Выбрано: ${SELECTED_DISKS[*]}"
  read -r -p "Enter..."
}

# Обновленная функция конфигурации с поддержкой множественных назначений
configure_destinations_menu(){
  while true; do
    clear
    echo -e "${CYAN}== Настройка мест назначения ==${NC}\n"
    
    echo "1) Единое место назначения для всех устройств"
    echo "2) Индивидуальные места назначения"
    echo "3) Управление сохранёнными местами назначения"
    echo "4) Назад"
    
    local choice
    read -r -p "Выбор: " choice
    
    case "$choice" in
      1) configure_single_destination ;;
      2) configure_individual_destinations ;;
      3) manage_saved_destinations ;;
      4) return ;;
      *) warning "Неверный выбор" ;;
    esac
  done
}

configure_single_destination(){
  # Старая логика для единого назначения
  while true; do
    clear
    echo -e "${CYAN}== Единое назначение ==${NC}\n"
    local need
    need=$(calculate_required_space)
    info "Требуется ~ $(format_size "$need")"
    [[ ${#SELECTED_DISKS[@]} -gt 0 ]] && info "Цели: ${SELECTED_DISKS[*]}"
    
    echo
    echo "1) Локальная папка"
    echo "2) SMB/CIFS"  
    echo "3) SSH/SSHFS"
    echo "4) Назад"
    
    local c
    read -r -p "Выбор: " c
    case "$c" in
      1)
        local p
        read -r -p "Абсолютный путь: " p
        [[ "$p" =~ ^/ ]] || { error "Нужен абсолютный путь"; read -r -p "Enter..."; continue; }
        [[ -d "$p" ]] || { mkdir -p "$p" 2>/dev/null || { error "Не создать $p"; read -r -p "Enter..."; continue; }; }
        [[ -w "$p" ]] || { error "Нет прав записи: $p"; read -r -p "Enter..."; continue; }
        BACKUP_LOCATION="$p"
        # Очищаем индивидуальные назначения
        DEVICE_DESTINATIONS=()
        save_config
        success "Единое назначение: $BACKUP_LOCATION"
        read -r -p "Enter..."
        return
        ;;
      4) return ;;
      *) warning "Неверный выбор" ;;
    esac
  done
}

configure_individual_destinations(){
  [[ ${#SELECTED_DISKS[@]} -eq 0 ]] && { 
    error "Сначала выберите устройства в пункте 2"
    read -r -p "Enter..."
    return
  }
  
  clear
  echo -e "${CYAN}== Индивидуальные назначения ==${NC}\n"
  
  for dev in "${SELECTED_DISKS[@]}"; do
    echo -e "\n${YELLOW}Настройка для $dev:${NC}"
    
    # Показываем доступные места назначения
    local destinations=()
    destinations+=("LOCAL")
    
    while IFS= read -r name; do
      [[ -n "$name" ]] && destinations+=("$name")
    done < <(list_network_destinations)
    
    echo "Доступные назначения:"
    echo "1) Локальная папка"
    local i=2
    for dest in "${destinations[@]:1}"; do
      local desc
      desc=$(get_destination_description "$dest")
      printf "%d) %s (%s)\n" $i "$dest" "$desc"
      ((i++))
    done
    echo "$i) Создать новое место назначения"
    
    local choice
    read -r -p "Выбор для $dev: " choice
    
    if [[ $choice -eq 1 ]]; then
      # Локальная папка
      local path
      read -r -p "Путь для $dev: " path
      [[ "$path" =~ ^/ ]] && [[ -d "$path" || $(mkdir -p "$path" 2>/dev/null) ]] && {
        DEVICE_DESTINATIONS["$dev"]="LOCAL:$path"
        success "$dev -> $path"
      }
    elif [[ $choice -ge 2 && $choice -lt $i ]]; then
      # Существующее место назначения
      local dest_name="${destinations[$((choice-1))]}"
      DEVICE_DESTINATIONS["$dev"]="$dest_name"
      success "$dev -> $dest_name"
    elif [[ $choice -eq $i ]]; then
      # Создать новое место назначения
      create_new_destination "$dev"
    fi
  done
  
  save_config
  read -r -p "Enter..."
}

create_new_destination(){
  local device="$1"
  echo -e "\n${CYAN}Создание нового места назначения:${NC}"
  
  local name
  read -r -p "Имя конфигурации: " name
  [[ -z "$name" ]] && { warning "Пустое имя"; return; }
  
  echo "1) SMB/CIFS"
  echo "2) SSHFS"
  local type_choice
  read -r -p "Тип: " type_choice
  
  case "$type_choice" in
    1)
      read -r -p "Сервер: " NET_SERVER
      read -r -p "Шара: " NET_SHARE  
      read -r -p "Пользователь: " NET_USER
      read -r -s -p "Пароль: " NET_PASSWORD
      echo
      read -r -p "Домен (опц.): " NET_DOMAIN
      
      save_network_destination "$name" "SMB"
      DEVICE_DESTINATIONS["$device"]="$name"
      success "Создано: $name для $device"
      ;;
    2)
      read -r -p "SSH пользователь: " NET_SSH_USER
      read -r -p "Хост: " NET_SSH_HOST
      read -r -p "Путь: " NET_SSH_PATH
      read -r -p "Порт [22]: " NET_SSH_PORT
      NET_SSH_PORT=${NET_SSH_PORT:-22}
      read -r -p "SSH ключ (опц.): " NET_SSH_KEY
      
      save_network_destination "$name" "SSHFS"
      DEVICE_DESTINATIONS["$device"]="$name"
      success "Создано: $name для $device"
      ;;
  esac
}

manage_saved_destinations(){
  while true; do
    clear
    echo -e "${CYAN}== Управление местами назначения ==${NC}\n"
    
    local destinations
    mapfile -t destinations < <(list_network_destinations)
    
    if [[ ${#destinations[@]} -eq 0 ]]; then
      warning "Нет сохранённых мест назначения"
      read -r -p "Enter..."
      return
    fi
    
    local i=1
    for dest in "${destinations[@]}"; do
      local desc
      desc=$(get_destination_description "$dest")
      printf "%d) %s (%s)\n" $i "$dest" "$desc"
      ((i++))
    done
    
    echo "$i) Назад"
    
    local choice
    read -r -p "Выберите для удаления: " choice
    
    if [[ $choice -ge 1 && $choice -le ${#destinations[@]} ]]; then
      local dest_name="${destinations[$((choice-1))]}"
      read -r -p "Удалить $dest_name? (y/N): " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] && {
        rm -f "$NET_CONFIG_DIR/$dest_name.conf"
        success "Удалено: $dest_name"
      }
    elif [[ $choice -eq $i ]]; then
      return
    fi
  done
}

calculate_required_space(){ 
  local total=0
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  [[ ${#SELECTED_DISKS[@]} -eq 0 ]] && { 
    echo $((5*1024*1024*1024))
    return
  }
  local t s
  for t in "${SELECTED_DISKS[@]}"; do
    s=$(get_device_size "$t")
    [[ $s -eq 0 ]] && continue
    # Более консервативная оценка - 30% от размера
    [[ $COMPRESSION_ENABLED == true ]] && s=$((s*30/100))
    total=$((total+s))
  done
  echo $((total + total/10))
}

# Функции монтирования (без изменений, но адаптированные для работы с новой системой)
mount_destination(){
  local dest_spec="$1"
  
  if [[ "$dest_spec" =~ ^LOCAL: ]]; then
    local path="${dest_spec#LOCAL:}"
    [[ -d "$path" && -w "$path" ]] && echo "$path" || return 1
  else
    # Сетевое назначение
    load_network_destination "$dest_spec" || return 1
    
    local mount_point="/tmp/backup_mount_${dest_spec}_$$"
    mkdir -p "$mount_point"
    
    case "$NET_TYPE" in
      SMB)
        local cred="/tmp/smb_cred_$$"
        { 
          echo "username=$NET_USER"
          echo "password=$NET_PASSWORD"
          [[ -n "$NET_DOMAIN" ]] && echo "domain=$NET_DOMAIN"
        } > "$cred"
        chmod 600 "$cred"
        
        local versions=("3.0" "2.1" "2.0" "1.0") v ok=false
        for v in "${versions[@]}"; do
          mount -t cifs "//$NET_SERVER/$NET_SHARE" "$mount_point" \
            -o "credentials=$cred,vers=$v,uid=0,gid=0,file_mode=0644,dir_mode=0755" 2>/dev/null && {
            ok=true
            break
          }
        done
        rm -f "$cred"
        
        $ok && mountpoint -q "$mount_point" && {
          MOUNTED_POINTS["$dest_spec"]="$mount_point"
          echo "$mount_point"
        } || {
          rmdir "$mount_point" 2>/dev/null
          return 1
        }
        ;;
      SSHFS)
        local opts="allow_other,default_permissions,reconnect,ServerAliveInterval=15"
        [[ -n "$NET_SSH_KEY" && -f "$NET_SSH_KEY" ]] && opts="$opts,IdentityFile=$NET_SSH_KEY"
        
        sshfs -p "$NET_SSH_PORT" -o "$opts" "$NET_SSH_USER@$NET_SSH_HOST:$NET_SSH_PATH" "$mount_point" 2>/dev/null && \
        mountpoint -q "$mount_point" && {
          MOUNTED_POINTS["$dest_spec"]="$mount_point"
          echo "$mount_point"
        } || {
          rmdir "$mount_point" 2>/dev/null
          return 1
        }
        ;;
    esac
  fi
}

cleanup_mounts(){
  for dest in "${!MOUNTED_POINTS[@]}"; do
    local mount_point="${MOUNTED_POINTS[$dest]}"
    [[ -d "$mount_point" ]] && {
      umount "$mount_point" 2>/dev/null || \
        fusermount -u "$mount_point" 2>/dev/null || \
        umount -l "$mount_point" 2>/dev/null || true
      rmdir "$mount_point" 2>/dev/null || true
    }
  done
  MOUNTED_POINTS=()
}

make_backup_session_dir(){ 
  local base="$1"
  local host ts dir
  host="$(hostname -s 2>/dev/null || hostname)"
  ts="$(date +%Y-%m-%d_%H%M%S)"
  dir="$base/$host/$ts"
  mkdir -p "$dir" || { 
    error "Cannot mkdir $dir"
    return 1
  }
  echo "$dir"
}

backup_disk_with_statistics(){
  local src="$1" out="$2"
  [[ -b "$src" ]] || { 
    error "No device: $src"
    return 1
  }
  dd if="$src" bs=1 count=1 of=/dev/null 2>/dev/null || { 
    error "No read access: $src"
    return 1
  }
  local ssize
  ssize=$(get_device_size "$src")
  [[ $ssize -eq 0 ]] && { 
    error "Cannot get size of $src"
    return 1
  }
  local start
  start=$(date +%s)
  local rc=0
  case "$PROGRESS_METHOD" in
    pv)
      if $COMPRESSION_ENABLED; then 
        pv -s "$ssize" "$src" | gzip -c > "$out"
        rc=${PIPESTATUS[0]}
      else 
        pv -s "$ssize" "$src" > "$out"
        rc=$?
      fi 
      ;;
    dcfldd)
      if $COMPRESSION_ENABLED; then 
        dcfldd if="$src" bs=1M conv=noerror,sync | gzip -c > "$out"
        rc=${PIPESTATUS[0]}
      else 
        dcfldd if="$src" of="$out" bs=1M conv=noerror,sync
        rc=$?
      fi 
      ;;
    *)
      if $COMPRESSION_ENABLED; then 
        dd if="$src" bs=1M conv=noerror,sync 2>/dev/null | gzip -c > "$out"
        rc=${PIPESTATUS[0]}
      else 
        dd if="$src" of="$out" bs=1M conv=noerror,sync 2>/dev/null
        rc=$?
      fi 
      ;;
  esac
  local end dur
  end=$(date +%s)
  dur=$((end-start))
  if [[ $rc -eq 0 && -f "$out" ]]; then 
    local filesize
    filesize=$(stat -c%s "$out" 2>/dev/null || echo 0)
    success "Done in $(format_time "$dur") -> $out"
    info "Исходный размер: $(format_size "$ssize"), Результат: $(format_size "$filesize")"
    return 0
  else 
    error "Backup failed"
    [[ -f "$out" ]] && rm -f "$out"
    return 1
  fi
}

perform_backup(){
  clear
  echo -e "${CYAN}== Бэкап ==${NC}\n"
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then 
    error "Нет целей"
    read -r -p "Enter..."
    return 1
  fi

  # Проверяем настройки назначения
  local use_individual=false
  if [[ ${#DEVICE_DESTINATIONS[@]} -gt 0 ]]; then
    use_individual=true
    info "Используются индивидуальные назначения"
  elif [[ -n "$BACKUP_LOCATION" ]]; then
    info "Используется единое назначение: $BACKUP_LOCATION"
  else
    error "Не настроено ни одно место назначения"
    read -r -p "Enter..."
    return 1
  fi

  info "Цели: ${SELECTED_DISKS[*]}"
  info "Сжатие: $($COMPRESSION_ENABLED && echo on || echo off)"

  local a
  read -r -p "Продолжить? (y/N): " a
  [[ "$a" =~ ^[Yy]$ ]] || { 
    warning "Отменено"
    read -r -p "Enter..."
    return 1
  }

  local ok=0 total=${#SELECTED_DISKS[@]} 
  local total_original=0 total_compressed=0

  for src in "${SELECTED_DISKS[@]}"; do
    [[ -b "$src" ]] || { 
      error "No device: $src"
      continue
    }

    # Определяем место назначения для устройства
    local backup_location
    if $use_individual; then
      local dest_spec="${DEVICE_DESTINATIONS[$src]}"
      [[ -z "$dest_spec" ]] && { 
        error "Не задано назначение для $src"
        continue
      }
      backup_location=$(mount_destination "$dest_spec") || {
        error "Не удалось подключить назначение для $src"
        continue
      }
    else
      backup_location="$BACKUP_LOCATION"
    fi

    local session
    session=$(make_backup_session_dir "$backup_location") || continue
    
    local base ttype out
    base=$(basename "$src")
    ttype="disk"
    [[ "$src" =~ [0-9]+$ ]] && ttype="part"
    out="$session/${base}_${ttype}.img"
    $COMPRESSION_ENABLED && out="${out}.gz"
    
    log "$src -> $out"
    
    local original_size
    original_size=$(get_device_size "$src")
    
    if backup_disk_with_statistics "$src" "$out"; then
      ((ok++))
      total_original=$((total_original + original_size))
      if [[ -f "$out" ]]; then
        local compressed_size
        compressed_size=$(stat -c%s "$out" 2>/dev/null || echo 0)
        total_compressed=$((total_compressed + compressed_size))
      fi
    fi
  done

  echo
  echo -e "${CYAN}== Итоги бэкапа ==${NC}"
  [[ $ok -eq $total ]] && success "Все успешно ($ok/$total)" || warning "Успешно: $ok/$total"
  
  if [[ $total_original -gt 0 ]]; then
    echo -e "${YELLOW}Общий исходный размер:${NC} $(format_size "$total_original")"
    echo -e "${YELLOW}Общий размер бэкапов:${NC} $(format_size "$total_compressed")"
    if [[ $total_compressed -gt 0 && $total_original -gt 0 ]]; then
      local ratio=$((total_compressed * 100 / total_original))
      echo -e "${YELLOW}Степень сжатия:${NC} $ratio% (экономия: $((100-ratio))%)"
    fi
  fi
  
  read -r -p "Enter..."
  cleanup_mounts
}

# Остальные функции без изменений (analyze_backup_requirements, restore, etc.)
analyze_backup_requirements(){
  clear
  echo -e "${CYAN}== Оценка ==${NC}\n"
  
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  
  if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then 
    warning "Нет выбранных целей - сначала выберите диски/разделы в пункте меню 2"
  else
    local total=0 t
    echo "Выбранные устройства:"
    for t in "${SELECTED_DISKS[@]}"; do
      local sz
      sz=$(get_device_size "$t")
      if [[ $sz -eq 0 ]]; then
        warning "Устройство $t недоступно или не найдено"
        continue
      fi
      total=$((total+sz))
      printf "  %-16s %s\n" "$t" "$(format_size "$sz")"
    done
    
    if [[ $total -gt 0 ]]; then
      local est=$total
      $COMPRESSION_ENABLED && est=$((total*30/100))
      echo
      echo -e "${YELLOW}Сумма источников:${NC} $(format_size "$total")"
      echo -e "${YELLOW}Оценка после сжатия:${NC} $(format_size "$est") (консервативная)"
      echo -e "${YELLOW}С запасом (110%):${NC} $(format_size $((est + est/10)))"
      warning "Реальное сжатие может быть значительно лучше для пустых/малозаполненных дисков"
    else
      warning "Не удалось получить размеры выбранных устройств"
    fi
  fi
  
  read -r -p "Enter..."
}

# Остальные функции меню и системы остаются без изменений...
show_main_menu(){
  clear
  echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   DISK BACKUP MANAGER v6.7            ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}\n"
  echo "1) Показать диски и разделы"
  echo "2) Выбрать цели для бэкапа"
  echo "3) Настроить места назначения"
  echo "4) Оценка размера и места"
  echo "5) Выполнить бэкап"
  echo "6) Восстановление (диск/раздел)"
  echo "7) Настройки (вкл/выкл сжатие)"
  echo "8) Установка утилит"
  echo "9) Выход"
  echo
}

# Заглушки для отсутствующих функций (добавьте по необходимости)
choose_target_device(){ echo "/dev/sda1"; }  # Placeholder
validate_image_vs_target(){ return 0; }     # Placeholder  
restore_from_image(){ return 0; }           # Placeholder
restore_menu(){ echo "Restore menu placeholder"; read -r -p "Enter..."; }
install_utilities_menu(){ echo "Install menu placeholder"; read -r -p "Enter..."; }
toggle_compression(){ 
  $COMPRESSION_ENABLED && COMPRESSION_ENABLED=false || COMPRESSION_ENABLED=true
  success "Сжатие: $($COMPRESSION_ENABLED && echo on || echo off)"
  save_config
  read -r -p "Enter..."
}

main(){
  trap 'cleanup_mounts' EXIT
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  while true; do
    show_main_menu
    local c
    read -r -p "Выбор: " c
    case "$c" in
      1) show_detailed_disk_info ;;
      2) select_backup_targets ;;
      3) configure_destinations_menu ;;
      4) analyze_backup_requirements ;;
      5) perform_backup ;;
      6) restore_menu ;;
      7) toggle_compression ;;
      8) install_utilities_menu ;;
      9) log "Выход"; exit 0 ;;
      *) warning "Неверный выбор"; sleep 1 ;;
    esac
  done
}

SELECTED_DISKS=()
check_root
check_core_dependencies
check_progress_tools
check_network_tools
load_config
success "Система готова"; sleep 1
main "$@"
