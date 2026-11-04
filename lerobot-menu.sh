#!/usr/bin/env bash
#
# LeRobot Linux 工具箱（Ubuntu / Debian）
#
# 与 Windows 版 lerobot-menu.ps1 对应：敲数字或字母就能做对应的事。
#
# 用法：
#   ./lerobot-menu.sh            # 打开菜单
#   ./lerobot-menu.sh 4          # 直达：标定
#   ./lerobot-menu.sh g          # 直达：GPU / 驱动管理
#   ./lerobot-menu.sh --dry-run  # 所有涉及安装的操作只打印命令
#
# 注意：GPU 驱动安装需要 sudo、可能要求重启，也可能影响桌面显示。
#       脚本会把要执行的命令先列出来让你确认，不会静默执行。

set -uo pipefail

ENV_NAME="lerobot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0

# ---------------------------------------------------------------- 输出
C_0=$'\033[0m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
C_C=$'\033[36m'; C_D=$'\033[90m'

section() { printf '\n%s== %s ==%s\n' "$C_C" "$1" "$C_0"; }
ok()      { printf '  %s[ OK ]%s  %s\n' "$C_G" "$C_0" "$1"; }
warn()    { printf '  %s[WARN]%s  %s\n' "$C_Y" "$C_0" "$1"; }
err()     { printf '  %s[FAIL]%s  %s\n' "$C_R" "$C_0" "$1"; }
info()    { printf '          %s%s%s\n' "$C_D" "$1" "$C_0"; }
die()     { printf '\n  %s[中止]%s %s\n\n' "$C_R" "$C_0" "$1"; exit 1; }

ask() {
    # ask "提示" "默认值" -> 只把答案打到 stdout；提示打到 stderr。
    # 这样 ans=$(ask ...) 拿到的才是干净的值，不会把提示文字一起吃进去。
    local prompt="$1" def="${2:-}"
    printf '  %s%s%s ' "$C_Y" "$prompt" "$C_0" >&2
    [ -n "$def" ] && printf '[%s] ' "$def" >&2
    local ans
    read -r ans || ans=""
    [ -z "$ans" ] && ans="$def"
    printf '%s' "$ans"
}

confirm() {
    # confirm "问题" -> 0=确认
    local prompt="$1" ans
    printf '  %s%s [y/N] %s' "$C_Y" "$prompt" "$C_0" >&2
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

pause_menu() { printf '\n  %s按回车返回菜单...%s' "$C_D" "$C_0"; read -r _ || true; }

run() {
    # 回显时给带空格/通配符的参数补上引号，否则用户照抄会出错
    local disp="" a
    for a in "$@"; do
        case "$a" in
            *' '*|*'*'*|*'?'*|*'^'*|*'$'*|*'"'*)
                disp="$disp '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
            *) disp="$disp $a" ;;
        esac
    done
    printf '  %s>%s%s\n' "$C_D" "$disp" "$C_0"
    if [ "$DRY_RUN" -eq 1 ]; then info "（DryRun：未执行）"; return 0; fi
    "$@"
}

# ---------------------------------------------------------------- 环境定位
find_env_prefix() {
    local bin=""
    if command -v conda >/dev/null 2>&1; then bin="$(command -v conda)"
    elif [ -x "${HOME}/miniforge3/bin/conda" ]; then bin="${HOME}/miniforge3/bin/conda"
    elif [ -x "${HOME}/miniconda3/bin/conda" ]; then bin="${HOME}/miniconda3/bin/conda"
    fi
    [ -z "$bin" ] && return 1

    local guess
    guess="$(cd "$(dirname "$bin")/.." 2>/dev/null && pwd)/envs/${ENV_NAME}"
    if [ -x "${guess}/bin/python" ]; then printf '%s\n' "$guess"; return 0; fi
    if command -v python3 >/dev/null 2>&1; then
        "$bin" env list --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for p in d.get("envs",[]):
    if p.rstrip("/").endswith("/envs/"+sys.argv[1]): print(p); break
' "$ENV_NAME" && return 0
    fi
    return 1
}

ENV_PREFIX="$(find_env_prefix || true)"
PY_BIN=""
[ -n "$ENV_PREFIX" ] && PY_BIN="${ENV_PREFIX}/bin/python"

need_env() {
    if [ -z "$ENV_PREFIX" ] || [ ! -x "$PY_BIN" ]; then
        err "找不到 conda 环境 [$ENV_NAME]"
        info "先跑 [0] 安装，或用 --env 指定环境名"
        return 1
    fi
    return 0
}

# ================================================================ GPU 检测
GPU_LINE=""; GPU_NAME=""; GPU_ARCH=""; GPU_OPEN_OK=0; GPU_DRIVER_VER=""

gpu_detect() {
    GPU_LINE=""; GPU_NAME=""; GPU_ARCH=""; GPU_OPEN_OK=0; GPU_DRIVER_VER=""

    if command -v nvidia-smi >/dev/null 2>&1; then
        local out
        out=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)
        if [ -n "$out" ]; then
            GPU_NAME=$(printf '%s' "$out" | cut -d',' -f1 | sed 's/^ *//;s/ *$//')
            GPU_DRIVER_VER=$(printf '%s' "$out" | cut -d',' -f2 | sed 's/^ *//;s/ *$//')
        fi
    fi

    if [ -z "$GPU_NAME" ] && command -v lspci >/dev/null 2>&1; then
        GPU_LINE=$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display' | grep -i nvidia | head -1)
        if [ -n "$GPU_LINE" ]; then
            # 形如: 01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3090] (rev a1)
            GPU_NAME=$(printf '%s' "$GPU_LINE" | sed -n 's/.*\[\(.*\)\].*/\1/p' | head -1)
            [ -z "$GPU_NAME" ] && GPU_NAME=$(printf '%s' "$GPU_LINE" | sed 's/.*: //' | head -1)
        fi
    fi

    [ -z "$GPU_NAME" ] && return 1

    # 从型号推断架构，决定能不能用开源内核模块
    # 开源模块（nvidia-driver-XXX-open）只支持 Turing 及以后
    local n
    n=$(printf '%s' "$GPU_NAME" | tr 'A-Z' 'a-z')
    case "$n" in
        *b100*|*b200*|*gb200*|*blackwell*|*rtx\ 50*|*rtx50*|*pro\ 6000*|*rtx\ pro*|*gb10*)
            GPU_ARCH="blackwell"; GPU_OPEN_OK=1 ;;
        *h100*|*h200*|*h800*|*hopper*|*gh200*)
            GPU_ARCH="hopper"; GPU_OPEN_OK=1 ;;
        *rtx\ 40*|*rtx40*|*l40*|*l4\ *|*ad102*|*ad104*|*ad106*|*ad107*|*ada*)
            GPU_ARCH="ada"; GPU_OPEN_OK=1 ;;
        *rtx\ 30*|*rtx30*|*a100*|*a10*|*a30*|*a40*|*ga102*|*ga104*|*ga106*|*ampere*)
            GPU_ARCH="ampere"; GPU_OPEN_OK=1 ;;
        *rtx\ 20*|*rtx20*|*t4*|*tu102*|*tu104*|*tu106*|*turing*|*quadro\ rtx*)
            GPU_ARCH="turing"; GPU_OPEN_OK=1 ;;
        *v100*|*gv100*|*volta*)
            GPU_ARCH="volta"; GPU_OPEN_OK=0 ;;
        *gtx\ 10*|*gtx10*|*p40*|*p100*|*p4\ *|*gp102*|*gp104*|*gp106*|*pascal*)
            GPU_ARCH="pascal"; GPU_OPEN_OK=0 ;;
        *)
            GPU_ARCH="unknown"; GPU_OPEN_OK=0 ;;
    esac
    return 0
}

