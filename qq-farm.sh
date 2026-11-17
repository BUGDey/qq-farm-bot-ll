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
# NapCat 的两种安装方式：
#   Shell 安装：社区留档的 NapCat-Installer（naxida2333 / jizizr）rootless 安装到 ~/Napcat，
#              执行前先用 sed 把 installer 里已失效的官方地址改成归档 release 地址，
#              并预先放好 NapCat.Shell.zip 与 QQ 安装包，让它检测到同名文件就跳过自己的下载。
#   Docker 安装：直接拉 mlikiowa/napcat-docker，失败时依次换镜像加速前缀，
#              再不行就用官方归档的离线 tar 包 docker load 后 docker tag。

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
# 源码包地址默认由 auth_tarball_urls() 生成（多源 + 加速前缀），这里只作为用户手动覆盖
AUTH_TARBALL_URL="${AUTH_TARBALL_URL:-}"
STATE_FILE="$NAPCAT_DIR/manager-config.env"
SCRIPT_VERSION="2026-11-17.7"
TMPDIR="${TMPDIR:-/tmp}"
FARM_DATA="$PROJECT_DIR/core/data"
FARM_STORE="$FARM_DATA/store.json"
FARM_ADMIN="$FARM_DATA/admin.json"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
CONTAINER_NAME="qq-farm-bot"
SOURCE_PID="$PROJECT_DIR/app_linux.pid"
SOURCE_LOG="$PROJECT_DIR/app_linux.log"
SOURCE_ERR="$PROJECT_DIR/app_linux.error.log"

# ---- NapCat 版本与归档源（版本默认跟随 BUGDey/qq-farm-bot 的 v4.18.19）
NAPCAT_VERSION="${NAPCAT_VERSION:-v4.18.19}"
NAPCAT_ARCHIVE_REPO="${NAPCAT_ARCHIVE_REPO:-XingYunStar/NapCatQQ}"
NAPCAT_INSTALLER_URL="${NAPCAT_INSTALLER_URL:-https://raw.githubusercontent.com/naxida2333/NapCat-Installer/main/script/install.sh}"
NAPCAT_INSTALLER_URL_BACKUP="${NAPCAT_INSTALLER_URL_BACKUP:-https://raw.githubusercontent.com/jizizr/NapCat-Installer/main/script/install.sh}"
# raw.githubusercontent.com 连加速站一起挂了时的最后一条：jsDelivr 的 gh 通道（不经 GitHub 源站）
NAPCAT_INSTALLER_URL_FALLBACK="${NAPCAT_INSTALLER_URL_FALLBACK:-https://cdn.jsdelivr.net/gh/naxida2333/NapCat-Installer@main/script/install.sh}"
NAPCAT_IMAGE_BASE="${NAPCAT_IMAGE_BASE:-mlikiowa/napcat-docker}"
NAPCAT_IMAGE_TAG="${NAPCAT_IMAGE_TAG:-v4.18.19}"
NAPCAT_IMAGE="${NAPCAT_IMAGE:-$NAPCAT_IMAGE_BASE:$NAPCAT_IMAGE_TAG}"
NAPCAT_CONTAINER="${NAPCAT_CONTAINER:-qq-farm-napcat}"
QQ_APP_DIR="${QQ_APP_DIR:-/opt/QQ/resources/app}"
NAPCAT_LOG="$NAPCAT_DIR/napcat.log"
NAPCAT_PID="$NAPCAT_DIR/napcat.pid"
NAPCAT_INSTALL_LOG="$NAPCAT_DIR/napcat-install.log"

info(){ printf '\033[36m[INFO]\033[0m %s\n' "$*" >&2; }
ok(){ printf '\033[32m[OK]\033[0m %s\n' "$*" >&2; }
warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
need_project(){ [[ -d "$PROJECT_DIR" ]] || die "找不到项目目录：$PROJECT_DIR"; }

farm_port(){
  local port="${ADMIN_PORT:-}" fallback='' line
  if [[ -f "$PROJECT_DIR/.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        ADMIN_PORT=*) [[ -n "$port" ]] || port="${line#ADMIN_PORT=}" ;;
        PORT=*) [[ -n "$fallback" ]] || fallback="${line#PORT=}" ;;
      esac
    done < "$PROJECT_DIR/.env"
  fi
  port="${port//[^0-9]/}"
  [[ -n "$port" ]] || port="${fallback//[^0-9]/}"
  [[ -n "$port" ]] || port=3007
  printf '%s' "$port"
}

local_ip(){
  local ip=''
  if [[ -n "${PANEL_IP:-}" ]]; then
    printf '%s' "$PANEL_IP"
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" || true
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  fi
  printf '%s' "${ip:-127.0.0.1}"
}

public_ip(){
  local ip=''
  [[ -n "${PANEL_PUBLIC_IP:-}" ]] && { printf '%s' "$PANEL_PUBLIC_IP"; return 0; }
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)"
  fi
  [[ "$ip" =~ ^[0-9.]+$ ]] || ip=''
  printf '%s' "$ip"
}

report_panel_access(){
  local show="${1:-0}" user="${2:-admin}" pass="${3:-}" port lan pub
  port="$(farm_port)"
  lan="$(local_ip)"
  pub="$(public_ip)"
  printf '\n'
  if [[ -n "$pub" && "$pub" != "$lan" ]]; then
    printf '\033[32m[面板]\033[0m 访问地址：http://%s:%s\n' "$pub" "$port"
  fi
  if [[ "$lan" != 127.0.0.1 && "$lan" != 0.0.0.0 ]]; then
    printf '\033[32m[面板]\033[0m 本机 IP 访问：http://%s:%s\n' "$lan" "$port"
  fi
  printf '\033[32m[面板]\033[0m 本地访问：http://127.0.0.1:%s\n' "$port"
  if [[ "$show" == 1 ]]; then
    printf '\033[32m[登录]\033[0m 管理员账号：%s\n' "$user"
    printf '\033[32m[登录]\033[0m 管理员密码：%s\n' "$pass"
  fi
  printf '\n'
}

# 首次构建启动时才打印账号密码；之后只打印访问地址。
# 用 marker 记录「已经打印过」，marker 在 napcat 目录下（已被 .gitignore 忽略）。
creds_marker(){ printf '%s' "$NAPCAT_DIR/.panel-credentials-shown"; }
creds_shown(){ [[ -f "$(creds_marker)" ]]; }
mark_creds_shown(){ mkdir -p "$NAPCAT_DIR" 2>/dev/null || true; : > "$(creds_marker)" 2>/dev/null || true; }

# 生成随机字母数字串。
# 注意：不要写成 `tr ... </dev/urandom | head -c N`——head 读够就退出会让 tr 收到
# SIGPIPE 而失败，配合 pipefail + set -e 会让脚本毫无提示地静默退出。
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
    command -v sudo >/dev/null 2>&1 || die '当前不是 root 且没有 sudo，无法安装系统依赖'
  fi
}

