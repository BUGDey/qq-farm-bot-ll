#!/usr/bin/env bash
set -Eeuo pipefail

# QQ Farm Bot + NapCat Linux 管理脚本
# 放置方式：脚本放在项目根目录（与 core/、web/、package.json 同级）
# ./qq-farm.sh
# ./core/  ./web/  ./package.json
# ./napcat/                 NapCat 安装、配置和数据目录（脚本所在目录内新建）
# ./qq-miniapp-auth/       QQ 扫码授权服务（脚本所在目录内新建）

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# 兼容两种布局：脚本位于项目根内（当前仓库形态）或与 qq-farm-bot/ 目录同级
if [[ -d "$ROOT_DIR/core" && -f "$ROOT_DIR/package.json" ]]; then
  PROJECT_DIR="$ROOT_DIR"
elif [[ -d "$ROOT_DIR/qq-farm-bot" ]]; then
  PROJECT_DIR="$ROOT_DIR/qq-farm-bot"
else
  PROJECT_DIR="$ROOT_DIR/qq-farm-bot"
fi
NAPCAT_DIR="$ROOT_DIR/napcat"
AUTH_DIR="$ROOT_DIR/qq-miniapp-auth"
AUTH_REPO="https://github.com/liyangpengs/qq-miniapp-auth.git"
AUTH_TARBALL_URL="https://codeload.github.com/liyangpengs/qq-miniapp-auth/tar.gz/refs/heads/master"
STATE_FILE="$NAPCAT_DIR/manager-config.env"
TMPDIR="${TMPDIR:-/tmp}"
FARM_DATA="$PROJECT_DIR/core/data"
FARM_STORE="$FARM_DATA/store.json"
FARM_ADMIN="$FARM_DATA/admin.json"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
CONTAINER_NAME="qq-farm-bot"
SOURCE_PID="$PROJECT_DIR/app_linux.pid"
SOURCE_LOG="$PROJECT_DIR/app_linux.log"
SOURCE_ERR="$PROJECT_DIR/app_linux.error.log"

info(){ printf '\033[36m[INFO]\033[0m %s\n' "$*" >&2; }
ok(){ printf '\033[32m[OK]\033[0m %s\n' "$*" >&2; }
warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
need_project(){ [[ -d "$PROJECT_DIR" ]] || die "找不到项目目录：$PROJECT_DIR"; }

load_state(){
  mkdir -p "$NAPCAT_DIR"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  : "${API_ENDPOINT:=http://127.0.0.1:8787}"
  : "${API_SECRET:=}"
  : "${ONEBOT_PORT:=3000}"
  : "${NAPCAT_ROOT:=$NAPCAT_DIR}"
}

save_state(){
  umask 077
  cat > "$STATE_FILE" <<EOF
API_ENDPOINT=$(printf '%q' "$API_ENDPOINT")
API_SECRET=$(printf '%q' "$API_SECRET")
ONEBOT_PORT=$(printf '%q' "$ONEBOT_PORT")
ONEBOT_TOKEN=$(printf '%q' "$ONEBOT_TOKEN")
NAPCAT_ROOT=$(printf '%q' "${NAPCAT_ROOT:-$NAPCAT_DIR}")
EOF
}