gpu_arch_cn() {
    case "$1" in
        pascal)   printf 'Pascal（GTX 10 系 / P40 / P100）' ;;
        volta)    printf 'Volta（V100）' ;;
        turing)   printf 'Turing（RTX 20 系 / T4 / Quadro RTX）' ;;
        ampere)   printf 'Ampere（RTX 30 系 / A100 / A10）' ;;
        ada)      printf 'Ada Lovelace（RTX 40 系 / L40 / L4）' ;;
        hopper)   printf 'Hopper（H100 / H200）' ;;
        blackwell) printf 'Blackwell（RTX 50 系 / B100 / B200 / RTX PRO 6000）' ;;
        *)        printf '未知架构' ;;
    esac
}

# 各架构建议的最低驱动大版本（低于这个版本会提示驱动太旧）
gpu_min_driver() {
    case "$1" in
        pascal)    printf '470' ;;
        volta)     printf '525' ;;
        turing)    printf '470' ;;
        ampere)    printf '470' ;;
        ada)       printf '525' ;;
        hopper)    printf '550' ;;
        blackwell) printf '570' ;;
        *)         printf '' ;;
    esac
}

# 列出 apt 里可用的 nvidia-driver 大版本
gpu_apt_drivers() {
    apt-cache search --names-only '^nvidia-driver-[0-9]+$' 2>/dev/null \
        | awk '{print $1}' | sed 's/nvidia-driver-//' | sort -n | uniq
}

# ================================================================ GPU 菜单动作
action_gpu_detect() {
    section "GPU 检测"
    if ! gpu_detect; then
        warn "没有检测到 NVIDIA 显卡"
        info "如果是虚拟机，需要开 GPU 直通；如果是容器，需要 --gpus all"
        return
    fi
    ok "显卡: $GPU_NAME"
    info "架构: $(gpu_arch_cn "$GPU_ARCH")"
    if [ -n "$GPU_DRIVER_VER" ]; then
        ok "驱动已安装，版本 $GPU_DRIVER_VER"
        if [ -n "$PY_BIN" ] && [ -x "$PY_BIN" ]; then
            local av
            av=$("$PY_BIN" -c 'import torch;print(torch.cuda.is_available())' 2>/dev/null || echo "?")
            info "torch.cuda.is_available() = $av"
        fi
    else
        warn "驱动未安装（或 nvidia-smi 不可用）"
        printf '  开源内核模块支持: %s\n' "$([ "$GPU_OPEN_OK" -eq 1 ] && echo '是' || echo '否（这张卡只能用闭源驱动）')"
    fi

    local minv
    minv=$(gpu_min_driver "$GPU_ARCH")
    [ -n "$minv" ] && info "建议驱动大版本 ≥ $minv"
}

action_gpu_install() {
    section "安装 NVIDIA 驱动"

    if ! gpu_detect; then
        warn "没有检测到 NVIDIA 显卡，装驱动没有意义"
        return
    fi
    ok "显卡: $GPU_NAME"
    info "架构: $(gpu_arch_cn "$GPU_ARCH")"
    [ -n "$GPU_DRIVER_VER" ] && info "当前驱动: $GPU_DRIVER_VER"

    if ! command -v apt-get >/dev/null 2>&1; then
        err "这个脚本的驱动安装只支持 apt 系发行版"
        return
    fi

    # 驱动种类选择
    printf '\n  驱动类型：\n'
    printf '    [1] 闭源（nvidia-driver-XXX）     默认，最稳，所有卡都支持\n'
    if [ "$GPU_OPEN_OK" -eq 1 ]; then
        printf '    [2] 开源内核模块（-open 后缀）     Turing 及以后可用，和内核主线更同步\n'
    else
        printf '    %s[2] 开源内核模块 —— 这张卡不支持，跳过%s\n' "$C_D" "$C_0"
    fi
    local kind
    kind=$(ask "选择" "1")
    local suffix=""
    case "$kind" in
        2)
            if [ "$GPU_OPEN_OK" -ne 1 ]; then
                warn "$(gpu_arch_cn "$GPU_ARCH") 不支持开源内核模块，改用闭源驱动"
                suffix=""
            else
                suffix="-open"
            fi
            ;;
        *) suffix="" ;;
    esac

    # 版本选择
    info "查询 apt 里可用的驱动版本…"
    local vers
    vers=$(gpu_apt_drivers | tr '\n' ' ')
    if [ -z "$vers" ]; then
        warn "apt 源里没找到 nvidia-driver 包"
        info "先执行： sudo apt update"
        info "如果是很新的卡（Blackwell / H200 / PRO 6000），Ubuntu 自带源可能太旧，"
        info "需要加 NVIDIA 官方 CUDA 源： https://developer.nvidia.com/cuda-downloads"
        return
    fi
    info "可用版本: $vers"

    local minv rec
    minv=$(gpu_min_driver "$GPU_ARCH")
    rec=$(printf '%s\n' $vers | sort -n | tail -1)
    if [ -n "$minv" ]; then
        rec=$(printf '%s\n' $vers | sort -n | awk -v m="$minv" '$1>=m' | tail -1)
        [ -z "$rec" ] && {
            warn "apt 里的驱动都低于建议的 $minv（$(gpu_arch_cn "$GPU_ARCH") 需要更新的驱动）"
            rec=$(printf '%s\n' $vers | sort -n | tail -1)
            info "将使用最高可用版本 $rec，但仍可能不认这张卡"
        }
    fi

    local ver
    ver=$(ask "要装哪个版本" "$rec"
    )
    [ -z "$ver" ] && ver="$rec"

    local pkg="nvidia-driver-${ver}${suffix}"
    section "即将执行"
    printf '  安装包: %s\n' "$pkg"
    [ -n "$suffix" ] && printf '  类型  : 开源内核模块\n' || printf '  类型  : 闭源\n'
    printf '\n  %s注意：%s\n' "$C_Y" "$C_0"
    printf '    - 需要 sudo 密码\n'
    printf '    - 会重新编译内核模块（DKMS），可能要几分钟\n'
    printf '    - 装完需要重启才生效\n'
    printf '    - 有桌面环境的话，重启前别注销，否则可能黑屏\n'

    if ! confirm "确认安装 $pkg ？"; then info "已取消"; return; fi

    run sudo apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
    if run sudo apt-get install -y "$pkg"; then
        ok "安装完成"
        printf '\n  下一步：%s 重启 %s，然后用 [1] 检测确认驱动生效\n' "$C_G" "$C_0"
        info "重启后仍不对的话： nvidia-smi  看有没有输出"
    else
        err "安装失败"
        info "常见原因：内核头文件缺失 → sudo apt install linux-headers-\$(uname -r)"
        info "或安全启动（Secure Boot）拦住了签名模块 → 需要在 BIOS 里关掉，或用 MOK 注册"
    fi
}

