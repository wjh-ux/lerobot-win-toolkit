<#
.SYNOPSIS
    在 Windows 上安装 LeRobot 开发环境（conda + ffmpeg + 源码编辑模式安装）。

.DESCRIPTION
    全程优先使用国内镜像，某个镜像不通时自动降级到下一个，最后才用官方源。
    镜像优先级（实测排序，脚本会逐个探测）：

        pip   : 清华 tuna -> 阿里云 -> 腾讯云 -> 中科大 -> 华为云 -> 官方 PyPI
        conda : 清华 tuna conda-forge -> conda 默认源
        git   : gh-proxy.com -> ghfast.top -> ghproxy.net -> 直连 GitHub
        兜底  : 上面 git 全不通时，从 pip 镜像下 sdist 解压（-FromPypi / -NoPypiFallback）
        HF    : hf-mirror.com（写进用户环境变量 HF_ENDPOINT）

    不需要 conda activate，脚本直接调用环境里的 python.exe，避免
    "脚本里 conda activate 无效" 这个经典问题。

.PARAMETER EnvName
    conda 环境名，默认 lerobot。

.PARAMETER PythonVersion
    Python 版本，默认 3.12（官方要求 >= 3.12）。

.PARAMETER Extras
    要装的 extras，逗号分隔。默认 core_scripts,training,feetech
    - core_scripts : 录制/回放/标定（lerobot-record / calibrate / teleoperate）
    - training    : 训练策略（lerobot-train）
    - feetech     : SO-101 用的飞特舵机 SDK

.PARAMETER InstallDir
    lerobot 源码放哪里，默认 $HOME\lerobot。

.PARAMETER Proxy
    可选。给 git/pip 用的代理，例如 http://127.0.0.1:7897。
    注意：设了代理后仍然先试国内镜像；只有直连 GitHub 时才会用到它。

.PARAMETER Recreate
    环境已存在时删掉重建。

.PARAMETER SkipFfmpeg
    跳过 conda 装 ffmpeg。只有在你确定 TorchCodec 不支持本机时才用
    （macOS Intel / Linux ARM / PyTorch < 2.8 的 Windows 会自动回退 pyav）。

.PARAMETER NoHfMirror
    不设置 HF_ENDPOINT 用户环境变量。

.PARAMETER PersistPipIndex
    把选中的 pip 镜像写进用户级 pip 配置（pip config set global.index-url），
    以后随手 pip install 也走镜像。默认不写，免得影响其它项目。

.PARAMETER FullHistory
    git clone 不加 --depth 1，拉完整历史（慢，但方便切版本）。

.PARAMETER FromPypi
    完全不碰 git：直接从 pip 镜像下载 lerobot 的 sdist（.tar.gz）解压当源码。
    适合公司网络封了 GitHub、连加速器也不好使的情况。
    代价：拿到的是 PyPI 上的发布版（如 0.6.1），不是 GitHub main 分支。

.PARAMETER PypiVersion
    配合 -FromPypi 指定版本，例如 0.6.1。不指定则取镜像上最高版本。

.PARAMETER NoPypiFallback
    默认行为是：git 全部失败后自动兜底走 sdist。加这个开关就不兜底，直接报错退出。

.PARAMETER AutoInstallPrereqs
    缺 conda / git 时尝试用 winget 自动装。默认关闭，只提示。

.PARAMETER DryRun
    只打印要执行的命令，不真的执行。第一次跑建议先加这个看看。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-lerobot.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-lerobot.ps1

.PARAMETER WithGit
    装完 conda 环境后，再用 conda 往这个环境里装一份 git。
    适合没有 winget、又下不动 Git for Windows 安装包的机器（比如 Server 2022）。
    装好后在 `conda activate <环境>` 里可以直接用 git。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-lerobot.ps1 -Proxy http://127.0.0.1:7897 -Extras core_scripts,feetech
#>
[CmdletBinding()]
param(
    [string]$EnvName        = 'lerobot',
    [string]$PythonVersion  = '3.12',
    [string]$Extras         = 'core_scripts,training,feetech',
    [string]$InstallDir     = (Join-Path $HOME 'lerobot'),
    [string]$Proxy          = '',
    [switch]$Recreate,
    [switch]$WithGit,
    [switch]$SkipFfmpeg,
    [switch]$NoHfMirror,
    [switch]$PersistPipIndex,
    [switch]$FullHistory,
    [switch]$FromPypi,
    [string]$PypiVersion = '',
    [switch]$NoPypiFallback,
    [switch]$AutoInstallPrereqs,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$script:Failures = 0
$script:Curl = Join-Path $env:SystemRoot 'System32\curl.exe'

# 进度条字符：逐个字符验证能否在当前控制台编码里往返。
# 踩过的坑：GBK 控制台里 U+2588(█) 能显示，但 U+2591(░) 会变成 '?'，
# 结果进度条一半是方块一半是问号。所以两个字符都要测，不行就降级。
function Test-Glyph([int]$cp) {
    try {
        $e = [Console]::OutputEncoding
        $s = [string][char]$cp
        return ($e.GetString($e.GetBytes([char]$cp)) -eq $s)
    } catch { return $false }
}

$script:BarFull  = '#'
$script:BarEmpty = '-'
if (Test-Glyph 0x2588) {
    $script:BarFull = [string][char]0x2588
    if (Test-Glyph 0x2591) {
        $script:BarEmpty = [string][char]0x2591
    } else {
        $script:BarEmpty = ' '     # 空心方块显示不了，用空格，观感仍然正常
    }
}

# ------------------------------------------------------------------ 输出
$script:StepNow   = 0
$script:StepTotal = 0          # 参数解析后按实际会执行的步骤数算出来
$script:TotalSw   = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Section([string]$t) {
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host ("  $t") -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}

function Enter-Step {
    <#  打印 "[3/9] [进度条] 33%  步骤名"，并推进步骤计数  #>
    param([Parameter(Mandatory)][string]$Name)
    $script:StepNow++
    Write-Host ''
    $pct = 0
    if ($script:StepTotal -gt 0) {
        $pct = [int][math]::Floor($script:StepNow * 100 / $script:StepTotal)
    }
    $barW = 20
    $filled = [int][math]::Floor($barW * $pct / 100)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $barW) { $filled = $barW }
    $bar = ($script:BarFull * $filled) + ($script:BarEmpty * ($barW - $filled))
    Write-Host ("  第 {0}/{1} 步  [{2}] {3,3}%  {4}" -f $script:StepNow, $script:StepTotal, $bar, $pct, $Name) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 70)) -ForegroundColor DarkGray
}

