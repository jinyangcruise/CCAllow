Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

# Win32 API via full C# class definition
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
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

                # 2. Try PostMessage Ctrl+Enter directly to Claude (no focus steal)
                try {
                    $hwnd = $proc.MainWindowHandle
                    [Win32]::PostMessage($hwnd, 0x100, [IntPtr]0x11, [IntPtr]::Zero) | Out-Null  # WM_KEYDOWN Ctrl
                    Start-Sleep -Milliseconds 20
                    [Win32]::PostMessage($hwnd, 0x100, [IntPtr]0x0D, [IntPtr]::Zero) | Out-Null  # WM_KEYDOWN Enter
                    Start-Sleep -Milliseconds 20
                    [Win32]::PostMessage($hwnd, 0x101, [IntPtr]0x0D, [IntPtr]::Zero) | Out-Null  # WM_KEYUP Enter
                    [Win32]::PostMessage($hwnd, 0x101, [IntPtr]0x11, [IntPtr]::Zero) | Out-Null  # WM_KEYUP Ctrl
                    Write-Output "clicked (PostMessage)!"
                    continue
                } catch { Write-Output "PostMessage error: $_" }

                # 3. Fallback: save foreground, activate Claude, SendKeys, restore
                try {
                    $prevHwnd = [Win32]::GetForegroundWindow()
                    $wshell = New-Object -ComObject wscript.shell
                    $wshell.AppActivate($proc.Id) | Out-Null
                    Start-Sleep -Milliseconds 100
                    [System.Windows.Forms.SendKeys]::SendWait("^({ENTER})")
                    # Restore previous window
                    if ($prevHwnd -and $prevHwnd -ne $proc.MainWindowHandle) {
                        [Win32]::SetForegroundWindow($prevHwnd) | Out-Null
                    }
                    Write-Output "clicked (SendKeys)!"
                } catch { Write-Output "key error: $_" }
            }
        } catch { Write-Output "error: $_" }
    }

    Start-Sleep -Milliseconds 500
}
