Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CachePath = Join-Path $script:AppRoot 'esi-name-cache.json'

function Get-EsiNameCache {
    if (-not (Test-Path -LiteralPath $script:CachePath)) {
        return @{}
    }

    $raw = Get-Content -LiteralPath $script:CachePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $parsed = $raw | ConvertFrom-Json
    $cache = @{}
    foreach ($item in $parsed.PSObject.Properties) {
        $cache[$item.Name] = [string]$item.Value
    }
    return $cache
}

function Save-EsiNameCache {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    $ordered = [ordered]@{}
    foreach ($key in ($Cache.Keys | Sort-Object)) {
        $ordered[$key] = $Cache[$key]
    }

    $ordered | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:CachePath -Encoding UTF8
}

function Find-EveSettingsFolders {
    $roots = @()
    if ($env:LOCALAPPDATA) {
        $roots += (Join-Path $env:LOCALAPPDATA 'CCP\EVE')
    }

    $folders = New-Object System.Collections.Generic.List[string]
    foreach ($root in ($roots | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'settings_*' } |
            ForEach-Object {
                $folders.Add($_.FullName)
            }
    }

    if (Test-Path -LiteralPath $script:AppRoot) {
        $folders.Add($script:AppRoot)
    }

    $folders.ToArray() | Sort-Object -Unique
}

function Resolve-EsiCharacterNames {
    param(
        [Parameter(Mandatory)]
        [string[]]$CharacterIds
    )

    $cache = Get-EsiNameCache
    $names = @{}
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($id in ($CharacterIds | Sort-Object -Unique)) {
        if ($cache.ContainsKey($id)) {
            $names[$id] = $cache[$id]
        }
        else {
            $missing.Add($id)
        }
    }

    if ($missing.Count -gt 0) {
        try {
            $body = $missing.ToArray() | ConvertTo-Json
            $response = Invoke-RestMethod -Method Post -Uri 'https://esi.evetech.net/latest/universe/names/' -ContentType 'application/json' -Body $body
            foreach ($item in $response) {
                if ($item.category -eq 'character') {
                    $names[[string]$item.id] = [string]$item.name
                    $cache[[string]$item.id] = [string]$item.name
                }
            }
            Save-EsiNameCache -Cache $cache
        }
        catch {
            foreach ($id in $missing) {
                $names[$id] = "Unknown [$id]"
            }
        }
    }

    foreach ($id in $CharacterIds) {
        if (-not $names.ContainsKey($id)) {
            $names[$id] = "Unknown [$id]"
        }
    }

    return $names
}

function Get-ClosestUserFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$CharFile,

        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$UserFiles
    )

    if (-not $UserFiles -or $UserFiles.Count -eq 0) {
        return $null
    }

    $nearest = $UserFiles |
        Sort-Object { [math]::Abs(($_.LastWriteTimeUtc - $CharFile.LastWriteTimeUtc).TotalSeconds) } |
        Select-Object -First 1

    if (-not $nearest) {
        return $null
    }

    return $nearest
}

