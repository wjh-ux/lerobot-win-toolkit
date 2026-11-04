<#
.SYNOPSIS
    LeRobot 交互式工具箱：敲数字或字母就能跑对应命令。

.DESCRIPTION
    把 lerobot 的全部命令 + 安装/自检包成一个菜单。不需要 conda activate，
    脚本自己定位环境里的 exe。

    支持两种用法：
      1) 菜单模式：直接运行，按提示敲数字/字母
      2) 直达模式：把编号或字母当参数传进去，例如
             .\lerobot-menu.ps1 4          标定
             .\lerobot-menu.ps1 c          相机检测

.PARAMETER Item
    可选。菜单编号（0-9）或字母（c/v/i/m/h/q）。给了就直接执行那一项。

.PARAMETER EnvName
    conda 环境名，默认 lerobot。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\lerobot-menu.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\lerobot-menu.ps1 5
#>
[CmdletBinding()]
param(
    [string]$Item = '',
    [string]$EnvName = 'lerobot'
)

$ErrorActionPreference = 'Continue'
$env:PYTHONNOUSERSITE = '1'

$script:PyExe     = $null
$script:Eof = $false
$script:EnvPrefix = $null
$script:ScriptsDir = $null
$script:LastCode = 0

# ============================================================ 基础工具
function Find-Conda {
    $c = Get-Command conda.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path $HOME 'miniconda3\Scripts\conda.exe'),
        (Join-Path $HOME 'miniforge3\Scripts\conda.exe'),
        (Join-Path $HOME 'anaconda3\Scripts\conda.exe'),
        (Join-Path $env:LOCALAPPDATA 'miniconda3\Scripts\conda.exe'),
        (Join-Path $env:LOCALAPPDATA 'miniforge3\Scripts\conda.exe'),
        (Join-Path $env:ProgramData 'miniconda3\Scripts\conda.exe'),
        (Join-Path $env:ProgramData 'Anaconda3\Scripts\conda.exe')
    )
    foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
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

function Invoke-Py {
    <#  写临时 .py 再执行：避免 PS 5.1 吞掉 -c 字符串里的双引号  #>
    param([string]$Code)
    $tmp = Join-Path $env:TEMP ('lr-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.py')
    try {
        [System.IO.File]::WriteAllText($tmp, $Code, (New-Object System.Text.UTF8Encoding($false)))
        $out = & $script:PyExe $tmp 2>&1
        return @{ Out = ($out | Out-String).Trim(); Code = $LASTEXITCODE }
    } catch {
        return @{ Out = $_.Exception.Message; Code = 1 }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Read-Key([string]$Prompt = '请选择') {
    Write-Host ''
    Write-Host ("  $Prompt：" ) -NoNewline -ForegroundColor Yellow
    $raw = Read-Host
    # Read-Host 在 stdin 关闭（EOF）时返回 $null。
    # 不处理的话主循环会拿到空串，一直 continue，菜单无限刷屏。
    if ($null -eq $raw) { $script:Eof = $true; return '' }
    return $raw.Trim().ToLower()
}

function Read-Text([string]$Prompt, [string]$Default = '') {
    if ($Default) {
        Write-Host ("  $Prompt [回车=$Default]：") -NoNewline -ForegroundColor Yellow
    } else {
        Write-Host ("  $Prompt：") -NoNewline -ForegroundColor Yellow
    }
    $v = (Read-Host).Trim()
    if (-not $v) { return $Default }
    return $v
}

function Pause-Menu {
    Write-Host ''
    Write-Host '  按回车返回菜单...' -ForegroundColor DarkGray
    $null = Read-Host
}
function Assert-Env {
    <#  动作前统一检查环境是否就绪；没装就给出明确指引  #>
    if ($script:EnvPrefix -and $script:PyExe -and (Test-Path -LiteralPath $script:PyExe)) { return $true }
    Write-Host ''
    Write-Host "  找不到 conda 环境 [$EnvName]。" -ForegroundColor Red
    Write-Host '  请先选 [0] 安装；如果环境名不是 lerobot，用 -EnvName 指定' -ForegroundColor Gray
    Write-Host '  例如： .\lerobot-menu.ps1 -EnvName my_env' -ForegroundColor Gray
    return $false
}

# ============================================================ 串口
function Get-SerialPorts {
    $r = Invoke-Py @'
import serial.tools.list_ports as lp
ps = list(lp.comports())
if not ps:
    print("NONE")
else:
    for p in ps:
        print("PORT:" + str(p.device) + "|" + str(p.description))
'@
    $ports = @()
    foreach ($line in ("$($r.Out)" -split "`r?`n")) {
        $m = [regex]::Match($line, 'PORT:([^|]+)\|(.*)')
        if ($m.Success) {
            $ports += [pscustomobject]@{
                Device = $m.Groups[1].Value.Trim()
                Desc   = $m.Groups[2].Value.Trim()
            }
        }
    }
    return $ports
}

function Select-SerialPort([string]$Title = '选择串口') {
    $ports = Get-SerialPorts
    if ($ports.Count -eq 0) {
        Write-Host '  没检测到串口。' -ForegroundColor Yellow
        Write-Host '  检查：USB 线插好了吗？舵机电源开了吗？驱动装了吗？' -ForegroundColor Gray
        return (Read-Text "$Title（可手动输入，例如 COM3）")
    }
    Write-Host ''
    Write-Host "  检测到 $($ports.Count) 个串口：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $ports.Count; $i++) {
        Write-Host ("    [{0}] {1,-8} {2}" -f ($i + 1), $ports[$i].Device, $ports[$i].Desc) -ForegroundColor White
    }
    $sel = Read-Text "$Title（输入编号，直接回车=第 1 个）" '1'
    $idx = 0
    if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $ports.Count) {
        return $ports[$idx - 1].Device
    }
    # 用户直接输了 COM3 这种
    if ($sel -match '^COM\d+$') { return $sel }
    return $ports[0].Device
}

# ============================================================ 机型
function Select-RobotType([switch]$ForTeleop) {
    $items = @(
        @{ Key = '1'; Type = 'so101_follower'; Name = 'SO-101 从臂（最常见）' }
        @{ Key = '2'; Type = 'so101_leader';   Name = 'SO-101 主臂' }
        @{ Key = '3'; Type = 'so100_follower'; Name = 'SO-100 从臂' }
        @{ Key = '4'; Type = 'so100_leader';   Name = 'SO-100 主臂' }
    )
    if ($ForTeleop) {
        $items = @(
            @{ Key = '1'; Type = 'so101_leader';   Name = 'SO-101 主臂（最常见）' }
            @{ Key = '2'; Type = 'so100_leader';   Name = 'SO-100 主臂' }
            @{ Key = '3'; Type = 'gamepad';        Name = '手柄' }
            @{ Key = '4'; Type = 'keyboard';       Name = '键盘' }
        )
    }
    Write-Host ''
    Write-Host '  设备类型：' -ForegroundColor Cyan
    foreach ($it in $items) {
        Write-Host ("    [{0}] {1,-16} {2}" -f $it.Key, $it.Type, $it.Name) -ForegroundColor White
    }
    $sel = Read-Text '选择' '1'
    foreach ($it in $items) { if ($it.Key -eq $sel) { return $it.Type } }
    return $items[0].Type
}

