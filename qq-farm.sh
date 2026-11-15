#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# 出错时打印是哪条命令失败的，避免脚本毫无提示地静默退出
# 只在最外层打印（子 shell 里的同一失败会再冒泡到外层，重复打印没有意义）
trap 'rc=$?; if [[ ${BASH_SUBSHELL:-0} -eq 0 ]]; then printf "\033[31m[FAIL]\033[0m 命令执行失败（退出码 %s）：%s\n" "$rc" "$BASH_COMMAND" >&2; printf "\033[31m[FAIL]\033[0m 请把上面这行命令的输出一起发出来，方便定位问题。\n" >&2; fi' ERR

# QQ Farm Bot + NapCat Linux 一键管理脚本
# 放置方式：脚本放在项目根目录（与 core/、web/、package.json 同级）
# ./qq-farm.sh
# ./core/  ./web/  ./package.json
# ./napcat/                 NapCat 安装包、配置、日志、状态（脚本所在目录内新建）
# ./qq-miniapp-auth/        QQ 扫码授权服务（脚本所在目录内新建）
#
# NapCat 版本跟随 BUGDey/qq-farm-bot：v4.18.19

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
AUTH_TARBALL_URL="${AUTH_TARBALL_URL:-https://codeload.github.com/liyangpengs/qq-miniapp-auth/tar.gz/refs/heads/master}"
STATE_FILE="$NAPCAT_DIR/manager-config.env"
SCRIPT_VERSION="2026-11-16.2"
TMPDIR="${TMPDIR:-/tmp}"
FARM_DATA="$PROJECT_DIR/core/data"
FARM_STORE="$FARM_DATA/store.json"
FARM_ADMIN="$FARM_DATA/admin.json"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
CONTAINER_NAME="qq-farm-bot"
SOURCE_PID="$PROJECT_DIR/app_linux.pid"
SOURCE_LOG="$PROJECT_DIR/app_linux.log"
SOURCE_ERR="$PROJECT_DIR/app_linux.error.log"

# NapCat 版本（与 BUGDey/qq-farm-bot 保持一致）
NAPCAT_VERSION="${NAPCAT_VERSION:-v4.18.19}"
NAPCAT_IMAGE="${NAPCAT_IMAGE:-mlikiowa/napcat-docker:v4.18.19}"
NAPCAT_CONTAINER="${NAPCAT_CONTAINER:-qq-farm-napcat}"
QQ_APP_DIR="${QQ_APP_DIR:-/opt/QQ/resources/app}"
NAPCAT_LOG="$NAPCAT_DIR/napcat.log"
NAPCAT_PID="$NAPCAT_DIR/napcat.pid"

info(){ printf '\033[36m[INFO]\033[0m %s\n' "$*" >&2; }
ok(){ printf '\033[32m[OK]\033[0m %s\n' "$*" >&2; }
warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
need_project(){ [[ -d "$PROJECT_DIR" ]] || die "找不到项目目录：$PROJECT_DIR"; }

# 生成随机字母数字串。
# 注意：不要写成 `tr ... </dev/urandom | head -c N`——head 读够就退出会让 tr 收到
# SIGPIPE 而失败，配合 pipefail + set -e 会让脚本毫无提示地静默退出。
# 这里先取固定长度的随机源，再用 bash 字符串截断，保证管道末端不会被提前关闭。
rand_alnum(){
  local n="${1:-32}" raw=''
  raw="$(head -c 512 /dev/urandom 2>/dev/null | base64 | tr -d '\n+/=')" || raw=''
  if [[ -z "$raw" ]]; then
    raw="$(date +%s%N)$$${RANDOM}${RANDOM}${RANDOM}"
  fi
  printf '%s' "${raw:0:n}"
}

