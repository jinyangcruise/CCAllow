Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

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
        Write-Output "proc: $($proc.ProcessName) hwnd=$($proc.MainWindowHandle)"
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
            if (-not $root) { Write-Output "  no UIA root"; continue }

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
                # Try Invoke pattern first (no interference)
                try {
                    $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
                    if ($invoke) { $invoke.Invoke(); Write-Output "clicked!"; continue }
                } catch { }
                # Send Ctrl+Enter keyboard shortcut to Claude window
                try {
                    $hwnd = $proc.MainWindowHandle
                    Add-Type -Name K -Member @"
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
"@ -ErrorAction Stop
                    [K]::SetForegroundWindow($hwnd) | Out-Null
                    Start-Sleep -Milliseconds 50
                    $VK_CONTROL = 0x11; $VK_RETURN = 0x0D
                    $WM_KEYDOWN = 0x100; $WM_KEYUP = 0x101
                    [K]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$VK_CONTROL, [IntPtr]::Zero) | Out-Null
                    Start-Sleep -Milliseconds 20
                    [K]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]::Zero) | Out-Null
                    Start-Sleep -Milliseconds 20
                    [K]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$VK_RETURN, [IntPtr]::Zero) | Out-Null
                    [K]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$VK_CONTROL, [IntPtr]::Zero) | Out-Null
                    Write-Output "clicked (Ctrl+Enter)!"
                } catch { Write-Output "key error: $_" }
            }
        } catch { Write-Output "  error: $_" }
    }

    Start-Sleep -Milliseconds 500
}
