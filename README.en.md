# LeRobot Windows Toolkit

One-click LeRobot setup for Windows. Instead of memorising a dozen commands, you press a number.

Built for networks where GitHub and Hugging Face are slow or blocked: every download step
probes multiple mirrors first (domestic mirrors preferred) and falls back through a chain
until one works.

Verified end-to-end on **Windows Server 2022** — no `winget`, no `git`, no GPU — from a bare
machine to `16/16 checks passing`.

> 中文说明见 [README.md](README.md)

---

## What's inside

| File | Purpose |
|---|---|
| `lerobot-menu.ps1` | **Entry point.** Interactive menu — press a number or letter |
| `install-lerobot.ps1` | Installs the environment, 9 steps with a progress bar |
| `test-lerobot.ps1` | Self-check: 8 software items + 3 hardware items |

Keep all three in the same folder.

## Quick start

```powershell
powershell -ExecutionPolicy Bypass -File .\lerobot-menu.ps1
```

```
   Environment
    [0] Install / repair        install-lerobot.ps1
    [1] Software self-check     test-lerobot.ps1
    [w] Hardware check (serial / camera / calibration)

   Robot setup (once, in this order)
    [2] Find serial port        lerobot-find-port
    [3] Set motor IDs           lerobot-setup-motors
    [4] Calibrate arm           lerobot-calibrate

   Daily use
    [5] Teleoperate             lerobot-teleoperate
    [6] Record a dataset        lerobot-record
    [7] Train a policy          lerobot-train
    [8] Run a policy            lerobot-rollout
    [9] Replay a dataset        lerobot-replay

   More
    [c] Detect cameras          [v] Dataset visualiser
    [i] Environment details     [m] Set HuggingFace mirror
    [h] Command reference       [q] Quit
```

On a fresh machine: **`0` → `1` → `2` → `3` → `4`**.

You can also skip the menu:

```powershell
.\lerobot-menu.ps1 4      # go straight to calibration
.\lerobot-menu.ps1 i      # environment details
```

## No flags to memorise

Every parameter is *chosen*, not typed:

- **Serial port** — ports are detected and listed with their driver description; pick a number
- **Calibration id** — existing ids are read from `~/.cache/huggingface/lerobot/calibration` so you can't typo them
- **Robot model** — pick from SO-101 / SO-100, leader or follower
- **Policy** — act / diffusion / smolvla / pi0 / pi05

The command it builds matches the official docs:

```
lerobot-calibrate --robot.type=so101_follower --robot.port=COM3 --robot.id=my_follower_arm
```

## Install pipeline (9 steps)

```
  Step 1/9  [██░░░░░░░░░░░░░░░░░░]  11%  Preflight
  Step 2/9  [████░░░░░░░░░░░░░░░░]  22%  conda env [lerobot]
  Step 3/9  [██████░░░░░░░░░░░░░░]  33%  Probe pip mirrors
  Step 4/9  [████████░░░░░░░░░░░░]  44%  Install ffmpeg (for TorchCodec)
  Step 5/9  [███████████░░░░░░░░░]  55%  Install git (via conda-forge)
  Step 6/9  [█████████████░░░░░░░]  66%  Fetch lerobot source
  Step 7/9  [███████████████░░░░░]  77%  Editable install
  Step 8/9  [█████████████████░░░]  88%  HuggingFace mirror
  Step 9/9  [████████████████████] 100%  Summary
```

The total adapts to your flags (`-SkipFfmpeg`, `-WithGit`), so you never see "step 4 of 9" and
then the script ends.

## Mirror fallback chain

Nothing is hardcoded to a single source — each stage probes, then degrades:

| Stage | Order (stops at the first that works) |
|---|---|
| pip | Tsinghua → Aliyun → Tencent → USTC → Huawei → official PyPI |
| conda | Tsinghua `pkgs/main` → Tsinghua `conda-forge` → defaults |
| git clone | gh-proxy.com → ghfast.top → ghproxy.net → GitHub direct |
| Source fallback | all git sources dead → download the sdist from a pip mirror |
| HF models | hf-mirror.com (written to `HF_ENDPOINT`) |

### A counter-intuitive measurement

Tsinghua's `conda-forge` `repodata.json` is **279 MB + 185 MB** uncompressed. On a slow link
that times out, and the failure surfaces as *"the domestic mirror doesn't work"*.

```
conda-forge   279 MB (win-64) + 185 MB (noarch)   65 MB as .zst
pkgs/main     112 MB (win-64)                     12 MB as .zst
```