function Get-EveProfiles {
    param(
        [Parameter(Mandatory)]
        [string]$SettingsFolder
    )

    $charFiles = @(Get-ChildItem -LiteralPath $SettingsFolder -File -Filter 'core_char_*.dat' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^core_char_(\d+)$' })
    $userFiles = @(Get-ChildItem -LiteralPath $SettingsFolder -File -Filter 'core_user_*.dat' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^core_user_(\d+)$' })

    $charIds = @($charFiles | ForEach-Object { [regex]::Match($_.BaseName, '^core_char_(\d+)$').Groups[1].Value })
    $names = Resolve-EsiCharacterNames -CharacterIds $charIds

    $profiles = foreach ($charFile in ($charFiles | Sort-Object LastWriteTime -Descending)) {
        $charId = [regex]::Match($charFile.BaseName, '^core_char_(\d+)$').Groups[1].Value
        $userFile = Get-ClosestUserFile -CharFile $charFile -UserFiles $userFiles

        [pscustomobject]@{
            Name = $names[$charId]
            CharId = $charId
            CharFile = $charFile.FullName
            UserId = if ($userFile) { [regex]::Match($userFile.BaseName, '^core_user_(\d+)$').Groups[1].Value } else { $null }
            UserFile = if ($userFile) { $userFile.FullName } else { $null }
        }
    }

    return @($profiles | Sort-Object Name)
}

function Backup-EveFile {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $backupRoot = Join-Path (Split-Path -Parent $FilePath) 'backups'
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destDir = Join-Path $backupRoot $timestamp
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
    }

    Copy-Item -LiteralPath $FilePath -Destination (Join-Path $destDir ([System.IO.Path]::GetFileName($FilePath))) -Force
}

function Copy-EveSettings {
    param(
        [Parameter(Mandatory)]
        [object]$SourceProfile,

        [Parameter(Mandatory)]
        [object[]]$TargetProfiles,

        [Parameter(Mandatory)]
        [bool]$CopyChar,

        [Parameter(Mandatory)]
        [bool]$CopyUser
    )

    if (-not $CopyChar -and -not $CopyUser) {
        throw 'Choose at least one of core_char or core_user.'
    }

    $copiedUsers = @{}
    foreach ($target in $TargetProfiles) {
        if ($target.CharId -eq $SourceProfile.CharId) {
            continue
        }

        if ($CopyChar) {
            Backup-EveFile -FilePath $target.CharFile
            Copy-Item -LiteralPath $SourceProfile.CharFile -Destination $target.CharFile -Force
        }

        if ($CopyUser -and $SourceProfile.UserFile -and $target.UserFile -and -not $copiedUsers.ContainsKey($target.UserFile)) {
            Backup-EveFile -FilePath $target.UserFile
            Copy-Item -LiteralPath $SourceProfile.UserFile -Destination $target.UserFile -Force
            $copiedUsers[$target.UserFile] = $true
        }
    }
}

function Set-DarkStyle {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.Control]$Control
    )

    $bg = [System.Drawing.Color]::FromArgb(13, 16, 22)
    $panel = [System.Drawing.Color]::FromArgb(22, 27, 36)
    $input = [System.Drawing.Color]::FromArgb(28, 34, 45)
    $text = [System.Drawing.Color]::FromArgb(236, 239, 244)

    switch ($Control.GetType().Name) {
        'Form' {
            $Control.BackColor = $bg
            $Control.ForeColor = $text
        }
        'Panel' {
            $Control.BackColor = $panel
            $Control.ForeColor = $text
        }
        'Label' {
            $Control.BackColor = [System.Drawing.Color]::Transparent
            $Control.ForeColor = $text
        }
        'Button' {
            $Control.BackColor = [System.Drawing.Color]::FromArgb(42, 50, 66)
            $Control.ForeColor = $text
            $Control.FlatStyle = 'Flat'
            $Control.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(76, 91, 112)
        }
        'ComboBox' {
            $Control.BackColor = $input
            $Control.ForeColor = $text
            $Control.FlatStyle = 'Flat'
        }
        'ListBox' {
            $Control.BackColor = $input
            $Control.ForeColor = $text
            $Control.BorderStyle = 'FixedSingle'
        }
        'CheckedListBox' {
            $Control.BackColor = $input
            $Control.ForeColor = $text
            $Control.BorderStyle = 'FixedSingle'
        }
        'CheckBox' {
            $Control.BackColor = [System.Drawing.Color]::Transparent
            $Control.ForeColor = $text
        }
        'TextBox' {
            $Control.BackColor = $input
            $Control.ForeColor = $text
            $Control.BorderStyle = 'FixedSingle'
        }
    }
}

function New-UiLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height = 22
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    Set-DarkStyle -Control $label
    return $label
}

function New-CardPanel {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(22, 27, 36)
    $panel.BorderStyle = 'FixedSingle'
    return $panel
}

