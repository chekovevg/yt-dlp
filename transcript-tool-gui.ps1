$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSCommandPath
. (Join-Path $root "transcript-job-lifecycle.ps1")
Import-Module (Join-Path $root "transcript-tool.psm1") -Force
Import-Module (Join-Path $root "transcript-gui-model.psm1") -Force
Import-Module (Join-Path $root "transcript-gui-view.psm1") -Force

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:uiText = Get-TranscriptUiText -Path (Join-Path $root "ui-text.ru.json")
$settings = Read-TranscriptSettings
$initialProjects = Get-TranscriptProjectNames -RootDir ([string]$settings.OutputDir)
$script:view = New-TranscriptMainView `
    -UiText $script:uiText `
    -Settings $settings `
    -Projects $initialProjects
$script:cards = New-Object System.Collections.ArrayList
$script:isBusy = $false
$script:queueState = $null
$script:currentItem = $null
$script:currentCard = $null
$script:deferredCleanupTicket = $null

$script:activeJob = $null
$script:activeResult = $null
$script:activeError = $null
$script:activeWorkerIdentity = $null
$script:activeProcessGroup = $null
$script:activeStartGate = $null
$script:activeWorkerIdentityPath = $null
$script:activeOperationId = $null
$script:activeTemporaryDirectory = $null
$script:activeStagingRoot = $null
$script:activeOutputDir = $null

$script:jobTimer = New-Object System.Windows.Forms.Timer
$script:jobTimer.Interval = 200

function Get-TranscriptCardById {
    param([Parameter(Mandatory = $true)][string]$CardId)

    return $script:cards |
        Where-Object { $_.Id -eq $CardId } |
        Select-Object -First 1
}

function Get-TranscriptCardProjectName {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($Card.ProjectBox.SelectedItem) {
        return [string]$Card.ProjectBox.SelectedItem.Value
    }

    return ""
}

function Get-TranscriptRootPath {
    $value = $script:view.RootBox.Text.Trim()
    if (-not $value) {
        throw [System.ArgumentException]::new("OutputDirectoryMissing")
    }

    return [System.IO.Path]::GetFullPath($value)
}

function Ensure-TranscriptRootDirectory {
    $rootPath = Get-TranscriptRootPath
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
        }
        catch {
            throw [System.IO.DirectoryNotFoundException]::new(
                "OutputDirectoryMissing",
                $_.Exception
            )
        }
    }

    return $rootPath
}

function Set-TranscriptGlobalStatus {
    param([Parameter(Mandatory = $true)][string]$Text)

    $script:view.GlobalStatusLabel.Text = $Text
    $script:view.GlobalStatusLabel.AccessibleName = $Text
}

function Resize-TranscriptVideoCards {
    $availableWidth = [Math]::Max(
        640,
        $script:view.VideoList.ClientSize.Width -
            [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 28
    )

    foreach ($card in $script:cards) {
        $card.Container.MinimumSize = New-Object System.Drawing.Size($availableWidth, 0)
        $card.Container.MaximumSize = New-Object System.Drawing.Size($availableWidth, 0)
        $card.Container.Width = $availableWidth
    }
}

function Update-TranscriptQueueActions {
    $filledCount = @(
        $script:cards |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.UrlBox.Text) }
    ).Count

    $script:view.CardCountLabel.Text = $script:uiText.CardCountFormat -f $script:cards.Count
    $script:view.AddVideoButton.Enabled = (-not $script:isBusy -and $script:cards.Count -lt 6)
    $script:view.SaveQueueButton.Enabled = (-not $script:isBusy -and $filledCount -gt 0)
    $script:view.SaveQueueButton.Text = if ($filledCount -gt 0) {
        $script:uiText.SaveVideosFormat -f $filledCount
    }
    else {
        $script:uiText.SaveVideos
    }
}

function Set-TranscriptUiBusy {
    param([Parameter(Mandatory = $true)][bool]$Busy)

    $script:isBusy = $Busy
    $script:view.RootBox.Enabled = -not $Busy
    $script:view.BrowseButton.Enabled = -not $Busy

    foreach ($card in $script:cards) {
        $card.UrlBox.Enabled = -not $Busy
        $card.ClearButton.Enabled = -not $Busy
        $card.ProjectBox.Enabled = -not $Busy
        $card.CreateProjectButton.Enabled = -not $Busy
        $card.RemoveButton.Enabled = -not $Busy
        $card.ResultContextMenu.Enabled = (
            -not $Busy -and
            $card.State -eq "Success" -and
            -not [string]::IsNullOrWhiteSpace([string]$card.TextPath)
        )
        $card.RetryButton.Enabled = -not $Busy
    }

    Update-TranscriptQueueActions
}

function Refresh-TranscriptProjectSelectors {
    param(
        [object]$OriginatingCard,
        [AllowEmptyString()][string]$SelectProject
    )

    try {
        $projects = Get-TranscriptProjectNames -RootDir (Get-TranscriptRootPath)
    }
    catch {
        $projects = @()
    }

    foreach ($card in $script:cards) {
        $selection = if ($OriginatingCard -and $card.Id -eq $OriginatingCard.Id) {
            [string]$SelectProject
        }
        else {
            Get-TranscriptCardProjectName -Card $card
        }

        Set-TranscriptVideoCardProjects `
            -Card $card `
            -Projects $projects `
            -SelectedProject $selection
    }
}

