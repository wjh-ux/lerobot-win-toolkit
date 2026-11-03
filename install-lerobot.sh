#!/usr/bin/env bash
#
# LeRobot Linux 安装脚本（Ubuntu / Debian）
#
# 与 Windows 版本的 lerobot-menu.ps1 / install-lerobot.ps1 对应，思路一致：
#   镜像先探测再降级，不通就换下一个，最后才用官方源。
#
# 用法：
#   chmod +x install-lerobot.sh
#   ./install-lerobot.sh                 # 标准安装
#   ./install-lerobot.sh --dry-run       # 只打印要执行的命令
#   ./install-lerobot.sh --from-pypi     # 不走 git，直接从 pip 镜像下 sdist
#   ./install-lerobot.sh --env myenv --extras core_scripts,feetech
#   ./install-lerobot.sh --skip-apt      # 跳过系统依赖（已装好时用）
#
# 注意：本脚本在写的时候只做过 `bash -n` 语法检查，
#       尚未在真实 Ubuntu/Debian 上完整跑通过。第一次使用建议先 --dry-run。

set -euo pipefail

# ---------------------------------------------------------------- 默认参数
ENV_NAME="lerobot"
PY_VERSION="3.12"
EXTRAS="core_scripts,training,feetech"
INSTALL_DIR="${HOME}/lerobot"
DRY_RUN=0
FROM_PYPI=0
SKIP_APT=0
PIP_VERSION=""

# ---------------------------------------------------------------- 输出
C_RESET=$'\033[0m'
C_RED=$'\033[31m'
C_GRN=$'\033[32m'
C_YEL=$'\033[33m'
C_CYN=$'\033[36m'
C_GRY=$'\033[90m'

STEP_NOW=0
STEP_TOTAL=6
FAILURES=0

section() { printf '\n%s== %s ==%s\n' "$C_CYN" "$1" "$C_RESET"; }
ok()      { printf '  %s[ OK ]%s  %s\n' "$C_GRN" "$C_RESET" "$1"; }
warn()    { printf '  %s[WARN]%s  %s\n' "$C_YEL" "$C_RESET" "$1"; }
err()     { printf '  %s[FAIL]%s  %s\n' "$C_RED" "$C_RESET" "$1"; FAILURES=$((FAILURES+1)); }
info()    { printf '          %s\n' "$C_GRY$1$C_RESET"; }
die()     { printf '\n  %s[中止]%s %s\n\n' "$C_RED" "$C_RESET" "$1"; exit 1; }

step() {
    STEP_NOW=$((STEP_NOW+1))
    local pct=$((STEP_NOW*100/STEP_TOTAL))
    local filled=$((pct*20/100))
    local bar_empty
    bar_empty=$(printf '%*s' $((20-filled)) '' | tr ' ' '-')
    local bar
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')${bar_empty}"
    printf '\n  %s第 %d/%d 步%s  [%s] %3d%%  %s\n' "$C_CYN" "$STEP_NOW" "$STEP_TOTAL" "$C_RESET" "$bar" "$pct" "$1"
    printf '  %s\n' "$(printf '%.0s-' {1..70})"
}

# 执行命令；dry-run 时只打印
run() {
    printf '  %s> %s%s\n' "$C_GRY" "$*" "$C_RESET"
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    "$@"
}

# ---------------------------------------------------------------- HTTP 工具
# Ubuntu 22.04 默认没有 curl（只有 wget），python3 一定有。
# 三级回退，免得因为缺一个工具就整脚本报废。
HTTP_TOOL=""
for c in curl wget python3; do
    command -v "$c" >/dev/null 2>&1 && { HTTP_TOOL="$c"; break; }
done
[ -n "$HTTP_TOOL" ] || { echo "需要 curl / wget / python3 其中之一" >&2; exit 1; }

# 取 Content-Length（拿不到返回 0）
http_length() {
    local url="$1"
    case "$HTTP_TOOL" in
        curl) curl -sIL -m 20 "$url" 2>/dev/null \
                | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2}END{gsub(/\r/,"",v);print v+0}' ;;
        wget) wget --spider --server-response --timeout=20 "$url" 2>&1 \
                | awk 'BEGIN{IGNORECASE=1}/[Cc]ontent-[Ll]ength:/{v=$2}END{gsub(/\r/,"",v);print v+0}' ;;
        *)    python3 -c 'import sys,urllib.request
