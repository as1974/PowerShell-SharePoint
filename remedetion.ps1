# Thüga Restart Manager - Remediation Script
Add-Type -AssemblyName System.Windows.Forms

# Registry configuration
$BasePath = "HKLM:\SOFTWARE\Thuega\RestartManager"
$DeadlineKey = "Deadline"
$TriggeredKey = "TriggeredNotifications"

# Function for custom popup with German buttons
function Show-RestartPrompt {
    param (
        [string]$Message,
        [string]$Title = "Windows Update Neustart"
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(520, 280)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $label.Size = New-Object System.Drawing.Size(480, 140)
    $label.Text = $Message
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $form.Controls.Add($label)

    $btnRestart = New-Object System.Windows.Forms.Button
    $btnRestart.Location = New-Object System.Drawing.Point(80, 180)
    $btnRestart.Size = New-Object System.Drawing.Size(180, 60)
    $btnRestart.Text = "Jetzt neu starten"
    $btnRestart.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $btnRestart.BackColor = "LightGreen"
    $btnRestart.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.AcceptButton = $btnRestart
    $form.Controls.Add($btnRestart)

    $btnLater = New-Object System.Windows.Forms.Button
    $btnLater.Location = New-Object System.Drawing.Point(280, 180)
    $btnLater.Size = New-Object System.Drawing.Size(180, 60)
    $btnLater.Text = "Später erinnern"
    $btnLater.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $btnLater.BackColor = "LightYellow"
    $btnLater.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.CancelButton = $btnLater
    $form.Controls.Add($btnLater)

    $result = $form.ShowDialog()
    return $result
}

# Cancel all production tasks
function Cancel-AllProductionTasks {
    $tasks = @("ForcedRestartProd", "Reminder0Prod", "Reminder1Prod", "Reminder2Prod")
    foreach ($task in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        } catch {
            Write-Host "Fehler beim Löschen der Task $task : $($_.Exception.Message)"
        }
    }
}

# Initialize registry path
function Initialize-RegistryPath {
    if (-not (Test-Path $BasePath)) {
        try {
            New-Item -Path $BasePath -Force -ErrorAction Stop | Out-Null
        } catch {
            throw "Fehler beim Erstellen des Registry-Pfads: $_"
        }
    }
}

# Save deadline to registry
function Save-DeadlineToRegistry {
    param([datetime]$Deadline)
    try {
        Initialize-RegistryPath
        $deadlineString = $Deadline.ToString("o")
        Set-ItemProperty -Path $BasePath -Name $DeadlineKey -Value $deadlineString -Force -ErrorAction Stop
    } catch {
        throw "Fehler beim Speichern der Deadline in Registry: $_"
    }
}

# Update triggered notifications in registry
function Update-TriggeredNotifications {
    param([string[]]$TriggeredHours)
    try {
        Initialize-RegistryPath
        $triggeredString = $TriggeredHours -join ","
        Set-ItemProperty -Path $BasePath -Name $TriggeredKey -Value $triggeredString -Force -ErrorAction Stop
    } catch {
        throw "Fehler beim Aktualisieren der Triggered Notifications: $_"
    }
}

# Get current logged-on user (robust version)
function Get-CurrentUser {
    try {
        # Method 1: Via WMI Explorer
        $user = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($user) { return $user }
        
        # Method 2: Via environment variable
        $user = $env:USERNAME
        if ($user) { return "$env:COMPUTERNAME\$user" }
        
        throw "Kein angemeldeter Benutzer erkannt"
    } catch {
        throw "Fehler beim Auslesen des aktuellen Benutzers: $_"
    }
}

# Schedule interactive task as current logged-on user
function Schedule-Task {
    param (
        [string]$TaskName,
        [datetime]$TriggerTime,
        [string]$ActionScript
    )
    try {
        # Remove existing task
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute 'Powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$ActionScript`""

        $trigger = New-ScheduledTaskTrigger -Once -At $TriggerTime

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
            -Hidden:$false `
            -StartWhenAvailable:$true

        $currentUser = Get-CurrentUser
        
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

        $task = Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $TaskName `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop
        
        if (-not $task) {
            throw "Task-Registrierung scheint fehlgeschlagen (null)"
        }
        
        Write-Host "Task '$TaskName' erfolgreich geplant für $TriggerTime"
    }
    catch {
        Write-Host "Fehler beim Planen von ${TaskName}: $($_.Exception.Message)"
        throw
    }
}