function Write-Ok([string]$t)   { Write-Host "  [ OK ]  $t" -ForegroundColor Green }
function Write-Warn2([string]$t){ Write-Host "  [WARN]  $t" -ForegroundColor Yellow }
function Write-Err([string]$t)  { Write-Host "  [FAIL]  $t" -ForegroundColor Red; $script:Failures++ }
function Write-Info([string]$t) { Write-Host "          $t" -ForegroundColor Gray }

function Write-Die([string]$msg) {
    Write-Host ''
    Write-Host "  [中止] $msg" -ForegroundColor Red
    Write-Host ''
    exit 1
}

# ------------------------------------------------------------------ 执行
function Invoke-Cmd {
    <#
      返回 exit code（整数）。DryRun 时只打印。
      注意 `| Out-Host`：不加的话子进程的 stdout 会混进本函数的返回值，
      调用方拿到的 $code 就变成一整段文本而不是退出码，`$code -eq 0` 永远为假。
      Out-Host 让输出照常显示在控制台，同时保持返回值干净。
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$ArgList = @(),
        [string]$WorkDir = ''
    )
    $pretty = "$Exe " + (($ArgList | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' ')
    Write-Host "  > $pretty" -ForegroundColor DarkGray

    if ($DryRun) { return 0 }

    $here = Get-Location
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        & $Exe @ArgList | Out-Host
        $rc = $LASTEXITCODE
        if ($null -eq $rc) { $rc = 0 }
        return [int]$rc
    } catch {
        Write-Info ("异常: " + $_.Exception.Message)
        return 1
    } finally {
        Set-Location -LiteralPath $here
    }
}

function Test-Url {
    <#  能拿到 2xx/3xx 就算通。curl 优先（Win10+ 自带），没有就退回 Invoke-WebRequest。  #>
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 8)
    if ($DryRun) { return $true }
    if (Test-Path $script:Curl) {
        $code = & $script:Curl -sS -o NUL -w '%{http_code}' -m $TimeoutSec -g $Url 2>$null
        return ($code -match '^[23]\d\d$')
    }
    try {
        $null = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Invoke-Download {
    <#
      带进度和速度的下载。
      不用 curl 自带的进度条：它走 stderr，被外层 2>&1 管道捕获后会变成一堆假的
      "NativeCommandError"。这里 curl 静默下载，脚本轮询文件大小自己画进度。
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutSec = 1800
    )
    if ($DryRun) {
        Write-Host "  > curl -L -sS -o `"$OutFile`" -m $TimeoutSec `"$Url`"" -ForegroundColor DarkGray
        return 0
    }

    # 先问一下总大小（拿不到就只显示已下多少）
    $total = 0
    try {
        $head = & $script:Curl -sI -L -m 20 -g $Url 2>$null | Out-String
        $m = [regex]::Match($head, '(?im)^content-length:\s*(\d+)')
        if ($m.Success) { $total = [int64]$m.Groups[1].Value }
    } catch { }

    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Curl
    # -f 必须有：不加的话 curl 遇到 404 会把错误页当文件存下来、还返回成功，
    # 后面就会拿一个 HTML 去当安装包执行。
    $psi.Arguments = '-L -f -sS -m ' + $TimeoutSec + ' -o "' + $OutFile + '" "' + $Url + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $lastPrint = 0.0
    $lastSize = 0
    $lastT = 0.0
    Write-Host '    进度：[百分比] 已下/总量 速度 已用/剩余' -ForegroundColor DarkGray

    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 400
        $now = $sw.Elapsed.TotalSeconds
        if (($now - $lastPrint) -lt 1) { continue }
        $lastPrint = $now
        $size = 0
        if (Test-Path -LiteralPath $OutFile) {
            try { $size = (Get-Item -LiteralPath $OutFile).Length } catch { $size = 0 }
        }
        $speed = 0
        if (($now - $lastT) -gt 0) { $speed = ($size - $lastSize) / ($now - $lastT) }
        $lastSize = $size
        $lastT = $now

        $doneMB = [math]::Round($size / 1MB, 1)
        $spdMB = [math]::Round($speed / 1MB, 2)
        $elapsed = [int][math]::Round($sw.Elapsed.TotalSeconds, 0)
        if ($total -gt 0) {
            $pct = [int][math]::Min(100, [math]::Floor($size * 100 / $total))
            $totMB = [math]::Round($total / 1MB, 1)
            $barW = 26
            $filled = [int][math]::Floor($barW * $pct / 100)
            if ($filled -lt 0) { $filled = 0 }
            if ($filled -gt $barW) { $filled = $barW }
            $bar = ($script:BarFull * $filled) + ($script:BarEmpty * ($barW - $filled))
            $eta = 0
            if ($speed -gt 1024) { $eta = [int][math]::Round(($total - $size) / $speed, 0) }
            if ($eta -lt 0) { $eta = 0 }
            # 保持纯 ASCII 数字：中文占两列，PadRight 算不准，容易让 \r 换行错位
            $line = "    [{0}] {1,3}%  {2,6}/{3} MB  {4,4} MB/s  {5}s/{6}s" -f $bar, $pct, $doneMB, $totMB, $spdMB, $elapsed, $eta
        } else {
            $line = "    {0,8} MB  {1,4} MB/s  {2}s" -f $doneMB, $spdMB, $elapsed
        }
        Write-Host ("`r" + $line.PadRight(74)) -NoNewline
        if ($sw.Elapsed.TotalSeconds -gt ($TimeoutSec + 120)) { $p.Kill(); break }
    }

    $code = $p.ExitCode
    $stdErr = $p.StandardError.ReadToEnd()
    $sw.Stop()
    $finalSize = 0
    if (Test-Path -LiteralPath $OutFile) {
        try { $finalSize = (Get-Item -LiteralPath $OutFile).Length } catch { }
    }
    # 收尾：清掉进度行，打一行总结
    Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline
    if ($code -eq 0 -and $finalSize -gt 0) {
        $avg = [math]::Round($finalSize / 1MB / [math]::Max($sw.Elapsed.TotalSeconds, 0.001), 2)
        Write-Host ("    完成 {0} MB，用时 {1} 秒，平均 {2} MB/s" -f [math]::Round($finalSize / 1MB, 1), [math]::Round($sw.Elapsed.TotalSeconds, 0), $avg) -ForegroundColor Green
    } else {
        if ($stdErr) { Write-Host ("    curl: " + ($stdErr -replace "`r?`n", ' ')) -ForegroundColor Yellow }
        Write-Host ("    下载失败（exit={0}，已下 {1} MB）" -f $code, [math]::Round($finalSize / 1MB, 1)) -ForegroundColor Yellow
    }
    return $code
}