function Renumber-TranscriptCards {
    for ($index = 0; $index -lt $script:cards.Count; $index++) {
        Set-TranscriptVideoCardIndex -Card $script:cards[$index] -Index ($index + 1)
    }

    Update-TranscriptQueueActions
    Resize-TranscriptVideoCards
}

function Clear-TranscriptCardUrl {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($script:isBusy) {
        return
    }

    $Card.UrlBox.Clear()
    $Card.TextPath = $null
    Set-TranscriptVideoCardState -Card $Card -State "Idle"
    $Card.UrlBox.Focus()
    Update-TranscriptQueueActions
}

function Remove-TranscriptCard {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($script:isBusy -or $script:cards.Count -le 1 -or $Card.Index -eq 1) {
        return
    }

    $script:view.VideoList.Controls.Remove($Card.Container)
    [void]$script:cards.Remove($Card)
    $Card.ToolTip.Dispose()
    $Card.ResultContextMenu.Dispose()
    $Card.Container.Dispose()
    Renumber-TranscriptCards
}

function Create-TranscriptProjectForCard {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($script:isBusy) {
        return
    }

    try {
        $rootPath = Ensure-TranscriptRootDirectory
        $projectName = Show-TranscriptProjectDialog `
            -Owner $script:view.Form `
            -UiText $script:uiText `
            -RootDir $rootPath
        if ($projectName) {
            Refresh-TranscriptProjectSelectors `
                -OriginatingCard $Card `
                -SelectProject $projectName
            Set-TranscriptGlobalStatus `
                -Text ($script:uiText.ProjectCreatedFormat -f $projectName)
        }
    }
    catch {
        Set-TranscriptGlobalStatus `
            -Text ($script:uiText.ProjectErrorCreateFailed -f $_.Exception.Message)
    }
}

function Set-TranscriptCardResultActionError {
    param(
        [Parameter(Mandatory = $true)][object]$Card,
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $isMissing = $ErrorRecord.Exception.Message -eq "ResultFileMissing"
    $message = if ($isMissing) {
        $script:uiText.ResultFileMissing
    }
    else {
        $script:uiText.ResultActionFailedFormat -f $ErrorRecord.Exception.Message
    }

    Set-TranscriptVideoCardState -Card $Card -State "Success" -Message $message
    if ($isMissing) {
        $Card.ResultContextMenu.Enabled = $false
    }
}

function Copy-TranscriptCardPath {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($script:isBusy -or -not $Card.TextPath) {
        return
    }

    try {
        $path = Resolve-TranscriptResultFilePath -Path $Card.TextPath
        [System.Windows.Forms.Clipboard]::SetText($path)
        Set-TranscriptVideoCardState `
            -Card $Card `
            -State "Success" `
            -Message $script:uiText.PathCopied
    }
    catch {
        Set-TranscriptCardResultActionError -Card $Card -ErrorRecord $_
    }
}