# ---------------------------------------------------------
# MAIN - 24-HOUR PRODUCTION VERSION (German)
# ---------------------------------------------------------

try {
    # Cleanup alte Tasks
    Cancel-AllProductionTasks

    $restartTime = (Get-Date).AddHours(24)

    # Erste Nachricht (Initialprompt)
    $initialMessage = "Ein Windows-Update erfordert in 24 Stunden einen Neustart des Geräts.`n`nBitte wählen Sie:`n- Jetzt neu starten`n- Später erinnern (wir melden uns wieder)"
    $result = Show-RestartPrompt -Message $initialMessage -Title "Windows Update - Neustart erforderlich"

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Cancel-AllProductionTasks
        # Cleanup Registry vor Neustart
        if (Test-Path $BasePath) {
            Remove-Item -Path $BasePath -Force -ErrorAction SilentlyContinue
        }
        Restart-Computer -Force
        exit 0
    }

    # Benutzer hat "Später erinnern" gewählt -> Deadline speichern
    Save-DeadlineToRegistry -Deadline $restartTime

    # Zwangs-Neustart nach 24 Stunden
    $restartScript = "shutdown /r /f /t 0"
    Schedule-Task -TaskName "ForcedRestartProd" -TriggerTime $restartTime -ActionScript $restartScript

    # Erinnerung 1: ca. 3 Stunden vorher
    $reminder1Time = $restartTime.AddHours(-3)
    $reminder1Msg = "Erinnerung: Zwangs-Neustart für Windows Update in ca. 3 Stunden.`n`nWas möchten Sie tun?"
    $reminder1Script = @"
    Add-Type -AssemblyName System.Windows.Forms;
    `$msg = '$reminder1Msg';
    `$form = New-Object System.Windows.Forms.Form;
    `$form.Text = 'Erinnerung: 3 Stunden verbleibend';
    `$form.Size = New-Object System.Drawing.Size(520,280);
    `$form.StartPosition = 'CenterScreen';
    `$form.FormBorderStyle = 'FixedDialog';
    `$form.TopMost = `$true;
    `$label = New-Object System.Windows.Forms.Label;
    `$label.Location = New-Object System.Drawing.Point(20,20);
    `$label.Size = New-Object System.Drawing.Size(480,140);
    `$label.Text = `$msg;
    `$label.Font = New-Object System.Drawing.Font('Segoe UI',11);
    `$form.Controls.Add(`$label);
    `$btnRestart = New-Object System.Windows.Forms.Button;
    `$btnRestart.Location = New-Object System.Drawing.Point(80,180);
    `$btnRestart.Size = New-Object System.Drawing.Size(180,60);
    `$btnRestart.Text = 'Jetzt neu starten';
    `$btnRestart.BackColor = 'LightGreen';
    `$btnRestart.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold);
    `$btnRestart.DialogResult = [System.Windows.Forms.DialogResult]::Yes;
    `$form.AcceptButton = `$btnRestart;
    `$form.Controls.Add(`$btnRestart);
    `$btnLater = New-Object System.Windows.Forms.Button;
    `$btnLater.Location = New-Object System.Drawing.Point(280,180);
    `$btnLater.Size = New-Object System.Drawing.Size(180,60);
    `$btnLater.Text = 'Später erinnern';
    `$btnLater.BackColor = 'LightYellow';
    `$btnLater.DialogResult = [System.Windows.Forms.DialogResult]::No;
    `$form.CancelButton = `$btnLater;
    `$form.Controls.Add(`$btnLater);
    `$result = `$form.ShowDialog();
    if (`$result -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
"@
    Schedule-Task -TaskName "Reminder0Prod" -TriggerTime $reminder1Time -ActionScript $reminder1Script

    # Erinnerung 2: ca. 1 Stunde vorher
    $reminder2Time = $restartTime.AddHours(-1)
    $reminder2Msg = "Erinnerung: Zwangs-Neustart in ca. 1 Stunde!`n`nBitte jetzt entscheiden:"
    $reminder2Script = @"
    Add-Type -AssemblyName System.Windows.Forms;
    `$msg = '$reminder2Msg';
    `$form = New-Object System.Windows.Forms.Form;
    `$form.Text = 'Erinnerung: 1 Stunde verbleibend';
    `$form.Size = New-Object System.Drawing.Size(520,280);
    `$form.StartPosition = 'CenterScreen';
    `$form.FormBorderStyle = 'FixedDialog';
    `$form.TopMost = `$true;
    `$label = New-Object System.Windows.Forms.Label;
    `$label.Location = New-Object System.Drawing.Point(20,20);
    `$label.Size = New-Object System.Drawing.Size(480,140);
    `$label.Text = `$msg;
    `$label.Font = New-Object System.Drawing.Font('Segoe UI',11);
    `$form.Controls.Add(`$label);
    `$btnRestart = New-Object System.Windows.Forms.Button;
    `$btnRestart.Location = New-Object System.Drawing.Point(80,180);
    `$btnRestart.Size = New-Object System.Drawing.Size(180,60);
    `$btnRestart.Text = 'Jetzt neu starten';
    `$btnRestart.BackColor = 'LightGreen';
    `$btnRestart.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold);
    `$btnRestart.DialogResult = [System.Windows.Forms.DialogResult]::Yes;
    `$form.AcceptButton = `$btnRestart;
    `$form.Controls.Add(`$btnRestart);
    `$btnLater = New-Object System.Windows.Forms.Button;
    `$btnLater.Location = New-Object System.Drawing.Point(280,180);
    `$btnLater.Size = New-Object System.Drawing.Size(180,60);
    `$btnLater.Text = 'Später erinnern';
    `$btnLater.BackColor = 'LightYellow';
    `$btnLater.DialogResult = [System.Windows.Forms.DialogResult]::No;
    `$form.CancelButton = `$btnLater;
    `$form.Controls.Add(`$btnLater);
    `$result = `$form.ShowDialog();
    if (`$result -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
"@
    Schedule-Task -TaskName "Reminder1Prod" -TriggerTime $reminder2Time -ActionScript $reminder2Script

    # Erinnerung 3: 15 Minuten vorher (dringend)
    $reminder3Time = $restartTime.AddMinutes(-15)
    $reminder3Msg = "LETZTE WARNUNG: Zwangs-Neustart in ca. 15 Minuten!`n`nBitte jetzt handeln:"
    $reminder3Script = @"
    Add-Type -AssemblyName System.Windows.Forms;
    `$msg = '$reminder3Msg';
    `$form = New-Object System.Windows.Forms.Form;
    `$form.Text = 'DRINGEND - 15 Minuten verbleibend';
    `$form.Size = New-Object System.Drawing.Size(520,280);
    `$form.StartPosition = 'CenterScreen';
    `$form.FormBorderStyle = 'FixedDialog';
    `$form.TopMost = `$true;
    `$label = New-Object System.Windows.Forms.Label;
    `$label.Location = New-Object System.Drawing.Point(20,20);
    `$label.Size = New-Object System.Drawing.Size(480,140);
    `$label.Text = `$msg;
    `$label.Font = New-Object System.Drawing.Font('Segoe UI',11);
    `$form.Controls.Add(`$label);
    `$btnRestart = New-Object System.Windows.Forms.Button;
    `$btnRestart.Location = New-Object System.Drawing.Point(80,180);
    `$btnRestart.Size = New-Object System.Drawing.Size(180,60);
    `$btnRestart.Text = 'Jetzt neu starten';
    `$btnRestart.BackColor = 'LightGreen';
    `$btnRestart.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold);
    `$btnRestart.DialogResult = [System.Windows.Forms.DialogResult]::Yes;
    `$form.AcceptButton = `$btnRestart;
    `$form.Controls.Add(`$btnRestart);
    `$btnLater = New-Object System.Windows.Forms.Button;
    `$btnLater.Location = New-Object System.Drawing.Point(280,180);
    `$btnLater.Size = New-Object System.Drawing.Size(180,60);
    `$btnLater.Text = 'Später erinnern';
    `$btnLater.BackColor = 'LightYellow';
    `$btnLater.DialogResult = [System.Windows.Forms.DialogResult]::No;
    `$form.CancelButton = `$btnLater;
    `$form.Controls.Add(`$btnLater);
    `$result = `$form.ShowDialog();
    if (`$result -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
"@
    Schedule-Task -TaskName "Reminder2Prod" -TriggerTime $reminder3Time -ActionScript $reminder3Script

    Write-Host "Produktionsversion (24 Stunden) erfolgreich geplant."
    Write-Host "Deadline: $($restartTime.ToString('o'))"
    exit 0

} catch {
    Write-Host "Fehler: $_"
    exit 1
}