# ============================================================ 执行
function Invoke-Lerobot {
    param([string]$Cmd, [string[]]$ArgList = @())
    $exe = Join-Path $script:ScriptsDir ($Cmd + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host "  找不到命令 $Cmd" -ForegroundColor Red
        Write-Host "  环境 $EnvName 里没装它，先跑 [0] 安装或 1 自检看看" -ForegroundColor Gray
        return
    }
    Write-Host ''
    Write-Host ('  执行：' + $Cmd + ' ' + ($ArgList -join ' ')) -ForegroundColor DarkCyan
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
    & $exe @ArgList
    $code = $LASTEXITCODE
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
    $script:LastCode = $code
    if ($code -eq 0) { Write-Host '  命令正常结束' -ForegroundColor Green }
    else { Write-Host "  命令退出码 $code（0 才是正常）" -ForegroundColor Yellow }
}

function Get-CalibrationRoot {
    # 与 lerobot 源码一致：HF_LEROBOT_CALIBRATION > HF_LEROBOT_HOME/calibration
    #                     > HF_HOME/lerobot/calibration > ~/.cache/huggingface/lerobot/calibration
    if ($env:HF_LEROBOT_CALIBRATION) { return $env:HF_LEROBOT_CALIBRATION }
    if ($env:HF_LEROBOT_HOME) { return (Join-Path $env:HF_LEROBOT_HOME 'calibration') }
    if ($env:HF_HOME) { return (Join-Path (Join-Path $env:HF_HOME 'lerobot') 'calibration') }
    return (Join-Path $HOME '.cache\huggingface\lerobot\calibration')
}

function Get-CalibrationFiles {
    $dir = Get-CalibrationRoot
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem $dir -Recurse -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object FullName)
}

function Get-CalibrationList {
    return @(Get-CalibrationFiles | ForEach-Object { $_.BaseName } | Select-Object -Unique)
}

function Select-RobotId([string]$Kind = 'robot', [string]$Default = '') {
    $existing = Get-CalibrationList
    if ($existing.Count -gt 0) {
        Write-Host ''
        Write-Host '  已有标定的 id：' -ForegroundColor Cyan
        for ($i = 0; $i -lt $existing.Count; $i++) {
            Write-Host ("    [{0}] {1}" -f ($i + 1), $existing[$i]) -ForegroundColor White
        }
        $sel = Read-Text '选择已有 id，或直接输入新名字' '1'
        $idx = 0
        if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $existing.Count) {
            return $existing[$idx - 1]
        }
        if ($sel) { return $sel }
    }
    if (-not $Default) {
        if ($Kind -eq 'teleop') { $Default = 'my_leader_arm' } else { $Default = 'my_follower_arm' }
    }
    return (Read-Text "给这个$Kind 起个名字" $Default)
}

# ============================================================ 菜单
function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor Cyan
    Write-Host '            LeRobot 工具箱 - 敲数字或字母即可' -ForegroundColor Cyan
    Write-Host '  ================================================================' -ForegroundColor Cyan

    if ($script:EnvPrefix) {
        Write-Host "  环境：$EnvName  ->  $($script:EnvPrefix)" -ForegroundColor DarkGray
    } else {
        Write-Host "  环境：$EnvName  ->  未安装（请先选 0）" -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '   环境' -ForegroundColor DarkGray
    Write-Host '    [0] 安装 / 修复环境       install-lerobot.ps1' -ForegroundColor White
    Write-Host '    [1] 软件环境自检          test-lerobot.ps1' -ForegroundColor White
    Write-Host '    [w] 硬件检查（串口/相机/标定）' -ForegroundColor White
    Write-Host ''
    Write-Host '   机械臂准备（按顺序做一次）' -ForegroundColor DarkGray
    Write-Host '    [2] 查找串口              lerobot-find-port' -ForegroundColor White
    Write-Host '    [3] 设置电机 ID           lerobot-setup-motors' -ForegroundColor White
    Write-Host '    [4] 标定机械臂            lerobot-calibrate' -ForegroundColor White
    Write-Host '    [r] 校准管理（删除/重标定）' -ForegroundColor White
    Write-Host '    [s] 安装 / 更新舵机调试工具（Seeed 图形界面）' -ForegroundColor White
    Write-Host '    [o] 打开舵机调试工具' -ForegroundColor White
    Write-Host ''
    Write-Host '   日常使用' -ForegroundColor DarkGray
    Write-Host '    [5] 遥操作                lerobot-teleoperate' -ForegroundColor White
    Write-Host '    [6] 录制数据集            lerobot-record' -ForegroundColor White
    Write-Host '    [7] 训练策略              lerobot-train' -ForegroundColor White
    Write-Host '    [8] 推理 / 跑策略         lerobot-rollout' -ForegroundColor White
    Write-Host '    [9] 回放数据集            lerobot-replay' -ForegroundColor White
    Write-Host ''
    Write-Host '   其他' -ForegroundColor DarkGray
    Write-Host '    [c] 相机检测              lerobot-find-cameras' -ForegroundColor White
    Write-Host '    [v] 数据集工具（删/拆/合并/转视频/可视化）' -ForegroundColor White
    Write-Host '    [i] 环境详情 / 标定文件' -ForegroundColor White
    Write-Host '    [m] 设置 HuggingFace 镜像' -ForegroundColor White
    Write-Host '    [h] 命令速查              [q] 退出' -ForegroundColor White
    Write-Host '    [t] 打开 LeRobot 终端（环境已激活，可自由敲命令）' -ForegroundColor White
    Write-Host '    [x] 高级选项（其余 8 个命令）' -ForegroundColor White
    Write-Host ''
}

# ============================================================ 各项动作
function Action-Install {
    $here = $PSScriptRoot
    $inst = Join-Path $here 'install-lerobot.ps1'
    if (-not (Test-Path $inst)) {
        Write-Host "  找不到 $inst" -ForegroundColor Red
        Write-Host '  请把 install-lerobot.ps1 和本脚本放在同一目录' -ForegroundColor Gray
        return
    }
    Write-Host ''
    Write-Host '  安装会用 -FromPypi -AutoInstallPrereqs -WithGit（不依赖 GitHub）' -ForegroundColor Gray
    $ok = Read-Key '确认开始？(y/n)'
    if ($ok -ne 'y') { Write-Host '  已取消' -ForegroundColor Gray; return }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $inst -FromPypi -AutoInstallPrereqs -WithGit
    $script:EnvPrefix = Get-EnvPrefix $EnvName
    if ($script:EnvPrefix) { $script:PyExe = Join-Path $script:EnvPrefix 'python.exe'; $script:ScriptsDir = Join-Path $script:EnvPrefix 'Scripts' }
}

function Action-Test {
    $here = $PSScriptRoot
    $t = Join-Path $here 'test-lerobot.ps1'
    if (-not (Test-Path $t)) { Write-Host "  找不到 $t" -ForegroundColor Red; return }
    Write-Host ''
    Write-Host '  正在检查软件环境（约 5-15 秒）...' -ForegroundColor Yellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File $t -EnvName $EnvName
}

function Action-HardwareCheck {
    $here = $PSScriptRoot
    $t = Join-Path $here 'test-lerobot.ps1'
    if (-not (Test-Path $t)) { Write-Host "  找不到 $t" -ForegroundColor Red; return }
    Write-Host ''
    Write-Host '  检查硬件：串口 / 标定文件 / 相机' -ForegroundColor Yellow
    Write-Host '  没接机械臂或摄像头时这些项会是 WARN，属正常。' -ForegroundColor Gray
    Write-Host '  相机探测最多等 25 秒，不会卡死。' -ForegroundColor Gray
    & powershell -NoProfile -ExecutionPolicy Bypass -File $t -EnvName $EnvName -Hardware
}