action_gpu_uninstall() {
    section "卸载 NVIDIA 驱动"

    printf '  将要执行：\n'
    printf '    %ssudo apt purge -y "^nvidia-.*" "^libnvidia-.*"%s\n' "$C_D" "$C_0"
    printf '    %ssudo apt autoremove -y%s\n' "$C_D" "$C_0"
    printf '\n  %s注意：这会移除所有 NVIDIA 驱动与库，包括 CUDA 运行时。%s\n' "$C_Y" "$C_0"
    printf '  卸载后需要重启，屏幕分辨率可能临时变低。\n'
    printf '  如果只是想换驱动，用 [2] 直接装新版本即可，不必先卸载。\n'

    if ! confirm "确认卸载 ？"; then info "已取消"; return; fi

    if run sudo apt-get purge -y '^nvidia-.*' '^libnvidia-.*'; then
        run sudo apt-get autoremove -y || true
        ok "已卸载，重启后生效"
    else
        err "卸载失败"
    fi
}

action_gpu_torch() {
    section "PyTorch：切换 CPU / CUDA 版"
    if ! need_env; then return; fi

    local info_json
    info_json=$("$PY_BIN" -c 'import torch,json;print(json.dumps({"v":torch.__version__,"cuda":torch.version.cuda or ""}))' 2>/dev/null || true)
    if [ -z "$info_json" ]; then warn "环境里还没装 torch"; else info "当前: $info_json"; fi

    printf '\n  [1] 装 CUDA 版（要显卡，约 +4.5 GB）\n'
    printf '  [2] 装 CPU 版（省空间）\n'
    local pick
    pick=$(ask "选择" "1")
    if [ "$pick" = "2" ]; then
        run "$PY_BIN" -m pip install "torch>=2.7,<2.12" "torchvision>=0.22,<0.27" \
            --index-url https://mirror.sjtu.edu.cn/pytorch-wheels/cpu --no-deps \
            --no-warn-script-location || err "安装失败"
    else
        run "$PY_BIN" -m pip install "torch>=2.7,<2.12" "torchvision>=0.22,<0.27" \
            --index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple \
            --no-warn-script-location || err "安装失败"
    fi
    local chk
    chk=$("$PY_BIN" -c 'import torch;print(torch.__version__, torch.cuda.is_available())' 2>/dev/null || echo "?")
    ok "现在: $chk"
}

menu_gpu() {
    while true; do
        clear 2>/dev/null || true
        printf '\n  %s====== GPU / NVIDIA 驱动 ======%s\n\n' "$C_C" "$C_0"
        if gpu_detect; then
            printf '  当前显卡: %s\n' "$GPU_NAME"
            printf '  架构    : %s\n' "$(gpu_arch_cn "$GPU_ARCH")"
            if [ -n "$GPU_DRIVER_VER" ]; then
                printf '  驱动    : %s（已安装）\n' "$GPU_DRIVER_VER"
            else
                printf '  驱动    : %s未安装%s\n' "$C_Y" "$C_0"
            fi
        else
            printf '  当前显卡: %s未检测到%s\n' "$C_D" "$C_0"
        fi
        printf '\n'
        printf '    [1] 检测显卡 / 驱动状态\n'
        printf '    [2] 安装驱动（闭源 / 开源可选）\n'
        printf '    [3] 卸载驱动\n'
        printf '    [4] PyTorch 切 CPU / CUDA 版\n'
        printf '    [0] 返回主菜单\n\n'
        local k
        k=$(ask "请输入")
        case "$k" in
            1) action_gpu_detect; pause_menu ;;
            2) action_gpu_install; pause_menu ;;
            3) action_gpu_uninstall; pause_menu ;;
            4) action_gpu_torch; pause_menu ;;
            0|q|"") return ;;
            *) warn "没有这个选项"; sleep 1 ;;
        esac
    done
}

# ================================================================ 主菜单动作
run_local() {
    # 调用同目录下的脚本
    local script="$1"; shift
    if [ ! -f "${SCRIPT_DIR}/${script}" ]; then
        err "找不到 ${SCRIPT_DIR}/${script}"
        return 1
    fi
    bash "${SCRIPT_DIR}/${script}" "$@"
}

action_install() {
    section "安装 / 修复环境"
    printf '  将调用 install-lerobot.sh（自动检测 GPU、镜像降级）\n\n'
    local extra=""
    [ "$DRY_RUN" -eq 1 ] && extra="--dry-run"
    run_local install-lerobot.sh --env "$ENV_NAME" $extra
    ENV_PREFIX="$(find_env_prefix || true)"
    [ -n "$ENV_PREFIX" ] && PY_BIN="${ENV_PREFIX}/bin/python"
}

