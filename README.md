# QQ 农场多账号挂机 + Web 面板

> 本仓库（两个平台同步，内容一致）：[GitHub](https://github.com/BUGDey/qq-farm-bot-ll) · [Gitee](https://gitee.com/bugdey/qq-farm-bot-ll)
>
> 基于上游 [liyangpengs/qq-farm-bot](https://github.com/liyangpengs/qq-farm-bot) 整理，额外附带 `qq-farm.sh` 一键管理脚本（Linux，自动安装并配置 NapCat / QQ 扫码）。国内服务器访问 Gitee 更快。

基于 Node.js 的 QQ 农场自动化工具，提供多账号挂机、农场与好友自动化、独立图鉴与藏品、活动中心、商城、数据分析和 Web 控制面板。当前项目版本为 `20261102`，QQ 与微信游戏协议版本均为 `1.16.1.6_20261028`，两端独立维护版本配置和 TSDK/WASM。

> [!IMPORTANT]
> 首次启动会创建默认管理员 `admin` / `admin`，Web 面板默认端口为 `3007`。对外部署后请立即修改密码，并避免将未加防护的管理端口直接暴露到公网。

## 项目截图
|  |  |
| --- | --- |
| ![项目截图 1](https://free.picui.cn/free/2026/08/21/6a87f4e28ce59.jpg) | ![项目截图 2](https://free.picui.cn/free/2026/08/21/6a87f4e2e5557.jpg) |
| ![项目截图 3](https://free.picui.cn/free/2026/08/21/6a87f4e3780bb.jpg) | ![项目截图 4](https://free.picui.cn/free/2026/08/21/6a87f4e398c30.jpg) |
| ![项目截图 5](https://free.picui.cn/free/2026/08/21/6a87f4e8bbbce.jpg) | ![项目截图 6](https://free.picui.cn/free/2026/08/21/6a87f4e90d06c.jpg) |
| ![项目截图 7](https://free.picui.cn/free/2026/08/21/6a87f4e95678d.jpg) | ![项目截图 8](https://free.picui.cn/free/2026/08/21/6a87f4e958eae.jpg) |
| ![项目截图 9](https://free.picui.cn/free/2026/08/21/6a87f4e91bccb.jpg) | ![项目截图 10](https://free.picui.cn/free/2026/08/21/6a87f4e355da8.jpg) |

## 功能概览

### 账号与登录

- 游戏账号可无限添加并独立运行，每个账号可单独配置种植、好友、自动化和执行间隔策略
- 支持抓包 Code 登录、微信扫码登录和 QQ扫码登录
- 支持账号启停、状态监控、实时日志和离线提醒
- Web 面板只保留一个超级管理员，不提供注册、普通用户和租户隔离

### 农场自动化

- 自动收获、种植、浇水、除草、除虫、铲除和土地升级
- 自动施肥、多季作物补肥、指定土地类型施肥和化肥自动购买
- 支持一键务农、一键种植、一键收获、一键铲除和一键全收等面板操作
- 支持多种种植策略、背包种子优先级、作物黑名单和执行间隔配置
- 汇总任务、免费礼包、分享奖励、会员礼包、月卡礼包和图鉴奖励等每日状态，并按天自动处理支持的领取项

### 图鉴

- 在“个人 → 图鉴”中查看作物图鉴和超变图鉴的等级、进度及果实收藏状态
- 作物图鉴按游戏配置排序展示作物，收藏奖励统一放在详情弹窗中查看
- 超变图鉴依据 `Illustrated.json` 的 `param` 和 `type` 字段区分黄金果实、活动果实与装扮果实，不依赖果实名或协议奖励分类字段推断
- 超变属性弹窗顶部汇总当前生效加成，等级列表展示属性名称、触发概率或数量，以及已达成状态或所需进度
- 移动端图鉴使用四列果实布局，等级进度和弹窗样式与现有面板保持一致

### 好友互动

- 自动访问好友、偷菜、帮忙浇水、除草除虫及放草放虫
- 支持好友黑名单、安静时段和互动经验上限
- 支持已知好友 GID 的批量维护、同步参数和互动记录查询
- 好友巡查合并为单次访问：每位好友只进一次农场，一次做完帮忙（除草/除虫/浇水）、偷菜和捣乱（放草/放虫）
- 好友上场宠物按天缓存：进好友农场时顺手记录，另有后台分批的每日补齐，“护主犬经验满仍帮忙”不再每轮逐个进农场试探
- 面板可对指定好友执行单次访问或农场操作

### 背包与交易

- 查看背包，使用、出售或批量出售物品
- 根据游戏配置判断活动区间外、活动结束后和道具过期后的物品可售状态
- 查看神秘商人活动商品及购买状态
- 浏览游戏商城商品、价格、折扣和限购信息，并执行购买
- 查询种子、果实、道具和作物收益数据

### 活动中心

- 通过活动列表协议统一展示当前活动和已结束活动；未实现详情页的活动仍会显示，但不可进入玩法页面
- 千星游记：查看赛季与通行证进度，领取可用奖励
- 观星礼录：查看星座进度、点亮星座并领取奖励
- 星砂商店：查看星砂余额和活动商品，执行兑换
- 节令活动：查看当前节令并领取开放奖励
- 鹊桥寄情：查看筑桥阶段、领取鹊桥奖励，并向好友赠送鹊羽香囊
- 雨落成诗：查看雷雨剩余时间和闪电变异配置，兑换或使用天气瓶，并推进气象研究节点
- 活动快照请求采用串行和重复请求合并，避免登录或切换账号时占满游戏网关请求队列
- 青梅酿酒活动已下线，前端不再提供入口；相关协议和实现暂时保留用于兼容

### Web 控制面板

- 概览、个人、活动、好友、分析、神秘商人、游戏商城和设置页面
- Socket.IO 实时状态与日志，全局使用单一暖白液态玻璃界面
- PC 端使用固定侧栏，移动端使用顶部栏和底部导航，并针对常用操作完成响应式适配
- 作物收益分析、策略预览、批量维护作物黑名单
- 设置页统一管理游戏账号、自动化策略、运行环境、管理员密码和下线提醒
- 基于 `pushoo` 的实例级事件推送，可配置通知渠道和离线自动清理时间

## 技术栈

| 模块 | 技术 |
| --- | --- |
| 后端 | Node.js 20、Express 4、Socket.IO 4、TypeScript 5.9 |
| 前端 | Vue 3.5、Naive UI 2、Vue Router 5、Pinia 3、Vite 7、UnoCSS 66 |
| 工程 | pnpm 10.30.2、ESLint 9、Docker Compose |
| 协议 | WebSocket、Protocol Buffers、TSDK WASM |

## 快速开始

### 环境要求

| 运行方式 | 要求 |
| --- | --- |
| 源码运行 | Node.js 20.19+、pnpm 10+ |
| Docker | Docker 20+、Docker Compose 2+、Node 20.19.6（镜像内置） |
| 二进制发布版 | 无需安装 Node.js |

推荐通过 Corepack 启用项目指定版本的 pnpm：

```bash
corepack enable
pnpm --version
```

### 源码运行

Windows、Linux 和 macOS 均可使用以下方式：

```bash
# GitHub（国外/直连）
git clone https://github.com/BUGDey/qq-farm-bot-ll.git
# Gitee（国内更快，二选一）
# git clone https://gitee.com/bugdey/qq-farm-bot-ll.git
cd qq-farm-bot-ll
pnpm install
pnpm dev
```

`pnpm dev` 会先构建前端，再启动后端服务。启动后访问：

- 本机：`http://localhost:3007`
- 局域网：`http://<服务器 IP>:3007`

如需分别启动开发服务：

```bash
# 终端 1：Vite 前端开发服务
pnpm dev:web

# 终端 2：后端开发服务
pnpm dev:core
```

只运行 `pnpm dev:core` 并由后端托管页面时，应先执行一次 `pnpm build:web`。

### Linux 后台脚本

```bash
# GitHub（国外/直连）
git clone https://github.com/BUGDey/qq-farm-bot-ll.git
# Gitee（国内更快，二选一）
# git clone https://gitee.com/bugdey/qq-farm-bot-ll.git
cd qq-farm-bot-ll
corepack enable
bash ./start.sh

# 拉取代码后如需忽略缓存并完整重建
bash ./start.sh --rebuild

# 查看日志
tail -f app_dev.log

# 停止服务
bash ./stop.sh
```

`start.sh` 会在依赖缺失或依赖清单变化时执行 `pnpm install --frozen-lockfile`，并按文件更新时间分别判断 Web、Core 是否需要重建。源码和依赖均未变化时会直接复用现有产物；`--rebuild` 可强制完整重建。脚本随后以生产模式后台运行 `node core/client.js`，日志写入 `app_dev.log`，进程号记录在 `app_dev.pid`。`stop.sh` 会校验 PID 对应的工作目录和启动命令，再停止整个服务进程组。

前端类型检查已与生产构建拆分，需要单独检查时执行 `pnpm typecheck:web`。

### 一键管理脚本（Linux，自动配置 NapCat / QQ 扫码）

仓库根目录的 `qq-farm.sh` 是一个面向 Linux 的交互式管理脚本，把源码/Docker 启动与 NapCat、QQ 扫码所需的两项登录配置串成一条命令。需要 Node.js 20+、`npm`、`curl`、`tar`、`unzip`（Docker 相关选项还需要 Docker Compose 与运行中的 Docker）。pnpm 不需要预装：脚本会读项目 `package.json` 里的 `packageManager` 字段，按声明版本把 pnpm 装到 `napcat/tools/pnpm/<版本>/` 下自己用，不碰全局环境；因此 `corepack enable` 不是必需步骤。选项 `3` / `4` 会调用社区安装器用 `apt`/`dnf` 装系统依赖，需要 root 或 sudo 权限（用 root 运行但系统没装 sudo 时，脚本会自动垫一个直通的 `sudo`）。所有 JSON 配置改写都由 Node 完成，因此不需要 `python3`。

```bash
chmod +x ./qq-farm.sh
./qq-farm.sh
```

菜单选项：

| 选项 | 说明 |
| --- | --- |
| `1` | 默认版 —— 进入子菜单选「源码后台启动」或「Docker 启动」（只启动农场，不碰 NapCat） |
| `2` | 自动配置版 —— 进入子菜单选「源码」或「Docker」，自动安装并配置 NapCat 与 qq-miniapp-auth 后再启动 |
| `5` | NapCat 管理 —— 进入子菜单：启动 / 停止 / 重启 NapCat、修复 QQ 扫码登录 |
| `6` | 重置管理员密码并打印访问地址、账号与新密码 |
| `0` | 退出 |

**默认版子菜单**（只管农场，不碰 NapCat）：`1` 源码后台启动、`2` Docker 启动、`3` 停止源码服务、`4` 重启源码服务、`5` 停止 Docker 服务、`6` 重启 Docker 服务、`0` 返回上级。源码启动时源码有改动才重新构建 Web/Core，然后后台运行 `node core/client.js`。

**自动配置版子菜单**：`1` / `2` 分别是源码 / Docker 的「启动 + 全自动安装配置 NapCat」首次流程；`3`–`5` 是整套服务（农场 + 授权服务 + NapCat）在源码模式下的启动 / 停止 / 重启；`6`–`8` 是整套服务在 Docker 模式下的启动 / 停止 / 重启；`0` 返回上级。「整套」的启停会一起处理农场、qq-miniapp-auth 和 NapCat；日常如果只是想启停农场（不动 NapCat），用默认版子菜单即可。农场面板与默认版一样在后台启动，即使 NapCat 的 QQ 登录暂时没就绪，面板也照常可访问。

自动配置版开始安装前，脚本会先做一次环境预检：检查 `curl`、`tar`、`node`（要求 Node.js ≥ 20）、`npm`、`unzip` 是否就绪，CPU 架构是否为 amd64/arm64，磁盘可用空间是否足够；Shell 安装还会检查系统包管理器与 root/sudo 权限，Docker 安装还会检查 Docker 守护进程与 Compose 插件。任一项不满足会一次性列出全部问题并取消安装，处理后再进子菜单重选一次即可。

启动完成后脚本会打印面板地址（本机 IP + 端口，能取到公网 IP 时额外打印一行），首次启动还会打印管理员账号和密码；之后再启动只打印地址，重置密码时再打印账号和新密码。

源码服务的运行判活不只看 `app_linux.pid`：PID 文件可能过期（进程换了 PID、或被别的脚本拉起），此时脚本会按面板端口找出真正在跑 `core/client.js` 的进程、把正确 PID 回写到 `app_linux.pid` 并复用，不会重复拉起撞 `EADDRINUSE`；停止源码服务时同样会按端口兜底清理残留进程。

NapCat 管理子菜单里的「修复 QQ 扫码登录」用于面板一直提示「工作流繁忙」「刷新二维码没反应」的情况：它会读授权服务的 `/api/health` 显示当前是否有登录卡住，然后重启 qq-miniapp-auth（内存里的单例登录工作流随之清空），并让 NapCat 重启登录 worker，之后回面板重新点「刷新二维码」即可。正常情况下不需要手动用它——面板在刷新二维码时会先释放上一个任务再建新任务。

qq-miniapp-auth 是否已启动以 `/api/health` 是否返回 200 为准，不只看 PID 文件：`npm start` 会多套一层 node 子进程，父进程退出后子进程仍可能占着 8787/9010，重复启动会报 `EADDRINUSE`。脚本启动前会先探测健康端点， unhealthy 时清掉本目录下残留的服务进程再启动。若手动重启后仍报端口被占，可先执行 `pkill -f 'qq-miniapp-auth/(bridge|server|start-all)\.js'` 清理，再进自动配置版子菜单或 NapCat 管理里的「修复 QQ 扫码登录」。

**NapCat 版本固定跟随上游 [BUGDey/qq-farm-bot](https://github.com/BUGDey/qq-farm-bot) 的 `v4.18.19`**，可用 `NAPCAT_VERSION` 覆盖。

NapNeko 官方的安装器与发布地址已经失效（`NapNeko/NapCatQQ` 的 release 资产为空、`NapNeko/NapCat-Installer` 仓库 404），所以两条链路改用下面这些仍可用的源：

- **Shell 安装**用社区留档的 [naxida2333/NapCat-Installer](https://github.com/naxida2333/NapCat-Installer)（备用 [jizizr](https://github.com/jizizr/NapCat-Installer)），以 `--docker n --cli n --proxy N --force` 非交互执行，rootless 装到 `~/Napcat`。执行前脚本会做三件事：① 用 `sed` 把 installer 里写死的失效地址改成归档仓库 `XingYunStar/NapCatQQ` 的固定 tag；② 预先下好 `NapCat.Shell.zip`；③ 预先下好 LinuxQQ 安装包并命名为 `QQ.deb`/`QQ.rpm`——installer 检测到同名文件就直接用本地包，从而绕开已失效的 `qqdl.gtimg.cn`。
- **Docker 安装**直接拉 `mlikiowa/napcat-docker`，拉不动时依次换 `docker.1ms.run`、`docker.xuanyuan.me`、`docker.mybacc.com`、`dytt.online`、`lispy.org`、`docker.m.daocloud.io`、华为云等加速前缀，全部失败才用归档的离线 tar 包 `docker load` 导入并 `docker tag`。

所有 GitHub 下载（NapCat 安装器、`NapCat.Shell.zip`、QQ 包、qq-miniapp-auth 源码、离线镜像 tar）都会走 10 个加速前缀的 fallback 链（`ghfast.top`、`git.yylx.win`、`gh-proxy.com`、`ghfile.geekertao.top`、`gh-proxy.net`、`j.1win.ggff.net`、`ghm.078465.xyz`、`gitproxy.127731.xyz`、`jiashu.1win.eu.org`、`github.tbedu.top`，最后直连），每个地址内部再重试 3 次；可用 `GH_PROXY_INDEX` 指定优先使用的加速站点。下载过程不打印候选地址、不打印 curl 进度条，成功只输出一行落地结果，只有某个源失败时才打印一行 `[WARN] 源不可用，换下一个：<地址>`。

另外三类下载各有一套补充源：

- `api.github.com` 不能套全部加速前缀（多数站点只代理 `github.com`），单独用实测可用的 4 个：`gh-proxy.com`、`gh-proxy.net`、`jiashu.1win.eu.org`、`git.yylx.win`；
- qq-miniapp-auth 源码有两条出口（`github.com/<repo>/archive/refs/heads/master.tar.gz` 与 `codeload.github.com/<repo>/tar.gz/refs/heads/master`），因为加速站只认前一种形式；NapCat 安装器还额外有一条 jsDelivr 兜底（`cdn.jsdelivr.net/gh/naxida2333/NapCat-Installer@main/script/install.sh`）；
- npm / pnpm 依赖按 `registry.npmmirror.com` → `registry.npmjs.org` → `mirrors.cloud.tencent.com/npm` → `mirrors.huaweicloud.com/repository/npm` → `registry.yarnpkg.com` 依次尝试；可用 `export NPM_REGISTRIES_OVERRIDE=<源1>,<源2>` 覆盖这张表。
- 项目声明了 `packageManager: pnpm@10.30.2`。如果系统里 `corepack` 下到的是别的版本（例如 12.x），pnpm 会以 `ERR_PNPM_BAD_PM_VERSION` 直接退出，此时换多少 registry 都没用。脚本因此不用 corepack 的版本协商：先看本地 `napcat/tools/pnpm/<声明版本>/` 有没有，没有就用 `npm install --prefix` 装一份；系统 pnpm 版本正好一致时直接用；最后才退到 `corepack pnpm --pm-on-fail=ignore` 跳过版本校验。
  - 注意 `npm ci` 不会理会 `--registry`，它严格按 `package-lock.json` 里写死的 `resolved` 地址下载 tarball，所以脚本会先把锁文件里的地址改写成当前源的规范形式（`<registry>/<包名>/-/<包文件名>-<版本>.tgz`）再装；仍失败则该源改用 `npm install` 兜底，全部源都失败时把锁文件还原。

关于 QQ 客户端：**NapCat 不是独立程序，而是注入 QQ 客户端进程的插件**，自身不带 `wrapper.node`，必须由 QQ 主进程加载才能拿到 NTQQ 原生接口，所以只装 `NapCat.Shell.zip` 跑不起来——installer 会用 `dpkg -x` / `rpm2cpio` 把 QQ 解包到 `~/Napcat/opt/QQ`，全程不需要 root 也不需要系统包管理器安装。QQ 安装包默认从 [zydou/QQ-Linux](https://github.com/zydou/QQ-Linux) 的 release 取（先查 API 取最新，失败回退已知 tag），可用 `QQ_PKG_URL` 指定；两者的下载包都缓存在 `napcat/` 下，重装不会重复下载。

选项 `3`（源码 + Shell 安装的 NapCat）流程：

1. 若检测到旧版系统级安装（`/opt/QQ/resources/app/app_launcher/napcat`），先备份其 `config/` 到 `napcat/napcat-config-backup.<时间戳>`，再把该 NapCat 目录挪走、把 QQ 的 `package.json` 恢复原样——否则 installer 会弹出「是否彻底删除旧版本」的交互提问，非交互环境下直接退出；
2. 下载社区留档的 NapCat 安装器并用 `sed` 修正其中已失效的上游地址；
3. 预置 `NapCat.Shell.zip` 与 `QQ.deb`/`QQ.rpm`（缓存于 `napcat/`），让 installer 跳过自己的下载；
4. 以 `--docker n --cli n --proxy N --force` 执行 installer：安装依赖 → 解包 QQ 到 `~/Napcat/opt/QQ` → 把 NapCat 注入 `app_launcher/napcat` 并写入 `loadNapCat.js`；
5. 拉取上游 [qq-miniapp-auth](https://github.com/liyangpengs/qq-miniapp-auth)、安装 `qq-miniapp-openauth` 插件（写入 `config/plugins.json` 并在 `napcat.mjs` 白名单中登记，改动前自动备份 `napcat.mjs.bak.<时间戳>`）；
6. 把 OneBot HTTP 服务配到 `127.0.0.1:3000`；
7. 把「NapCat 接口地址」（`napCatEndpoint`，默认 `http://127.0.0.1:8787`）和「接口签名」（`napCatSignature`，即 `API_SIGNING_SECRET`）写入 `core/data/store.json`，省去在「设置 → 系统设置 → 登录设置」里手动填写；
8. 后台启动 NapCat（`xvfb-run -a ~/Napcat/opt/QQ/qq --no-sandbox`）与 qq-miniapp-auth，最后启动农场源码。

选项 `4`（Docker 安装的 NapCat）流程与 `3` 大致相同，但 NapCat 运行在容器里：脚本直接使用官方镜像 `mlikiowa/napcat-docker:v4.18.19`（不再自建 Dockerfile），容器名 `qq-farm-napcat`，`NAPCAT_UID/GID` 用当前用户，三个具名目录 `napcat/docker/{config,plugins,QQ}` 分别挂到 `/app/napcat/config`、`/app/napcat/plugins`、`/app/.config/QQ`；WebUI 与 OneBot 都只映射到 `127.0.0.1`（`6099` 与 `$ONEBOT_PORT`）。容器内 OneBot 绑定 `0.0.0.0`，农场容器经 `host.docker.internal:3000` 访问，可用 `export NAPCAT_HOST_IP=<局域网 IP>` 覆盖。

所有配置全自动完成，不再交互询问签名或地址：`API_ENDPOINT`、`API_SECRET`、`ONEBOT_PORT` 都有默认值，可用同名环境变量覆盖；`ONEBOT_TOKEN` 首次运行时自动随机生成。

脚本会把生成的目录放在脚本所在目录：`napcat/`（下载缓存 `NapCat.Shell.zip`、`QQ.deb`、配置、日志、旧版备份）、`qq-miniapp-auth/`（授权服务源码）。配置持久化在 `napcat/manager-config.env`（`API_ENDPOINT`、`API_SECRET`、`ONEBOT_PORT`、`ONEBOT_TOKEN`、`NAPCAT_ROOT`、`NAPCAT_MODE`）。源码后台日志写入 `app_linux.log` / `app_linux.error.log`，进程号记录在 `app_linux.pid`；NapCat 日志与进程号分别是 `napcat/napcat.log` 和 `napcat/napcat.pid`；NapCat 安装器的完整输出在 `napcat/napcat-install.log`。两个生成目录已加入 `.gitignore`，不会污染仓库。

> [!NOTE]
> 该脚本尚未在真实 Linux 机器上做过一次完整的 QQ 扫码验证。菜单 `3` / `4` 完成后，请打开 `http://127.0.0.1:6099/webui/` 完成一次真实扫码；扫码后「登录设置」里的两项配置已就绪，可直接在农场面板使用 QQ 扫码登录。

### Docker Compose

```bash
# GitHub（国外/直连）
git clone https://github.com/BUGDey/qq-farm-bot-ll.git
# Gitee（国内更快，二选一）
# git clone https://gitee.com/bugdey/qq-farm-bot-ll.git
cd qq-farm-bot-ll
docker compose up -d --build

# 仅重启现有容器，不触发镜像构建
docker compose restart qq-farm-bot

# 查看状态和日志
docker compose ps
docker compose logs -f

# 检查 Compose 配置展开结果
docker compose config

# 停止并移除容器
docker compose down
```

默认访问 `http://<服务器 IP>:3007`。修改根目录 `.env` 中的 `PORT` 后，可调整宿主机映射端口：

```dotenv
PORT=3008
TZ=Asia/Shanghai
```

Docker 数据保存在 `qq-farm-data` 和 `qq-farm-logs` 命名卷中。执行 `docker compose down` 不会删除这些卷；不要使用 `docker compose down -v`，除非确认要删除运行数据。

Compose 使用根目录作为构建上下文，Dockerfile 位于 `core/Dockerfile`。镜像构建阶段固定使用 Node `20.19.6` 和 pnpm `10.30.2`，通过 BuildKit 缓存 pnpm store，并在相互独立的阶段构建 Web、Core 和生产依赖；仅修改一侧源码时可直接复用另一侧缓存。运行阶段只保留生产依赖、编译产物、协议定义、游戏配置和 TSDK WASM。容器内部固定监听 `3007`，根目录 `.env` 中的 `PORT` 只用于宿主机端口映射。

依赖源默认使用 npm 官方源；网络受限时可以在根目录 `.env` 中覆盖构建参数后重新构建：

```dotenv
NPM_REGISTRY=https://registry.npmmirror.com/
```

如需显式指定基础镜像或 pnpm 版本，也可以配置 `NODE_IMAGE` 和 `PNPM_VERSION`。修改构建参数或排查旧缓存问题时请执行 `docker compose build --pull --no-cache`，确保重新拉取基础镜像并安装依赖。

### 二进制发布版

可从 [GitHub Releases](https://github.com/BUGDey/qq-farm-bot-ll/releases) 或 [Gitee 发行版](https://gitee.com/bugdey/qq-farm-bot-ll/releases) 下载对应平台文件，也可以自行构建：

```bash
pnpm install
pnpm package:release
```

Windows x64、Linux x64、macOS Intel 和 macOS Apple Silicon 产物生成在 `core/dist/bin/`。运行后，程序会在可执行文件同级创建 `data/` 目录。

Linux 和 macOS 首次运行可能需要添加执行权限：

```bash
chmod +x ./qq-farm-bot
./qq-farm-bot
```

## 首次使用

1. 打开 Web 面板，使用 `admin` / `admin` 登录。
2. 进入“设置 → 系统设置”修改管理员密码。
3. 如需使用 QQ 扫码登录，Linux 下可直接运行 `./qq-farm.sh` 并选 `3`（源码）或 `4`（Docker），脚本会自动安装/配置 NapCat、[qq-miniapp-auth](https://github.com/liyangpengs/qq-miniapp-auth) 及两项登录配置；手动部署时需在“设置 → 系统设置 → 登录设置”开启 QQ 扫码登录，并填写 NapCat 接口地址和接口签名。
4. 在设置页添加游戏账号，可使用有效 Code、微信扫码或 QQ扫码登录。
5. 为账号配置种植、自动化和好友策略，并按需设置实例级下线提醒。
6. 启动账号，在概览页确认连接状态、农场数据和实时日志。

Code 具有时效性；登录失败时应先重新获取 Code 或重新扫码。QQ 客户端被挤下线后，官方“重新登录”会签发新的 Code；可启动 QQFarmCodeHelper 的标准获取模式并开启自动同步，再点击官方“重新登录”，Helper 会更新匹配账号的 Code 并重新启动远程账号。协议监听模式只落盘抓包，永远不会自动上传 Code。

QQ 扫码登录依赖外部 [qq-miniapp-auth](https://github.com/liyangpengs/qq-miniapp-auth) 服务。登录设置中的 NapCat 接口地址需填写该服务的可访问地址，NapCat 接口签名需与其 `API_SIGNING_SECRET` 配置一致；两者会保存在本机数据目录中，由后端调用外部服务时读取。QQ 扫码登录默认关闭，开启前必须同时配置接口地址和签名。上文的一键脚本 `qq-farm.sh` 选项 `3` / `4` 会自动写入这两项并开启 QQ 扫码登录。

## 配置说明

### 环境变量

| 变量 | 默认值 | 适用范围 | 说明 |
| --- | --- | --- | --- |
| `ADMIN_PORT` | `3007` | 源码、二进制 | Web 面板监听端口；Compose 容器内固定为 `3007` |
| `PORT` | `3007` | Docker Compose | 宿主机映射端口，从根目录 `.env` 读取 |
| `TZ` | `Asia/Shanghai` | Docker Compose | 容器时区 |
| `NODE_ENV` | `production` | Docker | Compose 当前固定为生产环境 |
| `LOG_LEVEL` | `info` | 后端 | 服务端日志级别 |

管理员账号不通过环境变量初始化。首次运行会自动创建 `admin` / `admin`，之后的管理员凭据保存在数据目录的 `admin.json` 中。项目不提供注册或新增管理员功能。

### 种植策略

| 策略值 | 面板名称 | 行为 |
| --- | --- | --- |
| `preferred` | 优先种植种子 | 优先使用指定种子，不可用时自动回退 |
| `level` | 最高等级作物 | 优先选择当前可种植的高等级作物 |
| `max_exp` | 最大经验/时 | 按单位时间经验选择，默认策略 |
| `max_fert_exp` | 最大普通肥经验/时 | 按普通肥条件下的单位时间经验选择 |
| `max_profit` | 最大净利润/时 | 按单位时间净利润选择 |
| `max_fert_profit` | 最大普通肥净利润/时 | 按普通肥条件下的单位时间净利润选择 |
| `bag_priority` | 背包种子优先 | 先按优先级消耗背包种子，再使用回退策略 |

### 施肥模式

| 模式值 | 面板名称 | 行为 |
| --- | --- | --- |
| `smart` | 普通 + 快成熟有机 | 默认模式，按成熟时间智能选择有机肥 |
| `both` | 普通 + 有机 | 同时使用普通肥和有机肥 |
| `normal` | 仅普通化肥 | 只使用普通化肥 |
| `organic` | 仅有机化肥 | 只使用有机化肥 |
| `none` | 不施肥 | 关闭自动施肥 |

`smart` 模式施加有机肥后会重新检查一次自有土地，并立即收获本轮因施肥进入成熟状态的作物；该追收最多执行一次，不会形成循环请求。

### 图鉴配置

图鉴使用 `core/src/gameConfig/Illustrated.json` 和 `core/src/gameConfig/BuffCfg.json` 两份游戏配置：

| 配置 | 字段 | 说明 |
| --- | --- | --- |
| `Illustrated.json` | `param` | 与图鉴协议返回的果实 ID 对应 |
| `Illustrated.json` | `type` | 果实分类，包括普通果实、黄金果实、活动果实和装扮果实 |
| `Illustrated.json` | `illustrated_type` | 区分普通图鉴和超变图鉴 |
| `Illustrated.json` | `sort` | 图鉴中的展示顺序 |
| `BuffCfg.json` | `source_type` | 超变图鉴只展示 `超变升级`，隐藏 `活动加成` |
| `BuffCfg.json` | `source_param` | 触发该属性加成的图鉴等级 |
| `BuffCfg.json` | `attr_id` | 属性加成名称 |
| `BuffCfg.json` | `attr_value` | 大于 `10` 时为触发概率，小于 `10` 时为数量 |

概率值按千分值转换为百分比展示，例如 `100` 显示为 `10%`、`500` 显示为 `50%`；数量值直接展示，例如 `2` 显示为 `数量 +2`。当前加成会按属性名称取当前等级已生效的最新配置。

## 数据与备份

| 运行方式 | 数据位置 |
| --- | --- |
| 源码运行 | `core/data/` |
| 二进制运行 | 可执行文件同级的 `data/` |
| Docker | `/app/core/data`，映射到 `qq-farm-data` 命名卷 |

管理员凭据、游戏账号、配置、活动状态和日志都属于运行数据。升级、迁移或重新部署前，建议先停止服务并备份整个数据目录或 Docker 命名卷，而不是只复制单个 JSON 文件。

游戏账号属于当前实例，不带用户归属字段，也没有数量上限。下线提醒同样是实例级配置，对当前实例内的所有游戏账号生效。

## 项目结构

```text
qq-farm-bot-ll/
├── core/                  # Node.js 后端、账号 Worker 与协议实现
│   ├── src/
│   │   ├── controllers/   # Web API 与鉴权路由
│   │   ├── core/          # 单账号 Worker 与任务调度
│   │   ├── runtime/       # 多账号运行时和状态同步
│   │   ├── services/      # 农场、好友、图鉴、活动、商城、微信登录等业务
│   │   ├── proto/         # Protocol Buffers 定义
│   │   ├── gameConfig/    # 作物、道具、等级、图鉴与属性加成等游戏配置
│   │   └── models/        # 超级管理员、游戏账号与配置持久化
│   └── data/              # 源码模式运行数据
├── web/                   # Vue 3 Web 面板
│   ├── src/components/    # 农场、图鉴、背包、任务、活动与基础组件
│   ├── src/stores/        # Pinia 状态管理
│   ├── src/views/         # 各功能页面
│   └── dist/              # 前端构建产物
├── docs/                  # 项目专题文档
├── tools/                 # 配置下载、图片下载与协议分析工具
├── qq-farm.sh             # Linux 一键管理脚本（自动配置 NapCat / QQ 扫码）
├── start.sh               # Linux 源码后台启动脚本
├── stop.sh                # Linux 服务停止脚本
├── napcat/                # 由 qq-farm.sh 生成：NapCat 安装与配置（不入库）
├── qq-miniapp-auth/       # 由 qq-farm.sh 生成：QQ 扫码授权服务（不入库）
├── docker-compose.yml
├── pnpm-workspace.yaml
└── package.json
```

## 开发命令

| 命令 | 说明 |
| --- | --- |
| `pnpm dev` | 构建前端并启动后端开发服务 |
| `pnpm dev:web` | 启动 Vite 前端开发服务 |
| `pnpm dev:core` | 使用 `tsx` 启动后端 |
| `pnpm lint` | 检查并自动修复前后端代码风格 |
| `pnpm -C core typecheck` | 执行后端 TypeScript 类型检查 |
| `pnpm typecheck:web` | 执行前端 TypeScript 类型检查（不参与生产启动） |
| `pnpm build:web` | 构建 Web 面板到 `web/dist/` |
| `pnpm -C web build:compressed` | 构建 Web 并额外生成预压缩 `.gz` 文件 |
| `pnpm -C web build:analyze` | 构建 Web 并生成 bundle 分析报告 |
| `pnpm build:core` | 编译后端 TypeScript |
| `pnpm build` | 依次构建前端和后端 |
| `pnpm package:release` | 构建四个平台的独立二进制文件 |
| `pnpm -C core test` | 编译 Core 并运行抓包协议、活动和请求并发测试 |

### 清理构建产物

```bash
# Linux/macOS
bash ./clean.sh

# Windows
clean-for-pack.bat

# 保留 core/data 运行数据
clean-for-pack.bat --keep-data
```

`clean.sh` 会停止当前服务，然后删除项目根目录下除 `.git` 以外的全部文件和目录，包括源码、依赖、构建产物、运行数据以及脚本自身。该操作不可撤销，只应用于准备通过 Git 重新检出工作区的场景。

Windows 的 `clean-for-pack.bat` 会清理依赖、构建产物、覆盖率文件、日志以及 `core/data` 运行数据，适合生成不包含账号和凭据的发布目录。如需保留 `core/data`，必须显式传入 `--keep-data`。

### 抓包协议分析

```bash
# 解码指定抓包目录中的协议帧
pnpm -C core exec tsx ../tools/decode-latest-protocols.js <capture-dir>

# 检查抓包 RPC 与本地 Protobuf 定义的兼容性
pnpm -C core exec tsx ../tools/audit-capture-compatibility.js <capture-dir>
```

## 项目文档

专题说明统一收录在 [`docs/`](docs/README.md)：

- [工具脚本](docs/tools.md)
- [网络并发模型](docs/network-concurrency.md)
- [TSDK Node.js 运行约定](docs/tsdk-runtime.md)
- [配置存储、迁移与缓存](docs/config-storage.md)
- [2026-10-22 游戏版本与资源对齐](docs/game-update-20261022.md)
- [雨落成诗活动协议与实现](docs/weather-activity.md)
- [神秘商人、游戏商城与购买协议](docs/shop-protocols.md)
- [好友宠物缓存与每日同步](docs/friend-pet-cache.md)
- [个人页宠物协议](docs/pet-protocols.md)
- [图鉴、变异宝典与藏品](docs/collections-20261101.md)

## 免责声明

本项目仅供学习与研究用途。使用本工具可能违反游戏服务条款，由此产生的一切后果由使用者自行承担。

<div align="center">
  <p>如果觉得项目有用，欢迎点一个 Star。</p>
</div>
