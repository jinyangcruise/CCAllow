Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwp);
    [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwp);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, int gaFlags);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, IntPtr attrValue, int attrSize);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
}

[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }

[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

[StructLayout(LayoutKind.Sequential)]
public struct WINDOWPLACEMENT {
    public int length;
    public int flags;
    public int showCmd;
    public POINT ptMinPosition;
    public POINT ptMaxPosition;
    public RECT rcNormalPosition;
    public RECT rcDevice;
}
"@

# Enable DPI awareness so GetWindowRect and WindowFromPoint use the same coordinate system
[Win32]::SetProcessDpiAwareness(2) | Out-Null  # PROCESS_PER_MONITOR_DPI_AWARE

$SM_CXSCREEN = 0; $SM_CYSCREEN = 1

$targets = @("Allow once", "Allow Once", "Allow for this time", "Allow for this")
$running = $true
$peekInterval = 2500
$minimizedPolling = $false
$minimizeAfterAllow = $false
$loopCount = 0

$reader = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput())
$readTask = $reader.ReadLineAsync()

function HandleCommand($line) {
    if (-not $line) { return }
    Write-Output "  cmd: $line"
    if ($line -eq "exit") { $script:running = $false; return }
    if ($line -match '^interval:(\d+)$') { $script:peekInterval = [int]$Matches[1]; return }
    if ($line -eq "polling:on") { $script:minimizedPolling = $true; return }
    if ($line -eq "polling:off") { $script:minimizedPolling = $false; return }
    if ($line -eq "minimize-after-allow:on") { $script:minimizeAfterAllow = $true; return }
    if ($line -eq "minimize-after-allow:off") { $script:minimizeAfterAllow = $false; return }
}

function FindAllowButton($root) {
    if (-not $root) { return $null }
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElementIdentifiers]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, $cond)
        if (-not $buttons -or $buttons.Count -eq 0) { return $null }
        for ($i = 0; $i -lt $buttons.Count; $i++) {
            $btn = $buttons[$i]
            if (-not $btn.Current.IsEnabled) { continue }
            $name = $btn.Current.Name.Trim()
            foreach ($t in $targets) {
                if ($name.StartsWith($t)) { return $btn }
            }
        }
    } catch { }
    return $null
}