function Copy-TranscriptCardContents {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($script:isBusy -or -not $Card.TextPath) {
        return
    }

    try {
        $text = Read-TranscriptResultFileText -Path $Card.TextPath
        [System.Windows.Forms.Clipboard]::SetText($text)
        Set-TranscriptVideoCardState `
            -Card $Card `
            -State "Success" `
            -Message $script:uiText.TextCopied
    }
    catch {
        Set-TranscriptCardResultActionError -Card $Card -ErrorRecord $_
    }
}

function Show-TranscriptCardInExplorer {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($script:isBusy -or -not $Card.TextPath) {
        return
    }

    try {
        $argument = Get-TranscriptExplorerSelectArgument -Path $Card.TextPath
        Start-Process -FilePath "explorer.exe" -ArgumentList @($argument)
        Set-TranscriptVideoCardState `
            -Card $Card `
            -State "Success" `
            -Message $script:uiText.ShownInExplorer
    }
    catch {
        Set-TranscriptCardResultActionError -Card $Card -ErrorRecord $_
    }
}

function Add-TranscriptVideoCard {
    if ($script:isBusy -or $script:cards.Count -ge 6) {
        return $null
    }

    try {
        $projects = Get-TranscriptProjectNames -RootDir (Get-TranscriptRootPath)
    }
    catch {
        $projects = @()
    }

    $card = New-TranscriptVideoCardView `
        -UiText $script:uiText `
        -Index ($script:cards.Count + 1) `
        -Projects $projects
    [void]$script:cards.Add($card)
    [void]$script:view.VideoList.Controls.Add($card.Container)

    $eventCard = $card
    $card.ClearButton.Add_Click({
        Clear-TranscriptCardUrl -Card $eventCard
    }.GetNewClosure())
    $card.RemoveButton.Add_Click({
        Remove-TranscriptCard -Card $eventCard
    }.GetNewClosure())
    $card.CreateProjectButton.Add_Click({
        Create-TranscriptProjectForCard -Card $eventCard
    }.GetNewClosure())
    $card.CopyPathMenuItem.Add_Click({
        Copy-TranscriptCardPath -Card $eventCard
    }.GetNewClosure())
    $card.CopyContentsMenuItem.Add_Click({
        Copy-TranscriptCardContents -Card $eventCard
    }.GetNewClosure())
    $card.ShowInExplorerMenuItem.Add_Click({
        Show-TranscriptCardInExplorer -Card $eventCard
    }.GetNewClosure())
    $card.RetryButton.Add_Click({
        Start-TranscriptCardRetry -Card $eventCard
    }.GetNewClosure())
    $card.UrlBox.Add_TextChanged({
        if (-not $script:isBusy -and $eventCard.State -in "Success", "Error") {
            $eventCard.TextPath = $null
            Set-TranscriptVideoCardState -Card $eventCard -State "Idle"
        }
        Update-TranscriptQueueActions
    }.GetNewClosure())

    Renumber-TranscriptCards
    return $card
}

function Reset-ActiveTranscriptJobState {
    if ($script:activeProcessGroup) {
        $script:activeProcessGroup.Dispose()
    }

    if ($script:activeStartGate) {
        $script:activeStartGate.Dispose()
    }

    if ($script:activeWorkerIdentityPath) {
        Remove-Item `
            -LiteralPath $script:activeWorkerIdentityPath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    $script:activeJob = $null
    $script:activeResult = $null
    $script:activeError = $null
    $script:activeWorkerIdentity = $null
    $script:activeProcessGroup = $null
    $script:activeStartGate = $null
    $script:activeWorkerIdentityPath = $null
    $script:activeOperationId = $null
    $script:activeTemporaryDirectory = $null
    $script:activeStagingRoot = $null
    $script:activeOutputDir = $null
}

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
        -OperationId $script:activeOperationId `
        -OutputDir $script:activeOutputDir `
        -TemporaryDirectory $script:activeTemporaryDirectory `
        -StagingRoot $script:activeStagingRoot `
        -UiDeadlineMilliseconds 1500

    $script:activeJob = $null
    $script:activeResult = $null
    $script:activeError = $null
    $script:activeWorkerIdentity = $null
    $script:activeProcessGroup = $null
    $script:activeWorkerIdentityPath = $null
    $script:activeOperationId = $null
    $script:activeTemporaryDirectory = $null
    $script:activeStagingRoot = $null
    $script:activeOutputDir = $null
}

