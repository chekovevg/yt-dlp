$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-Module (Join-Path $PSScriptRoot "transcript-gui-model.psm1") -Force

function Get-TranscriptUiText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-TranscriptChoiceItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [AllowEmptyString()]
        [string]$Value
    )

    return [pscustomobject]@{
        Label = $Label
        Value = $Value
    }
}

function Set-TranscriptChoiceByValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ComboBox]$ComboBox,

        [AllowEmptyString()]
        [string]$Value
    )

    for ($index = 0; $index -lt $ComboBox.Items.Count; $index++) {
        if ([string]$ComboBox.Items[$index].Value -eq [string]$Value) {
            $ComboBox.SelectedIndex = $index
            return $true
        }
    }

    if ($ComboBox.Items.Count -gt 0) {
        $ComboBox.SelectedIndex = 0
    }

    return $false
}

function Set-TranscriptVideoCardProjects {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Card,

        [string[]]$Projects,

        [AllowEmptyString()]
        [string]$SelectedProject
    )

    $selection = if ($PSBoundParameters.ContainsKey("SelectedProject")) {
        [string]$SelectedProject
    }
    elseif ($Card.ProjectBox.SelectedItem) {
        [string]$Card.ProjectBox.SelectedItem.Value
    }
    else {
        ""
    }

    $Card.ProjectBox.BeginUpdate()
    try {
        $Card.ProjectBox.Items.Clear()
        [void]$Card.ProjectBox.Items.Add(
            (New-TranscriptChoiceItem -Label $Card.UiText.NoProject -Value "")
        )

        foreach ($project in @($Projects | Sort-Object -Unique)) {
            [void]$Card.ProjectBox.Items.Add(
                (New-TranscriptChoiceItem -Label $project -Value $project)
            )
        }

        [void](Set-TranscriptChoiceByValue -ComboBox $Card.ProjectBox -Value $selection)
    }
    finally {
        $Card.ProjectBox.EndUpdate()
    }
}

