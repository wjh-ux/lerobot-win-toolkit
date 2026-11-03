# LeRobot Windows 一键安装工具

把 [LeRobot](https://github.com/huggingface/lerobot) 在 Windows 上从"一堆命令"变成"敲个数字"。

专治国内网络环境下的几个老问题：GitHub 连不上、清华 conda 镜像的索引太大导致超时、
pip 装到一半失败、装完了不知道该敲什么命令。

已在 **Windows Server 2022（无 winget、无 git、无 GPU）** 上从零跑通全流程。

> English: [README.en.md](README.en.md)

---

## 最简用法：双击 `lerobot.bat`

不用记 `powershell -ExecutionPolicy Bypass -File ...` 这一串，也不用开 PowerShell。

1. 把 4 个文件放进同一个文件夹
2. **双击 `lerobot.bat`**
3. 出菜单，敲数字

也可以在 CMD 里带参数直接跑：

```bat
lerobot.bat            打开菜单
lerobot.bat 4          直接标定（等价于菜单里按 4）
lerobot.bat install    安装环境（等价于 0）
lerobot.bat check      软件自检（等价于 1）
lerobot.bat hw         硬件检查（等价于 w）
```

> `lerobot.bat` 只是把 CMD 转接到 PowerShell，参数原样透传，并且只在**双击**时
> 结束时停住窗口（在 CMD 里调用会自动退出，不会卡住）。

## 关于管理员权限

**全程不需要管理员权限。** 不是"尽量不用"，而是脚本里根本没有需要提权的操作：

| 可能被误认为要提权的地方 | 实际做法 |
|---|---|
| 装 conda | `InstallationType=JustMe`，装到 `%USERPROFILE%`，不写 `Program Files` |
| 建 conda 环境、装包 | 都在用户目录下 |
| 设 `HF_ENDPOINT` | `SetEnvironmentVariable(..., 'User')`，只写当前用户 |
| 改执行策略 | 不改。只在命令行传 `-ExecutionPolicy Bypass`，不碰系统设置 |
| 注册表 / 服务 / 防火墙 | 完全不涉及 |

实测环境就是一个**未提权**的会话（`IsInRole(Administrator)` = `False`），
Miniconda 静默安装、`conda create`、`pip install torch`、写用户环境变量全部成功。

### 那什么情况会"跑不起来"

下面三种都不是权限问题，但表现很像：

**1. 组策略锁死了执行策略（真正的墙）**

命令行传的 `-ExecutionPolicy Bypass` 会覆盖 `CurrentUser` / `LocalMachine` 级别，
但**覆盖不了** GPO 下发的 `MachinePolicy` / `UserPolicy`。自查：

```powershell
Get-ExecutionPolicy -List
```

如果 `MachinePolicy` 不是 `Undefined`，那就得找 IT。这种情况普通用户无解，
也不是本工具的锅。

**2. 下载的 zip 带有"Internet 标记"**

从网页下载的 zip 解压后，里面的文件会被标记为不受信任，`RemoteSigned` 策略下
PowerShell 会拒绝执行。`lerobot.bat` 会在启动前自动对这些 `.ps1` 执行 `Unblock-File`，
正常情况下你碰不到这个问题。万一还不行，手动解一下：

```powershell
Get-ChildItem .\*.ps1 | Unblock-File
```

**3. SmartScreen 提示"Windows 已保护你的电脑"**

双击下载来的 `.bat` 可能出现这个提示。点 **更多信息 → 仍要运行** 即可，
这不涉及管理员权限，只是 Windows 对陌生可执行文件的提醒。

## 文档

- **[LeRobot 上手笔记](docs/lerobot-notes.md)** —— 从环境搭建到项目架构的原理讲解。
  回答的是脚本背后的"为什么"：Anaconda 与 Miniconda 到底差什么、Python 模块与包的由来、
  `pip install -e` 为什么能让改代码立刻生效、`pyproject.toml` 里每一节是什么意思、
  LeRobot 的 `src/lerobot/` 是怎么组织的、为什么 extras 要把 feetech 单独拆出来。

  卡在某个报错上想弄明白原因时，翻这篇；只想装好跑起来，用下面的菜单就行。

- **[真机验证清单](docs/hardware-verification.md)** —— 接上机械臂后按这个走一遍，
  能验证本工具尚未在硬件上确认的部分（标定、双摄配置、控制频率）。

## 四个文件

### Windows

| 文件 | 作用 | 大小 |
|---|---|---|
| `lerobot.bat` | **双击入口**。CMD 转接 PowerShell，参数透传 | 2 KB |
| `lerobot-menu.ps1` | **真正的入口**。交互式菜单，敲数字或字母 | 27 KB |
| `install-lerobot.ps1` | 安装环境，9 个步骤带进度条 | 45 KB |
| `test-lerobot.ps1` | 自检，软件 8 项 + 硬件 3 项 | 19 KB |

### Linux（Ubuntu / Debian）

| 文件 | 作用 |
|---|---|
| `lerobot-menu.sh` | **工具箱面板**。敲数字或字母，与 Windows 版菜单对应 |
| `install-lerobot.sh` | 安装环境，镜像降级 + 进度显示 |
| `test-lerobot.sh` | 自检，软件组 + 硬件组（`--hw`） |

```bash
chmod +x lerobot-menu.sh install-lerobot.sh test-lerobot.sh
./lerobot-menu.sh                   # 打开面板
./install-lerobot.sh --dry-run      # 或直接用安装脚本
./test-lerobot.sh                   # 装完自检
```

面板长这样：

```
   环境
    [0] 安装 / 修复环境
    [1] 软件环境自检
    [w] 硬件检查（串口/相机/标定）
    [g] GPU 与 NVIDIA 驱动   ← 装驱动、切换 CPU/CUDA

   机械臂准备（按顺序做一次）
    [2] 查找串口    [3] 设置电机 ID    [4] 标定机械臂

   日常使用
    [5] 遥操作    [6] 录制    [7] 训练    [8] 推理    [9] 回放

   其他
    [c] 相机检测   [i] 环境详情   [m] HF 镜像   [h] 命令速查   [q] 退出
```

也可以直达：`./lerobot-menu.sh g`（GPU 面板）、`./lerobot-menu.sh 4`（标定）。
加 `--dry-run` 时所有安装类操作只打印命令。

### GPU 驱动管理（`[g]`）

支持 10 / 20 / 30 / 40 / 50 系、V100、H100 / H200、RTX PRO 6000 等，
闭源驱动和开源内核模块两种都能装，也能卸载。

```
    [1] 检测显卡 / 驱动状态
    [2] 安装驱动（闭源 / 开源可选）
    [3] 卸载驱动
    [4] PyTorch 切 CPU / CUDA 版
```

**从型号自动判断架构**，并据此决定开源模块能不能用：

| 架构 | 代表型号 | 开源内核模块 |
|---|---|---|
| Pascal | GTX 10 系、P40、P100 | ❌ 只能用闭源 |
| Volta | V100 | ❌ 只能用闭源 |
| Turing | RTX 20 系、T4 | ✅ |
| Ampere | RTX 30 系、A100、A10 | ✅ |
| Ada | RTX 40 系、L40、L4 | ✅ |
| Hopper | H100、H200 | ✅ |
| Blackwell | RTX 50 系、B100/B200、RTX PRO 6000 | ✅ |

开源模块从 **Turing（20 系）** 才开始支持，10 系和 V100 选开源会被自动纠正为闭源。

安装前会把「装哪个包、什么类型、要注意什么」列清楚再让你确认；卸载用
`apt purge '^nvidia-.*' '^libnvidia-.*'` + `autoremove`，同样要确认。

> 驱动安装需要 sudo、会触发 DKMS 重新编译内核模块、装完要重启。
> 有桌面环境时**重启前别注销**，否则可能黑屏。

**关于 `--cpu`**：PyPI 的 Linux torch 轮子自带整套 CUDA 库（`nvidia-*`、`cuda-toolkit`），
在没有 NVIDIA GPU 的机器上白占约 4.5 GB。加 `--cpu` 会先从国内镜像
（上海交大 `mirror.sjtu.edu.cn/pytorch-wheels/cpu`，官方 `download.pytorch.org/whl/cpu` 兜底）
装 `torch+torchvision` 的 CPU 轮子，再装 lerobot。

### GPU 自动检测

**默认不用加参数**，脚本会自己判断：

1. **检测**：`nvidia-smi` → `/proc/driver/nvidia/version` → `lspci`，三重判断
2. **推荐**：查到 NVIDIA 卡就提示机型、驱动版本，并推荐 CUDA 版，问你 `[Y/n]`
3. **核查**：装完检查 `torch.cuda.is_available()`，不完整会明确告诉你是哪种情况

```
  [ OK ]  检测到 GPU: NVIDIA GeForce RTX 4090（驱动 550.54.14）
  检测到 NVIDIA GPU，推荐安装 CUDA 版 PyTorch
    CUDA 版体积大（约 +4.5 GB），但能用显卡训练；
    CPU 版只有 2.4 GB，装得快，适合只做推理或没显卡驱动的情况。
  安装 CUDA 版？[Y/n]
```

没显卡就**自动装 CPU 版**，不问（省 4.5 GB）。

| 参数 | 行为 |
|---|---|
| （默认） | 自动检测，有卡会问，没卡直接 CPU |
| `--gpu` | 强制 CUDA 版；没卡会警告"装了也用不上" |
| `--cpu` | 强制 CPU 版 |
| `--yes` | 非交互：不问，有卡按 GPU、没卡按 CPU |

装完的核查会区分三种结果：

- **GPU 可用** → 打印卡名和显存，绿色通过
- **装了 CUDA 版但 `cuda.is_available()` 为假** → 列出常见原因（驱动没装/版本太老、
  虚拟机没开 GPU 直通、容器没挂 `--gpus all`），并计入失败数
- **CPU 版** → 正常通过；如果机器上其实有卡，会提示"想用显卡就加 `--gpu` 重装"

与 Windows 版的差异：

- **系统依赖走 apt**（`cmake build-essential python3-dev pkg-config git curl` + 一组 `libav*-dev`），
  需要有 sudo 权限。脚本只在 `sudo -n true` 通过时才自动装，否则会打印手动命令让你执行 —— 
  因为它经常跑在非交互环境里，不能卡在密码提示上。
- **HTTP 工具三级回退**：`curl` → `wget` → `python3`。Ubuntu 22.04 默认没有 curl，
  少了这层回退会因为"探测不到镜像"直接失败。
- **`HF_ENDPOINT` 写进 `~/.bashrc` / `~/.profile`**，而不是改系统配置。


四个放在同一目录即可。

## 快速开始

**方式一（推荐，零门槛）**：双击 `lerobot.bat`，按菜单走。

**方式二**：在 PowerShell 或 CMD 里：

```bat
cd /d 你放脚本的目录
lerobot.bat
```

**方式三**：跳过包装，直接调 PowerShell（等价）：

```powershell
powershell -ExecutionPolicy Bypass -File .\lerobot-menu.ps1
```

看到菜单后：

```
   环境
    [0] 安装 / 修复环境       install-lerobot.ps1
    [1] 软件环境自检          test-lerobot.ps1
    [w] 硬件检查（串口/相机/标定）

   机械臂准备（按顺序做一次）
    [2] 查找串口              lerobot-find-port
    [3] 设置电机 ID           lerobot-setup-motors
    [4] 标定机械臂            lerobot-calibrate

   日常使用
    [5] 遥操作                lerobot-teleoperate
    [6] 录制数据集            lerobot-record
    [7] 训练策略              lerobot-train
    [8] 推理 / 跑策略         lerobot-rollout
    [9] 回放数据集            lerobot-replay

   其他
    [c] 相机检测              lerobot-find-cameras
    [v] 数据集可视化          lerobot-dataset-viz
    [i] 环境详情 / 标定文件
    [m] 设置 HuggingFace 镜像
    [h] 命令速查              [q] 退出
```

新机器按 **`0` → `1` → `2` → `3` → `4`** 的顺序走一遍就行。

也可以跳过菜单直达：

```powershell
.\lerobot-menu.ps1 4      # 直接进标定
.\lerobot-menu.ps1 i      # 环境详情
```

## 参数不用记

菜单里所有参数都是**选**出来的，不是打出来的：

- **串口**：自动列出 `COM3 / COM4` 和驱动描述，输编号即可
- **标定 id**：自动列出现有标定文件里的名字，避免打错导致找不到标定
- **机型**：从 SO-101/100 主从臂里选
- **策略**：act / diffusion / smolvla / pi0 / pi05 选一个

底层拼出来的命令和官方文档一致，例如：

```
lerobot-calibrate --robot.type=so101_follower --robot.port=COM3 --robot.id=my_follower_arm
```

## 安装流程（9 步，带进度条）

```
  第 1/9 步  [██░░░░░░░░░░░░░░░░░░]  11%  前置检查
  第 2/9 步  [████░░░░░░░░░░░░░░░░]  22%  conda 环境 [lerobot]
  第 3/9 步  [██████░░░░░░░░░░░░░░]  33%  探测 pip 镜像（国内优先，不通降级）
  第 4/9 步  [████████░░░░░░░░░░░░]  44%  安装 ffmpeg（TorchCodec 解码视频用）
  第 5/9 步  [███████████░░░░░░░░░]  55%  安装 git（走 conda-forge）
  第 6/9 步  [█████████████░░░░░░░]  66%  获取 lerobot 源码
  第 7/9 步  [███████████████░░░░░]  77%  编辑模式安装 lerobot
  第 8/9 步  [█████████████████░░░]  88%  Hugging Face 下载源
  第 9/9 步  [████████████████████] 100%  结果
```

步骤总数会随参数变化（`-SkipFfmpeg` 少一步、`-WithGit` 多一步），不会出现"第 4/9 步之后就结束"。

## 镜像降级策略

每个环节都是**先探测、再按顺序降级**，不是写死一个源：

| 环节 | 顺序（通了就停） |
|---|---|
| pip | 清华 → 阿里云 → 腾讯云 → 中科大 → 华为云 → 官方 PyPI |
| conda | 清华 pkgs/main → 清华 conda-forge → 默认源 |
| git clone | gh-proxy.com → ghfast.top → ghproxy.net → 直连 GitHub |
| 源码兜底 | 以上全失败 → 从 pip 镜像下载 sdist 解压（`-FromPypi`） |
| HF 模型 | hf-mirror.com（写入 `HF_ENDPOINT`） |

### 一个反直觉的实测结论

清华 conda-forge 的 `repodata.json` 未压缩有 **279 MB + 185 MB**，
在慢链路上会超时，表现出来就是"国内镜像创建环境失败"。

```
conda-forge   279 MB (win-64) + 185 MB (noarch)   zst 压缩后 65 MB
pkgs/main     112 MB (win-64)                     zst 压缩后 12 MB
```

而 `pkgs/main` 里同样有 Python 3.12。所以**建环境先走 12 MB 的小仓库**，
只有装 ffmpeg / git 这种 conda-forge 才有的包时才去大仓库。

## 自检分两组

`[1]` 只查软件（装完就该全 PASS）：

```
[PASS] conda 环境 / Python 版本 / pip 可用 / lerobot 已安装
[PASS] 从臂 / 主臂 / 飞特舵机 SDK / OpenCV / 数据集 / 策略
[PASS] 命令行入口 8 个 / 入口模块可加载 / ffmpeg + 编码器
[WARN] PyTorch / CUDA          ← 没有 NVIDIA 显卡时是 WARN，正常
[PASS] Hugging Face 源
```

`[w]` 才查硬件（串口 / 标定文件 / 相机）。相机探测有 **25 秒硬超时**，
没插摄像头不会被卡住。

**为什么要分开**：没接机械臂的机器上，串口、标定、相机必然是 WARN，
混在环境自检里会让人误以为"环境没装好"。

## 常用参数

```powershell
# 只看计划，不装任何东西
.\install-lerobot.ps1 -DryRun

# 标准安装（能连 GitHub）
.\install-lerobot.ps1 -AutoInstallPrereqs -WithGit

# GitHub 连不上时（公司网络 / 国内直连）
.\install-lerobot.ps1 -FromPypi -AutoInstallPrereqs -WithGit

# 指定版本
.\install-lerobot.ps1 -FromPypi -PypiVersion 0.6.1
```

`-FromPypi` 走的是 PyPI 发布版，**不是 GitHub main 分支**（两者 extras 数量不同，
脚本会在名字对不上时明确提示，不会静默跳过）。

## 环境要求

- Windows 10 / 11 / Server 2019+，PowerShell 5.1 或更高
- 磁盘剩余 ≥ 15 GB（torch + rerun-sdk 比较大）
- 可选：NVIDIA 显卡 + 驱动（训练用；没有也能跑 CPU，只是慢）

conda 和 git 都不用预装，加 `-AutoInstallPrereqs` 会走清华镜像自动装。

## 已知限制

诚实说明，这些没有在真硬件上验证过：

- **机械臂三步**（`find-port` / `setup-motors` / `calibrate`）需要人手插线、摆关节，
  命令拼装逻辑测过，但没有接真实舵机跑过。
- **`lerobot-record` 的双摄配置**：`--robot.cameras="{...}"` 的格式按官方文档拼的，
  没在双摄像头机器上验证。第一次录制建议先用单摄像头。
- **`lerobot-rollout`** 是 0.6.x 才有的命令，0.5.x 及更早没有；脚本会检测并给出提示。

**想帮忙关掉前两条？** 按 [真机验证清单](docs/hardware-verification.md) 走一遍，
里面有每一步该看什么、该记录什么，以及一张可直接填的结果表。跑完把结果提 issue 或 PR，
就能把上面两条删掉，并把实测控制频率补进文档。

## 踩过的坑（如果你也想自己写类似脚本）

这些都是实测踩出来的，写在这里省得别人再踩一遍：

| 问题 | 现象 | 原因 |
|---|---|---|
| 函数返回值被污染 | 退出码变成一整段英文 | `& $exe` 的输出混进了函数返回值，要 `\| Out-Host` |
| 子进程输出消失 | 菜单点了没反应 | `$null = Invoke-Item` 把管道输出全吞了 |
| 引号被吞 | `print("%d" % x)` → SyntaxError | PowerShell 5.1 向外部程序传参会剥掉双引号，改用临时 .py 文件 |
| curl 404 当成功 | 把 HTML 错误页当安装包执行 | curl 默认不因 HTTP 错误返回非零，要加 `-f` |
| conda 装完找不到 | 误判安装失败 | NSIS 静默安装会提前返回，要轮询等文件锁释放 |
| 环境"借"用户级包 | 换账户就 `ModuleNotFoundError` | 系统里已有同版本 Python 时会启用 user site-packages，要设 `PYTHONNOUSERSITE=1` |
| 进度条变问号 | `[██???]` | GBK 控制台撑不住 `░`，要逐字符探测编码 |
| `(if …)` 语法错误 | `无法将"if"项识别为 cmdlet` | PS 5.1 不支持把 if 当括号表达式（那是 PS7） |
| 相机探测卡死 | 看起来死机 | 没摄像头时 OpenCV 的 DSHOW 枚举会长时间阻塞，要加硬超时 |

脚本文件请存成 **UTF-8 带 BOM**，否则 PS 5.1 会按 GBK 读中文，引号错位直接读废。

## 相关链接

- LeRobot 官方仓库：<https://github.com/huggingface/lerobot>
- 安装文档：<https://huggingface.co/docs/lerobot/installation>
- SO-101 教程：<https://huggingface.co/docs/lerobot/so101>
- 硬件 BOM / 打印件：<https://github.com/TheRobotStudio/SO-ARM100>

## License

MIT，见 [LICENSE](LICENSE)。
