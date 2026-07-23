#!/bin/zsh
cd "$(dirname "$0")" || exit 1

restore_sleep() {
  /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
}

restore_volume() {
  if [[ -n "${ORIGINAL_VOLUME:-}" ]]; then
    /usr/bin/sudo -u "$TARGET_USER" /usr/bin/osascript -e "set volume output volume $ORIGINAL_VOLUME" >/dev/null 2>&1 || true
  fi
}

restore_system_state() {
  restore_sleep
  restore_volume
}

fail() {
  print -u2 -- "\n오류: $1"
  exit 1
}

if [[ "$EUID" -ne 0 ]]; then
  print "관리자 권한이 필요합니다. 아래 명령으로 다시 실행하세요:"
  print "  sudo ./watch.sh"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$(/usr/bin/stat -f%Su /dev/console)}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" || "$TARGET_USER" == "loginwindow" ]]; then
  fail "macOS에 로그인한 사용자 계정을 찾을 수 없습니다. Finder에서 터미널을 열고 다시 실행하세요."
fi

TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
TARGET_HOME="${TARGET_HOME:-/Users/$TARGET_USER}"
ALERT_DIR="$PWD"
CONFIG_PATH="$ALERT_DIR/config.json"
DEFAULT_RECORDING_DIR="$TARGET_HOME/Movies/MacBook Theft Alarm"

run_as_target_user() {
  /usr/bin/sudo -u "$TARGET_USER" \
    HOME="$TARGET_HOME" \
    PATH="$TARGET_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@"
}

find_ngrok() {
  local candidate
  for candidate in \
    "$TARGET_HOME/.local/bin/ngrok" \
    /opt/homebrew/bin/ngrok \
    /usr/local/bin/ngrok \
    /usr/bin/ngrok; do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_command_line_tools() {
  SWIFT_PATH="$(/usr/bin/xcrun --find swift 2>/dev/null || true)"
  if [[ -n "$SWIFT_PATH" && -x "$SWIFT_PATH" ]]; then
    return
  fi

  print "\nXcode Command Line Tools가 없어 macOS 설치 창을 엽니다."
  print "설치를 완료한 뒤 이 명령을 다시 실행하세요: sudo ./watch.sh"
  /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  exit 1
}

install_ngrok() {
  local brew_path=""
  local architecture download_url temporary_dir

  for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew_path" ]]; then
      print "\nngrok이 없어 Homebrew로 설치합니다."
      run_as_target_user "$brew_path" install ngrok || fail "ngrok 자동 설치에 실패했습니다. 오류를 해결한 뒤 다시 실행하세요."
      return
    fi
  done

  case "$(/usr/bin/uname -m)" in
    arm64) architecture="arm64" ;;
    x86_64) architecture="amd64" ;;
    *) fail "이 Mac의 CPU 종류에서는 ngrok 자동 설치를 지원하지 않습니다." ;;
  esac

  download_url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-${architecture}.zip"
  temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macbook-theft-alarm-ngrok.XXXXXX")" || fail "ngrok 설치용 임시 폴더를 만들지 못했습니다."

  print "\nngrok이 없어 공식 배포본을 내려받아 설치합니다."
  if ! /usr/bin/curl --fail --location --silent --show-error "$download_url" --output "$temporary_dir/ngrok.zip" || \
     ! /usr/bin/unzip -q "$temporary_dir/ngrok.zip" -d "$temporary_dir" || \
     [[ ! -x "$temporary_dir/ngrok" ]]; then
    /bin/rm -rf "$temporary_dir"
    fail "ngrok 자동 설치에 실패했습니다. 인터넷 연결을 확인한 뒤 다시 실행하세요."
  fi

  /bin/mkdir -p "$TARGET_HOME/.local/bin"
  /bin/mv "$temporary_dir/ngrok" "$TARGET_HOME/.local/bin/ngrok"
  /usr/sbin/chown "$TARGET_USER" "$TARGET_HOME/.local/bin"
  /usr/sbin/chown "$TARGET_USER" "$TARGET_HOME/.local/bin/ngrok"
  /bin/chmod 755 "$TARGET_HOME/.local/bin/ngrok"
  /bin/rm -rf "$temporary_dir"
}