# ------------------------------------------------------------------ 镜像表
$script:PipMirrors = @(
    @{ Name = '清华 tuna';      Index = 'https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple'; Probe = 'https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/pip/' }
    @{ Name = '阿里云';         Index = 'https://mirrors.aliyun.com/pypi/simple';                Probe = 'https://mirrors.aliyun.com/pypi/simple/pip/' }
    @{ Name = '腾讯云';         Index = 'https://mirrors.cloud.tencent.com/pypi/simple';         Probe = 'https://mirrors.cloud.tencent.com/pypi/simple/pip/' }
    @{ Name = '中科大';         Index = 'https://pypi.mirrors.ustc.edu.cn/simple';               Probe = 'https://pypi.mirrors.ustc.edu.cn/simple/pip/' }
    @{ Name = '华为云';         Index = 'https://repo.huaweicloud.com/repository/pypi/simple';    Probe = 'https://repo.huaweicloud.com/repository/pypi/simple/pip/' }
    @{ Name = '官方 PyPI';      Index = 'https://pypi.org/simple';                               Probe = 'https://pypi.org/simple/pip/' }
)

$script:CondaMirrorName = '清华 tuna conda-forge'
$script:CondaMirrorUrl  = 'https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge'
$script:CondaMirrorProbe = 'https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge/'

$script:GitUrls = @(
    @{ Name = 'gh-proxy.com 加速'; Url = 'https://gh-proxy.com/https://github.com/huggingface/lerobot.git' }
    @{ Name = 'ghfast.top 加速';   Url = 'https://ghfast.top/https://github.com/huggingface/lerobot.git' }
    @{ Name = 'ghproxy.net 加速';  Url = 'https://ghproxy.net/https://github.com/huggingface/lerobot.git' }
    @{ Name = '直连 GitHub';       Url = 'https://github.com/huggingface/lerobot.git' }
)

# ================================================================== 0. 参数
# 本次实际会走几步：ffmpeg、git 是可选的，总数跟着变，避免出现 "第 4/9 步" 之后直接结束
$script:StepTotal = 7
if (-not $SkipFfmpeg) { $script:StepTotal++ }
if ($WithGit)        { $script:StepTotal++ }

Write-Section '参数'
Write-Info "环境名      : $EnvName"
Write-Info "Python      : $PythonVersion"
Write-Info "extras      : $Extras"
Write-Info "源码目录    : $InstallDir"
Write-Info "代理        : $(if ($Proxy) { $Proxy } else { '（未设置）' })"
Write-Info "源码来源    : $(if ($FromPypi) { 'PyPI sdist（-FromPypi）' } else { 'git，失败自动兜底到 PyPI sdist' })"
if ($DryRun) { Write-Warn2 'DryRun 模式：只打印命令，不执行任何安装' }

# ================================================================== 1. 前置检查
Enter-Step '前置检查'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Die "需要 PowerShell 5.1 或更高（当前 $($PSVersionTable.PSVersion)）"
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

# --- git（-FromPypi 根本不用 git，别为此卡住）
$gitExe = $null
if ($FromPypi) {
    Write-Info 'git：跳过（-FromPypi 走 sdist，不需要 git）'
} else {
    $gitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    if (-not $gitExe) {
        if ($AutoInstallPrereqs) {
            Write-Warn2 'git 未安装，尝试 winget 安装 Git.Git'
            if (Invoke-Cmd -Exe 'winget' -ArgList @('install','--id','Git.Git','-e','--source','winget','--accept-package-agreements','--accept-source-agreements') -eq 0) {
                $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
                $gitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
            }
        }
        if (-not $gitExe) {
            Write-Err 'git 未安装'
            Write-Info '下载 https://git-scm.com/download/win 或执行：winget install --id Git.Git -e'
            Write-Info '装完重开一个终端再跑本脚本'
            Write-Info '或者：不想装 git 就加 -FromPypi，直接从 pip 镜像取源码'
            exit 1
        }
    }
    Write-Ok "git $(& $gitExe --version)"
}

# --- conda
function Find-Conda {
    $c = Get-Command conda.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path $HOME 'miniconda3\Scripts\conda.exe'),
        (Join-Path $HOME 'miniforge3\Scripts\conda.exe'),
        (Join-Path $HOME 'anaconda3\Scripts\conda.exe'),
        (Join-Path $env:LOCALAPPDATA 'miniconda3\Scripts\conda.exe'),
        (Join-Path $env:LOCALAPPDATA 'miniforge3\Scripts\conda.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\miniconda3\Scripts\conda.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\miniforge3\Scripts\conda.exe'),
        (Join-Path $env:ProgramData 'miniconda3\Scripts\conda.exe'),
        (Join-Path $env:ProgramData 'miniforge3\Scripts\conda.exe'),
        (Join-Path $env:ProgramData 'Anaconda3\Scripts\conda.exe')
    )
    foreach ($p in $cands) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