try:
    print(urllib.request.urlopen(sys.argv[1],timeout=20).headers.get("Content-Length") or 0)
except Exception:
    print(0)' "$url" 2>/dev/null ;;
    esac
}

# 实际下载（后台跑，由 fetch 轮询进度）
http_get() {
    local url="$1" out="$2"
    case "$HTTP_TOOL" in
        curl) curl -L -f -sS -o "$out" "$url" ;;
        wget) wget -q -O "$out" "$url" ;;
        *)    python3 -c 'import sys,urllib.request,shutil
with urllib.request.urlopen(sys.argv[1],timeout=60) as r, open(sys.argv[2],"wb") as f:
    shutil.copyfileobj(r,f)' "$url" "$out" ;;
    esac
}

# 带进度和速度的下载
fetch() {
    local url="$1" out="$2" total=0 size=0 pct=0 last=0 spd=0 start
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  %s> [%s] %s -> %s%s\n' "$C_GRY" "$HTTP_TOOL" "$url" "$out" "$C_RESET"
        return 0
    fi
    total=$(http_length "$url" || echo 0)
    start=$(date +%s)
    http_get "$url" "$out" &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        if [ -f "$out" ]; then size=$(stat -c %s "$out" 2>/dev/null || echo 0); fi
        local now elapsed
        now=$(date +%s); elapsed=$((now-start))
        [ "$elapsed" -lt 1 ] && elapsed=1
        spd=$((size/elapsed))
        if [ "$total" -gt 0 ]; then
            pct=$((size*100/total))
            printf '\r    下载 %3d%%  %6.1f / %6.1f MB  %5.2f MB/s' \
                "$pct" "$(awk "BEGIN{print $size/1048576}")" "$(awk "BEGIN{print $total/1048576}")" \
                "$(awk "BEGIN{print $spd/1048576}")"
        else
            printf '\r    下载 %6.1f MB  %5.2f MB/s' \
                "$(awk "BEGIN{print $size/1048576}")" "$(awk "BEGIN{print $spd/1048576}")"
        fi
        last=$size
    done
    wait "$pid" || { printf '\n'; warn "下载失败: $url"; return 1; }
    printf '\r%*s\r' 70 ''
    ok "已下载 $(awk "BEGIN{printf \"%.1f\", $(stat -c %s "$out" 2>/dev/null || echo 0)/1048576}") MB"
}

# 取一个文本页面（用于解析 pip 的 simple 索引）
http_text() {
    local url="$1"
    case "$HTTP_TOOL" in
        curl) curl -sSL -m 40 "$url" 2>/dev/null ;;
        wget) wget -q -O - --timeout=40 "$url" 2>/dev/null ;;
        *)    python3 -c 'import sys,urllib.request
try:
    print(urllib.request.urlopen(sys.argv[1],timeout=40).read().decode("utf-8","replace"))
except Exception:
    pass' "$url" 2>/dev/null ;;
    esac
}

# 探测 URL 是否可用（2xx/3xx）
probe() {
    local url="$1" code
    case "$HTTP_TOOL" in
        curl)
            code=$(curl -sS -o /dev/null -w '%{http_code}' -m 10 -g "$url" 2>/dev/null || echo 000)
            case "$code" in 2*|3*) return 0 ;; *) return 1 ;; esac
            ;;
        wget)
            wget -q --spider --timeout=10 "$url" >/dev/null 2>&1 && return 0 || return 1
            ;;
        *)
            python3 -c 'import sys,urllib.request
try:
    urllib.request.urlopen(sys.argv[1],timeout=10); sys.exit(0)
except Exception:
    sys.exit(1)' "$url" >/dev/null 2>&1
            ;;
    esac
}

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --from-pypi)  FROM_PYPI=1 ;;
        --skip-apt)   SKIP_APT=1 ;;
        --env)        ENV_NAME="$2"; shift ;;
        --python)     PY_VERSION="$2"; shift ;;
        --extras)     EXTRAS="$2"; shift ;;
        --dir)        INSTALL_DIR="$2"; shift ;;
        --pypi-version) PIP_VERSION="$2"; shift ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "不认识的参数: $1（用 --help 看用法）" ;;
    esac
    shift
done

# ---------------------------------------------------------------- 镜像表
PIP_MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"
    "https://mirrors.aliyun.com/pypi/simple"
    "https://mirrors.cloud.tencent.com/pypi/simple"
    "https://pypi.mirrors.ustc.edu.cn/simple"
    "https://pypi.org/simple"
)

