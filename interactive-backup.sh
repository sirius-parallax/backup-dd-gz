#!/bin/bash
# =====================================================================
# Disk/Partition Backup Manager v6.8 (Astra/Linux)
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
PROFILES_DIR="$HOME/.backup_manager_profiles"
BACKUP_LOCATION=""
COMPRESSION_ENABLED=true
PROGRESS_METHOD="builtin"
NETWORK_MOUNTED=false
MOUNT_POINT="/tmp/backup_mount_$$"
SELECTED_DISKS=()

HAS_PV=false; HAS_DCFLDD=false; HAS_PROGRESS=false
HAS_CIFS_UTILS=false; HAS_SSHFS=false

check_root(){ [[ $EUID -ne 0 ]] && { error "Run as root"; exit 1; }; }

save_config(){
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
  {
    echo "# config v6.8 $(date)"
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

save_connection_profile(){
  local name="$1" type="$2"
  mkdir -p "$PROFILES_DIR" 2>/dev/null
  local profile_file="$PROFILES_DIR/$name.profile"
  
  {
    echo "# Connection profile: $name"
    echo "# Created: $(date)"
    echo "# Type: $type"
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
  success "Профиль '$name' сохранен"
}

load_connection_profile(){
  local name="$1"
  local profile_file="$PROFILES_DIR/$name.profile"
  [[ -f "$profile_file" ]] || return 1
  # shellcheck disable=SC1090
  . "$profile_file" 2>/dev/null || return 1
}

list_connection_profiles(){
  mkdir -p "$PROFILES_DIR" 2>/dev/null
  find "$PROFILES_DIR" -name "*.profile" -exec basename {} .profile \; 2>/dev/null | sort
}

get_profile_description(){
  local name="$1"
  load_connection_profile "$name" || return 1
  case "$PROFILE_TYPE" in
    SMB) echo "SMB: $SMB_SERVER/$SMB_SHARE (пользователь: $SMB_USER)" ;;
    SSHFS) echo "SSHFS: $SSHFS_USER@$SSHFS_HOST:$SSHFS_PATH" ;;
    *) echo "Неизвестный тип" ;;
  esac
}