function Action-FindPort {
    if (-not (Assert-Env)) { return }
    Invoke-Lerobot 'lerobot-find-port'
}

function Action-SetupMotors {
    if (-not (Assert-Env)) { return }
    $isTeleop = (Read-Key '这是主臂(leader)吗？(y=主臂 / n=从臂)') -eq 'y'
    $type = Select-RobotType -ForTeleop:$isTeleop
    $port = Select-SerialPort '接哪个串口'
    $side = 'robot'
    if ($isTeleop) { $side = 'teleop' }
    Invoke-Lerobot 'lerobot-setup-motors' @("--$side.type=$type", "--$side.port=$port")
}

function Action-Calibrate {
    if (-not (Assert-Env)) { return }
    $isTeleop = (Read-Key '标定主臂(leader)？(y=主臂 / n=从臂)') -eq 'y'
    $type = Select-RobotType -ForTeleop:$isTeleop
    $port = Select-SerialPort '接哪个串口'
    $side = 'robot'
    if ($isTeleop) { $side = 'teleop' }
    $id = Select-RobotId -Kind $side
    Write-Host ''
    Write-Host '  标定步骤：1) 把各关节摆到行程中间 2) 回车 3) 每个关节走完整行程' -ForegroundColor Yellow
    Invoke-Lerobot 'lerobot-calibrate' @("--$side.type=$type", "--$side.port=$port", "--$side.id=$id")
}