# 安装前预检：先把所有前置条件查一遍，全部通过再开始安装，避免装到一半才报错。
# shellcheck disable=SC2317
preflight_install(){
  local mode="${1:-shell}" problems=0
  local -a missing=()

  need_project

  info '安装前检查运行环境…'

  # 1. 通用命令
  local c
  for c in curl tar node npm unzip; do
    command -v "$c" >/dev/null 2>&1 || missing+=("命令 $c")
  done
  # Node >= 20：授权服务与国产 QQ wrapper 都要 Node 20+
  if command -v node >/dev/null 2>&1; then
    local nver
    nver="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [[ "$nver" =~ ^[0-9]+$ ]] && (( nver < 20 )); then
      missing+=("Node.js 版本需 >= 20（当前 $(node --version 2>/dev/null || echo "主版本 $nver")）")
    fi
  fi

  # 2. CPU 架构（QQ / NapCat 只支持 amd64、arm64）
  if ! qq_arch >/dev/null 2>&1; then
    missing+=("CPU 架构不支持：$(uname -m)（仅支持 x86_64/amd64、aarch64/arm64）")
  fi

  # 3. 系统包管理器（Shell 安装缺依赖时要能补装）
  if [[ "$mode" == 'shell' ]]; then
    if ! command -v apt-get >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
      missing+=('系统包管理器（apt-get / dnf / yum，用于补装 QQ 运行依赖）')
    fi
    if [[ "$IS_ROOT" -eq 0 ]] && ! command -v sudo >/dev/null 2>&1; then
      missing+=('root 权限或 sudo（用于安装系统依赖）')
    fi
  fi

  # 4. Docker 模式专属
  if [[ "$mode" == 'docker' ]]; then
    command -v docker >/dev/null 2>&1 || missing+=('命令 docker')
    if command -v docker >/dev/null 2>&1; then
      docker info >/dev/null 2>&1 || missing+=('Docker 守护进程未运行，或当前用户无权访问（需 root 或加入 docker 组）')
      if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        missing+=('Docker Compose（apt install docker-compose-plugin / dnf install docker-compose-plugin）')
      fi
    fi
  fi

  # 5. 磁盘空间：软链包缓存约需 1.5G，这里只做宽松提醒
  local avail=''
  if command -v df >/dev/null 2>&1; then
    avail="$(df -Pm "$ROOT_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < 2048 )); then
      missing+=("可用磁盘空间不足 2G（当前约 ${avail}M，下载缓存与 QQ 客户端需要空间）")
    fi
  fi

  if (( ${#missing[@]} > 0 )); then
    printf '\033[31m[FAIL]\033[0m 安装前检查未通过，请先处理下列问题：\n' >&2
    local m
    for m in "${missing[@]}"; do
      printf '  - %s\n' "$m" >&2
    done
    printf '\033[31m[FAIL]\033[0m 处理完后再重新选择安装。\n' >&2
    return 1
  fi

  ok "安装前检查通过（系统：$(uname -s) $(uname -m)；Node：$(node --version 2>/dev/null || echo '?')）"
  return 0
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

# ---------------------------------------------------------------- 下载（GitHub 加速前缀链）

# GitHub 代理前缀，顺序即尝试顺序
GH_PROXY_PREFIXES=(
  "https://ghfast.top/"
  "https://git.yylx.win/"
  "https://gh-proxy.com/"
  "https://ghfile.geekertao.top/"
  "https://gh-proxy.net/"
  "https://j.1win.ggff.net/"
  "https://ghm.078465.xyz/"
  "https://gitproxy.127731.xyz/"
  "https://jiashu.1win.eu.org/"
  "https://github.tbedu.top/"
)

# 把原始 GitHub 地址展开成候选列表：GH_PROXY_INDEX 指定的优先，其余代理，最后直连
gh_url_variants(){
  local url="$1"
  local -a out=()
  local i
  if [[ -n "${GH_PROXY_INDEX:-}" && "${GH_PROXY_INDEX:-}" =~ ^[0-9]+$ ]]; then
    if ((GH_PROXY_INDEX >= 1 && GH_PROXY_INDEX <= ${#GH_PROXY_PREFIXES[@]})); then
      out+=("${GH_PROXY_PREFIXES[$((GH_PROXY_INDEX - 1))]}${url}")
    fi
  fi
  for i in "${!GH_PROXY_PREFIXES[@]}"; do
    [[ -n "${GH_PROXY_INDEX:-}" ]] && ((i + 1 == GH_PROXY_INDEX)) && continue
    out+=("${GH_PROXY_PREFIXES[$i]}${url}")
  done
  out+=("$url")
  printf '%s\n' "${out[@]}"
}

# 静默下载：不打印候选地址、不打印进度条，成功时什么都不输出（调用方自己打 ok）。
# 某个源彻底失败才 warn 一行，并把 curl 的最后一句原因带上（只带一句，不刷屏）。
fetch_to(){
  local dest="$1"; shift
  local url attempt err reason
  local errf="$dest.curlerr"
  for url in "$@"; do
    [[ -n "$url" ]] || continue
    # -fsS：不输出进度条，但把失败原因写进 errf（我们自己汇总成一行，不让 curl 刷屏）
    for attempt in 1 2 3; do
      if curl -fsSL -S --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 3600 \
          -A 'Mozilla/5.0' -o "$dest.part" "$url" 2>"$errf"; then
        mv "$dest.part" "$dest"
        rm -f "$errf"
        return 0
      fi
      [[ "$attempt" -lt 3 ]] && sleep 2
    done
    rm -f "$dest.part"
    reason="$(tail -n 1 "$errf" 2>/dev/null | tr -d '\r' || true)"
    rm -f "$errf"
    if [[ -n "$reason" ]]; then warn "源不可用，换下一个（$reason）：$url"
    else warn "源不可用，换下一个：$url"; fi
  done
  rm -f "$dest.part" "$errf"
  return 1
}

# 从 GitHub 下载（自动套用加速前缀）。可一次传多个原始地址，按序展开后逐个尝试
fetch_github(){
  local dest="$1"; shift
  local base
  local -a urls=() variants=()
  for base in "$@"; do
    [[ -n "$base" ]] || continue
    mapfile -t variants < <(gh_url_variants "$base")
    urls+=("${variants[@]}")
  done
  fetch_to "$dest" "${urls[@]}"
}

# GitHub API 不能走全部加速站点（多数只代理 github.com），这里单独给一份实测可用的前缀，
# 仍然先试 GH_PROXY_INDEX 指定的那个，最后直连 api.github.com。
GH_API_PROXY_PREFIXES=(
  "https://gh-proxy.com/"
  "https://gh-proxy.net/"
  "https://jiashu.1win.eu.org/"
  "https://git.yylx.win/"
)

api_url_variants(){
  local url="$1"
  local -a out=()
  local i
  if [[ -n "${GH_PROXY_INDEX:-}" && "${GH_PROXY_INDEX:-}" =~ ^[0-9]+$ ]]; then
    if ((GH_PROXY_INDEX >= 1 && GH_PROXY_INDEX <= ${#GH_API_PROXY_PREFIXES[@]})); then
      out+=("${GH_API_PROXY_PREFIXES[$((GH_PROXY_INDEX - 1))]}${url}")
    fi
  fi
  for i in "${!GH_API_PROXY_PREFIXES[@]}"; do
    [[ -n "${GH_PROXY_INDEX:-}" ]] && ((i + 1 == GH_PROXY_INDEX)) && continue
    out+=("${GH_API_PROXY_PREFIXES[$i]}${url}")
  done
  out+=("$url")
  printf '%s\n' "${out[@]}"
}

# qq-miniapp-auth 源码包的两个 GitHub 出口，各自再套一遍加速前缀：
#   codeload.github.com/...tar.gz   —— 直连可用的老地址
#   github.com/.../archive/...tar.gz —— ghfast 等站点真正支持的那条
AUTH_REPO="${AUTH_REPO:-liyangpengs/qq-miniapp-auth}"
AUTH_BRANCH="${AUTH_BRANCH:-master}"

auth_tarball_urls(){
  local -a fam=()
  if [[ -n "${AUTH_TARBALL_URL:-}" ]]; then printf '%s\n' "$AUTH_TARBALL_URL"; fi
  # 加速站只认 github.com 的 /archive/ 形式，直接把 codeload 域名套前缀会 403/14 字节，
  # 所以先出「前缀 + github.com/archive」，最后再补一条 codeload 直连。
  mapfile -t fam < <(gh_url_variants \
    "https://github.com/${AUTH_REPO}/archive/refs/heads/${AUTH_BRANCH}.tar.gz")
  printf '%s\n' "${fam[@]}"
  printf '%s\n' "https://codeload.github.com/${AUTH_REPO}/tar.gz/refs/heads/${AUTH_BRANCH}"
}

# ---------------------------------------------------------------- LinuxQQ 安装包

qq_arch(){
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' 'amd64' ;;
    aarch64|arm64) printf '%s\n' 'arm64' ;;
    *) return 1 ;;
  esac
}

qq_pkg_ext(){
  if command -v dpkg >/dev/null 2>&1; then printf '%s\n' 'deb'
  elif command -v rpm >/dev/null 2>&1; then printf '%s\n' 'rpm'
  else printf '%s\n' 'deb'; fi
}

# 从 zydou/QQ-Linux 归档 release 里挑最新的对应架构安装包地址
qq_deb_url_from_api(){
  local arch="$1" ext="$2" json
  json="$TMPDIR/qq-linux-releases.$$.json"
  # api.github.com 不能走全部加速站点（多数只代理 github.com），用单独一张实测可用的表
  local -a urls=()
  mapfile -t urls < <(api_url_variants "https://api.github.com/repos/${QQ_PKG_REPO:-zydou/QQ-Linux}/releases?per_page=20")
  fetch_to "$json" "${urls[@]}" >/dev/null 2>&1 \
    || { rm -f "$json"; return 1; }
  local url
  url="$(node -e '
const fs = require("fs");
const [p, arch, ext] = process.argv.slice(1);
let rel;
try { rel = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { process.exit(1); }
if (!Array.isArray(rel)) process.exit(1);
for (const r of rel) {
  const a = (r.assets || []).find((x) => x.name && x.name.endsWith("-" + arch + "." + ext));
  if (a && a.browser_download_url) { process.stdout.write(a.browser_download_url); break; }
}
' "$json" "$arch" "$ext" 2>/dev/null || true)"
  rm -f "$json"
  [[ -n "$url" ]] || return 1
  printf '%s\n' "$url"
}

# 准备好 QQ 安装包，放到 installer 的工作目录里（文件名必须是 QQ.deb / QQ.rpm），
# 这样 installer 会打印「检测到当前目录下存在QQ安装包」并直接用它，绕开已失效的 qqdl 地址。
# 包会缓存在 $NAPCAT_DIR 下：installer 跑完的 clean() 会删掉工作目录里的副本，
# 缓存留着，下次重装就不用再下 170MB。
napcat_prepare_qq_pkg(){
  local work="$1"
  local arch ext pkg cache
  arch="$(qq_arch)" || die "不支持的 CPU 架构：$(uname -m)"
  ext="$(qq_pkg_ext)"
  cache="$NAPCAT_DIR/QQ.$ext"
  pkg="$work/QQ.$ext"
  mkdir -p "$NAPCAT_DIR"
  if [[ ! -s "$cache" ]]; then
    local url=''
    url="$(qq_deb_url_from_api "$arch" "$ext" 2>/dev/null || true)"
    local -a urls=()
    if [[ -n "${QQ_PKG_URL:-}" ]]; then urls+=("$QQ_PKG_URL"); fi
    if [[ -n "$url" ]]; then
      mapfile -t -O "${#urls[@]}" urls < <(gh_url_variants "$url")
    fi
    # 兜底：归档里已知可用的版本（与本脚本默认 NapCat 版本配套）
    local fallback_tag='3.2.28-260429'
    mapfile -t -O "${#urls[@]}" urls < <(gh_url_variants \
      "https://github.com/zydou/QQ-Linux/releases/download/${fallback_tag}/QQ-${fallback_tag}-${arch}.${ext}")
    info '下载 LinuxQQ 安装包（GitHub 归档，免安装直接解包）…'
    fetch_to "$cache" "${urls[@]}" \
      || die 'LinuxQQ 安装包下载失败，可用 QQ_PKG_URL 指定地址'
    ok "QQ 安装包已缓存：$cache（$(du -h "$cache" | cut -f1)）"
  else
    ok "已有 QQ 安装包缓存：$cache（$(du -h "$cache" | cut -f1)）"
  fi
  cp -f "$cache" "$pkg" || die "无法把 QQ 安装包复制到：$pkg"
  printf '%s\n' "$pkg"
}

# 旧版本（本脚本 2026-11-16.3 及更早）装的是系统级 /opt/QQ + NapCat，
# 新版 NapCat-Installer 检测到它就会交互式询问是否彻底删除，脚本非交互会读到 EOF 直接退出。
# 这里提前把 NapCat 目录挪走（只挪 NapCat，不碰 QQ 本体），并把 QQ 的 main 恢复原样，
# 这样 installer 认为「没有旧版本」直接往下走，用户原来的 QQ 也不会被弄坏。
napcat_cleanup_old_install(){
  local app='/opt/QQ/resources/app'
  local old="$app/app_launcher/napcat"
  [[ -d "$old" ]] || return 0
  warn '检测到旧版系统级安装（/opt/QQ 下的 NapCat），先备份配置再把 NapCat 目录挪走'
  local backup="$NAPCAT_DIR/napcat-config-backup.$(date +%Y%m%d%H%M%S)"
  mkdir -p "$backup"
  as_root cp -a "$old/config/." "$backup/" 2>/dev/null || warn '旧配置备份失败（忽略）'
  ok "旧 NapCat 配置已备份：$backup"
  as_root mv "$old" "$NAPCAT_DIR/napcat-old-app_launcher" \
    || { warn '挪走旧 NapCat 目录失败，尝试直接删除'; as_root rm -rf "$old" || die '无法清理旧版 NapCat 目录'; }
  # QQ 的 package.json 之前被改成 main="./loadNapCat.js"，NapCat 挪走后会启动失败，改回原值
  if [[ -f "$app/package.json" ]]; then
    need node
    as_root node -e '
const fs=require("fs");const p=process.argv[1];
try{const o=JSON.parse(fs.readFileSync(p,"utf8"));
if(o.main==="./loadNapCat.js"){o.main="./application.asar/app_launcher/index.js";
fs.writeFileSync(p+".tmp",JSON.stringify(o,null,2)+"\n");fs.renameSync(p+".tmp",p);}}catch(e){}
' "$app/package.json" 2>/dev/null || true
  fi
  ok '旧版系统级 NapCat 已挪走（QQ 本体保留）'
}

# ---------------------------------------------------------------- NapCat Shell 安装

# 下载社区留档的 NapCat-Installer，并把里面已失效的官方地址就地改掉
napcat_get_installer(){
  local work="$1"
  local dest="$work/napcat.sh"
  rm -f "$dest"
  local base try_url
  local -a bases=("$NAPCAT_INSTALLER_URL" "$NAPCAT_INSTALLER_URL_BACKUP" \
                  "$NAPCAT_INSTALLER_URL_FALLBACK")
  local -a urls=() variants=()
  # 两个候选仓库 × 全部加速前缀 + 直连，逐个试；每个地址内部再重试 2 次
  for base in "${bases[@]}"; do
    [[ -n "$base" ]] || continue
    mapfile -t variants < <(gh_url_variants "$base")
    urls+=("${variants[@]}")
  done
  local attempt reason
  local errf="$dest.curlerr"
  for try_url in "${urls[@]}"; do
    for attempt in 1 2; do
      # 不要写成 `head -n 1 | grep -q`：grep 命中即退出会让 head 收到 SIGPIPE，
      # 配合 pipefail 会把「下载成功」误判成失败。
      if curl -fsSL -S --connect-timeout 20 --max-time 120 -o "$dest" "$try_url" 2>"$errf" \
          && [[ -s "$dest" ]] && [[ "$(head -c 2 "$dest")" == '#!' ]]; then
        rm -f "$errf"
        ok 'NapCat 安装器已就绪'
        printf '%s\n' "$dest"
        return 0
      fi
      [[ "$attempt" -lt 2 ]] && sleep 2
    done
    rm -f "$dest"
  done
  reason="$(tail -n 1 "$errf" 2>/dev/null | tr -d '\r' || true)"
  rm -f "$errf"
  die "NapCat 安装器下载失败（所有源都不可用）${reason:+：$reason}"
}

# installer 内部仍写死已失效的官方地址，执行前就地改成归档地址：
#   1) NapCat.Shell.zip      -> 归档仓库固定 tag
#   2) 网络探测 package.json -> 归档仓库里确实存在的 README.md
napcat_patch_installer(){
  local file="$1"
  local zip_url="github.com/${NAPCAT_ARCHIVE_REPO}/releases/download/${NAPCAT_VERSION}/NapCat.Shell.zip"
  local probe_url="raw.githubusercontent.com/${NAPCAT_ARCHIVE_REPO}/main/README.md"
  sed -i \
    -e "s#github.com/NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip#${zip_url}#g" \
    -e "s#raw.githubusercontent.com/NapNeko/NapCatQQ/main/package.json#${probe_url}#g" \
    "$file"
  if grep -q 'NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip' "$file"; then
    die 'NapCat 安装器地址修正失败（上游格式变化）'
  fi
  ok '已修正安装器内的失效上游地址'
}

# 预先把 NapCat.Shell.zip 放到 installer 工作目录，installer 检测到就不自己下了。
# 注意：本函数在 installer 装依赖之前执行，系统上可能还没有 unzip，
# 所以校验用「PK 魔数 + 体积」而不是 unzip -t（真正的解压由 installer 负责）。
zip_looks_ok(){
  local f="$1"
  [[ -s "$f" ]] || return 1
  local magic size
  magic="$(head -c 2 "$f" 2>/dev/null || true)"
  [[ "$magic" == 'PK' ]] || return 1
  size="$(wc -c <"$f" | tr -d ' ')"
  [[ "$size" -gt 1000000 ]] || return 1
  if command -v unzip >/dev/null 2>&1; then
    unzip -tq "$f" >/dev/null 2>&1 || return 1
  fi
  return 0
}

napcat_prepare_shell_zip(){
  local work="$1"
  local zip="$work/NapCat.Shell.zip"
  local cache="$NAPCAT_DIR/NapCat.Shell.zip"
  mkdir -p "$NAPCAT_DIR"
  # installer 跑完的 clean() 会删掉工作目录里的副本，所以缓存放在 napcat/ 下
  if ! zip_looks_ok "$cache"; then
    rm -f "$cache"
    local url="https://github.com/${NAPCAT_ARCHIVE_REPO}/releases/download/${NAPCAT_VERSION}/NapCat.Shell.zip"
    info "下载 NapCat Shell 包（${NAPCAT_VERSION}）…"
    if [[ -n "${NAPCAT_ZIP_URL:-}" ]]; then
      fetch_to "$cache" "$NAPCAT_ZIP_URL" || die "NapCat Shell 包下载失败（NAPCAT_ZIP_URL 指定的地址不可用）"
    else
      fetch_github "$cache" "$url" \
        || die "NapCat Shell 包下载失败（所有源都不可用，可设置 NAPCAT_ZIP_URL 指定镜像）"
    fi
    zip_looks_ok "$cache" || die 'NapCat.Shell.zip 校验失败（不是有效的 zip 包）'
    ok "NapCat Shell 包已缓存：$cache（$(du -h "$cache" | cut -f1)）"
  else
    ok "已有 NapCat Shell 包缓存：$cache"
  fi
  cp -f "$cache" "$zip" || die "无法把 NapCat Shell 包复制到：$zip"
  printf '%s\n' "$zip"
}

# 开放 6099（尽力而为，失败不影响安装）
open_port(){
  local port="${1:-6099}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    as_root ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ok "ufw 已放行 ${port} 端口"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    as_root firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    as_root firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行 ${port} 端口"
  elif command -v iptables >/dev/null 2>&1; then
    as_root iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 \
      || as_root iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    ok "iptables 已放行 ${port} 端口"
  fi
}

napcat_sudo_shim(){
  # installer 里到处写死 `sudo ...`，且 check_sudo() 一开头就要求机器上有 sudo。
  # 用 root 跑而系统恰好没装 sudo（精简镜像常见）时，塞一个直通的 sudo 垫片，避免装到一半失败。
  [[ "$(id -u)" == '0' ]] || return 0
  command -v sudo >/dev/null 2>&1 && return 0
  local shim="$NAPCAT_DIR/bin"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexec "$@"\n' > "$shim/sudo"
  chmod +x "$shim/sudo"
  export PATH="$shim:$PATH"
  warn "系统没有 sudo，已用直通垫片代替：$shim/sudo"
}

install_napcat_shell(){
  need curl; need tar; need node
  read_settings
  # 已装过就直接复用，不重复下载/执行安装器；只确保状态记录正确
  if [[ "${NAPCAT_MODE:-}" == 'native' ]] && napcat_installed; then
    ok 'NapCat Shell 已安装，跳过安装步骤（如需强制重装可先清空 napcat/ 目录）'
    return 0
  fi
  require_root_ability
  cd_home
  info '========== NapCat Shell 安装 =========='
  # 重装前先结束残留的 NapCat QQ 进程，避免多实例竞争导致 OneBot 端口不监听
  local stale; stale="$(napcat_running_pids)"
  if [[ -n "$stale" ]]; then
    warn '检测到残留的 NapCat QQ 进程，先结束它们再安装'
    kill_napcat_pids "$stale"
  fi
  napcat_cleanup_old_install
  napcat_sudo_shim
  local installer zip
  installer="$(napcat_get_installer "$HOME")"
  napcat_patch_installer "$installer"
  zip="$(napcat_prepare_shell_zip "$HOME")"
  napcat_prepare_qq_pkg "$HOME" >/dev/null
  info '开始执行 NapCat 安装器（非交互：不装 Docker、不装 CLI、不自动启动）'
  info "安装日志：$NAPCAT_INSTALL_LOG"
  : > "$NAPCAT_INSTALL_LOG"
  # stdin 接 /dev/null：installer 里少数 read 提示会读到 EOF 走默认分支，不会卡住
  if ! bash "$installer" --docker n --cli n --proxy "${GH_PROXY_INDEX:-0}" --force \
      </dev/null 2>&1 | tee -a "$NAPCAT_INSTALL_LOG"; then
    die "NapCat 安装器执行失败，请查看日志：$NAPCAT_INSTALL_LOG"
  fi
  local root
  root="$(napcat_detect_root || true)"
  [[ -n "$root" ]] || die "安装器执行完了但没找到 NapCat 目录，请查看日志：$NAPCAT_INSTALL_LOG"
  NAPCAT_ROOT="$root"
  NAPCAT_MODE="native"
  save_state
  ok "NapCat Shell 已安装：$root"
  open_port 6099
}

# installer 是 rootless 的：装到 ~/Napcat 下
napcat_detect_root(){
  local c
  for c in \
    "$HOME/Napcat/opt/QQ/resources/app/app_launcher/napcat" \
    "/opt/QQ/resources/app/app_launcher/napcat"; do
    if [[ -f "$c/napcat.mjs" ]]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

napcat_detect_qq(){
  local c
  for c in "$HOME/Napcat/opt/QQ/qq" "/opt/QQ/qq"; do
    if [[ -x "$c" ]]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

# NapCat 是否已装好：用于幂等——已装就跳过安装，只做配置与启动。
# 只有状态里明确记录过对应模式时才跳过，避免首次运行时误把旧的系统级安装当成"已装"。
napcat_installed(){
  case "${NAPCAT_MODE:-}" in
    native)
      local root; root="$(napcat_detect_root 2>/dev/null || true)"
      [[ -n "$root" && -f "$root/napcat.mjs" ]] || return 1
      napcat_detect_qq >/dev/null 2>&1 || return 1
      return 0
      ;;
    docker)
      docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAPCAT_CONTAINER" || return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# 列出当前在跑的 NapCat QQ 进程（xvfb-run 父进程与 qq 子进程都会命中）。
# 重装或异常退出会留下多组进程；多实例竞争时只有持登录态的那个加载 OneBot 配置，
# 另一个不监听 3000，二维码接口就会失败。启动前据此清理，保证只有一个实例。
napcat_running_pids(){
  local p cmd
  for p in $(pgrep -f 'Napcat/opt/QQ/qq|app_launcher/napcat' 2>/dev/null || true); do
    [[ "$p" == "$$" ]] && continue
    cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *"Napcat/opt/QQ/qq"*|*"app_launcher/napcat"*) printf '%s\n' "$p" ;;
    esac
  done | sort -u
}

kill_napcat_pids(){
  local pids="$1" p
  [[ -n "$pids" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    kill -TERM "$p" 2>/dev/null || true
  done <<< "$pids"
  sleep 2
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    kill -9 "$p" 2>/dev/null || true
  done <<< "$pids"
}

cd_home(){ cd "$HOME" || die "无法进入 $HOME"; }

# ---------------------------------------------------------------- NapCat Docker 安装

# Docker 镜像加速前缀
DOCKER_MIRROR_PREFIXES=(
  ""
  "docker.1ms.run/"
  "docker.xuanyuan.me/"
  "docker.mybacc.com/"
  "dytt.online/"
  "lispy.org/"
  "docker.m.daocloud.io/"
  "swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/"
)

# 依次尝试从加速站点拉取镜像，成功后统一打成本地 NAPCAT_IMAGE 标签
ensure_napcat_image(){
  if docker image inspect "$NAPCAT_IMAGE" >/dev/null 2>&1; then
    ok "已存在基础镜像：$NAPCAT_IMAGE"
    return 0
  fi
  [[ -n "${NAPCAT_IMAGE:-}" ]] || die 'NAPCAT_IMAGE 为空'
  local prefix ref
  local img_path="$NAPCAT_IMAGE_BASE:$NAPCAT_IMAGE_TAG"
  for prefix in "${DOCKER_MIRROR_PREFIXES[@]}"; do
    ref="${prefix}${img_path}"
    info "拉取镜像：$ref"
    if command -v timeout >/dev/null 2>&1; then
      timeout 300 docker pull "$ref" >/dev/null 2>&1 || continue
    else
      docker pull "$ref" >/dev/null 2>&1 || continue
    fi
    if [[ "$ref" != "$NAPCAT_IMAGE" ]]; then
      docker tag "$ref" "$NAPCAT_IMAGE" >/dev/null 2>&1 || true
    fi
    if docker image inspect "$NAPCAT_IMAGE" >/dev/null 2>&1; then
      ok "基础镜像就绪：$NAPCAT_IMAGE"
      return 0
    fi
  done
  warn '所有镜像加速站点都拉取失败，改用官方归档的离线 tar 包'
  local arch name tarfile
  arch="$(qq_arch)" || die "不支持的 CPU 架构：$(uname -m)"
  name="napcat-docker-${NAPCAT_IMAGE_TAG}-${arch}.tar"
  tarfile="$NAPCAT_DIR/$name"
  if [[ ! -s "$tarfile" ]]; then
    info "下载离线镜像包（约 570MB）：$name"
    fetch_github "$tarfile" \
      "https://github.com/${NAPCAT_ARCHIVE_REPO}/releases/download/${NAPCAT_IMAGE_TAG}/${name}" \
      || die "离线镜像包下载失败（可用 NAPCAT_IMAGE_TAR_URL 指定）"
  else
    ok "已有离线镜像包：$tarfile"
  fi
  info '导入离线镜像（文件较大，请耐心等待）…'
  local load_out=''
  load_out="$(docker load -i "$tarfile" 2>&1)" || die "docker load 失败：$tarfile"
  printf '%s\n' "$load_out" >&2
  if ! docker image inspect "$NAPCAT_IMAGE" >/dev/null 2>&1; then
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
    docker tag "$loaded_ref" "$NAPCAT_IMAGE" || die "无法把 $loaded_ref 标记为 $NAPCAT_IMAGE"
  fi
  ok "基础镜像已导入：$NAPCAT_IMAGE"
}

install_napcat_docker(){
  need docker
  docker info >/dev/null 2>&1 || die 'Docker 未运行或当前用户无权访问 Docker'
  read_settings
  info '========== NapCat Docker 安装 =========='
  ensure_napcat_image
  mkdir -p "$NAPCAT_DIR/docker/config" "$NAPCAT_DIR/docker/plugins" "$NAPCAT_DIR/docker/QQ"
  docker rm -f "$NAPCAT_CONTAINER" >/dev/null 2>&1 || true
  local uid gid
  uid="$(id -u)"; gid="$(id -g)"
  info "创建容器：$NAPCAT_CONTAINER（镜像 $NAPCAT_IMAGE）"
  docker run -d --name "$NAPCAT_CONTAINER" --restart=always \
    -e "NAPCAT_UID=$uid" -e "NAPCAT_GID=$gid" -e TZ=Asia/Shanghai \
    -e "WEBUI_TOKEN=$ONEBOT_TOKEN" \
    -p "127.0.0.1:6099:6099" -p "127.0.0.1:${ONEBOT_PORT}:3000" \
    -v "$NAPCAT_DIR/docker/config:/app/napcat/config" \
    -v "$NAPCAT_DIR/docker/plugins:/app/napcat/plugins" \
    -v "$NAPCAT_DIR/docker/QQ:/app/.config/QQ" \
    "$NAPCAT_IMAGE" >/dev/null || die "容器创建失败，请手动执行 docker logs $NAPCAT_CONTAINER 排查"
  NAPCAT_MODE="docker"
  NAPCAT_ROOT="$NAPCAT_DIR/docker"
  save_state
  sleep 5
  local status=''
  status="$(docker ps --filter "name=$NAPCAT_CONTAINER" --format '{{.Status}}' 2>/dev/null || true)"
  [[ "$status" == *Up* ]] || die "NapCat 容器未正常运行，请查看：docker logs $NAPCAT_CONTAINER"
  ok "NapCat 容器已启动：$NAPCAT_CONTAINER（WebUI 127.0.0.1:6099，OneBot 127.0.0.1:$ONEBOT_PORT）"
  open_port 6099
}

# ---------------------------------------------------------------- 授权服务

install_auth_service(){
  need_project; need curl; need tar; need node
  if [[ ! -d "$AUTH_DIR" ]]; then
    info '下载 qq-miniapp-auth 源码…'
    local tmp="$TMPDIR/qq-miniapp-auth.$$.tar.gz"
    local -a srcs=()
    mapfile -t srcs < <(auth_tarball_urls)
    fetch_to "$tmp" "${srcs[@]}" || die 'qq-miniapp-auth 源码下载失败（所有源都不可用，可用 AUTH_TARBALL_URL 指定）'
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
    ok 'qq-miniapp-auth 依赖已安装，跳过 npm install'
  else
    npm_install_in "$AUTH_DIR"
  fi
  ok "qq-miniapp-auth 已准备：$AUTH_DIR"
}

# 依赖安装也走多源。注意：`npm ci` 不理会 --registry，它严格按 package-lock.json 里
# 写死的 resolved 地址下载；而 qq-miniapp-auth 的锁文件把 tarball 钉在 cdn.npmmirror.com，
# 那台服务器连不上那个 CDN，于是换源完全无效。所以这里先把锁文件的 resolved 改写成
# 当前源的规范地址（<registry>/<name>/-/<basename>-<version>.tgz），再执行 npm ci。
if [[ -n "${NPM_REGISTRIES_OVERRIDE:-}" ]]; then
  # 逗号或空格分隔，例：NPM_REGISTRIES_OVERRIDE=https://registry.npmmirror.com
  IFS=', ' read -r -a NPM_REGISTRIES <<< "$NPM_REGISTRIES_OVERRIDE"
else
  NPM_REGISTRIES=(
    "https://registry.npmmirror.com"
    "https://registry.npmjs.org"
    "https://mirrors.cloud.tencent.com/npm"
    "https://mirrors.huaweicloud.com/repository/npm"
    "https://registry.yarnpkg.com"
  )
fi

# 把锁文件里的 tarball 地址整体改指向指定源；非 registry 来源（git/file 依赖）原样保留
npm_rewrite_lock(){
  local dir="$1" reg="$2"
  local lock="$dir/package-lock.json"
  [[ -f "$lock" ]] || return 0
  local node_bin; node_bin="$(command -v node)" || return 1
  "$node_bin" - "$lock" "$reg" <<'JS'
const fs = require('fs');
const [lockPath, reg] = process.argv.slice(2);
const base = reg.replace(/\/+$/, '');
let lock;
try { lock = JSON.parse(fs.readFileSync(lockPath, 'utf8')); } catch (e) { process.exit(0); }
const pkgs = lock.packages || {};
let changed = 0;
for (const key of Object.keys(pkgs)) {
  const p = pkgs[key];
  if (!p || !p.version || !p.resolved) continue;
  if (!/^https?:/.test(p.resolved)) continue;           // git/ssh/file 依赖不动
  const name = p.name || key.replace(/^.*node_modules\//, '');
  if (!name || name.startsWith('.')) continue;
  const baseName = name.split('/').pop();
  const fixed = `${base}/${name}/-/${baseName}-${p.version}.tgz`;
  if (p.resolved !== fixed) { p.resolved = fixed; changed++; }
}
fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + '\n');
if (process.env.NPM_REWRITE_VERBOSE) process.stderr.write(`rewrote ${changed}\n`);
JS
}

npm_install_in(){
  local dir="$1"; shift
  local -a extra=()
  if (( $# )); then extra=("$@"); fi
  local reg rc lock_bak
  if [[ -d "$dir/node_modules" && -f "$dir/node_modules/.package-lock.json" ]]; then
    ok "依赖已安装，跳过：$dir"
    return 0
  fi
  lock_bak=""
  if [[ -f "$dir/package-lock.json" ]]; then
    lock_bak="$dir/package-lock.json.bak.$$"
    cp -f "$dir/package-lock.json" "$lock_bak"
  fi
  for reg in "${NPM_REGISTRIES[@]}"; do
    info "安装依赖（源：$reg）…"
    npm_rewrite_lock "$dir" "$reg" || true
    pushd "$dir" >/dev/null
    if [[ -f package-lock.json ]]; then
      npm ci --omit=dev --no-audit --no-fund --registry="$reg" ${extra[@]+"${extra[@]}"} && rc=0 || rc=$?
      # 锁文件与 registry 元数据不一致时 npm ci 会直接报错，退回普通 install 再试一次
      if [[ "$rc" -ne 0 ]]; then
        rm -rf node_modules
        npm install --omit=dev --no-audit --no-fund --registry="$reg" ${extra[@]+"${extra[@]}"} && rc=0 || rc=$?
      fi
    else
      npm install --omit=dev --no-audit --no-fund --registry="$reg" ${extra[@]+"${extra[@]}"} && rc=0 || rc=$?
    fi
    popd >/dev/null
    if [[ "$rc" -eq 0 ]]; then
      [[ -n "$lock_bak" ]] && rm -f "$lock_bak"
      return 0
    fi
    warn "该源安装失败（$reg），换下一个"
  done
  if [[ -n "$lock_bak" && -f "$lock_bak" ]]; then mv -f "$lock_bak" "$dir/package-lock.json" 2>/dev/null || rm -f "$lock_bak"; fi
  return 1
}

# 授权服务健康端点：以 HTTP 200 判断服务是否真正在跑。
# npm start 会再套一层 node 子进程，父进程退出后子进程可能仍占着端口，
# 只看 PID 文件会误判成「没在跑」而重复启动，造成 8787/9010 EADDRINUSE。
auth_health_url(){
  printf '%s/api/health' "${API_ENDPOINT:-http://127.0.0.1:8787}"
}

auth_is_healthy(){
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$(auth_health_url)" 2>/dev/null || true)"
  [[ "$code" == '200' ]]
}

# 结束本目录下残留的授权服务进程：命令行含服务入口、且工作目录就是 AUTH_DIR 才处理，
# 不碰其他目录下的 node 进程。
stop_auth_leftovers(){
  local p cmd cwd
  for p in $(pgrep -f 'start-all\.js|bridge\.js|server\.js' 2>/dev/null || true); do
    [[ -r "/proc/$p/cmdline" ]] || continue
    cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
    cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || true)"
    local is_entry
    is_entry=0
    [[ "$cmd" == *start-all.js* || "$cmd" == *bridge.js* || "$cmd" == *server.js* ]] && is_entry=1
    # 工作目录或命令行路径命中本目录才算，避免误杀其他项目的 node 服务
    if [[ "$is_entry" == 1 ]] && { [[ "$cwd" == "$AUTH_DIR" ]] || [[ "$cmd" == *"$AUTH_DIR"* ]]; }; then
      kill -TERM "$p" 2>/dev/null || true
    fi
  done
  sleep 2
}

# 兜底：若上面按目录清理后端口仍被占（例如残留进程工作目录不同），
# 用 fuser / lsof 结束占用授权服务端口的进程。只处理 8787 / 9010。
free_auth_ports(){
  local port holders
  for port in 8787 9010; do
    holders=''
    if command -v fuser >/dev/null 2>&1; then
      holders="$(fuser "$port/tcp" 2>/dev/null || true)"
    elif command -v lsof >/dev/null 2>&1; then
      holders="$(lsof -ti "tcp:$port" 2>/dev/null || true)"
    fi
    for p in $holders; do
      kill -TERM "$p" 2>/dev/null || true
    done
  done
  [[ -n "${holders:-}" ]] && sleep 2 || true
}

start_auth_service(){
  install_auth_service
  local pid_file="$AUTH_DIR/qq-miniapp-auth.pid"
  if auth_is_healthy; then
    ok "qq-miniapp-auth 已在运行（服务响应正常）"
    return 0
  fi
  if [[ -f "$pid_file" ]]; then
    local oldpid
    oldpid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      ok "qq-miniapp-auth 已在后台运行，PID $oldpid"
      return 0
    fi
  fi
  # 服务不可用：先清掉上次残留的进程，避免端口仍被占用
  stop_auth_leftovers
  auth_is_healthy || free_auth_ports
  local log="$AUTH_DIR/qq-miniapp-auth.log"
  pushd "$AUTH_DIR" >/dev/null
  nohup npm start >>"$log" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" > "$pid_file"
  popd >/dev/null
  local i
  for ((i=0; i<15; i++)); do
    auth_is_healthy && break
    sleep 1
  done
  if auth_is_healthy; then
    ok "qq-miniapp-auth 已后台启动，PID=$pid，日志：$log"
    return 0
  fi
  kill -0 "$pid" 2>/dev/null || die "qq-miniapp-auth 启动失败，请查看 $log"
  die "qq-miniapp-auth 已启动但服务未就绪，请查看 $log"
}

stop_auth_service(){
  local pid_file="$AUTH_DIR/qq-miniapp-auth.pid"
  local pid=''
  if [[ -f "$pid_file" ]]; then
    pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
  fi
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    # npm start 会再套一层 node，整组一起结束
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  # 兜底：清掉工作目录在本目录下、命令行命中服务入口的残留进程；
  # 它们才是真正占着 8787/9010 的进程，只杀 PID 文件里的 npm 父进程不够。
  stop_auth_leftovers
  return 0
}

restart_auth_service(){
  info '正在重启 qq-miniapp-auth（会清空卡住的扫码登录状态）…'
  stop_auth_service
  start_auth_service
}

# QQ 扫码登录卡在「工作流繁忙」时，内存里的单例工作流没释放，只能重启授权服务。
# NapCat 侧还会残留 WebUI 的 QQLoginStatus 标志，一并让它重启 worker。
fix_qq_login(){
  load_state
  local health
  health="$(curl -fsS --max-time 3 "${API_ENDPOINT%/}/api/health" 2>/dev/null || true)"
  if [[ -n "$health" ]]; then
    if command -v node >/dev/null 2>&1; then
      printf '%s' "$health" | node -e '
let raw = "";
process.stdin.on("data", d => raw += d).on("end", () => {
  try {
    const h = JSON.parse(raw);
    if (h.workflowBusy) console.log(`[状态] 有扫码登录卡住：phase=${h.workflowPhase || "?"}`);
    else console.log("[状态] 当前没有卡住的登录工作流");
    if (h.logoutRecoveryRequired) console.log("[状态] 上一次 QQ 注销未完成，需要恢复");
  } catch { console.log("[状态] 授权服务返回内容无法解析"); }
});
' >&2 || true
    fi
  else
    warn "授权服务没有响应（$API_ENDPOINT），将直接重启它"
  fi
  restart_auth_service
  # 清掉 NapCat WebUI 里残留的登录标志，否则新二维码可能仍被拒
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    docker restart "$NAPCAT_CONTAINER" >/dev/null 2>&1 || true
  elif command -v curl >/dev/null 2>&1; then
    local token=''
    local webui_cfg="${NAPCAT_ROOT:-$NAPCAT_DIR}/config/webui.json"
    if [[ -f "$webui_cfg" ]]; then
      token="$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).token||"")}catch{}' "$webui_cfg" 2>/dev/null || true)"
    fi
    if [[ -n "$token" ]]; then
      curl -fsS --max-time 5 -X POST "http://127.0.0.1:6099/api/QQLogin/RestartNapCat" \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
    fi
  fi
  ok 'QQ 扫码登录状态已重置，回到面板重新点「刷新二维码」即可'
  report_panel_access 0
}

# ---------------------------------------------------------------- 插件安装

install_napcat_plugin(){
  need node
  read_settings
  [[ -d "$AUTH_DIR/napcat-openauth-plugin" ]] || die 'qq-miniapp-auth 中缺少 napcat-openauth-plugin'
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NAPCAT_CONTAINER" \
      || die "NapCat 容器不存在：$NAPCAT_CONTAINER"
    info '安装 qq-miniapp-openauth 插件到 NapCat 容器…'
    local plugin_dir="$NAPCAT_DIR/docker/plugins/qq-miniapp-openauth"
    mkdir -p "$plugin_dir"
    cp -a "$AUTH_DIR/napcat-openauth-plugin/." "$plugin_dir/"
    docker exec -u 0 "$NAPCAT_CONTAINER" bash -c '
f=/app/napcat/napcat.mjs
[ -f "$f" ] || exit 2
grep -Fq "\"qq-miniapp-openauth\"" "$f" && exit 0
grep -Fq "\"napcat-plugin-qce\"" "$f" || exit 3
sed -i "0,/\"napcat-plugin-qce\"/s//\"napcat-plugin-qce\",\n  \"qq-miniapp-openauth\"/" "$f"
' || warn '容器内白名单补丁失败（插件目录已放入，可能需要手动处理）'
    local token
    token="$(sed -n 's/^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=//p' "$AUTH_DIR/.env" 2>/dev/null | sed -n '1p' || true)"
    [[ -n "$token" ]] || token="$ONEBOT_TOKEN"
    mkdir -p "$NAPCAT_DIR/docker/config/plugins/qq-miniapp-openauth"
    node -e '
const fs = require("fs");
const [out, token] = process.argv.slice(1);
fs.writeFileSync(out, JSON.stringify({ token }, null, 2) + "\n");
' "$NAPCAT_DIR/docker/config/plugins/qq-miniapp-openauth/config.json" "$token"
    node -e '
const fs = require("fs");
const p = process.argv[1];
let obj = {};
try { obj = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { obj = {}; }
obj["qq-miniapp-openauth"] = true;
fs.mkdirSync(require("path").dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
' "$NAPCAT_DIR/docker/config/plugins.json"
    write_plugin_token "$token"
    save_state
    docker restart "$NAPCAT_CONTAINER" >/dev/null 2>&1 || true
    ok 'qq-miniapp-openauth 插件已安装到 NapCat 容器'
    return 0
  fi
  local napcat_root="${NAPCAT_ROOT:-}"
  if [[ -z "$napcat_root" ]]; then
    napcat_root="$(napcat_detect_root || true)"
  fi
  [[ -n "$napcat_root" && -f "$napcat_root/napcat.mjs" ]] \
    || die "找不到 NapCat 根目录中的 napcat.mjs：${napcat_root:-未找到}"
  info '安装 qq-miniapp-openauth NapCat 插件…'
  local plugin_dir="$napcat_root/plugins/qq-miniapp-openauth"
  local plugin_cfg="$napcat_root/config/plugins/qq-miniapp-openauth/config.json"
  mkdir -p "$plugin_dir" "$(dirname "$plugin_cfg")"
  cp -a "$AUTH_DIR/napcat-openauth-plugin/." "$plugin_dir/"
  local token
  token="$(sed -n 's/^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=//p' "$AUTH_DIR/.env" 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$token" ]] || token="$ONEBOT_TOKEN"
  node -e '
const fs = require("fs");
const [out, token] = process.argv.slice(1);
fs.writeFileSync(out, JSON.stringify({ token }, null, 2) + "\n");
' "$plugin_cfg" "$token"
  chmod 600 "$plugin_cfg" 2>/dev/null || true
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
    cp -a "$napcat_root/napcat.mjs" "$napcat_root/napcat.mjs.bak.$(date +%Y%m%d%H%M%S)"
    node -e '
const fs = require("fs");
const [p] = process.argv.slice(1);
let s = fs.readFileSync(p, "utf8");
const marker = "\"napcat-plugin-qce\"";
const plugin = "\"qq-miniapp-openauth\"";
const i = s.indexOf(marker);
if (i < 0) { console.error("plugin whitelist marker not found"); process.exit(1); }
s = s.slice(0, i + marker.length) + ",\n  " + plugin + s.slice(i + marker.length);
fs.writeFileSync(p + ".tmp", s);
fs.renameSync(p + ".tmp", p);
' "$napcat_root/napcat.mjs"
  fi
  write_plugin_token "$token"
  NAPCAT_ROOT="$napcat_root"
  save_state
  ok "qq-miniapp-openauth 插件已安装：$plugin_dir"
}

write_plugin_token(){
  local token="$1"
  node -e '
const fs = require("fs");
const [envPath, token] = process.argv.slice(1);
let s = fs.readFileSync(envPath, "utf8");
const line = "NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=" + token;
const re = /^NAPCAT_OPEN_AUTH_PLUGIN_TOKEN=.*$/m;
s = re.test(s) ? s.replace(re, line) : s + (s.endsWith("\n") ? "" : "\n") + line + "\n";
fs.writeFileSync(envPath, s);
' "$AUTH_DIR/.env" "$token"
}

# ---------------------------------------------------------------- OneBot / 农场配置

find_onebot_configs(){
  local root="${1:-${NAPCAT_ROOT:-}}"
  [[ -n "$root" ]] || return 0
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

# OneBot HTTP 端口是否已在监听（NapCat 真正加载配置的判据）
onebot_listening(){
  local pids; pids="$(port_listen_pids "$ONEBOT_PORT")"
  [[ -n "$pids" ]] && return 0
  if command -v curl >/dev/null 2>&1; then
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$ONEBOT_PORT/" 2>/dev/null || true)"
    # 只要不是 000（连不上），即使返回 4xx 也说明端口在监听、NapCat 已加载配置
    [[ -n "$code" && "$code" != '000' ]] && return 0
  fi
  return 1
}

configure_napcat(){
  read_settings
  local cfg_dir
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    cfg_dir="$NAPCAT_DIR/docker/config"
  else
    local root="${NAPCAT_ROOT:-}"
    [[ -n "$root" ]] || root="$(napcat_detect_root || true)"
    [[ -n "$root" ]] || die '找不到 NapCat 根目录，无法写 OneBot 配置'
    cfg_dir="$root/config"
  fi
  local files=()
  mapfile -t files < <(find_onebot_configs "$(dirname "$cfg_dir")" || true)
  if ((${#files[@]} == 0)); then
    mkdir -p "$cfg_dir"
    files=("$cfg_dir/onebot11.json")
  fi
  local file
  for file in "${files[@]}"; do
    mkdir -p "$(dirname "$file")"
    if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
      # 容器内 OneBot 必须绑 0.0.0.0，否则宿主端口映射访问不到
      configure_onebot_file "$file" '0.0.0.0'
    else
      configure_onebot_file "$file" '127.0.0.1'
    fi
  done
  ok "NapCat OneBot HTTP 服务已配置：$([[ "${NAPCAT_MODE:-}" == 'docker' ]] && echo 0.0.0.0 || echo 127.0.0.1):$ONEBOT_PORT"
  info "qq-miniapp-auth API 地址：$API_ENDPOINT"
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    docker restart "$NAPCAT_CONTAINER" >/dev/null 2>&1 || warn 'NapCat 容器重启失败，请手动执行 docker restart'
    sleep 3
    ok 'NapCat 容器已重启以加载 OneBot 配置'
  else
    # 原生模式下 NapCat 正在跑时，配置改动必须重启才会生效；否则配置写了但端口不监听
    local running; running="$(napcat_running_pids)"
    if [[ -n "$running" ]]; then
      info 'NapCat 正在运行，重启以加载新的 OneBot 配置…'
      kill_napcat_pids "$running"
      rm -f "$NAPCAT_PID"
    fi
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

start_napcat(){
  load_state
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    docker start "$NAPCAT_CONTAINER" >/dev/null 2>&1 || true
    sleep 3
    local status=''
    status="$(docker ps --filter "name=$NAPCAT_CONTAINER" --format '{{.Status}}' 2>/dev/null || true)"
    [[ "$status" == *Up* ]] || die "NapCat 容器启动失败：docker logs $NAPCAT_CONTAINER"
    ok "NapCat 容器已运行：$NAPCAT_CONTAINER"
    return 0
  fi
  local qq
  qq="$(napcat_detect_qq || true)"
  [[ -n "$qq" ]] || die "未找到 QQ 可执行文件（$HOME/Napcat/opt/QQ/qq 或 /opt/QQ/qq）"

  # 只要 OneBot 端口已经在监听，说明 NapCat 已带配置正常运行，直接复用，不再拉起第二个实例
  if onebot_listening; then
    ok "NapCat 的 OneBot 服务已在监听 $ONEBOT_PORT，跳过重复启动"
    return 0
  fi

  # 清理残留的 NapCat QQ 进程：多实例竞争会导致只有一个加载 OneBot 配置，
  # 另一个不监听 3000，二维码接口取不到数据。启动前保证从单实例开始。
  local stale; stale="$(napcat_running_pids)"
  if [[ -n "$stale" ]]; then
    warn '检测到残留的 NapCat QQ 进程，先结束它们，保证只有一个实例加载配置'
    kill_napcat_pids "$stale"
  fi
  if [[ -f "$NAPCAT_PID" ]] && kill -0 "$(cat "$NAPCAT_PID" 2>/dev/null || echo 0)" 2>/dev/null; then
    ok "NapCat 已在运行，PID $(cat "$NAPCAT_PID")"
    return 0
  fi
  if ! command -v xvfb-run >/dev/null 2>&1; then
    warn '未安装 xvfb-run，尝试安装…'
    install_pkgs xvfb >/dev/null 2>&1 || install_pkgs xorg-x11-server-Xvfb >/dev/null 2>&1 || true
  fi
  mkdir -p "$NAPCAT_DIR"
  printf '\n===== NapCat start %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$NAPCAT_LOG"
  info "启动 NapCat：$qq"
  nohup bash -c "xvfb-run -a '$qq' --no-sandbox" >>"$NAPCAT_LOG" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" > "$NAPCAT_PID"
  disown 2>/dev/null || true
  sleep 3
  local alive=0
  if kill -0 "$pid" 2>/dev/null; then alive=1; fi
  if [[ "$alive" -eq 0 ]]; then
    sleep 3
    kill -0 "$pid" 2>/dev/null && alive=1 || alive=0
  fi
  if [[ "$alive" -eq 0 ]]; then
    tail -15 "$NAPCAT_LOG" >&2 || true
    die "NapCat 启动失败，请查看日志：$NAPCAT_LOG"
  fi
  info '等待 WebUI 就绪…'
  local i=0
  while ((i < 60)); do
    if grep -qE 'WebUi.*(Panel Url|Token)' "$NAPCAT_LOG" 2>/dev/null; then break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    ((i++)) || true
  done
  ok "NapCat 已后台启动，PID=$pid，日志：$NAPCAT_LOG"
  # OneBot HTTP 服务要在 NapCat 成功加载 QQ 登录态与配置后才会监听；
  # 这里再等最多 30 秒，超时给明确提示，避免面板拿到一个没起来的 3000 端口。
  local w=0
  while ((w < 30)); do
    onebot_listening && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    ((w++)) || true
  done
  if onebot_listening; then
    ok "NapCat OneBot HTTP 服务已在监听 $ONEBOT_PORT"
  else
    warn "NapCat 进程已起，但 OneBot 端口 $ONEBOT_PORT 尚未监听：通常需要在 WebUI 扫码登录 QQ 后才会加载配置；请打开 WebUI 完成登录：http://127.0.0.1:6099/webui/"
  fi
  info '打开 NapCat WebUI 扫码登录 QQ：http://127.0.0.1:6099/webui/'
}

stop_napcat(){
  load_state
  if [[ "${NAPCAT_MODE:-}" == 'docker' ]]; then
    docker stop "$NAPCAT_CONTAINER" >/dev/null 2>&1 || true
    ok "NapCat 容器已停止：$NAPCAT_CONTAINER"
    return 0
  fi
  local pid=''
  if [[ -f "$NAPCAT_PID" ]]; then
    pid="$(tr -d '[:space:]' < "$NAPCAT_PID" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$NAPCAT_PID"
  fi
  # 只结束本脚本拉起的 NapCat（rootless 安装路径），不做全局 pkill
  pkill -f "Napcat/opt/QQ/qq" 2>/dev/null || true
  sleep 1
  ok 'NapCat 已停止'
}

restart_napcat(){
  info '正在重启 NapCat…'
  stop_napcat || true
  sleep 2
  start_napcat
}

install_pkgs(){
  (($#)) || return 0
  if command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive as_root apt-get install -y "$@" || return 1
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y "$@" || return 1
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y "$@" || return 1
  else
    warn '未识别的包管理器，跳过系统依赖安装'
  fi
}

# ---------------------------------------------------------------- 农场本体

run_pnpm(){
  local bin
  bin="$(pnpm_bin)" || die '无法准备 pnpm（已试本地安装与 corepack）'
  if [[ "$bin" == "__corepack__" ]]; then
    # corepack 沿用它自带的版本，但要跳过 packageManager 版本校验
    COREPACK_NPM_REGISTRY="${NPM_REGISTRIES[0]}" corepack pnpm --pm-on-fail=ignore "$@"
    return
  fi
  local node_bin
  node_bin="$(command -v node 2>/dev/null || true)"
  export NO_UPDATE_NOTIFIER=1
  # pnpm 的入口是 .cjs，需要 Node 来跑；系统装了 pnpm 时可执行文件则直接调用
  if [[ "$bin" == *.cjs || "$bin" == *.js ]]; then
    [[ -n "$node_bin" ]] || die '找不到 node，无法运行 pnpm'
    "$node_bin" "$bin" "$@"
  else
    "$bin" "$@"
  fi
}

# 项目 package.json 里 packageManager 声明的 pnpm 版本（形如 pnpm@10.30.2）
pnpm_required_version(){
  local node_bin ver
  node_bin="$(command -v node 2>/dev/null || true)"
  if [[ -n "$node_bin" && -f "$PROJECT_DIR/package.json" ]]; then
    ver="$("$node_bin" -e 'try{const p=require(process.argv[1]);const m=(p.packageManager||"").match(/^pnpm@(.+)$/);process.stdout.write(m?m[1]:"");}catch(e){}' "$PROJECT_DIR/package.json" 2>/dev/null || true)"
    if [[ -n "$ver" ]]; then printf '%s' "$ver"; return 0; fi
  fi
  printf '%s' "${PNPM_VERSION:-10.30.2}"
}

# 返回一个可执行的 pnpm 入口。优先用与项目声明版本一致的本地安装，
# 避免 corepack 自行下载最新版后因 packageManager 不匹配而直接失败。
pnpm_bin(){
  if [[ -n "${_PNPM_BIN_RESOLVED:-}" && -e "$_PNPM_BIN_RESOLVED" ]]; then
    printf '%s' "$_PNPM_BIN_RESOLVED"; return 0
  fi
  local want reg dir entry ver_out
  want="$(pnpm_required_version)"
  dir="$NAPCAT_DIR/tools/pnpm/$want"
  entry="$dir/node_modules/pnpm/bin/pnpm.cjs"

  # 1) 已经装好过
  if [[ -f "$entry" ]]; then
    _PNPM_BIN_RESOLVED="$entry"; printf '%s' "$entry"; return 0
  fi

  # 2) 系统里现成的 pnpm 版本刚好一致就直接用
  if command -v pnpm >/dev/null 2>&1; then
    ver_out="$(pnpm --version 2>/dev/null || true)"
    if [[ "$ver_out" == "$want" ]]; then
      _PNPM_BIN_RESOLVED="$(command -v pnpm)"; printf '%s' "$_PNPM_BIN_RESOLVED"; return 0
    fi
  fi

  # 3) 用 npm 把这个版本装到脚本目录下（不需要 root，也不碰全局环境）
  if command -v npm >/dev/null 2>&1; then
    mkdir -p "$dir"
    for reg in "${NPM_REGISTRIES[@]}"; do
      if npm install --prefix "$dir" --no-save --no-audit --no-fund --registry="$reg" "pnpm@$want" >/dev/null 2>&1; then
        if [[ -f "$entry" ]]; then
          _PNPM_BIN_RESOLVED="$entry"; printf '%s' "$entry"; return 0
        fi
      fi
    done
  fi

  # 4) 兜底：corepack 带 --pm-on-fail=ignore 跳过版本校验
  if command -v corepack >/dev/null 2>&1; then
    _PNPM_BIN_RESOLVED="__corepack__"; printf '%s' "__corepack__"; return 0
  fi
  return 1
}

# pnpm install 也按源逐个重试，全部失败才由调用方处理
pnpm_install_multi(){
  local dir="$1"; shift
  local reg
  for reg in "${NPM_REGISTRIES[@]}"; do
    info "安装依赖（源：$reg）…"
    if run_pnpm -C "$dir" install --frozen-lockfile --registry="$reg" "$@"; then
      return 0
    fi
    # 锁文件与当前源解析不出同一个版本时 --frozen-lockfile 会直接拒绝，去掉该限制再试一次
    rm -rf "$dir/node_modules"
    if run_pnpm -C "$dir" install --registry="$reg" "$@"; then
      return 0
    fi
    warn "该源安装失败（$reg），换下一个"
  done
  return 1
}

# 列出监听指定 TCP 端口的进程 PID（尽力而为，逐行去重；工具缺失时返回空）
port_listen_pids(){
  local port="$1" pids='' x
  if command -v fuser >/dev/null 2>&1; then
    x="$(fuser -n tcp "$port" 2>&1 | grep -oE '[0-9]+' || true)"
    pids="$pids $x"
  fi
  if command -v ss >/dev/null 2>&1; then
    x="$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 || true)"
    pids="$pids $x"
  fi
  if command -v lsof >/dev/null 2>&1; then
    x="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    pids="$pids $x"
  fi
  printf '%s\n' "$pids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true
}

source_running(){
  # 先按 PID 文件判断
  if [[ -f "$SOURCE_PID" ]]; then
    local pid; pid="$(cat "$SOURCE_PID" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      local cmd; cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
      [[ "$cmd" == *core/client.js* ]] && return 0
    fi
  fi
  # PID 文件失效时，按端口找出真正在跑的服务并回写 PID，避免重复启动撞端口
  local port; port="$(farm_port)"
  local p pids; pids="$(port_listen_pids "$port")"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    local pcmd; pcmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
    if [[ "$pcmd" == *core/client.js* ]]; then
      printf '%s' "$p" > "$SOURCE_PID"
      return 0
    fi
  done <<< "$pids"
  return 1
}

# 构建产物比源码旧（或不存在）时才重新构建，避免每次启动都重跑一遍构建。
needs_build(){
  local out="$1"; shift
  [[ -f "$out" ]] || return 0
  local newer
  newer="$(find "$@" -newer "$out" -print -quit 2>/dev/null || true)"
  [[ -n "$newer" ]]
}

start_source(){
  need_project
  if source_running; then
    ok "源码服务已在运行，PID $(cat "$SOURCE_PID")"
    report_panel_access 0
    return 0
  fi
  local first_run=0
  creds_shown || first_run=1
  if [[ ! -d "$PROJECT_DIR/node_modules" ]]; then
    pnpm_install_multi "$PROJECT_DIR" || die '依赖安装失败：已试全部 npm 镜像，可用 NPM_REGISTRIES 环境变量覆盖'
  fi
  if needs_build "$PROJECT_DIR/web/dist/index.html" "$PROJECT_DIR/web/src" "$PROJECT_DIR/web/package.json" "$PROJECT_DIR/web/vite.config.ts"; then
    info '构建前端（pnpm -C web run build）…'
    run_pnpm -C "$PROJECT_DIR/web" run build
  fi
  if needs_build "$PROJECT_DIR/core/client.js" "$PROJECT_DIR/core/src" "$PROJECT_DIR/core/package.json" "$PROJECT_DIR/core/tsconfig.json"; then
    info '构建后端（pnpm -C core run build:ts）…'
    run_pnpm -C "$PROJECT_DIR/core" run build:ts
  fi
  : > "$SOURCE_LOG"; : > "$SOURCE_ERR"
  info '后台启动源码服务…'
  ( cd "$PROJECT_DIR" && nohup node core/client.js >>"$SOURCE_LOG" 2>>"$SOURCE_ERR" </dev/null & echo $! > "$SOURCE_PID" )
  sleep 4
  local pid; pid="$(cat "$SOURCE_PID" 2>/dev/null || echo '')"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    ok "源码服务已后台启动，PID=$pid，日志：$SOURCE_LOG"
    if [[ "$first_run" == 1 ]]; then
      report_panel_access 1 admin admin
      mark_creds_shown
    else
      report_panel_access 0
    fi
  else
    tail -20 "$SOURCE_ERR" >&2 || true
    die "源码服务启动失败，请查看 $SOURCE_ERR"
  fi
}

compose_up(){
  local -a cmd=()
  if docker compose version >/dev/null 2>&1; then
    cmd=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    cmd=(docker-compose)
  else
    die '未安装 Docker Compose（apt install docker-compose-plugin / dnf install docker-compose-plugin），或改用选项 1'
  fi
  ( cd "$PROJECT_DIR" && "${cmd[@]}" -f "$COMPOSE_FILE" up -d --build )
}

start_docker(){
  local quiet="${1:-0}"
  need docker
  need_project
  docker info >/dev/null 2>&1 || die 'Docker 未运行或当前用户无权访问 Docker'
  local first_run=0
  creds_shown || first_run=1
  info '启动农场容器…'
  compose_up
  ok '农场 Docker 已启动'
  if [[ "$quiet" == 1 ]]; then
    return 0
  fi
  if [[ "$first_run" == 1 ]]; then
    report_panel_access 1 admin admin
    mark_creds_shown
  else
    report_panel_access 0
  fi
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
  mark_creds_shown
  report_panel_access 1 admin "$password"
}

# ---------------------------------------------------------------- 菜单

# ---------------------------------------------------------------- 服务组控制（供子菜单调用）

# 停止 Docker 农场（复用 compose 探测，只 stop 不删容器）
compose_stop(){
  need docker
  local -a cmd=()
  if docker compose version >/dev/null 2>&1; then
    cmd=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    cmd=(docker-compose)
  else
    die '未安装 Docker Compose（apt install docker-compose-plugin / dnf install docker-compose-plugin）'
  fi
  ( cd "$PROJECT_DIR" && "${cmd[@]}" -f "$COMPOSE_FILE" stop )
}

# 农场服务：只启停农场本身，不碰 NapCat / 授权服务
start_farm(){
  local mode="${1:-source}"
  if [[ "$mode" == 'docker' ]]; then start_docker; else start_source; fi
}

stop_farm(){
  local mode="${1:-source}"
  need_project
  if [[ "$mode" == 'docker' ]]; then
    need docker
    docker info >/dev/null 2>&1 || die 'Docker 未运行或当前用户无权访问 Docker'
    compose_stop
    ok '农场 Docker 已停止'
  else
    local pids='' pid
    if [[ -f "$SOURCE_PID" ]]; then
      pid="$(tr -d '[:space:]' < "$SOURCE_PID" 2>/dev/null || true)"
      [[ -n "$pid" ]] && pids="$pids $pid"
    fi
    # PID 文件可能已失效，再从监听端口找出真正占着端口的农场进程
    local port; port="$(farm_port)"
    pids="$pids $(port_listen_pids "$port")"
    for pid in $pids; do
      local pcmd; pcmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
      [[ "$pcmd" == *core/client.js* ]] || continue
      kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in $pids; do
      kill -9 "$pid" 2>/dev/null || true
    done
    rm -f "$SOURCE_PID"
    ok '农场源码服务已停止'
  fi
}

restart_farm(){
  local mode="${1:-source}"
  stop_farm "$mode"
  sleep 2
  start_farm "$mode"
}

# 整套服务：农场 + 授权服务 + NapCat
start_stack(){
  local mode="${1:-source}"
  start_farm "$mode"
  start_auth_service
  start_napcat
}

stop_stack(){
  local mode="${1:-source}"
  stop_farm "$mode"
  stop_napcat
  stop_auth_service
  ok '整套服务已停止'
}

restart_stack(){
  local mode="${1:-source}"
  stop_stack "$mode"
  sleep 2
  start_stack "$mode"
}

# 完整安装配置流程（首次用）：源码模式
auto_install_shell(){
  if ! preflight_install shell; then
    warn '环境检查未通过，已取消安装，请处理后重试'
    return 1
  fi
  read_settings
  install_napcat_shell
  install_auth_service
  install_napcat_plugin
  configure_napcat
  configure_source
  # 农场服务按默认版的方式后台启动；先起农场，再拉起 NapCat/授权服务。
  # 这样即使 NapCat 的 QQ 登录暂时没就绪，面板也已经在后台运行。
  start_source
  start_auth_service
  start_napcat
}

# 完整安装配置流程（首次用）：Docker 模式
auto_install_docker(){
  if ! preflight_install docker; then
    warn '环境检查未通过，已取消安装，请处理后重试'
    return 1
  fi
  read_settings
  install_napcat_docker
  install_auth_service
  install_napcat_plugin
  configure_napcat
  start_docker 1
  configure_docker
  start_auth_service
  start_napcat
  if creds_shown; then
    report_panel_access 0
  else
    report_panel_access 1 admin admin
    mark_creds_shown
  fi
}

# -------- 二级菜单：默认版（只启动农场，不碰 NapCat）

menu_default(){
  while true; do
    printf '\n---- 默认版（只启动农场，不碰 NapCat）----\n'
    printf '1. 源码后台启动\n'
    printf '2. Docker 启动\n'
    printf '3. 停止源码服务\n'
    printf '4. 重启源码服务\n'
    printf '5. 停止 Docker 服务\n'
    printf '6. 重启 Docker 服务\n'
    printf '0. 返回上级\n'
    read -r -p '请选择：' c
    case "$c" in
      1) start_source;;
      2) start_docker;;
      3) stop_farm source;;
      4) restart_farm source;;
      5) stop_farm docker;;
      6) restart_farm docker;;
      0) return 0;;
      *) warn '无效选项';;
    esac
    read -r -p '按回车继续…' _
  done
}

# -------- 二级菜单：自动配置版（自动安装并配置 NapCat 与 qq-miniapp-auth）

menu_auto(){
  while true; do
    printf '\n---- 自动配置版（自动安装并配置 NapCat 与 qq-miniapp-auth）----\n'
    printf '1. 源码启动 + 全自动安装配置 NapCatShell\n'
    printf '2. Docker 启动 + 全自动安装配置 NapCat\n'
    printf '3. 启动源码\n'
    printf '4. 停止源码\n'
    printf '5. 重启源码\n'
    printf '6. Docker启动\n'
    printf '7. 停止Docker\n'
    printf '8. 重启Docker\n'
    printf '0. 返回上级\n'
    read -r -p '请选择：' c
    case "$c" in
      1) auto_install_shell;;
      2) auto_install_docker;;
      3) start_stack source;;
      4) stop_stack source;;
      5) restart_stack source;;
      6) start_stack docker;;
      7) stop_stack docker;;
      8) restart_stack docker;;
      0) return 0;;
      *) warn '无效选项';;
    esac
    read -r -p '按回车继续…' _
  done
}

