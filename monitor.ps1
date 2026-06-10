Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
}
"@

$targets = @("Allow once", "Allow for this time", "Allow for this")
$running = $true

$reader = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput())
$readTask = $reader.ReadLineAsync()

function CheckButton($hwnd) {
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        if (-not $root) { return $null }

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

function ClickButton($btn, $hwnd) {
    $name = $btn.Current.Name.Trim()
    Write-Output "found: >>$name<<"

    # 1. Try InvokePattern
    try {
        $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
        if ($invoke) { $invoke.Invoke(); Write-Output "clicked!"; return $true }
    } catch { }

    # 2. Activate + SendKeys Ctrl+Enter, then restore prev window
    try {
        $prevHwnd = [IntPtr]::Zero
        try { $prevHwnd = [Win32]::GetForegroundWindow() } catch { }
        $wshell = New-Object -ComObject wscript.shell
        if ($wshell) { $wshell.AppActivate($proc.Id) | Out-Null }
        Start-Sleep -Milliseconds 150
        [System.Windows.Forms.SendKeys]::SendWait("^({ENTER})")
        if ($prevHwnd -and $prevHwnd -ne [IntPtr]::Zero -and $prevHwnd -ne $hwnd) {
            try { [Win32]::SetForegroundWindow($prevHwnd) | Out-Null } catch { }
        }
        Write-Output "clicked (SendKeys)!"
        return $true
    } catch { Write-Output "key error: $_" }
    return $false
}

while ($running) {
    if ($readTask.IsCompleted) {
        $line = $readTask.Result.Trim()
        if ($line -eq "exit") { $running = $false; break }
        $readTask = $reader.ReadLineAsync()
    }

    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'claude' } |
        Where-Object { $_.MainWindowHandle -ne 0 }

    if (-not $procs) { Start-Sleep -Milliseconds 300; continue }

    foreach ($proc in $procs) {
        $hwnd = $proc.MainWindowHandle
        $wasMinimized = [Win32]::IsIconic($hwnd)

        # If minimized, briefly show without activation so UIA can access
        if ($wasMinimized) {
            [Win32]::ShowWindow($hwnd, 4) | Out-Null  # SW_SHOWNOACTIVATE
            Start-Sleep -Milliseconds 200
        }

        $btn = CheckButton($hwnd)

        if ($btn) {
            ClickButton $btn $hwnd
        }

        # If was minimized and no Allow found, minimize back
        if ($wasMinimized -and -not $btn) {
            [Win32]::ShowWindow($hwnd, 6) | Out-Null  # SW_MINIMIZE
        }
    }

    if ($wasMinimized) { Start-Sleep -Milliseconds 2500 } else { Start-Sleep -Milliseconds 500 }
}
