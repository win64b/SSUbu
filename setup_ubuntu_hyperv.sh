#!/usr/bin/env bash

# Останавливать выполнение скрипта при возникновении любых ошибок
set -e

# Цветовые константы для наглядного вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Сброс цвета

# Функции для логирования
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_err() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 1. Проверка запуска от имени root (или через sudo)
if [ "$EUID" -ne 0 ]; then
    log_err "Этот скрипт должен запускаться только от root (или через sudo)."
    exit 1
fi

log_info "Начало первоначальной настройки Ubuntu Server 24.04 LTS для Hyper-V..."

# 2. Настройка часового пояса
log_info "Установка часового пояса Europe/Moscow..."
timedatectl set-timezone Europe/Moscow
log_info "Текущее системное время: $(date)"

# 3. Отключение режимов сна для обеспечения стабильности сервера
log_info "Отключение режимов сна (маскирование sleep, suspend, hibernate, hybrid-sleep)..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# 4. Обновление системы
log_info "Обновление списков пакетов (apt update)..."
apt-get update

log_info "Полное обновление системы (apt full-upgrade)..."
apt-get full-upgrade -y

# 5. Установка пакетов интеграции Hyper-V и необходимых утилит
# Формируем полный список требуемых пакетов
REQUIRED_PACKAGES=(
    linux-image-virtual
    linux-tools-virtual
    linux-cloud-tools-virtual
    "linux-cloud-tools-$(uname -r)"
    mc
    htop
    btop
    curl
    wget
    net-tools
    git
)

PACKAGES_TO_INSTALL=()

log_info "Проверка наличия уже установленных пакетов..."
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        PACKAGES_TO_INSTALL+=("$pkg")
    else
        echo -e "  - Пакет ${YELLOW}$pkg${NC} уже установлен, установка не требуется."
    fi
done

# Устанавливаем только недостающие пакеты одной командой
if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
    log_info "Установка недостающих пакетов: ${PACKAGES_TO_INSTALL[*]}"
    apt-get install -y "${PACKAGES_TO_INSTALL[@]}"
else
    log_info "Все необходимые пакеты уже установлены в системе."
fi

# 6. Активация и запуск служб интеграции Hyper-V
log_info "Активация и запуск служб интеграции Hyper-V..."
HV_SERVICES=(
    hv-kvp-daemon
    hv-vss-daemon
    hv-fcopy-daemon
)

for svc in "${HV_SERVICES[@]}"; do
    log_info "Включение и запуск службы: $svc..."
    systemctl enable --now "$svc"
done

# 7. Настройка глобального алиаса для всех пользователей
BASHRC_FILE="/etc/bash.bashrc"
ALIAS_STR="alias update='sudo apt update && sudo apt upgrade -y'"

log_info "Настройка глобального алиаса 'update' в файле $BASHRC_FILE..."
if ! grep -q "alias update=" "$BASHRC_FILE"; then
    echo "" >> "$BASHRC_FILE"
    echo "# Глобальный алиас для быстрого обновления системы" >> "$BASHRC_FILE"
    echo "$ALIAS_STR" >> "$BASHRC_FILE"
    log_info "Алиас успешно добавлен."
else
    log_info "Алиас 'update' уже настроен в $BASHRC_FILE."
fi

# 8. Завершение работы и предложение о перезагрузке
log_info "Настройка ноды успешно завершена!"
echo ""
echo -e "${YELLOW}======================================================================${NC}"
echo -e "${GREEN}Для применения обновленного ядра и корректной работы всех служб${NC}"
echo -e "${GREEN}интеграции Hyper-V настоятельно рекомендуется перезагрузить сервер.${NC}"
echo -e "${YELLOW}======================================================================${NC}"

# Проверка на интерактивный режим терминала, чтобы не блокировать CI/CD или автоматические скрипты
if [ -t 0 ]; then
    read -p "Перезагрузить сервер прямо сейчас? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        log_info "Инициируется перезагрузка системы..."
        reboot
    else
        log_info "Перезагрузка отложена. Пожалуйста, выполните 'sudo reboot' вручную."
    fi
else
    log_info "Скрипт запущен в неинтерактивном режиме. Предложение о перезагрузке пропущено."
    log_info "Пожалуйста, запланируйте перезагрузку ('sudo reboot') в удобное время."
fi
