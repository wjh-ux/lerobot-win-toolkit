# LeRobot 上手笔记：从环境搭建到项目架构

> **这是一份原理讲解，不是操作手册。**
> 想直接装好跑起来，用仓库根目录的 [`lerobot-menu.ps1`](../lerobot-menu.ps1)：
> `powershell -ExecutionPolicy Bypass -File .\lerobot-menu.ps1`，然后按 `[0]` 安装、`[1]` 自检。
>
> 本文回答的是脚本背后的"为什么"——为什么要有 conda、`pip install -e` 到底做了什么、
> `pyproject.toml` 里每一节是什么意思、LeRobot 的代码是怎么组织的。
> 卡在某个报错上想弄明白原因时，翻这里。

> 依据：官方 [LeRobot Installation](https://huggingface.co/docs/lerobot/installation)（main 分支源码）、[SO-101 教程](https://huggingface.co/docs/lerobot/so101)、[Cheat sheet](https://huggingface.co/docs/lerobot/cheat-sheet)，以及电子羊公社 [escommune.readthedocs.io](https://escommune.readthedocs.io/) 教程。
> 公社文档成文于 `lerobot 0.5.0`，官方 main 已到 `v0.6.1`，两者有少量命令差异，见第 10 节。

---

## 0. 先看全局：这九件事的依赖关系

不是九个并列的知识点，是一条流水线。前面不懂，后面必卡。

```
Anaconda/Miniconda  ──> 提供一个"干净的、可丢弃的" Python 环境
        │
        ├── PyCharm   ──>  在这个环境里读代码、跑脚本
        ├── Git       ──>  把别人的项目完整拿下来（可改、可回滚、可 pull）
        │
        └── 模块/包/pip/pyproject.toml/编辑模式安装
                    ──>  看懂 LeRobot 为什么是 pip install -e ".[feetech]"
                                │
                                └──> 安装 LeRobot ──> 找端口 / 设 ID / 标定 / 遥操作
```

**一句话概括后面七节的关系**：`.py` 文件是模块，目录加 `__init__.py` 是包，`pip` 是从 PyPI 装包的工具，`pyproject.toml` 是包的"身份证 + 依赖清单 + 命令入口"，`pip install -e .` 是"让这个包边改边生效"的安装方式，LeRobot 就是这么装的。

---

## 1. Anaconda 与 Miniconda

### 1.1 它们到底是什么

**conda 首先是个环境管理器，其次才是个包管理器。** 这句话是理解全部后续操作的关键。

- 普通 `pip` 只能装 Python 包（PyPI 上的纯 Python 或带 wheel 的包）。
- `conda` 能装**任意二进制**：`ffmpeg`、CUDA 运行时、`cmake`、编译器。LeRobot 在 Windows 上装 `ffmpeg` 就必须用 conda —— 这是后面第 9 节的一个真实坑点。
- `conda` 能凭空造一个独立解释器（`python=3.12`），`pip` 做不到，`pip` 只能往"当前已有的解释器"里塞东西。

所以有 conda 之后，你的机器上可以同时存在 Python 3.10 做 A 项目、Python 3.12 做 LeRobot，互不干扰。

### 1.2 Anaconda 与 Miniconda 的区别

**功能上没有任何差异**，同一个 `conda` 命令、同一套 `conda create/activate`。区别只在预装内容：

| | Anaconda | Miniconda（及 Miniforge） |
|---|---|---|
| 图形界面 | 有（Anaconda Navigator） | 无，纯命令行 |
| 预装包 | 数百个（numpy/pandas/jupyter/…） | 几乎零预装 |
| 安装体积 | 约 4.4 GB | 约 480 MB |
| 默认软件源 | `repo.anaconda.com`（Anaconda 官方仓库） | `conda-forge`（社区仓库） |
| 典型场景 | Windows 桌面、笔记本、初学者 | Linux 服务器、Jetson、树莓派、Docker |

选型建议：
- **Windows 笔记本/台式机**：装 Anaconda，省事，图形界面能看环境列表。
- **Linux / Jetson / 树莓派**：装 Miniforge（官方 `installation.mdx` 明确推荐 miniforge，而不是 Miniconda）。
- **公司环境注意**：Anaconda 官方仓库对 200 人以上组织有商业授权要求，`conda-forge` 没有这个问题；介意的话直接用 Miniforge。

> 官方安装文档给的是 Miniforge，公社文档给的是"Windows 装 Anaconda、Linux 装 Miniforge"。两者不冲突，看你的机器决定。

### 1.3 必须背下来的五条命令

```bash
conda create -y -n lerobot python=3.12   # 造一个叫 lerobot 的环境，Python 3.12
conda activate lerobot                   # 进入（每次开新终端都要执行一次）
conda deactivate                         # 退出
conda env list                           # 看现在有哪些环境、当前在哪个
conda remove -n lerobot --all            # 删掉整个环境（删错了重来即可，成本很低）
```

**验证是否真的进去了**：命令行提示符前面出现 `(lerobot)`，并且

```bash
which python     # Linux/macOS
where.exe python # Windows PowerShell（注意是 where.exe，不是 where）
```

输出路径里应当含有 `envs\lerobot`。

> 关键心智模型：`conda activate` 干的事，说白了就是**改环境变量 PATH**，让 `python` 和 `pip` 指向 `envs/lerobot/` 下那一份。所以"我在 A 环境里 pip 装的包，B 环境里找不到"从来不是 bug。

---

## 2. PyCharm

### 2.1 版本选择

下载 [PyCharm Community](https://www.jetbrains.com/pycharm/) 即可，免费且够用。不要装 Professional（要钱），本教程用不到远程开发、数据库那些功能。

### 2.2 装完必须做的三件事

1. **打开项目时选 `lerobot` 这个 clone 下来的目录**，不要选它的父目录，否则索引会扫一大堆无关文件。
2. **配置解释器**：`File → Settings → Project → Python Interpreter → Add Interpreter → Conda Environment → Existing environment`，指向
   ```
   C:\Users\<你>\anaconda3\envs\lerobot\python.exe
   ```
   配错解释器是新手 90% 的"模块找不到"报错来源 —— 代码没错，是 PyCharm 在用另一个 Python 跑。
3. **确认 Terminal 里 conda 能激活**。PyCharm 底部 Terminal 打开后，提示符应带 `(lerobot)`。如果没有：

   ```powershell
   conda init powershell    # 执行一次，然后重启 PyCharm
   ```
   Windows 上更省事的做法是 `Settings → Tools → Terminal → Shell path` 改成 `cmd.exe`，然后在 cmd 里 `conda activate lerobot`（cmd 的 conda 初始化通常默认就配好了）。

### 2.3 PyCharm 里最有用的三个键

- `Ctrl + 左键点击`：跳到定义。读 LeRobot 源码全靠它，从 `--robot.type=so101_follower` 一层层点进去。
- `Ctrl + Shift + F`：全项目搜索。想知道 `setup_motors` 在哪实现，搜它。
- `Shift + F10` / 右上角绿色三角：运行当前脚本。但注意 LeRobot 的命令行脚本是带参数的，直接跑多半缺参数，老老实实用 Terminal。

---

## 3. Git

### 3.1 安装

[git-scm.com](https://git-scm.com/) 下载安装，一路默认即可（Windows 上默认会把 Git Bash 一起装上）。

### 3.2 装完必做的两行配置

```bash
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
```

不配这两行，以后 `git commit` 会报错。名字用英文/拼音，避免某些工具乱码。

### 3.3 够用的六条命令

```bash
git clone https://github.com/huggingface/lerobot.git   # 把仓库整个拿下来
cd lerobot
git status                    # 我改了哪些文件
git log --oneline -5          # 最近 5 次提交
git diff                      # 我具体改了什么
git pull                      # 拉取别人的最新改动（改动多时先 commit 或 stash）
git checkout .                # 丢弃所有本地修改，回到干净状态（危险，确认后再用）
```

### 3.4 为什么教程都让你 `git clone` 而不是"下载 ZIP"

三个理由，都会真实咬人：

1. **可回滚**。LeRobot 迭代很快，`git log` + `git checkout <commit>` 能退回任何一个能跑的版本。
2. **可更新**。`git pull` 一行拿到官方修复，ZIP 只能整包重下。
3. **可贡献**。公社文档的原话是希望更多人真的能改代码、参与开源。改代码的前提是你手里是一份 git 仓库，而不是一个快照。

> 给 China 网络的实用建议：`git clone` 慢或失败时，可以走代理
> ```bash
> git config --global http.proxy http://127.0.0.1:7897
> git config --global https.proxy http://127.0.0.1:7897
> ```
> 取消：`git config --global --unset http.proxy`（https 同理）。只在 clone 阶段需要，之后可以取消。

---

## 4. Python 模块与包的由来（一条演化线）

这一段把"模块 / 包 / pip / pyproject.toml / 编辑模式安装"串成一个故事，理解了故事，后面五个概念就不需要背了。

### 4.1 第一幕：从 REPL 到 `.py`

在控制台里敲 `a = 1`，关掉窗口，变量就没了。想让代码活下来，就得存进文件。**一个以 `.py` 结尾、能被 `import` 的文件，就叫 module（模块）**。

```python
# module_test.py
a = 1
b = 2

def minus(x: int, y: int) -> int:
    return x - y

print(f"hello, a+b = {a + b}")
```

### 4.2 第二幕：`import` 到底做了三件事

```python
>>> import module_test
hello, a+b = 3          # ← 注意：import 的瞬间就打印了
>>> module_test.minus(2, 1)
1
```

1. **找**：在 `sys.path` 列出的那些目录里，逐个找 `module_test.py`。
2. **执行**：找到就从头到尾执行一遍，并把里面的名字装进一个模块对象。
3. **缓存并绑定**：模块对象存进 `sys.modules`，然后在你当前的命名空间里绑上 `module_test` 这个名字。第二次 `import` 不会重复执行 —— 这就是为什么"改了模块，交互式环境里不生效，得重启"。

看 `sys.path` 是什么：

```bash
python -c "import sys; print(sys.path)"
```

第一条通常是当前脚本所在目录（或 `''`，表示当前工作目录），这也解释了那个经典困惑：**"我在 A 目录能 import，换到 B 目录就不行了"** —— 因为当前目录变了，`sys.path` 第一条就变了。

### 4.3 第三幕：文件一多，就撞名字了

模块多了有两个问题：散落在各处不好管理，以及两个 `utils.py` 会打架（`sys.modules` 里同一时间只能有一个叫 `utils` 的）。

解决办法：**用目录分层，并在目录里放一个 `__init__.py` 声明"我是一个包"**。

```
escommune_pkg/
├── __init__.py          ← 包的标志；包被 import 时执行
├── scripts/
│   └── esc_cli.py
├── sub_pkg1/
│   ├── __init__.py
│   ├── mod1.py
│   ├── mod2.py
│   └── mod3.py
└── sub_pkg2/
    ├── __init__.py
    ├── mod4.py
    └── mod5.py
```

于是名字从 `utils` 变成 `escommune_pkg.sub_pkg1.mod1.some_func`，全宇宙唯一。

`__init__.py` 里通常干两件事：定义包级变量、把子模块里的常用名字"提"到包这一层，让使用者少敲几层点（`from lerobot import ...` 就是这么变短变的）。

> 补充：Python 3.3 之后有"命名空间包"（没有 `__init__.py` 也能当包），setuptools 的 `find` 就依赖这个特性。但**写自己的项目时，老老实实放 `__init__.py`**，能省掉一堆诡异问题。

### 4.4 第四幕：想给别人用，就得能"安装"

现在你的包在自己电脑上能 import，因为它在 `sys.path` 里。发给同事就废了。

于是需要一套标准：**声明"我叫什么、什么版本、依赖谁、对外暴露哪些命令"，然后让工具把它放进 `site-packages`（`sys.path` 的默认成员之一）**。这个声明文件就是 `pyproject.toml`，这个工具就是 `pip`，这个"放"的动作就是 `pip install`。

第 5、6、7 节分别讲这三样。

---

## 5. pip：管理包

### 5.1 pip 与 conda 的分工

| | pip | conda |
|---|---|---|
| 装什么 | PyPI 上的 Python 包 | Python 包 **+ 二进制**（ffmpeg、CUDA、编译器） |
| 装到哪 | 当前解释器的 `site-packages` | 当前环境的 `site-packages` / `Library\bin` |
| 环境隔离 | 靠 venv/conda 提供 | 自带 |
| 能否换 Python 版本 | 不能 | 能 |

**实践原则**：先 `conda activate`，再 `pip install`。这样 pip 装进的是 conda 环境，不是系统 Python。

### 5.2 国内镜像源（必做，否则装 PyTorch 会等到天荒地老）

```bash
pip config set global.index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
```

其它可选：阿里 `https://mirrors.aliyun.com/pypi/simple/`、中科大 `https://pypi.mirrors.ustc.edu.cn/simple/`。

查看/删除：

```bash
pip config list
pip config unset global.index-url
```

> 注意：镜像源只加速 PyPI。装 `torch` 这类从 `download.pytorch.org` 拿的包、以及从 Hugging Face 下模型权重，镜像源管不着 —— 后者见 9.5 节的 `HF_ENDPOINT`。

### 5.3 日常六条

```bash
pip install <包名>                # 装
pip install <包名>==1.2.3         # 装指定版本
pip install -e .                  # 编辑模式安装当前目录的项目（第 7 节详讲）
pip list                          # 当前环境装了啥
pip show lerobot                  # 某个包的版本、位置、依赖
pip uninstall <包名>
pip freeze > requirements.txt     # 冻结当前环境（给别人复现用）
```

### 5.4 三条纪律

1. **不要在系统 Python 上 `pip install`**，更不要 `sudo pip install`。污染系统 Python 之后，Linux 上连包管理器都会挂。
2. **每个项目一个环境**。宁可 `conda create` 多花 30 秒，也不要事后解依赖地狱。
3. **装完记一句** `pip show <包>`，确认装进了你以为的那个环境。

---

## 6. `pyproject.toml` 逐段讲解

`pyproject.toml` 是 PEP 518/621 定下来的现代 Python 项目配置标准，用来取代过去的 `setup.py`（命令式脚本，能写任意 Python 代码，不可静态分析，构建工具无法提前知道要装什么）。

用 TOML 而不是 JSON/YAML 的原因很朴素：JSON 不支持注释、YAML 缩进易错、INI 表达不了嵌套。

下面是一个能跑的最小例子，逐段说：

```toml
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.build_meta"

[project]
name = "escommune_pkg"
version = "0.4.3"
license = { text = "Apache-2.0" }
description = "For lerobot tutorial"
readme = "README.rst"
requires-python = ">=3.10"
authors = [{ name = "alex" }]
dependencies = ["numpy"]

[project.optional-dependencies]
scipy = ["scipy"]

[project.urls]
homepage = "https://escommune.readthedocs.io/"

[tool.setuptools.packages.find]
where = ["src"]

[project.scripts]
esc-cli = "escommune_pkg.scripts.esc_cli:main"
```

### 6.1 `[build-system]` —— 谁来负责"打包"

`requires` 是**构建时需要**的工具（不是运行时依赖），`build-backend` 是真正干活的函数入口。setuptools 是事实标准；也有 hatchling、poetry-core、flit 等替代。

这一节的意义：`pip` 自己其实不懂怎么打包，它读到 `requires` 就先建一个临时环境装好 setuptools，再调用 `build_meta` 去构建。所以"要装包先装 setuptools"这句老话的出处就在这里。

### 6.2 `[project]` —— 包的身份证

- `name`：PyPI 上的名字，`pip install escommune_pkg` 用的就是它。
- `version`：版本号，`pip` 判断"要不要升级"的依据。
- `requires-python`：**不是提示，是硬约束**。写 `>=3.10`，用 3.9 的机器 `pip install` 会直接拒绝。
- `dependencies`：运行时依赖。`pip install escommune_pkg` 会连带把 numpy 装上。**这是"包"和"文件夹"最本质的区别** —— 包知道自己需要什么。

### 6.3 `[project.optional-dependencies]` —— extras，重点

```toml
[project.optional-dependencies]
scipy  = ["scipy"]
feetech = ["feetech-servo-sdk"]
training = ["dataset-pkg", "accelerate", "trackio"]
```

方括号里的 key（`scipy`、`feetech`、`training`）就是 **extra 名**。装法：

```bash
pip install escommune_pkg            # 只装 dependencies
pip install "escommune_pkg[scipy]"   # dependencies + scipy
pip install "escommune_pkg[feetech,training]"   # 多个 extra 用逗号
pip install "escommune_pkg[all]"     # 通常项目会有一个 all，把全部串起来
```

**LeRobot 把整个安装体系都建在这个机制上**，这是理解 `pip install -e ".[feetech]"` 的唯一钥匙：

| Extra | 加了什么 | 干什么用 |
|---|---|---|
| `dataset` | `datasets`, `av`, `torchcodec`, `jsonlines` | 读写数据集 |
| `hardware` | `pynput`, `pyserial`, `deepdiff` | 连真机 |
| `viz` | `rerun-sdk`, `foxglove-sdk` | 录制/评估时可视化 |
| `core_scripts` | `dataset` + `hardware` + `viz` | `lerobot-record` / `replay` / `calibrate` |
| `training` | `dataset` + `accelerate` + `trackio` | 训练策略 |
| `evaluation` | `av` | `lerobot-eval` |
| `feetech` | `feetech-servo-sdk` | SO-100 / SO-101 的舵机 |
| `dynamixel` | SDK | Koch v1.1 的舵机 |
| `all` | 全部 | 全功能 |

`lerobot 0.5.0` 起官方把默认依赖砍到最小（只剩 torch/torchvision/numpy/opencv/einops/draccus/huggingface-hub/gymnasium/safetensors），其余全部推进 extras。所以**光 `pip install -e .` 是跑不了标定和录制的** —— 这是公社文档特意加粗提示的那句话。

### 6.4 `[tool.setuptools.packages.find]` —— 告诉工具源码在哪

`where = ["src"]` 表示源码在 `src/` 下。这叫 **src-layout**：

```
项目根/
├── pyproject.toml
├── src/
│   └── escommune_pkg/
│       └── __init__.py
└── tests/
```

对比 flat-layout（包直接放根目录）。src-layout 多一层麻烦，但好处很实在：**没安装就 import 不到**。逼着你验证"安装是对的"，而不是"因为我在项目根目录所以能 import"。LeRobot 用的也是 src-layout（`src/lerobot/`）。

### 6.5 `[project.scripts]` —— 命令行脚本的来源

```toml
[project.scripts]
esc-cli = "escommune_pkg.scripts.esc_cli:main"
```

格式固定：`命令名 = "模块路径:函数名"`。含义是"**当有人执行 `esc-cli` 时，去 `escommune_pkg/scripts/esc_cli.py` 里调用 `main()`**"。

这一行的产物，就是你在终端里能直接敲 `lerobot-find-port` 的原因。第 7 节展开。

---

## 7. 编辑模式安装与命令行脚本

### 7.1 `pip install .` 与 `pip install -e .` 的区别

| | `pip install .` | `pip install -e .` |
|---|---|---|
| 动作 | 把源码**复制**到 `site-packages` | 在 `site-packages` 里放一个**指针**（`.pth` / finder），指回你的源码目录 |
| 改代码后 | 要重新安装才生效 | **立即生效**，重启进程即可 |
| 卸载 | 干净 | 干净（但源码目录还在，你自己删） |
| 适合 | 使用者 | **开发者**、要读源码/改 bug 的人 |

`-e` 是 `--editable` 的缩写。原理上，现代 setuptools 会在 `site-packages` 里写一个形如 `__editable__.escommune_pkg-0.4.3.pth` 的文件（内部是一个路径或 finder 配置），Python 启动时读 `.pth` 就把你的源码目录加进 `sys.path`。**所以它不是"安装了一个副本"，而是"让 Python 永远认得你那个目录"**。

公社文档强烈建议编辑模式装 LeRobot，理由给得很直白：

> 毕竟是开源项目，里面很多 bug，有时候自己发现了就可以改，例如 Windows 下的 OpenCV backend 选择问题。而且公社的目标也是让更多人能参与到类似项目的开发中去。

而 `pip install lerobot`（从 PyPI 装）拿到的是打包好的副本，改不了、看不到源码、也没法 `git pull`。

### 7.2 一条命令的诞生链路

以 `lerobot-setup-motors` 为例，完整链路是：

```
1. pyproject.toml 里写着
   [project.scripts]
   lerobot-setup-motors = "lerobot.scripts.lerobot_setup_motors:main"

2. pip install -e . 读这一节，在环境的 Scripts/bin 目录生成一个包装器：
   Windows: G:\...\envs\lerobot\Scripts\lerobot-setup-motors.exe
   Linux:   ~/miniforge3/envs/lerobot/bin/lerobot-setup-motors

3. 你敲 lerobot-setup-motors --robot.type=so101_follower ...
   → 包装器启动对应 Python → import lerobot.scripts.lerobot_setup_motors → 调 main()

4. main() 用 draccus 把命令行参数解析成一个 dataclass 配置对象
```

验证第 2 步：

```powershell
where.exe lerobot-setup-motors
# G:\ProgramFile\Anaconda2506\envs\lerobot\Scripts\lerobot-setup-motors.exe
```

```bash
which lerobot-setup-motors
ls ~/miniforge3/envs/lerobot/bin | grep lerobot
```

**如果 `where.exe` 找不到，就说明安装没生效或进了别的环境** —— 这比"命令报错"更能定位问题。

### 7.3 `".[core_scripts]"` 这个语法怎么读

```bash
pip install -e ".[core_scripts]"
```

拆开看：

- `-e`：编辑模式
- `.`：要安装的项目是**当前目录**
- `[core_scripts]`：同时装上 `optional-dependencies` 里名为 `core_scripts` 的那组

`.` 和 `[` 之间没有空格，整体必须加引号（bash 里 `[` 是通配符，不加引号可能被 shell 展开）。

同理 `pip install "lerobot[feetech]"` = 从 PyPI 装 lerobot 并加上 feetech 那组依赖。

### 7.4 配置驱动：参数为什么长得像 `--robot.port=COM3`

这是 LeRobot 代码里最有特色的一点，看懂了架构就顺了。

```bash
lerobot-calibrate --robot.type=so101_follower --robot.port=COM3 --robot.id=my_arm
```

这三条参数**不是**三个独立的命令行开关，而是 `--robot` 这个配置对象下面的三个字段。LeRobot 用 [draccus](https://github.com/facebookresearch/draccus) 把 CLI 参数解析成 Python dataclass：

```python
# 等价于
config = CalibrateConfig(
    robot=SO101FollowerConfig(type="so101_follower", port="COM3", id="my_arm")
)
```

好处是：加一个新机器人（比如 `so101_follower` → `so101_follower_v2`），不需要改任何 CLI 解析代码，只要注册一个新的 config 类。这是 LeRobot 能支持几十种硬件而不爆炸的原因。

---

## 8. LeRobot 项目架构分析

### 8.1 目录骨架（v0.6.1 实测，`src/lerobot/` 下 29 个顶层条目）

```
lerobot/
├── pyproject.toml              ← 依赖、extras、21 个命令行入口都在这里
├── src/lerobot/                ← 真正的源码（src-layout）
│   ├── robots/                 ← 机器人本体（从臂）
│   │     so_follower/(SO100/SO101 共用)、koch_follower、bi_so_follower、
│   │     lekiwi、hope_jr、openarm_follower、unitree_g1、reachy2…
│   │     另有 robot.py（抽象基类）、config.py
│   ├── teleoperators/          ← 遥操作设备（主臂/手柄/键盘/手机）
│   │     so_leader/(SO100/SO101 共用)、koch_leader、gamepad、keyboard、
│   │     phone、homunculus、openarm_leader…
│   │     另有 teleoperator.py（抽象基类）
│   ├── motors/                 ← 舵机/电机总线驱动
│   │     feetech/(SO-101 用)、dynamixel/、damiao/、robstride/、
│   │     motors_bus.py（总线抽象）、calibration_gui.py
│   ├── cameras/                ← opencv/、realsense/、zmq/、reachy2_camera/
│   │     utils.py ← Windows 后端问题就出在这个文件（见 10.2）
│   ├── datasets/               ← LeRobotDataset 读写、视频编码、统计量
│   ├── policies/               ← 策略模型：act、diffusion、smolvla、pi0、pi05、
│   │     pi0_fast、groot、xvla、tdmpc、vqbet、multi_task_dit…
│   │     factory.py（按 --policy.type 查表创建）
│   ├── processor/              ← 数据在模型前后的变换管线（0.6 起强化，注意是单数）
│   ├── configs/                ← 各类 dataclass 配置定义
│   ├── scripts/                ← 21 个 CLI 入口的实现
│   ├── envs/                   ← 仿真环境（aloha、pusht、libero、metaworld）
│   ├── rollout/、inference/    ← 推理与 rollout 策略（0.6 新增，见 10.1）
│   ├── rewards/、rl/           ← 奖励模型与强化学习
│   ├── data_processing/、transforms/、streaming/、transport/
│   ├── model/、optim/、distributed/、jobs/
│   ├── utils/、common/、templates/、annotations/
│   └── lerobot_types.py、__version__.py
├── examples/                   ← notebook 与示例
└── tests/
```

`pyproject.toml` 里当前注册的 21 个命令（**这就是你能敲的全部 `lerobot-*`**）：

```
lerobot-find-port          lerobot-setup-motors     lerobot-calibrate
lerobot-teleoperate        lerobot-record           lerobot-replay
lerobot-train              lerobot-eval            lerobot-rollout
lerobot-find-cameras       lerobot-dataset-viz     lerobot-imgtransform-viz
lerobot-info               lerobot-edit-dataset    lerobot-annotate
lerobot-find-joint-limits  lerobot-setup-can       lerobot-build-mp4-sidecar
lerobot-convert-dcp        lerobot-train-tokenizer lerobot-policy-server
```

> 顺带回答一个常被问的问题：**"命令名字和文件名不是一一对应的，怎么找？"**
> 打开 `pyproject.toml` 搜 `[project.scripts]`，两列一一对应。想知道 `lerobot-calibrate` 干了什么，看 `lerobot_calibrate.py`。

### 8.2 一条数据流，把上面这些模块串起来

这是理解架构最快的方式 —— 不要从 100 个文件看起，先看数据怎么流动：

```
     主臂(leader)                    从臂(follower)
  teleoperators/so_leader   ──位置──>  robots/so_follower
         │                                  │
         │                                  ├──> motors/feetech  ──串口──> STS3215 舵机
         │                                  └──> cameras/opencv  ──USB──> 摄像头
         │                                          │
         └──────────────┬───────────────────────────┘
                        ▼
              datasets/LeRobotDataset
              (observation.state / images / action / task)
                        │
                        ▼
                 policies/act 等
                        │
                        ▼
                 训练出的策略 → 推理时替换掉"主臂"这一路
```

**遥操作和推理的区别，只在最左边那一路**：遥操作时 action 来自主臂，推理时 action 来自策略网络的输出。中间和右边的机械臂、电机、摄像头代码完全复用 —— 这是 LeRobot 设计上最漂亮的地方，也解释了为什么标定必须做对：主臂和从臂的位置值必须可比，否则"人教的"和"机器学的"不在同一个坐标系里。

### 8.3 三个架构特征

**① 硬件 = 配置 + 驱动，而不是分支 if-else**
每个机器人一个 config dataclass（`SO101FollowerConfig`）加一个实现类（`SO101Follower`），注册进注册表。`--robot.type=so101_follower` 就是在查这张表。

**② 依赖按功能切片（extras）**
`feetech` 这种 SDK 只在用飞特舵机时才需要，所以单独一个 extra。装 `[all]` 会拖进一堆用不上的仿真环境依赖，这也是为什么官方推荐的组合是 `[core_scripts]` + `[training]` + `[feetech]`，而不是无脑 `[all]`。

**③ 文档与代码强绑定**
公社文档提到，LeRobot 的开发范式要求"代码更改必须附带文档的更改"，所以英文文档永远最准，中文翻译（含官方 i18n 项目）总是滞后。**遇到的问题如果搜不到答案，去翻 main 分支的 `docs/source/*.mdx`，比翻任何教程都可靠。**

### 8.4 建议的源码阅读顺序

1. `pyproject.toml` —— 先看 `[project.scripts]`，知道有哪些命令；再看 extras，知道有哪些能力。
2. `src/lerobot/scripts/lerobot_calibrate.py` —— 最短的一个脚本，看懂 `main()` 怎么把 config 变成动作。
3. `src/lerobot/robots/so_follower/config_so_follower.py` —— 看 `SO101FollowerConfig` 有哪些字段，正好对上 `--robot.port` / `--robot.id` / `--robot.cameras`。
4. `src/lerobot/robots/so_follower/so_follower.py` —— 看 `connect()` 里的 `configure()`，改 PID 降抖动就在这（P 从 32 改成 16）。注意 SO100 和 SO101 共用这个文件，靠 config 区分。
5. `src/lerobot/motors/feetech/` + `motors_bus.py` —— 想明白"一条总线 6 个舵机靠 ID 区分"。
6. `src/lerobot/datasets/lerobot_dataset.py` —— 数据结构长什么样。
7. `src/lerobot/policies/factory.py` → 某个具体策略 —— 那是模型，跟硬件无关，改起来风险最低也最独立。

---

## 9. 安装 LeRobot

### 9.1 前置检查

```bash
conda --version     # 有
git --version       # 有
python --version    # 全局的不用管，重点是激活环境后对不对
```

**Python 版本要求**：官方 main 分支要求 **Python >= 3.12 + PyTorch >= 2.10**。公社文档用的也是 `python=3.12`，一致。

### 9.2 造环境并激活

```bash
conda create -y -n lerobot python=3.12
conda activate lerobot
```

（WSL 里装的话，额外 `conda install evdev -c conda-forge`。）

### 9.3 装 ffmpeg（Windows 上的第一个坑）

LeRobot 默认用 TorchCodec 解码视频，它需要 ffmpeg。

```bash
conda install ffmpeg -c conda-forge
```

**验证**（这一步必须做，别跳过）：

```powershell
where.exe ffmpeg
# 期望：G:\ProgramFile\Anaconda2506\envs\lerobot\Library\bin\ffmpeg.exe
```

```bash
which ffmpeg
```

路径里必须含 `envs\lerobot`。如果指向了系统装的 ffmpeg，或者找不到，后面录制数据集会以各种奇怪的方式失败。

**已知坑（公社文档记录）**：Windows 上装 ffmpeg 有可能破坏虚拟环境（比如 `pip` 突然不能用了）。退路是装低一个版本并跳过依赖检查：

```bash
conda install ffmpeg=7.1.0 -c conda-forge --no-deps
```

官方也提到，如果遇到 `libsvtav1` 缺失或与 torchcodec 版本不匹配，可以钉 `ffmpeg=7.1.1`。用 `ffmpeg -encoders` 可以看到编解码器列表。

> 判断是否需要装：macOS Intel、Linux ARM(aarch64)、以及 PyTorch < 2.8 的 Windows，TorchCodec 不可用，LeRobot 会自动回退到 pyav，这时**可以不装 ffmpeg**，直接跳到下一步。

### 9.4 源码 + 编辑模式安装（推荐路线）

```bash
git clone https://github.com/huggingface/lerobot.git
cd lerobot

pip install -e ".[core_scripts]"   # 录制、回放、标定（必装）
pip install -e ".[training]"       # 要训练策略才装
pip install -e ".[feetech]"        # SO-101 用飞特舵机，必装
```

三个可以合成一条：

```bash
pip install -e ".[core_scripts,training,feetech]"
```

要全功能（会拖进一堆仿真依赖）：`pip install -e ".[all]"`。

**只装 PyPI 版的话**（不打算改代码）：

```bash
pip install "lerobot[core_scripts,feetech]"
```

### 9.5 网络加速（China 环境，绕不过去）

PyPI 走第 5.2 节的镜像源。Hugging Face 的模型/数据集走镜像：

```powershell
# Windows PowerShell，当前会话有效
$env:HF_ENDPOINT = "https://hf-mirror.com"
```

```bash
# Linux/macOS，写进 ~/.bashrc 长期有效
export HF_ENDPOINT=https://hf-mirror.com
```

`git clone` 和 pip 的代理见 3.4。

### 9.6 验证安装成功

```bash
python -c "import lerobot; print(lerobot.__version__)"
where.exe lerobot-find-port     # 或 which lerobot-find-port
lerobot-find-port --help
lerobot-calibrate --help
```

四条全过，环境就干净了。**任何一条不过，先回去查"是不是在 `(lerobot)` 环境里"，不要急着重装。**

### 9.7 常见报错对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| `ModuleNotFoundError: No module named 'lerobot'` | 不在 `(lerobot)` 环境，或 PyCharm 解释器指错 | `conda activate lerobot`；检查 PyCharm Interpreter |
| `where.exe lerobot-calibrate` 找不到 | 没装或有多个环境 | 重跑 `pip install -e ".[core_scripts]"`，确认在同环境 |
| `lerobot-calibrate` 报 `KeyError: 'feetech'` / 找不到舵机 SDK | 漏了 feetech extra | `pip install -e ".[feetech]"` |
| 标定报串口打不开 | 端口号错 / 被别的程序占用 | 关掉串口助手；重跑 `lerobot-find-port` |
| `ffmpeg` 找不到 / 视频编码失败 | ffmpeg 不在当前环境 | 见 9.3，`where.exe ffmpeg` 验证 |
| 录制时第二个摄像头报错 | Windows OpenCV 多线程已知问题 | 见 10.2 |
| 遥操作时从臂抖动 | 控制频率掉到 20Hz 以下 | 关掉摄像头先试无摄像头遥操作；降低分辨率/换 MJPG |
| `pip` 突然不能用了 | conda 装 ffmpeg 破坏了环境 | 重装 ffmpeg `--no-deps`；或重建环境（成本很低） |

---

## 10. 与公社文档的差异（务必注意）

### 10.1 版本差异：`lerobot-record` 不再用于推理

公社文档成文于 `0.5.0`。**0.6.x 起，推理有了独立命令 `lerobot-rollout`**：

```bash
# 0.6.x 的推理
lerobot-rollout \
    --strategy.type=base \
    --policy.path=${HF_USER}/policy_test \
    --robot.type=so101_follower \
    --robot.port=/dev/ttyACM0 \
    --robot.id=my_follower_arm \
    --robot.cameras="{ top: {type: opencv, index_or_path: 1, width: 640, height: 480, fps: 30}, wrist: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 30} }" \
    --task="put the red brick in a bowl" \
    --duration=60
```

在 `0.5.x` 及更早，没有 `lerobot-rollout`，推理还是用 `lerobot-record`。

另外 `0.6` 的实验追踪默认从 W&B 换成了 **Trackio**（`--trackio.enable=true`，本地存在 `~/.cache/huggingface/trackio`，用 `trackio show --project lerobot` 看面板），W&B 的参数 `--wandb.*` 仍可用但已不是首选。

### 10.2 Windows 摄像头：公社文档记录的老坑

**现象**：Windows 上 OpenCV 多线程只能读一个摄像头，第二个报错。

原因与现状：
- 上游 PR #1495 把后端从默认换成了 `cv2.CAP_MSMF`，但并非所有 Windows 机器都被修好。
- 公社的临时改法是改源码（这正好是第 7 节"编辑模式安装"的价值兑现处）：

```python
# src/lerobot/cameras/utils.py 约 71-72 行 —— 公社版改法
if platform.system() == "Windows":
    return int(cv2.CAP_DSHOW)   # DSHOW or ANY, instead of MSMF
```

- 查自己 OpenCV 支持哪些后端：

```python
import cv2
print(cv2.getBuildInformation())   # 看 Video I/O backends
```

- 公社给的两个规避方向：**单摄像头**（Windows 最稳），或换 Linux（Linux 上两个摄像头不要插在同一个 USB Hub / 同一个控制器上，会抢 IO 带宽）。
- 分辨率/编码权衡：`YUYV` 画质好但慢，`MJPG` 快但画质差。

> 这类平台特有问题的通用判断法：**先去 GitHub issue 搜现象，再去 `docs/source/` 看是否已记录，最后才看教程**。教程永远滞后于这些补丁。

### 10.3 一个小纠正

公社 BOM 里写的"飞特电机 **STS**3215"，官方文档与飞特官方型号是 **STS3215**（S 系列 TTL 总线舵机）。买件时按 `STS3215` 搜。

从臂 6 个全部是 `1/345` 减速比；主臂为了"既能撑住自重、又能被轻松推动"，用了三种不同减速比：轴1 `1/191`、轴2 `1/345`、轴3 `1/191`、轴4-6 `1/147`。**这个差异是装配时最容易装错的地方** —— 主臂 6 个舵机长得一样，减速比不一样。

---

## 11. 命令速查

### 环境

```bash
conda create -y -n lerobot python=3.12
conda activate lerobot
conda env list
conda remove -n lerobot --all
conda list                      # 看环境里所有包（含 conda 装的二进制）
conda install ffmpeg -c conda-forge
where.exe ffmpeg                # Windows 验证
```

### 安装

```bash
pip config set global.index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
git clone https://github.com/huggingface/lerobot.git && cd lerobot
pip install -e ".[core_scripts,training,feetech]"
python -c "import lerobot; print(lerobot.__version__)"
```

### 硬件流程（顺序不能乱）

```bash
# 1. 找端口（按提示拔线、回车）
lerobot-find-port

# 2. 设电机 ID（一次性的，写进 EEPROM；从 gripper=6 开始倒数）
lerobot-setup-motors --robot.type=so101_follower --robot.port=COM3
lerobot-setup-motors --teleop.type=so101_leader  --teleop.port=COM4

# 3. 标定（每台臂一次，id 必须与后续命令完全一致）
lerobot-calibrate --robot.type=so101_follower --robot.port=COM3 --robot.id=my_follower_arm
lerobot-calibrate --teleop.type=so101_leader --teleop.port=COM4 --teleop.id=my_leader_arm

# 4. 遥操作
lerobot-teleoperate \
  --robot.type=so101_follower --robot.port=COM3 --robot.id=my_follower_arm \
  --teleop.type=so101_leader  --teleop.port=COM4 --teleop.id=my_leader_arm

# 5. 找摄像头
lerobot-find-cameras opencv
```

标定文件位置：

```
Windows: C:\Users\<你>\.cache\huggingface\lerobot\calibration\
Linux:   ~/.cache/huggingface/lerobot/calibration/
          ├── robots/so101_follower/my_follower_arm.json
          └── teleoperators/so101_leader/my_leader_arm.json
```

**多台臂同型号时，就靠 `--robot.id` 这个名字区分文件** —— 名字写错，标定白做。

### 训练（0.6.x）

```bash
lerobot-train \
  --dataset.repo_id=${HF_USER}/so101_dataset_test_YYYYMMDD_HHMMSS \
  --policy.type=act \
  --output_dir=outputs/train/act_so101_test \
  --job_name=act_so101_test \
  --policy.device=cuda \
  --trackio.enable=true \
  --steps=20000
```

`--policy.type` 是**从零训练**；`--policy.path=<repo_id>` 是**在已有模型上微调**（此时不用给 `--policy.type`）。

---

## 附：一句话记忆卡

| 概念 | 一句话 |
|---|---|
| conda | 环境管理器，能装二进制，`activate` 本质是改 PATH |
| Anaconda / Miniconda | 同一个 conda，差别只在预装软件和默认源 |
| module | 一个 `.py` 文件 |
| package | 一个带 `__init__.py` 的目录 |
| import | 在 `sys.path` 里找 → 执行一次 → 缓存进 `sys.modules` |
| pip | 从 PyPI 往当前环境装包 |
| pyproject.toml | 包的身份证 + 依赖清单 + 命令入口 |
| extras | `optional-dependencies` 的 key，`.[feetech]` 里的那个词 |
| `pip install -e .` | 不复制源码，放个指针让 Python 永远认得你的目录 |
| `[project.scripts]` | `lerobot-find-port` 这类命令的出生证明 |
| LeRobot 架构 | 硬件=config+驱动，依赖=extras 切片，数据流 主臂→从臂→数据集→策略 |
| 标定 | 让"人教的"和"机器学的"落在同一个坐标系 |

---

## 参考

- 官方安装：[huggingface.co/docs/lerobot/installation](https://huggingface.co/docs/lerobot/installation)
- 官方 SO-101：[huggingface.co/docs/lerobot/so101](https://huggingface.co/docs/lerobot/so101)
- 官方速查：[huggingface.co/docs/lerobot/cheat-sheet](https://huggingface.co/docs/lerobot/cheat-sheet)
- 电子羊公社：[escommune.readthedocs.io](https://escommune.readthedocs.io/)
- 硬件 BOM / 打印件：[TheRobotStudio/SO-ARM100](https://github.com/TheRobotStudio/SO-ARM100)
- 源码：[github.com/huggingface/lerobot](https://github.com/huggingface/lerobot)