manage_connection_profiles(){
  while true; do
    clear
    echo -e "${CYAN}== Управление профилями подключений ==${NC}\n"
    
    local profiles
    mapfile -t profiles < <(list_connection_profiles)
    
    if [[ ${#profiles[@]} -eq 0 ]]; then
      warning "Нет сохранённых профилей"
    else
      echo "Сохранённые профили:"
      local i=1
      for profile in "${profiles[@]}"; do
        local desc
        desc=$(get_profile_description "$profile")
        printf "%d) %s - %s\n" $i "$profile" "$desc"
        ((i++))
      done
      echo
      echo "d) Удалить профиль"
    fi
    
    echo "b) Назад"
    echo
    
    local choice
    read -r -p "Выбор: " choice
    
    case "$choice" in
      d|D)
        if [[ ${#profiles[@]} -eq 0 ]]; then
          warning "Нет профилей для удаления"
          read -r -p "Enter..."
          continue
        fi
        
        echo "Выберите профиль для удаления:"
        local i=1
        for profile in "${profiles[@]}"; do
          printf "%d) %s\n" $i "$profile"
          ((i++))
        done
        
        local del_choice
        read -r -p "Номер профиля: " del_choice
        
        if [[ "$del_choice" =~ ^[0-9]+$ && $del_choice -ge 1 && $del_choice -le ${#profiles[@]} ]]; then
          local profile_to_delete="${profiles[$((del_choice-1))]}"
          read -r -p "Удалить профиль '$profile_to_delete'? (y/N): " confirm
          if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$PROFILES_DIR/$profile_to_delete.profile"
            success "Профиль '$profile_to_delete' удален"
          fi
        else
          warning "Неверный выбор"
        fi
        read -r -p "Enter..."
        ;;
      b|B) return ;;
      *) warning "Неверный выбор"; read -r -p "Enter..." ;;
    esac
  done
}

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

get_device_size(){ 
  local dev="$1"
  blockdev --getsize64 "$dev" 2>/dev/null || echo 0
}

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

list_disks_raw(){
  lsblk -pdn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'
}

find_all_partitions(){
  lsblk -pln -o NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}'
}

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
    [[ $COMPRESSION_ENABLED == true ]] && s=$((s*30/100))
    total=$((total+s))
  done
  echo $((total + total/10))
}

check_local_path_conflicts(){
  local dst="$1" realdst
  realdst=$(readlink -f "$1" 2>/dev/null || echo "$1")
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  local t
  for t in "${SELECTED_DISKS[@]}"; do
    if [[ "$t" =~ [0-9]+$ ]]; then
      local mnt
      mnt=$(lsblk -pdn -o MOUNTPOINT "$t" 2>/dev/null | tr -d ' ')
      if [[ -n "$mnt" ]]; then
        local rmnt
        rmnt=$(readlink -f "$mnt" 2>/dev/null || echo "$mnt")
        [[ "$realdst/" == "$rmnt/"* || "$realdst" == "$rmnt" ]] && { 
          error "Назначение на исходном разделе: $t ($mnt)"
          return 1
        }
      fi
    fi
  done
  return 0
}

check_free_space(){
  local path="$1" need="$2"
  [[ ! -d "$path" ]] && { 
    error "No such dir: $path"
    return 1
  }
  local avail
  avail=$(df --output=avail -B1 "$path" 2>/dev/null | tail -n1)
  [[ "$avail" =~ ^[0-9]+$ ]] || { 
    warning "df unknown output for $path"
    return 1
  }
  info "Avail: $(format_size "$avail") | Need: $(format_size "$need")"
  [[ $avail -lt $need ]] && { 
    error "Not enough space"
    return 1
  }
  return 0
}

mount_smb_share(){
  local server="$1" share="$2" user="$3" pass="$4" domain="$5"
  command -v mount.cifs >/dev/null 2>&1 || { 
    error "cifs-utils не установлены"
    return 1
  }
  mkdir -p "$MOUNT_POINT"
  local cred="/tmp/smb_cred_$$"
  { 
    echo "username=$user"
    echo "password=$pass"
    [[ -n "$domain" ]] && echo "domain=$domain"
  } > "$cred"
  chmod 600 "$cred"
  local versions=("3.0" "2.1" "2.0" "1.0") v ok=false
  for v in "${versions[@]}"; do
    mount -t cifs "//$server/$share" "$MOUNT_POINT" \
      -o "credentials=$cred,vers=$v,uid=0,gid=0,file_mode=0644,dir_mode=0755" 2>/dev/null && {
      ok=true
      break
    }
  done
  rm -f "$cred"
  $ok || { 
    error "SMB монтирование не удалось"
    rmdir "$MOUNT_POINT" 2>/dev/null
    return 1
  }
  mountpoint -q "$MOUNT_POINT" || { 
    error "SMB не смонтирован"
    rmdir "$MOUNT_POINT"
    return 1
  }
  touch "$MOUNT_POINT/.rwtest_$$" 2>/dev/null || { 
    error "Нет записи на SMB"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    return 1
  }
  rm -f "$MOUNT_POINT/.rwtest_$$"
  success "SMB смонтирован: $MOUNT_POINT"
  NETWORK_MOUNTED=true
  BACKUP_LOCATION="$MOUNT_POINT"
  return 0
}

mount_ssh_share(){
  local user="$1" host="$2" path="$3" port="${4:-22}" key="$5"
  command -v sshfs >/dev/null 2>&1 || { 
    error "sshfs не установлен"
    return 1
  }
  mkdir -p "$MOUNT_POINT"
  local opts="allow_other,default_permissions,reconnect,ServerAliveInterval=15,StrictHostKeyChecking=no"
  [[ -n "$key" && -f "$key" ]] && opts="$opts,IdentityFile=$key"
  sshfs -p "$port" -o "$opts" "$user@$host:$path" "$MOUNT_POINT" 2>/dev/null || { 
    error "SSHFS монтирование не удалось"
    rmdir "$MOUNT_POINT"
    return 1
  }
  mountpoint -q "$MOUNT_POINT" || { 
    error "SSHFS не смонтирован"
    rmdir "$MOUNT_POINT"
    return 1
  }
  touch "$MOUNT_POINT/.rwtest_$$" 2>/dev/null || { 
    error "Нет записи на SSHFS"
    fusermount -u "$MOUNT_POINT" || umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    return 1
  }
  rm -f "$MOUNT_POINT/.rwtest_$$"
  success "SSHFS смонтирован: $MOUNT_POINT"
  NETWORK_MOUNTED=true
  BACKUP_LOCATION="$MOUNT_POINT"
  return 0
}

cleanup_mounts(){ 
  if $NETWORK_MOUNTED && [[ -d "$MOUNT_POINT" ]]; then
    umount "$MOUNT_POINT" 2>/dev/null || \
      fusermount -u "$MOUNT_POINT" 2>/dev/null || \
      umount -l "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    NETWORK_MOUNTED=false
    info "Сетевой ресурс размонтирован"
  fi
}

configure_backup_destination(){
  while true; do
    clear
    echo -e "${CYAN}== Назначение бэкапа ==${NC}\n"
    local need
    need=$(calculate_required_space)
    info "Требуется ~ $(format_size "$need")"
    [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
    [[ ${#SELECTED_DISKS[@]} -gt 0 ]] && info "Цели: ${SELECTED_DISKS[*]}"
    echo
    echo "1) Локальная папка"
    echo "2) SMB/CIFS"
    echo "3) SSH/SSHFS"
    
    local profiles
    mapfile -t profiles < <(list_connection_profiles)
    if [[ ${#profiles[@]} -gt 0 ]]; then
      echo "4) Использовать сохранённый профиль"
    fi
    echo "5) Управление профилями"
    echo "6) Назад"
    
    local c
    read -r -p "Выбор: " c
    case "$c" in
      1)
        cleanup_mounts
        local p
        read -r -p "Абсолютный путь к папке: " p
        [[ "$p" =~ ^/ ]] || { 
          error "Нужен абсолютный путь"
          read -r -p "Enter..."
          continue
        }
        [[ -d "$p" ]] || { 
          warning "Создаём: $p"
          mkdir -p "$p" 2>/dev/null || { 
            error "Не создать $p"
            read -r -p "Enter..."
            continue
          }
        }
        [[ -w "$p" ]] || { 
          error "Нет прав на запись: $p"
          read -r -p "Enter..."
          continue
        }
        check_local_path_conflicts "$p" || { 
          read -r -p "Enter..."
          continue
        }
        check_free_space "$p" "$need" || { 
          read -r -p "Продолжить? (y/N): " y
          [[ "$y" =~ ^[Yy]$ ]] || continue
        }
        BACKUP_LOCATION="$p"
        NETWORK_MOUNTED=false
        success "Назначение: $BACKUP_LOCATION"
        save_config
        read -r -p "Enter..."
        return 0
        ;;
      2)
        cleanup_mounts
        local s sh u pw d save_choice profile_name
        read -r -p "Сервер (IP/имя): " s
        read -r -p "Шара: " sh
        read -r -p "Пользователь: " u
        read -r -s -p "Пароль: " pw
        echo
        read -r -p "Домен (опц.): " d
        
        mount_smb_share "$s" "$sh" "$u" "$pw" "$d" || { 
          read -r -p "Enter..."
          continue
        }
        check_free_space "$MOUNT_POINT" "$need" || { 
          error "Недостаточно места на SMB"
          cleanup_mounts
          read -r -p "Enter..."
          continue
        }
        
        read -r -p "Сохранить эти настройки как профиль? (y/N): " save_choice
        if [[ "$save_choice" =~ ^[Yy]$ ]]; then
          read -r -p "Имя профиля: " profile_name
          if [[ -n "$profile_name" ]]; then
            SMB_SERVER="$s"
            SMB_SHARE="$sh"
            SMB_USER="$u"
            SMB_PASSWORD="$pw"
            SMB_DOMAIN="$d"
            save_connection_profile "$profile_name" "SMB"
          fi
        fi
        
        save_config
        read -r -p "Enter..."
        return 0
        ;;
      3)
        cleanup_mounts
        local su shost sp spn sk save_choice profile_name
        read -r -p "SSH пользователь: " su
        read -r -p "Хост: " shost
        read -r -p "Удал. путь (напр., /backup): " sp
        read -r -p "Порт [22]: " spn
        spn=${spn:-22}
        read -r -p "Путь к SSH-ключу (опц.): " sk
        
        mount_ssh_share "$su" "$shost" "$sp" "$spn" "$sk" || { 
          read -r -p "Enter..."
          continue
        }
        check_free_space "$MOUNT_POINT" "$need" || { 
          error "Недостаточно места на SSHFS"
          cleanup_mounts
          read -r -p "Enter..."
          continue
        }
        
        read -r -p "Сохранить эти настройки как профиль? (y/N): " save_choice
        if [[ "$save_choice" =~ ^[Yy]$ ]]; then
          read -r -p "Имя профиля: " profile_name
          if [[ -n "$profile_name" ]]; then
            SSHFS_HOST="$shost"
            SSHFS_USER="$su"
            SSHFS_PATH="$sp"
            SSHFS_PORT="$spn"
            SSHFS_KEY="$sk"
            save_connection_profile "$profile_name" "SSHFS"
          fi
        fi
        
        save_config
        read -r -p "Enter..."
        return 0
        ;;
      4)
        if [[ ${#profiles[@]} -gt 0 ]]; then
          cleanup_mounts
          echo "Выберите профиль:"
          local i=1
          for profile in "${profiles[@]}"; do
            local desc
            desc=$(get_profile_description "$profile")
            printf "%d) %s - %s\n" $i "$profile" "$desc"
            ((i++))
          done
          
          local profile_choice
          read -r -p "Номер профиля: " profile_choice
          
          if [[ "$profile_choice" =~ ^[0-9]+$ && $profile_choice -ge 1 && $profile_choice -le ${#profiles[@]} ]]; then
            local selected_profile="${profiles[$((profile_choice-1))]}"
            load_connection_profile "$selected_profile" || {
              error "Не удалось загрузить профиль"
              read -r -p "Enter..."
              continue
            }
            
            case "$PROFILE_TYPE" in
              SMB)
                mount_smb_share "$SMB_SERVER" "$SMB_SHARE" "$SMB_USER" "$SMB_PASSWORD" "$SMB_DOMAIN" || { 
                  read -r -p "Enter..."
                  continue
                }
                ;;
              SSHFS)
                mount_ssh_share "$SSHFS_USER" "$SSHFS_HOST" "$SSHFS_PATH" "$SSHFS_PORT" "$SSHFS_KEY" || { 
                  read -r -p "Enter..."
                  continue
                }
                ;;
            esac
            
            check_free_space "$MOUNT_POINT" "$need" || { 
              error "Недостаточно места"
              cleanup_mounts
              read -r -p "Enter..."
              continue
            }
            save_config
            read -r -p "Enter..."
            return 0
          else
            warning "Неверный выбор"
            read -r -p "Enter..."
          fi
        fi
        ;;
      5)
        manage_connection_profiles
        ;;
      6) 
        return 1 
        ;;
      *) 
        warning "Неверный выбор"
        ;;
    esac
  done
}

make_backup_session_dir(){ 
  local base="$BACKUP_LOCATION" host ts dir
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
  if [[ -z "$BACKUP_LOCATION" ]]; then 
    error "Назначение не настроено"
    read -r -p "Enter..."
    return 1
  fi
  if [[ ! -d "$BACKUP_LOCATION" || ! -w "$BACKUP_LOCATION" ]]; then 
    error "Назначение не доступно для записи"
    read -r -p "Enter..."
    return 1
  fi

  info "Цели: ${SELECTED_DISKS[*]}"
  info "Назначение: $BACKUP_LOCATION"
  info "Сжатие: $($COMPRESSION_ENABLED && echo on || echo off)"

  local a
  read -r -p "Продолжить? (y/N): " a
  [[ "$a" =~ ^[Yy]$ ]] || { 
    warning "Отменено"
    read -r -p "Enter..."
    return 1
  }

  local session
  session=$(make_backup_session_dir) || { 
    read -r -p "Enter..."
    return 1
  }
  
  local ok=0 total=${#SELECTED_DISKS[@]} src base ttype out
  local total_original=0 total_compressed=0

  for src in "${SELECTED_DISKS[@]}"; do
    [[ -b "$src" ]] || { 
      error "No device: $src"
      continue
    }
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
}

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
  
  echo
  if [[ -n "$BACKUP_LOCATION" && -d "$BACKUP_LOCATION" ]]; then
    local avail
    avail=$(df --output=avail -B1 "$BACKUP_LOCATION" 2>/dev/null | tail -n1)
    if [[ "$avail" =~ ^[0-9]+$ ]]; then 
      echo -e "${YELLOW}Доступно в назначении:${NC} $(format_size "$avail")"
      echo -e "${YELLOW}Путь назначения:${NC} $BACKUP_LOCATION"
    else 
      warning "Назначение недоступно или не смонтировано: $BACKUP_LOCATION"
    fi
  else
    warning "Назначение не настроено - настройте в пункте меню 3"
  fi
  
  read -r -p "Enter..."
}

choose_target_device(){
  local ITEMS=() INFOS=()
  {
    echo -e "${CYAN}== Выбор целевого устройства ==${NC}\n"
    
    while IFS= read -r dev; do
      [[ -b "$dev" ]] || continue
      local size model serial
      size=$(format_size "$(get_device_size "$dev")")
      model=$(lsblk -pdn -o MODEL "$dev" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      serial=$(lsblk -pdn -o SERIAL "$dev" 2>/dev/null | tr -d ' ')
      INFOS+=("ДИСК: ${size:-?} ${model:+- $model} ${serial:+(S/N: $serial)}")
      ITEMS+=("$dev")
    done < <(list_disks_raw)
    
    while IFS= read -r part; do
      [[ -b "$part" ]] || continue
      local details psize pfs plabel pmount
      details=$(get_partition_details "$part")
      IFS='|' read -r psize pfs plabel pmount <<< "$details"
      
      local desc="РАЗДЕЛ: ${psize:-?}"
      [[ "$pfs" != "-" ]] && desc="$desc [$pfs]"
      [[ "$plabel" != "-" ]] && desc="$desc \"$plabel\""
      [[ "$pmount" != "-" ]] && desc="$desc -> $pmount"
      
      INFOS+=("$desc")
      ITEMS+=("$part")
    done < <(find_all_partitions)
    
    if [[ ${#ITEMS[@]} -eq 0 ]]; then 
      echo -e "${RED}[ERROR]${NC} Нет доступных устройств"
      echo
      echo "" 1>&3
      return
    fi
    
    local i
    for i in "${!ITEMS[@]}"; do
      printf "%2d) %-16s %s\n" $((i+1)) "${ITEMS[i]}" "${INFOS[i]}"
    done
    echo
    printf "%s\0" "${ITEMS[@]}" 1>&3
  } 1>&2 3>"/tmp/.choose_list_$$"
  
  local nsel
  read -r -p "Номер устройства: " nsel 1>&2
  mapfile -d '' -t __ALL < "/tmp/.choose_list_$$"
  rm -f "/tmp/.choose_list_$$"
  
  if [[ "$nsel" =~ ^[0-9]+$ && $nsel -ge 1 && $nsel -le ${#__ALL[@]} ]]; then 
    echo "${__ALL[$((nsel-1))]}"
  else 
    echo ""
  fi
}

validate_image_vs_target(){
  local image="$1" target="$2"
  local is_gz=0
  [[ "$image" =~ \.gz$ ]] && is_gz=1
  local itype="unknown"
  [[ "$image" =~ _disk\.img(\.gz)?$ ]] && itype="disk"
  [[ "$image" =~ _part\.img(\.gz)?$ ]] && itype="part"
  local ttype="disk"
  [[ "$target" =~ [0-9]+$ ]] && ttype="part"
  
  if [[ "$itype" != "unknown" && "$itype" != "$ttype" ]]; then
    warning "Тип образа ($itype) <> тип цели ($ttype)"
    local c
    read -r -p "Продолжить? (y/N): " c
    [[ "$c" =~ ^[Yy]$ ]] || return 1
  fi
  
  local mp
  mp=$(lsblk -pdn -o MOUNTPOINT "$target" 2>/dev/null | tr -d ' ')
  [[ -n "$mp" ]] && { 
    error "Цель смонтирована: $mp"
    return 1
  }
  
  if [[ $is_gz -eq 0 ]]; then
    local isize tsize
    isize=$(stat -c%s "$image" 2>/dev/null || echo 0)
    tsize=$(get_device_size "$target")
    [[ $isize -gt 0 && $tsize -gt 0 && $isize -gt $tsize ]] && { 
      error "Образ больше цели ($(format_size "$isize") > $(format_size "$tsize"))"
      return 1
    }
  else
    info "Образ .gz: исходный размер неизвестен — осторожно."
  fi
  return 0
}

restore_from_image(){
  local image="$1" target="$2"
  [[ -f "$image" ]] || { 
    error "No file: $image"
    read -r -p "Enter..."
    return 1
  }
  [[ -b "$target" ]] || { 
    error "No target: $target"
    read -r -p "Enter..."
    return 1
  }
  validate_image_vs_target "$image" "$target" || { 
    read -r -p "Enter..."
    return 1
  }
  echo -e "${RED}DANGER:${NC} overwrite $target"
  local x
  read -r -p "Type YES to continue: " x
  [[ "$x" == "YES" ]] || { 
    warning "Canceled"
    read -r -p "Enter..."
    return 1
  }
  local rc=0
  if [[ "$image" =~ \.gz$ ]]; then 
    gunzip -c "$image" | dd of="$target" bs=1M conv=fsync status=progress
    rc=${PIPESTATUS[1]}
  else 
    dd if="$image" of="$target" bs=1M conv=fsync status=progress
    rc=$?
  fi
  [[ $rc -eq 0 ]] && success "Restored" || error "Restore failed"
  read -r -p "Enter..."
  return $rc
}

restore_menu(){
  clear
  echo -e "${CYAN}== Восстановление ==${NC}\n"
  if [[ -z "$BACKUP_LOCATION" ]]; then 
    error "Назначение не настроено"
    read -r -p "Enter..."
    return
  fi
  echo "1) Из сессии (<host>/<date>)"
  echo "2) Указать файл вручную"
  echo "3) Файлы в корне назначения"
  echo "4) Назад"
  local ch
  read -r -p "Выбор: " ch
  case "$ch" in
    1)
      local sessions=()
      while IFS= read -r s; do 
        sessions+=("$s")
      done < <(find "$BACKUP_LOCATION" -mindepth 2 -maxdepth 2 -type d -printf "%P\n" 2>/dev/null | sort)
      
      if [[ ${#sessions[@]} -eq 0 ]]; then 
        warning "Сессии не найдены"
        read -r -p "Enter..."
        return
      fi
      
      local i
      for i in "${!sessions[@]}"; do
        printf "%2d) %s\n" $((i+1)) "${sessions[i]}"
      done
      local n
      read -r -p "Номер сессии: " n
      
      if [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#sessions[@]} ]]; then
        local dir="$BACKUP_LOCATION/${sessions[$((n-1))]}" files=()
        while IFS= read -r f; do 
          files+=("$f")
        done < <(find "$dir" -maxdepth 1 -type f \( -name "*.img" -o -name "*.img.gz" \) -printf "%f\n" 2>/dev/null | sort)
        
        if [[ ${#files[@]} -eq 0 ]]; then 
          warning "В сессии нет образов"
          read -r -p "Enter..."
          return
        fi
        
        local j
        for j in "${!files[@]}"; do
          printf "%2d) %s\n" $((j+1)) "${files[j]}"
        done
        local fn
        read -r -p "Номер файла: " fn
        
        if [[ "$fn" =~ ^[0-9]+$ && $fn -ge 1 && $fn -le ${#files[@]} ]]; then
          local image="$dir/${files[$((fn-1))]}" target
          target="$(choose_target_device)"
          [[ -n "$target" ]] || { 
            warning "Не выбрано"
            read -r -p "Enter..."
            return
          }
          restore_from_image "$image" "$target"
        else 
          warning "Неверный выбор"
          read -r -p "Enter..."
        fi
      else 
        warning "Неверный выбор"
        read -r -p "Enter..."
      fi
      ;;
    2)
      local image
      read -r -p "Путь к образу (.img/.img.gz): " image
      [[ -f "$image" ]] || { 
        error "Нет файла"
        read -r -p "Enter..."
        return
      }
      local target
      target="$(choose_target_device)"
      [[ -n "$target" ]] || { 
        warning "Не выбрано"
        read -r -p "Enter..."
        return
      }
      restore_from_image "$image" "$target"
      ;;
    3)
      local dir="$BACKUP_LOCATION" files=()
      while IFS= read -r f; do 
        files+=("$f")
      done < <(find "$dir" -maxdepth 1 -type f \( -name "*.img" -o -name "*.img.gz" \) -printf "%f\n" 2>/dev/null | sort)
      
      if [[ ${#files[@]} -eq 0 ]]; then 
        warning "Нет образов"
        read -r -p "Enter..."
        return
      fi
      
      local k
      for k in "${!files[@]}"; do
        printf "%2d) %s\n" $((k+1)) "${files[k]}"
      done
      local fn2
      read -r -p "Номер файла: " fn2
      
      if [[ "$fn2" =~ ^[0-9]+$ && $fn2 -ge 1 && $fn2 -le ${#files[@]} ]]; then
        local image="$dir/${files[$((fn2-1))]}" target
        target="$(choose_target_device)"
        [[ -n "$target" ]] || { 
          warning "Не выбрано"
          read -r -p "Enter..."
          return
        }
        restore_from_image "$image" "$target"
      else 
        warning "Неверный выбор"
        read -r -p "Enter..."
      fi
      ;;
    4) 
      return 
      ;;
    *) 
      warning "Неверный выбор"
      read -r -p "Enter..."
      ;;
  esac
}

install_utilities_menu(){
  while true; do
    clear
    echo -e "${CYAN}== Установка утилит ==${NC}"
    echo "1) Установить pv/dcfldd/sshfs/cifs-utils (через пакетный менеджер)"
    echo "2) Назад"
    echo
    echo "Статус: pv=$($HAS_PV && echo yes || echo no), dcfldd=$($HAS_DCFLDD && echo yes || echo no), sshfs=$($HAS_SSHFS && echo yes || echo no), cifs-utils=$($HAS_CIFS_UTILS && echo yes || echo no)"
    read -r -p "Выбор: " c
    case "$c" in
      1)
        if command -v apt >/dev/null 2>&1; then 
          apt update && apt install -y pv dcfldd sshfs cifs-utils || warning "apt failed"
        elif command -v dnf >/dev/null 2>&1; then 
          dnf install -y pv dcfldd sshfs cifs-utils || warning "dnf failed"
        elif command -v yum >/dev/null 2>&1; then 
          yum install -y pv dcfldd sshfs cifs-utils || warning "yum failed"
        else 
          warning "Unknown package manager"
        fi
        ;;
      2) 
        break 
        ;;
      *) 
        warning "Неверный выбор"
        ;;
    esac
    check_progress_tools
    check_network_tools
    read -r -p "Enter..."
  done
}

toggle_compression(){ 
  $COMPRESSION_ENABLED && COMPRESSION_ENABLED=false || COMPRESSION_ENABLED=true
  success "Сжатие: $($COMPRESSION_ENABLED && echo on || echo off)"
  save_config
  read -r -p "Enter..."
}

show_current_settings(){
  clear
  echo -e "${CYAN}== Текущие настройки ==${NC}\n"
  echo -e "${YELLOW}Цели:${NC}"
  [[ -z "${SELECTED_DISKS+x}" ]] && SELECTED_DISKS=()
  if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then 
    echo "  (нет)"
  else 
    local t
    for t in "${SELECTED_DISKS[@]}"; do
      echo "  - $t"
    done
  fi
  echo -e "\n${YELLOW}Назначение:${NC} ${BACKUP_LOCATION:-(нет)}"
  echo -e "${YELLOW}Сетевое монтирование:${NC} $($NETWORK_MOUNTED && echo yes || echo no)"
  echo -e "${YELLOW}Сжатие:${NC} $($COMPRESSION_ENABLED && echo on || echo off)"
  echo -e "${YELLOW}Прогресс:${NC} $PROGRESS_METHOD"
  echo
  local profiles
  mapfile -t profiles < <(list_connection_profiles)
  echo -e "${YELLOW}Сохранённых профилей:${NC} ${#profiles[@]}"
  echo
  read -r -p "Enter..."
}

show_main_menu(){
  clear
  echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   DISK BACKUP MANAGER v6.8            ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}\n"
  echo "1) Показать диски и разделы"
  echo "2) Выбрать цели для бэкапа"
  echo "3) Настроить место назначения"
  echo "4) Оценка размера и места"
  echo "5) Выполнить бэкап"
  echo "6) Восстановление (диск/раздел)"
  echo "7) Настройки (вкл/выкл сжатие)"
  echo "8) Установка утилит"
  echo "9) Выход"
  echo
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
      3) configure_backup_destination ;;
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