# 标定不好（抖动、漂移、动作范围不对）时，删掉校准文件重来
function Action-CalibrationManager {
    $root = Get-CalibrationRoot
    Write-Host ''
    Write-Host '=== 校准管理 ===' -ForegroundColor Cyan
    Write-Host "  校准目录：$root" -ForegroundColor DarkGray
    if ($env:HF_LEROBOT_CALIBRATION) { Write-Host '  （来自 HF_LEROBOT_CALIBRATION）' -ForegroundColor DarkGray }
    elseif ($env:HF_LEROBOT_HOME)    { Write-Host '  （来自 HF_LEROBOT_HOME）' -ForegroundColor DarkGray }
    elseif ($env:HF_HOME)            { Write-Host '  （来自 HF_HOME）' -ForegroundColor DarkGray }
    Write-Host ''

    $files = @(Get-CalibrationFiles)
    if ($files.Count -eq 0) {
        Write-Host '  还没有校准文件' -ForegroundColor Yellow
        Write-Host '  接上机械臂后用 [4] 标定' -ForegroundColor Gray
        return
    }

    Write-Host '  现有校准文件：' -ForegroundColor White
    for ($i = 0; $i -lt $files.Count; $i++) {
        $rel = $files[$i].FullName.Substring($root.Length).TrimStart('\', '/')
        Write-Host ("    [{0}] {1,-44} {2,6} B  {3}" -f ($i + 1), $rel, $files[$i].Length,
                                                  $files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    }

    Write-Host ''
    Write-Host '  校准不好就删掉重来。' -ForegroundColor Gray
    Write-Host '    [1] 删除全部（整个目录改名为 .bak-时间戳，可还原）' -ForegroundColor White
    Write-Host '    [2] 只删指定的一个' -ForegroundColor White
    Write-Host '    [3] 只备份不删' -ForegroundColor White
    Write-Host '    [4] 删除后接着重新标定' -ForegroundColor White
    Write-Host '    [0] 返回' -ForegroundColor White

    $k = Read-Text '选择' '0'
    $bak = "$root.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')

    switch ($k) {
        '1' {
            Write-Host ''
            Write-Host '  整个校准目录会被改名成备份，效果等于清空。' -ForegroundColor Yellow
            if ((Read-Text '确认删除全部校准？(y/N)' 'n') -notmatch '^[yY]') { Write-Host '  已取消' -ForegroundColor Gray; return }
            try {
                Move-Item -LiteralPath $root -Destination $bak -ErrorAction Stop
                Write-Host "  已备份并清空：$bak" -ForegroundColor Green
                Write-Host "  要还原就把该目录改回 $root" -ForegroundColor Gray
                Write-Host '  接下来用 [4] 重新标定' -ForegroundColor Gray
            } catch { Write-Host "  操作失败：$($_.Exception.Message)" -ForegroundColor Red }
        }
        '2' {
            $pick = Read-Text '要删第几个' '1'
            $idx = 0
            if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $files.Count) {
                Write-Host '  序号不对' -ForegroundColor Yellow; return
            }
            $target = $files[$idx - 1]
            Write-Host ''
            Write-Host ("  将要删除：" + $target.FullName.Substring($root.Length).TrimStart('\', '/')) -ForegroundColor Yellow
            if ((Read-Text '确认删除？(y/N)' 'n') -notmatch '^[yY]') { Write-Host '  已取消' -ForegroundColor Gray; return }
            try {
                Remove-Item -LiteralPath $target.FullName -Force -ErrorAction Stop
                Write-Host '  已删除，可用 [4] 重新标定' -ForegroundColor Green
            } catch { Write-Host "  删除失败：$($_.Exception.Message)" -ForegroundColor Red }
        }
        '3' {
            try {
                Copy-Item -LiteralPath $root -Destination $bak -Recurse -Force -ErrorAction Stop
                Write-Host "  已备份到：$bak" -ForegroundColor Green
            } catch { Write-Host "  备份失败：$($_.Exception.Message)" -ForegroundColor Red }
        }
        '4' {
            if ((Read-Text '删除全部并重新标定？(y/N)' 'n') -notmatch '^[yY]') { Write-Host '  已取消' -ForegroundColor Gray; return }
            try {
                Move-Item -LiteralPath $root -Destination $bak -ErrorAction Stop
                Write-Host "  已备份并清空：$bak" -ForegroundColor Green
                Action-Calibrate
            } catch { Write-Host "  操作失败：$($_.Exception.Message)" -ForegroundColor Red }
        }
        default { return }
    }
}

function Action-Teleoperate {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    $fType = Select-RobotType
    $fPort = Select-SerialPort '从臂串口'
    $fId = Select-RobotId -Kind 'robot' -Default 'my_follower_arm'
    $lType = Select-RobotType -ForTeleop
    $lPort = Select-SerialPort '主臂串口'
    $lId = Select-RobotId -Kind 'teleop' -Default 'my_leader_arm'
    $args = @(
        "--robot.type=$fType", "--robot.port=$fPort", "--robot.id=$fId",
        "--teleop.type=$lType", "--teleop.port=$lPort", "--teleop.id=$lId"
    )
    $show = Read-Key '要显示画面吗？(y/n)'
    if ($show -eq 'y') { $args += '--display_data=true' }
    Invoke-Lerobot 'lerobot-teleoperate' $args
}

function Action-Record {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    $fType = Select-RobotType
    $fPort = Select-SerialPort '从臂串口'
    $fId = Select-RobotId -Kind 'robot' -Default 'my_follower_arm'
    $lType = Select-RobotType -ForTeleop
    $lPort = Select-SerialPort '主臂串口'
    $lId = Select-RobotId -Kind 'teleop' -Default 'my_leader_arm'

    $user = $env:HF_USER
    if (-not $user) { $user = Read-Text '你的 HuggingFace 用户名（HF_USER）' '' }
    if (-not $user) { Write-Host '  没有用户名，数据集没法命名' -ForegroundColor Red; return }

    $task = Read-Text '任务描述（例如: put the red brick in a bowl）' 'put the red brick in a bowl'
    $name = Read-Text '数据集名字' 'so101_dataset'
    $eps = Read-Text '录几回合' '30'

    $args = @(
        "--robot.type=$fType", "--robot.port=$fPort", "--robot.id=$fId",
        "--teleop.type=$lType", "--teleop.port=$lPort", "--teleop.id=$lId",
        "--dataset.repo_id=$user/$name",
        "--dataset.num_episodes=$eps",
        "--dataset.single_task=$task",
        '--dataset.streaming_encoding=true',
        '--display_data=true'
    )

    $withCam = Read-Key '接摄像头了吗？(y/n)'
    if ($withCam -eq 'y') {
        $top = Read-Text '环境相机编号（通常 0 或 1）' '1'
        $wrist = Read-Text '腕部相机编号' '0'
        $cam = '{ top: {type: opencv, index_or_path: ' + $top + ', width: 640, height: 480, fps: 30}, wrist: {type: opencv, index_or_path: ' + $wrist + ', width: 640, height: 480, fps: 30} }'
        $args += "--robot.cameras=$cam"
    }

    Write-Host ''
    Write-Host '  录制中的键盘操作：' -ForegroundColor Yellow
    Write-Host '    右方向键 / n  = 保存这一回合，录下一回合' -ForegroundColor Gray
    Write-Host '    左方向键 / r  = 丢掉这一回合重录' -ForegroundColor Gray
    Write-Host '    ESC / q       = 结束并上传' -ForegroundColor Gray
    Invoke-Lerobot 'lerobot-record' $args
}

function Action-Train {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    $user = $env:HF_USER
    if (-not $user) { $user = Read-Text '你的 HuggingFace 用户名（HF_USER）' '' }
    $ds = Read-Text '数据集 repo_id（用户名/数据集名）' "$user/so101_dataset"
    Write-Host ''
    Write-Host '  策略类型：' -ForegroundColor Cyan
    Write-Host '    [1] act        （入门首选，小数据也能跑）' -ForegroundColor White
    Write-Host '    [2] diffusion' -ForegroundColor White
    Write-Host '    [3] smolvla' -ForegroundColor White
    Write-Host '    [4] pi0' -ForegroundColor White
    Write-Host '    [5] pi05' -ForegroundColor White
    $sel = Read-Text '选择' '1'
    $pol = 'act'
    switch ($sel) {
        '2' { $pol = 'diffusion' }
        '3' { $pol = 'smolvla' }
        '4' { $pol = 'pi0' }
        '5' { $pol = 'pi05' }
    }
    $steps = Read-Text '训练步数' '20000'
    $dev = Read-Text '设备（cuda / cpu）' 'cuda'
    $tag = Read-Text '本次训练的名字' ("${pol}_so101")
    $args = @(
        "--dataset.repo_id=$ds",
        "--policy.type=$pol",
        "--policy.device=$dev",
        "--policy.repo_id=$user/$tag",
        "--output_dir=outputs/train/$tag",
        "--job_name=$tag",
        "--steps=$steps"
    )
    Invoke-Lerobot 'lerobot-train' $args
}

function Action-Rollout {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    $policy = Read-Text '策略路径或 repo_id（例如 你的用户名/policy_test）' ''
    if (-not $policy) { Write-Host '  需要先有训练好的策略' -ForegroundColor Red; return }
    $fType = Select-RobotType
    $fPort = Select-SerialPort '从臂串口'
    $fId = Select-RobotId -Kind 'robot' -Default 'my_follower_arm'
    $task = Read-Text '任务描述（要和录制时一致）' 'put the red brick in a bowl'
    $dur = Read-Text '跑多少秒' '60'
    $args = @(
        '--strategy.type=base',
        "--policy.path=$policy",
        "--robot.type=$fType", "--robot.port=$fPort", "--robot.id=$fId",
        "--task=$task", "--duration=$dur"
    )
    $exe = Join-Path $script:ScriptsDir 'lerobot-rollout.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host ''
        Write-Host '  lerobot-rollout 不存在（0.5.x 及更早没有这个命令）' -ForegroundColor Yellow
        Write-Host '  改用 lerobot-record 做推理，参数格式不同，请参考文档' -ForegroundColor Gray
        return
    }
    Invoke-Lerobot 'lerobot-rollout' $args
}

function Action-Replay {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    $user = $env:HF_USER
    if (-not $user) { $user = Read-Text '你的 HuggingFace 用户名（HF_USER）' '' }
    $ds = Read-Text '数据集 repo_id' "$user/so101_dataset"
    $ep = Read-Text '回放第几回合（从 0 开始）' '0'
    $fType = Select-RobotType
    $fPort = Select-SerialPort '从臂串口'
    $fId = Select-RobotId -Kind 'robot' -Default 'my_follower_arm'
    Invoke-Lerobot 'lerobot-replay' @(
        "--dataset.repo_id=$ds", "--dataset.episode=$ep",
        "--robot.type=$fType", "--robot.port=$fPort", "--robot.id=$fId"
    )
}

function Action-Cameras {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    Write-Host '  会打开本机摄像头预览并报出编号' -ForegroundColor Gray
    $exe = Join-Path $script:ScriptsDir 'lerobot-find-cameras.exe'
    if (Test-Path -LiteralPath $exe) {
        & $exe opencv
    } else {
        Write-Host '  找不到 lerobot-find-cameras' -ForegroundColor Red
    }
}

function Action-Viz {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    $user = $env:HF_USER
    if (-not $user) { $user = Read-Text '你的 HuggingFace 用户名（HF_USER）' '' }
    $ds = Read-Text '数据集 repo_id' "$user/so101_dataset"
    $ep = Read-Text '看第几回合' '0'
    Invoke-Lerobot 'lerobot-dataset-viz' @("--repo-id=$ds", "--episode-index=$ep")
}

function Action-Info {
    if (-not (Assert-Env)) { return }
    Write-Host ''
    Write-Host '  === 环境 ===' -ForegroundColor Cyan
    Write-Host "    Python : $(& $script:PyExe --version 2>&1)"
    $lv = Invoke-Py 'import lerobot;print(lerobot.__version__)'
    Write-Host "    lerobot: $($lv.Out)"
    Write-Host "    路径   : $($script:EnvPrefix)"
    Write-Host ''
    Write-Host '  === 关键包 ===' -ForegroundColor Cyan
    $pk = Invoke-Py @'
import importlib.metadata as md
for n in ["torch","torchvision","numpy","opencv-python-headless","feetech-servo-sdk","datasets","accelerate"]:
    try:
        print("    %-24s %s" % (n, md.version(n)))
    except Exception:
        print("    %-24s (未安装)" % n)
'@
    Write-Host $pk.Out
    Write-Host ''
    Write-Host '  === 标定文件 ===' -ForegroundColor Cyan
    $cals = Get-CalibrationList
    if ($cals.Count -eq 0) {
        Write-Host '    （还没有，跑 [4] 标定）' -ForegroundColor Gray
    } else {
        $dir = Get-CalibrationRoot
        Get-ChildItem $dir -Recurse -Filter *.json | ForEach-Object {
            Write-Host ("    {0}" -f $_.FullName) -ForegroundColor White
        }
    }
    Write-Host ''
    Write-Host '  === HF 设置 ===' -ForegroundColor Cyan
    $hf = [Environment]::GetEnvironmentVariable('HF_ENDPOINT','User')
    if ($hf) { Write-Host "    HF_ENDPOINT = $hf" } else { Write-Host '    HF_ENDPOINT 未设置（直连 huggingface.co）' -ForegroundColor Gray }
    $hu = $env:HF_USER
    if ($hu) { Write-Host "    HF_USER     = $hu" } else { Write-Host '    HF_USER     未设置（录制数据集时需要）' -ForegroundColor Gray }
}

function Action-Mirror {
    Write-Host ''
    $cur = [Environment]::GetEnvironmentVariable('HF_ENDPOINT','User')
    if ($cur) { Write-Host "  当前：$cur" } else { Write-Host '  当前：未设置（直连官方）' }
    Write-Host ''
    Write-Host '    [1] 使用国内镜像 hf-mirror.com（推荐国内）' -ForegroundColor White
    Write-Host '    [2] 取消，直连官方 huggingface.co' -ForegroundColor White
    $sel = Read-Key '选择' '1'
    if ($sel -eq '2') {
        [Environment]::SetEnvironmentVariable('HF_ENDPOINT', $null, 'User')
        $env:HF_ENDPOINT = $null
        Write-Host '  已取消 HF_ENDPOINT，新终端生效' -ForegroundColor Green
    } else {
        [Environment]::SetEnvironmentVariable('HF_ENDPOINT', 'https://hf-mirror.com', 'User')
        $env:HF_ENDPOINT = 'https://hf-mirror.com'
        Write-Host '  已设置为 https://hf-mirror.com，新终端生效' -ForegroundColor Green
    }
}

function Action-Help {
    Write-Host ''
    Write-Host '  === LeRobot 全部命令 ===' -ForegroundColor Cyan
    $cmds = @(
        'lerobot-find-port', 'lerobot-setup-motors', 'lerobot-calibrate',
        'lerobot-teleoperate', 'lerobot-record', 'lerobot-replay',
        'lerobot-train', 'lerobot-eval', 'lerobot-rollout',
        'lerobot-find-cameras', 'lerobot-dataset-viz', 'lerobot-imgtransform-viz',
        'lerobot-info', 'lerobot-edit-dataset', 'lerobot-annotate',
        'lerobot-find-joint-limits', 'lerobot-setup-can', 'lerobot-build-mp4-sidecar',
        'lerobot-convert-dcp', 'lerobot-train-tokenizer', 'lerobot-policy-server'
    )
    $hasEnv = [bool]($script:ScriptsDir -and (Test-Path -LiteralPath $script:ScriptsDir))
    foreach ($c in $cmds) {
        $mark = '  '
        $color = 'DarkGray'
        if ($hasEnv) {
            $exe = Join-Path $script:ScriptsDir ($c + '.exe')
            if (Test-Path -LiteralPath $exe) { $mark = 'OK'; $color = 'White' }
        }
        Write-Host ("    [{0}] {1}" -f $mark, $c) -ForegroundColor $color
    }
    if (-not $hasEnv) {
        Write-Host ''
        Write-Host '  （环境还没装，所以上面都没标 OK）' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  查某个命令的全部参数：' -ForegroundColor Gray
    Write-Host '    lerobot-<命令> --help' -ForegroundColor White
    Write-Host ''
    Write-Host '  在任意命令后加 --help 都能看到 --robot.type / --robot.port 这些参数' -ForegroundColor Gray
}

# ============================================================ 数据集工具
# 对应 Seeed《SO-Arm 数据集工具》：全是 lerobot-edit-dataset 的不同 operation。
# 参数命名注意：edit-dataset 用下划线 --repo_id / --new_repo_id；
#               dataset-viz 用连字符 --repo-id。两者不能混。
function Get-DatasetRepoDefault {
    if ($env:HF_USER) { return "$env:HF_USER/so101_dataset" }
    return 'so101_dataset'
}

function Read-DatasetRepo {
    return (Read-Text '数据集 repo_id（用户/名字）' (Get-DatasetRepoDefault))
}

function Action-DatasetTool {
    if (-not (Assert-Env)) { return }
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ====== 数据集工具（lerobot-edit-dataset）======' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    [1] 删除剧集         delete_episodes' -ForegroundColor White
        Write-Host '    [2] 拆分数据集       split' -ForegroundColor White
        Write-Host '    [3] 合并数据集       merge' -ForegroundColor White
        Write-Host '    [4] 移除特征         remove_feature（如去掉桌面相机）' -ForegroundColor White
        Write-Host '    [5] 图像转视频       convert_image_to_video（省空间）' -ForegroundColor White
        Write-Host '    [6] 可视化（本地）   lerobot-dataset-viz' -ForegroundColor White
        Write-Host '    [7] 在线可视化       HuggingFace Space（打印网址）' -ForegroundColor White
        Write-Host '    [8] 上传到 HuggingFace' -ForegroundColor White
        Write-Host ''
        Write-Host '    [0] 返回' -ForegroundColor White
        Write-Host ''
        Write-Host '  提示：新版数据集是压缩存的，操作比较慢，终端会有进度条；卡住就按回车刷一下。' -ForegroundColor DarkGray

        $k = Read-Key '请输入'
        $ds = ''; $idx = ''; $newid = ''
        switch ($k) {
            '1' {
                Write-Host ''
                Write-Host '=== 删除剧集 ===' -ForegroundColor Cyan
                $ds = Read-DatasetRepo
                if (-not $ds) { break }
                $idx = Read-Text '要删哪些剧集（逗号分隔，如 0,2,5）' ''
                if (-not $idx) { Write-Host '  没填剧集号' -ForegroundColor Yellow; break }
                Write-Host ''
                Write-Host '    [1] 直接改原数据集' -ForegroundColor White
                Write-Host '    [2] 存成新数据集（不动原数据，推荐）' -ForegroundColor White
                $mode = Read-Text '选择' '2'
                $a = @("--repo_id=$ds", '--operation.type=delete_episodes', "--operation.episode_indices=[$idx]")
                if ($mode -eq '2') {
                    $newid = Read-Text '新数据集 repo_id' "$($ds)_deleted"
                    $a += "--new_repo_id=$newid"
                }
                Invoke-Lerobot 'lerobot-edit-dataset' $a
            }
            '2' {
                Write-Host ''
                Write-Host '=== 拆分数据集 ===' -ForegroundColor Cyan
                $ds = Read-DatasetRepo
                if (-not $ds) { break }
                Write-Host '    [1] 按比例拆（如 8:2）' -ForegroundColor White
                Write-Host '    [2] 按剧集编号拆' -ForegroundColor White
                $how = Read-Text '选择' '1'
                if ($how -eq '2') {
                    $splits = Read-Text '按剧集编号，JSON 形如 {"task1":[0,1,2],"task2":[3,4]}' ''
                } else {
                    $splits = Read-Text '按比例，JSON 形如 {"train":0.8,"val":0.2}' '{"train":0.8,"val":0.2}'
                }
                if (-not $splits) { Write-Host '  没填拆分规则' -ForegroundColor Yellow; break }
                Invoke-Lerobot 'lerobot-edit-dataset' @("--repo_id=$ds", '--operation.type=split', "--operation.splits=$splits")
            }
            '3' {
                Write-Host ''
                Write-Host '=== 合并数据集 ===' -ForegroundColor Cyan
                $srcs = Read-Text '要合并哪些（JSON 列表，形如 ["用户/a","用户/b"]）' ''
                if (-not $srcs) { Write-Host '  没填源数据集' -ForegroundColor Yellow; break }
                $newid = Read-Text '合并后的新 repo_id' "$(Get-DatasetRepoDefault)_merged"
                Invoke-Lerobot 'lerobot-edit-dataset' @("--repo_id=$newid", '--operation.type=merge', "--operation.repo_ids=$srcs")
            }
            '4' {
                Write-Host ''
                Write-Host '=== 移除特征 ===' -ForegroundColor Cyan
                $ds = Read-DatasetRepo
                if (-not $ds) { break }
                Write-Host '  典型用途：双相机录的，只想留腕部相机 → 删掉 observation.images.top' -ForegroundColor DarkGray
                $feats = Read-Text '要删哪些特征（JSON 列表）' '["observation.images.top"]'
                if (-not $feats) { Write-Host '  没填特征名' -ForegroundColor Yellow; break }
                Write-Host '    [1] 直接改原数据集' -ForegroundColor White
                Write-Host '    [2] 存成新数据集（推荐）' -ForegroundColor White
                $m2 = Read-Text '选择' '2'
                $a2 = @("--repo_id=$ds", '--operation.type=remove_feature', "--operation.feature_names=$feats")
                if ($m2 -eq '2') {
                    $newid = Read-Text '新数据集 repo_id' "$($ds)_onecam"
                    $a2 += "--new_repo_id=$newid"
                }
                Invoke-Lerobot 'lerobot-edit-dataset' $a2
            }
            '5' {
                Write-Host ''
                Write-Host '=== 图像转视频 ===' -ForegroundColor Cyan
                $ds = Read-DatasetRepo
                if (-not $ds) { break }
                $out = Read-Text '输出目录（留空=默认）' ''
                # 官方默认 h264，但那需要 libx264；conda-forge 的 ffmpeg 没带，
                # 所以默认 libsvtav1，避免一跑就 Unknown encoder 'libx264'
                $vcodec = Read-Text '编码器（libsvtav1 / h264 / hevc）' 'libsvtav1'
                $crf = Read-Text '画质 crf（越小越清晰，默认 30）' '30'
                $a3 = @("--repo_id=$ds", '--operation.type=convert_image_to_video',
                        "--operation.vcodec=$vcodec", "--operation.crf=$crf")
                if ($out) { $a3 += "--operation.output_dir=$out" }
                Invoke-Lerobot 'lerobot-edit-dataset' $a3
            }
            '6' {
                Write-Host ''
                Write-Host '=== 本地可视化 ===' -ForegroundColor Cyan
                $ds = Read-DatasetRepo
                if (-not $ds) { break }
                $ep = Read-Text '剧集号' '0'
                $root = Read-Text '本地目录 root（云端数据集留空）' ''
                $a4 = @("--repo-id=$ds", "--episode-index=$ep")
                if ($root) { $a4 += @("--root=$root", '--mode=local') }
                Invoke-Lerobot 'lerobot-dataset-viz' $a4
            }
            '7' {
                Write-Host ''
                Write-Host '=== 在线可视化 ===' -ForegroundColor Cyan
                Write-Host '  https://huggingface.co/spaces/lerobot/visualize_dataset' -ForegroundColor Cyan
                Write-Host '  把数据集 repo_id 填进去即可，不用本地环境' -ForegroundColor Gray
            }
            '8' {
                Write-Host ''
                Write-Host '=== 上传到 HuggingFace ===' -ForegroundColor Cyan
                $ds = Read-DatasetRepo
                if (-not $ds) { break }
                $defDir = Join-Path (Join-Path $HOME '.cache\huggingface\lerobot') $ds
                $dir = Read-Text '本地目录（留空=默认缓存目录）' $defDir
                $hf = Join-Path $script:ScriptsDir 'hf.exe'
                $cli = Join-Path $script:ScriptsDir 'huggingface-cli.exe'
                if (Test-Path -LiteralPath $hf) {
                    & $hf upload $ds $dir
                } elseif (Test-Path -LiteralPath $cli) {
                    & $cli upload $ds $dir
                } else {
                    Write-Host '  环境里没有 hf / huggingface-cli' -ForegroundColor Yellow
                    Write-Host "  手动： $($script:PyExe) -m pip install -U huggingface_hub" -ForegroundColor Gray
                }
            }
            '0' { return }
            '' { return }
            default { Write-Host '  没有这个选项' -ForegroundColor Yellow; Start-Sleep -Milliseconds 600; continue }
        }
        Pause-Menu
    }
}

# ============================================================ 舵机调试工具
# Seeed 的图形化舵机调试工具（Seeed_RoboController）
# 三个坑，Wiki 没写清：
#   1) 工具在 factory 分支；默认分支 master 是另一个 Web 版，直接 clone 会拿错
#   2) 依赖只有 PySide6 + pyserial
#   3) 界面是 Qt（PySide6），需要图形环境
$script:ServoToolDir = Join-Path $HOME 'Seeed_RoboController'
$script:ServoToolBranch = 'factory'
$script:ServoToolUrl = 'https://github.com/Seeed-Projects/Seeed_RoboController.git'

function Test-ServoToolInstalled {
    return (Test-Path -LiteralPath (Join-Path $script:ServoToolDir 'src\gui\factory_calibration_tool.py'))
}

function Install-ServoTool {
    if (-not (Assert-Env)) { return }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host '  需要 git 才能拉取工具源码' -ForegroundColor Red
        Write-Host '  装好 git 后重来；或者先用 [0] 安装环境，那边会处理依赖' -ForegroundColor Gray
        return
    }

    $urls = @(
        ('https://gh-proxy.com/' + $script:ServoToolUrl),
        ('https://ghfast.top/' + $script:ServoToolUrl),
        $script:ServoToolUrl
    )

    if (Test-Path -LiteralPath (Join-Path $script:ServoToolDir '.git')) {
        Write-Host '  已存在，尝试更新' -ForegroundColor Gray
        Push-Location $script:ServoToolDir
        try {
            & git fetch --depth 1 origin $script:ServoToolBranch 2>&1 | Out-Null
            & git checkout $script:ServoToolBranch 2>&1 | Out-Null
            & git pull --ff-only 2>&1 | Out-Null
        } catch { Write-Host '  更新失败，继续用现有代码' -ForegroundColor Yellow }
        finally { Pop-Location }
    } else {
        if (Test-Path -LiteralPath $script:ServoToolDir) {
            Write-Host "  $($script:ServoToolDir) 已存在但不是 git 仓库，先删掉或用 [4] 卸载" -ForegroundColor Yellow
            return
        }
        $done = $false
        foreach ($u in $urls) {
            Write-Host "  尝试 $u" -ForegroundColor Gray
            # -b factory 是关键，否则默认分支 master 是另一个项目
            & git clone --depth 1 -b $script:ServoToolBranch $u $script:ServoToolDir 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $done = $true; break }
            Write-Host '  失败，换下一个源' -ForegroundColor Yellow
            Remove-Item -LiteralPath $script:ServoToolDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not $done) {
            Write-Host '  拉不下来（检查网络，或手动 git clone -b factory）' -ForegroundColor Red
            return
        }
    }

    if (-not (Test-ServoToolInstalled)) {
        Write-Host '  克隆成功但没找到入口脚本' -ForegroundColor Yellow
        Write-Host '  确认分支是不是 factory；master 分支是另一个项目' -ForegroundColor Gray
        return
    }
    Write-Host "  代码就位：$($script:ServoToolDir)（分支 $script:ServoToolBranch）" -ForegroundColor Green

    Write-Host '  安装依赖 PySide6（约 200 MB）...' -ForegroundColor Gray
    & $script:PyExe -m pip install 'PySide6>=6.0.0' 'pyserial>=3.5' --no-warn-script-location
    if ($LASTEXITCODE -eq 0) { Write-Host '  依赖安装完成' -ForegroundColor Green }
    else { Write-Host '  依赖安装失败，可手动： python -m pip install PySide6 pyserial' -ForegroundColor Red }
}