function Start-EveLayoutManager {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'EVE Layout Copier'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(980, 720)
    $form.MinimumSize = New-Object System.Drawing.Size(980, 720)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    Set-DarkStyle -Control $form

    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(980, 110)
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(16, 21, 30)
    $headerPanel.Anchor = 'Top, Left, Right'

    $accentBar = New-Object System.Windows.Forms.Panel
    $accentBar.Location = New-Object System.Drawing.Point(0, 0)
    $accentBar.Size = New-Object System.Drawing.Size(980, 6)
    $accentBar.BackColor = [System.Drawing.Color]::FromArgb(201, 146, 66)
    $accentBar.Anchor = 'Top, Left, Right'

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'EVE Layout Copier'
    $titleLabel.Location = New-Object System.Drawing.Point(26, 18)
    $titleLabel.Size = New-Object System.Drawing.Size(460, 38)
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 22, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(246, 239, 224)
    $titleLabel.BackColor = [System.Drawing.Color]::Transparent

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = 'Choose one pilot as the source. Everyone else can be overwritten in one pass.'
    $subtitleLabel.Location = New-Object System.Drawing.Point(28, 58)
    $subtitleLabel.Size = New-Object System.Drawing.Size(560, 22)
    $subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(162, 170, 184)
    $subtitleLabel.BackColor = [System.Drawing.Color]::Transparent

    $topCard = New-CardPanel -X 22 -Y 128 -Width 936 -Height 118
    $sourceCard = New-CardPanel -X 22 -Y 256 -Width 290 -Height 384
    $targetsCard = New-CardPanel -X 330 -Y 256 -Width 628 -Height 384
    $bottomCard = New-CardPanel -X 22 -Y 652 -Width 936 -Height 40
    $topCard.Anchor = 'Top, Left, Right'
    $sourceCard.Anchor = 'Top, Bottom, Left'
    $targetsCard.Anchor = 'Top, Bottom, Left, Right'
    $bottomCard.Anchor = 'Left, Right, Bottom'

    $folderLabel = New-UiLabel -Text 'Settings Folder' -X 16 -Y 14 -Width 120
    $folderLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $folderLabel.ForeColor = [System.Drawing.Color]::FromArgb(229, 231, 236)

    $folderBox = New-Object System.Windows.Forms.ComboBox
    $folderBox.Location = New-Object System.Drawing.Point(16, 44)
    $folderBox.Size = New-Object System.Drawing.Size(902, 28)
    $folderBox.DropDownStyle = 'DropDownList'
    $folderBox.Anchor = 'Top, Left, Right'
    Set-DarkStyle -Control $folderBox

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse'
    $browseButton.Location = New-Object System.Drawing.Point(736, 78)
    $browseButton.Size = New-Object System.Drawing.Size(88, 32)
    $browseButton.Anchor = 'Top, Right'
    Set-DarkStyle -Control $browseButton

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = 'Refresh'
    $refreshButton.Location = New-Object System.Drawing.Point(834, 78)
    $refreshButton.Size = New-Object System.Drawing.Size(84, 32)
    $refreshButton.Anchor = 'Top, Right'
    Set-DarkStyle -Control $refreshButton

    $sourceLabel = New-UiLabel -Text 'Source Pilot' -X 18 -Y 16 -Width 160
    $sourceLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)
    $sourceLabel.ForeColor = [System.Drawing.Color]::FromArgb(246, 239, 224)

    $sourceHint = New-UiLabel -Text 'Pick the layout you want to clone.' -X 18 -Y 42 -Width 210
    $sourceHint.ForeColor = [System.Drawing.Color]::FromArgb(146, 156, 172)

    $sourceList = New-Object System.Windows.Forms.ListBox
    $sourceList.Location = New-Object System.Drawing.Point(18, 76)
    $sourceList.Size = New-Object System.Drawing.Size(252, 272)
    $sourceList.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $sourceList.Anchor = 'Top, Bottom, Left, Right'
    Set-DarkStyle -Control $sourceList

    $sourceNote = New-UiLabel -Text 'Selecting a source removes it from the recipient list automatically.' -X 18 -Y 356 -Width 235 -Height 40
    $sourceNote.ForeColor = [System.Drawing.Color]::FromArgb(146, 156, 172)
    $sourceNote.Anchor = 'Left, Right, Bottom'

    $targetsLabel = New-UiLabel -Text 'Recipients' -X 18 -Y 16 -Width 180
    $targetsLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)
    $targetsLabel.ForeColor = [System.Drawing.Color]::FromArgb(246, 239, 224)

    $targetsHint = New-UiLabel -Text 'Choose who gets overwritten. The current source never appears here.' -X 18 -Y 42 -Width 420
    $targetsHint.ForeColor = [System.Drawing.Color]::FromArgb(146, 156, 172)

    $targetList = New-Object System.Windows.Forms.CheckedListBox
    $targetList.Location = New-Object System.Drawing.Point(18, 76)
    $targetList.Size = New-Object System.Drawing.Size(592, 182)
    $targetList.CheckOnClick = $true
    $targetList.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $targetList.Anchor = 'Top, Bottom, Left, Right'
    Set-DarkStyle -Control $targetList

    $actionsPanel = New-CardPanel -X 18 -Y 258 -Width 592 -Height 128
    $actionsPanel.Anchor = 'Left, Right, Bottom'
    $actionsPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 23, 31)

    $copyCharCheck = New-Object System.Windows.Forms.CheckBox
    $copyCharCheck.Text = 'Copy core_char'
    $copyCharCheck.Location = New-Object System.Drawing.Point(14, 14)
    $copyCharCheck.Size = New-Object System.Drawing.Size(150, 24)
    $copyCharCheck.Checked = $true
    $copyCharCheck.Anchor = 'Left, Bottom'
    Set-DarkStyle -Control $copyCharCheck

    $copyUserCheck = New-Object System.Windows.Forms.CheckBox
    $copyUserCheck.Text = 'Copy core_user'
    $copyUserCheck.Location = New-Object System.Drawing.Point(172, 14)
    $copyUserCheck.Size = New-Object System.Drawing.Size(150, 24)
    $copyUserCheck.Checked = $true
    $copyUserCheck.Anchor = 'Left, Bottom'
    Set-DarkStyle -Control $copyUserCheck

    $copyModeHint = New-UiLabel -Text 'Leave both on to move layout and shared keybind settings together.' -X 14 -Y 44 -Width 420
    $copyModeHint.ForeColor = [System.Drawing.Color]::FromArgb(146, 156, 172)
    $copyModeHint.Anchor = 'Left, Bottom'

    $buttonRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonRow.Location = New-Object System.Drawing.Point(236, 78)
    $buttonRow.Size = New-Object System.Drawing.Size(420, 40)
    $buttonRow.Anchor = 'Right, Bottom'
    $buttonRow.FlowDirection = 'LeftToRight'
    $buttonRow.WrapContents = $false
    $buttonRow.AutoSize = $true
    $buttonRow.AutoSizeMode = 'GrowAndShrink'
    $buttonRow.BackColor = [System.Drawing.Color]::Transparent
    $buttonRow.Padding = New-Object System.Windows.Forms.Padding(0)
    $buttonRow.Margin = New-Object System.Windows.Forms.Padding(0)

    $selectAllButton = New-Object System.Windows.Forms.Button
    $selectAllButton.Text = 'Select All'
    $selectAllButton.Size = New-Object System.Drawing.Size(110, 34)
    $selectAllButton.Margin = New-Object System.Windows.Forms.Padding(0, 3, 10, 3)
    Set-DarkStyle -Control $selectAllButton

    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text = 'Clear'
    $clearButton.Size = New-Object System.Drawing.Size(110, 34)
    $clearButton.Margin = New-Object System.Windows.Forms.Padding(0, 3, 10, 3)
    Set-DarkStyle -Control $clearButton

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copy To Selected'
    $copyButton.Size = New-Object System.Drawing.Size(196, 36)
    $copyButton.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    Set-DarkStyle -Control $copyButton

    $status = New-UiLabel -Text 'Ready.' -X 16 -Y 9 -Width 776
    $status.Height = 22
    $status.ForeColor = [System.Drawing.Color]::FromArgb(157, 166, 180)
    $status.Anchor = 'Left, Right, Top'

    $sourceBadge = New-Object System.Windows.Forms.Label
    $sourceBadge.Text = 'SOURCE'
    $sourceBadge.Location = New-Object System.Drawing.Point(188, 18)
    $sourceBadge.Size = New-Object System.Drawing.Size(82, 22)
    $sourceBadge.TextAlign = 'MiddleCenter'
    $sourceBadge.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    $sourceBadge.ForeColor = [System.Drawing.Color]::FromArgb(32, 24, 8)
    $sourceBadge.BackColor = [System.Drawing.Color]::FromArgb(201, 146, 66)
    $sourceBadge.Anchor = 'Top, Right'

    $recipientBadge = New-Object System.Windows.Forms.Label
    $recipientBadge.Text = 'TARGETS'
    $recipientBadge.Location = New-Object System.Drawing.Point(528, 18)
    $recipientBadge.Size = New-Object System.Drawing.Size(82, 22)
    $recipientBadge.TextAlign = 'MiddleCenter'
    $recipientBadge.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    $recipientBadge.ForeColor = [System.Drawing.Color]::FromArgb(12, 18, 24)
    $recipientBadge.BackColor = [System.Drawing.Color]::FromArgb(111, 165, 195)
    $recipientBadge.Anchor = 'Top, Right'

    $form.Controls.AddRange(@(
        $headerPanel,
        $topCard, $sourceCard, $targetsCard, $bottomCard
    ))

    $headerPanel.Controls.AddRange(@(
        $accentBar, $titleLabel, $subtitleLabel
    ))

    $topCard.Controls.AddRange(@(
        $folderLabel, $folderBox, $browseButton, $refreshButton
    ))

    $sourceCard.Controls.AddRange(@(
        $sourceLabel, $sourceHint, $sourceBadge, $sourceList, $sourceNote
    ))

    $targetsCard.Controls.AddRange(@(
        $recipientBadge,
        $targetsLabel, $targetsHint, $targetList, $actionsPanel
    ))

    $actionsPanel.Controls.AddRange(@(
        $copyCharCheck, $copyUserCheck, $copyModeHint, $buttonRow
    ))

    $buttonRow.Controls.AddRange(@(
        $selectAllButton, $clearButton, $copyButton
    ))

    $bottomCard.Controls.Add($status)

    $applyResponsiveLayout = {
        $headerPanel.Width = $form.ClientSize.Width
        $accentBar.Width = $form.ClientSize.Width

        $topCard.Width = $form.ClientSize.Width - 44
        $sourceCard.Top = $topCard.Bottom + 10
        $sourceCard.Height = $form.ClientSize.Height - 336
        $targetsCard.Width = $form.ClientSize.Width - 352
        $targetsCard.Top = $topCard.Bottom + 10
        $targetsCard.Height = $form.ClientSize.Height - 336
        $bottomCard.Top = $form.ClientSize.Height - 54
        $bottomCard.Width = $form.ClientSize.Width - 44

        $folderBox.Width = $topCard.ClientSize.Width - 32
        $browseButton.Left = $topCard.ClientSize.Width - 200
        $refreshButton.Left = $topCard.ClientSize.Width - 102

        $sourceList.Width = $sourceCard.ClientSize.Width - 36
        $sourceList.Height = $sourceCard.ClientSize.Height - 132
        $sourceNote.Top = $sourceCard.ClientSize.Height - 48
        $sourceNote.Width = $sourceCard.ClientSize.Width - 36
        $sourceBadge.Left = $sourceCard.ClientSize.Width - $sourceBadge.Width - 18

        $targetList.Width = $targetsCard.ClientSize.Width - 36
        $actionsPanel.Width = $targetsCard.ClientSize.Width - 36
        $actionsPanel.Top = $targetsCard.ClientSize.Height - $actionsPanel.Height - 18
        $targetList.Height = $actionsPanel.Top - $targetList.Top - 12
        $recipientBadge.Left = $targetsCard.ClientSize.Width - $recipientBadge.Width - 18

        $buttonRow.Left = $actionsPanel.ClientSize.Width - $buttonRow.PreferredSize.Width - 14

        $status.Width = $bottomCard.ClientSize.Width - 32
        $status.Top = 9
    }

    $form.Add_Resize($applyResponsiveLayout)

    $state = @{
        Profiles = @()
    }

    $refreshLists = {
        $sourceList.Items.Clear()
        $targetList.Items.Clear()
        $state.RecipientProfiles = @()

        foreach ($profile in $state.Profiles) {
            [void]$sourceList.Items.Add($profile.Name)
        }

        if ($sourceList.Items.Count -gt 0) {
            $sourceList.SelectedIndex = 0
            $status.Text = "Loaded $($state.Profiles.Count) characters."
        }
        else {
            $status.Text = 'No character files found in that folder.'
        }
    }

    $refreshRecipients = {
        $targetList.Items.Clear()
        $state.RecipientProfiles = @()

        $sourceIndex = $sourceList.SelectedIndex
        $sourceCharId = $null
        if ($sourceIndex -ge 0 -and $sourceIndex -lt $state.Profiles.Count) {
            $sourceCharId = $state.Profiles[$sourceIndex].CharId
        }

        foreach ($profile in $state.Profiles) {
            if ($profile.CharId -eq $sourceCharId) {
                continue
            }

            $state.RecipientProfiles += $profile
            [void]$targetList.Items.Add($profile.Name)
        }
    }

    $scanFolder = {
        try {
            $folder = [string]$folderBox.SelectedItem
            if ([string]::IsNullOrWhiteSpace($folder)) {
                throw 'Choose a settings folder first.'
            }

            $status.Text = 'Scanning files and resolving character names...'
            $form.Refresh()

            $state.Profiles = @(Get-EveProfiles -SettingsFolder $folder)
            & $refreshLists
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Scan Failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            $status.Text = 'Scan failed.'
        }
    }

    $sourceList.Add_SelectedIndexChanged({
        & $refreshRecipients
        if ($sourceList.SelectedIndex -ge 0) {
            $status.Text = "Source selected: $($sourceList.SelectedItem)"
        }
    })

    $selectAllButton.Add_Click({
        for ($i = 0; $i -lt $targetList.Items.Count; $i++) {
            $targetList.SetItemChecked($i, $true)
        }
    })

    $clearButton.Add_Click({
        for ($i = 0; $i -lt $targetList.Items.Count; $i++) {
            $targetList.SetItemChecked($i, $false)
        }
    })

    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = 'Choose the EVE settings folder that contains core_char_*.dat and core_user_*.dat'

    $browseButton.Add_Click({
        if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $picked = $folderDialog.SelectedPath
            if (-not ($folderBox.Items -contains $picked)) {
                [void]$folderBox.Items.Add($picked)
            }
            $folderBox.SelectedItem = $picked
        }
    })

    $refreshButton.Add_Click($scanFolder)

    $copyButton.Add_Click({
        try {
            if ($sourceList.SelectedIndex -lt 0) {
                throw 'Choose a source character.'
            }

            $targets = New-Object System.Collections.Generic.List[object]
            foreach ($index in $targetList.CheckedIndices) {
                $number = [int]$index
                if ($number -ge 0 -and $number -lt $state.RecipientProfiles.Count) {
                    $targets.Add($state.RecipientProfiles[$number])
                }
            }

            if ($targets.Count -eq 0) {
                throw 'Choose at least one target character to overwrite.'
            }

            if (-not $copyCharCheck.Checked -and -not $copyUserCheck.Checked) {
                throw 'Choose core_char, core_user, or both.'
            }

            $source = $state.Profiles[$sourceList.SelectedIndex]
            $targetNames = ($targets | ForEach-Object Name) -join ', '
            $message = "Copy from '$($source.Name)' to: $targetNames"
            $confirm = [System.Windows.Forms.MessageBox]::Show($message, 'Confirm Overwrite', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($confirm -ne [System.Windows.Forms.DialogResult]::OK) {
                return
            }

            Copy-EveSettings -SourceProfile $source -TargetProfiles $targets.ToArray() -CopyChar ([bool]$copyCharCheck.Checked) -CopyUser ([bool]$copyUserCheck.Checked)
            $status.Text = "Copied settings from $($source.Name) to $($targets.Count) target(s)."
            [System.Windows.Forms.MessageBox]::Show('Done. Backups were created before overwrite.', 'Copy Complete', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Copy Failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            $status.Text = 'Copy failed.'
        }
    })

    foreach ($folder in Find-EveSettingsFolders) {
        [void]$folderBox.Items.Add($folder)
    }

    & $applyResponsiveLayout

    if ($folderBox.Items.Count -gt 0) {
        $folderBox.SelectedIndex = 0
        & $scanFolder
    }

    [void]$form.ShowDialog()
}

Start-EveLayoutManager
