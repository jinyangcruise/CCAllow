Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$targets = @("Allow", "Allow once", "Allow for this time", "Allow for this")
$running = $true

$reader = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput())
$readTask = $reader.ReadLineAsync()

while ($running) {
    if ($readTask.IsCompleted) {
        $line = $readTask.Result.Trim()
        if ($line -eq "exit") { $running = $false; break }
        $readTask = $reader.ReadLineAsync()
    }

    $procs = Get-Process -Name "claude" -ErrorAction SilentlyContinue
    foreach ($proc in $procs) {
        if ($proc.MainWindowHandle -eq 0) { continue }
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
            if (-not $root) { continue }

            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElementIdentifiers]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button)

            $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, $cond)
            if (-not $buttons -or $buttons.Count -eq 0) { continue }

            for ($i = 0; $i -lt $buttons.Count; $i++) {
                $btn = $buttons[$i]
                if (-not $btn.Current.IsEnabled) { continue }
                $name = $btn.Current.Name.Trim()
                foreach ($t in $targets) {
                    if ($name -eq $t) {
                        Write-Output "found: [$name]"
                        try {
                            $invoke = [System.Windows.Automation.InvokePattern]::GetPattern($btn)
                            if ($invoke) { $invoke.Invoke(); Write-Output "clicked: $t" }
                        } catch {
                            # fallback: try LegacyIAccessible
                            try {
                                $legacy = [System.Windows.Automation.LegacyIAccessiblePattern]::GetPattern($btn)
                                if ($legacy) { $legacy.DoDefaultAction(); Write-Output "clicked(legacy): $t" }
                            } catch { Write-Output "click failed: $t" }
                        }
                        break
                    }
                }
            }
        } catch { }
    }

    Start-Sleep -Milliseconds 300
}