action_test()   { section "软件环境自检"; run_local test-lerobot.sh --env "$ENV_NAME"; }
action_hw()     { section "硬件检查"; run_local test-lerobot.sh --env "$ENV_NAME" --hw; }

lerobot_cmd() {
    # lerobot_cmd 命令名 参数...
    need_env || return 1
    local c="$1"; shift
    local exe="${ENV_PREFIX}/bin/${c}"
    if [ ! -x "$exe" ]; then
        err "环境里没有 $c"
        info "先跑 [0] 安装，或 [1] 自检看看缺什么"
        return 1
    fi
    printf '\n  %s> %s %s%s\n' "$C_D" "$c" "$*" "$C_0"
    "$exe" "$@"
}

pick_port() {
    need_env || return 1
    local ports
    ports=$("$PY_BIN" -c 'import serial.tools.list_ports as l
for p in l.comports():
    d=p.device
    if d.startswith("/dev/ttyACM") or d.startswith("/dev/ttyUSB"): print("%s|%s"%(d,p.description))' 2>/dev/null)
    if [ -z "$ports" ]; then
        warn "没检测到 USB 串口（机械臂没插？）"
        ask "手动输入串口（如 /dev/ttyACM0）"
        return
    fi

    # 官方 SO-ARM 教程里反复出现 sudo chmod 666 /dev/ttyACM*，
    # 就是因为默认权限下普通用户打不开，接上臂第一件事就会撞 Permission denied。
    local denied=""
    while IFS='|' read -r d _; do
        [ -z "$d" ] && continue
        if [ ! -r "$d" ] || [ ! -w "$d" ]; then denied="$denied $d"; fi
    done <<< "$ports"
    if [ -n "$denied" ]; then
        warn "这些串口当前用户打不开:$denied"
        info "临时放行： sudo chmod 666 /dev/ttyACM*"
        info "永久生效： sudo usermod -aG dialout \$USER   然后重新登录"
    fi

    printf '\n  检测到：\n'
    local i=0
    while IFS='|' read -r dev desc; do
        i=$((i+1)); printf '    [%d] %-14s %s\n' "$i" "$dev" "$desc"
    done <<< "$ports"
    # 官方教程里的经验：先插的是从臂、后插的是主臂
    info "经验：先插的通常是 ttyACM0（从臂），后插的是 ttyACM1（主臂）"

    local sel; sel=$(ask "选择串口" "1")
    local dev
    dev=$(printf '%s\n' "$ports" | sed -n "${sel}p" | cut -d'|' -f1)
    [ -z "$dev" ] && dev=$(printf '%s\n' "$ports" | head -1 | cut -d'|' -f1)
    printf '%s' "$dev"
}

action_find_port() { lerobot_cmd lerobot-find-port; }

action_setup_motors() {
    local side="robot" kind
    kind=$(ask "主臂(leader)? y=主臂 n=从臂" "n")
    case "$kind" in y|Y) side="teleop" ;; esac
    local type; type=$(ask "机型（so101_follower/so101_leader）" "$([ "$side" = teleop ] && echo so101_leader || echo so101_follower)")
    local port; port=$(pick_port)
    [ -z "$port" ] && return
    lerobot_cmd lerobot-setup-motors "--${side}.type=${type}" "--${side}.port=${port}"
}

action_calibrate() {
    local side="robot" kind
    kind=$(ask "标定主臂(leader)? y=主臂 n=从臂" "n")
    case "$kind" in y|Y) side="teleop" ;; esac
    local type; type=$(ask "机型" "$([ "$side" = teleop ] && echo so101_leader || echo so101_follower)")
    local port; port=$(pick_port)
    [ -z "$port" ] && return
    local id; id=$(ask "标定 id" "$([ "$side" = teleop ] && echo my_leader_arm || echo my_follower_arm)")
    printf '\n  标定步骤：1) 各关节摆到行程中间 2) 回车 3) 每个关节走完整行程\n'
    lerobot_cmd lerobot-calibrate "--${side}.type=${type}" "--${side}.port=${port}" "--${side}.id=${id}"
}

# ---------------------------------------------------------------- 校准文件管理
# 路径来自 lerobot 源码：calibration/robots/<机型>/<id>.json
#                        calibration/teleoperators/<机型>/<id>.json
# 根目录可以被三个环境变量覆盖，必须跟着走，否则删了个空目录还以为成功了。
calib_root() {
    if [ -n "${HF_LEROBOT_CALIBRATION:-}" ]; then
        printf '%s' "$HF_LEROBOT_CALIBRATION"
    elif [ -n "${HF_LEROBOT_HOME:-}" ]; then
        printf '%s/calibration' "$HF_LEROBOT_HOME"
    elif [ -n "${HF_HOME:-}" ]; then
        printf '%s/lerobot/calibration' "$HF_HOME"
    else
        printf '%s/.cache/huggingface/lerobot/calibration' "$HOME"
    fi
}

calib_list() {
    local root; root=$(calib_root)
    [ -d "$root" ] || return 0
    find "$root" -type f -name '*.json' 2>/dev/null | sort
}