function New-TranscriptVideoCardView {
    param(
        [Parameter(Mandatory = $true)]
        [object]$UiText,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 6)]
        [int]$Index,

        [string[]]$Projects
    )

    $toolTip = New-Object System.Windows.Forms.ToolTip

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.AutoSize = $true
    $container.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $container.BackColor = [System.Drawing.Color]::White
    $container.CellBorderStyle = [System.Windows.Forms.TableLayoutPanelCellBorderStyle]::Single
    $container.ColumnCount = 1
    $container.Dock = [System.Windows.Forms.DockStyle]::Top
    $container.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $container.MinimumSize = New-Object System.Drawing.Size(640, 126)
    $container.Padding = New-Object System.Windows.Forms.Padding(10)
    $container.RowCount = 3
    [void]$container.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    [void]$container.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    [void]$container.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )

    $header = New-Object System.Windows.Forms.TableLayoutPanel
    $header.AutoSize = $true
    $header.ColumnCount = 2
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$header.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)
    )
    [void]$header.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )

    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.AutoSize = $true
    $headerLabel.Font = New-Object System.Drawing.Font(
        "Segoe UI",
        10,
        [System.Drawing.FontStyle]::Bold
    )
    $headerLabel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 6)
    $headerLabel.Text = $UiText.VideoFormat -f $Index
    $header.Controls.Add($headerLabel, 0, 0)

    $removeButton = New-Object System.Windows.Forms.Button
    $removeButton.AccessibleName = $UiText.RemoveRow
    $removeButton.AutoSize = $true
    $removeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $removeButton.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 4)
    $removeButton.Text = $UiText.RemoveRow
    $removeButton.Visible = ($Index -gt 1)
    $toolTip.SetToolTip($removeButton, $UiText.RemoveRow)
    $header.Controls.Add($removeButton, 1, 0)
    $container.Controls.Add($header, 0, 0)

    $inputRow = New-Object System.Windows.Forms.TableLayoutPanel
    $inputRow.AutoSize = $true
    $inputRow.ColumnCount = 3
    $inputRow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $inputRow.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    [void]$inputRow.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 58)
    )
    [void]$inputRow.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 22)
    )
    [void]$inputRow.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 20)
    )

    $urlHost = New-Object System.Windows.Forms.TableLayoutPanel
    $urlHost.AutoSize = $true
    $urlHost.ColumnCount = 2
    $urlHost.Dock = [System.Windows.Forms.DockStyle]::Fill
    $urlHost.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    [void]$urlHost.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)
    )
    [void]$urlHost.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )

    $urlBox = New-Object System.Windows.Forms.TextBox
    $urlBox.AccessibleName = $UiText.Url
    $urlBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $urlBox.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
    $urlHost.Controls.Add($urlBox, 0, 0)

    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.AccessibleName = $UiText.ClearUrl
    $clearButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $clearButton.Margin = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
    $clearButton.Size = New-Object System.Drawing.Size(30, 27)
    $clearButton.Text = $UiText.ClearGlyph
    $toolTip.SetToolTip($clearButton, $UiText.ClearUrl)
    $urlHost.Controls.Add($clearButton, 1, 0)
    $inputRow.Controls.Add($urlHost, 0, 0)

    $projectBox = New-Object System.Windows.Forms.ComboBox
    $projectBox.AccessibleName = $UiText.Project
    $projectBox.DisplayMember = "Label"
    $projectBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $projectBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $projectBox.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
    $inputRow.Controls.Add($projectBox, 1, 0)

    $createProjectButton = New-Object System.Windows.Forms.Button
    $createProjectButton.AccessibleName = $UiText.CreateProject
    $createProjectButton.AutoSize = $true
    $createProjectButton.Dock = [System.Windows.Forms.DockStyle]::Fill
    $createProjectButton.Margin = New-Object System.Windows.Forms.Padding(0)
    $createProjectButton.Text = $UiText.CreateProject
    $inputRow.Controls.Add($createProjectButton, 2, 0)
    $container.Controls.Add($inputRow, 0, 1)

    $statusRow = New-Object System.Windows.Forms.TableLayoutPanel
    $statusRow.AutoSize = $true
    $statusRow.ColumnCount = 3
    $statusRow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusRow.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$statusRow.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)
    )
    [void]$statusRow.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    [void]$statusRow.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.AccessibleName = $UiText.Idle
    $statusLabel.AutoEllipsis = $true
    $statusLabel.AutoSize = $true
    $statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 8, 0)
    $statusLabel.Text = $UiText.Idle
    $statusRow.Controls.Add($statusLabel, 0, 0)

    $copyTextButton = New-Object System.Windows.Forms.Button
    $copyTextButton.AccessibleName = $UiText.CopyText
    $copyTextButton.AutoSize = $true
    $copyTextButton.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $copyTextButton.Text = $UiText.CopyText
    $copyTextButton.Visible = $false
    $statusRow.Controls.Add($copyTextButton, 1, 0)

    $retryButton = New-Object System.Windows.Forms.Button
    $retryButton.AccessibleName = $UiText.Retry
    $retryButton.AutoSize = $true
    $retryButton.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $retryButton.Text = $UiText.Retry
    $retryButton.Visible = $false
    $statusRow.Controls.Add($retryButton, 2, 0)
    $container.Controls.Add($statusRow, 0, 2)

    $card = [pscustomobject]@{
        Id = [Guid]::NewGuid().ToString("N")
        UiText = $UiText
        Index = $Index
        State = "Idle"
        TextPath = $null
        Container = $container
        HeaderLabel = $headerLabel
        UrlBox = $urlBox
        ClearButton = $clearButton
        ProjectBox = $projectBox
        CreateProjectButton = $createProjectButton
        RemoveButton = $removeButton
        StatusLabel = $statusLabel
        CopyTextButton = $copyTextButton
        RetryButton = $retryButton
        ToolTip = $toolTip
    }

    Set-TranscriptVideoCardProjects -Card $card -Projects $Projects -SelectedProject ""
    return $card
}