function Get-TranscriptJobErrorMessage {
    param(
        [object]$JobError,
        [object]$JobReason
    )

    if ($JobError -and $JobError.Exception -and $JobError.Exception.Message) {
        return [string]$JobError.Exception.Message
    }

    if ($JobError) {
        return [string]$JobError
    }

    if ($JobReason -and $JobReason.Message) {
        return [string]$JobReason.Message
    }

    return $script:uiText.NoResult
}

function Complete-CurrentTranscriptQueueItem {
    param(
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [object]$Result,
        [string]$ErrorMessage
    )

    $card = $script:currentCard
    if ($Succeeded -and $Result) {
        $card.TextPath = [string]$Result.TextPath
        Set-TranscriptVideoCardState `
            -Card $card `
            -State "Success" `
            -Message (Get-TranscriptCompletedMessage `
                -UiText $script:uiText `
                -TextPath $card.TextPath `
                -WarningCode ([string]$Result.WarningCode))
        $card.ResultContextMenu.Enabled = -not $script:isBusy
    }
    else {
        $card.TextPath = $null
        Set-TranscriptVideoCardState `
            -Card $card `
            -State "Error" `
            -Message $ErrorMessage
    }

    Move-TranscriptQueueNext -State $script:queueState -Succeeded $Succeeded
    $script:currentItem = $null
    $script:currentCard = $null

    if ($script:queueState.IsRunning) {
        Start-NextTranscriptQueueItem
        return
    }

    $summary = Get-TranscriptQueueSummary -State $script:queueState
    Set-TranscriptUiBusy -Busy $false
    Set-TranscriptGlobalStatus `
        -Text ($script:uiText.SummaryFormat -f $summary.Completed, $summary.Failed)
}

function Start-ActiveTranscriptItem {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][object]$Card
    )

    $modulePath = Join-Path $root "transcript-tool.psm1"
    $workerScriptPath = Join-Path $root "transcript-worker.ps1"
    $script:activeResult = $null
    $script:activeError = $null
    $script:activeWorkerIdentity = $null
    $script:activeProcessGroup = $null
    $script:activeOperationId = [Guid]::NewGuid().ToString("N")
    $script:activeOutputDir = [string]$Item.OutputDir
    $script:activeTemporaryDirectory = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("youtube-transcript-tool-" + $script:activeOperationId)
    $script:activeStagingRoot = Join-Path `
        $script:activeOutputDir `
        (".youtube-transcript-operation-" + $script:activeOperationId)
    $startGateName = "Local\YouTubeTranscriptTool-" + [Guid]::NewGuid().ToString("N")
    $script:activeWorkerIdentityPath = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("youtube-transcript-tool-worker-" + [Guid]::NewGuid().ToString("N") + ".json")
    $script:activeStartGate = New-Object System.Threading.EventWaitHandle -ArgumentList @(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $startGateName
    )

    try {
        $script:activeJob = Start-Job `
            -ArgumentList @(
                $modulePath,
                $workerScriptPath,
                [string]$Item.Url,
                [string]$Item.OutputDir,
                $startGateName,
                $script:activeWorkerIdentityPath,
                $script:activeOperationId
            ) `
            -ScriptBlock {
                param(
                    $modulePath,
                    $workerScriptPath,
                    $url,
                    $outputDir,
                    $startGateName,
                    $workerIdentityPath,
                    $operationId
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
                Invoke-TranscriptWorkerProcess `
                    -WorkerScriptPath $workerScriptPath `
                    -ArgumentList @(
                        "-Url", $url,
                        "-OutputDir", $outputDir,
                        "-KeepSubtitles", "0",
                        "-OperationId", $operationId
                    )
            }

        $script:jobTimer.Start()
    }
    catch {
        $script:jobTimer.Stop()
        if ($script:activeJob) {
            Request-ActiveTranscriptJobCleanup
        }
        else {
            Reset-ActiveTranscriptJobState
        }

        Complete-CurrentTranscriptQueueItem `
            -Succeeded $false `
            -ErrorMessage $_.Exception.Message
    }
}