function Invoke-ServoToolCheck {
    if (-not (Assert-Env)) { return }
    if (-not (Test-ServoToolInstalled)) { Write-Host '  还没安装，先用 [1]' -ForegroundColor Yellow; return }
    Push-Location $script:ServoToolDir
    try { & $script:PyExe 'setup.py' } finally { Pop-Location }
}

function Start-ServoTool {
    if (-not (Assert-Env)) { return }
    if (-not (Test-ServoToolInstalled)) { Write-Host '  还没安装，先用 [1]' -ForegroundColor Yellow; return }

    & $script:PyExe -c 'import PySide6' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  环境里没有 PySide6，先跑 [1] 安装' -ForegroundColor Yellow
        return
    }

    Write-Host '  启动中，界面会单独弹出（关闭窗口即退出）' -ForegroundColor Gray
    Write-Host '  串口被占用时可手动指定： --port1 COM3 --port2 COM4' -ForegroundColor Gray
    Push-Location $script:ServoToolDir
    try {
        & $script:PyExe -m src.gui.factory_calibration_tool
    } finally { Pop-Location }
}

function Remove-ServoTool {
    if (-not (Test-Path -LiteralPath $script:ServoToolDir)) {
        Write-Host '  没装，无需卸载' -ForegroundColor Gray
        return
    }
    Write-Host "  将删除目录：$($script:ServoToolDir)" -ForegroundColor Yellow
    Write-Host '  （PySide6 不删，可能被别的程序用着）' -ForegroundColor Gray
    if ((Read-Text '确认删除？(y/N)' 'n') -notmatch '^[yY]') { Write-Host '  已取消' -ForegroundColor Gray; return }
    try {
        Remove-Item -LiteralPath $script:ServoToolDir -Recurse -Force -ErrorAction Stop
        Write-Host '  已删除' -ForegroundColor Green
    } catch { Write-Host "  删除失败：$($_.Exception.Message)" -ForegroundColor Red }
}

