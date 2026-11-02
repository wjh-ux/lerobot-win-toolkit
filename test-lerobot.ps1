<#
.SYNOPSIS
    检查 Windows 上 LeRobot 环境是否完整可用（装完、或者出问题时跑）。

.DESCRIPTION
    分两组检查，默认只跑【软件环境】那一组：

    【软件环境】装完就该全 PASS
      1. conda 环境与 Python 版本
      2. pip 是否还能用（Windows 装 ffmpeg 后有可能坏掉）
      3. lerobot 是否已安装、版本、是否编辑模式安装
      4. 关键模块能否 import（机器人 / 主臂 / 飞特舵机 / 相机 / 数据集 / 策略）
      5. 命令行入口是否齐全（lerobot-find-port 等）
      6. ffmpeg 位置与编码器
      7. torch 与 CUDA
      8. Hugging Face 下载源连通性

    【硬件】（加 -Hardware 才跑）
      9.  串口枚举
      10. 标定文件
      11. 相机能否打开（带 25 秒硬超时，不会卡住）

    为什么要分开：没接机械臂的机器上，串口/标定/相机必然是 WARN，
    混在一起会让人以为"环境没装好"。装完想确认环境，只跑默认组就够了。

    不需要先 conda activate，脚本自己找环境里的 python.exe。

.PARAMETER EnvName
    conda 环境名，默认 lerobot。

.PARAMETER Hardware
    额外检查硬件：串口、标定文件、相机（相机有 25 秒硬超时）。
    没接机械臂的机器不用加这个参数。

.PARAMETER Full
    -Hardware 的旧名字，保留兼容。

.PARAMETER Json
    以 JSON 输出结果，方便别的脚本解析。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\test-lerobot.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\test-lerobot.ps1 -Hardware -EnvName lerobot
#>
[CmdletBinding()]
param(
    [string]$EnvName = 'lerobot',
    [switch]$Hardware,
    [switch]$Full,
    [switch]$Json
)

if ($Full) { $Hardware = $true }

$ErrorActionPreference = 'Continue'

$script:Results = @()