CONDA_CHANNELS=(
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main"
    "https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge"
    ""   # 空字符串 = 默认源
)

GIT_URLS=(
    "https://gh-proxy.com/https://github.com/huggingface/lerobot.git"
    "https://ghfast.top/https://github.com/huggingface/lerobot.git"
    "https://github.com/huggingface/lerobot.git"
)

MINIFORGE_URLS=(
    "https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh"
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
)

# ================================================================ 0. 环境识别
section "0. 环境识别"

[ "$(uname -s)" = "Linux" ] || die "这个脚本只用于 Linux"

DISTRO_ID=""; DISTRO_NAME=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
fi
ok "发行版: ${DISTRO_NAME:-未知}"

ARCH="$(uname -m)"
ok "架构: $ARCH"

case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|raspbian|kali)
        ok "apt 系发行版，继续" ;;
    *)
        warn "这个脚本按 Ubuntu/Debian(apt) 写的，当前是 $DISTRO_ID"
        warn "系统依赖那步可能失败，可加 --skip-apt 跳过"
        ;;
esac

if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
    warn "非 x86_64/aarch64，PyTorch 可能没有对应轮子"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    warn "DryRun 模式：只打印命令，不执行安装"
fi

# ================================================================ 1. 系统依赖
if [ "$SKIP_APT" -eq 1 ]; then
    section "1. 系统依赖（--skip-apt 跳过）"
else
    step "系统依赖（apt）"
    # 这些是编译 PyAV / torchcodec 等需要的
    APT_PKGS=(cmake build-essential python3-dev pkg-config git curl
              libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev
              libswscale-dev libswresample-dev libavfilter-dev)

    SUDO=""
    if [ "$(id -u)" -eq 0 ]; then
        ok "以 root 运行，不需要 sudo"
    elif command -v sudo >/dev/null 2>&1; then
        # sudo 免密才直接跑；需要密码的话在这里就会失败，
        # 而脚本多半是在非交互环境里跑的，不能让它卡在密码提示上
        if sudo -n true 2>/dev/null; then
            SUDO="sudo"
            ok "sudo 免密可用"
        else
            warn "sudo 需要密码，跳过自动安装系统依赖"
            info "办法一：先在本终端执行一次  sudo -v  ，再重跑本脚本"
            info "办法二：手动装依赖后加 --skip-apt 重跑，例如："
            info "  sudo apt-get install -y cmake build-essential python3-dev pkg-config git curl \\"
            info "       libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev \\"
            info "       libswscale-dev libswresample-dev libavfilter-dev"
        fi
    else
        warn "不是 root 也没有 sudo，跳过系统依赖"
    fi

    if [ -n "$SUDO" ]; then
        run $SUDO apt-get update -qq || warn "apt-get update 失败"
        if run $SUDO apt-get install -y "${APT_PKGS[@]}"; then
            ok "系统依赖就绪"
        else
            err "系统依赖安装失败"
        fi
    fi
fi

# ================================================================ 2. conda
step "conda 环境 [$ENV_NAME]"

CONDA_BIN=""
if command -v conda >/dev/null 2>&1; then
    CONDA_BIN="$(command -v conda)"
elif [ -x "${HOME}/miniforge3/bin/conda" ]; then
    CONDA_BIN="${HOME}/miniforge3/bin/conda"
elif [ -x "${HOME}/miniconda3/bin/conda" ]; then
    CONDA_BIN="${HOME}/miniconda3/bin/conda"
fi