read_settings(){
  load_state
  if [[ -z "$API_ENDPOINT" ]]; then read -r -p 'qq-miniapp-auth API 地址 [http://127.0.0.1:8787]: ' API_ENDPOINT; API_ENDPOINT="${API_ENDPOINT:-http://127.0.0.1:8787}"; fi
  if [[ -z "$API_SECRET" ]]; then read -r -p 'API_SIGNING_SECRET（必须与 qq-miniapp-auth 一致）: ' API_SECRET; API_SECRET="${API_SECRET:-qq-miniapp-auth-default-signing-secret}"; fi
  if [[ -z "$ONEBOT_TOKEN" ]]; then ONEBOT_TOKEN="qq-farm-$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32)"; fi
  [[ "$API_ENDPOINT" =~ ^https?:// ]] || die 'API 地址必须以 http:// 或 https:// 开头'
  save_state
}

run_pnpm(){
  if command -v corepack >/dev/null 2>&1; then corepack pnpm "$@"
  elif command -v pnpm >/dev/null 2>&1; then pnpm "$@"
  else die '需要 pnpm 或 corepack'; fi
}

source_running(){
  [[ -f "$SOURCE_PID" ]] || return 1
  local pid; pid="$(cat "$SOURCE_PID" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local cmd; cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  [[ "$cmd" == *"core/client.js"* ]]
}

start_source(){
  need_project; need node
  if source_running; then ok "源码已在后台运行，PID $(cat "$SOURCE_PID")"; return; fi
  rm -f "$SOURCE_PID"
  pushd "$PROJECT_DIR" >/dev/null
  run_pnpm install --frozen-lockfile
  run_pnpm -C web run build
  run_pnpm -C core run build:ts
  [[ -f core/client.js ]] || die '构建后找不到 core/client.js'
  : > "$SOURCE_LOG"; : > "$SOURCE_ERR"
  nohup node core/client.js >>"$SOURCE_LOG" 2>>"$SOURCE_ERR" </dev/null &
  local pid=$!
  echo "$pid" > "$SOURCE_PID"
  popd >/dev/null
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then die "源码进程启动后退出，请查看 $SOURCE_ERR"; fi
  ok "源码已后台启动，PID=$pid"
  info "标准日志：$SOURCE_LOG"
  info "错误日志：$SOURCE_ERR"
}

start_docker(){
  need_project; need docker
  docker info >/dev/null 2>&1 || die 'Docker 未运行或当前用户无权访问 Docker'
  docker compose -f "$COMPOSE_FILE" up -d --build
  ok 'Docker 已启动'
}

find_napcat_launcher(){
  find "${NAPCAT_ROOT:-$NAPCAT_DIR}" -type f \( -name napcat -o -name napcat.sh -o -name launcher.sh -o -name NapCat.AppImage \) -print -quit 2>/dev/null || true
}

install_napcat(){
  mkdir -p "$NAPCAT_DIR"
  local launcher; launcher="$(find_napcat_launcher)"
  [[ -n "$launcher" ]] && { printf '%s\n' "$launcher"; return; }
  need curl; need unzip
  info '下载 NapCat Linux 安装器…'
  local installer="$NAPCAT_DIR/napcat-installer.sh"
  curl -fL --connect-timeout 20 --max-time 1800 -o "$installer" 'https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh'
  chmod +x "$installer"
  info '开始运行 NapCat Linux 安装器（安装到当前用户目录；按提示完成 QQ/NapCat 初始化）'
  bash "$installer" --docker n --cli y --github-proxy 0
  launcher="$(find_napcat_launcher)"
  if [[ -z "$launcher" ]]; then
    warn "安装器已运行，但未在 $NAPCAT_DIR 找到启动器。请将 NapCat 根目录放到该目录或设置 NAPCAT_ROOT。"
  else
    local root; root="$(dirname "$(find "${NAPCAT_ROOT:-$NAPCAT_DIR}" -type f -name napcat.mjs -print -quit 2>/dev/null || true)")"
    if [[ -n "$root" && -f "$root/napcat.mjs" ]]; then NAPCAT_ROOT="$root"; save_state; fi
  fi
  printf '%s\n' "$launcher"
}

install_auth_service(){
  need_project; need curl; need tar; need node
  if [[ ! -d "$AUTH_DIR" ]]; then
    info '下载 qq-miniapp-auth 源码…'
    local tmp="$TMPDIR/qq-miniapp-auth.$$.tar.gz"
    curl -fL --connect-timeout 20 --max-time 1800 -o "$tmp" "$AUTH_TARBALL_URL"
    mkdir -p "$ROOT_DIR/.auth-extract"
    tar -xzf "$tmp" -C "$ROOT_DIR/.auth-extract"
    local extracted
    extracted="$(find "$ROOT_DIR/.auth-extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$extracted" ]] || die 'qq-miniapp-auth 源码解压失败'
    mv "$extracted" "$AUTH_DIR"
    rm -rf "$ROOT_DIR/.auth-extract" "$tmp"
  fi
  [[ -f "$AUTH_DIR/package.json" ]] || die "qq-miniapp-auth package.json 不存在：$AUTH_DIR"
  if [[ ! -f "$AUTH_DIR/.env" ]]; then
    if [[ -f "$AUTH_DIR/.env.example" ]]; then cp "$AUTH_DIR/.env.example" "$AUTH_DIR/.env"
    else : > "$AUTH_DIR/.env"; fi
  fi
  read_settings
  python3 - "$AUTH_DIR/.env" "$API_SECRET" "$ONEBOT_TOKEN" <<'PY'
import pathlib, re, sys
path, secret, onebot = sys.argv[1:]
p=pathlib.Path(path)
s=p.read_text(encoding='utf-8') if p.exists() else ''
values={
 'HOST':'127.0.0.1',
 'PORT':'8787',
 'NAPCAT_API_URL':'http://127.0.0.1:3000',
 'NAPCAT_TOKEN':onebot,
 'NAPCAT_OPEN_AUTH_PLUGIN_URL':'http://127.0.0.1:6099/plugin/qq-miniapp-openauth/api',
 'NAPCAT_OPEN_AUTH_PLUGIN_TOKEN':'',
 'NAPCAT_WEBUI_API_URL':'http://127.0.0.1:6099/api',
 'BRIDGE_HOST':'127.0.0.1',
 'BRIDGE_PORT':'9010',
 'API_SIGNING_SECRET':secret,
}
for key,value in values.items():
    line=f'{key}={value}'
    pattern=rf'^{re.escape(key)}=.*$'
    if re.search(pattern,s,re.M): s=re.sub(pattern,line,s,flags=re.M)
    else: s += ('' if not s or s.endswith('\n') else '\n') + line + '\n'
p.write_text(s,encoding='utf-8')
PY
  pushd "$AUTH_DIR" >/dev/null
  if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
  popd >/dev/null
  ok "qq-miniapp-auth 已准备：$AUTH_DIR"
}

start_auth_service(){
  install_auth_service
  local pid_file="$AUTH_DIR/qq-miniapp-auth.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then ok "qq-miniapp-auth 已在后台运行，PID $(cat "$pid_file")"; return; fi
  local log="$AUTH_DIR/qq-miniapp-auth.log"
  pushd "$AUTH_DIR" >/dev/null
  nohup npm start >>"$log" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" > "$pid_file"
  popd >/dev/null
  sleep 2
  kill -0 "$pid" 2>/dev/null || die "qq-miniapp-auth 启动失败，请查看 $log"
  ok "qq-miniapp-auth 已后台启动，PID=$pid，日志：$log"
}

install_napcat_plugin(){
  install_auth_service
  need curl
  local napcat_root
  napcat_root="${NAPCAT_ROOT:-$NAPCAT_DIR}"
  if [[ ! -f "$napcat_root/napcat.mjs" ]]; then
    local candidate
    candidate="$(find "$napcat_root" -type f -name napcat.mjs -print -quit 2>/dev/null || true)"
    [[ -n "$candidate" ]] && napcat_root="$(dirname "$candidate")"
  fi
  [[ -f "$napcat_root/napcat.mjs" ]] || die "找不到 NapCat 根目录中的 napcat.mjs：$napcat_root"
  [[ -d "$AUTH_DIR/napcat-openauth-plugin" ]] || die 'qq-miniapp-auth 中缺少 napcat-openauth-plugin'
  info '安装 qq-miniapp-openauth NapCat 插件…'
  local plugin_dir="$napcat_root/plugins/qq-miniapp-openauth"
  local plugin_cfg_dir="$napcat_root/config/plugins/qq-miniapp-openauth"
  mkdir -p "$plugin_dir" "$plugin_cfg_dir"
  cp -a "$AUTH_DIR/napcat-openauth-plugin/." "$plugin_dir/"
  local token
  token="$(grep -E '^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=' "$AUTH_DIR/.env" | head -n1 | cut -d= -f2- || true)"
  if [[ -z "$token" ]]; then token="$(node -e 'console.log(require("node:crypto").randomBytes(32).toString("base64"))')"; fi
  printf '{\n  "token": %s\n}\n' "$(printf '%s' "$token" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" > "$plugin_cfg_dir/config.json"
  chmod 600 "$plugin_cfg_dir/config.json"
  python3 - "$napcat_root/config/plugins.json" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); obj={}
if p.exists():
    try: obj=json.loads(p.read_text(encoding='utf-8'))
    except Exception: obj={}
obj['qq-miniapp-openauth']=True
p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY
  python3 - "$AUTH_DIR/.env" "$token" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); token=sys.argv[2]; s=p.read_text(encoding='utf-8')
line='NAPCAT_OPEN_AUTH_PLUGIN_TOKEN='+token
if re.search(r'^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=.*$',s,re.M): s=re.sub(r'^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=.*$',line,s,flags=re.M)
else: s += ('' if not s.endswith('\n') else '') + line+'\n'
p.write_text(s,encoding='utf-8')
PY
  if ! grep -Fq '"qq-miniapp-openauth"' "$napcat_root/napcat.mjs"; then
    grep -Fq '"napcat-plugin-qce"' "$napcat_root/napcat.mjs" || die 'napcat.mjs 中找不到官方插件白名单标记，拒绝自动修改'
    cp -a "$napcat_root/napcat.mjs" "$napcat_root/napcat.mjs.bak.$(date +%Y%m%d%H%M%S)"
    python3 - "$napcat_root/napcat.mjs" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
marker='"napcat-plugin-qce"'; plugin='"qq-miniapp-openauth"'; i=s.find(marker)
if i < 0: raise SystemExit('plugin whitelist marker not found')
s=s[:i+len(marker)]+',\n '+plugin+s[i+len(marker):]
p.write_text(s,encoding='utf-8')
PY
  fi

  NAPCAT_ROOT="$napcat_root"
  save_state
  ok "qq-miniapp-openauth 插件已安装到：$plugin_dir"
  ok '插件白名单和 plugins.json 已更新；请重启 NapCat 后验证插件状态。'
}