function Add-Result {
    param(
        [string]$Name,
        [ValidateSet('PASS','WARN','FAIL','SKIP')][string]$Status,
        [string]$Detail = ''
    )
    $script:Results += [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

function Write-Badge($r) {
    $color = 'Gray'
    switch ($r.Status) {
        'PASS' { $color = 'Green' }
        'WARN' { $color = 'Yellow' }
        'FAIL' { $color = 'Red' }
        'SKIP' { $color = 'DarkGray' }
    }
    $tag = '[' + $r.Status + ']'
    Write-Host ("  {0,-6} {1,-30} {2}" -f $tag, $r.Name, $r.Detail) -ForegroundColor $color
}

function Find-Conda {
    $c = Get-Command conda.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path $HOME 'miniforge3\Scripts\conda.exe'),
        (Join-Path $HOME 'miniconda3\Scripts\conda.exe'),
        (Join-Path $HOME 'anaconda3\Scripts\conda.exe'),
        'C:\ProgramData\miniforge3\Scripts\conda.exe',
        'C:\ProgramData\miniconda3\Scripts\conda.exe',
        'C:\ProgramData\Anaconda3\Scripts\conda.exe'
    )
    foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Get-EnvPrefix([string]$name) {
    $conda = Find-Conda
    if (-not $conda) { return $null }
    $raw = & $conda env list --json 2>$null | Out-String
    $start = $raw.IndexOf('{')
    if ($start -lt 0) { return $null }
    try { $obj = $raw.Substring($start) | ConvertFrom-Json } catch { return $null }
    foreach ($p in $obj.envs) {
        if ((Split-Path -Leaf $p) -eq $name) { return $p }
    }
    return $null
}

# ================================================================== 0. 环境
Write-Host ''
Write-Host '===== LeRobot 环境自检 =====' -ForegroundColor Cyan
Write-Host ''

# 与安装脚本一致：屏蔽用户级 site-packages，否则会把"借来的"模块误判为已装
$env:PYTHONNOUSERSITE = '1'

$envPrefix = Get-EnvPrefix $EnvName
if (-not $envPrefix) {
    Add-Result 'conda 环境' 'FAIL' "找不到环境 [$EnvName]"
    Write-Badge $script:Results[-1]
    Write-Host ''
    Write-Host '  先跑安装脚本：install-lerobot.ps1 -EnvName ' -NoNewline
    Write-Host $EnvName -ForegroundColor White
    Write-Host ''
    if ($Json) { $script:Results | ConvertTo-Json -Depth 3 }
    exit 1
}
Add-Result 'conda 环境' 'PASS' $envPrefix
Write-Badge $script:Results[-1]

$pyExe = Join-Path $envPrefix 'python.exe'
if (-not (Test-Path -LiteralPath $pyExe)) {
    Add-Result 'python.exe' 'FAIL' "缺 $pyExe"
    Write-Badge $script:Results[-1]
    exit 1
}

# 统一的跑 python 的小工具
# 注意：不要用 `python -c "..."`。PowerShell 5.1 向外部程序传参时会剥掉字符串里的双引号，
# 于是 print("%d.%d" % x) 变成 print(%d.%d % x) → SyntaxError。
# 改成写临时 .py 文件再执行，彻底避开引号和转义问题。
function Invoke-Py([string]$code) {
    $tmp = Join-Path $env:TEMP ('chk-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.py')
    try {
        [System.IO.File]::WriteAllText($tmp, $code, (New-Object System.Text.UTF8Encoding($false)))
        $out = & $pyExe $tmp 2>&1
        return @{ Out = ($out | Out-String).Trim(); Code = $LASTEXITCODE }
    } catch {
        return @{ Out = ('执行失败: ' + $_.Exception.Message); Code = 1 }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PyTimeout {
    <#  带硬超时的 python 调用（摄像头探测用）。
        没插摄像头时 OpenCV 的 DSHOW 枚举会长时间阻塞，没有超时就像整个脚本卡死。
        超时返回 Code=124。  #>
    param([string]$Code, [int]$TimeoutSec = 25)
    $tmp     = Join-Path $env:TEMP ('chk-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.py')
    $outFile = $tmp + '.out'
    $errFile = $tmp + '.err'
    try {
        [System.IO.File]::WriteAllText($tmp, $Code, (New-Object System.Text.UTF8Encoding($false)))
        $p = Start-Process -FilePath $pyExe -ArgumentList ('"' + $tmp + '"') `
                           -NoNewWindow -PassThru `
                           -RedirectStandardOutput $outFile `
                           -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return @{ Out = "超时（${TimeoutSec} 秒未返回）"; Code = 124 }
        }
        $so = ''
        $se = ''
        if (Test-Path -LiteralPath $outFile) { $so = Get-Content -LiteralPath $outFile -Raw }
        if (Test-Path -LiteralPath $errFile) { $se = Get-Content -LiteralPath $errFile -Raw }
        # Start-Process -PassThru 拿到的对象，ExitCode 有时是 $null，要先 Refresh
        $ec = 0
        try {
            $p.Refresh()
            if ($null -ne $p.ExitCode) { $ec = [int]$p.ExitCode }
        } catch { }
        return @{ Out = (("$so" + "`n" + "$se").Trim()); Code = $ec }
    } catch {
        return @{ Out = ('执行失败: ' + $_.Exception.Message); Code = 1 }
    } finally {
        Remove-Item $tmp, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ 1. Python
$r = Invoke-Py 'import sys;print("%d.%d.%d"%sys.version_info[:3])'
if ($r.Code -eq 0) {
    $v = [version](($r.Out -split '\.')[0..1] -join '.')
    if ($v -ge [version]'3.12') { Add-Result 'Python 版本' 'PASS' $r.Out }
    else { Add-Result 'Python 版本' 'WARN' "$($r.Out) （LeRobot 要求 >= 3.12）" }
} else {
    Add-Result 'Python 版本' 'FAIL' $r.Out
}
Write-Badge $script:Results[-1]

# ------------------------------------------------------------------ 2. pip
$r = Invoke-Py 'import pip;print(pip.__version__)'
if ($r.Code -eq 0) { Add-Result 'pip 可用' 'PASS' "pip $($r.Out)" }
else { Add-Result 'pip 可用' 'FAIL' 'pip 坏了（多半是 conda 装 ffmpeg 导致），用 --no-deps 重装 ffmpeg' }
Write-Badge $script:Results[-1]

# ------------------------------------------------------------------ 3. lerobot
$r = Invoke-Py 'import lerobot,os;print(lerobot.__version__);print(os.path.dirname(lerobot.__file__))'
if ($r.Code -eq 0) {
    $lines = $r.Out -split "`r?`n"
    $ver = $lines[0]
    $loc = $lines[-1]
    $mode = '已安装（副本）'
    if ($loc -match '\\src\\lerobot$') { $mode = '编辑模式（指向源码）' }
    Add-Result 'lerobot 已安装' 'PASS' "$ver  $mode"
    Write-Badge $script:Results[-1]
    Write-Host ("         {0} 位置：{1}" -f '', $loc) -ForegroundColor DarkGray
} else {
    Add-Result 'lerobot 已安装' 'FAIL' 'import lerobot 失败'
    Write-Badge $script:Results[-1]
    Write-Host ("         {0}" -f ($r.Out -split "`r?`n")[0]) -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ 4. 关键模块
$modules = [ordered]@{
    'robots.so_follower'         = '从臂（SO-100/101）'
    'teleoperators.so_leader'    = '主臂（SO-100/101）'
    'motors.feetech'             = '飞特舵机 SDK'
    'cameras.opencv'             = 'OpenCV 相机'
    'datasets'                   = '数据集'
    'policies'                   = '策略模型'
}
foreach ($k in $modules.Keys) {
    $name = 'lerobot.' + $k
    $r = Invoke-Py "import $name"
    if ($r.Code -eq 0) { Add-Result $modules[$k] 'PASS' $name }
    else {
        $msg = ($r.Out -split "`r?`n" | Where-Object { $_ -match 'Error|error' } | Select-Object -First 1)
        if (-not $msg) { $msg = 'import 失败' }
        Add-Result $modules[$k] 'FAIL' $msg
    }
    Write-Badge $script:Results[-1]
}

# ------------------------------------------------------------------ 5. CLI 入口
$cmds = @(
    'lerobot-find-port',
    'lerobot-setup-motors',
    'lerobot-calibrate',
    'lerobot-teleoperate',
    'lerobot-record',
    'lerobot-replay',
    'lerobot-train',
    'lerobot-find-cameras'
)
$scriptsDir = Join-Path $envPrefix 'Scripts'
$missing = @()
foreach ($c in $cmds) {
    $found = $false
    foreach ($ext in @('.exe','.bat','.cmd','-script.py')) {
        if (Test-Path -LiteralPath (Join-Path $scriptsDir ($c + $ext))) { $found = $true; break }
    }
    if (-not $found) { $missing += $c }
}
if ($missing.Count -eq 0) {
    Add-Result '命令行入口' 'PASS' "全部 $($cmds.Count) 个都在"
} else {
    Add-Result '命令行入口' 'WARN' ("缺: " + ($missing -join ', '))
}
Write-Badge $script:Results[-1]

# 确认入口不是"文件在但一跑就崩"。
# 不用 --help：lerobot-find-port 不理 --help，它会直接进交互流程然后因为拿不到输入而退出，
# 拿它的退出码判断会误伤。改为直接 import 入口模块，能加载就说明依赖链是通的。
$findPortExe = Join-Path $scriptsDir 'lerobot-find-port.exe'
if (Test-Path -LiteralPath $findPortExe) {
    $r = Invoke-Py @'
import importlib
m = importlib.import_module("lerobot.scripts.lerobot_find_port")
print("entry-ok" if hasattr(m, "main") else "no-main")
'@
    if ($r.Code -eq 0 -and $r.Out -match 'entry-ok') {
        Add-Result 'lerobot-find-port 可加载' 'PASS' '入口模块与依赖链正常'
    } else {
        Add-Result 'lerobot-find-port 可加载' 'FAIL' (($r.Out -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1) -as [string])
    }
    Write-Badge $script:Results[-1]
}

# ------------------------------------------------------------------ 6. ffmpeg
$ffInEnv = Join-Path $envPrefix 'Library\bin\ffmpeg.exe'
$ffOnPath = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source
if (Test-Path -LiteralPath $ffInEnv) {
    Add-Result 'ffmpeg 位置' 'PASS' $ffInEnv
    $enc = & $ffInEnv -hide_banner -encoders 2>&1 | Out-String
    if ($enc -match 'libx264|libsvtav1') {
        Add-Result 'ffmpeg 编码器' 'PASS' '有 h264/av1 编码器'
    } else {
        Add-Result 'ffmpeg 编码器' 'WARN' '没看到 libx264/libsvtav1，录制可能失败'
    }
} elseif ($ffOnPath) {
    Add-Result 'ffmpeg 位置' 'WARN' "在 PATH 上但不在环境内：$ffOnPath"
    Add-Result 'ffmpeg 编码器' 'SKIP' ''
} else {
    Add-Result 'ffmpeg 位置' 'FAIL' ("找不到 ffmpeg（conda install -n {0} ffmpeg -c conda-forge）" -f $EnvName)
    Add-Result 'ffmpeg 编码器' 'SKIP' ''
}
Write-Badge $script:Results[-2]
Write-Badge $script:Results[-1]

# ------------------------------------------------------------------ 7. torch / CUDA
$r = Invoke-Py 'import torch;print(torch.__version__);print(torch.cuda.is_available());print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "-")'
if ($r.Code -eq 0) {
    $l = $r.Out -split "`r?`n"
    if ($l[1] -eq 'True') {
        Add-Result 'PyTorch / CUDA' 'PASS' ("torch " + $l[0] + "   GPU: " + $l[2])
    } else {
        Add-Result 'PyTorch / CUDA' 'WARN' ("torch " + $l[0] + "   CUDA 不可用（只能 CPU）")
    }
} else {
    Add-Result 'PyTorch / CUDA' 'FAIL' 'import torch 失败'
}
Write-Badge $script:Results[-1]

# ------------------------------------------------------------------ 8. 串口
# 硬件项只在 -Hardware 时检查：没接机械臂的机器上这些必然是 WARN，
# 混在环境自检里只会把"环境好不好"这个判断搅浑。
if ($Hardware) {
    $r = Invoke-Py @'
import serial.tools.list_ports as lp
ps=list(lp.comports())
print(len(ps))
for p in ps:
    print(p.device+"|"+p.description)
'@
    if ($r.Code -eq 0) {
        $l = @($r.Out -split "`r?`n" | Where-Object { $_ })
        $n = [int]$l[0]
        if ($n -eq 0) {
            Add-Result '串口' 'WARN' '没有串口（机械臂没插？或驱动没装）'
        } else {
            Add-Result '串口' 'PASS' "$n 个"
            foreach ($line in $l[1..($l.Count-1)]) {
                $parts = $line -split '\|'
                Write-Host ("         {0}" -f ($parts[0] + '   ' + $parts[1])) -ForegroundColor DarkGray
            }
        }
    } else {
        Add-Result '串口' 'WARN' 'pyserial 不可用'
    }
    Write-Badge $script:Results[-1]
}

# ------------------------------------------------------------------ 9. 标定文件
if ($Hardware) {
    $calDir = Join-Path $HOME '.cache\huggingface\lerobot\calibration'
    if (Test-Path -LiteralPath $calDir) {
        $files = @(Get-ChildItem -LiteralPath $calDir -Recurse -Filter *.json -ErrorAction SilentlyContinue)
        if ($files.Count -gt 0) {
            Add-Result '标定文件' 'PASS' "$($files.Count) 个"
            foreach ($f in $files) {
                Write-Host ("         {0}" -f $f.FullName) -ForegroundColor DarkGray
            }
        } else {
            Add-Result '标定文件' 'WARN' '目录在但没有 json，还没做过标定'
        }
    } else {
        Add-Result '标定文件' 'WARN' '还没有标定过（lerobot-calibrate）'
    }
    Write-Badge $script:Results[-1]
}

# ------------------------------------------------------------------ 10. HF
$hf = $env:HF_ENDPOINT
$hfUser = [Environment]::GetEnvironmentVariable('HF_ENDPOINT','User')
if (-not $hf) { $hf = $hfUser }
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'

function Get-HfCode([string]$u) {
    <#  返回 HTTP 状态码字符串；连不上返回 '000'。
        注意：4xx 也说明主机可达（只是那个路径不存在），不能当成"不通"。  #>
    if (-not (Test-Path $curl)) { return 'nocurl' }
    $c = & $curl -sS -o NUL -w '%{http_code}' -m 25 -g $u 2>$null
    $c = ("$c").Trim()
    if (-not $c) { return '000' }
    return $c
}

# 用根路径探，又快又不会被某个不存在的模型 id 干扰
$mirrorCode = Get-HfCode 'https://hf-mirror.com/'
$mirrorOk = ($mirrorCode -match '^[1-4]\d\d$')

if ($mirrorOk) {
    $detail = "hf-mirror.com 可达 (HTTP $mirrorCode)"
    if ($hf -and $hf -match 'hf-mirror') { $detail += '，已配置为 HF_ENDPOINT' }
    Add-Result 'Hugging Face 源' 'PASS' $detail
} else {
    $oriCode = Get-HfCode 'https://huggingface.co/'
    if ($oriCode -match '^[1-4]\d\d$') {
        Add-Result 'Hugging Face 源' 'WARN' "镜像不通 (HTTP $mirrorCode) 但官方可达 (HTTP $oriCode)，建议取消 HF_ENDPOINT"
    } else {
        Add-Result 'Hugging Face 源' 'FAIL' "镜像 ($mirrorCode) 和官方 ($oriCode) 都不通，下载模型会失败"
    }
}
Write-Badge $script:Results[-1]

# ------------------------------------------------------------------ 11. 相机（硬件组）
if ($Hardware) {
    # OpenCV 会往 stderr 打一堆 VIDEOIO 警告，不能靠"有没有输出"判断。
    # 让它把结论写成 RESULT:... 一行，PowerShell 只认这个标记。
    # 用带硬超时的调用：没插摄像头时 DSHOW 枚举会长时间阻塞，没有超时就像卡死。
    Write-Host ''
    Write-Host '  正在探测相机（最多等 25 秒）...' -ForegroundColor DarkGray
    $r = Invoke-PyTimeout -TimeoutSec 25 -Code @'
import os
os.environ["OPENCV_LOG_LEVEL"] = "SILENT"
import cv2
try:
    cv2.setLogLevel(0)
except Exception:
    pass
found = []
for i in range(3):
    cap = cv2.VideoCapture(i, cv2.CAP_DSHOW)
    if cap.isOpened():
        ok, _ = cap.read()
        if ok:
            w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            found.append("%d:%dx%d" % (i, w, h))
    cap.release()
print("RESULT:" + (";".join(found) if found else "none"))
'@
    $camText = ''
    $mCam = [regex]::Match("$($r.Out)", 'RESULT:(.+)')
    if ($mCam.Success) { $camText = $mCam.Groups[1].Value.Trim() }

    if ($r.Code -eq 124) {
        Add-Result '相机' 'WARN' '探测超时（25 秒）——摄像头没插时常见，不影响其它项'
    } elseif ($r.Code -ne 0 -and -not $mCam.Success) {
        $why = ($r.Out -split "`r?`n" | Where-Object { $_ -and "$_".Trim() } | Select-Object -Last 1) -as [string]
        Add-Result '相机' 'WARN' ("相机探测失败: " + $why)
    } elseif ($camText -eq 'none' -or -not $camText) {
        Add-Result '相机' 'WARN' '没检测到可用相机（没插？或被别的程序占用）'
    } else {
        Add-Result '相机' 'PASS' $camText
    }
    Write-Badge $script:Results[-1]
}

# ================================================================== 汇总
$pass = @($script:Results | Where-Object Status -eq 'PASS').Count
$warn = @($script:Results | Where-Object Status -eq 'WARN').Count
$fail = @($script:Results | Where-Object Status -eq 'FAIL').Count

Write-Host ''
Write-Host ('-' * 66) -ForegroundColor DarkGray
Write-Host ("  通过 $pass   警告 $warn   失败 $fail") -ForegroundColor Cyan

if ($fail -gt 0) {
    Write-Host '  环境还不能用，先修 [FAIL] 项。' -ForegroundColor Red
} elseif ($warn -gt 0) {
    Write-Host '  核心功能已就绪，[WARN] 项按需处理（多半是没接硬件）。' -ForegroundColor Yellow
} else {
    Write-Host '  全部通过，可以接机械臂跑 lerobot-find-port 了。' -ForegroundColor Green
}

if ($fail -eq 0 -and $warn -le 1) {
    Write-Host ''
    Write-Host '  下一步（接上机械臂，先只插一根 USB）：' -ForegroundColor Gray
    Write-Host '    lerobot-find-port' -ForegroundColor White
    Write-Host '    lerobot-setup-motors --robot.type=so101_follower --robot.port=COMx' -ForegroundColor White
    Write-Host '    lerobot-calibrate    --robot.type=so101_follower --robot.port=COMx --robot.id=my_follower_arm' -ForegroundColor White
}
Write-Host ''

if ($Json) {
    $script:Results | ConvertTo-Json -Depth 3
}

if ($fail -gt 0) { exit 1 } else { exit 0 }
