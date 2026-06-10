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
                try {
                    $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
                    if ($invoke) { $invoke.Invoke(); Write-Output "clicked!"; continue }
                } catch { }
                # Fallback: Win32 SendMessage BM_CLICK
                try {
                    $hwnd = [IntPtr] $btn.Current.NativeWindowHandle
                    if ($hwnd -eq 0) { Write-Output "no hwnd"; continue }
                    Add-Type -Name W32 -Member @"
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
"@ -ErrorAction Stop
                    [W32]::SendMessage($hwnd, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                    Write-Output "clicked (SendMessage)!"
                } catch { Write-Output "error: $_" }
            }
        } catch { Write-Output "  error: $_" }
    }

    Start-Sleep -Milliseconds 500
}