$condaExe = Find-Conda
if (-not $condaExe) {
    if ($AutoInstallPrereqs) {
        Write-Warn2 'conda 未找到，自动安装 miniforge/miniconda（国内镜像优先）'
        # 每个源给独立的安装目录 + 独立的临时文件名：
        #  - 安装器退出前会一直占着 exe，复用同名文件会让下一个源写不进去（实测踩过）
        #  - /D 指定目录，装到哪就确定可知，不靠猜
        $mfSources = @(
            @{ Name = '清华 Miniconda'; Url = 'https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-latest-Windows-x86_64.exe'; Dir = (Join-Path $HOME 'miniconda3') }
            @{ Name = '清华 Miniforge'; Url = 'https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Windows-x86_64.exe'; Dir = (Join-Path $HOME 'miniforge3') }
            @{ Name = 'GitHub Miniforge'; Url = 'https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe'; Dir = (Join-Path $HOME 'miniforge3') }
        )
        $bootIdx = 0
        foreach ($s in $mfSources) {
            $bootIdx++
            if (-not (Test-Url -Url $s.Url -TimeoutSec 25)) {
                Write-Info "$($s.Name) 不通，换下一个"
                continue
            }
            $tmp = Join-Path $env:TEMP "conda-bootstrapper-$bootIdx.exe"
            Write-Info "下载 $($s.Name)（约 150 MB，慢是正常的）"
            # 用 -sS 而不是默认进度条：curl 的进度条走 stderr，
            # 被外层 2>&1 管道捕获后会变成一堆假的 "NativeCommandError"
            if ((Invoke-Download -Url $s.Url -OutFile $tmp -TimeoutSec 1800) -ne 0) {
                Write-Info '  下载失败，换下一个'
                continue
            }
            if (Test-Path -LiteralPath $tmp) {
                Write-Info ("  已下载 " + [math]::Round((Get-Item -LiteralPath $tmp).Length / 1MB, 1) + " MB")
            }
            # 校验确实是 PE 可执行文件，别把 HTML 错误页当安装包跑
            $fsCheck = [System.IO.File]::OpenRead($tmp)
            $buf = New-Object byte[] 2
            $null = $fsCheck.Read($buf, 0, 2)
            $fsCheck.Close()
            if (-not ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A)) {
                Write-Warn2 '  下载到的不是 exe（可能是错误页），换下一个'
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Info "静默安装中 -> $($s.Dir)（可能需要几分钟，别中断）"
            # /D 必须是最后一个参数，且不能带引号
            $instArgs = @('/InstallationType=JustMe','/RegisterPython=0','/AddToPath=0','/S', "/D=$($s.Dir)")
            Invoke-Cmd -Exe $tmp -ArgList $instArgs | Out-Null

            # NSIS 静默安装有时会立刻返回、实际还在后台写盘。
            # 用文件锁判断它是否真的结束了：能独占打开 = 装完了。
            $condaExe = $null
            $deadline = (Get-Date).AddSeconds(300)
            while ((Get-Date) -lt $deadline) {
                $condaExe = Find-Conda
                if ($condaExe) { break }
                $stillRunning = $false
                try {
                    $probe = [System.IO.File]::Open($tmp, 'Open', 'ReadWrite', 'None')
                    $probe.Close()
                } catch {
                    $stillRunning = $true      # 文件还被占着 -> 安装器没结束
                }
                if (-not $stillRunning) { break }
                Start-Sleep -Seconds 4
            }
            $condaExe = Find-Conda
            if ($condaExe) {
                Write-Ok "conda 已就位：$condaExe"
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                break
            }
            Write-Warn2 "  装完仍找不到 conda（$($s.Dir)），换下一个源"
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $condaExe) {
        if ($DryRun) {
            $condaExe = 'conda.exe'
        } else {
            Write-Err 'conda 未找到'
            Write-Info '装 Miniforge：https://conda-forge.org/download/'
            Write-Info '或加 -AutoInstallPrereqs 让脚本自己装（走清华镜像）'
            exit 1
        }
    }
}
if ($DryRun) {
    Write-Ok 'conda（DryRun：跳过版本探测）'
} else {
    Write-Ok "conda $(& $condaExe --version)"
}

# --- 磁盘空间（torch + 环境大约 6-10 GB）
try {
    $freeGB = [math]::Round((Get-PSDrive -Name ((Split-Path -Qualifier $InstallDir).TrimEnd(':')) -ErrorAction Stop).Free / 1GB, 1)
    if ($freeGB -lt 15) {
        Write-Warn2 "目标盘剩余 ${freeGB} GB，装上 torch 可能不够（建议 15 GB 以上）"
    } else {
        Write-Ok "目标盘剩余 ${freeGB} GB"
    }
} catch {
    Write-Info '磁盘空间检查跳过'
}

# ================================================================== 2. 环境
Enter-Step "conda 环境 [$EnvName]"

# conda 渠道优先级：先小仓库后大仓库。
# 实测（2026-11）清华各渠道 repodata 体积：
#   pkgs/main     12 MB (zst)  <- 有 python 3.12，建环境够用，最快
#   conda-forge   65 MB (zst)  <- 有 ffmpeg / git
#   完整 json    279+185 MB    <- 慢链路上极易超时，这就是"镜像失败"的真凶
$script:CondaChannels = @(
    @{ Name = '清华 pkgs/main';   Args = @('--override-channels','-c','https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main') }
    @{ Name = '清华 conda-forge'; Args = @('--override-channels','-c','https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge') }
    @{ Name = '默认源';           Args = @() }
)

function Invoke-CondaStep {
    <#  按渠道优先级跑一条 conda 命令；失败时打印真实原因，不吞错误  #>
    param(
        [Parameter(Mandatory)][string[]]$Verb,     # 例如 @('create','-y','-n',...) 前半段
        [string[]]$Packages = @(),
        [string]$Label = 'conda'
    )
    foreach ($ch in $script:CondaChannels) {
        $argList = $Verb + $Packages + $ch.Args
        Write-Info "尝试 [$($ch.Name)]"

        if ($DryRun) {
            Write-Host ("  > " + $condaExe + " " + ($argList -join ' ')) -ForegroundColor DarkGray
            return $true
        }

        $capText = ''
        $code = 1
        try {
            & $condaExe @argList 2>&1 | Tee-Object -Variable capText | Out-Null
            $code = $LASTEXITCODE
        } catch {
            $code = 1
            $capText = @($_.Exception.Message)
        }

        if ($code -eq 0) { return $true }

        Write-Warn2 "$($ch.Name) 失败（退出码 $code）"
        $lines = @($capText | Where-Object { $_ -and "$_".Trim() } | Select-Object -Last 4)
        foreach ($l in $lines) {
            Write-Info ('   ' + (("$l" -replace "`r?`n", ' ').Trim()))
        }
    }
    return $false
}

function Get-EnvPrefix([string]$name) {
    if ($DryRun) { return $null }   # DryRun 下 conda 是占位符，不去探它
    $raw = $null
    try { $raw = & $condaExe env list --json 2>$null | Out-String } catch { return $null }
    if (-not $raw) { return $null }
    $start = $raw.IndexOf('{')
    if ($start -lt 0) { return $null }
    try { $obj = $raw.Substring($start) | ConvertFrom-Json } catch { return $null }
    foreach ($p in $obj.envs) {
        if ((Split-Path -Leaf $p) -eq $name) { return $p }
    }
    return $null
}

$envPrefix = Get-EnvPrefix $EnvName

if ($envPrefix -and $Recreate) {
    Write-Warn2 "环境已存在，-Recreate：删除后重建"
    Write-Info "conda remove -n $EnvName --all"
    Invoke-Cmd -Exe $condaExe -ArgList @('remove','-y','-n',$EnvName,'--all') | Out-Null
    $envPrefix = $null
}

if (-not $envPrefix) {
    $condaOk = Invoke-CondaStep -Verb @('create','-y','-n',$EnvName) -Packages @("python=$PythonVersion") -Label 'create'
    if (-not $condaOk) { Write-Die '所有 conda 渠道都建不了环境（原因见上面的报错行）' }

    $envPrefix = Get-EnvPrefix $EnvName
    if (-not $envPrefix) {
        if ($DryRun) {
            $envPrefix = Join-Path $HOME "miniforge3\envs\$EnvName"
        } else {
            Write-Die '建完环境却找不到它的路径，请手工检查 conda env list'
        }
    }
    Write-Ok "已创建 $envPrefix"
} else {
    Write-Ok "环境已存在：$envPrefix"
    if (-not $Recreate) { Write-Info '加 -Recreate 可以删掉重建' }
}

$pyExe = Join-Path $envPrefix 'python.exe'
if (-not $DryRun -and -not (Test-Path -LiteralPath $pyExe)) { Write-Die "找不到 $pyExe" }

# 把这个变量固化进环境，以后 conda activate 之后也自动生效
if (-not $DryRun) {
    try {
        & $condaExe env config vars set -n $EnvName PYTHONNOUSERSITE=1 2>&1 | Out-Host
    } catch { }
}

# 关键：屏蔽用户级 site-packages。
# 机器上若已有同版本的 Python 3.12，conda 环境会"借用" %APPDATA%\Python\Python312\site-packages，
# 导致 pip 认为 tqdm / pyserial 之类"已满足"而不装进本环境 —— 环境是脏的，
# 换个账户或删掉那个目录就崩。设这个变量让 Python 彻底忽略用户目录。
$env:PYTHONNOUSERSITE = '1'
if (-not $DryRun) {
    $userSite = (& $pyExe -c "import site;print(site.getusersitepackages() if site.ENABLE_USER_SITE else '')" 2>$null)
    if ($userSite) { Write-Warn2 "环境仍在启用用户级 site-packages：$userSite" }
    else { Write-Ok '已屏蔽用户级 site-packages（PYTHONNOUSERSITE=1）' }
}

if ($DryRun) {
    Write-Ok "Python $PythonVersion（DryRun）"
} else {
    $pyVer = (& $pyExe -c "import sys;print('%d.%d.%d'%sys.version_info[:3])" 2>$null)
    Write-Ok "Python $pyVer"

    $majorMinor = [version](($pyVer -split '\.')[0..1] -join '.')
    if ($majorMinor -lt [version]'3.12') {
        Write-Warn2 "LeRobot 要求 Python >= 3.12，当前 $pyVer"
    }
}

# ================================================================== 3. 选 pip 镜像
Enter-Step '探测 pip 镜像（国内优先，不通降级）'

$pipOrder = @()
foreach ($m in $script:PipMirrors) {
    if (Test-Url -Url $m.Probe -TimeoutSec 8) {
        Write-Ok "$($m.Name)  $($m.Index)"
        $pipOrder += $m
    } else {
        Write-Info "$($m.Name) 不通，跳过"
    }
}
if ($pipOrder.Count -eq 0) { Write-Die '所有 pip 镜像都不通，检查网络或加 -Proxy' }

$primaryPip = $pipOrder[0]
Write-Info "选用：$($primaryPip.Name)"

if ($Proxy) {
    $env:HTTP_PROXY  = $Proxy
    $env:HTTPS_PROXY = $Proxy
    Write-Ok "已为本次会话设置代理 $Proxy"
}

if ($PersistPipIndex) {
    Write-Info "写入用户级 pip 配置：$($primaryPip.Index)"
    Invoke-Cmd -Exe $pyExe -ArgList @('-m','pip','config','set','global.index-url',$primaryPip.Index) | Out-Null
}

# 依次尝试所有可用镜像，第一个成功就停
function Invoke-Pip([string[]]$PipArgs, [string]$WorkDir = '') {
    foreach ($m in $pipOrder) {
        $all = @('-m','pip') + $PipArgs + @('--index-url', $m.Index)
        $code = Invoke-Cmd -Exe $pyExe -ArgList $all -WorkDir $WorkDir
        if ($code -eq 0) { return $true }
        Write-Warn2 "在 $($m.Name) 上失败（退出码 $code），换下一个镜像"
    }
    return $false
}

# 升级 pip / setuptools（顺手验证网络）
Write-Info '升级 pip / setuptools / wheel'
if (-not (Invoke-Pip -PipArgs @('install','--upgrade','pip','setuptools','wheel','--disable-pip-version-check','--no-warn-script-location'))) {
    Write-Die 'pip 无法从任何镜像升级，网络基本不可用'
}

# ================================================================== 4. ffmpeg
if (-not $SkipFfmpeg) {
    Enter-Step '安装 ffmpeg（TorchCodec 解码视频用）'

    $ffmpegOk = Invoke-CondaStep -Verb @('install','-y','-n',$EnvName) -Packages @('ffmpeg') -Label 'ffmpeg'
    if (-not $ffmpegOk -and -not $DryRun) {
        Write-Warn2 '换钉版本 7.1.1 再试一轮'
        $ffmpegOk = Invoke-CondaStep -Verb @('install','-y','-n',$EnvName) -Packages @('ffmpeg=7.1.1') -Label 'ffmpeg'
    }

    if ($ffmpegOk -and -not $DryRun) {
        # 官方文档提示：Windows 上装 ffmpeg 有可能把环境里的 pip 弄坏，装完必验
        & $pyExe -m pip --version *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 'pip 失效了（Windows 已知问题），用 --no-deps 重装低版本 ffmpeg 修复'
            Invoke-CondaStep -Verb @('install','-y','-n',$EnvName,'--no-deps') -Packages @('ffmpeg=7.1.0') -Label 'ffmpeg-fix' | Out-Null
            & $pyExe -m pip --version *> $null
            if ($LASTEXITCODE -ne 0) { Write-Err 'pip 仍然不可用，建议 -Recreate 重建环境' }
            else { Write-Ok 'pip 已恢复' }
        }

        $ffPath = Join-Path $envPrefix 'Library\bin\ffmpeg.exe'
        if (Test-Path -LiteralPath $ffPath) { Write-Ok "ffmpeg 在环境内：$ffPath" }
        else { Write-Warn2 "没在 $ffPath 找到 ffmpeg，请跑测试脚本确认" }
    } elseif ($ffmpegOk) {
        Write-Ok 'ffmpeg 安装命令已打印（DryRun）'
    } else {
        Write-Err 'ffmpeg 安装失败（录制/训练会出问题）'
        Write-Info ("可手动：conda install -y -n {0} ffmpeg -c conda-forge" -f $EnvName)
    }
} else {
    Write-Info '跳过 ffmpeg（-SkipFfmpeg）'
}

