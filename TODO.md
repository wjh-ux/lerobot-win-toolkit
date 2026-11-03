# TODO

## 1. 真机验证（唯一实质空缺）

接上 SO-101 机械臂与摄像头后，按 [docs/hardware-verification.md](docs/hardware-verification.md)
走一遍 8 个步骤，填写末尾那张 11 行结果表。

跑通后要做的三件事：

- [ ] 删掉 README「已知限制」里的前两条（机械臂三步、双摄配置）
- [ ] 把实测控制频率补进文档（无摄像头 / 加摄像头 两档）
- [ ] 如果遇到新问题，补进「我遇到的其它问题」和 README 的踩坑表

这是目前唯一无法靠读代码验证的部分，没有硬件就无法推进。

## 2. Linux 安装脚本

| 目标 | 状态 |
|---|---|
| Ubuntu / Debian | ✅ `install-lerobot.sh` + `test-lerobot.sh`，已在 **Ubuntu 22.04.5 / x86_64** 实机跑通：lerobot 0.6.1、6 个关键模块、18 个命令入口、ffmpeg 全部就位 |
| OpenWrt | ❌ 基本不可行，见下文 |

### 实测记录（Ubuntu 22.04.5，4 核 / 3.8 GB）

```
安装结果：lerobot 0.6.1，torch 2.11.0+cu130，ffmpeg 8.1.2
自检结果：15 PASS / 4 WARN / 0 FAIL（WARN 全是无 GPU、无机械臂、无摄像头）
安装体积：6.9 GB
```

**体积问题**：Linux 上 PyPI 的 torch 轮子自带整套 CUDA 库（`nvidia-*`、`cuda-toolkit-13.0.2`），
在没有 GPU 的机器上白占约 4 GB。想瘦身可以先用 CPU 版 torch：

```bash
~/miniforge3/envs/lerobot/bin/python -m pip install torch torchvision \
    --index-url https://download.pytorch.org/whl/cpu
```

已提供 `--cpu` 参数：从上海交大镜像（`mirror.sjtu.edu.cn/pytorch-wheels/cpu`，官方源兜底）
装 CPU 版 torch，**必须钉版本**（`torch==2.11.0+cpu` 这种）——不钉的话会装到
torch 2.15，而 lerobot 要求 `<2.12`，装 lerobot 时又会被判不满足、把 CUDA 版拉回来。

**ffmpeg 编码器**：conda-forge 的 ffmpeg **不带 libx264**（GPL 组件），实测
`Unknown encoder 'libx264'`。但它带 `libsvtav1`（AV1）、`libopenh264`、`mpeg4`，
而官方文档本身也说明默认用 libsvtav1，所以录制不受影响。

### 真机测试中发现并修掉的 5 个 bug

| # | 问题 | 后果 |
|---|---|---|
| 1 | 依赖 `curl`，但 Ubuntu 22.04 默认没有 | 所有镜像"探测不通"，直接中止 → 改成 curl→wget→python3 三级回退 |
| 2 | `set -e` 下 `INDEX_HTML=$(...)` 取页失败会退出整个脚本 | 卡在"找 sdist"且无任何报错 |
| 3 | sdist 的 `href` 正则要求 `.tar.gz` 后紧跟引号，实际后面是 `#sha256=` | 一个都匹配不到 |
| 4 | `sort -V` 排的是完整路径，路径哈希不同导致装错版本 | **装成了 lerobot 0.4.1** |
| 5 | `set -o pipefail` + `grep -q` 提前退出（SIGPIPE 141） | ffmpeg 明明有编码器却报 WARN |

### OpenWrt 为什么不可行

LeRobot 的硬依赖是 Python ≥3.12 + PyTorch。OpenWrt 环境下：

- **musl libc**：PyTorch 的 Linux 轮子是 `manylinux`（glibc），在 musl 上 `import torch` 直接失败
- **没有可用的预编译包**：OpenWrt 的 opkg 源里没有 torch，pip 也装不到匹配的轮子
- **存储与内存**：典型路由器 16–128 MB flash，torch 光解压就 1 GB+
- **交叉编译 torch**：理论可行，实际在一个路由器上编 PyTorch 不现实

如果确实需要「路由器参与」，可选的方向是：

1. 路由器只做**网络层**（流量代理、镜像缓存），计算仍在 PC / Jetson 上
2. 换成 **Debian/Ubuntu 的 ARM 单板**（树莓派、Jetson）当边缘节点，脚本可以直接复用
3. 如果只是想**远程控制串口舵机**，那属于另一个更轻的项目，不该套 LeRobot

## 3. 待确认

- [ ] v1.2.0 之后是否需要把 Linux 脚本并入同一个仓库（现在只在 Windows 工具里）
- [ ] 是否需要为 Windows 也补一份「卸载 / 清空环境」脚本

## 4. GPU 驱动管理（已做，未在真卡上验证）

`lerobot-menu.sh` 的 `[g]` 面板支持：检测显卡、装驱动（闭源 / 开源内核模块）、卸载驱动、
切换 PyTorch CPU/CUDA 版。

- [x] 从 `lspci` 型号推断架构（Pascal/Volta/Turing/Ampere/Ada/Hopper/Blackwell）
- [x] 按架构判断开源模块可用性（Turing 起支持）
- [x] 各架构的建议最低驱动版本
- [x] 卸载：`apt purge '^nvidia-.*' '^libnvidia-.*'` + `autoremove`
- [ ] **未在真实 NVIDIA 显卡上跑过** —— 这台 VM 没有 GPU，只验证了检测分类和命令拼装

真机测试时重点确认：

- [ ] `nvidia-driver-XXX` 装完重启后 `nvidia-smi` 有输出
- [ ] 开源模块 `-open` 在 30/40 系上能正常加载（Secure Boot 关掉的前提下）
- [ ] V100 / GTX 10 系选开源时被正确纠正为闭源
- [ ] 卸载后能正常回退到 nouveau，桌面不黑屏