function Set-TranscriptVideoCardIndex {
    param(
        [Parameter(Mandatory = $true)][object]$Card,
        [Parameter(Mandatory = $true)][ValidateRange(1, 6)][int]$Index
    )

    $Card.Index = $Index
    $Card.HeaderLabel.Text = $Card.UiText.VideoFormat -f $Index
    $Card.RemoveButton.Visible = ($Index -gt 1)
}

function Set-TranscriptVideoCardState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Card,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Idle", "Queued", "Running", "Success", "Error")]
        [string]$State,

        [AllowEmptyString()]
        [string]$Message
    )

    $defaultMessage = switch ($State) {
        "Idle" { $Card.UiText.Idle }
        "Queued" { $Card.UiText.Queued }
        "Running" { $Card.UiText.Checking }
        "Success" { $Card.UiText.Success }
        "Error" { $Card.UiText.Error }
    }

    $Card.State = $State
    $Card.StatusLabel.Text = if ($PSBoundParameters.ContainsKey("Message")) {
        [string]$Message
    }
    else {
        [string]$defaultMessage
    }
    $Card.CopyTextButton.Visible = ($State -eq "Success")
    $Card.RetryButton.Visible = ($State -eq "Error")
}

function New-TranscriptMainView {
    param(
        [Parameter(Mandatory = $true)]
        [object]$UiText,

        [Parameter(Mandatory = $true)]
        [object]$Settings,

        [string[]]$Projects
    )

    $form = New-Object System.Windows.Forms.Form
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.ClientSize = New-Object System.Drawing.Size(820, 620)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 520)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Text = $UiText.WindowTitle

    $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $rootLayout.ColumnCount = 1
    $rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rootLayout.Padding = New-Object System.Windows.Forms.Padding(16)
    $rootLayout.RowCount = 5
    [void]$rootLayout.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    [void]$rootLayout.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    [void]$rootLayout.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    [void]$rootLayout.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)
    )
    [void]$rootLayout.RowStyles.Add(
        [System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    $form.Controls.Add($rootLayout)

    $heading = New-Object System.Windows.Forms.Label
    $heading.AutoSize = $true
    $heading.Font = New-Object System.Drawing.Font(
        "Segoe UI",
        15,
        [System.Drawing.FontStyle]::Bold
    )
    $heading.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $heading.Text = $UiText.Heading
    $rootLayout.Controls.Add($heading, 0, 0)

    $settingsLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $settingsLayout.AutoSize = $true
    $settingsLayout.ColumnCount = 3
    $settingsLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $settingsLayout.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    $settingsLayout.RowCount = 2
    [void]$settingsLayout.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )
    [void]$settingsLayout.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)
    )
    [void]$settingsLayout.ColumnStyles.Add(
        [System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize)
    )

    $folderLabel = New-Object System.Windows.Forms.Label
    $folderLabel.AutoSize = $true
    $folderLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 12, 8)
    $folderLabel.Text = $UiText.SaveFolder
    $settingsLayout.Controls.Add($folderLabel, 0, 0)

    $rootBox = New-Object System.Windows.Forms.TextBox
    $rootBox.AccessibleName = $UiText.SaveFolder
    $rootBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rootBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 8)
    $rootBox.Text = [string]$Settings.OutputDir
    $settingsLayout.Controls.Add($rootBox, 1, 0)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.AccessibleName = $UiText.Browse
    $browseButton.AutoSize = $true
    $browseButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $browseButton.Text = $UiText.Browse
    $settingsLayout.Controls.Add($browseButton, 2, 0)

    $languageLabel = New-Object System.Windows.Forms.Label
    $languageLabel.AutoSize = $true
    $languageLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 12, 0)
    $languageLabel.Text = $UiText.Language
    $settingsLayout.Controls.Add($languageLabel, 0, 1)

    $languageBox = New-Object System.Windows.Forms.ComboBox
    $languageBox.AccessibleName = $UiText.Language
    $languageBox.DisplayMember = "Label"
    $languageBox.Dock = [System.Windows.Forms.DockStyle]::Left
    $languageBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $languageBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
    $languageBox.Width = 210
    foreach ($choice in @(
            (New-TranscriptChoiceItem -Label $UiText.LanguageAuto -Value "auto"),
            (New-TranscriptChoiceItem -Label $UiText.LanguageRu -Value "ru"),
            (New-TranscriptChoiceItem -Label $UiText.LanguageEn -Value "en"),
            (New-TranscriptChoiceItem -Label $UiText.LanguageDe -Value "de")
        )) {
        [void]$languageBox.Items.Add($choice)
    }
    [void](Set-TranscriptChoiceByValue -ComboBox $languageBox -Value ([string]$Settings.Language))
    $settingsLayout.Controls.Add($languageBox, 1, 1)
    $rootLayout.Controls.Add($settingsLayout, 0, 1)

    $videosHeader = New-Object System.Windows.Forms.FlowLayoutPanel
    $videosHeader.AutoSize = $true
    $videosHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
    $videosHeader.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $videosHeader.WrapContents = $false

    $videosLabel = New-Object System.Windows.Forms.Label
    $videosLabel.AutoSize = $true
    $videosLabel.Font = New-Object System.Drawing.Font(
        "Segoe UI",
        11,
        [System.Drawing.FontStyle]::Bold
    )
    $videosLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 14, 0)
    $videosLabel.Text = $UiText.Videos
    [void]$videosHeader.Controls.Add($videosLabel)

    $addVideoButton = New-Object System.Windows.Forms.Button
    $addVideoButton.AccessibleName = $UiText.AddVideo
    $addVideoButton.AutoSize = $true
    $addVideoButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $addVideoButton.Text = $UiText.AddVideo
    [void]$videosHeader.Controls.Add($addVideoButton)

    $cardCountLabel = New-Object System.Windows.Forms.Label
    $cardCountLabel.AutoSize = $true
    $cardCountLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
    $cardCountLabel.Text = $UiText.CardCountFormat -f 1
    [void]$videosHeader.Controls.Add($cardCountLabel)
    $rootLayout.Controls.Add($videosHeader, 0, 2)

    $videoList = New-Object System.Windows.Forms.FlowLayoutPanel
    $videoList.AutoScroll = $true
    $videoList.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $videoList.Dock = [System.Windows.Forms.DockStyle]::Fill
    $videoList.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $videoList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $videoList.Padding = New-Object System.Windows.Forms.Padding(8)
    $videoList.WrapContents = $false
    $rootLayout.Controls.Add($videoList, 0, 3)

    $footer = New-Object System.Windows.Forms.TableLayoutPanel
    $footer.AutoSize = $true
    $footer.ColumnCount = 1
    $footer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $footer.Margin = New-Object System.Windows.Forms.Padding(0)
    $footer.RowCount = 2

    $footerActions = New-Object System.Windows.Forms.FlowLayoutPanel
    $footerActions.AutoSize = $true
    $footerActions.Dock = [System.Windows.Forms.DockStyle]::Fill
    $footerActions.Margin = New-Object System.Windows.Forms.Padding(0)
    $footerActions.WrapContents = $false

    $saveQueueButton = New-Object System.Windows.Forms.Button
    $saveQueueButton.AccessibleName = $UiText.SaveVideos
    $saveQueueButton.AutoSize = $true
    $saveQueueButton.Font = New-Object System.Drawing.Font(
        "Segoe UI",
        9,
        [System.Drawing.FontStyle]::Bold
    )
    $saveQueueButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $saveQueueButton.Text = $UiText.SaveVideos
    [void]$footerActions.Controls.Add($saveQueueButton)

    $openRootButton = New-Object System.Windows.Forms.Button
    $openRootButton.AccessibleName = $UiText.OpenRoot
    $openRootButton.AutoSize = $true
    $openRootButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $openRootButton.Text = $UiText.OpenRoot
    [void]$footerActions.Controls.Add($openRootButton)

    $copyRootPathButton = New-Object System.Windows.Forms.Button
    $copyRootPathButton.AccessibleName = $UiText.CopyRootPath
    $copyRootPathButton.AutoSize = $true
    $copyRootPathButton.Margin = New-Object System.Windows.Forms.Padding(0)
    $copyRootPathButton.Text = $UiText.CopyRootPath
    [void]$footerActions.Controls.Add($copyRootPathButton)
    $footer.Controls.Add($footerActions, 0, 0)

    $globalStatusLabel = New-Object System.Windows.Forms.Label
    $globalStatusLabel.AccessibleName = $UiText.Ready
    $globalStatusLabel.AutoSize = $true
    $globalStatusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $globalStatusLabel.Text = $UiText.Ready
    $footer.Controls.Add($globalStatusLabel, 0, 1)
    $rootLayout.Controls.Add($footer, 0, 4)

    $form.AcceptButton = $saveQueueButton

    return [pscustomobject]@{
        Form = $form
        RootLayout = $rootLayout
        RootBox = $rootBox
        BrowseButton = $browseButton
        LanguageBox = $languageBox
        AddVideoButton = $addVideoButton
        CardCountLabel = $cardCountLabel
        VideoList = $videoList
        SaveQueueButton = $saveQueueButton
        OpenRootButton = $openRootButton
        CopyRootPathButton = $copyRootPathButton
        GlobalStatusLabel = $globalStatusLabel
        KeepSubtitlesBox = $null
    }
}