# -------- 二级菜单：NapCat 管理（启动 / 停止 / 重启 / 修复 QQ 扫码）

menu_napcat(){
  while true; do
    printf '\n---- NapCat 管理 ----\n'
    printf '1. 启动 NapCat\n'
    printf '2. 停止 NapCat\n'
    printf '3. 重启 NapCat\n'
    printf '4. 修复 QQ 扫码登录（重置卡住的登录状态）\n'
    printf '0. 返回上级\n'
    read -r -p '请选择：' c
    case "$c" in
      1) start_napcat;;
      2) stop_napcat;;
      3) restart_napcat;;
      4) fix_qq_login;;
      0) return 0;;
      *) warn '无效选项';;
    esac
    read -r -p '按回车继续…' _
  done
}

menu(){
  while true; do
    printf '\n==== QQ Farm Bot + NapCat ====\n'
    printf '1. 默认版\n'
    printf '2. 自动配置版\n'
    printf '5. NapCat 管理\n'
    printf '6. 重置管理员密码\n'
    printf '0. 退出\n'
    read -r -p '请选择：' choice
    case "$choice" in
      1) menu_default; continue;;
      2) menu_auto; continue;;
      5) menu_napcat; continue;;
      6) reset_admin;;
      0) exit 0;;
      *) warn '无效选项';;
    esac
    read -r -p '按回车继续…' _
  done
}

need_project
menu
