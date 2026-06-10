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
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
}
"@

$targets = @("Allow", "Allow once", "Allow for this time", "Allow for this")
$running = $true
$debugCounter = 0

$reader = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput())
$readTask = $reader.ReadLineAsync()

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
    # Try InvokePattern
    try {
        $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
        if ($invoke) { $invoke.Invoke(); Write-Output "clicked!"; return }
    } catch { }
    # Activate + SendKeys
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
    if ($readTask.IsCompleted) {
        $line = $readTask.Result.Trim()
        if ($line -eq "exit") { $running = $false; break }
        $readTask = $reader.ReadLineAsync()
    }

    $claudeProcs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'claude' } |
        Where-Object { $_.MainWindowHandle -ne 0 }

    if (-not $claudeProcs) { Start-Sleep -Milliseconds 500; continue }

    $claudePids = @{}
    foreach ($p in $claudeProcs) { $claudePids[$p.Id] = $p.MainWindowHandle }

    # 1) Check main Claude windows via UIA (works when not minimized)
    foreach ($p in $claudeProcs) {
        if ([Win32]::IsIconic($p.MainWindowHandle)) { continue }
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
            $btn = FindAllowButton $root
            if ($btn) { ClickButton $btn $p.Id }
        } catch { }
    }

    # 2) Periodically dump top-level windows for debugging
    $debugCounter++
    if ($debugCounter -ge 50) {
        $debugCounter = 0
        $isMin = [Win32]::IsIconic($claudeProcs[0].MainWindowHandle)
        Write-Output "--- top-level windows (minimized=$isMin) ---"
        [Win32]::EnumWindows({ param($h, $p)
            $t = New-Object System.Text.StringBuilder 256
            $c = New-Object System.Text.StringBuilder 64
            [Win32]::GetWindowText($h, $t, 256) | Out-Null
            [Win32]::GetClassName($h, $c, 64) | Out-Null
            $tt = $t.ToString().Trim()
            if ($tt -ne '') { Write-Output "  $($c.ToString().Trim()) : $tt" }
            return $true
        }, [IntPtr]::Zero) | Out-Null
        Write-Output "--- end ---"
    }

    Start-Sleep -Milliseconds 400
}
