$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSCommandPath
. (Join-Path $root "transcript-job-lifecycle.ps1")
Import-Module (Join-Path $root "transcript-tool.psm1") -Force

function New-Utf8String {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    [System.Text.Encoding]::UTF8.GetString($Bytes)
}

$uiText = @{
    Title = New-Utf8String @(208,161,208,190,209,133,209,128,208,176,208,189,208,181,208,189,208,184,208,181,32,209,130,208,181,208,186,209,129,209,130,208,176,32,89,111,117,84,117,98,101)
    SaveFolder = New-Utf8String @(208,159,208,176,208,191,208,186,208,176,32,209,129,208,190,209,133,209,128,208,176,208,189,208,181,208,189,208,184,209,143)
    Browse = New-Utf8String @(208,146,209,139,208,177,209,128,208,176,209,130,209,140,46,46,46)
    Language = New-Utf8String @(208,175,208,183,209,139,208,186,32,209,129,209,131,208,177,209,130,208,184,209,130,209,128,208,190,208,178)
    Keep = New-Utf8String @(208,161,208,190,209,133,209,128,208,176,208,189,209,143,209,130,209,140,32,209,130,208,176,208,186,208,182,208,181,32,208,190,209,128,208,184,208,179,208,184,208,189,208,176,208,187,209,140,208,189,209,139,208,181,32,209,129,209,131,208,177,209,130,208,184,209,130,209,128,209,139,44,32,208,181,209,129,208,187,208,184,32,208,180,208,190,209,129,209,130,209,131,208,191,208,189,209,139)
    Save = New-Utf8String @(208,161,208,190,209,133,209,128,208,176,208,189,208,184,209,130,209,140,32,209,130,208,181,208,186,209,129,209,130)
    OpenFolder = New-Utf8String @(208,158,209,130,208,186,209,128,209,139,209,130,209,140,32,208,191,208,176,208,191,208,186,209,131)
    Ready = New-Utf8String @(208,147,208,190,209,130,208,190,208,178,208,190,32,208,186,32,209,128,208,176,208,177,208,190,209,130,208,181)
    Checking = New-Utf8String @(208,159,209,128,208,190,208,178,208,181,209,128,209,143,209,142,32,209,129,209,129,209,139,208,187,208,186,209,131,46,46,46)
    Looking = New-Utf8String @(208,152,209,137,209,131,32,209,129,209,131,208,177,209,130,208,184,209,130,209,128,209,139,46,46,46)
    Saving = New-Utf8String @(208,161,208,190,209,133,209,128,208,176,208,189,209,143,209,142,32,209,132,208,176,208,185,208,187,46,46,46)
    Done = New-Utf8String @(208,147,208,190,209,130,208,190,208,178,208,190)
    Error = New-Utf8String @(208,158,209,136,208,184,208,177,208,186,208,176)
    NeedUrl = New-Utf8String @(208,146,209,129,209,130,208,176,208,178,209,140,209,130,208,181,32,209,129,209,129,209,139,208,187,208,186,209,131,32,208,189,208,176,32,89,111,117,84,117,98,101,45,208,178,208,184,208,180,208,181,208,190,46)
    NeedFolder = New-Utf8String @(208,146,209,139,208,177,208,181,209,128,208,184,209,130,208,181,32,208,191,208,176,208,191,208,186,209,131,32,208,180,208,187,209,143,32,209,129,208,190,209,133,209,128,208,176,208,189,208,181,208,189,208,184,209,143,32,209,132,208,176,208,185,208,187,208,190,208,178,46)
    FolderDialog = New-Utf8String @(208,146,209,139,208,177,208,181,209,128,208,184,209,130,208,181,32,208,191,208,176,208,191,208,186,209,131,32,208,180,208,187,209,143,32,209,129,208,190,209,133,209,128,208,176,208,189,208,181,208,189,208,184,209,143,32,209,130,208,181,208,186,209,129,209,130,208,176)
    DoneFormat = New-Utf8String @(208,147,208,190,209,130,208,190,208,178,208,190,32,45,32,209,129,208,190,209,133,209,128,208,176,208,189,208,181,208,189,209,139,32,209,129,209,131,208,177,209,130,208,184,209,130,209,128,209,139,58,32,123,48,125,32,40,123,49,125,41)
}

