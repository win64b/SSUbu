#!/usr/bin/env bash

# Строгий режим: остановка при ошибках
set -euo pipefail

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Логирование
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log_err "Скрипт необходимо запускать от имени root (через sudo)."
    exit 1
fi

# ================= ФУНКЦИИ НАСТРОЙКИ =================

setup_base() {
    log_info "Установка часового пояса Europe/Moscow..."
    timedatectl set-timezone Europe/Moscow
    timedatectl set-ntp true

    log_info "Отключение режимов сна (sleep, suspend, hibernate)..."
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1

    log_info "Обновление системы (apt update && full-upgrade)..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y

    REQUIRED_PACKAGES=(
        linux-image-virtual linux-tools-virtual linux-cloud-tools-virtual "linux-cloud-tools-$(uname -r)"
        mc htop btop curl wget net-tools git ufw fail2ban unattended-upgrades update-notifier-common
    )

    PACKAGES_TO_INSTALL=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            PACKAGES_TO_INSTALL+=("$pkg")
        fi
    done

    if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
        log_info "Установка пакетов: ${PACKAGES_TO_INSTALL[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES_TO_INSTALL[@]}"
    fi

    log_info "Активация служб Hyper-V и fail2ban..."
    for svc in hv-kvp-daemon hv-vss-daemon hv-fcopy-daemon fail2ban; do
        systemctl enable --now "$svc" || log_warn "Служба $svc недоступна."
    done
}

setup_firewall() {
    log_info "Настройка UFW (Firewall)..."
    # Убеждаемся, что UFW установлен (если пользователь выбрал только пункт меню 2)
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
    fi

    ufw allow OpenSSH
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
    log_info "UFW активирован. Разрешен только OpenSSH (порт 22)."
}

setup_security_hardening() {
    log_info "Харденинг SSH (запрет root-логина и пустых паролей)..."
    SSH_CONF="/etc/ssh/sshd_config.d/99-custom-hardening.conf"
    cat <<EOF > "$SSH_CONF"
PermitRootLogin no
PermitEmptyPasswords no
X11Forwarding no
EOF
    systemctl restart ssh || log_warn "Не удалось перезапустить SSH."

    log_info "Тюнинг sysctl (защита от spoofing, SYN-flood)..."
    SYSCTL_CONF="/etc/sysctl.d/99-security.conf"
    cat <<EOF > "$SYSCTL_CONF"
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
EOF
    sysctl -p "$SYSCTL_CONF" > /dev/null

    log_info "Включение unattended-upgrades..."
    dpkg-reconfigure -f noninteractive unattended-upgrades
}

setup_misc() {
    BASHRC_FILE="/etc/bash.bashrc"
    ALIAS_STR="alias update='sudo apt update && sudo apt full-upgrade -y && sudo apt autoremove --purge -y'"
    
    if ! grep -q "alias update=" "$BASHRC_FILE"; then
        echo -e "\n# Быстрое обновление системы\n$ALIAS_STR" >> "$BASHRC_FILE"
        log_info "Глобальный алиас 'update' добавлен."
    fi

    log_info "Очистка кэша APT..."
    apt-get autoremove --purge -y
    apt-get clean
}

prompt_reboot() {
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "${GREEN}Настройка завершена. Настоятельно рекомендуется перезагрузить сервер.${NC}"
    echo -e "${YELLOW}======================================================================${NC}"
    read -p "Перезагрузить сервер прямо сейчас? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        log_info "Инициируется перезагрузка..."
        reboot
    else
        log_info "Перезагрузка отложена."
    fi
}

run_full_setup() {
    setup_base
    setup_firewall
    setup_security_hardening
    setup_misc
    prompt_reboot
}

# ================= МЕНЮ =================

show_menu() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${GREEN}  Мастер настройки Ubuntu 24.04 LTS (Hyper-V)${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo "1. Выполнить полную настройку (Base + Security + UFW + Hyper-V)"
    echo "2. Включить и настроить только Firewall (UFW)"
    echo "3. Выход"
    echo -e "${CYAN}====================================================${NC}"
    
    # Защита от запуска через 'curl | bash' без терминала
    if [ ! -t 0 ]; then
        log_err "Скрипт запущен без интерактивного терминала (возможно через пайп). Выход."
        exit 1
    fi

    read -p "Выберите действие [1-3]: " choice

    case "$choice" in
        1)
            echo ""
            log_info "Запуск полной настройки..."
            run_full_setup
            ;;
        2)
            echo ""
            log_info "Запуск настройки Firewall..."
            setup_firewall
            ;;
        3)
            echo ""
            log_info "Выход из скрипта."
            exit 0
            ;;
        *)
            echo -e "${RED}Ошибка: Неверный выбор.${NC} Нажмите Enter, чтобы продолжить..."
            read -r
            show_menu
            ;;
    esac
}

# Запуск меню
show_menu