action_calibration() {
    local root; root=$(calib_root)
    section "校准管理"
    info "校准目录: $root"
    [ -n "${HF_LEROBOT_CALIBRATION:-}" ] && info "（来自 HF_LEROBOT_CALIBRATION）"
    [ -z "${HF_LEROBOT_CALIBRATION:-}" ] && [ -n "${HF_LEROBOT_HOME:-}" ] && info "（来自 HF_LEROBOT_HOME）"
    [ -z "${HF_LEROBOT_CALIBRATION:-}" ] && [ -z "${HF_LEROBOT_HOME:-}" ] && [ -n "${HF_HOME:-}" ] && info "（来自 HF_HOME）"
    echo

    local files; files=$(calib_list)
    if [ -z "$files" ]; then
        warn "还没有校准文件"
        info "接上机械臂后用 [4] 标定"
        return
    fi

    printf '  现有校准文件：\n'
    local n=0
    while IFS= read -r f; do
        n=$((n+1))
        local rel size mt
        rel=${f#"$root"/}
        size=$(stat -c %s "$f" 2>/dev/null || echo "?")
        mt=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
        printf '    [%d] %-46s %5s B  %s\n' "$n" "$rel" "$size" "$mt"
    done <<< "$files"

    printf '\n  校准不好（抖动、漂移、动作范围不对）就删掉重来。\n'
    printf '    [1] 删除全部（整个目录改名为 .bak-时间戳，可还原）\n'
    printf '    [2] 只删指定的一个\n'
    printf '    [3] 只备份不删\n'
    printf '    [4] 删除后接着重新标定\n'
    printf '    [0] 返回\n'

    local k; k=$(ask "选择" "0")
    local bak; bak="${root}.bak-$(date +%Y%m%d-%H%M%S)"

    case "$k" in
        1)
            printf '\n  %s整个校准目录会被改名成备份，效果等于清空。%s\n' "$C_Y" "$C_0"
            confirm "确认删除全部校准？" || { info "已取消"; return; }
            if mv "$root" "$bak"; then
                ok "已备份并清空：$bak"
                info "要还原就把该目录改回 ${root}"
                info "接下来用 [4] 重新标定"
            else
                err "操作失败（权限？目录被占用？）"
            fi
            ;;
        2)
            local pick; pick=$(ask "要删第几个" "1")
            local target
            target=$(printf '%s\n' "$files" | sed -n "${pick}p")
            [ -z "$target" ] && { warn "没有第 $pick 项"; return; }
            printf '\n  将要删除：%s\n' "${target#"$root"/}"
            confirm "确认删除？" || { info "已取消"; return; }
            if rm -f "$target"; then ok "已删除，可用 [4] 重新标定"; else err "删除失败"; fi
            ;;
        3)
            if cp -a "$root" "$bak"; then
                ok "已备份到：$bak"
            else
                err "备份失败"
            fi
            ;;
        4)
            confirm "删除全部并重新标定？" || { info "已取消"; return; }
            if mv "$root" "$bak"; then
                ok "已备份并清空：$bak"
                action_calibrate
            else
                err "操作失败"
            fi
            ;;
        0|"") return ;;
        *) warn "没有这个选项" ;;
    esac
}

action_teleoperate() {
    local fport lport fid lid
    fport=$(pick_port); [ -z "$fport" ] && return
    lport=$(pick_port); [ -z "$lport" ] && return
    fid=$(ask "从臂 id" "my_follower_arm")
    lid=$(ask "主臂 id" "my_leader_arm")
    lerobot_cmd lerobot-teleoperate \
        --robot.type=so101_follower "--robot.port=$fport" "--robot.id=$fid" \
        --teleop.type=so101_leader "--teleop.port=$lport" "--teleop.id=$lid"
}

action_record() {
    local fport lport
    fport=$(pick_port); [ -z "$fport" ] && return
    lport=$(pick_port); [ -z "$lport" ] && return
    local user; user=$(ask "HF_USER（HuggingFace 用户名）" "${HF_USER:-}")
    local name; name=$(ask "数据集名字" "so101_dataset")
    local task; task=$(ask "任务描述" "put the red brick in a bowl")
    local eps; eps=$(ask "录几回合" "30")
    local fid lid
    fid=$(ask "从臂 id" "my_follower_arm")
    lid=$(ask "主臂 id" "my_leader_arm")
    printf '\n  录制中：→/n 保存进入下一回合；←/r 丢重录；ESC/q 结束\n'
    lerobot_cmd lerobot-record \
        --robot.type=so101_follower "--robot.port=$fport" "--robot.id=$fid" \
        --teleop.type=so101_leader "--teleop.port=$lport" "--teleop.id=$lid" \
        "--dataset.repo_id=${user}/${name}" "--dataset.num_episodes=$eps" \
        "--dataset.single_task=$task" --dataset.streaming_encoding=true
}

action_replay() {
    local user; user=$(ask "HF_USER" "${HF_USER:-}")
    local ds; ds=$(ask "数据集 repo_id" "${user}/so101_dataset")
    local ep; ep=$(ask "回放第几回合（从 0 开始）" "0")
    local fport; fport=$(pick_port); [ -z "$fport" ] && return
    lerobot_cmd lerobot-replay "--dataset.repo_id=$ds" "--dataset.episode=$ep" \
        --robot.type=so101_follower "--robot.port=$fport" --robot.id=my_follower_arm
}

action_train() {
    local user; user=$(ask "HF_USER" "${HF_USER:-}")
    local ds; ds=$(ask "数据集 repo_id" "${user}/so101_dataset")
    local pol; pol=$(ask "策略（act/diffusion/smolvla/pi0/pi05）" "act")
    local steps; steps=$(ask "训练步数" "20000")
    local dev; dev=$(ask "设备（cuda/cpu）" "cuda")
    lerobot_cmd lerobot-train "--dataset.repo_id=$ds" "--policy.type=$pol" \
        "--policy.device=$dev" "--output_dir=outputs/train/${pol}_so101" \
        "--job_name=${pol}_so101" "--steps=$steps"
}

action_rollout() {
    local pol; pol=$(ask "策略路径或 repo_id" "")
    [ -z "$pol" ] && { warn "需要先训练出策略"; return; }
    local fport; fport=$(pick_port); [ -z "$fport" ] && return
    local task; task=$(ask "任务描述（与录制时一致）" "put the red brick in a bowl")
    lerobot_cmd lerobot-rollout --strategy.type=base "--policy.path=$pol" \
        --robot.type=so101_follower "--robot.port=$fport" "--robot.id=my_follower_arm" \
        "--task=$task" --duration=60
}

action_cameras() {
    need_env || return 1
    local exe="${ENV_PREFIX}/bin/lerobot-find-cameras"
    [ -x "$exe" ] && "$exe" opencv || err "没有 lerobot-find-cameras"
}

action_info() {
    section "环境详情"
    if need_env; then
        ok "环境路径: $ENV_PREFIX"
        ok "Python: $("$PY_BIN" -V 2>&1)"
        local lv; lv=$("$PY_BIN" -c 'import lerobot;print(lerobot.__version__)' 2>/dev/null || echo "未装")
        ok "lerobot: $lv"
        printf '\n  关键包：\n'
        "$PY_BIN" -m pip list 2>/dev/null | grep -aiE '^torch|^torchvision|^numpy|^opencv|^feetech|^datasets' | sed 's/^/    /'
    fi
    section "GPU"
    action_gpu_detect
    section "标定文件"
    local cal; cal=$(calib_root)
    if [ -d "$cal" ]; then find "$cal" -name '*.json' 2>/dev/null | sed 's/^/    /' || true
    else info "还没有标定过"; fi
    section "HuggingFace"
    info "HF_ENDPOINT = ${HF_ENDPOINT:-（未设置）}"
}