function Set-UiStatus {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Label]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $Label.Text = $Text
}

function Show-UserError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "YouTube Transcript Tool",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$settings = Read-TranscriptSettings

$form = New-Object System.Windows.Forms.Form
$form.Text = "YouTube Transcript Tool"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size(600, 360)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = $uiText.Title
$title.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 16)
$title.Size = New-Object System.Drawing.Size(540, 28)
$form.Controls.Add($title)

$linkLabel = New-Object System.Windows.Forms.Label
$linkLabel.Text = "YouTube link"
$linkLabel.Location = New-Object System.Drawing.Point(20, 58)
$linkLabel.Size = New-Object System.Drawing.Size(120, 20)
$form.Controls.Add($linkLabel)

$linkBox = New-Object System.Windows.Forms.TextBox
$linkBox.Location = New-Object System.Drawing.Point(20, 80)
$linkBox.Size = New-Object System.Drawing.Size(558, 24)
$linkBox.Anchor = "Left,Right,Top"
$form.Controls.Add($linkBox)

$folderLabel = New-Object System.Windows.Forms.Label
$folderLabel.Text = $uiText.SaveFolder
$folderLabel.Location = New-Object System.Drawing.Point(20, 120)
$folderLabel.Size = New-Object System.Drawing.Size(120, 20)
$form.Controls.Add($folderLabel)

