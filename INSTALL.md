# Установка и настройка

## Системные требования

### Минимальные требования
- **ОС**: Linux (любой дистрибутив с ядром 3.0+)
- **Оперативная память**: 512MB
- **Свободное место**: 100MB для скрипта + место для резервных копий
- **Права доступа**: root (sudo)

### Рекомендуемые требования
- **ОС**: Linux с systemd поддержкой
- **Оперативная память**: 2GB+
- **Свободное место**: 2GB+ для временных файлов
- **Сеть**: стабильное подключение для сетевых назначений

## Поддерживаемые дистрибутивы

### ✅ Полностью поддерживаемые
- **Ubuntu** 18.04+ (LTS рекомендуется)
- **Debian** 9+
- **CentOS** 7+
- **RHEL** 7+
- **Fedora** 30+
- **Arch Linux** (актуальный)
- **openSUSE** Leap 15+

### ⚠️ Частично поддерживаемые  
- **Alpine Linux** (требует установка bash)
- **Gentoo** (требует ручная сборка зависимостей)
- **Slackware** (ограниченная поддержка пакетного менеджера)

## Способы установки

### 1. Быстрая установка (рекомендуется)

```bash
# Скачивание и установка одной командой
curl -fsSL https://raw.githubusercontent.com/your-repo/main/install.sh | sudo bash
```

### 2. Ручная установка

```bash
# Создание папки для скрипта
sudo mkdir -p /opt/backup-manager
cd /opt/backup-manager

# Скачивание скрипта
sudo wget https://raw.githubusercontent.com/your-repo/main/backup-manager-v7.01-fixed.sh

# Установка прав доступа
sudo chmod +x backup-manager-v7.01-fixed.sh

# Создание символической ссылки
sudo ln -sf /opt/backup-manager/backup-manager-v7.01-fixed.sh /usr/local/bin/backup-manager

# Проверка установки
backup-manager --version
```

### 3. Установка через Git

```bash
# Клонирование репозитория
git clone https://github.com/your-repo/disk-backup-manager.git
cd disk-backup-manager

# Установка
sudo ./install.sh

# Или копирование вручную
sudo cp backup-manager-v7.01-fixed.sh /usr/local/bin/backup-manager
sudo chmod +x /usr/local/bin/backup-manager
```

## Установка зависимостей

### Ubuntu/Debian
```bash
# Основные зависимости
sudo apt update
sudo apt install -y lsblk coreutils gzip util-linux

# Для сборки утилит прогресса
sudo apt install -y gcc make autoconf automake pkg-config git libncurses5-dev curl wget

# Сетевые утилиты
sudo apt install -y cifs-utils sshfs openssh-client fuse
```

### CentOS/RHEL
```bash
# Основные зависимости  
sudo yum install -y util-linux coreutils gzip

# Для сборки утилит прогресса
sudo yum install -y gcc make autoconf automake pkgconfig git ncurses-devel curl wget

# Сетевые утилиты
sudo yum install -y cifs-utils sshfs openssh-clients fuse

# Для RHEL может потребоваться EPEL
sudo yum install -y epel-release
```

### Fedora
```bash
# Основные зависимости
sudo dnf install -y util-linux coreutils gzip

# Для сборки утилит прогресса
sudo dnf install -y gcc make autoconf automake pkg-config git ncurses-devel curl wget

# Сетевые утилиты
sudo dnf install -y cifs-utils sshfs openssh-clients fuse
```

### Arch Linux
```bash
# Основные зависимости
sudo pacman -S util-linux coreutils gzip

# Для сборки утилит прогресса
sudo pacman -S gcc make autoconf automake pkg-config git ncurses curl wget

# Сетевые утилиты
sudo pacman -S cifs-utils sshfs openssh fuse2 fuse3
```

## Начальная настройка

### 1. Первый запуск
```bash
# Запуск скрипта
sudo backup-manager

# Или полный путь
sudo /opt/backup-manager/backup-manager-v7.01-fixed.sh
```

### 2. Установка утилит прогресса
В главном меню выберите:
- **9) Установка утилит** 
- **8) Установить все утилиты прогресса**
- Дождитесь завершения установки

### 3. Настройка места назначения
- **3) Настроить место назначения**
- Выберите локальную папку или сетевое подключение
- Для сетевых подключений создайте профиль

### 4. Выбор дисков для резервного копирования  
- **1) Показать диски и разделы** - изучите доступные устройства
- **2) Выбрать цели для бэкапа** - выберите нужные диски/разделы

## Дополнительные настройки

### Настройка автозапуска

#### Systemd Service
```bash
# Создание service файла
sudo tee /etc/systemd/system/backup-manager.service > /dev/null <<EOF
[Unit]
Description=Disk Backup Manager
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-manager --auto
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Создание timer файла
sudo tee /etc/systemd/system/backup-manager.timer > /dev/null <<EOF
[Unit]  
Description=Daily Backup Manager
Requires=backup-manager.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Активация
sudo systemctl daemon-reload
sudo systemctl enable backup-manager.timer
sudo systemctl start backup-manager.timer

# Проверка статуса
sudo systemctl status backup-manager.timer
```

#### Cron Job
```bash
# Добавление в crontab root пользователя
sudo crontab -e

# Добавить строку для ежедневного запуска в 2:00
0 2 * * * /usr/local/bin/backup-manager --auto >> /var/log/backup-manager.log 2>&1

# Или еженедельно по воскресеньям в 3:00
0 3 * * 0 /usr/local/bin/backup-manager --auto >> /var/log/backup-manager.log 2>&1
```