action_mirror() {
    section "HuggingFace 镜像"
    printf '  [1] 使用 hf-mirror.com（国内推荐）\n'
    printf '  [2] 取消（直连官方）\n'
    local k; k=$(ask "选择" "1")
    local line='export HF_ENDPOINT=https://hf-mirror.com'
    if [ "$k" = "2" ]; then
        for rc in "$HOME/.bashrc" "$HOME/.profile"; do
            [ -f "$rc" ] && sed -i '/HF_ENDPOINT/d' "$rc"
        done
        ok "已移除 HF_ENDPOINT"
    else
        for rc in "$HOME/.bashrc" "$HOME/.profile"; do
            [ -f "$rc" ] || continue
            grep -q 'HF_ENDPOINT' "$rc" || printf '\n%s\n' "$line" >> "$rc"
        done
        ok "已写入 HF_ENDPOINT=https://hf-mirror.com"
    fi
    info "新终端生效"
}

action_help() {
    section "命令速查"
    if [ -n "$ENV_PREFIX" ] && [ -d "${ENV_PREFIX}/bin" ]; then
        ls "${ENV_PREFIX}/bin" | grep -a '^lerobot-' | sed 's/^/    /'
    else
        info "环境未安装，装好后这里会列出全部命令"
    fi
    printf '\n  查某个命令的参数： lerobot-<命令> --help\n'
}

# ---------------------------------------------------------------- 舵机调试工具
# Seeed 的图形化舵机调试工具（Seeed_RoboController）
# 注意三个坑，Wiki 上没写清楚：
#   1) 工具在 factory 分支上；默认分支 master 是另一个 Web 版，直接 clone 会拿错东西
#   2) 依赖只有 PySide6 + pyserial，pyserial 环境里通常已有
#   3) 界面是 Qt 的，没有桌面环境（DISPLAY/WAYLAND_DISPLAY）跑不起来
SERVO_TOOL_DIR="${HOME}/Seeed_RoboController"
SERVO_TOOL_BRANCH="factory"
SERVO_TOOL_URL="https://github.com/Seeed-Projects/Seeed_RoboController.git"

servo_tool_installed() { [ -d "${SERVO_TOOL_DIR}/.git" ] && [ -f "${SERVO_TOOL_DIR}/src/gui/factory_calibration_tool.py" ]; }

servo_tool_install() {
    need_env || return 1
    section "安装舵机调试工具"

    if ! command -v git >/dev/null 2>&1; then
        err "需要 git 才能拉取工具源码"
        info "sudo apt install -y git"
        info "或者先跑 [0] 安装环境，那边会把 git 一起装上"
        return 1
    fi

    if [ -d "$SERVO_TOOL_DIR" ] && [ ! -d "${SERVO_TOOL_DIR}/.git" ]; then
        warn "$SERVO_TOOL_DIR 已存在但不是 git 仓库"
        info "先删除或用 [4] 卸载后再装"
        return 1
    fi

    if [ -d "${SERVO_TOOL_DIR}/.git" ]; then
        info "已存在，尝试更新"
        run git -C "$SERVO_TOOL_DIR" fetch --depth 1 origin "$SERVO_TOOL_BRANCH" || warn "拉取失败，继续用现有代码"
        run git -C "$SERVO_TOOL_DIR" checkout "$SERVO_TOOL_BRANCH" || true
        run git -C "$SERVO_TOOL_DIR" pull --ff-only || warn "更新失败，继续用现有代码"
    else
        local ok=0 u
        for u in \
            "https://gh-proxy.com/https://github.com/Seeed-Projects/Seeed_RoboController.git" \
            "https://ghfast.top/https://github.com/Seeed-Projects/Seeed_RoboController.git" \
            "$SERVO_TOOL_URL"
        do
            info "尝试 $u"
            # 关键是 -b factory，否则默认分支是 master（另一个 Web 项目）
            if run git clone --depth 1 -b "$SERVO_TOOL_BRANCH" "$u" "$SERVO_TOOL_DIR"; then
                ok=1; break
            fi
            warn "失败，换下一个源"
            rm -rf "$SERVO_TOOL_DIR"
        done
        if [ "$ok" -eq 0 ]; then
            err "拉不下来（检查网络，或手动 git clone -b factory）"
            return 1
        fi
    fi

    if [ ! -f "${SERVO_TOOL_DIR}/src/gui/factory_calibration_tool.py" ]; then
        warn "克隆成功但没找到入口脚本"
        info "确认分支是不是 factory；master 分支是另一个项目"
        return 1
    fi
    ok "代码就位：$SERVO_TOOL_DIR（分支 $SERVO_TOOL_BRANCH）"

    info "安装依赖 PySide6（约 200 MB，慢一点）"
    # 注意：PIP_MIRRORS 定义在 install-lerobot.sh 里，本脚本没有这个数组，
    # 直接引用会因 set -u 报未定义。这里用本地列表。
    local mirrors=(
        "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"
        "https://mirrors.aliyun.com/pypi/simple"
        "https://pypi.org/simple"
    )
    local m installed=0
    for m in "${mirrors[@]}"; do
        if run "$PY_BIN" -m pip install "PySide6>=6.0.0" "pyserial>=3.5" \
                --index-url "$m" --disable-pip-version-check --no-warn-script-location; then
            installed=1; break
        fi
        warn "在这个源上失败，换下一个"
    done
    [ "$installed" -eq 1 ] && ok "依赖安装完成" || err "依赖安装失败，可手动： $PY_BIN -m pip install PySide6 pyserial"
}

servo_tool_check() {
    need_env || return 1
    section "环境检查"
    if ! servo_tool_installed; then
        warn "还没安装，先用 [1]"
        return 1
    fi
    ( cd "$SERVO_TOOL_DIR" && "$PY_BIN" setup.py )
}

