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
                # Try Invoke pattern
                try {
                    $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
                    if ($invoke) { $invoke.Invoke(); Write-Output "clicked!"; continue }
                } catch { }
                # Fallback: simulate mouse click at button center
                try {
                    $rect = $btn.Current.BoundingRectangle
                    if (-not $rect -or ($rect.Width -eq 0 -and $rect.Height -eq 0)) { Write-Output "no rect"; continue }
                    Add-Type -Name M -Member @"
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
"@ -ErrorAction Stop
                    $x = [int]($rect.Left + $rect.Width / 2)
                    $y = [int]($rect.Top + $rect.Height / 2)
                    [M]::SetCursorPos($x, $y) | Out-Null
                    Start-Sleep -Milliseconds 50
                    [M]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)  # down
                    [M]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)  # up
                    Write-Output "clicked (mouse)!"
                } catch { Write-Output "error: $_" }
            }
        } catch { Write-Output "  error: $_" }
    }

    Start-Sleep -Milliseconds 500
}
