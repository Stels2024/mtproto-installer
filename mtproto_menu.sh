cat > /root/mtproto_menu.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

NAME="mtproto"
IMAGE="telegrammessenger/proxy:latest"
ENV_FILE="/root/mtproto.env"
LINK_SCRIPT="/root/get_mtproto_link.sh"

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запусти от root: sudo -i"
    exit 1
  fi
}

pause() { read -r -p "Нажми Enter..." _; }

auto_ip() {
  local ip=""
  ip="$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -n 1 || true)"
  fi
  echo "$ip"
}

port_busy() {
  local p="$1"
  ss -lntup 2>/dev/null | grep -qE ":${p}\b"
}

# Secret (32 hex) без xxd
gen_secret() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
    return 0
  fi
  echo "ERROR: нет python3/openssl для генерации secret" >&2
  return 1
}

is_hex32() {
  [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

disable_ookla_repo_if_present() {
  local f="/etc/apt/sources.list.d/ookla_speedtest-cli.list"
  if [[ -f "$f" ]]; then
    mv "$f" "${f}.disabled" || true
    echo "Отключил Ookla repo: ${f}.disabled"
  fi
}

apt_update_safe() {
  if apt update -y; then
    return 0
  fi
  echo "apt update упал. Пытаюсь авто-исправление (Ookla repo)..."
  disable_ookla_repo_if_present
  apt update -y
}

install_docker_if_needed() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker не найден — ставлю..."
    apt_update_safe
    apt install -y docker.io
    systemctl enable --now docker
  else
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
}

ufw_open_port() {
  local p="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${p}/tcp" >/dev/null
    echo "ufw: открыт порт ${p}/tcp"
  else
    echo "ufw не активен/не установлен — пропускаю."
  fi
}

save_env() {
  local ip="$1" port="$2" secret="$3"
  cat > "$ENV_FILE" <<EOF
IP="${ip}"
PORT="${port}"
SECRET="${secret}"
EOF
  chmod 600 "$ENV_FILE"
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    IP=""
    PORT=""
    SECRET=""
  fi
}

write_link_script() {
  cat > "$LINK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="/root/mtproto.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Нет /root/mtproto.env — сначала установи MTProto через меню."
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

echo "MTProto:"
echo "Server: ${IP}"
echo "Port:   ${PORT}"
echo "Secret: ${SECRET}"
echo
echo "tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
echo "https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
EOF
  chmod +x "$LINK_SCRIPT"
}

run_container() {
  local port="$1" secret="$2"
  docker pull "$IMAGE" >/dev/null

  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi

  docker run -d --name "$NAME" \
    --restart=always \
    -p "${port}:443" \
    -e SECRET="${secret}" \
    "$IMAGE" >/dev/null
}

wizard_install() {
  need_root
  install_docker_if_needed
  load_env

  local detected_ip ip port secret

  detected_ip="$(auto_ip)"
  local default_ip="${detected_ip:-${IP:-}}"

  echo
  echo "=== Установка/обновление MTProto ==="
  echo

  # ВАЖНО: не показываем реальный IP в подсказке
  read -r -p "IP сервера [авто]: " ip
  ip="${ip:-$default_ip}"
  if [[ -z "$ip" ]]; then
    echo "Не смог определить IP автоматически. Введи вручную."
    read -r -p "IP сервера: " ip
    ip="${ip:-}"
  fi
  if [[ -z "$ip" ]]; then
    echo "IP пустой — отмена."
    pause
    return
  fi

  local suggested_port="443"
  if port_busy 443; then suggested_port="8443"; fi
  read -r -p "Порт (наружный) [${PORT:-$suggested_port}]: " port
  port="${port:-${PORT:-$suggested_port}}"

  if port_busy "$port"; then
    echo "⚠️ Порт ${port} уже занят. Выбери другой (например 8443/2053/2083/2087/2096)."
    pause
    return
  fi

  echo
  echo "Secret нужен в HEX (32 символа)."
  echo "1) Сгенерировать автоматически"
  echo "2) Ввести вручную"
  read -r -p "Выбор [1/2] (по умолчанию 1): " ch
  ch="${ch:-1}"

  if [[ "$ch" == "2" ]]; then
    read -r -p "Вставь SECRET (32 hex): " secret
    secret="$(echo "$secret" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if ! is_hex32 "$secret"; then
      echo "❌ Неверный формат. Нужно ровно 32 hex символа."
      pause
      return
    fi
  else
    secret="$(gen_secret)"
  fi

  echo
  echo "Запускаю контейнер ${NAME} на порт ${port}..."
  run_container "$port" "$secret"

  echo
  read -r -p "Открыть порт ${port}/tcp в ufw (если включен)? [Y/n]: " fw
  fw="${fw:-Y}"
  if [[ "$fw" =~ ^[Yy]$ ]]; then
    ufw_open_port "$port"
  fi

  save_env "$ip" "$port" "$secret"
  write_link_script

  echo
  echo "✅ Готово. Данные/ссылка:"
  "$LINK_SCRIPT"
  echo
  echo "Логи: docker logs -f ${NAME}"
  pause
}

show_info() {
  need_root
  write_link_script
  echo
  "$LINK_SCRIPT"
  echo
  pause
}

restart_proxy() {
  need_root
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker restart "$NAME" >/dev/null
    echo "Перезапущено: $NAME"
  else
    echo "Контейнер $NAME не найден."
  fi
  pause
}

logs_follow() {
  need_root
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker logs -f "$NAME"
  else
    echo "Контейнер $NAME не найден."
    pause
  fi
}

stop_remove() {
  need_root
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker rm -f "$NAME" >/dev/null
    echo "Удалено: $NAME"
  else
    echo "Контейнер $NAME не найден."
  fi
  pause
}

main_menu() {
  need_root
  while true; do
    echo
    echo "=============================="
    echo " MTProto Proxy Меню"
    echo "=============================="
    echo "1) Установить/обновить (ввод IP/порт/secret)"
    echo "2) Показать ссылку/данные"
    echo "3) Перезапустить прокси"
    echo "4) Логи (docker logs -f)"
    echo "5) Остановить и удалить прокси"
    echo "0) Выход"
    echo
    read -r -p "Выбор: " choice
    case "$choice" in
      1) wizard_install ;;
      2) show_info ;;
      3) restart_proxy ;;
      4) logs_follow ;;
      5) stop_remove ;;
      0) exit 0 ;;
      *) echo "Неверно"; pause ;;
    esac
  done
}

main_menu
BASH

chmod +x /root/mtproto_menu.sh
exec /root/mtproto_menu.sh