function Start-NextTranscriptQueueItem {
    $item = Get-TranscriptQueueCurrentItem -State $script:queueState
    if (-not $item) {
        return
    }

    $card = Get-TranscriptCardById -CardId $item.CardId
    if (-not $card) {
        Complete-CurrentTranscriptQueueItem `
            -Succeeded $false `
            -ErrorMessage $script:uiText.Error
        return
    }

    $script:currentItem = $item
    $script:currentCard = $card
    Set-TranscriptVideoCardState `
        -Card $card `
        -State "Running" `
        -Message $script:uiText.Checking
    Start-ActiveTranscriptItem -Item $item -Card $card
}

function Start-TranscriptQueue {
    param([object[]]$Rows)

    if ($script:isBusy) {
        return
    }

    try {
        $rootPath = Ensure-TranscriptRootDirectory
        $plan = @(
            New-TranscriptBatchPlan `
                -Rows $Rows `
                -RootDir $rootPath
        )
        Assert-TranscriptOutputDirectoriesWritable `
            -OutputDirs @($plan | ForEach-Object { $_.OutputDir })
        Write-TranscriptSettings `
            -OutputDir $rootPath `
            -KeepSubtitles:$false

        foreach ($item in $plan) {
            $card = Get-TranscriptCardById -CardId $item.CardId
            $card.TextPath = $null
            Set-TranscriptVideoCardState -Card $card -State "Queued"
        }

        $script:queueState = New-TranscriptQueueState -Items $plan
        Set-TranscriptUiBusy -Busy $true
        Start-NextTranscriptQueueItem
    }
    catch {
        $message = switch ($_.Exception.Message) {
            "NoVideos" { $script:uiText.NeedUrl }
            "ProjectMissing" { $script:uiText.ProjectMissing }
            "OutputDirectoryMissing" { $script:uiText.OutputDirectoryMissing }
            "OutputDirectoryNotWritable" { $script:uiText.OutputDirectoryNotWritable }
            default { $_.Exception.Message }
        }

        Set-TranscriptGlobalStatus -Text $message
        if ($_.Exception.Message -eq "ProjectMissing") {
            Refresh-TranscriptProjectSelectors
        }
        elseif ($script:cards.Count -gt 0) {
            $script:cards[0].UrlBox.Focus()
        }
    }
}

function Start-AllTranscriptCards {
    $rows = @(
        $script:cards | ForEach-Object {
            [pscustomobject]@{
                CardId = $_.Id
                Url = $_.UrlBox.Text
                ProjectName = Get-TranscriptCardProjectName -Card $_
            }
        }
    )
    Start-TranscriptQueue -Rows $rows
}