# 主菜单直达：安装
function Action-ServoInstall {
    Install-ServoTool
    if (Test-ServoToolInstalled) {
        Write-Host ''
        if ((Read-Text '装好了，现在打开图形界面？(y/N)' 'n') -match '^[yY]') {
            Start-ServoTool
        } else {
            Write-Host '  以后用主菜单 [o] 打开' -ForegroundColor Gray
        }
    }
}

# 主菜单直达：打开（没装就先问要不要装）
function Action-ServoOpen {
    Write-Host ''
    Write-Host '=== 舵机调试工具 ===' -ForegroundColor Cyan
    if (-not (Test-ServoToolInstalled)) {
        Write-Host '  还没安装' -ForegroundColor Yellow
        if ((Read-Text '现在安装？(y/N)' 'n') -match '^[yY]') {
            Install-ServoTool
            if (-not (Test-ServoToolInstalled)) { return }
        } else { return }
    }
    Start-ServoTool
}

function Action-ServoTool {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ====== 舵机调试工具（Seeed_RoboController）======' -ForegroundColor Cyan
        Write-Host ''
        if (Test-ServoToolInstalled) {
            Write-Host "  状态：已安装  $($script:ServoToolDir)" -ForegroundColor Green
        } else {
            Write-Host '  状态：未安装' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '    [1] 安装 / 更新' -ForegroundColor White
        Write-Host '    [2] 环境检查' -ForegroundColor White
        Write-Host '    [3] 启动图形界面' -ForegroundColor White
        Write-Host '    [4] 卸载' -ForegroundColor White
        Write-Host '    [5] 官方说明（网址）' -ForegroundColor White
        Write-Host '    [0] 返回' -ForegroundColor White
        Write-Host ''

        $k = Read-Key '请输入'
        switch ($k) {
            '1' { Install-ServoTool }
            '2' { Invoke-ServoToolCheck }
            '3' { Start-ServoTool }
            '4' { Remove-ServoTool }
            '5' {
                Write-Host ''
                Write-Host '  https://wiki.seeedstudio.com/cn/lerobot_steering_gear_debugging_tool/' -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  能做什么：' -ForegroundColor White
                Write-Host '    - 检测 1-6 号舵机是否都在线' -ForegroundColor Gray
                Write-Host '    - 改舵机 ID（ID 重复时只能一个个拆下来重刷）' -ForegroundColor Gray
                Write-Host '    - 写中位值（把当前位置当零点烧进去）' -ForegroundColor Gray
                Write-Host '    - 单个舵机拖进度条测试、看电压/温度/负载/电流' -ForegroundColor Gray
                Write-Host '    - 读写寄存器、改波特率、恢复出厂' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  注意：工具在 factory 分支，master 分支是另一个 Web 项目。' -ForegroundColor Yellow
            }
            '0' { return }
            ''  { return }
            default { Write-Host '  没有这个选项' -ForegroundColor Yellow; Start-Sleep -Milliseconds 600 }
        }
        Pause-Menu
    }
}