if [ -z "$CONDA_BIN" ]; then
    warn "没找到 conda，尝试安装 Miniforge（清华镜像优先）"
    TMP_INSTALLER="/tmp/miniforge-installer.sh"
    GOT=0
    for u in "${MINIFORGE_URLS[@]}"; do
        probe "$u" || { info "不通: $u"; continue; }
        if fetch "$u" "$TMP_INSTALLER"; then GOT=1; break; fi
    done
    if [ "$GOT" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            # DryRun 只展示计划，不因为网络问题中止
            warn "DryRun：所有 Miniforge 源都探测不到，正式运行时这里会重试"
            info "  会依次尝试: ${MINIFORGE_URLS[*]}"
            CONDA_BIN="conda"
        else
            die "所有 Miniforge 源都不通（检查网络，或先手动装好 conda）"
        fi
    elif [ "$DRY_RUN" -eq 0 ]; then
        bash "$TMP_INSTALLER" -b -p "${HOME}/miniforge3"
        CONDA_BIN="${HOME}/miniforge3/bin/conda"
    else
        run bash "$TMP_INSTALLER" -b -p "${HOME}/miniforge3"
        CONDA_BIN="conda"
    fi
fi
ok "conda: $CONDA_BIN"

# 环境已存在就不重复建
# 先按 conda 的标准布局猜（/envs/<名字>），猜不中再用 python3 解析 --json。
# 不能用 grep "/envs/<名字>$"：JSON 里路径后面会跟着 ] 或 :{name:...}，匹配不到。
conda_env_path() {
    local name="$1" guess
    guess="$(cd "$(dirname "$CONDA_BIN")/.." 2>/dev/null && pwd)/envs/${name}"
    if [ -x "${guess}/bin/python" ]; then
        printf '%s\n' "$guess"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        "$CONDA_BIN" env list --json 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in data.get("envs", []):
    if p.rstrip("/").endswith("/envs/" + name):
        print(p)
        break
' "$name"
    fi
}

ENV_PREFIX=""
if [ "$DRY_RUN" -eq 0 ]; then
    ENV_PREFIX="$(conda_env_path "$ENV_NAME" || true)"
fi

if [ -n "$ENV_PREFIX" ] && [ -x "$ENV_PREFIX/bin/python" ]; then
    ok "环境已存在: $ENV_PREFIX"
else
    CREATED=0
    for ch in "${CONDA_CHANNELS[@]}"; do
        if [ -n "$ch" ]; then
            info "尝试渠道: $ch"
            if run "$CONDA_BIN" create -y -n "$ENV_NAME" "python=${PY_VERSION}" --override-channels -c "$ch"; then
                CREATED=1; break
            fi
            warn "渠道失败: $ch"
        else
            info "尝试默认源"
            if run "$CONDA_BIN" create -y -n "$ENV_NAME" "python=${PY_VERSION}"; then
                CREATED=1; break
            fi
            warn "默认源也失败"
        fi
    done
    [ "$CREATED" -eq 1 ] || die "所有 conda 渠道都建不了环境"

    if [ "$DRY_RUN" -eq 0 ]; then
        ENV_PREFIX="$(conda_env_path "$ENV_NAME" || true)"
    else
        ENV_PREFIX="${HOME}/miniforge3/envs/${ENV_NAME}"
    fi
    [ -n "$ENV_PREFIX" ] || die "建完环境却找不到路径，请手工检查 conda env list"
    ok "已创建 $ENV_PREFIX"
fi

PY_BIN="${ENV_PREFIX}/bin/python"
if [ "$DRY_RUN" -eq 0 ] && [ ! -x "$PY_BIN" ]; then die "找不到 $PY_BIN"; fi

# 与 Windows 版一致：屏蔽用户级 site-packages
export PYTHONNOUSERSITE=1
if [ "$DRY_RUN" -eq 0 ]; then
    "$CONDA_BIN" env config vars set -n "$ENV_NAME" PYTHONNOUSERSITE=1 >/dev/null 2>&1 || true
    ok "已屏蔽用户级 site-packages"
fi

# ================================================================ 3. pip 镜像
step "探测 pip 镜像（国内优先，不通降级）"

PIP_OK=()
for m in "${PIP_MIRRORS[@]}"; do
    if probe "${m%/}/pip/"; then
        ok "$m"
        PIP_OK+=("$m")
    else
        info "不通，跳过: $m"
    fi
done
[ "${#PIP_OK[@]}" -gt 0 ] || die "所有 pip 镜像都不通"

pip_try() {
    for m in "${PIP_OK[@]}"; do
        if run "$PY_BIN" -m pip "$@" --index-url "$m" --disable-pip-version-check --no-warn-script-location; then
            return 0
        fi
        warn "在 $m 上失败，换下一个"
    done
    return 1
}

info "升级 pip / setuptools / wheel"
pip_try install --upgrade pip setuptools wheel || die "pip 无法从任何镜像升级"

# ================================================================ 4. ffmpeg
step "安装 ffmpeg（TorchCodec 解码视频用）"

FFMPEG_OK=0
for ch in "${CONDA_CHANNELS[@]}"; do
    if [ -n "$ch" ]; then
        if run "$CONDA_BIN" install -y -n "$ENV_NAME" ffmpeg --override-channels -c "$ch"; then
            FFMPEG_OK=1; break
        fi
    else
        if run "$CONDA_BIN" install -y -n "$ENV_NAME" ffmpeg -c conda-forge; then
            FFMPEG_OK=1; break
        fi
    fi
done

if [ "$FFMPEG_OK" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 0 ] && [ -x "${ENV_PREFIX}/bin/ffmpeg" ]; then
        ok "ffmpeg 在环境内: ${ENV_PREFIX}/bin/ffmpeg"
    else
        warn "没在环境里找到 ffmpeg，稍后自检确认"
    fi
else
    err "ffmpeg 安装失败（录制/训练会出问题）"
fi

# ================================================================ 5. 源码
step "获取 lerobot 源码"

SRC_OK=0
if [ "$FROM_PYPI" -eq 1 ]; then
    info "--from-pypi：跳过 git，直接从 pip 镜像取 sdist"
    for m in "${PIP_OK[@]}"; do
        info "在 $m 上找 sdist"
        INDEX_HTML=$(http_text "${m%/}/lerobot/" || true)
        if [ -z "$INDEX_HTML" ]; then info "  这个镜像没有 lerobot 页"; continue; fi

        # href 形如 ../../packages/xx/yy/lerobot-0.6.1.tar.gz#sha256=...
        # 注意后面跟的是 #fragment 而不是引号，正则要留出这一段
        # sort -V 按版本号排序，否则 0.10.0 会排在 0.6.1 前面
        # href 形如 ../../packages/xx/yy/lerobot-0.6.1.tar.gz#sha256=...
        # 1) 去掉 #fragment；2) 按"文件名"排序而不是完整路径——
        #    路径里的哈希目录各不相同，直接 sort -V 会用哈希决定顺序，装错版本。
        #    awk 把文件名提到第一列，sort -V 才会按版本号排。
        SDIST=$(printf '%s' "$INDEX_HTML" \
            | grep -o 'href="[^"]*\.tar\.gz[^"]*"' \
            | sed 's/^href="//; s/".*$//; s/#.*//' \
            | awk -F/ '{print $NF"\t"$0}' \
            | sort -uV \
            | tail -1 | cut -f2-)
        [ -n "$SDIST" ] || { info "  没找到 tar.gz"; continue; }

        case "$SDIST" in
            http*) ABS_URL="$SDIST" ;;
            *)     ABS_URL="${m%/}/lerobot/${SDIST}" ;;
        esac

        TMPTGZ="/tmp/lerobot-sdist.tar.gz"
        if fetch "$ABS_URL" "$TMPTGZ"; then
            # DryRun 下 fetch 只打印不下载，后面解压必然失败，直接收工
            if [ "$DRY_RUN" -eq 1 ]; then ok "（DryRun）会取该 sdist"; SRC_OK=1; break; fi
            rm -rf "$INSTALL_DIR"
            mkdir -p "$(dirname "$INSTALL_DIR")"
            rm -rf /tmp/lr-extract && mkdir -p /tmp/lr-extract
            tar -xzf "$TMPTGZ" -C /tmp/lr-extract
            EXTRACTED=$(find /tmp/lr-extract -maxdepth 1 -type d -name 'lerobot-*' | head -1)
            if [ -n "$EXTRACTED" ] && [ -f "$EXTRACTED/pyproject.toml" ]; then
                mv "$EXTRACTED" "$INSTALL_DIR"
                ok "sdist 就位: $INSTALL_DIR"
                SRC_OK=1; break
            fi
            warn "解压结果不对，换下一个镜像"
        fi
    done
