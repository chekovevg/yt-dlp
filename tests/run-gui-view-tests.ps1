$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$viewPath = Join-Path $root "transcript-gui-view.psm1"
$textPath = Join-Path $root "ui-text.ru.json"

if (-not (Test-Path -LiteralPath $viewPath -PathType Leaf)) {
    throw "GUI view module is missing: $viewPath"
}

if (-not (Test-Path -LiteralPath $textPath -PathType Leaf)) {
    throw "Russian UI text resource is missing: $textPath"
}

Import-Module $viewPath -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$uiText = Get-TranscriptUiText -Path $textPath
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "transcript-gui-view-tests-" + [Guid]::NewGuid().ToString("N")
)
$mainView = $null
$firstCard = $null
$secondCard = $null

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    Assert-Equal ([int][char]$uiText.WindowTitle[0]) 1057 "Russian window title was not decoded as UTF-8."
    Assert-Equal ([int][char]$uiText.NoProject[0]) 1041 "Russian project label was not decoded as UTF-8."

    $mainView = New-TranscriptMainView `
        -UiText $uiText `
        -Settings ([pscustomobject]@{ OutputDir = $testRoot; KeepSubtitles = $false }) `
        -Projects @("Research")

    $expectedSaveText = '"\u0421\u043E\u0445\u0440\u0430\u043D\u0438\u0442\u044C \u0442\u0435\u043A\u0441\u0442"' |
        ConvertFrom-Json
    Assert-Equal $uiText.SaveVideos $expectedSaveText "Primary action still describes saving a video."
    Assert-Equal ($uiText.SaveVideosFormat -f 2) "$expectedSaveText (2)" "Counted primary action copy is incorrect."
    Assert-Equal $mainView.SaveQueueButton.Text $uiText.SaveVideos "Idle primary action does not use the save-text copy."
    Assert-True ($mainView.Form.MinimumSize.Width -ge 720) "Minimum window width is too small."
    Assert-True ($mainView.Form.MinimumSize.Height -ge 520) "Minimum window height is too small."
    Assert-True $mainView.VideoList.AutoScroll "Video list does not scroll."
    Assert-Equal $mainView.KeepSubtitlesBox $null "The removed VTT option is still exposed."
    Assert-True (-not $mainView.PSObject.Properties["LanguageBox"]) "The removed language selector is still exposed."
    Assert-True ($mainView.Form.AcceptButton -eq $mainView.SaveQueueButton) "Enter does not start the queue."
    Assert-Equal $mainView.AddVideoButton.AccessibleName $uiText.AddVideo "Add-video action lacks a name."
    Assert-Equal $mainView.OpenRootButton $null "The removed open-root button is still exposed."
    Assert-Equal $mainView.CopyRootPathButton $null "The removed copy-root button is still exposed."

    $firstCard = New-TranscriptVideoCardView `
        -UiText $uiText `
        -Index 1 `
        -Projects @("Research")
    $secondCard = New-TranscriptVideoCardView `
        -UiText $uiText `
        -Index 2 `
        -Projects @("Research")

    Assert-Equal $firstCard.HeaderLabel.Text ($uiText.VideoFormat -f 1) "First card heading changed."
    Assert-True (-not $firstCard.RemoveButton.Visible) "The required first card can be removed."
    Assert-True $secondCard.RemoveButton.Visible "An added card cannot be removed."
    Assert-Equal $secondCard.ClearButton.AccessibleName $uiText.ClearUrl "Clear action lacks a name."
    Assert-Equal `
        $secondCard.ToolTip.GetToolTip($secondCard.ClearButton) `
        $uiText.ClearUrl `
        "Clear action lacks a tooltip."
    Assert-Equal $secondCard.ProjectBox.SelectedItem.Value "" "Cards do not default to the root."
    Assert-Equal $secondCard.ProjectBox.Items.Count 2 "Project selector items changed."
    Assert-True `
        ($secondCard.CreateProjectButton.Dock -ne [System.Windows.Forms.DockStyle]::Fill) `
        "Create-project action stretches vertically across the card."
    Assert-True `
        ($secondCard.Container.MinimumSize.Height -eq 0) `
        "Card has an artificial minimum height."
    Assert-Equal $secondCard.CopyTextButton $null "The removed copy-text button is still exposed."
    Assert-True ($null -ne $secondCard.ResultContextMenu) "Result context menu is missing."
    Assert-Equal $secondCard.ResultContextMenu.Items.Count 3 "Result context menu item count changed."
    Assert-Equal `
        $secondCard.ResultContextMenu.Items[0] `
        $secondCard.CopyPathMenuItem `
        "Copy-path action is not first."
    Assert-Equal `
        $secondCard.ResultContextMenu.Items[1] `
        $secondCard.CopyContentsMenuItem `
        "Copy-contents action is not second."
    Assert-Equal `
        $secondCard.ResultContextMenu.Items[2] `
        $secondCard.ShowInExplorerMenuItem `
        "Show-in-Explorer action is not third."
    Assert-Equal `
        $secondCard.CopyPathMenuItem.Text `
        $uiText.CopyResultPath `
        "Copy-path text changed."
    Assert-Equal `
        $secondCard.CopyContentsMenuItem.Text `
        $uiText.CopyResultContents `
        "Copy-contents text changed."
    Assert-Equal `
        $secondCard.ShowInExplorerMenuItem.Text `
        $uiText.ShowResultInExplorer `
        "Show-in-Explorer text changed."
    Assert-True (-not $secondCard.ResultContextMenu.Enabled) "Result context menu is enabled before success."
    foreach ($control in @(
            $secondCard.Container,
            $secondCard.HeaderLabel,
            $secondCard.StatusLabel
        )) {
        Assert-True `
            ($control.ContextMenuStrip -eq $secondCard.ResultContextMenu) `
            "A card control does not share the result context menu."
    }
    Assert-True (-not $secondCard.RetryButton.Visible) "Retry action is visible before failure."

    $automaticMessage = Get-TranscriptCompletedMessage `
        -UiText $uiText `
        -TextPath (Join-Path $testRoot "automatic.txt") `
        -WarningCode "AutomaticOriginalAccuracy"
    Assert-True ($automaticMessage -match [regex]::Escape($uiText.WarningAutomaticOriginal)) "ASR warning is missing from the completed-card message."
    $manualMessage = Get-TranscriptCompletedMessage `
        -UiText $uiText `
        -TextPath (Join-Path $testRoot "manual.txt") `
        -WarningCode "ManualLanguageUnconfirmed"
    Assert-True ($manualMessage -match [regex]::Escape($uiText.WarningManualUnconfirmed)) "Unconfirmed-language warning is missing from the completed-card message."

    $secondCard.Container.MinimumSize = [System.Drawing.Size]::new(640, 0)
    $secondCard.Container.MaximumSize = [System.Drawing.Size]::new(640, 0)
    $secondCard.Container.Width = 640
    $secondCard.Container.PerformLayout()
    Assert-True (-not $secondCard.StatusLabel.AutoEllipsis) "Long quality warnings are still configured to truncate."
    Assert-True ($secondCard.StatusLabel.MaximumSize.Width -gt 0) "Quality warning label has no wrapping width."

    Set-TranscriptVideoCardState `
        -Card $secondCard `
        -State "Success" `
        -Message $automaticMessage
    Assert-True $secondCard.ResultContextMenu.Enabled "Result context menu is disabled after success."
    foreach ($control in @($secondCard.UrlBox, $secondCard.ProjectBox)) {
        Assert-True `
            ($control.ContextMenuStrip -eq $secondCard.ResultContextMenu) `
            "A focused card control cannot open result actions from the keyboard."
    }
    Assert-True (-not $secondCard.RetryButton.Visible) "Retry action is visible after success."
    Assert-Equal $secondCard.StatusLabel.Text $automaticMessage "Persistent success warning changed."
    Assert-Equal $secondCard.StatusLabel.AccessibleName $automaticMessage "Persistent warning is not exposed to assistive technology."
    Assert-Equal `
        $secondCard.Container.AccessibleDescription `
        $uiText.ResultContextHint `
        "Successful card lacks the context-menu accessibility hint."

    Set-TranscriptVideoCardState `
        -Card $secondCard `
        -State "Error" `
        -Message $uiText.Error
    Assert-True (-not $secondCard.ResultContextMenu.Enabled) "Result context menu is enabled after failure."
    foreach ($control in @($secondCard.UrlBox, $secondCard.ProjectBox)) {
        Assert-Equal `
            $control.ContextMenuStrip `
            $null `
            "A failed card overrides an input's native context menu."
    }
    Assert-True $secondCard.RetryButton.Visible "Retry action is hidden after failure."
    Assert-Equal $secondCard.StatusLabel.Text $uiText.Error "Error message changed."

    Set-TranscriptVideoCardProjects `
        -Card $secondCard `
        -Projects @("Research", "Writing") `
        -SelectedProject "Writing"
    Assert-Equal $secondCard.ProjectBox.SelectedItem.Value "Writing" "Created project was not selected."

    Set-TranscriptVideoCardProjects `
        -Card $secondCard `
        -Projects @("Research") `
        -SelectedProject "Writing"
    Assert-Equal $secondCard.ProjectBox.SelectedItem.Value "" "Missing project did not reset to root."

    Write-Host "PASS Russian resources load explicitly as UTF-8"
    Write-Host "PASS Main view is adaptive and keeps only the primary footer action"
    Write-Host "PASS Video cards expose result actions through a success-only context menu"
    Write-Host "PASS Completed cards preserve subtitle quality warnings"
    Write-Host "PASS Project selector refresh preserves only existing projects"
    Write-Host "5/5 GUI view tests passed."
}
finally {
    foreach ($card in @($firstCard, $secondCard)) {
        if ($card -and $card.Container) {
            $card.Container.Dispose()
        }
    }

    if ($mainView -and $mainView.Form) {
        $mainView.Form.Dispose()
    }

    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