$folderBox = New-Object System.Windows.Forms.TextBox
$folderBox.Location = New-Object System.Drawing.Point(20, 142)
$folderBox.Size = New-Object System.Drawing.Size(462, 24)
$folderBox.Text = [string]$settings.OutputDir
$form.Controls.Add($folderBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = $uiText.Browse
$browseButton.Location = New-Object System.Drawing.Point(492, 140)
$browseButton.Size = New-Object System.Drawing.Size(86, 28)
$form.Controls.Add($browseButton)

$languageLabel = New-Object System.Windows.Forms.Label
$languageLabel.Text = $uiText.Language
$languageLabel.Location = New-Object System.Drawing.Point(20, 184)
$languageLabel.Size = New-Object System.Drawing.Size(140, 20)
$form.Controls.Add($languageLabel)

$languageBox = New-Object System.Windows.Forms.ComboBox
$languageBox.DropDownStyle = "DropDownList"
$languageBox.Items.AddRange(@("auto", "ru", "en", "de"))
$languageBox.Location = New-Object System.Drawing.Point(20, 206)
$languageBox.Size = New-Object System.Drawing.Size(120, 24)
$languageBox.SelectedItem = [string]$settings.Language
if (-not $languageBox.SelectedItem) {
    $languageBox.SelectedIndex = 0
}
$form.Controls.Add($languageBox)

$keepBox = New-Object System.Windows.Forms.CheckBox
$keepBox.Text = $uiText.Keep
$keepBox.Location = New-Object System.Drawing.Point(170, 205)
$keepBox.Size = New-Object System.Drawing.Size(330, 24)
$keepBox.Checked = [bool]$settings.KeepSubtitles
$form.Controls.Add($keepBox)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = $uiText.Save
$saveButton.Location = New-Object System.Drawing.Point(20, 252)
$saveButton.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($saveButton)

$openFolderButton = New-Object System.Windows.Forms.Button
$openFolderButton.Text = $uiText.OpenFolder
$openFolderButton.Location = New-Object System.Drawing.Point(154, 252)
$openFolderButton.Size = New-Object System.Drawing.Size(112, 34)
$openFolderButton.Enabled = $false
$form.Controls.Add($openFolderButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = $uiText.Ready
$statusLabel.Location = New-Object System.Drawing.Point(20, 302)
$statusLabel.Size = New-Object System.Drawing.Size(558, 20)
$form.Controls.Add($statusLabel)

$resultBox = New-Object System.Windows.Forms.TextBox
$resultBox.Location = New-Object System.Drawing.Point(20, 326)
$resultBox.Size = New-Object System.Drawing.Size(558, 24)
$resultBox.ReadOnly = $true
$form.Controls.Add($resultBox)

$lastOutputDir = $folderBox.Text
$activeJob = $null
$activeResult = $null
$activeError = $null
$activeWorkerIdentity = $null
$activeProcessGroup = $null
$activeStartGate = $null
$activeWorkerIdentityPath = $null
$deferredCleanupTicket = $null

$jobTimer = New-Object System.Windows.Forms.Timer
$jobTimer.Interval = 200

$jobTimer.Add_Tick({
    $job = $script:activeJob
    if (-not $job) {
        $jobTimer.Stop()
        return
    }

    $receivedErrors = @()
    $messages = @(Receive-Job `
        -Job $job `
        -ErrorAction SilentlyContinue `
        -ErrorVariable +receivedErrors)
    $jobState = $job.State

    if ($jobState -in "Completed", "Failed", "Stopped") {
        $messages += @(Receive-Job `
            -Job $job `
            -ErrorAction SilentlyContinue `
            -ErrorVariable +receivedErrors)
    }

    if (-not $script:activeError -and $receivedErrors.Count -gt 0) {
        $script:activeError = $receivedErrors[0]
    }

    foreach ($message in $messages) {
        switch ([string]$message.Kind) {
            "Worker" {
                $script:activeWorkerIdentity = $message.Value

                try {
                    $script:activeProcessGroup = New-TranscriptProcessGroup `
                        -WorkerIdentity $script:activeWorkerIdentity
                }
                catch {
                    $script:activeError = $_
                    $jobTimer.Stop()
                    Request-ActiveTranscriptJobCleanup
                    $saveButton.Enabled = $true
                    $browseButton.Enabled = $true
                    $openFolderButton.Enabled = $false
                    Set-UiStatus -Label $statusLabel -Text $uiText.Error
                    Show-UserError $_.Exception.Message
                    $form.Close()
                    return
                }

                if ($script:activeStartGate) {
                    $startGate = $script:activeStartGate
                    $script:activeStartGate = $null

                    try {
                        [void]$startGate.Set()
                    }
                    finally {
                        $startGate.Dispose()
                    }
                }

                if ($script:activeWorkerIdentityPath) {
                    Remove-Item `
                        -LiteralPath $script:activeWorkerIdentityPath `
                        -Force `
                        -ErrorAction SilentlyContinue
                    $script:activeWorkerIdentityPath = $null
                }
            }
            "Status" {
                $status = [string]$message.Value
                switch ($status) {
                    "Checking link" { Set-UiStatus -Label $statusLabel -Text $uiText.Checking }
                    "Looking for subtitles" { Set-UiStatus -Label $statusLabel -Text $uiText.Looking }
                    "Saving file" { Set-UiStatus -Label $statusLabel -Text $uiText.Saving }
                    "Done" { Set-UiStatus -Label $statusLabel -Text $uiText.Done }
                    default { Set-UiStatus -Label $statusLabel -Text $status }
                }
            }
            "Result" {
                $script:activeResult = $message.Value
            }
        }
    }

    if ($jobState -notin "Completed", "Failed", "Stopped") {
        return
    }

    $jobTimer.Stop()

    if (-not $script:activeError) {
        $script:activeError = $job.ChildJobs |
            ForEach-Object { $_.Error } |
            Select-Object -First 1
    }

    $result = $script:activeResult
    $jobError = $script:activeError
    $jobReason = $job.JobStateInfo.Reason

    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if ($script:activeProcessGroup) {
        $script:activeProcessGroup.Dispose()
    }
    $script:activeJob = $null
    $script:activeResult = $null
    $script:activeError = $null
    $script:activeWorkerIdentity = $null
    $script:activeProcessGroup = $null

    if ($script:activeStartGate) {
        $script:activeStartGate.Dispose()
        $script:activeStartGate = $null
    }

    if ($script:activeWorkerIdentityPath) {
        Remove-Item `
            -LiteralPath $script:activeWorkerIdentityPath `
            -Force `
            -ErrorAction SilentlyContinue
        $script:activeWorkerIdentityPath = $null
    }

    $saveButton.Enabled = $true
    $browseButton.Enabled = $true

    if ($jobState -eq "Completed" -and $result) {
        $script:lastOutputDir = [string]$result.OutputDir
        $resultBox.Text = [string]$result.TextPath
        $openFolderButton.Enabled = $true
        Set-UiStatus -Label $statusLabel -Text ($uiText.DoneFormat -f $result.Language, $result.Source)
        return
    }

    $openFolderButton.Enabled = $false
    Set-UiStatus -Label $statusLabel -Text $uiText.Error

    $errorMessage = if ($jobError -and $jobError.Exception -and $jobError.Exception.Message) {
        $jobError.Exception.Message
    }
    elseif ($jobError) {
        [string]$jobError
    }
    elseif ($jobReason -and $jobReason.Message) {
        $jobReason.Message
    }
    else {
        "The transcript save did not return a result."
    }

    Show-UserError $errorMessage
})

function Request-ActiveTranscriptJobCleanup {
    $job = $script:activeJob
    if (-not $job) {
        return
    }

    if ($script:activeStartGate) {
        $script:activeStartGate.Dispose()
        $script:activeStartGate = $null
    }

    $script:deferredCleanupTicket = Request-TranscriptBackgroundJobStop `
        -Job $job `
        -ProcessGroup $script:activeProcessGroup `
        -WorkerIdentity $script:activeWorkerIdentity `
        -WorkerIdentityPath $script:activeWorkerIdentityPath `
        -UiDeadlineMilliseconds 1500

    $script:activeJob = $null
    $script:activeResult = $null
    $script:activeError = $null
    $script:activeWorkerIdentity = $null
    $script:activeProcessGroup = $null
    $script:activeWorkerIdentityPath = $null
}

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $uiText.FolderDialog
    $dialog.SelectedPath = $folderBox.Text

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $folderBox.Text = $dialog.SelectedPath
    }
})

