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
    public const int SW_RESTORE = 9;
}
"@

$targets = @("Allow once", "Allow for this time", "Allow for this")
$running = $true

$reader = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput())
$readTask = $reader.ReadLineAsync()

while ($running) {
    if ($readTask.IsCompleted) {
        $line = $readTask.Result.Trim()
        if ($line -eq "exit") { $running = $false; break }
        $readTask = $reader.ReadLineAsync()
    }

    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'claude' } |
        Where-Object { $_.MainWindowHandle -ne 0 }

    if (-not $procs) {
        Start-Sleep -Milliseconds 300
        continue
    }

    foreach ($proc in $procs) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
            if (-not $root) { Write-Output "no UIA root"; continue }

            $ctrlCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElementIdentifiers]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button)

            $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, $ctrlCond)

            for ($i = 0; $i -lt $buttons.Count; $i++) {
                $btn = $buttons[$i]
                $name = $btn.Current.Name.Trim()
                $enabled = $btn.Current.IsEnabled

                if (-not $enabled) { continue }
                $matched = $false
                foreach ($t in $targets) {
                    if ($name.StartsWith($t)) { $matched = $t; break }
                }
                if (-not $matched) { continue }
                Write-Output "found: >>$name<<"

                # 1. Try InvokePattern (no side effects)
                try {
                    $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
                    if ($invoke) { $invoke.Invoke(); Write-Output "clicked!"; continue }
                } catch { }

                # 2. Save foreground, restore Claude if minimized, SendKeys Ctrl+Enter, restore prev window
                try {
                    $prevHwnd = [IntPtr]::Zero
                    try { $prevHwnd = [Win32]::GetForegroundWindow() } catch { }
                    $hwnd = $proc.MainWindowHandle
                    if ($hwnd -ne [IntPtr]::Zero -and [Win32]::IsIconic($hwnd)) {
                        [Win32]::ShowWindow($hwnd, 9) | Out-Null  # SW_RESTORE
                        Start-Sleep -Milliseconds 200
                    }
                    $wshell = New-Object -ComObject wscript.shell
                    if ($wshell) { $wshell.AppActivate($proc.Id) | Out-Null }
                    Start-Sleep -Milliseconds 150
                    [System.Windows.Forms.SendKeys]::SendWait("^({ENTER})")
                    if ($prevHwnd -and $prevHwnd -ne [IntPtr]::Zero -and $prevHwnd -ne $hwnd) {
                        try { [Win32]::SetForegroundWindow($prevHwnd) | Out-Null } catch { }
                    }
                    Write-Output "clicked (SendKeys)!"
                } catch { Write-Output "key error: $_" }
            }
        } catch { Write-Output "error: $_" }
    }

    Start-Sleep -Milliseconds 500
}