if [[ ${EUID:-0} -eq 0 ]]; then IS_ROOT=1; else IS_ROOT=0; fi
as_root(){
  if [[ "$IS_ROOT" -eq 1 ]]; then "$@"; else sudo "$@"; fi
}
require_root_ability(){
  if [[ "$IS_ROOT" -eq 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die '当前不是 root 且没有 sudo，无法安装系统级 NapCat/LinuxQQ'
  fi
}

# ---------------------------------------------------------------- 状态与配置

load_state(){
  mkdir -p "$NAPCAT_DIR"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  : "${API_ENDPOINT:=http://127.0.0.1:8787}"
  : "${API_SECRET:=qq-miniapp-auth-default-signing-secret}"
  : "${ONEBOT_PORT:=3000}"
  : "${ONEBOT_TOKEN:=}"
  : "${NAPCAT_ROOT:=}"
  : "${NAPCAT_MODE:=}"
}

save_state(){
  umask 077
  cat > "$STATE_FILE" <<EOF
API_ENDPOINT=$(printf '%q' "$API_ENDPOINT")
API_SECRET=$(printf '%q' "$API_SECRET")
ONEBOT_PORT=$(printf '%q' "$ONEBOT_PORT")
ONEBOT_TOKEN=$(printf '%q' "$ONEBOT_TOKEN")
NAPCAT_ROOT=$(printf '%q' "${NAPCAT_ROOT:-}")
NAPCAT_MODE=$(printf '%q' "${NAPCAT_MODE:-}")
EOF
}

# 全自动：不再交互提问，全部有默认值，可用环境变量覆盖
read_settings(){
  load_state
  API_ENDPOINT="${API_ENDPOINT:-http://127.0.0.1:8787}"
  API_SECRET="${API_SECRET:-qq-miniapp-auth-default-signing-secret}"
  ONEBOT_PORT="${ONEBOT_PORT:-3000}"
  if [[ -z "${ONEBOT_TOKEN:-}" ]]; then
    ONEBOT_TOKEN="qq-farm-$(rand_alnum 32)"
  fi
  [[ "$API_ENDPOINT" =~ ^https?:// ]] || die 'API 地址必须以 http:// 或 https:// 开头'
  save_state
}

# ---------------------------------------------------------------- 通用下载

fetch_to(){
  local dest="$1"; shift
  local url
  for url in "$@"; do
    [[ -n "$url" ]] || continue
    info "下载：$url"
    if curl -fL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 3600 -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return 0
    fi
    warn "该地址下载失败，尝试下一个"
  done
  rm -f "$dest.part"
  return 1
}

napcat_zip_urls(){
  local v="$NAPCAT_VERSION"
  [[ -n "${NAPCAT_ZIP_URL:-}" ]] && printf '%s\n' "$NAPCAT_ZIP_URL"
  printf '%s\n' \
    "https://ghfast.top/https://github.com/XingYunStar/NapCatQQ/releases/download/$v/NapCat.Shell.zip" \
    "https://gh-proxy.com/https://github.com/XingYunStar/NapCatQQ/releases/download/$v/NapCat.Shell.zip" \
    "https://ghproxy.net/https://github.com/XingYunStar/NapCatQQ/releases/download/$v/NapCat.Shell.zip" \
    "https://github.com/XingYunStar/NapCatQQ/releases/download/$v/NapCat.Shell.zip"
}

pc_config_urls(){
  printf '%s\n' \
    "https://qq-web.cdn-go.cn/im.qq.com_new/latest/rainbow/pcConfig.json" \
    "https://im.qq.com/proxy/domain/qq-web.cdn-go.cn/im.qq.com_new/latest/rainbow/pcConfig.json"
}

# ---------------------------------------------------------------- 源码 / Docker

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
  kill -0 "$pid" 2>/dev/null || die "源码进程启动后退出，请查看 $SOURCE_ERR"
  ok "源码已后台启动，PID=$pid"
  info "标准日志：$SOURCE_LOG"
  info "错误日志：$SOURCE_ERR"
}

compose_up(){
  need_project; need docker
  docker info >/dev/null 2>&1 || die 'Docker 未运行或当前用户无权访问 Docker'
  # 优先用 compose 插件；没有插件就用独立的 docker-compose 命令
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" up -d --build
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" up -d --build
  else
    die '未安装 Docker Compose。请安装 compose 插件后重试：
  apt install docker-compose-plugin    # Debian/Ubuntu
  dnf install docker-compose-plugin    # Fedora/RHEL
  或者改用选项 1（源码启动）'
  fi
}

start_docker(){
  compose_up
  ok 'Docker 已启动'
}

# ---------------------------------------------------------------- LinuxQQ 客户端

# 从官方 pcConfig.json 解析当前 LinuxQQ 下载地址；也可用 LINUXQQ_DEB_URL 直接指定
resolve_linuxqq_url(){
  local fmt="$1"
  if [[ -n "${LINUXQQ_DEB_URL:-}" ]]; then
    printf '%s\n' "$LINUXQQ_DEB_URL"
    return 0
  fi
  local cfg="$TMPDIR/qq-pcConfig.$$.json"
  local urls=()
  mapfile -t urls < <(pc_config_urls)
  fetch_to "$cfg" "${urls[@]}" || { rm -f "$cfg"; return 1; }
  local arch url
  arch="$(uname -m)"
  url="$(node -e '
const fs = require("fs");
const [cfgPath, arch, fmt] = process.argv.slice(1);
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
const linux = cfg.Linux || {};
const arm = /^(aarch64|arm64)$/.test(arch);
const section = arm ? linux.armDownloadUrl : linux.x64DownloadUrl;
if (!section) process.exit(2);
const url = section[fmt] || section.deb || section.rpm || section.appimage;
if (!url) process.exit(3);
process.stdout.write(url);
' "$cfg" "$arch" "$fmt" 2>/dev/null || true)"
  rm -f "$cfg"
  [[ -n "$url" ]] || return 1
  printf '%s\n' "$url"
}

install_pkgs(){
  (($#)) || return 0
  if command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update -qq || true
    as_root apt-get install -y "$@" || return 1
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y "$@" || return 1
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y "$@" || return 1
  else
    warn '未识别的包管理器，跳过系统依赖安装'
  fi
}

install_qq_client(){
  if [[ -x /opt/QQ/qq ]]; then
    ok '已检测到 LinuxQQ：/opt/QQ/qq'
    return 0
  fi
  require_root_ability
  local fmt='deb'
  if ! command -v dpkg >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then fmt='rpm'; fi
  local url
  url="$(resolve_linuxqq_url "$fmt" || true)"
  if [[ -z "$url" ]]; then
    die '无法获取 LinuxQQ 下载地址。可执行前设置 LINUXQQ_DEB_URL=<deb 直链> 后重试'
  fi
  info "LinuxQQ 安装包：$url"
  local pkg="$TMPDIR/linuxqq.$$.$fmt"
  fetch_to "$pkg" "$url" || die "LinuxQQ 下载失败：$url"
  info '安装 LinuxQQ 运行依赖…'
  install_pkgs curl unzip xvfb libnss3 libgbm1 >/dev/null 2>&1 || warn '部分依赖安装失败，继续尝试'
  install_pkgs libasound2 >/dev/null 2>&1 || install_pkgs libasound2t64 >/dev/null 2>&1 || true
  if [[ "$fmt" == 'deb' ]]; then
    if ! as_root apt-get install -y "$pkg" >/dev/null 2>&1; then
      as_root dpkg -i --force-depends "$pkg" || true
      as_root apt-get install -f -y >/dev/null 2>&1 || true
    fi
  else
    as_root rpm -Uvh --replacepkgs "$pkg" || as_root dnf install -y "$pkg" || true
  fi
  rm -f "$pkg"
  [[ -x /opt/QQ/qq ]] || die 'LinuxQQ 安装后未找到 /opt/QQ/qq，请手动安装后重试'
  ok 'LinuxQQ 安装完成'
}

# ---------------------------------------------------------------- NapCat 安装

napcat_zip(){
  local zip="$NAPCAT_DIR/NapCat.Shell.zip"
  mkdir -p "$NAPCAT_DIR"
  if [[ -s "$zip" ]] && unzip -tq "$zip" >/dev/null 2>&1; then
    ok "已有可用 NapCat Shell 包：$zip"
    printf '%s\n' "$zip"
    return 0
  fi
  need curl; need unzip
  local urls=()
  mapfile -t urls < <(napcat_zip_urls)
  rm -f "$zip"
  fetch_to "$zip" "${urls[@]}" || die "NapCat Shell 包下载失败（可设置 NAPCAT_ZIP_URL 指定镜像）"
  unzip -tq "$zip" >/dev/null 2>&1 || die '下载到的 NapCat.Shell.zip 校验失败'
  ok "NapCat Shell 包下载完成（$NAPCAT_VERSION）：$zip"
  printf '%s\n' "$zip"
}

patch_qq_main(){
  local pkg_json="$1"
  local node_bin; node_bin="$(command -v node)"
  as_root "$node_bin" -e '
const fs = require("fs");
const p = process.argv[1];
const obj = JSON.parse(fs.readFileSync(p, "utf8"));
obj.main = "./loadNapCat.js";
fs.writeFileSync(p + ".tmp", JSON.stringify(obj, null, 2) + "\n");
fs.renameSync(p + ".tmp", p);
' "$pkg_json"
}

# NapCat Shell 包内 qqnt.json 声明了它期望的 LinuxQQ 版本；
# 官方客户端版本更新后，必须把 QQ 的 versions/config.json 对齐，否则 NapCat 无法挂载。
patch_qq_version_config(){
  local extract="$1"
  need node
  local qqnt="$extract/qqnt.json"
  [[ -f "$qqnt" ]] || { warn 'NapCat 包内没有 qqnt.json，跳过版本对齐'; return 0; }
  local target_ver target_hash
  target_ver="$(node -e 'const j=require(process.argv[1]); process.stdout.write(j.linuxVersion||j.version||"")' "$qqnt" 2>/dev/null || true)"
  target_hash="$(node -e 'const j=require(process.argv[1]); process.stdout.write(j.linuxVerHash||j.verHash||"")' "$qqnt" 2>/dev/null || true)"
  if [[ -z "$target_ver" ]]; then
    warn '无法解析 qqnt.json 中的 LinuxQQ 版本，跳过版本对齐'
    return 0
  fi
  local build="${target_ver##*-}"
  info "NapCat 期望的 LinuxQQ 版本：$target_ver（build $build）"
  local node_bin; node_bin="$(command -v node)"
  local confs=()
  local home_dir
  for home_dir in /root "/home/$(id -un)" "${HOME:-}"; do
    [[ -n "$home_dir" && -f "$home_dir/.config/QQ/versions/config.json" ]] \
      && confs+=("$home_dir/.config/QQ/versions/config.json")
  done
  if ((${#confs[@]} == 0)); then
    # 还没登录过 QQ，先建好初始配置，避免挂载失败
    local cfg_dir="${HOME:-/root}/.config/QQ/versions"
    as_root mkdir -p "$cfg_dir"
    echo '{}' | as_root tee "$cfg_dir/config.json" >/dev/null
    confs=("$cfg_dir/config.json")
  fi
  local conf
  for conf in "${confs[@]}"; do
    as_root "$node_bin" -e '
const fs = require("fs");
const [path, ver, build, hashArg] = process.argv.slice(1);
let obj = {};
try { obj = JSON.parse(fs.readFileSync(path, "utf8")); } catch (e) { obj = {}; }
obj.baseVersion = ver;
obj.curVersion = ver;
obj.buildId = build;
if (hashArg) obj.hash = hashArg;
fs.writeFileSync(path + ".tmp", JSON.stringify(obj, null, 2) + "\n");
fs.renameSync(path + ".tmp", path);
' "$conf" "$target_ver" "$build" "$target_hash"
    ok "已对齐 QQ 版本配置：$conf"
  done
}

install_napcat_native(){
  need curl; need unzip; need node
  require_root_ability
  local zip; zip="$(napcat_zip)"
  install_qq_client
  local app_dir="$QQ_APP_DIR"
  [[ -d "$app_dir" ]] || die "未找到 LinuxQQ 安装目录：$app_dir"
  local target="$app_dir/app_launcher/napcat"
  local extract="$NAPCAT_DIR/shell"
  rm -rf "$extract"; mkdir -p "$extract"
  unzip -q -o "$zip" -d "$extract"
  [[ -f "$extract/napcat.mjs" ]] || die 'NapCat 包内缺少 napcat.mjs'
  as_root mkdir -p "$target"
  as_root cp -rf "$extract/." "$target/"
  as_root chmod -R 755 "$target"
  printf "(async () => {await import('file://%s/napcat.mjs');})();\n" "$target" \
    | as_root tee "$app_dir/loadNapCat.js" >/dev/null
  patch_qq_main "$app_dir/package.json"
  patch_qq_version_config "$extract"
  NAPCAT_ROOT="$target"
  NAPCAT_MODE="native"
  save_state
  ok "NapCat Shell 已安装到：$target"
  ok "已修补 $app_dir/package.json 的 main 指向 loadNapCat.js"
}

napcat_docker_entrypoint(){
  cat > "$1" <<'ENTRY'
#!/usr/bin/env bash
set -euo pipefail
cd /app
token_file=/app/napcat-auth/token
mkdir -p "$(dirname "$token_file")"
if [[ ! -s "$token_file" ]]; then
  umask 077
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$token_file"
fi
NAPCAT_TOKEN="$(tr -d '\r\n' < "$token_file")"
export WEBUI_TOKEN="${WEBUI_TOKEN:-$NAPCAT_TOKEN}"

# 固化 WebUI 配置：qq-miniapp-auth 通过 NAPCAT_WEBUI_CONFIG 读取这里的 token
webui_cfg=/app/napcat/config/webui.json
if [[ ! -s "$webui_cfg" ]] && command -v jq >/dev/null 2>&1; then
  mkdir -p "$(dirname "$webui_cfg")"
  jq -n --arg token "$WEBUI_TOKEN" \
    '{host: "0.0.0.0", port: 6099, token: $token, loginRate: 3}' > "$webui_cfg"
fi

if [[ ! -f /app/napcat/napcat.mjs ]]; then
  if [[ -f /app/NapCat.Shell.zip ]]; then
    unzip -q /app/NapCat.Shell.zip -d /app/NapCat.Shell
    cp -rf /app/NapCat.Shell/* /app/napcat/
    rm -rf /app/NapCat.Shell
  else
    for u in \
      "https://ghfast.top/https://github.com/XingYunStar/NapCatQQ/releases/download/${NAPCAT_VERSION:-v4.18.19}/NapCat.Shell.zip" \
      "https://gh-proxy.com/https://github.com/XingYunStar/NapCatQQ/releases/download/${NAPCAT_VERSION:-v4.18.19}/NapCat.Shell.zip" \
      "https://github.com/XingYunStar/NapCatQQ/releases/download/${NAPCAT_VERSION:-v4.18.19}/NapCat.Shell.zip"; do
      if curl -fL --connect-timeout 20 --max-time 1800 -o /tmp/NapCat.Shell.zip "$u"; then break; fi
    done
    unzip -q /tmp/NapCat.Shell.zip -d /app/NapCat.Shell
    cp -rf /app/NapCat.Shell/* /app/napcat/
    rm -rf /app/NapCat.Shell /tmp/NapCat.Shell.zip
  fi
fi

if [[ -d /opt/qq-farm/qq-miniapp-openauth ]]; then
  rm -rf /app/napcat/plugins/qq-miniapp-openauth
  mkdir -p /app/napcat/plugins
  cp -a /opt/qq-farm/qq-miniapp-openauth /app/napcat/plugins/
  if ! grep -Fq '"qq-miniapp-openauth"' /app/napcat/napcat.mjs; then
    if grep -Fq '"napcat-plugin-qce"' /app/napcat/napcat.mjs; then
      sed -i '0,/"napcat-plugin-qce"/s//"napcat-plugin-qce",\n  "qq-miniapp-openauth"/' /app/napcat/napcat.mjs
    else
      echo "NapCat plugin whitelist marker not found" >&2
    fi
  fi
  if command -v jq >/dev/null 2>&1; then
    plugin_config=/app/napcat/config/plugins/qq-miniapp-openauth/config.json
    mkdir -p "$(dirname "$plugin_config")"
    jq -n --arg token "$NAPCAT_TOKEN" '{token: $token}' > "$plugin_config.tmp"
    mv "$plugin_config.tmp" "$plugin_config"
    chmod 600 "$plugin_config"
    plugins_config=/app/napcat/config/plugins.json
    if [[ -s "$plugins_config" ]] && jq empty "$plugins_config" 2>/dev/null; then
      jq '. + {"qq-miniapp-openauth": true}' "$plugins_config" > "$plugins_config.tmp"
    else
      jq -n '{"qq-miniapp-openauth": true}' > "$plugins_config.tmp"
    fi
    mv "$plugins_config.tmp" "$plugins_config"
  fi
fi

exec bash /app/entrypoint.sh "$@"
ENTRY
}

napcat_image_tar_urls(){
  local arch name
  case "$(uname -m)" in
    x86_64|amd64) arch='amd64' ;;
    aarch64|arm64) arch='arm64' ;;
    *) return 0 ;;
  esac
  name="napcat-docker-${NAPCAT_VERSION}-${arch}.tar"
  printf '%s\n' \
    "https://ghfast.top/https://github.com/XingYunStar/NapCatQQ/releases/download/$NAPCAT_VERSION/$name" \
    "https://gh-proxy.com/https://github.com/XingYunStar/NapCatQQ/releases/download/$NAPCAT_VERSION/$name" \
    "https://ghproxy.net/https://github.com/XingYunStar/NapCatQQ/releases/download/$NAPCAT_VERSION/$name" \
    "https://github.com/XingYunStar/NapCatQQ/releases/download/$NAPCAT_VERSION/$name"
}

# 确保基础镜像在本地：优先复用，其次 docker pull，最后用官方 release 的离线 tar 包 docker load
ensure_napcat_base_image(){
  if docker image inspect "$NAPCAT_IMAGE" >/dev/null 2>&1; then
    ok "已存在基础镜像：$NAPCAT_IMAGE"
    return 0
  fi
  info "尝试拉取基础镜像：$NAPCAT_IMAGE"
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 docker pull "$NAPCAT_IMAGE" || rc=$?
  else
    docker pull "$NAPCAT_IMAGE" || rc=$?
  fi
  if ((rc == 0)) && docker image inspect "$NAPCAT_IMAGE" >/dev/null 2>&1; then
    ok "基础镜像拉取完成：$NAPCAT_IMAGE"
    return 0
  fi
  warn '无法直接从镜像仓库拉取，改用官方离线包（与 BUGDey 使用的版本一致）'
  need curl
  local arch_tar
  case "$(uname -m)" in
    x86_64|amd64) arch_tar='amd64' ;;
    aarch64|arm64) arch_tar='arm64' ;;
    *) die "不支持的 CPU 架构：$(uname -m)，请手动设置 NAPCAT_IMAGE" ;;
  esac
  local urls=() tarfile
  mapfile -t urls < <(napcat_image_tar_urls)
  tarfile="$NAPCAT_DIR/napcat-docker-${NAPCAT_VERSION}-${arch_tar}.tar"
  if [[ ! -s "$tarfile" ]]; then
    fetch_to "$tarfile" "${urls[@]}" || die 'NapCat 离线镜像包下载失败（可用 NAPCAT_IMAGE 指定自建镜像）'
  else
    ok "已有离线镜像包：$tarfile"
  fi
  info '导入离线镜像（文件较大，请耐心等待）…'
  local load_out
  load_out="$(docker load -i "$tarfile" 2>&1)" || die "docker load 失败：$tarfile"
  printf '%s\n' "$load_out" | grep -E '^Loaded image' >&2 || true
  if ! docker image inspect "$NAPCAT_IMAGE" >/dev/null 2>&1; then
    # 离线包里的仓库名可能与 NAPCAT_IMAGE 不同，把刚导入的镜像重新打标签
    local loaded_ref='' line
    while IFS= read -r line; do
      case "$line" in
        'Loaded image: '*) loaded_ref="${line#Loaded image: }"; break;;
      esac
    done <<< "$load_out"
    if [[ -z "$loaded_ref" ]]; then
      while IFS= read -r line; do
        case "$line" in
          'Loaded image ID: '*) loaded_ref="${line#Loaded image ID: }"; break;;
        esac
      done <<< "$load_out"
    fi
    [[ -n "$loaded_ref" ]] || die 'docker load 成功但无法识别镜像名，请手动 docker tag 后重试'
    docker tag "$loaded_ref" "$NAPCAT_IMAGE" \
      || die "无法将 $loaded_ref 标记为 $NAPCAT_IMAGE"
    info "已将 $loaded_ref 标记为 $NAPCAT_IMAGE"
  fi
  ok "基础镜像已导入：$NAPCAT_IMAGE"
}

install_napcat_docker(){
  need docker
  docker info >/dev/null 2>&1 || die 'Docker 未运行或当前用户无权访问 Docker'
  read_settings
  ensure_napcat_base_image
  install_auth_service
  local ctx="$NAPCAT_DIR/docker"
  rm -rf "$ctx"; mkdir -p "$ctx"
  if [[ -d "$AUTH_DIR/napcat-openauth-plugin" ]]; then
    cp -a "$AUTH_DIR/napcat-openauth-plugin" "$ctx/qq-miniapp-openauth"
  else
    warn '未找到 napcat-openauth-plugin，容器内将跳过插件安装'
    mkdir -p "$ctx/qq-miniapp-openauth"
  fi
  napcat_docker_entrypoint "$ctx/entrypoint.sh"
  cat > "$ctx/Dockerfile" <<'DOCKER'
ARG NAPCAT_IMAGE=mlikiowa/napcat-docker:v4.18.19
FROM ${NAPCAT_IMAGE}
ENV NAPCAT_VERSION=""
COPY qq-miniapp-openauth /opt/qq-farm/qq-miniapp-openauth
COPY entrypoint.sh /usr/local/bin/qq-farm-napcat-entrypoint
RUN chmod +x /usr/local/bin/qq-farm-napcat-entrypoint || true
ENTRYPOINT ["/usr/local/bin/qq-farm-napcat-entrypoint"]
DOCKER
  info "构建 NapCat 容器镜像（基础镜像 $NAPCAT_IMAGE）…"
  docker build --build-arg NAPCAT_IMAGE="$NAPCAT_IMAGE" -t qq-farm-napcat:local "$ctx"
  mkdir -p "$NAPCAT_DIR/config" "$NAPCAT_DIR/QQ" "$NAPCAT_DIR/auth"
  docker rm -f "$NAPCAT_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$NAPCAT_CONTAINER" --restart unless-stopped \
    -e NAPCAT_UID=0 -e NAPCAT_GID=0 \
    -e NAPCAT_TOKEN="$ONEBOT_TOKEN" -e WEBUI_TOKEN="$ONEBOT_TOKEN" \
    -e NAPCAT_VERSION="$NAPCAT_VERSION" \
    -p "127.0.0.1:6099:6099" -p "127.0.0.1:${ONEBOT_PORT}:3000" \
    -v "$NAPCAT_DIR/config:/app/napcat/config" \
    -v "$NAPCAT_DIR/QQ:/app/.config/QQ" \
    -v "$NAPCAT_DIR/auth:/app/napcat-auth" \
    qq-farm-napcat:local >/dev/null
  NAPCAT_MODE="docker"
  NAPCAT_ROOT="$NAPCAT_DIR"
  save_state
  sleep 3
  local napcat_status=''
  napcat_status="$(docker ps --filter "name=$NAPCAT_CONTAINER" --format '{{.Status}}' 2>/dev/null || true)"
  [[ "$napcat_status" == *Up* ]] \
    || die "NapCat 容器未正常运行，请查看：docker logs $NAPCAT_CONTAINER"
  ok "NapCat 容器已启动：$NAPCAT_CONTAINER（WebUI 127.0.0.1:6099，OneBot 127.0.0.1:$ONEBOT_PORT）"
}

# ---------------------------------------------------------------- 授权服务

install_auth_service(){
  need_project; need curl; need tar; need node
  if [[ ! -d "$AUTH_DIR" ]]; then
    info '下载 qq-miniapp-auth 源码…'
    local tmp="$TMPDIR/qq-miniapp-auth.$$.tar.gz"
    fetch_to "$tmp" "$AUTH_TARBALL_URL" || die 'qq-miniapp-auth 源码下载失败'
    mkdir -p "$ROOT_DIR/.auth-extract"
    tar -xzf "$tmp" -C "$ROOT_DIR/.auth-extract"
    local extracted
    extracted="$(find "$ROOT_DIR/.auth-extract" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)"
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
  local webui_config="${NAPCAT_ROOT:-$NAPCAT_DIR}/config/webui.json"
  node -e '
const fs = require("fs");
const [path, secret, onebot, webuiCfg, onebotPort] = process.argv.slice(1);
let s = fs.existsSync(path) ? fs.readFileSync(path, "utf8") : "";
const values = {
  HOST: "127.0.0.1",
  PORT: "8787",
  NAPCAT_API_URL: "http://127.0.0.1:" + onebotPort,
  NAPCAT_TOKEN: onebot,
  NAPCAT_OPEN_AUTH_PLUGIN_URL: "http://127.0.0.1:6099/plugin/qq-miniapp-openauth/api",
  NAPCAT_WEBUI_API_URL: "http://127.0.0.1:6099/api",
  NAPCAT_WEBUI_CONFIG: webuiCfg,
  BRIDGE_HOST: "127.0.0.1",
  BRIDGE_PORT: "9010",
  API_SIGNING_SECRET: secret,
  MINIAPP_SECRETS: "{}",
};
for (const [k, v] of Object.entries(values)) {
  const re = new RegExp("^" + k + "=.*$", "m");
  const line = k + "=" + v;
  if (re.test(s)) s = s.replace(re, line);
  else s += (s === "" || s.endsWith("\n") ? "" : "\n") + line + "\n";
}
fs.writeFileSync(path, s);
' "$AUTH_DIR/.env" "$API_SECRET" "$ONEBOT_TOKEN" "$webui_config" "$ONEBOT_PORT"
  chmod 600 "$AUTH_DIR/.env" 2>/dev/null || true
  if [[ -d "$AUTH_DIR/node_modules" && -f "$AUTH_DIR/node_modules/.package-lock.json" ]]; then
    ok "qq-miniapp-auth 依赖已安装，跳过 npm install"
  else
    pushd "$AUTH_DIR" >/dev/null
    if [[ -f package-lock.json ]]; then npm ci --omit=dev
    else npm install --omit=dev; fi
    popd >/dev/null
  fi
  ok "qq-miniapp-auth 已准备：$AUTH_DIR"
}

start_auth_service(){
  install_auth_service
  local pid_file="$AUTH_DIR/qq-miniapp-auth.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    ok "qq-miniapp-auth 已在后台运行，PID $(cat "$pid_file")"
    return
  fi
  local log="$AUTH_DIR/qq-miniapp-auth.log"
  pushd "$AUTH_DIR" >/dev/null
  nohup npm start >>"$log" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" > "$pid_file"
  popd >/dev/null
  sleep 3
  kill -0 "$pid" 2>/dev/null || die "qq-miniapp-auth 启动失败，请查看 $log"
  ok "qq-miniapp-auth 已后台启动，PID=$pid，日志：$log"
}

# ---------------------------------------------------------------- 插件安装

install_napcat_plugin(){
  need node
  read_settings
  local napcat_root="${NAPCAT_ROOT:-}"
  if [[ -z "$napcat_root" ]]; then
    if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then napcat_root="$NAPCAT_DIR"; else napcat_root="$QQ_APP_DIR/app_launcher/napcat"; fi
  fi
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    # 镜像内已带插件，entrypoint 每次启动都会刷新插件目录与白名单
    ok 'NapCat 容器内插件由 entrypoint 自动安装，无需额外操作'
    return 0
  fi
  [[ -f "$napcat_root/napcat.mjs" ]] || die "找不到 NapCat 根目录中的 napcat.mjs：$napcat_root"
  [[ -d "$AUTH_DIR/napcat-openauth-plugin" ]] || die 'qq-miniapp-auth 中缺少 napcat-openauth-plugin'
  info '安装 qq-miniapp-openauth NapCat 插件…'
  local plugin_dir="$napcat_root/plugins/qq-miniapp-openauth"
  local plugin_cfg="$napcat_root/config/plugins/qq-miniapp-openauth/config.json"
  as_root mkdir -p "$plugin_dir" "$(dirname "$plugin_cfg")"
  as_root cp -a "$AUTH_DIR/napcat-openauth-plugin/." "$plugin_dir/"
  local token
  token="$(sed -n 's/^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=//p' "$AUTH_DIR/.env" 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$token" ]] || token="$ONEBOT_TOKEN"
  node -e '
const fs = require("fs");
const [out, token] = process.argv.slice(1);
fs.writeFileSync(out, JSON.stringify({ token }, null, 2) + "\n");
' "$TMPDIR/plugin-config.$$.json" "$token"
  as_root cp "$TMPDIR/plugin-config.$$.json" "$plugin_cfg"
  as_root chmod 600 "$plugin_cfg"
  rm -f "$TMPDIR/plugin-config.$$.json"
  node -e '
const fs = require("fs");
const p = process.argv[1];
let obj = {};
try { obj = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { obj = {}; }
obj["qq-miniapp-openauth"] = true;
fs.mkdirSync(require("path").dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
' "$napcat_root/config/plugins.json"
  if ! grep -Fq '"qq-miniapp-openauth"' "$napcat_root/napcat.mjs"; then
    grep -Fq '"napcat-plugin-qce"' "$napcat_root/napcat.mjs" \
      || die 'napcat.mjs 中找不到官方插件白名单标记，拒绝自动修改'
    as_root cp -a "$napcat_root/napcat.mjs" "$napcat_root/napcat.mjs.bak.$(date +%Y%m%d%H%M%S)"
    node -e '
const fs = require("fs");
const [src, dst] = process.argv.slice(1);
let s = fs.readFileSync(src, "utf8");
const marker = "\"napcat-plugin-qce\"";
const plugin = "\"qq-miniapp-openauth\"";
const i = s.indexOf(marker);
if (i < 0) { console.error("plugin whitelist marker not found"); process.exit(1); }
s = s.slice(0, i + marker.length) + ",\n  " + plugin + s.slice(i + marker.length);
fs.writeFileSync(dst, s);
' "$napcat_root/napcat.mjs" "$TMPDIR/napcat-patch.$$.mjs"
    as_root cp "$TMPDIR/napcat-patch.$$.mjs" "$napcat_root/napcat.mjs"
    rm -f "$TMPDIR/napcat-patch.$$.mjs"
  fi
  node -e '
const fs = require("fs");
const [envPath, token] = process.argv.slice(1);
let s = fs.readFileSync(envPath, "utf8");
const line = "NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=" + token;
const re = /^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=.*$/m;
s = re.test(s) ? s.replace(re, line) : s + (s.endsWith("\n") ? "" : "\n") + line + "\n";
fs.writeFileSync(envPath, s);
' "$AUTH_DIR/.env" "$token"
  NAPCAT_ROOT="$napcat_root"
  save_state
  ok "qq-miniapp-openauth 插件已安装：$plugin_dir"
}

# ---------------------------------------------------------------- OneBot / 农场配置

find_onebot_configs(){
  local root="${NAPCAT_ROOT:-$NAPCAT_DIR}"
  find "$root/config" -maxdepth 1 -type f -name 'onebot11*.json' 2>/dev/null || true
}

configure_onebot_file(){
  local file="$1" bind_host="${2:-127.0.0.1}"
  node -e '
const fs = require("fs");
const [path, port, token, bindHost] = process.argv.slice(1);
let obj = {};
try { obj = JSON.parse(fs.readFileSync(path, "utf8").replace(/^\uFEFF/, "")); } catch (e) { obj = {}; }
const network = obj.network = obj.network || {};
const servers = network.httpServers = network.httpServers || [];
let server = servers.find((x) => x && x.name === "qq-miniapp-auth-onebot");
if (!server) {
  server = {
    name: "qq-miniapp-auth-onebot",
    enable: true,
    host: bindHost,
    port: Number(port),
    token,
    enableCors: false,
    enableWebsocket: false,
    messagePostFormat: "array",
    debug: false,
  };
  servers.push(server);
} else {
  Object.assign(server, { enable: true, host: bindHost, port: Number(port), token });
}
for (const k of ["httpClients", "websocketServers", "websocketClients"]) {
  if (!Array.isArray(network[k])) network[k] = [];
}
fs.mkdirSync(require("path").dirname(path), { recursive: true });
fs.writeFileSync(path, JSON.stringify(obj, null, 2) + "\n");
' "$file" "$ONEBOT_PORT" "$ONEBOT_TOKEN" "$bind_host"
}

configure_napcat(){
  read_settings
  local files=()
  mapfile -t files < <(find_onebot_configs)
  if ((${#files[@]} == 0)); then
    local cfg_dir
    if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then cfg_dir="$NAPCAT_DIR/config"; else cfg_dir="${NAPCAT_ROOT:-$QQ_APP_DIR/app_launcher/napcat}/config"; fi
    mkdir -p "$cfg_dir"
    files=("$cfg_dir/onebot11.json")
  fi
  local file
  for file in "${files[@]}"; do
    if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
      # 容器内的 OneBot 必须绑定 0.0.0.0，否则宿主机端口映射访问不到；
      # config 目录是 volume，直接写宿主侧文件即可，容器重启后生效
      mkdir -p "$(dirname "$file")"
      configure_onebot_file "$file" '0.0.0.0'
    else
      as_root mkdir -p "$(dirname "$file")"
      if [[ -w "$(dirname "$file")" ]]; then configure_onebot_file "$file"
      else
        local tmp="$TMPDIR/onebot.$$.json"
        configure_onebot_file "$tmp"
        as_root cp "$tmp" "$file"
        rm -f "$tmp"
      fi
    fi
  done
  ok "NapCat OneBot HTTP 服务已配置：127.0.0.1:$ONEBOT_PORT"
  info "qq-miniapp-auth API 地址：$API_ENDPOINT"
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    # 配置是通过 docker cp 写进去的，重启容器让它重新加载
    docker restart "$NAPCAT_CONTAINER" >/dev/null 2>&1 || warn 'NapCat 容器重启失败，请手动执行 docker restart'
    sleep 3
    ok 'NapCat 容器已重启以加载 OneBot 配置'
  fi
}

update_farm_store(){
  local file="$1"
  node -e '
const fs = require("fs");
const [path, endpoint, secret] = process.argv.slice(1);
let obj = {};
try { obj = JSON.parse(fs.readFileSync(path, "utf8").replace(/^\uFEFF/, "")); } catch (e) { obj = {}; }
const login = obj.loginSettings = obj.loginSettings || {};
Object.assign(login, { qqQrLogin: true, napCatEndpoint: endpoint, napCatSignature: secret });
fs.mkdirSync(require("path").dirname(path), { recursive: true });
fs.writeFileSync(path + ".tmp", JSON.stringify(obj, null, 2) + "\n");
fs.renameSync(path + ".tmp", path);
' "$file" "$API_ENDPOINT" "$API_SECRET"
}

configure_source(){
  read_settings
  update_farm_store "$FARM_STORE"
  ok '源码模式 QQ 扫码登录配置已写入 core/data/store.json'
}

configure_docker(){
  read_settings
  local tmp="$TMPDIR/qq-farm-store.$$.json"
  if ! docker cp "$CONTAINER_NAME:/app/core/data/store.json" "$tmp" >/dev/null 2>&1; then
    echo '{}' > "$tmp"
  fi
  update_farm_store "$tmp"
  docker cp "$tmp" "$CONTAINER_NAME:/app/core/data/store.json" >/dev/null
  docker restart "$CONTAINER_NAME" >/dev/null
  rm -f "$tmp"
  ok 'Docker 模式 QQ 扫码登录配置已写入并重启容器'
}

# ---------------------------------------------------------------- 启停

start_napcat_native(){
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    docker start "$NAPCAT_CONTAINER" >/dev/null 2>&1 || true
    sleep 2
    local napcat_status=''
    napcat_status="$(docker ps --filter "name=$NAPCAT_CONTAINER" --format '{{.Status}}' 2>/dev/null || true)"
    if [[ "$napcat_status" == *Up* ]]; then
      ok "NapCat 容器已运行：$NAPCAT_CONTAINER"
    else
      die "NapCat 容器启动失败：docker logs $NAPCAT_CONTAINER"
    fi
    return 0
  fi
  local qq='/opt/QQ/qq'
  [[ -x "$qq" ]] || qq="$(command -v qq || true)"
  [[ -n "$qq" ]] || die '未找到 QQ 可执行文件（/opt/QQ/qq）'
  if [[ -f "$NAPCAT_PID" ]] && kill -0 "$(cat "$NAPCAT_PID" 2>/dev/null || echo 0)" 2>/dev/null; then
    ok "NapCat 已在运行，PID $(cat "$NAPCAT_PID")"
    return 0
  fi
  : > "$NAPCAT_LOG"
  if command -v xvfb-run >/dev/null 2>&1; then
    nohup xvfb-run -a "$qq" --no-sandbox >>"$NAPCAT_LOG" 2>&1 </dev/null &
  else
    warn '未安装 xvfb-run，尝试直接启动（无 X 显示环境时可能失败）'
    nohup "$qq" --no-sandbox >>"$NAPCAT_LOG" 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
  sleep 6
  # xvfb-run / setsid 可能再 fork，不能用 $! 判定存活，改为按进程名确认
  local real_pid
  real_pid="$(pgrep -f "xvfb-run -a $qq" 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$real_pid" ]] || real_pid="$(pgrep -x qq 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$real_pid" ]] || die "NapCat 启动后未存活，请查看 $NAPCAT_LOG"
  echo "$real_pid" > "$NAPCAT_PID"
  ok "NapCat 已后台启动，PID=$real_pid，日志：$NAPCAT_LOG"
  info '首次启动后请打开 NapCat WebUI 扫码登录 QQ：http://127.0.0.1:6099/webui/'
}

restart_napcat(){
  load_state
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    docker restart "$NAPCAT_CONTAINER" >/dev/null
    ok "NapCat 容器已重启：$NAPCAT_CONTAINER"
    return 0
  fi
  # 仅结束脚本自己拉起的 NapCat（xvfb-run 包装进程 + qq 主进程），不做全局 pkill
  local qq_bin='/opt/QQ/qq'
  local pid
  if [[ -f "$NAPCAT_PID" ]]; then
    pid="$(cat "$NAPCAT_PID" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$NAPCAT_PID"
  fi
  pkill -TERM -f "xvfb-run -a $qq_bin" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "xvfb-run -a $qq_bin" 2>/dev/null || true
  # 只清理挂着我们 NapCat 目录的 qq 进程，避免误杀用户自己的 QQ
  pkill -TERM -f "$qq_bin --no-sandbox" 2>/dev/null || true
  sleep 2
  start_napcat_native
}

reset_admin(){
  need node; mkdir -p "$FARM_DATA"
  local password="QqFarm!$(rand_alnum 12)"
  node -e '
const crypto = require("crypto");
const fs = require("fs");
const [path, password] = process.argv.slice(1);
const salt = crypto.randomBytes(32).toString("hex");
const digest = crypto.pbkdf2Sync(password, salt, 100000, 64, "sha512").toString("hex");
const obj = {
  admin: {
    username: "admin",
    password: salt + ":" + digest,
    createdAt: Date.now(),
    mustChangePassword: false,
  },
};
fs.mkdirSync(require("path").dirname(path), { recursive: true });
fs.writeFileSync(path + ".tmp", JSON.stringify(obj, null, 2) + "\n");
fs.renameSync(path + ".tmp", path);
' "$FARM_ADMIN" "$password"
  printf '\n管理员账号：admin\n管理员密码：%s\n\n' "$password"
}

# ---------------------------------------------------------------- 菜单

menu(){
  while true; do
    printf '\n==== QQ Farm Bot + NapCat（脚本版本 %s）====\n' "$SCRIPT_VERSION"
    printf '1. 源码后台启动\n'
    printf '2. Docker 启动\n'
    printf '3. 源码启动并全自动安装/配置 NapCat 与 qq-miniapp-auth\n'
    printf '4. Docker 启动并全自动安装/配置 NapCat 与 qq-miniapp-auth\n'
    printf '5. 重启 NapCat\n'
    printf '6. 重置管理员密码\n'
    printf '0. 退出\n'
    read -r -p '请选择：' choice
    case "$choice" in
      1) start_source;;
      2) start_docker;;
      3)
        read_settings
        install_napcat_native
        install_auth_service
        install_napcat_plugin
        configure_napcat
        configure_source
        start_auth_service
        start_napcat_native
        start_source
        ;;
      4)
        read_settings
        install_napcat_docker
        install_napcat_plugin
        start_docker
        configure_docker
        configure_napcat
        start_auth_service
        ;;
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