ensure_ngrok() {
  NGROK_PATH="$(find_ngrok || true)"
  if [[ -z "$NGROK_PATH" ]]; then
    install_ngrok
    NGROK_PATH="$(find_ngrok || true)"
    [[ -n "$NGROK_PATH" ]] || fail "ngrok 설치 뒤 실행 파일을 찾지 못했습니다."
  fi

  local ngrok_config
  for ngrok_config in \
    "$TARGET_HOME/Library/Application Support/ngrok/ngrok.yml" \
    "$TARGET_HOME/.config/ngrok/ngrok.yml" \
    "$TARGET_HOME/.ngrok2/ngrok.yml"; do
    if [[ -f "$ngrok_config" ]] && /usr/bin/grep -q '^[[:space:]]*authtoken:' "$ngrok_config"; then
      return
    fi
  done

  if [[ ! -t 0 ]]; then
    fail "ngrok 로그인 토큰이 필요합니다. 터미널에서 sudo ./watch.sh를 실행해 토큰을 입력하세요."
  fi

  print "\nngrok 계정 로그인 토큰이 필요합니다."
  print "https://dashboard.ngrok.com/get-started/your-authtoken 에서 토큰을 복사해 붙여넣으세요."
  local ngrok_authtoken=""
  while [[ -z "$ngrok_authtoken" ]]; do
    read -r "ngrok_authtoken?ngrok authtoken: "
    [[ -z "$ngrok_authtoken" ]] && print "토큰을 비워둘 수 없습니다."
  done

  run_as_target_user "$NGROK_PATH" config add-authtoken "$ngrok_authtoken" || fail "ngrok 로그인 토큰 저장에 실패했습니다."
}

create_first_run_config() {
  [[ -f "$CONFIG_PATH" ]] && return
  [[ -f "$ALERT_DIR/config.example.json" ]] || fail "config.example.json을 찾을 수 없습니다."
  [[ -t 0 ]] || fail "최초 설정이 필요합니다. 터미널에서 sudo ./watch.sh를 실행하세요."

  print "\n처음 실행 설정을 시작합니다."
  print "녹화 프레임은 다음 폴더에 저장합니다: $DEFAULT_RECORDING_DIR"
  run_as_target_user /bin/mkdir -p "$DEFAULT_RECORDING_DIR" || fail "기본 녹화 폴더를 만들지 못했습니다."

  print "\n감시 링크를 받을 메신저 웹훅 주소를 입력하세요."
  print "Slack, Telegram, Discord 웹훅 또는 일반 웹훅 URL을 사용할 수 있습니다."
  local webhook_url=""
  while [[ -z "$webhook_url" ]]; do
    read -r "webhook_url?notification_webhook_url: "
    [[ -z "$webhook_url" ]] && print "웹훅 주소를 비워둘 수 없습니다."
  done

  local notification_recipient=""
  if [[ "$webhook_url" == *"api.telegram.org/bot"* ]]; then
    print "Telegram을 선택했습니다. 링크를 받을 chat_id를 입력하세요."
    while [[ -z "$notification_recipient" ]]; do
      read -r "notification_recipient?Telegram chat_id: "
      [[ -z "$notification_recipient" ]] && print "chat_id를 비워둘 수 없습니다."
    done
  fi

  local temporary_config="$(/usr/bin/mktemp "$ALERT_DIR/.config.plist.XXXXXX")" || fail "설정 파일을 저장하지 못했습니다."
  /bin/cp "$ALERT_DIR/config.example.json" "$temporary_config"
  /usr/bin/plutil -convert xml1 "$temporary_config" && \
    /usr/bin/plutil -replace recording_dir -string "$DEFAULT_RECORDING_DIR" "$temporary_config" && \
    /usr/bin/plutil -replace notification_webhook_url -string "$webhook_url" "$temporary_config" && \
    /usr/bin/plutil -replace notification_recipient -string "$notification_recipient" "$temporary_config" && \
    /usr/bin/plutil -convert json -o "$CONFIG_PATH" "$temporary_config" || \
    fail "최초 설정 파일을 만들지 못했습니다."
  /bin/rm "$temporary_config"
  /usr/sbin/chown "$TARGET_USER" "$CONFIG_PATH"
  /bin/chmod 600 "$CONFIG_PATH"
  print "첫 실행 설정을 저장했습니다."
}

ensure_command_line_tools
ensure_ngrok
create_first_run_config

ORIGINAL_VOLUME="$(run_as_target_user /usr/bin/osascript -e 'output volume of (get volume settings)' 2>/dev/null || true)"

print "\n뚜껑을 닫아도 경보가 유지되도록 잠자기를 막습니다."
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -g | /usr/bin/grep SleepDisabled || true
trap restore_system_state EXIT INT TERM

run_as_target_user /usr/bin/env \
  ALERT_DIR="$ALERT_DIR" \
  ALERT_TERMINAL_PROGRAM="${TERM_PROGRAM:-}" \
  NGROK_PATH="$NGROK_PATH" \
  "$SWIFT_PATH" run alert live
