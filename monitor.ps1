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
}

[StructLayout(LayoutKind.Sequential)]
public struct POINT {
    public int X; public int Y;
}

[StructLayout(LayoutKind.Sequential)]
public struct RECT {
    public int Left; public int Top; public int Right; public int Bottom;
}

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

$targets = @("Allow once", "Allow Once", "Allow for this time", "Allow for this")
$running = $true
$peekInterval = 2500
$minimizedPolling = $false
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

function ClickButton($btn, $procId) {
    $name = $btn.Current.Name.Trim()
    Write-Output "found: >>$name<<"
    try {
        $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
        if ($invoke) { $invoke.Invoke(); Write-Output "clicked!"; return }
    } catch { }
    try {
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

while ($running) {
    $loopCount++
    if ($loopCount % 10 -eq 0) { Write-Output "alive (loop $loopCount, polling=$minimizedPolling, interval=$peekInterval)" }
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

    # Check Claude window when NOT minimized
    if (-not $isMin) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
            $btn = FindAllowButton $root
            if ($btn) { ClickButton $btn $p.Id; continue }
        } catch { Write-Output "  check err: $_" }
        Start-Sleep -Milliseconds 400
        continue
    }

    # Claude IS minimized
    if ($minimizedPolling) {
        $wp = New-Object WINDOWPLACEMENT
        $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
        [Win32]::GetWindowPlacement($hwnd, [ref]$wp) | Out-Null
        $savedNormal = $wp.rcNormalPosition
        # Restore off-screen in a single SetWindowPlacement call
        $wp.showCmd = 9  # SW_RESTORE
        $wp.rcNormalPosition = New-Object RECT
        $wp.rcNormalPosition.Left = 4000; $wp.rcNormalPosition.Top = 3000
        $wp.rcNormalPosition.Right = 4100; $wp.rcNormalPosition.Bottom = 3100
        [Win32]::SetWindowPlacement($hwnd, [ref]$wp) | Out-Null
        Start-Sleep -Milliseconds 300
        Write-Output "  checking..."
        try {
            $btn = FindAllowButton ([System.Windows.Automation.AutomationElement]::FromHandle($hwnd))
            if ($btn) {
                # Restore original position
                $wp.rcNormalPosition = $savedNormal
                [Win32]::SetWindowPlacement($hwnd, [ref]$wp) | Out-Null
                ClickButton $btn $p.Id
                continue
            }
        } catch { }
        $wp.showCmd = 6  # SW_MINIMIZE
        $wp.rcNormalPosition = $savedNormal
        [Win32]::SetWindowPlacement($hwnd, [ref]$wp) | Out-Null
        Start-Sleep -Milliseconds $peekInterval
    } else {
        Start-Sleep -Milliseconds 1000
    }
}