else
    if [ -d "${INSTALL_DIR}/.git" ]; then
        ok "已存在 git 仓库: $INSTALL_DIR"
        run git -C "$INSTALL_DIR" pull --ff-only || warn "git pull 失败，继续用现有代码"
        SRC_OK=1
    else
        for u in "${GIT_URLS[@]}"; do
            info "尝试 $u"
            if run git clone --depth 1 "$u" "$INSTALL_DIR"; then
                if [ "$DRY_RUN" -eq 1 ] || [ -f "${INSTALL_DIR}/pyproject.toml" ]; then
                    ok "克隆成功"
                    SRC_OK=1; break
                fi
            fi
            warn "失败，换下一个"
            rm -rf "$INSTALL_DIR"
        done
        if [ "$SRC_OK" -eq 0 ]; then
            warn "所有 git 源都不通，启用 PyPI sdist 兜底"
            FROM_PYPI=1
            # 复用上面的 sdist 逻辑
            for m in "${PIP_OK[@]}"; do
                INDEX_HTML=$(http_text "${m%/}/lerobot/" || true)
                [ -n "$INDEX_HTML" ] || continue
                SDIST=$(printf '%s' "$INDEX_HTML" | grep -o 'href="[^"]*\.tar\.gz[^"]*"' | sed 's/^href="//; s/".*$//; s/#.*//' | awk -F/ '{print $NF"\t"$0}' | sort -uV | tail -1 | cut -f2-)
                [ -n "$SDIST" ] || continue
                case "$SDIST" in http*) ABS_URL="$SDIST" ;; *) ABS_URL="${m%/}/lerobot/${SDIST}" ;; esac
                TMPTGZ="/tmp/lerobot-sdist.tar.gz"
                if fetch "$ABS_URL" "$TMPTGZ"; then
                    rm -rf "$INSTALL_DIR"; mkdir -p "$(dirname "$INSTALL_DIR")"
                    rm -rf /tmp/lr-extract && mkdir -p /tmp/lr-extract
                    tar -xzf "$TMPTGZ" -C /tmp/lr-extract
                    EXTRACTED=$(find /tmp/lr-extract -maxdepth 1 -type d -name 'lerobot-*' | head -1)
                    if [ -n "$EXTRACTED" ]; then
                        mv "$EXTRACTED" "$INSTALL_DIR"; ok "sdist 就位"; SRC_OK=1; break
                    fi
                fi
            done
        fi
    fi