$openFolderButton.Add_Click({
    $target = if ($lastOutputDir) { $lastOutputDir } else { $folderBox.Text }

    if ($target -and (Test-Path -LiteralPath $target)) {
        Start-Process explorer.exe -ArgumentList @($target)
    }
})

$saveButton.Add_Click({
    $url = $linkBox.Text.Trim()
    $outputDir = $folderBox.Text.Trim()
    $language = [string]$languageBox.SelectedItem
    $keepSubtitles = [bool]$keepBox.Checked

    if (-not $url) {
        Show-UserError $uiText.NeedUrl
        return
    }

    if (-not $outputDir) {
        Show-UserError $uiText.NeedFolder
        return
    }

    $saveButton.Enabled = $false
    $browseButton.Enabled = $false
    $openFolderButton.Enabled = $false
    $resultBox.Text = ""

    try {
        Write-TranscriptSettings -OutputDir $outputDir -Language $language -KeepSubtitles:$keepSubtitles

        $modulePath = Join-Path $root "transcript-tool.psm1"
        $script:activeResult = $null
        $script:activeError = $null
        $script:activeWorkerIdentity = $null
        $script:activeProcessGroup = $null
        $startGateName = "Local\YouTubeTranscriptTool-" + [Guid]::NewGuid().ToString("N")
        $script:activeWorkerIdentityPath = Join-Path `
            ([System.IO.Path]::GetTempPath()) `
            ("youtube-transcript-tool-worker-" + [Guid]::NewGuid().ToString("N") + ".json")
        $script:activeStartGate = New-Object System.Threading.EventWaitHandle -ArgumentList @(
            $false,
            [System.Threading.EventResetMode]::ManualReset,
            $startGateName
        )
        $script:activeJob = Start-Job `
            -ArgumentList @(
                $modulePath,
                $url,
                $outputDir,
                $language,
                $keepSubtitles,
                $startGateName,
                $script:activeWorkerIdentityPath
            ) `
            -ScriptBlock {
                param(
                    $modulePath,
                    $url,
                    $outputDir,
                    $language,
                    $keepSubtitles,
                    $startGateName,
                    $workerIdentityPath
                )

                $ErrorActionPreference = "Stop"
                $workerProcess = [System.Diagnostics.Process]::GetCurrentProcess()
                $workerIdentity = [pscustomobject]@{
                    Id = $PID
                    CreationFileTimeUtc = $workerProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
                }
                [System.IO.File]::WriteAllText(
                    $workerIdentityPath,
                    ($workerIdentity | ConvertTo-Json -Compress)
                )
                $startGate = [System.Threading.EventWaitHandle]::OpenExisting($startGateName)

                try {
                    [pscustomobject]@{
                        Kind = "Worker"
                        Value = $workerIdentity
                    }

                    [void]$startGate.WaitOne()
                }
                finally {
                    $startGate.Dispose()
                }

                Import-Module $modulePath -Force

                Save-TranscriptFromYoutube `
                    -Url $url `
                    -OutputDir $outputDir `
                    -Language $language `
                    -KeepSubtitles:$keepSubtitles `
                    -OnStatus {
                        param($status)
                        [pscustomobject]@{
                            Kind = "Status"
                            Value = $status
                        }
                    } |
                    ForEach-Object {
                        if ([string]$_.Kind -eq "Status") {
                            $_
                        }
                        else {
                            [pscustomobject]@{
                                Kind = "Result"
                                Value = $_
                            }
                        }
                    }
                }

        $jobTimer.Start()
    }
    catch {
        $jobTimer.Stop()

        if ($script:activeJob) {
            Request-ActiveTranscriptJobCleanup
        }
        elseif ($script:activeStartGate) {
            $script:activeStartGate.Dispose()
            $script:activeStartGate = $null
        }

        if ($script:activeWorkerIdentityPath) {
            Remove-Item `
                -LiteralPath $script:activeWorkerIdentityPath `
                -Force `
                -ErrorAction SilentlyContinue
            $script:activeWorkerIdentityPath = $null
        }

        $script:activeResult = $null
        $script:activeError = $null
        $script:activeWorkerIdentity = $null
        $script:activeProcessGroup = $null
        Set-UiStatus -Label $statusLabel -Text $uiText.Error
        Show-UserError $_.Exception.Message
        $saveButton.Enabled = $true
        $browseButton.Enabled = $true

        if ($script:deferredCleanupTicket) {
            $form.Close()
        }
    }
})

$form.Add_FormClosing({
    $jobTimer.Stop()

    if ($script:activeJob -and -not $script:deferredCleanupTicket) {
        Request-ActiveTranscriptJobCleanup
    }
    elseif ($script:activeStartGate) {
        $script:activeStartGate.Dispose()
        $script:activeStartGate = $null
    }

    if ($script:activeWorkerIdentityPath -and -not $script:deferredCleanupTicket) {
        Remove-Item `
            -LiteralPath $script:activeWorkerIdentityPath `
            -Force `
            -ErrorAction SilentlyContinue
        $script:activeWorkerIdentityPath = $null
    }

    $script:activeResult = $null
    $script:activeError = $null
    $script:activeWorkerIdentity = $null
    $script:activeProcessGroup = $null
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
$jobTimer.Dispose()

if ($script:deferredCleanupTicket) {
    Complete-TranscriptBackgroundJobCleanup -Ticket $script:deferredCleanupTicket
    $script:deferredCleanupTicket = $null
}
