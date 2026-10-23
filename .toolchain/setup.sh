#!/usr/bin/env bash
# HarmonyOS / Flutter-OH Linux 工具链一键安装
# 说明：沙箱重启后 /opt 会回到基础镜像，/workspace 保留。
#       本脚本幂等，可重复执行；安装包缓存在 /workspace/.toolchain/cache。
set -euo pipefail

CACHE_DIR="${CACHE_DIR:-/workspace/.toolchain/cache}"
HOS_ROOT="${HOS_ROOT:-/opt/harmonyos}"
CLT_VER="${CLT_VER:-6.1.1.268}"
CLT_ZIP="$CACHE_DIR/commandline-tools-linux-x64-$CLT_VER.zip"
CLT_URL="${CLT_URL:-https://contentcenter-vali-drcn.dbankcdn.cn/pvt_2/DeveloperAlliance_package_901_9/bb/v3/2kEEcCD9Ts2UwlVvAYKfNQ/commandline-tools-linux-x64-6.1.1.268.zip?HW-CC-KV=V1&HW-CC-Date=20260518T055136Z&HW-CC-Expire=315360000&HW-CC-Sign=E81EFE847B3869574A569EC11FD6E665435892764C866BD0853E935748DC07EF}"

FLUTTER_TGZ="$CACHE_DIR/flutter_ohos_3.35.7+ohos-1.0.5.tar.gz"
FLUTTER_URL="${FLUTTER_URL:-https://raw.gitcode.com/CPF-Flutter/flutter_flutter/archive/refs/heads/3.35.7+ohos-1.0.5.tar.gz}"
FLUTTER_HOME=/opt/flutter
CLT_HOME="$HOS_ROOT/hos611/command-line-tools"

PROXY="${PROXY:-http://127.0.0.1:18080}"
CURL_PROXY=()
if [ -n "$PROXY" ]; then CURL_PROXY=(-x "$PROXY"); fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "需要 root 运行"
mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------- 1. JDK 21
log "检查 JDK 21"
if [ ! -x /usr/lib/jvm/java-21-openjdk-amd64/bin/java ]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jdk-headless
fi
[ -x /usr/lib/jvm/java-21-openjdk-amd64/bin/java ] || die "JDK 21 安装失败"

# ------------------------------------------------------- 2. HarmonyOS CLI
log "准备 HarmonyOS Command Line Tools $CLT_VER"
if [ ! -f "$CLT_ZIP" ]; then
  curl -L --retry 3 "${CURL_PROXY[@]}" -o "$CLT_ZIP" "$CLT_URL"
fi
if [ ! -d "$CLT_HOME" ]; then
  mkdir -p "$HOS_ROOT/hos611"
  unzip -q -o "$CLT_ZIP" -d "$HOS_ROOT/hos611"
fi
[ -d "$CLT_HOME/sdk" ] || die "CLT 解压结构异常：$CLT_HOME/sdk 不存在"

# ------------------------------------------------------------ 3. Flutter-OH
log "准备 Flutter-OH 3.35.7+ohos-1.0.5"
if [ ! -f "$FLUTTER_TGZ" ]; then
  curl -L --retry 3 "${CURL_PROXY[@]}" -o "$FLUTTER_TGZ" "$FLUTTER_URL"
fi
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  tar -xzf "$FLUTTER_TGZ" -C /opt
  mv "/opt/flutter_flutter-3.35.7+ohos-1.0.5" "$FLUTTER_HOME"
  # gitcode 的分支归档不含 .git，而 flutter 工具依赖 git 信息；
  # 另外 bin/internal/engine.version 被 .gitignore 排除，需强制跟踪，
  # 否则 update_engine_version.sh 会去 merge-base origin/master 并失败。
  (
    cd "$FLUTTER_HOME"
    git init -q
    git add -A
    git -c user.email=toolchain@local -c user.name=toolchain commit -q -m "flutter 3.35.7+ohos-1.0.5"
    git add -f bin/internal/engine.version
    git -c user.email=toolchain@local -c user.name=toolchain commit -q -m "track engine.version"
    # flutter 用 git describe 推断版本号，没有 tag 会变成 0.0.0-unknown
    git tag -f "3.35.7+ohos-1.0.5" "$(git rev-parse HEAD)"
  )
