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
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int nLeftRect, int nTopRect, int nRightRect, int nBottomRect);
    [DllImport("gdi32.dll")] public static extern int CombineRgn(IntPtr hrgnDest, IntPtr hrgnSrc1, IntPtr hrgnSrc2, int fnCombineMode);
    [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr hrgn, out RECT lprc);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);
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
    
    $w = $targetRect.Right - $targetRect.Left
    $h = $targetRect.Bottom - $targetRect.Top
    if ($w -le 0 -or $h -le 0) { return $false }
    
    # Get screen dimensions to filter out off-screen or oversized windows
    $screenW = [Win32]::GetSystemMetrics(0)
    $screenH = [Win32]::GetSystemMetrics(1)
    
    [Console]::Error.WriteLine("[dbg] IsWindowFullyOccluded: claudeRect=($($targetRect.Left),$($targetRect.Top),$($targetRect.Right),$($targetRect.Bottom)) screen=${screenW}x${screenH}")
    
    # Create Claude window region, then subtract each above window
    $claudeRgn = [Win32]::CreateRectRgn($targetRect.Left, $targetRect.Top, $targetRect.Right, $targetRect.Bottom)
    if ($claudeRgn -eq [IntPtr]::Zero) { return $false }
    
    try {
        $current = [Win32]::GetWindow($hwnd, 3)  # GW_HWNDPREV
        while ($current -ne [IntPtr]::Zero) {
            if ([Win32]::IsWindowVisible($current) -and -not [Win32]::IsIconic($current)) {
                $winPid = [uint32]0
                [Win32]::GetWindowThreadProcessId($current, [ref]$winPid) | Out-Null
                if (-not ($procIds -contains [int]$winPid)) {
                    $cloaked = 0
                    [Win32]::DwmGetWindowAttribute($current, 14, [ref]$cloaked, 4) | Out-Null
                    if ($cloaked -eq 0) {
                        $aboveRect = New-Object RECT
                        if ([Win32]::GetWindowRect($current, [ref]$aboveRect)) {
                            $aw = $aboveRect.Right - $aboveRect.Left
                            $ah = $aboveRect.Bottom - $aboveRect.Top
                            
                            $partiallyOnScreen = $aboveRect.Left -lt $screenW -and $aboveRect.Right -gt 0 -and
                                                   $aboveRect.Top -lt $screenH -and $aboveRect.Bottom -gt 0
                            $reasonableSize = $aw -le $screenW -and $ah -le $screenH
                            
                            $aboveName = (Get-Process -Id $winPid -ErrorAction SilentlyContinue).ProcessName
                            [Console]::Error.WriteLine("[dbg]   above: pid=$winPid name=$aboveName rect=($($aboveRect.Left),$($aboveRect.Top),$($aboveRect.Right),$($aboveRect.Bottom)) onScreen=$partiallyOnScreen reasonable=$reasonableSize")
                            
                            if ($aw -gt 0 -and $ah -gt 0 -and $partiallyOnScreen -and $reasonableSize -and
                                $aboveRect.Left -lt $targetRect.Right -and $aboveRect.Right -gt $targetRect.Left -and
                                $aboveRect.Top -lt $targetRect.Bottom -and $aboveRect.Bottom -gt $targetRect.Top) {
                                $aboveRgn = [Win32]::CreateRectRgn($aboveRect.Left, $aboveRect.Top, $aboveRect.Right, $aboveRect.Bottom)
                                if ($aboveRgn -ne [IntPtr]::Zero) {
                                    [Console]::Error.WriteLine("[dbg]   subtracting: pid=$winPid name=$aboveName")
                                    [Win32]::CombineRgn($claudeRgn, $claudeRgn, $aboveRgn, 4) | Out-Null
                                    [Win32]::DeleteObject($aboveRgn) | Out-Null
                                    
                                    $boxRect = New-Object RECT
                                    $rgnType = [Win32]::GetRgnBox($claudeRgn, [ref]$boxRect)
                                    [Console]::Error.WriteLine("[dbg]   after subtract: rgnType=$rgnType")
                                    if ($rgnType -eq 1) { 
                                        [Console]::Error.WriteLine("[dbg]   fully occluded!")
                                        return $true
                                    }
                                }
                            }
                        }
                    }
                }
            }
            $current = [Win32]::GetWindow($current, 3)
        }
    } finally {
        [Win32]::DeleteObject($claudeRgn) | Out-Null
    }
    
    [Console]::Error.WriteLine("[dbg]   result: not fully occluded")
    [Console]::Error.Flush()
    return $false
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
            Write-Output "Allow button detected (peek)"
            ClickButton $btn $procId | Out-Null
            Write-Output "Allow request processed"
            if ($script:minimizeAfterAllow) {
                $savedWp.showCmd = 6  # SW_MINIMIZE
                [Win32]::SetWindowPlacement($hwnd, [ref]$savedWp) | Out-Null
                EnableAnim $hwnd
            } else {
                EnableAnim $hwnd
                $savedWp.showCmd = 4  # SW_SHOWNOACTIVATE
                [Win32]::SetWindowPlacement($hwnd, [ref]$savedWp) | Out-Null
            }
            return $true
        }
    } catch { }
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
            Write-Output "Allow button detected (occluded)"
            # Move back before clicking
            [Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $origRect.Left, $origRect.Top, $pw, $ph, 0x0014)
            EnableAnim $hwnd
            ClickButton $btn $procId | Out-Null
            Write-Output "Allow request processed"
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


    [Console]::Error.WriteLine("[dbg] state: isMin=$isMin minimizedPolling=$minimizedPolling")
    if (-not $isMin) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
            $btn = FindAllowButton $root
            if ($btn) {
                Write-Output "Allow button detected"
                ClickButton $btn $p.Id
                Write-Output "Allow request processed"
                continue
            }
        } catch { Write-Output "  check err: $_" }

        # Window not minimized but button not found → check if fully occluded
        if ($minimizedPolling) {
            # Write-Output "  [dbg] not-min, polling=ON, checking occlusion..."
            $result = IsWindowFullyOccluded $hwnd $allClaudePids
            Write-Output "isOccluded=[$result]"
            if ($result) {
                # Write-Output "  [dbg] OCCLUDED → peek"

                [Console]::Error.WriteLine("[dbg] occluded=true, calling PeekOccluded")
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
    [Console]::Error.WriteLine("[dbg] window minimized, minimizedPolling=$minimizedPolling")
    # Write-Output "  [dbg] minimized, polling=$minimizedPolling"
    if ($minimizedPolling) {
        [Console]::Error.WriteLine("[dbg] minimized, calling PeekAndScan")
        if (PeekAndScan $hwnd $p.Id) { continue }
        Start-Sleep -Milliseconds $peekInterval
    } else {
        Start-Sleep -Milliseconds 1000
    }
}