### Настройка логирования

#### Systemd Journald
```bash
# Просмотр логов
sudo journalctl -u backup-manager.service

# Логи в реальном времени
sudo journalctl -u backup-manager.service -f

# Логи за определенный период
sudo journalctl -u backup-manager.service --since="2025-09-01" --until="2025-09-03"
```

#### Файловое логирование
```bash
# Создание папки для логов
sudo mkdir -p /var/log/backup-manager

# Настройка ротации логов
sudo tee /etc/logrotate.d/backup-manager > /dev/null <<EOF
/var/log/backup-manager/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
```

### Настройка уведомлений

#### Email уведомления
```bash
# Установка mailutils
sudo apt install mailutils  # Ubuntu/Debian
sudo yum install mailx      # CentOS/RHEL

# Настройка в cron
0 2 * * * /usr/local/bin/backup-manager --auto && echo "Backup completed" | mail -s "Backup Success" admin@example.com || echo "Backup failed" | mail -s "Backup FAILED" admin@example.com
```

#### Telegram Bot уведомления
```bash
# Создание скрипта уведомлений
sudo tee /usr/local/bin/backup-notify.sh > /dev/null <<'EOF'
#!/bin/bash
BOT_TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="YOUR_CHAT_ID"
MESSAGE="$1"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d text="${MESSAGE}"
EOF

sudo chmod +x /usr/local/bin/backup-notify.sh

# Использование в cron
0 2 * * * /usr/local/bin/backup-manager --auto && /usr/local/bin/backup-notify.sh "✅ Backup completed successfully" || /usr/local/bin/backup-notify.sh "❌ Backup failed"
```

## Проверка установки

### Базовая проверка
```bash
# Проверка версии
backup-manager --version

# Проверка справки
backup-manager --help

# Проверка конфигурации
backup-manager --check-config

# Проверка зависимостей
backup-manager --check-deps
```

### Тестовый запуск
```bash
# Сухой прогон (без выполнения операций)
sudo backup-manager --dry-run

# Тестовое резервное копирование небольшого раздела
sudo backup-manager --test-mode
```

### Проверка утилит прогресса
```bash
# Проверка pv
pv --version

# Проверка dcfldd  
dcfldd --version

# Проверка progress
progress --version

# Проверка dd поддержки status=progress
dd --help | grep progress
```

## Обновление

### Автоматическое обновление
```bash
# Проверка доступных обновлений
sudo backup-manager --check-updates

# Автоматическое обновление до последней версии
sudo backup-manager --update
```

### Ручное обновление
```bash
# Скачивание новой версии
cd /opt/backup-manager
sudo wget -O backup-manager-new.sh https://raw.githubusercontent.com/your-repo/main/backup-manager-v7.01-fixed.sh

# Проверка версии
bash backup-manager-new.sh --version

# Замена старой версии
sudo mv backup-manager-v7.01-fixed.sh backup-manager-v7.01-fixed.sh.backup
sudo mv backup-manager-new.sh backup-manager-v7.01-fixed.sh
sudo chmod +x backup-manager-v7.01-fixed.sh

# Перезапуск сервисов
sudo systemctl daemon-reload
sudo systemctl restart backup-manager.timer
```

## Удаление

### Полное удаление
```bash
# Остановка служб
sudo systemctl stop backup-manager.timer
sudo systemctl disable backup-manager.timer

# Удаление служб
sudo rm -f /etc/systemd/system/backup-manager.service
sudo rm -f /etc/systemd/system/backup-manager.timer
sudo systemctl daemon-reload

# Удаление скрипта
sudo rm -f /usr/local/bin/backup-manager
sudo rm -rf /opt/backup-manager

# Удаление конфигурации (опционально)
rm -rf ~/.backup_manager_config ~/.backup_manager_profiles

# Удаление логов
sudo rm -rf /var/log/backup-manager

# Удаление из crontab
sudo crontab -e  # удалить строки с backup-manager
```

### Очистка временных файлов
```bash
# Очистка временных папок
sudo rm -rf /tmp/backup_manager_build
sudo rm -rf /tmp/backup_mount_*

# Очистка кеша пакетного менеджера
sudo apt autoremove && sudo apt autoclean  # Ubuntu/Debian
sudo yum autoremove && sudo yum clean all  # CentOS/RHEL
```

---

## Решение проблем установки

### Ошибка прав доступа
```bash
# Если возникают проблемы с правами
sudo chown root:root /usr/local/bin/backup-manager
sudo chmod 755 /usr/local/bin/backup-manager
```

### Проблемы с зависимостями
```bash
# Обновление списка пакетов
sudo apt update          # Ubuntu/Debian
sudo yum makecache       # CentOS/RHEL
sudo pacman -Sy          # Arch Linux

# Принудительная установка зависимостей
sudo apt install --fix-missing -y packagename
```

### Ошибки сетевых утилит
```bash
# Проверка модулей ядра для FUSE
sudo modprobe fuse

# Добавление в автозагрузку
echo 'fuse' | sudo tee -a /etc/modules

# Проверка SMB поддержки
sudo modprobe cifs
```

Для получения дополнительной помощи обращайтесь к разделу [Troubleshooting](TROUBLESHOOTING.md) или создавайте Issues на GitHub.