# ================================================================== 4.5 git
if ($WithGit) {
    Enter-Step '安装 git（走 conda-forge）'

    # conda 装的 git 在 Windows 上落在 Library\bin 或 Scripts，两处都查
    $gitCands = @(
        (Join-Path $envPrefix 'Library\bin\git.exe'),
        (Join-Path $envPrefix 'Scripts\git.exe'),
        (Join-Path $envPrefix 'Library\mingw64\bin\git.exe')
    )
    $gitInEnv = $null
    foreach ($g in $gitCands) { if (Test-Path -LiteralPath $g) { $gitInEnv = $g; break } }

    if (-not $gitInEnv) {
        Write-Info 'conda install git（含依赖，走国内渠道降级）'
        Invoke-CondaStep -Verb @('install','-y','-n',$EnvName) -Packages @('git') -Label 'git' | Out-Null
        foreach ($g in $gitCands) { if (Test-Path -LiteralPath $g) { $gitInEnv = $g; break } }
    }

    if ($DryRun) {
        Write-Ok 'git 安装命令已打印（DryRun）'
    } elseif ($gitInEnv) {
        $gitVer = (& $gitInEnv --version 2>&1 | Out-String).Trim()
        Write-Ok "git 已就位：$gitInEnv"
        Write-Info $gitVer
        Write-Info "用法：conda activate $EnvName 之后直接敲 git"
        # 让后续步骤（比如回退到 git 源码路径）也能用上
        $env:Path = (Split-Path $gitInEnv -Parent) + ';' + $env:Path
    } else {
        Write-Err 'git 安装失败（conda-forge 上取不到 git 包）'
        Write-Info ("手动：conda install -n {0} git -c conda-forge" -f $EnvName)
    }
}

