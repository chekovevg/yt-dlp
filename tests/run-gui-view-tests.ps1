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
        -Settings ([pscustomobject]@{ OutputDir = $testRoot; Language = "ru" }) `
        -Projects @("Research")

    Assert-True ($mainView.Form.MinimumSize.Width -ge 720) "Minimum window width is too small."
    Assert-True ($mainView.Form.MinimumSize.Height -ge 520) "Minimum window height is too small."
    Assert-True $mainView.VideoList.AutoScroll "Video list does not scroll."
    Assert-Equal $mainView.KeepSubtitlesBox $null "The removed VTT option is still exposed."
    Assert-Equal $mainView.LanguageBox.Items.Count 4 "Language choices changed."
    Assert-Equal $mainView.LanguageBox.SelectedItem.Value "ru" "Saved language was not selected."
    Assert-True ($mainView.Form.AcceptButton -eq $mainView.SaveQueueButton) "Enter does not start the queue."
    Assert-Equal $mainView.AddVideoButton.AccessibleName $uiText.AddVideo "Add-video action lacks a name."
    Assert-Equal $mainView.OpenRootButton.AccessibleName $uiText.OpenRoot "Open-root action lacks a name."

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
    Assert-True (-not $secondCard.CopyTextButton.Visible) "Copy action is visible before success."
    Assert-True (-not $secondCard.RetryButton.Visible) "Retry action is visible before failure."

    Set-TranscriptVideoCardState `
        -Card $secondCard `
        -State "Success" `
        -Message $uiText.Success
    Assert-True $secondCard.CopyTextButton.Visible "Copy action is hidden after success."
    Assert-True (-not $secondCard.RetryButton.Visible) "Retry action is visible after success."
    Assert-Equal $secondCard.StatusLabel.Text $uiText.Success "Success message changed."

    Set-TranscriptVideoCardState `
        -Card $secondCard `
        -State "Error" `
        -Message $uiText.Error
    Assert-True (-not $secondCard.CopyTextButton.Visible) "Copy action is visible after failure."
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
    Write-Host "PASS Main view is adaptive and exposes global actions"
    Write-Host "PASS Video cards distinguish clear, remove, success, and error actions"
    Write-Host "PASS Project selector refresh preserves only existing projects"
    Write-Host "4/4 GUI view tests passed."
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