# ============================================================ 高级选项
function Action-Advanced {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ====== 高级选项（其余 lerobot 命令）======' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    [1] lerobot-info              环境与硬件信息' -ForegroundColor White
        Write-Host '    [2] lerobot-find-joint-limits 探测关节限位' -ForegroundColor White
        Write-Host '    [3] lerobot-dataset-viz       数据集可视化' -ForegroundColor White
        Write-Host '    [4] lerobot-imgtransform-viz  图像变换可视化' -ForegroundColor White
        Write-Host '    [5] lerobot-eval              评估策略' -ForegroundColor White
        Write-Host '    [6] lerobot-annotate          数据标注' -ForegroundColor White
        Write-Host '    [7] lerobot-edit-dataset      数据集工具（删/拆/合并/转视频）' -ForegroundColor White
        Write-Host '    [8] lerobot-train-tokenizer   训练 VLA tokenizer' -ForegroundColor White
        Write-Host '    [9] lerobot-setup-can         Damiao CAN 总线初始化' -ForegroundColor White
        Write-Host ''
        Write-Host '    [s] 舵机工具：环境检查 / 卸载 / 说明' -ForegroundColor White
        Write-Host '    [c] 任意命令（自己敲参数）' -ForegroundColor White
        Write-Host '    [0] 返回' -ForegroundColor White
        Write-Host ''

        $k = Read-Key '请输入'
        switch ($k) {
            '1' { Invoke-Lerobot 'lerobot-info' }
            '2' {
                if (-not (Assert-Env)) { break }
                $port = Select-SerialPort '串口'
                if (-not $port) { break }
                $type = Select-RobotType
                $id = Select-RobotId -Kind 'robot' -Default 'my_follower_arm'
                Invoke-Lerobot 'lerobot-find-joint-limits' @("--robot.type=$type", "--robot.port=$port", "--robot.id=$id")
            }
            '3' {
                if (-not (Assert-Env)) { break }
                $ds = Read-Text '数据集 repo_id' $(if ($env:HF_USER) { "$env:HF_USER/so101_dataset" } else { 'so101_dataset' })
                $ep = Read-Text '回合号（留空=全部）' ''
                if ($ep) { Invoke-Lerobot 'lerobot-dataset-viz' @("--repo-id=$ds", "--episode-index=$ep") }
                else { Invoke-Lerobot 'lerobot-dataset-viz' @("--repo-id=$ds") }
            }
            '4' {
                if (-not (Assert-Env)) { break }
                $ds = Read-Text '数据集 repo_id' $(if ($env:HF_USER) { "$env:HF_USER/so101_dataset" } else { 'so101_dataset' })
                Invoke-Lerobot 'lerobot-imgtransform-viz' @("--repo-id=$ds")
            }
            '5' {
                if (-not (Assert-Env)) { break }
                $pol = Read-Text '策略路径（outputs\train\... 或 HF repo_id）' ''
                if (-not $pol) { Write-Host '  需要策略路径' -ForegroundColor Yellow; break }
                Invoke-Lerobot 'lerobot-eval' @("--policy.path=$pol")
            }
            '6' {
                if (-not (Assert-Env)) { break }
                $ds = Read-Text '数据集 repo_id' $(if ($env:HF_USER) { "$env:HF_USER/so101_dataset" } else { 'so101_dataset' })
                Invoke-Lerobot 'lerobot-annotate' @("--repo-id=$ds")
            }
            '7' {
                if (-not (Assert-Env)) { break }
                Action-DatasetTool
                break
            }
            '8' {
                if (-not (Assert-Env)) { break }
                $ds = Read-Text '数据集 repo_id' $(if ($env:HF_USER) { "$env:HF_USER/so101_dataset" } else { 'so101_dataset' })
                Invoke-Lerobot 'lerobot-train-tokenizer' @("--dataset.repo_id=$ds")
            }
            '9' {
                Write-Host '  Damiao 电机走 CAN 总线（OpenArm 等），需要先配置 can 接口' -ForegroundColor Gray
                Invoke-Lerobot 'lerobot-setup-can' @('--help')
            }
            's' {
                Action-ServoTool
                break
            }
            'c' {
                if (-not (Assert-Env)) { break }
                $names = @(Get-ChildItem $script:ScriptsDir -Filter 'lerobot-*.exe' -ErrorAction SilentlyContinue |
                           ForEach-Object { $_.BaseName -replace '^lerobot-', '' })
                if ($names.Count -eq 0) { Write-Host '  环境里没有 lerobot-* 命令' -ForegroundColor Yellow; break }
                Write-Host ''
                Write-Host ('  可用：' + ($names -join '  ')) -ForegroundColor Gray
                $short = Read-Text '要运行哪个（不带 lerobot- 前缀）' ''
                if (-not $short) { break }
                $raw = Read-Text '参数（留空则显示 --help）' '--help'
                $argv = @()
                if ($raw) { $argv = $raw -split '\s+' | Where-Object { $_ } }
                Invoke-Lerobot "lerobot-$short" $argv
            }
            '0' { return }
            '' { return }
            default { Write-Host '  没有这个选项' -ForegroundColor Yellow; Start-Sleep -Milliseconds 600 }
        }
        Pause-Menu
    }
}

