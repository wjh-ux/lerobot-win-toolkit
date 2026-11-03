#!/usr/bin/env bash
#
# LeRobot Linux 自检（Ubuntu / Debian）
#
# 与 Windows 版 test-lerobot.ps1 对应，分两组：
#   默认      只查软件环境（装完应该全 PASS）
#   -H/--hw   额外查硬件（串口、标定文件、摄像头）
#
# 用法：
#   ./test-lerobot.sh
#   ./test-lerobot.sh --hw
#   ./test-lerobot.sh --env myenv

set -uo pipefail

ENV_NAME="lerobot"
WITH_HW=0

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--hw|--hardware) WITH_HW=1 ;;
        --env) ENV_NAME="$2"; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "不认识的参数: $1" >&2; exit 2 ;;
    esac
    shift
done

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_D=$'\033[90m'; C_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0

res() {
    local name="$1" status="$2" detail="${3:-}"
    case "$status" in
        PASS) PASS=$((PASS+1)); printf '  %s[PASS]%s %-28s %s\n' "$C_G" "$C_0" "$name" "$detail" ;;
        WARN) WARN=$((WARN+1)); printf '  %s[WARN]%s %-28s %s\n' "$C_Y" "$C_0" "$name" "$detail" ;;
        FAIL) FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %-28s %s\n' "$C_R" "$C_0" "$name" "$detail" ;;
    esac
}

echo
echo "${C_C}===== LeRobot 环境自检（Linux）=====${C_0}"
echo

# ---------------------------------------------------------------- 定位环境
CONDA_BIN=""
for c in conda "${HOME}/miniforge3/bin/conda" "${HOME}/miniconda3/bin/conda"; do
    if command -v "$c" >/dev/null 2>&1; then CONDA_BIN="$c"; break; fi
    [ -x "$c" ] && { CONDA_BIN="$c"; break; }
done

ENV_PREFIX=""
if [ -n "$CONDA_BIN" ]; then
    guess="$(cd "$(dirname "$CONDA_BIN")/.." 2>/dev/null && pwd)/envs/${ENV_NAME}"
    if [ -x "${guess}/bin/python" ]; then
        ENV_PREFIX="$guess"
    elif command -v python3 >/dev/null 2>&1; then
        ENV_PREFIX="$("$CONDA_BIN" env list --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for p in d.get("envs",[]):
    if p.rstrip("/").endswith("/envs/"+sys.argv[1]): print(p); break
' "$ENV_NAME")"
    fi
fi

if [ -z "$ENV_PREFIX" ] || [ ! -x "${ENV_PREFIX}/bin/python" ]; then
    res "conda 环境" "FAIL" "找不到环境 [$ENV_NAME]"
    echo
    echo "  先跑： ./install-lerobot.sh"
    echo
    exit 1
fi
res "conda 环境" "PASS" "$ENV_PREFIX"

PY="${ENV_PREFIX}/bin/python"
export PYTHONNOUSERSITE=1

# ---------------------------------------------------------------- 软件环境
ver="$("$PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)"
if [ -n "$ver" ]; then
    major_minor="${ver%.*}"
    if [ "$(printf '%s\n3.12\n' "$major_minor" | sort -V | head -1)" = "3.12" ]; then
        res "Python 版本" "PASS" "$ver"
    else
        res "Python 版本" "WARN" "$ver（LeRobot 要求 >= 3.12）"
    fi
else
    res "Python 版本" "FAIL" "无法运行 $PY"
fi

pipv="$("$PY" -m pip --version 2>/dev/null | awk '{print $2}')"
[ -n "$pipv" ] && res "pip 可用" "PASS" "pip $pipv" || res "pip 可用" "FAIL" "pip 不可用"

lv="$("$PY" -c 'import lerobot;print(lerobot.__version__)' 2>/dev/null)"
if [ -n "$lv" ]; then
    loc="$("$PY" -c 'import lerobot,os;print(os.path.dirname(lerobot.__file__))' 2>/dev/null)"
    mode="已安装"
    case "$loc" in */src/lerobot) mode="编辑模式（指向源码）" ;; esac
    res "lerobot 已安装" "PASS" "$lv  $mode"
    printf '  %s        位置：%s%s\n' "$C_D" "$loc" "$C_0"