`pkgs/main` also has Python 3.12. So **create the env from the small index**, and only touch
the big one when you need packages that exist solely on conda-forge (ffmpeg, git).

## Self-check is split in two

`[1]` checks software only (this should be all PASS after install):

```
[PASS] conda env / Python / pip / lerobot installed
[PASS] follower / leader / Feetech SDK / OpenCV / datasets / policies
[PASS] 8 CLI entry points / entry module importable / ffmpeg + encoders
[WARN] PyTorch / CUDA          <- WARN without an NVIDIA GPU, expected
[PASS] HuggingFace mirror reachable
```

`[w]` checks hardware (serial ports, calibration files, cameras). Camera probing has a
**25-second hard timeout**, so a missing camera can't hang the suite.

**Why split**: on a machine with no arm connected, serial/calibration/camera are *always* WARN.
Mixing them into the environment check makes people think the install failed.

## Common flags

```powershell
# Show the plan, install nothing
.\install-lerobot.ps1 -DryRun

# Standard install (GitHub reachable)
.\install-lerobot.ps1 -AutoInstallPrereqs -WithGit

# GitHub unreachable (corporate network / direct-connect CN)
.\install-lerobot.ps1 -FromPypi -AutoInstallPrereqs -WithGit

# Pin a version
.\install-lerobot.ps1 -FromPypi -PypiVersion 0.6.1
```

`-FromPypi` installs the PyPI release, **not the GitHub `main` branch** — the two have
different `extras` lists. The script compares your requested extras against the actual
`pyproject.toml` and tells you when a name doesn't exist, instead of silently skipping it.

## Requirements

- Windows 10 / 11 / Server 2019+, PowerShell 5.1 or newer
- ≥ 15 GB free disk (torch and rerun-sdk are large)
- Optional: NVIDIA GPU + driver for training (CPU works, just slower)

Neither conda nor git needs to be preinstalled — `-AutoInstallPrereqs` fetches them
through Tsinghua mirrors.

## Known limitations

Not yet verified against real hardware:

- **The three arm steps** (`find-port` / `setup-motors` / `calibrate`) need a human to plug
  cables and move joints. The command construction is tested; no real Feetech servos were involved.
- **Dual-camera `lerobot-record`** — the `--robot.cameras="{...}"` string follows the official
  docs but was never run on a machine with two cameras. Use a single camera for the first recording.
- **`lerobot-rollout`** only exists in 0.6.x and later; the script detects older versions and says so.

See [docs/hardware-verification.md](docs/hardware-verification.md) for the exact checklist to
close these gaps.

## Gotchas we hit (if you're writing similar tooling)

| Problem | Symptom | Cause |
|---|---|---|
| Return value polluted | exit code becomes a paragraph of English | `& $exe` output leaks into the function's return value; pipe through `\| Out-Host` |
| Child output vanishes | menu turns silent after a keypress | `$null = Invoke-Item` swallows everything on the pipeline |
| Quotes eaten | `print("%d" % x)` → SyntaxError | PowerShell 5.1 strips double quotes when passing to native exes; write a temp `.py` instead |
| curl 404 counts as success | an HTML error page gets executed as an installer | curl doesn't fail on HTTP errors by default; add `-f` |
| conda installed but "not found" | install reported as failed | NSIS silent installers return early; poll until the file lock is released |
| Env borrows user packages | `ModuleNotFoundError` after switching accounts | a system Python of the same version enables user site-packages; set `PYTHONNOUSERSITE=1` |
| Progress bar shows `?` | `[██???]` | the GBK console can't render `░`; probe each glyph |
| `(if …)` syntax error | `if is not recognized as a cmdlet` | PS 5.1 has no if-expression (that's PS7) |
| Camera probe hangs | looks like a deadlock | OpenCV's DSHOW enumeration blocks when no camera exists; add a hard timeout |

Save the scripts as **UTF-8 with BOM** — otherwise PS 5.1 decodes Chinese as GBK and the
quoting breaks the file.

## Links

- LeRobot: <https://github.com/huggingface/lerobot>
- Installation docs: <https://huggingface.co/docs/lerobot/installation>
- SO-101 tutorial: <https://huggingface.co/docs/lerobot/so101>
- Hardware BOM / printed parts: <https://github.com/TheRobotStudio/SO-ARM100>

## License

MIT — see [LICENSE](LICENSE).