servo_tool_launch() {
    need_env || return 1
    section "启动舵机调试工具"
    if ! servo_tool_installed; then
        warn "还没安装，先用 [1]"
        return 1
    fi

    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        err "当前没有图形界面（DISPLAY 与 WAYLAND_DISPLAY 都没设置）"
        info "这个工具是 Qt 界面，必须有桌面环境才能跑。"
        info "如果是 SSH 远程，可以："
        info "  - 用 ssh -X 转发图形（速度慢，能用）"
        info "  - 或直接在机械臂那台机器的桌面上运行"
        info "没有桌面又只想验证舵机，用 [2] 找串口 + [4] 标定机械臂 也够用"
        return 1
    fi

    if ! "$PY_BIN" -c 'import PySide6' >/dev/null 2>&1; then
        warn "环境里没有 PySide6，先跑 [1] 安装"
        return 1
    fi

    info "启动中，界面会单独弹出（关闭窗口即退出）"
    info "串口被占用时可手动指定： --port1 /dev/ttyUSB0 --port2 /dev/ttyUSB1"
    ( cd "$SERVO_TOOL_DIR" && "$PY_BIN" -m src.gui.factory_calibration_tool )
}

servo_tool_uninstall() {
    section "卸载舵机调试工具"
    if [ ! -d "$SERVO_TOOL_DIR" ]; then
        info "没装，无需卸载"
        return 0
    fi
    info "将删除目录：$SERVO_TOOL_DIR"
    info "（PySide6 不删，可能被别的程序用着）"
    confirm "确认删除？" || { info "已取消"; return 0; }
    if rm -rf "$SERVO_TOOL_DIR"; then ok "已删除"; else err "删除失败"; fi
}

# 主菜单直达：安装
action_servo_install() {
    servo_tool_install
    if servo_tool_installed; then
        echo
        if confirm "装好了，现在打开图形界面？"; then
            servo_tool_launch
        else
            info "以后用主菜单 [o] 打开"
        fi
    fi
}

# 主菜单直达：打开（没装就先问要不要装）
action_servo_open() {
    section "舵机调试工具"
    if ! servo_tool_installed; then
        warn "还没安装"
        if confirm "现在安装？"; then
            servo_tool_install || return 1
        else
            return 1
        fi
    fi
    servo_tool_launch
}

action_servo_tool() {
    while true; do
        clear 2>/dev/null || true
        printf '\n  %s====== 舵机调试工具（Seeed_RoboController）======%s\n\n' "$C_C" "$C_0"
        if servo_tool_installed; then
            printf '  状态: %s已安装%s  %s\n' "$C_G" "$C_0" "$SERVO_TOOL_DIR"
        else
            printf '  状态: %s未安装%s\n' "$C_D" "$C_0"
        fi
        printf '\n'
        printf '    [1] 安装 / 更新\n'
        printf '    [2] 环境检查\n'
        printf '    [3] 启动图形界面\n'
        printf '    [4] 卸载\n'
        printf '    [5] 官方说明（网址）\n'
        printf '    [0] 返回\n\n'

        local k; k=$(ask "请输入")
        case "$k" in
            1) servo_tool_install ;;
            2) servo_tool_check ;;
            3) servo_tool_launch ;;
            4) servo_tool_uninstall ;;
            5)
                section "官方说明"
                info "https://wiki.seeedstudio.com/cn/lerobot_steering_gear_debugging_tool/"
                echo
                printf '  能做什么：\n'
                printf '    - 检测 1-6 号舵机是否都在线\n'
                printf '    - 改舵机 ID（ID 重复时只能一个个拆下来重刷）\n'
                printf '    - 写中位值（把当前位置当零点烧进去）\n'
                printf '    - 单个舵机拖进度条测试、看电压/温度/负载/电流\n'
                printf '    - 读写寄存器、改波特率、恢复出厂\n'
                echo
                printf '  %s注意：这是 Qt 图形程序，必须有桌面环境；无桌面请用本菜单的 [2][4]。%s\n' "$C_Y" "$C_0"
                ;;
            0|"") return ;;
            *) warn "没有这个选项"; sleep 1; continue ;;
        esac
        pause_menu
    done
}

# ---------------------------------------------------------------- 高级选项
action_advanced() {
    while true; do
        clear 2>/dev/null || true
        printf '\n  %s====== 高级选项（其余 lerobot 命令）======%s\n\n' "$C_C" "$C_0"
        printf '    [1] lerobot-info              环境与硬件信息\n'
        printf '    [2] lerobot-find-joint-limits 探测关节限位\n'
        printf '    [3] lerobot-dataset-viz       数据集可视化\n'
        printf '    [4] lerobot-imgtransform-viz  图像变换可视化\n'
        printf '    [5] lerobot-eval              评估策略\n'
        printf '    [6] lerobot-annotate          数据标注\n'
        printf '    [7] lerobot-edit-dataset      数据集编辑（删回合/合并/改特征）\n'
        printf '    [8] lerobot-train-tokenizer   训练 VLA tokenizer\n'
        printf '    [9] lerobot-setup-can         Damiao CAN 总线初始化\n'
        printf '\n    [s] 舵机工具：环境检查 / 卸载 / 说明\n'
        printf '    [c] 任意命令（自己敲参数）\n'
        printf '    [0] 返回\n\n'

        local k; k=$(ask "请输入")
        case "$k" in
            1) lerobot_cmd lerobot-info ;;
            2)
                local port; port=$(pick_port); [ -z "$port" ] && { pause_menu; continue; }
                local type; type=$(ask "机型" "so101_follower")
                local id; id=$(ask "id" "my_follower_arm")
                lerobot_cmd lerobot-find-joint-limits \
                    "--robot.type=$type" "--robot.port=$port" "--robot.id=$id"
                ;;
            3)
                local ds; ds=$(ask "数据集 repo_id" "${HF_USER:+$HF_USER/}so101_dataset")
                local ep; ep=$(ask "回合号（留空=全部）" "")
                if [ -n "$ep" ]; then
                    lerobot_cmd lerobot-dataset-viz "--repo-id=$ds" "--episode-index=$ep"
                else
                    lerobot_cmd lerobot-dataset-viz "--repo-id=$ds"
                fi
                ;;
            4)
                local ds2; ds2=$(ask "数据集 repo_id" "${HF_USER:+$HF_USER/}so101_dataset")
                lerobot_cmd lerobot-imgtransform-viz "--repo-id=$ds2"
                ;;
            5)
                local pol; pol=$(ask "策略路径（outputs/train/... 或 HF repo_id）" "")
                [ -z "$pol" ] && { warn "需要策略路径"; pause_menu; continue; }
                lerobot_cmd lerobot-eval "--policy.path=$pol"
                ;;
            6)
                local ds3; ds3=$(ask "数据集 repo_id" "${HF_USER:+$HF_USER/}so101_dataset")
                lerobot_cmd lerobot-annotate "--repo-id=$ds3"
                ;;
            7)
                local ds4; ds4=$(ask "数据集 repo_id" "${HF_USER:+$HF_USER/}so101_dataset")
                info "常见操作： delete_episodes / merge_datasets / add_features"
                local op; op=$(ask "操作类型（留空看帮助）" "")
                if [ -n "$op" ]; then
                    lerobot_cmd lerobot-edit-dataset "--repo-id=$ds4" "--operation.type=$op"
                else
                    lerobot_cmd lerobot-edit-dataset "--help"
                fi
                ;;
            8)
                local ds5; ds5=$(ask "数据集 repo_id" "${HF_USER:+$HF_USER/}so101_dataset")
                lerobot_cmd lerobot-train-tokenizer "--dataset.repo_id=$ds5"
                ;;
            9)
                info "Damiao 电机走 CAN 总线（OpenArm 等），需要先配置 can 接口"
                lerobot_cmd lerobot-setup-can --help
                ;;
            s|S)
                action_servo_tool
                continue
                ;;
            c|C)
                need_env || { pause_menu; continue; }
                printf '\n  可用命令（不带 lerobot- 前缀）：\n    '
                ls "$ENV_PREFIX/bin" 2>/dev/null | grep -a '^lerobot-' | sed 's/^lerobot-//' | tr '\n' ' '
                printf '\n\n'
                local short; short=$(ask "要运行哪个" "")
                [ -z "$short" ] && { pause_menu; continue; }
                local args; args=$(ask "参数（留空则显示 --help）" "--help")
                local -a argv=()
                read -ra argv <<< "$args"
                lerobot_cmd "lerobot-$short" "${argv[@]}"
                ;;
            0|"") return ;;
            *) warn "没有这个选项"; sleep 1; continue ;;
        esac
        pause_menu
    done
}