start_official_qq_mode(){
  need_project
  [[ -f "$PROJECT_DIR/start.sh" ]] || die "当前项目没有官方 start.sh：$PROJECT_DIR/start.sh"
  chmod +x "$PROJECT_DIR/start.sh"
  info '调用 QQ Farm Bot 官方 Linux QQ 扫码部署流程：start.sh 2'
  (cd "$PROJECT_DIR" && ./start.sh 2)
  ok '官方 QQ 扫码部署流程已结束；请按输出打开 NapCat WebUI 完成扫码。'
}

start_official_default_mode(){
  need_project
  [[ -f "$PROJECT_DIR/start.sh" ]] || die "当前项目没有官方 start.sh：$PROJECT_DIR/start.sh"
  chmod +x "$PROJECT_DIR/start.sh"
  info '调用 QQ Farm Bot 官方 Linux默认部署流程：start.sh 1'
  (cd "$PROJECT_DIR" && ./start.sh 1)
}


configure_onebot_file(){
  local file="$1"
  need python3
  python3 - "$file" "$ONEBOT_PORT" "$ONEBOT_TOKEN" <<'PY'
import json, sys
path, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(path, encoding='utf-8-sig') as f: obj=json.load(f)
except Exception:
    obj={}
network=obj.setdefault('network', {})
servers=network.setdefault('httpServers', [])
server=next((x for x in servers if x.get('name') == 'qq-miniapp-auth-onebot'), None)
if server is None:
    server={'name':'qq-miniapp-auth-onebot','enable':True,'host':'127.0.0.1','port':port,'token':token,'enableCors':False,'enableWebsocket':False,'messagePostFormat':'array','debug':False}
    servers.append(server)
else:
    server.update(enable=True, host='127.0.0.1', port=port, token=token)
for key in ('httpClients','websocketServers','websocketClients'):
    network.setdefault(key, [])
with open(path, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
}

configure_napcat(){
  read_settings
  NAPCAT_ROOT="${NAPCAT_ROOT:-$NAPCAT_DIR}"
  mapfile -t files < <(find_onebot_configs)
  if ((${#files[@]} == 0)); then
    mkdir -p "$NAPCAT_DIR/config"
    files=("$NAPCAT_DIR/config/onebot11.json")
  fi
  local file; for file in "${files[@]}"; do configure_onebot_file "$file"; done
  ok "NapCat OneBot HTTP 服务已配置：127.0.0.1:$ONEBOT_PORT"
  info "qq-miniapp-auth API 地址：$API_ENDPOINT"
}

update_farm_store(){
  local file="$1"
  need python3
  mkdir -p "$(dirname "$file")"
  python3 - "$file" "$API_ENDPOINT" "$API_SECRET" <<'PY'
import json, os, sys
path, endpoint, secret = sys.argv[1:]
try:
    with open(path, encoding='utf-8-sig') as f: obj=json.load(f)
except Exception:
    obj={}
login=obj.setdefault('loginSettings', {})
login.update(qqQrLogin=True, napCatEndpoint=endpoint, napCatSignature=secret)
tmp=path+'.tmp'
with open(tmp,'w',encoding='utf-8') as f:
    json.dump(obj,f,ensure_ascii=False,indent=2); f.write('\n')
os.replace(tmp,path)
PY
}

configure_source(){ read_settings; update_farm_store "$FARM_STORE"; ok '源码模式 QQ 扫码登录配置已写入 core/data/store.json'; }

configure_docker(){
  local host_ip="${NAPCAT_HOST_IP:-host.docker.internal}"
  local docker_api="http://${host_ip}:${ONEBOT_PORT}"
  local docker_env="$AUTH_DIR/.env.docker"
  cp "$AUTH_DIR/.env" "$docker_env"
  sed -i -E "s#^NAPCAT_API_URL=.*#NAPCAT_API_URL=$docker_api#" "$docker_env"
  local tmp="$TMPDIR/qq-farm-store.$$.json"
  if ! docker cp "$CONTAINER_NAME:/app/core/data/store.json" "$tmp" >/dev/null 2>&1; then echo '{}' > "$tmp"; fi
  update_farm_store "$tmp"
  docker cp "$tmp" "$CONTAINER_NAME:/app/core/data/store.json" >/dev/null
  docker restart "$CONTAINER_NAME" >/dev/null
  rm -f "$tmp"
  ok 'Docker 模式 QQ 扫码登录配置已写入并重启容器'
}

start_napcat(){
  local launcher="${1:-}"; launcher="${launcher:-$(find_napcat_launcher)}"
  if [[ -n "$launcher" ]]; then
    chmod +x "$launcher" 2>/dev/null || true
    nohup "$launcher" >/dev/null 2>&1 </dev/null &
    ok "NapCat 已后台启动：$launcher"
  else warn "未找到 NapCat 启动器，请检查 $NAPCAT_DIR"; fi
}

restart_napcat(){
  pkill -f 'napcat|NapCat|qq' 2>/dev/null || true
  sleep 2
  start_napcat
}

reset_admin(){
  need python3; mkdir -p "$FARM_DATA"
  local password="QqFarm!$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)"
  python3 - "$FARM_ADMIN" "$password" <<'PY'
import hashlib, json, os, secrets, sys
path, password=sys.argv[1:]
salt=secrets.token_hex(32)
digest=hashlib.pbkdf2_hmac('sha512', password.encode(), salt.encode(), 100000, 64).hex()
obj={'admin':{'username':'admin','password':salt+':'+digest,'createdAt':int(__import__('time').time()*1000),'mustChangePassword':False}}
tmp=path+'.tmp'
with open(tmp,'w') as f: json.dump(obj,f,indent=2); f.write('\n')
os.replace(tmp,path)
PY
  printf '\n管理员账号：admin\n管理员密码：%s\n\n' "$password"
}

menu(){
  while true; do
    printf '\n==== QQ Farm Bot + NapCat ====\n'
    printf '1. 源码后台启动\n2. Docker 启动\n3. 源码启动并自动安装/配置 NapCat 与 qq-miniapp-auth\n4. Docker 启动并自动安装/配置 NapCat 与 qq-miniapp-auth\n5. 重启 NapCat\n6. 重置管理员密码\n0. 退出\n'
    read -r -p '请选择：' choice
    case "$choice" in
      1) start_source;;
      2) start_docker;;
      3) launcher="$(install_napcat)"; install_auth_service; install_napcat_plugin; configure_napcat; configure_source; start_auth_service; start_source; start_napcat "$launcher";;
      4) launcher="$(install_napcat)"; install_auth_service; install_napcat_plugin; configure_napcat; start_docker; configure_docker; start_auth_service; start_napcat "$launcher";;
      5) restart_napcat;;
      6) reset_admin;;
      0) exit 0;;
      *) warn '无效选项';;
    esac
    read -r -p '按回车继续…' _
  done
}

need_project
menu