function IsWindowFullyOccluded($hwnd, $procIds) {
    $targetRect = New-Object RECT
    if (-not [Win32]::GetWindowRect($hwnd, [ref]$targetRect)) { return $false }
    $tL = $targetRect.Left; $tT = $targetRect.Top
    $tR = $targetRect.Right; $tB = $targetRect.Bottom
    if ($tR -le $tL -or $tB -le $tT) { return $false }

    # Collect windows above Claude that overlap Claude rect (for multi-window fallback)
    $aboveOverlapWindows = @()

    # Walk Z-order upward from Claude's window
    $current = [Win32]::GetWindow($hwnd, 3)  # GW_HWNDPREV = 3
    while ($current -ne [IntPtr]::Zero) {
        if ([Win32]::IsWindowVisible($current) -and -not [Win32]::IsIconic($current)) {
            $r = New-Object RECT
            if ([Win32]::GetWindowRect($current, [ref]$r)) {
                $winPid = [uint32]0
                [Win32]::GetWindowThreadProcessId($current, [ref]$winPid) | Out-Null
                $zName = (Get-Process -Id $winPid -ErrorAction SilentlyContinue).ProcessName
                $zTitle = New-Object System.Text.StringBuilder 256
                [Win32]::GetWindowText($current, $zTitle, 256) | Out-Null
                $covers = ($r.Left -le $tL -and $r.Top -le $tT -and $r.Right -ge $tR -and $r.Bottom -ge $tB)
                # [Console]::Error.WriteLine("Z-ABOVE: pid=$winPid name=$zName title='$($zTitle.ToString())' rect=($($r.Left),$($r.Top),$($r.Right),$($r.Bottom)) covers=$covers isClaude=$($procIds -contains [int]$winPid)")

                if ($covers) {
                    if ($procIds -contains [int]$winPid) { $current = [Win32]::GetWindow($current, 3); continue }

                    $fg = [Win32]::GetForegroundWindow()
                    if ($current -eq $fg) {
                        # [Console]::Error.WriteLine("Z-ABOVE ==> FOREGROUND, COVERED")
                        return $true  # Covered by the active foreground window
                    }
                }

                # Collect overlapping windows for multi-window occlusion fallback
                if (-not ($procIds -contains [int]$winPid) -and
                    $r.Left -lt $tR -and $r.Right -gt $tL -and $r.Top -lt $tB -and $r.Bottom -gt $tT) {
                    $ow = $r.Right - $r.Left; $oh = $r.Bottom - $r.Top
                    if ($ow -ge 50 -and $oh -ge 50) {
                        $aboveOverlapWindows += @{left=$r.Left; top=$r.Top; right=$r.Right; bottom=$r.Bottom; name=$zName; title=$zTitle.ToString()}
                    }
                }
            }
        }
        $current = [Win32]::GetWindow($current, 3)
    }

    # Fallback: multi-window occlusion detection via pixel sampling
    # Only check when Claude is NOT the foreground window (user is working elsewhere)
    $fg = [Win32]::GetForegroundWindow()
    if ($fg -eq $hwnd) { return $false }

    # Debug: log Claude window info and foreground info
    $fgTitle = New-Object System.Text.StringBuilder 256
    [Win32]::GetWindowText($fg, $fgTitle, 256) | Out-Null
    $fgPid = [uint32]0
    [Win32]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null
    $fgName = (Get-Process -Id $fgPid -ErrorAction SilentlyContinue).ProcessName
    # 40 sample points: 20 interior (5x4 grid, 10% inset) + 20 on edges
    $w = $tR - $tL; $h = $tB - $tT
    # [Console]::Error.WriteLine("MULTI-OCCL: claudeRect=($tL,$tT,$tR,$tB) sz=${w}x${h} fgPid=$fgPid fgName=$fgName fgTitle='$($fgTitle.ToString())' claudePids=[$($procIds -join ',')]")
    $marginX = [int]($w * 0.1); $marginY = [int]($h * 0.1)
    $innerW = $w - 2 * $marginX; $innerH = $h - 2 * $marginY
    if ($innerW -le 0 -or $innerH -le 0) { # [Console]::Error.WriteLine("MULTI-OCCL: invalid inner size"); return $false }

    $samplePoints = @()
    # Interior grid: 5 columns x 4 rows = 20 points
    for ($c = 0; $c -lt 5; $c++) {
        for ($r = 0; $r -lt 4; $r++) {
            $x = $tL + $marginX + [int]($innerW * $c / 4)
            $y = $tT + $marginY + [int]($innerH * $r / 3)
            $samplePoints += @($x, $y)
        }
    }
    # Edge points: 5 per edge = 20 points, inset 1px
    for ($i = 0; $i -lt 5; $i++) {
        $xi = $tL + 1 + [int](($w - 2) * $i / 4)
        $yi = $tT + 1 + [int](($h - 2) * $i / 4)
        # Pre-compute edge coordinates to avoid parsing issues in @()
        $topY = $tT + 1; $rightX = $tR - 1
        $bottomY = $tB - 1; $leftX = $tL + 1
        $samplePoints += @($xi, $topY)         # top edge
        $samplePoints += @($rightX, $yi)       # right edge
        $samplePoints += @($xi, $bottomY)      # bottom edge
        $samplePoints += @($leftX, $yi)        # left edge
    }

    $anyClaudeVisible = $false; $belowCount = 0; $aboveCount = 0
    for ($p = 0; $p -lt $samplePoints.Count; $p += 2) {
        $x = $samplePoints[$p]; $y = $samplePoints[$p+1]
        $topHwnd = [Win32]::WindowFromPoint($x, $y)
        if ($topHwnd -eq [IntPtr]::Zero) { # [Console]::Error.WriteLine("  [$x,$y] → hwnd=0 (skip)"); continue }
        $rootHwnd = [Win32]::GetAncestor($topHwnd, 2)  # GA_ROOT = 2

        # Check if this point shows Claude itself → visible at this point
        $winPid = [uint32]0
        [Win32]::GetWindowThreadProcessId($rootHwnd, [ref]$winPid) | Out-Null
        if ($rootHwnd -eq $hwnd -or $procIds -contains [int]$winPid) {
            # [Console]::Error.WriteLine("  [$x,$y] → Claude itself (visible)")
            $anyClaudeVisible = $true; continue
        }

        # Z-order verification: is this window ABOVE Claude?
        $isAbove = $false
        $z = [Win32]::GetWindow($hwnd, 3)
        while ($z -ne [IntPtr]::Zero) {
            if ($z -eq $rootHwnd) { $isAbove = $true; break }
            $z = [Win32]::GetWindow($z, 3)
        }

        if (-not $isAbove) {
            # WindowFromPoint returned BELOW: check known above-overlap windows
            $coveredByAbove = $false
            foreach ($w in $aboveOverlapWindows) {
                if ($x -ge $w.left -and $x -lt $w.right -and $y -ge $w.top -and $y -lt $w.bottom) {
                    # [Console]::Error.WriteLine("  [$x,$y] → covered by known above window: name=$($w.name) title='$($w.title)' rect=($($w.left),$($w.top),$($w.right),$($w.bottom))")
                    $coveredByAbove = $true; break
                }
            }
            if ($coveredByAbove) {
                $aboveCount++
            } else {
                $belowCount++
                # [Console]::Error.WriteLine("  [$x,$y] → NOT covered by any above window (below Claude)")
            }
            continue
        }

        # Window is ABOVE Claude: log detailed info for occlusion analysis
        $coverName = (Get-Process -Id $winPid -ErrorAction SilentlyContinue).ProcessName
        $coverTitle = New-Object System.Text.StringBuilder 256
        [Win32]::GetWindowText($rootHwnd, $coverTitle, 256) | Out-Null
        $coverRect = New-Object RECT
        [Win32]::GetWindowRect($rootHwnd, [ref]$coverRect) | Out-Null
        $pointInRect = ($x -ge $coverRect.Left -and $x -lt $coverRect.Right -and $y -ge $coverRect.Top -and $y -lt $coverRect.Bottom)
        # [Console]::Error.WriteLine("  [$x,$y] → ABOVE: name=$coverName title='$($coverTitle.ToString())' rect=($($coverRect.Left),$($coverRect.Top),$($coverRect.Right),$($coverRect.Bottom)) pointInRect=$pointInRect")
        $aboveCount++
    }
    # [Console]::Error.WriteLine("  ==> above=$aboveCount below=$belowCount claudeVisible=$anyClaudeVisible")
    if ($anyClaudeVisible) { # [Console]::Error.WriteLine("  ==> decision: NOT occluded (Claude visible at some point)"); return $false }
    if ($belowCount -gt 0) { # [Console]::Error.WriteLine("  ==> decision: NOT occluded ($belowCount points below Claude)"); return $false }
    # [Console]::Error.WriteLine("  ==> decision: OCCLUDED (all $aboveCount points covered by windows above Claude)")
    return $true
}

function ClickButton($btn, $procId) {
    $name = $btn.Current.Name.Trim()
    Write-Output "found: >>$name<<"
    # Try InvokePattern (doesn't steal focus)
    try {
        $invoke = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        if ($invoke) { $invoke.Invoke(); Write-Output "clicked (InvokePattern)!"; return }
        else { Write-Output "  no InvokePattern on '$name'" }
    } catch { Write-Output "  InvokePattern error: $_" }
    # Fallback: activate + SendKeys
    try {
        Write-Output "  SendKeys fallback..."
        $prevHwnd = [IntPtr]::Zero
        try { $prevHwnd = [Win32]::GetForegroundWindow() } catch { }
        $wshell = New-Object -ComObject wscript.shell
        if ($wshell) { $wshell.AppActivate($procId) | Out-Null }
        Start-Sleep -Milliseconds 150
        [System.Windows.Forms.SendKeys]::SendWait("^({ENTER})")
        if ($prevHwnd -and $prevHwnd -ne [IntPtr]::Zero) {
            try { [Win32]::SetForegroundWindow($prevHwnd) | Out-Null } catch { }
        }
        Write-Output "clicked (SendKeys)!"
    } catch { Write-Output "key error: $_" }
}

function DisableAnim($hwnd) {
    $mem = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, 0, 1)
    [Win32]::DwmSetWindowAttribute($hwnd, 3, $mem, 4) | Out-Null  # DWMWA_TRANSITIONS_FORCEDISABLED
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($mem)
}
function EnableAnim($hwnd) {
    $mem = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, 0, 0)
    [Win32]::DwmSetWindowAttribute($hwnd, 3, $mem, 4) | Out-Null
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($mem)
}

function PeekAndScan($hwnd, $procId) {
    DisableAnim $hwnd
    $wp = New-Object WINDOWPLACEMENT
    $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
    [Win32]::GetWindowPlacement($hwnd, [ref]$wp) | Out-Null
    $savedWp = $wp
    $sw = [Win32]::GetSystemMetrics(0); $sh = [Win32]::GetSystemMetrics(1)
    $pw = $wp.rcNormalPosition.Right - $wp.rcNormalPosition.Left
    $ph = $wp.rcNormalPosition.Bottom - $wp.rcNormalPosition.Top
    $offX = [Math]::Max(0, $sw - 10); $offY = [Math]::Max(0, $sh - 10 - 80)
    $r = $wp.rcNormalPosition
    $r.Left = $offX; $r.Top = $offY; $r.Right = $offX + $pw; $r.Bottom = $offY + $ph
    $wp.rcNormalPosition = $r
    $wp.showCmd = 6  # SW_MINIMIZE (keep minimized without activating)
    [Win32]::SetWindowPlacement($hwnd, [ref]$wp) | Out-Null
    Start-Sleep -Milliseconds 100
    [Win32]::ShowWindow($hwnd, 4) | Out-Null  # SW_SHOWNOACTIVATE (show at new pos)
    [Win32]::SetWindowPlacement($hwnd, [ref]$wp) | Out-Null
    Start-Sleep -Milliseconds 600
    try {
        $btn = FindAllowButton ([System.Windows.Automation.AutomationElement]::FromHandle($hwnd))
        if ($btn) {
            EnableAnim $hwnd
            $savedWp.showCmd = 4
            [Win32]::SetWindowPlacement($hwnd, [ref]$savedWp) | Out-Null
            ClickButton $btn $procId | Out-Null
            if ($script:minimizeAfterAllow) {
                $savedWp.showCmd = 6  # SW_MINIMIZE
                [Win32]::SetWindowPlacement($hwnd, [ref]$savedWp) | Out-Null
            }
            EnableAnim $hwnd
            return $true
        }
    } catch { }
    EnableAnim $hwnd
    # Restore: save original position but minimize the window
    # When user clicks taskbar icon, it will restore to original position
    $savedWp.showCmd = 2  # SW_SHOWMINIMIZED
    [Win32]::SetWindowPlacement($hwnd, [ref]$savedWp) | Out-Null
    return $false
}

function PeekOccluded($hwnd, $procId) {
    DisableAnim $hwnd
    $origRect = New-Object RECT
    [Win32]::GetWindowRect($hwnd, [ref]$origRect) | Out-Null
    $sw = [Win32]::GetSystemMetrics(0); $sh = [Win32]::GetSystemMetrics(1)
    $pw = $origRect.Right - $origRect.Left; $ph = $origRect.Bottom - $origRect.Top
    $offX = [Math]::Max(0, $sw - 10); $offY = [Math]::Max(0, $sh - 10 - 80)

    # Move to bottom-right (no state change, no activate)
    [Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $offX, $offY, $pw, $ph, 0x0014)  # SWP_NOZORDER|SWP_NOACTIVATE
    Start-Sleep -Milliseconds 600

    try {
        $btn = FindAllowButton ([System.Windows.Automation.AutomationElement]::FromHandle($hwnd))
        if ($btn) {
            # Move back before clicking
            [Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $origRect.Left, $origRect.Top, $pw, $ph, 0x0014)
            EnableAnim $hwnd
            ClickButton $btn $procId | Out-Null
            return $true
        }
    } catch { }

    # Move back to original position
    [Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $origRect.Left, $origRect.Top, $pw, $ph, 0x0014)
    EnableAnim $hwnd
    return $false
}

while ($running) {
    $loopCount++
    if ($loopCount % 10 -eq 0) { } # Write-Output "alive (loop $loopCount, polling=$minimizedPolling, interval=$peekInterval)"
    if ($readTask.IsCompleted) {
        $line = $readTask.Result
        if ($null -eq $line) { $running = $false; break }
        $line = $line.Trim()
        HandleCommand $line
        if (-not $running) { break }
        $readTask = $reader.ReadLineAsync()
    }

    $claudeProcs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'claude' } |
        Where-Object { $_.MainWindowHandle -ne 0 }

    if (-not $claudeProcs) { Start-Sleep -Milliseconds 500; continue }

    $p = $claudeProcs[0]
    $hwnd = $p.MainWindowHandle
    $isMin = [Win32]::IsIconic($hwnd)

    # Collect ALL Claude process PIDs (multi-process: main, GPU, renderer, etc.)
    $allClaudePids = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'claude' } |
        ForEach-Object { $_.Id })

    # Check Claude window when NOT minimized
    if (-not $isMin) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
            $btn = FindAllowButton $root
            if ($btn) { ClickButton $btn $p.Id; continue }
        } catch { Write-Output "  check err: $_" }

        # Window not minimized but button not found → check if fully occluded
        if ($minimizedPolling) {
            # Write-Output "  [dbg] not-min, polling=ON, checking occlusion..."
            if (IsWindowFullyOccluded $hwnd $allClaudePids) {
                # Write-Output "  [dbg] OCCLUDED → peek"
                if (PeekOccluded $hwnd $p.Id) { continue }
            } else {
                # Write-Output "  [dbg] NOT occluded"
            }
            # Write-Output "  [dbg] sleep ${peekInterval}ms start"
            Start-Sleep -Milliseconds $peekInterval
            # Write-Output "  [dbg] sleep ${peekInterval}ms done"
            continue
        }

        Start-Sleep -Milliseconds 400
        continue
    }

    # Claude IS minimized
    # Write-Output "  [dbg] minimized, polling=$minimizedPolling"
    if ($minimizedPolling) {
        if (PeekAndScan $hwnd $p.Id) { continue }
        Start-Sleep -Milliseconds $peekInterval
    } else {
        Start-Sleep -Milliseconds 1000
    }
}