function Get-TranscriptProjectErrorText {
    param(
        [Parameter(Mandatory = $true)][object]$UiText,
        [Parameter(Mandatory = $true)][string]$Code
    )

    $property = $UiText.PSObject.Properties["ProjectError" + $Code]
    if ($property) {
        return [string]$property.Value
    }

    return ($UiText.ProjectErrorCreateFailed -f $Code)
}

function Show-TranscriptProjectDialog {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Owner,

        [Parameter(Mandatory = $true)]
        [object]$UiText,

        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.ClientSize = New-Object System.Drawing.Size(440, 170)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Text = $UiText.ProjectDialogTitle

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.ColumnCount = 1
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Padding = New-Object System.Windows.Forms.Padding(14)
    $layout.RowCount = 4
    $dialog.Controls.Add($layout)

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.Text = $UiText.ProjectName
    $layout.Controls.Add($label, 0, 0)

    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.AccessibleName = $UiText.ProjectName
    $nameBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nameBox.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
    $layout.Controls.Add($nameBox, 0, 1)

    $errorLabel = New-Object System.Windows.Forms.Label
    $errorLabel.AutoSize = $true
    $errorLabel.ForeColor = [System.Drawing.Color]::Firebrick
    $errorLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $layout.Controls.Add($errorLabel, 0, 2)

    $actions = New-Object System.Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true
    $actions.Dock = [System.Windows.Forms.DockStyle]::Right
    $actions.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.AccessibleName = $UiText.Cancel
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Text = $UiText.Cancel
    [void]$actions.Controls.Add($cancelButton)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.AccessibleName = $UiText.Ok
    $okButton.Text = $UiText.Ok
    [void]$actions.Controls.Add($okButton)
    $layout.Controls.Add($actions, 0, 3)

    $okButton.Add_Click({
        $validation = Get-TranscriptProjectNameValidation -Name $nameBox.Text
        if (-not $validation.IsValid) {
            $errorLabel.Text = Get-TranscriptProjectErrorText `
                -UiText $UiText `
                -Code $validation.ErrorCode
            $nameBox.Focus()
            return
        }

        try {
            [void](New-TranscriptProjectDirectory -RootDir $RootDir -Name $validation.Name)
            $dialog.Tag = $validation.Name
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
        catch {
            $errorLabel.Text = Get-TranscriptProjectErrorText `
                -UiText $UiText `
                -Code $_.Exception.Message
            $nameBox.Focus()
        }
    })

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    try {
        if ($dialog.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            return [string]$dialog.Tag
        }

        return $null
    }
    finally {
        $dialog.Dispose()
    }
}

Export-ModuleMember -Function @(
    "Get-TranscriptUiText",
    "New-TranscriptMainView",
    "New-TranscriptVideoCardView",
    "Set-TranscriptVideoCardIndex",
    "Set-TranscriptVideoCardProjects",
    "Set-TranscriptVideoCardState",
    "Show-TranscriptProjectDialog"
)