# ============================================================ 自由终端
function Action-Terminal {
    if (-not (Assert-Env)) { return }
    $rc = Join-Path $env:TEMP ("lerobot-term-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    $prefix = $script:EnvPrefix
    $lines = @(
        "`$env:CONDA_PREFIX     = '$prefix'"
        "`$env:CONDA_DEFAULT_ENV = '$EnvName'"
        "`$env:PATH = '$prefix;$prefix\Scripts;$prefix\Library\bin;' + `$env:PATH"
        "`$env:PYTHONNOUSERSITE = '1'"
        "if (-not `$env:HF_ENDPOINT) { `$env:HF_ENDPOINT = 'https://hf-mirror.com' }"
        "function global:prompt { '(lerobot) PS ' + (Get-Location) + '> ' }"
        "Write-Host '================================================' -ForegroundColor Cyan"
        "Write-Host ' LeRobot 终端（环境已激活）' -ForegroundColor Cyan"
        "`$py = (Get-Command python -ErrorAction SilentlyContinue)"
        "if (`$py) { Write-Host (' python : ' + `$py.Source) -ForegroundColor Gray }"
        "Write-Host ' 输入 exit 关闭这个窗口' -ForegroundColor Gray"
        "Write-Host '================================================' -ForegroundColor Cyan"
        "Set-Location '$HOME'"
    )
    Set-Content -LiteralPath $rc -Value $lines -Encoding UTF8
    Write-Host ''
    Write-Host '  正在打开新的 PowerShell 窗口（环境已激活）...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoExit', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', "`"$rc`""
    ) | Out-Null
    Write-Host '  关闭那个窗口即可回到这里' -ForegroundColor Gray
}

# ============================================================ 分发
function Invoke-MenuItem([string]$key) {
    switch ($key) {
        '0' { Action-Install }
        '1' { Action-Test }
        'w' { Action-HardwareCheck }
        '2' { Action-FindPort }
        '3' { Action-SetupMotors }
        '4' { Action-Calibrate }
        'r' { Action-CalibrationManager }
        's' { Action-ServoInstall }
        'o' { Action-ServoOpen }
        '5' { Action-Teleoperate }
        '6' { Action-Record }
        '7' { Action-Train }
        '8' { Action-Rollout }
        '9' { Action-Replay }
        'c' { Action-Cameras }
        'v' { Action-DatasetTool; return }
        'i' { Action-Info }
        'm' { Action-Mirror }
        'h' { Action-Help }
        't' { Action-Terminal }
        'x' { Action-Advanced; return }
        'q' {
            Write-Host ''
            Write-Host '  再见。' -ForegroundColor Cyan
            exit 0
        }
        default {
            Write-Host ''
            Write-Host "  没有这个选项：$key" -ForegroundColor Red
            Write-Host '  可用：0-9、w、c、v、i、m、h、q' -ForegroundColor Gray
        }
    }
}

# ============================================================ 入口
$script:EnvPrefix = Get-EnvPrefix $EnvName
if ($script:EnvPrefix) {
    $script:PyExe = Join-Path $script:EnvPrefix 'python.exe'
    $script:ScriptsDir = Join-Path $script:EnvPrefix 'Scripts'
}

# 直达模式：把编号/字母当参数传
# 注意：这里千万不要写成 `$null = Invoke-MenuItem ...`。
# 那样会把子进程（powershell / lerobot-*.exe）的输出全部吞掉，屏幕上什么都不剩。
if ($Item) {
    if ($Item -eq 'q') { exit 0 }
    Invoke-MenuItem ($Item.Trim().ToLower())
    if ($script:LastCode -gt 0) { exit $script:LastCode }
    exit 0
}

# 菜单模式
while ($true) {
    Show-Menu
    $k = Read-Key '请输入'
    if ($script:Eof) {
        Write-Host ''
        Write-Host '  输入结束，退出。' -ForegroundColor Gray
        break
    }
    if ($k -eq '') { continue }
    Invoke-MenuItem $k
    Pause-Menu
}