# ================================================================== 5. 源码
Enter-Step '获取 lerobot 源码'

function Test-GitRemote([string]$url) {
    <#  用 ls-remote 真探一次，比 ping 靠谱  #>
    if ($DryRun) { return $true }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $gitExe -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=25 ls-remote --heads $url 2>&1
    $ok = ($LASTEXITCODE -eq 0) -and ($out -match 'refs/heads')
    $ErrorActionPreference = $prevEap
    return $ok
}

function Get-LerobotFromPypi {
    <#
      兜底方案：github 全不通时，直接从 pip 镜像下 sdist（.tar.gz）解压。
      这条路不需要 git，也不需要翻墙 —— 但拿到的是发布版，不是 main 分支。
    #>
    $tarExe = (Get-Command tar.exe -ErrorAction SilentlyContinue).Source
    if (-not $tarExe) { $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe' }
    if (-not (Test-Path -LiteralPath $tarExe)) {
        Write-Err '系统里没有 tar.exe（Windows 10 1803 以下），无法解压 sdist'
        Write-Info '改用：手动下载 https://pypi.org/project/lerobot/#files 后解压到 -InstallDir'
        return $false
    }

    foreach ($m in $pipOrder) {
        $indexBase = [System.Uri]($m.Index.TrimEnd('/') + '/lerobot/')
        Write-Info "在 $($m.Name) 上找 sdist"

        if ($DryRun) {
            Write-Ok "（DryRun）会从 $($indexBase.AbsoluteUri) 取最高版本 tar.gz 解压到 $InstallDir"
            return $true
        }

        $page = (& $script:Curl -sS -m 40 -g $indexBase.AbsoluteUri 2>$null) -join "`n"
        if (-not $page -or $page -match '404 Not Found') {
            Write-Info '  这个镜像没有 lerobot 的 simple 页，换下一个'
            continue
        }

        # href 可能是相对路径（../../packages/...）也可能是绝对路径（files.pythonhosted.org）
        $hrefs = @([regex]::Matches($page, 'href="([^"#]+\.tar\.gz)(?:#[^"]*)?"') |
                   ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($hrefs.Count -eq 0) {
            Write-Info '  这个镜像上没找到 tar.gz，换下一个'
            continue
        }

        # 选版本：指定了就精确匹配，否则取最高
        $pick = $null
        $pickVer = $null
        foreach ($h in $hrefs) {
            $vm = [regex]::Match($h, 'lerobot-([0-9]+\.[0-9]+(?:\.[0-9]+)?)[^/]*\.tar\.gz')
            if (-not $vm.Success) { continue }
            if ($PypiVersion) {
                if ($vm.Groups[1].Value -eq $PypiVersion) {
                    $pick = $h
                    $pickVer = $vm.Groups[1].Value
                    break
                }
            } else {
                $v = [version]$vm.Groups[1].Value
                if (-not $pickVer -or $v -gt $pickVer) { $pickVer = $v; $pick = $h }
            }
        }
        if (-not $pick) {
            if ($PypiVersion) {
                Write-Warn2 "  该镜像上没有 $PypiVersion，换下一个"
                continue
            }
            Write-Info '  解析不到版本号，换下一个'
            continue
        }

        $absUrl = [System.Uri]::new($indexBase, $pick).AbsoluteUri
        $tmpRoot = Join-Path $env:TEMP ('lerobot-sdist-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $tgz = Join-Path $tmpRoot 'lerobot.tar.gz'
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

        Write-Info "下载 $absUrl"
        if ((Invoke-Download -Url $absUrl -OutFile $tgz -TimeoutSec 600) -ne 0) {
            Write-Warn2 "  下载失败，换下一个镜像"
            Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }
        $mb = [math]::Round((Get-Item -LiteralPath $tgz).Length / 1MB, 2)
        Write-Info "  已下载 $mb MB"

        if ((Invoke-Cmd -Exe $tarExe -ArgList @('-xzf',$tgz,'-C',$tmpRoot)) -ne 0) {
            Write-Warn2 '  解压失败，换下一个镜像'
            Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        $extracted = Get-ChildItem -LiteralPath $tmpRoot -Directory |
                     Where-Object { $_.Name -like 'lerobot-*' } | Select-Object -First 1
        if (-not $extracted -or -not (Test-Path -LiteralPath (Join-Path $extracted.FullName 'pyproject.toml'))) {
            Write-Warn2 '  解压结果不对（没有 pyproject.toml），换下一个镜像'
            Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        # 挪到目标目录
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $InstallDir) -Force | Out-Null
        Move-Item -LiteralPath $extracted.FullName -Destination $InstallDir -Force
        Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

        Write-Ok "sdist 就位：$InstallDir  (版本 $($pickVer)，来源 $($m.Name))"
        Write-Warn2 '注意：这是发布版，不是 GitHub main 分支；要最新代码请加 -Proxy 走 git'
        return $true
    }
    return $false
}

$pypiUsed = $false

if ($FromPypi) {
    Write-Info '-FromPypi：跳过 git，直接从 pip 镜像取 sdist'
    if (-not (Get-LerobotFromPypi)) {
        Write-Die '所有镜像上都拿不到 lerobot 的 sdist'
    }
    $pypiUsed = $true
} else {
    $isRepo = Test-Path -LiteralPath (Join-Path $InstallDir '.git')
    $gitOk = $false
    if ($isRepo) {
        Write-Ok "已存在 git 仓库：$InstallDir"
        Write-Info '拉取最新代码（--ff-only，冲突就跳过）'
        $code = Invoke-Cmd -Exe $gitExe -ArgList @('-C',$InstallDir,'pull','--ff-only')
        if ($code -ne 0) { Write-Warn2 'git pull 失败，继续用现有代码' }
        $gitOk = $true
    } elseif (Test-Path -LiteralPath $InstallDir) {
        Write-Die "$InstallDir 已存在但不是 git 仓库。换个 -InstallDir，或手工清空该目录"
    } else {
        foreach ($g in $script:GitUrls) {
            Write-Info "尝试 $($g.Name)"
            if (-not (Test-GitRemote $g.Url)) {
                Write-Info '  不通，换下一个'
                continue
            }
            $cloneArgs = @('clone')
            if (-not $FullHistory) { $cloneArgs += @('--depth','1') }
            $cloneArgs += @($g.Url, $InstallDir)
            $code = Invoke-Cmd -Exe $gitExe -ArgList $cloneArgs
            if ($DryRun) {
                Write-Ok "（DryRun）会用 $($g.Name) 克隆"
                $gitOk = $true
                break
            }
            if ($code -eq 0 -and (Test-Path -LiteralPath (Join-Path $InstallDir 'pyproject.toml'))) {
                Write-Ok "克隆成功（$($g.Name)）"
                $gitOk = $true
                break
            }
            Write-Warn2 "$($g.Name) 克隆失败，换下一个"
            if (Test-Path -LiteralPath $InstallDir) {
                Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $gitOk) {
        if ($NoPypiFallback) {
            Write-Die '所有 git 源都不通，且指定了 -NoPypiFallback。可以加 -Proxy，或去掉该开关让它走 PyPI 兜底'
        }
        Write-Warn2 '所有 git 源都不通 —— 启用 PyPI sdist 兜底（发布版，非 main 分支）'
        if (-not (Get-LerobotFromPypi)) {
            Write-Die 'PyPI 兜底也失败了。检查网络，或手动把源码放到 -InstallDir 后重跑'
        }
        $pypiUsed = $true
    }
}

$pyProject = Join-Path $InstallDir 'pyproject.toml'
if (-not $DryRun -and -not (Test-Path -LiteralPath $pyProject)) { Write-Die "源码不完整：缺 $pyProject" }

# 版本号
if (-not $DryRun) {
    $verLine = Select-String -LiteralPath $pyProject -Pattern '^version\s*=' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($verLine) { Write-Info ("源码版本 " + ($verLine.Line -replace '.*=\s*"?([^"]+)"?.*','$1')) }
}

# ================================================================== 6. 装 lerobot
Enter-Step '编辑模式安装 lerobot'

# extras 校验：拼错会被 pip 静默忽略成 warning，这里提前拦
$requested = $Extras -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($requested.Count -gt 0 -and (Test-Path -LiteralPath $pyProject)) {
    $toml = Get-Content -LiteralPath $pyProject -Raw -Encoding UTF8
    $m = [regex]::Match($toml, '(?s)\[project\.optional-dependencies\](.*?)\n\[')
    if ($m.Success) {
        $known = @([regex]::Matches($m.Groups[1].Value, '(?m)^([A-Za-z0-9_\-]+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        $bad = @($requested | Where-Object { $known -notcontains $_ })
        if ($bad.Count -gt 0) {
            Write-Warn2 "未知 extras：$($bad -join ', ')（会被 pip 忽略）"
            Write-Info "本版本可用的 extras：$($known -join ', ')"
            $requested = @($requested | Where-Object { $known -contains $_ })
        }
    }
}

$spec = '.[' + ($requested -join ',') + ']'
if ($requested.Count -eq 0) { $spec = '.' }
Write-Info "安装目标：$spec"

if (-not (Invoke-Pip -PipArgs @('install','-e',$spec,'--no-input','--no-warn-script-location') -WorkDir $InstallDir)) {
    Write-Err 'lerobot 安装失败'
    Write-Info "手动重试：`"$pyExe`" -m pip install -e `"$spec`" --index-url $($primaryPip.Index)"
} else {
    Write-Ok 'lerobot 安装完成'
}

# ================================================================== 7. HF 镜像
Enter-Step 'Hugging Face 下载源'

if (-not $NoHfMirror) {
    $hf = 'https://hf-mirror.com'
    if (Test-Url -Url ($hf + '/') -TimeoutSec 12) {
        if ($DryRun) {
            Write-Ok "HF_ENDPOINT = $hf（DryRun：不写环境变量）"
        } else {
            [Environment]::SetEnvironmentVariable('HF_ENDPOINT', $hf, 'User')
            $env:HF_ENDPOINT = $hf
            Write-Ok "HF_ENDPOINT = $hf（已写入用户环境变量，新终端生效）"
            Write-Info '模型/数据集下载会走国内镜像；要改回去：'
            Write-Info '  删除用户环境变量 HF_ENDPOINT 即可'
        }
    } else {
        Write-Warn2 'hf-mirror.com 不通，不改 HF_ENDPOINT'
    }
} else {
    Write-Info '跳过（-NoHfMirror）'
}

# ================================================================== 8. 汇总
Enter-Step '结果'

$checks = @()
$ffmpegInEnv = Test-Path -LiteralPath (Join-Path $envPrefix 'Library\bin\ffmpeg.exe')
$ffmpegLabel = '待确认'
if ($ffmpegInEnv) { $ffmpegLabel = '环境内' }
$sourceLabel = 'git'
if ($pypiUsed) { $sourceLabel = 'PyPI sdist（发布版）' }
if ($DryRun) {
    # DryRun 什么都没装，别让汇总看起来像失败
    $checks += @{ N = 'conda 环境';   V = "$EnvName（DryRun）";      Ok = $true }
    $checks += @{ N = 'pip 镜像';     V = $primaryPip.Name;          Ok = $true }
    $checks += @{ N = 'lerobot 源码'; V = "$InstallDir（DryRun）";   Ok = $true }
    $checks += @{ N = '源码来源';     V = $sourceLabel;              Ok = $true }
    $checks += @{ N = 'ffmpeg';       V = '将安装（DryRun）';        Ok = $true }
} else {
    $checks += @{ N = 'conda 环境';   V = $EnvName;            Ok = (Test-Path -LiteralPath $pyExe) }
    $checks += @{ N = 'pip 镜像';     V = $primaryPip.Name;    Ok = $true }
    $checks += @{ N = 'lerobot 源码'; V = $InstallDir;         Ok = (Test-Path -LiteralPath $pyProject) }
    $checks += @{ N = '源码来源';     V = $sourceLabel;        Ok = $true }
    $checks += @{ N = 'ffmpeg';       V = $ffmpegLabel;        Ok = $ffmpegInEnv }
}

foreach ($c in $checks) {
    if ($c.Ok) { Write-Ok "$($c.N): $($c.V)" } else { Write-Warn2 "$($c.N): $($c.V)" }
}

Write-Host ''
Write-Host '  下一步：' -ForegroundColor Cyan
Write-Host '    1) 打开新终端（让 HF_ENDPOINT 生效），然后：' -ForegroundColor Gray
Write-Host "         conda activate $EnvName" -ForegroundColor White
Write-Host '    2) 跑测试脚本确认环境完整：' -ForegroundColor Gray
Write-Host "         powershell -ExecutionPolicy Bypass -File .\test-lerobot.ps1 -EnvName $EnvName" -ForegroundColor White
Write-Host '    3) 接上机械臂后：lerobot-find-port' -ForegroundColor Gray
Write-Host ''

$script:TotalSw.Stop()
$mins = [int][math]::Floor($script:TotalSw.Elapsed.TotalSeconds / 60)
$secs = [int][math]::Floor($script:TotalSw.Elapsed.TotalSeconds % 60)
Write-Host ("  总用时 {0} 分 {1} 秒，共走了 {2} 步" -f $mins, $secs, $script:StepNow) -ForegroundColor Cyan

if ($script:Failures -gt 0) {
    Write-Host "  有 $($script:Failures) 项失败，见上面的 [FAIL]" -ForegroundColor Yellow
    exit 1
}
Write-Host '  安装流程结束。' -ForegroundColor Green
exit 0