else
    res "lerobot 已安装" "FAIL" "import lerobot 失败"
fi

for pair in \
    "lerobot.robots.so_follower:从臂（SO-100/101）" \
    "lerobot.teleoperators.so_leader:主臂（SO-100/101）" \
    "lerobot.motors.feetech:飞特舵机 SDK" \
    "lerobot.cameras.opencv:OpenCV 相机" \
    "lerobot.datasets:数据集" \
    "lerobot.policies:策略模型"
do
    mod="${pair%%:*}"; label="${pair#*:}"
    if "$PY" -c "import $mod" >/dev/null 2>&1; then
        res "$label" "PASS" "$mod"
    else
        res "$label" "FAIL" "$mod"
    fi
done

entries="lerobot-find-port lerobot-setup-motors lerobot-calibrate lerobot-teleoperate lerobot-record lerobot-replay lerobot-train lerobot-find-cameras"
missing=""
for e in $entries; do
    [ -x "${ENV_PREFIX}/bin/$e" ] || missing="$missing $e"
done
if [ -z "$missing" ]; then
    res "命令行入口" "PASS" "8 个都在"
else
    res "命令行入口" "WARN" "缺:$missing"
fi

if "$PY" -c 'import lerobot.scripts.lerobot_find_port' >/dev/null 2>&1; then
    res "find-port 可加载" "PASS" "入口模块与依赖链正常"
else
    res "find-port 可加载" "FAIL" "入口模块导入失败"
fi

ff="${ENV_PREFIX}/bin/ffmpeg"
if [ -x "$ff" ]; then
    res "ffmpeg 位置" "PASS" "$ff"
    # 注意：不能写成 `ffmpeg -encoders | grep -q ...`。
    # 开了 pipefail 时 grep -q 提前退出会让 ffmpeg 收到 SIGPIPE 返回 141，
    # 整个管道判为失败，于是明明有编码器也报 WARN。先取到变量再用 case 匹配。
    encs="$("$ff" -hide_banner -encoders 2>/dev/null || true)"
    case "$encs" in
        *libx264*)
            res "ffmpeg 编码器" "PASS" "有 libx264"
            ;;
        *libsvtav1*)
            # conda-forge 的 ffmpeg 不带 libx264（GPL 组件），
            # 官方文档也说明默认用 libsvtav1，这属于正常情况
            res "ffmpeg 编码器" "PASS" "无 libx264(GPL)，有 libsvtav1(AV1)"
            ;;
        *)
            res "ffmpeg 编码器" "WARN" "既没有 libx264 也没有 libsvtav1，录制可能失败"
            ;;
    esac
else
    res "ffmpeg 位置" "FAIL" "环境里没有 ffmpeg"
    res "ffmpeg 编码器" "WARN" "跳过"
fi

torchinfo="$("$PY" -c 'import torch;print(torch.__version__, torch.cuda.is_available())' 2>/dev/null)"
if [ -n "$torchinfo" ]; then
    tv="${torchinfo% *}"; cu="${torchinfo#* }"
    if [ "$cu" = "True" ]; then
        gpu="$("$PY" -c 'import torch;print(torch.cuda.get_device_name(0))' 2>/dev/null)"
        res "PyTorch / CUDA" "PASS" "torch $tv  GPU: $gpu"
    else
        res "PyTorch / CUDA" "WARN" "torch $tv  CUDA 不可用（只能 CPU）"
    fi
else
    res "PyTorch / CUDA" "FAIL" "import torch 失败"
fi

hf="${HF_ENDPOINT:-$(grep -a '^export HF_ENDPOINT' "$HOME/.bashrc" 2>/dev/null | tail -1 | cut -d= -f2)}"
if command -v curl >/dev/null 2>&1; then
    code=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 https://hf-mirror.com/ 2>/dev/null || echo 000)