fi
[ -x "$FLUTTER_HOME/bin/flutter" ] || die "Flutter 解压失败"

# ------------------------------------------------- 4. npm / ohpm 配置
log "写入 npm / ohpm 配置"
cat > /root/.npmrc <<'EOF'
registry=https://repo.huaweicloud.com/repository/npm/
@ohos:registry=https://repo.harmonyos.com/npm/
EOF

mkdir -p /root/.ohpm
cat > /root/.ohpm/.ohpmrc <<EOF
registry=https://repo.harmonyos.com/ohpm/
strict_ssl=true
publish_registry=https://ohpm.openharmony.cn/ohpm/
https_proxy=$PROXY/
http_proxy=$PROXY/
EOF

# ohpm 的 axios 1.15 在 proxy=undefined 时会自动读 HTTPS_PROXY，
# 与自身传入的 httpsAgent 叠加后把 https 请求以明文发给代理，导致 403。
OHPM_INIT="$CLT_HOME/ohpm/lib/core/registry/OhpmRequestInit.js"
if [ -f "$OHPM_INIT" ] && grep -q 'proxy:!!this.agent&&void 0' "$OHPM_INIT"; then
  sed -i 's/proxy:!!this\.agent&&void 0/proxy:!!this.agent\&\&!1/' "$OHPM_INIT"
fi
grep -q 'proxy:!!this.agent&&!1' "$OHPM_INIT" || die "ohpm axios 代理补丁未生效"

# --------------------------------------------------------- 5. 环境变量
log "生成 env.sh"
cat > "$HOS_ROOT/env.sh" <<'EOF'
# HarmonyOS / Flutter-OH Linux toolchain environment
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

# HarmonyOS Command Line Tools 6.1.1 (HarmonyOS SDK 6.1.1 / API 24)
export HOS_CLI_HOME=/opt/harmonyos/hos611/command-line-tools
export HOS_SDK_HOME=$HOS_CLI_HOME/sdk
export DEVECO_SDK_HOME=$HOS_SDK_HOME
export HDC_HOME=$HOS_SDK_HOME/default/openharmony/toolchains
export NODE_HOME=$HOS_CLI_HOME/tool/node

export FLUTTER_HOME=/opt/flutter
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export FLUTTER_SUPPRESS_ANALYTICS=true

export PATH=$JAVA_HOME/bin:$NODE_HOME/bin:$HOS_CLI_HOME/bin:$HDC_HOME:$FLUTTER_HOME/bin:$PATH
EOF
for rc in /root/.bashrc /root/.zshrc; do
  touch "$rc"
  grep -q 'opt/harmonyos/env.sh' "$rc" || echo '[ -f /opt/harmonyos/env.sh ] && source /opt/harmonyos/env.sh' >> "$rc"
done

# shellcheck disable=SC1091
source "$HOS_ROOT/env.sh"
export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY"

# ------------------------------------------------------- 6. Flutter 引擎
log "预下载 Flutter 引擎产物（首次较慢）"
"$FLUTTER_HOME/bin/flutter" precache --ohos

# --------------------------------------------- 7. flutter_ohos HAR 补丁
log "修补 flutter_embedding HAR（API 24 SDK 兼容）"
python3 /workspace/.toolchain/patch_ohos_har.py

log "完成"
source "$HOS_ROOT/env.sh"
flutter --version
echo
echo "用法：source /opt/harmonyos/env.sh   # 新终端已自动 source"
echo "出包：cd /workspace && flutter build hap --release"