fi

[ "$SRC_OK" -eq 1 ] || die "拿不到 lerobot 源码"

# ================================================================ 6. 安装
step "编辑模式安装 lerobot"

SPEC=".[${EXTRAS}]"
info "安装目标: $SPEC"

INSTALL_OK=0
for m in "${PIP_OK[@]}"; do
    if ( cd "$INSTALL_DIR" && run "$PY_BIN" -m pip install -e "$SPEC" --no-input --index-url "$m" \
            --disable-pip-version-check --no-warn-script-location ); then
        INSTALL_OK=1; break
    fi
    warn "在 $m 上失败，换下一个"
done

if [ "$INSTALL_OK" -eq 1 ]; then
    ok "lerobot 安装完成"
else
    err "lerobot 安装失败"
    info "手动重试: cd $INSTALL_DIR && $PY_BIN -m pip install -e \"$SPEC\" --index-url ${PIP_OK[0]}"
fi

# ================================================================ HF 镜像
section "HuggingFace 下载源"
if probe "https://hf-mirror.com/"; then
    if [ "$DRY_RUN" -eq 0 ]; then
        # 写进 shell 启动文件，而不是改系统配置
        for rc in "$HOME/.bashrc" "$HOME/.profile"; do
            [ -f "$rc" ] || continue
            grep -q 'HF_ENDPOINT' "$rc" || printf '\nexport HF_ENDPOINT=https://hf-mirror.com\n' >> "$rc"
        done
        export HF_ENDPOINT="https://hf-mirror.com"
        ok "HF_ENDPOINT 已写入 ~/.bashrc / ~/.profile"
        info "新开终端生效；要改回去就删掉那一行"
    else
        info "会写入 HF_ENDPOINT=https://hf-mirror.com"
    fi
else
    warn "hf-mirror.com 不通，不改 HF_ENDPOINT"
fi

# ================================================================ 汇总
section "结果"

if [ "$DRY_RUN" -eq 0 ]; then
    VER="$("$PY_BIN" -c 'import lerobot;print(lerobot.__version__)' 2>/dev/null || echo '未装好')"
    ok "Python: $("$PY_BIN" -V 2>&1)"
    ok "lerobot: $VER"
    ok "环境路径: $ENV_PREFIX"
else
    info "DryRun：以上命令均未执行"
fi

printf '\n  下一步：\n'
printf '    source %s/bin/activate %s# 或 conda activate %s\n' "$ENV_PREFIX" '' "$ENV_NAME" 2>/dev/null || true
printf '    bash test-lerobot.sh      # 如果有自检脚本\n'
printf '    lerobot-find-port         # 接上机械臂后\n\n'

if [ "$FAILURES" -gt 0 ]; then
    printf '  有 %d 项失败，见上面的 [FAIL]\n' "$FAILURES"
    exit 1
fi
printf '  安装流程结束。\n'