elif command -v wget >/dev/null 2>&1; then
    wget -q --spider --timeout=20 https://hf-mirror.com/ >/dev/null 2>&1 && code=200 || code=000
else
    code=skipped
fi
case "$code" in
    2*|3*|4*) res "HuggingFace 源" "PASS" "hf-mirror.com 可达 (HTTP $code)${hf:+，HF_ENDPOINT=$hf}" ;;
    skipped)  res "HuggingFace 源" "WARN" "没有 curl/wget，跳过" ;;
    *)        res "HuggingFace 源" "FAIL" "hf-mirror.com 不通 (HTTP $code)" ;;
esac

# ---------------------------------------------------------------- 硬件组
if [ "$WITH_HW" -eq 1 ]; then
    if "$PY" -c 'import serial.tools.list_ports as l;print(len(list(l.comports())))' >/dev/null 2>&1; then
        # 只把 ttyACM / ttyUSB 当作"机械臂可能的口"：
        # 笔记本和虚拟机上常有一堆 /dev/ttyS* 传统串口，全列出来只会干扰判断
        usbports=$("$PY" -c 'import serial.tools.list_ports as l
for p in l.comports():
    d = p.device
    if d.startswith("/dev/ttyACM") or d.startswith("/dev/ttyUSB"):
        print("%s  %s" % (d, p.description))' 2>/dev/null)
        total=$("$PY" -c 'import serial.tools.list_ports as l;print(len(list(l.comports())))' 2>/dev/null)
        if [ -z "$usbports" ]; then
            res "串口" "WARN" "没有 USB 串口（共 $total 个系统串口）——机械臂没插？"
        else
            res "串口" "PASS" "$(printf '%s\n' "$usbports" | wc -l) 个 USB 串口"
            printf '%s\n' "$usbports" | sed 's/^/         /'
            printf '  %s        提示：非 root 用户若打不开串口，把账号加进 dialout 组：sudo usermod -aG dialout $USER%s\n' "$C_D" "$C_0"
        fi
    else
        res "串口" "WARN" "pyserial 不可用"
    fi

    cal="${HOME}/.cache/huggingface/lerobot/calibration"
    if [ -d "$cal" ]; then
        cnt=$(find "$cal" -name '*.json' 2>/dev/null | wc -l)
        if [ "$cnt" -gt 0 ]; then
            res "标定文件" "PASS" "$cnt 个"
            find "$cal" -name '*.json' 2>/dev/null | sed "s/^/         /"
        else
            res "标定文件" "WARN" "目录在但没有 json"
        fi
    else
        res "标定文件" "WARN" "还没标定过（lerobot-calibrate）"
    fi

    camout=$(timeout 25 "$PY" -c 'import os
os.environ["OPENCV_LOG_LEVEL"]="SILENT"
import cv2
found=[]
for i in range(3):
    cap=cv2.VideoCapture(i, cv2.CAP_V4L2)
    if cap.isOpened():
        ok,_=cap.read()
        if ok:
            found.append("%d:%dx%d"%(i,int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))))
    cap.release()
print("RESULT:"+(";".join(found) if found else "none"))' 2>/dev/null)
    rc=$?
    cam="${camout#*RESULT:}"
    if [ $rc -eq 124 ]; then
        res "相机" "WARN" "探测超时（25 秒）"
    elif [ "$cam" = "none" ] || [ -z "$cam" ]; then
        res "相机" "WARN" "没检测到可用相机"
    else
        res "相机" "PASS" "$cam"
    fi
fi

# ---------------------------------------------------------------- 汇总
echo
printf -- '------------------------------------------------------------------\n'
printf '  通过 %d   警告 %d   失败 %d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '  %s环境还不能用，先修 [FAIL] 项。%s\n' "$C_R" "$C_0"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    printf '  %s核心功能已就绪，[WARN] 项按需处理。%s\n' "$C_Y" "$C_0"
else
    printf '  %s全部通过。%s\n' "$C_G" "$C_0"
fi
echo
exit 0
