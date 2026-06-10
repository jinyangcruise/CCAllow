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
}
"@

$targets = @("Allow", "Allow once", "Allow Once", "Allow for this time", "Allow for this")
$running = $true
$peekInterval = 2500
$minimizedPolling = $false

$reader = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput())
$readTask = $reader.ReadLineAsync()

function HandleCommand($line) {
    if (-not $line) { return }
    if ($line -eq "exit") { $running = $false; return }
    if ($line -match '^interval:(\d+)$') { $peekInterval = [int]$Matches[1]; return }
    if ($line -eq "polling:on") { $minimizedPolling = $true; return }
    if ($line -eq "polling:off") { $minimizedPolling = $false; return }
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
            $btn = FindAllowButton ([System.Windows.Automation.AutomationElement]::FromHandle($hwnd))
            if ($btn) { ClickButton $btn $p.Id }
        } catch { }
        Start-Sleep -Milliseconds 400
        continue
    }

    # Claude IS minimized
    if ($minimizedPolling) {
        [Win32]::ShowWindow($hwnd, 4) | Out-Null
        Start-Sleep -Milliseconds 200
        try {
            $btn = FindAllowButton ([System.Windows.Automation.AutomationElement]::FromHandle($hwnd))
            if ($btn) { ClickButton $btn $p.Id; continue }
        } catch { }
        [Win32]::ShowWindow($hwnd, 6) | Out-Null
        Start-Sleep -Milliseconds $peekInterval
    } else {
        Start-Sleep -Milliseconds 1000
    }
}