function Start-TranscriptCardRetry {
    param([Parameter(Mandatory = $true)][object]$Card)

    if ($script:isBusy) {
        return
    }

    Start-TranscriptQueue -Rows @(
        [pscustomobject]@{
            CardId = $Card.Id
            Url = $Card.UrlBox.Text
            ProjectName = Get-TranscriptCardProjectName -Card $Card
        }
    )
}

$script:jobTimer.Add_Tick({
    $job = $script:activeJob
    if (-not $job) {
        $script:jobTimer.Stop()
        return
    }

    $receivedErrors = @()
    $messages = @(
        Receive-Job `
            -Job $job `
            -ErrorAction SilentlyContinue `
            -ErrorVariable +receivedErrors
    )
    $jobState = $job.State

    if ($jobState -in "Completed", "Failed", "Stopped") {
        $messages += @(
            Receive-Job `
                -Job $job `
                -ErrorAction SilentlyContinue `
                -ErrorVariable +receivedErrors
        )
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
                    $script:jobTimer.Stop()
                    Request-ActiveTranscriptJobCleanup
                    Set-TranscriptGlobalStatus -Text $_.Exception.Message
                    $script:view.Form.Close()
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
                $status = switch ([string]$message.Value) {
                    "Checking link" { $script:uiText.Checking }
                    "Looking for subtitles" { $script:uiText.Looking }
                    "Saving file" { $script:uiText.Saving }
                    "Done" { $script:uiText.Success }
                    default { [string]$message.Value }
                }
                Set-TranscriptVideoCardState `
                    -Card $script:currentCard `
                    -State "Running" `
                    -Message $status
            }
            "Result" {
                $script:activeResult = $message.Value
            }
        }
    }

    if ($jobState -notin "Completed", "Failed", "Stopped") {
        return
    }

    $script:jobTimer.Stop()
    if (-not $script:activeError) {
        $script:activeError = $job.ChildJobs |
            ForEach-Object { $_.Error } |
            Select-Object -First 1
    }

    $result = $script:activeResult
    $jobError = $script:activeError
    $jobReason = $job.JobStateInfo.Reason
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Reset-ActiveTranscriptJobState

    if ($jobState -eq "Completed" -and $result) {
        Complete-CurrentTranscriptQueueItem -Succeeded $true -Result $result
    }
    else {
        Complete-CurrentTranscriptQueueItem `
            -Succeeded $false `
            -ErrorMessage (Get-TranscriptJobErrorMessage -JobError $jobError -JobReason $jobReason)
    }
})

$script:view.AddVideoButton.Add_Click({
    [void](Add-TranscriptVideoCard)
})

$script:view.BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $script:uiText.SaveFolder
    if (Test-Path -LiteralPath $script:view.RootBox.Text -PathType Container) {
        $dialog.SelectedPath = $script:view.RootBox.Text
    }

    if ($dialog.ShowDialog($script:view.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:view.RootBox.Text = $dialog.SelectedPath
        Refresh-TranscriptProjectSelectors
        Set-TranscriptGlobalStatus -Text $script:uiText.Ready
    }

    $dialog.Dispose()
})

$script:view.RootBox.Add_Leave({
    Refresh-TranscriptProjectSelectors
})

$script:view.SaveQueueButton.Add_Click({
    Start-AllTranscriptCards
})

$script:view.VideoList.Add_SizeChanged({
    Resize-TranscriptVideoCards
})

$script:view.Form.Add_Shown({
    Resize-TranscriptVideoCards
    if ($script:cards.Count -gt 0) {
        $script:cards[0].UrlBox.Focus()
    }
})

$script:view.Form.Add_FormClosing({
    $script:jobTimer.Stop()
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
})

[void](Add-TranscriptVideoCard)
Update-TranscriptQueueActions
[System.Windows.Forms.Application]::Run($script:view.Form)
$script:jobTimer.Dispose()

if ($script:deferredCleanupTicket) {
    Complete-TranscriptBackgroundJobCleanup -Ticket $script:deferredCleanupTicket
    $script:deferredCleanupTicket = $null
}