# ---------------------------------------------------------------- 自由终端
action_terminal() {
    if ! need_env; then return 1; fi
    section "LeRobot 终端"
    info "环境已激活：$ENV_NAME"
    info "输入 exit 回到菜单"

    local rc
    rc=$(mktemp /tmp/lerobot-term-XXXXXX.rc 2>/dev/null || echo "/tmp/lerobot-term.rc")
    cat > "$rc" <<RCEOF
export CONDA_PREFIX="$ENV_PREFIX"
export CONDA_DEFAULT_ENV="$ENV_NAME"
export PATH="$ENV_PREFIX/bin:\$PATH"
export PYTHONNOUSERSITE=1
export HF_ENDPOINT="\${HF_ENDPOINT:-https://hf-mirror.com}"
if [ -d "$ENV_PREFIX/lib" ]; then export LD_LIBRARY_PATH="$ENV_PREFIX/lib:\${LD_LIBRARY_PATH:-}"; fi
PS1='(lerobot) \w \$ '
echo "================================================"
echo " LeRobot 终端（环境已激活）"
echo " python : \$(command -v python)"
echo " 输入 exit 回到菜单"
echo "================================================"
RCEOF

    bash --rcfile "$rc" -i
    rm -f "$rc"
    ok "已退出终端"
}

# ================================================================ 主菜单
show_menu() {
    clear 2>/dev/null || true
    printf '\n  %s================================================================%s\n' "$C_C" "$C_0"
    printf '            LeRobot 工具箱（Linux）· 敲数字或字母\n'
    printf '  %s================================================================%s\n' "$C_C" "$C_0"
    if [ -n "$ENV_PREFIX" ]; then
        printf '  环境: %s -> %s\n' "$ENV_NAME" "$ENV_PREFIX"
    else
        printf '  环境: %s -> %s未安装%s\n' "$ENV_NAME" "$C_R" "$C_0"
    fi
    printf '\n   环境\n'
    printf '    [0] 安装 / 修复环境\n'
    printf '    [1] 软件环境自检\n'
    printf '    [w] 硬件检查（串口/相机/标定）\n'
    printf '    [g] GPU 与 NVIDIA 驱动   %s← 装驱动、切换 CPU/CUDA%s\n' "$C_D" "$C_0"
    printf '\n   机械臂准备（按顺序做一次）\n'
    printf '    [2] 查找串口\n'
    printf '    [3] 设置电机 ID\n'
    printf '    [4] 标定机械臂    [r] 校准管理（删除/重标定）\n'
    printf '    [s] 安装 / 更新舵机调试工具（Seeed 图形界面）\n'
    printf '    [o] 打开舵机调试工具\n'
    printf '\n   日常使用\n'
    printf '    [5] 遥操作    [6] 录制    [7] 训练    [8] 推理    [9] 回放\n'
    printf '\n   其他\n'
    printf '    [c] 相机检测   [i] 环境详情   [m] HF 镜像   [h] 命令速查   [q] 退出\n'
    printf '    [t] 打开 LeRobot 终端（环境已激活，可自由敲命令）\n'
    printf '    [x] 高级选项（其余 8 个命令）\n\n'
}

dispatch() {
    case "$1" in
        0) action_install ;;
        1) action_test ;;
        w|W) action_hw ;;
        g|G) menu_gpu; return ;;
        2) action_find_port ;;
        3) action_setup_motors ;;
        4) action_calibrate ;;
        r|R) action_calibration ;;
        s|S) action_servo_install ;;
        o|O) action_servo_open ;;
        5) action_teleoperate ;;
        6) action_record ;;
        7) action_train ;;
        8) action_rollout ;;
        9) action_replay ;;
        c|C) action_cameras ;;
        v|V) info "数据集可视化：lerobot-dataset-viz --help" ;;
        i|I) action_info ;;
        m|M) action_mirror ;;
        h|H) action_help ;;
        t|T) action_terminal ;;
        x|X) action_advanced; return ;;
        q|Q) printf '\n  再见。\n\n'; exit 0 ;;
        *) err "没有这个选项: $1"; return 1 ;;
    esac
}

# ---------------------------------------------------------------- 入口
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --env) ENV_NAME="$2"; shift ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) ITEM="$1" ;;
    esac
    shift
done

[ "$DRY_RUN" -eq 1 ] && warn "DryRun 模式：所有安装类操作只打印命令"

if [ -n "${ITEM:-}" ]; then
    dispatch "$ITEM"
    exit $?
fi

while true; do
    show_menu
    k=$(ask "请输入")
    [ -z "$k" ] && continue
    dispatch "$k"
    pause_menu
done
