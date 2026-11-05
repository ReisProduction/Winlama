function Get-ComputerModelsMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1';
            Key = 'Manager.Computer.List'; Action = 'List';
            Color = 'White' }
        [pscustomobject]@{ Choice = '2';
            Key = 'Manager.Computer.Download'; Action = 'Download';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '3';
            Key = 'Manager.Computer.Import'; Action = 'Import';
            Color = 'Cyan' }
        [pscustomobject]@{ Choice = '4';
            Key = 'Manager.Computer.Export'; Action = 'Export';
            Color = 'Magenta' }
        [pscustomobject]@{ Choice = '5';
            Key = 'Manager.Computer.Delete'; Action = 'Delete';
            Color = 'Red' }
    )
}
function Get-InstallationModelsMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1';
            Key = 'Manager.Installation.List'; Action = 'Packages';
            Color = 'White' }
        [pscustomobject]@{ Choice = '2';
            Key = 'Manager.Installation.Verify'; Action = 'Verify';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '3';
            Key = 'Manager.Installation.Import'; Action = 'Export';
            Color = 'Magenta' }
        [pscustomobject]@{ Choice = '4';
            Key = 'Manager.Installation.Export'; Action = 'Import';
            Color = 'Cyan' }
        [pscustomobject]@{ Choice = '5';
            Key = 'Manager.Installation.Delete';
            Action = 'PackageDelete'; Color = 'Red' }
    )
}
function Get-ComfyUIModelsMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1';
            Key = 'Manager.ComfyUI.List'; Action = 'ComfyUIList';
            Color = 'White' }
        [pscustomobject]@{ Choice = '2';
            Key = 'Manager.ComfyUI.Download'; Action = 'ComfyUIDownload';
            Color = 'Green' }
        [pscustomobject]@{ Choice = '3';
            Key = 'Manager.ComfyUI.Delete'; Action = 'ComfyUIDelete';
            Color = 'Red' }
    )
}
function Get-ManagerMainMenuItems {
    return @(
        [pscustomobject]@{ Choice = '1'; Key = 'Manager.Menu.Computer';
            Color = 'Green'; Arguments = @() }
        [pscustomobject]@{ Choice = '2'; Key = 'Manager.Menu.Installation';
            Color = 'Cyan'; Arguments = @() }
        [pscustomobject]@{ Choice = '3'; Key = 'Manager.Menu.ComfyUIModels';
            Color = 'Magenta'; Arguments = @('3') }
        [pscustomobject]@{ Choice = '4'; Key = 'Manager.Menu.Repair';
            Color = 'Yellow'; Arguments = @() }
        [pscustomobject]@{ Choice = '5'; Key = 'Manager.Menu.Uninstall';
            Color = 'Red'; Arguments = @() }
        [pscustomobject]@{ Choice = '0'; Key = 'Manager.Menu.Exit';
            Color = 'Gray'; Arguments = @() }
    )
}
function Assert-ManagerMenuContract {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string[]]$ExpectedColors,
        [switch]$HasBack
    )
    $expected = @(1..$Items.Count | ForEach-Object { [string]$_ })
    if ($Items[-1].Choice -eq '0') {
        $expected = @(1..($Items.Count - 1) |
            ForEach-Object { [string]$_ }) + '0'
    }
    if (($Items.Choice -join ',') -ne ($expected -join ',')) {
        throw 'Model yoneticisi menu numaralari veya sirasi gecersiz.'
    }
    if (($Items.Color -join ',') -ne ($ExpectedColors -join ',')) {
        throw 'Model yoneticisi menu renk sirasi gecersiz.'
    }
    $texts = @()
    foreach ($item in $Items) {
        $arguments = if ($null -ne `
            $item.PSObject.Properties['Arguments']) {
            @($item.Arguments)
        }
        else {
            @()
        }
        $text = if (@($arguments).Count -gt 0) {
            Get-LocalizedText -Key $item.Key -Arguments $arguments
        }
        else {
            Get-LocalizedText -Key $item.Key
        }
        if ($text -notmatch ('^\s*\[{0}\]\s+\S' -f $item.Choice)) {
            throw "Model yoneticisi menu etiketi gecersiz: $($item.Key)"
        }
        $texts += $text.Trim()
    }
    if (@($texts | Sort-Object -Unique).Count -ne $Items.Count) {
        throw 'Model yoneticisi menusunde yinelenen etiket var.'
    }
    if ($HasBack) {
        $back = Get-LocalizedText -Key 'Manager.Menu.Back'
        if ($back -notmatch '^\s*\[0\]\s+\S') {
            throw 'Model yoneticisi geri etiketi gecersiz.'
        }
    }
}
function Show-ManagerActionMenuLayout {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Notice
    )
    Write-ManagerBanner
    Show-ManagerPaths
    Write-ManagerSection -Title $Title -NoLeadingRule
    if (-not [string]::IsNullOrWhiteSpace($Notice)) {
        Write-ManagerLine -Text (Get-LocalizedText -Key $Notice) `
            -Color Cyan
        Write-ManagerRule
    }
    foreach ($item in $Items) {
        Write-ManagerLine -Text (Get-LocalizedText `
            -Key $item.Key) -Color $item.Color
    }
    Write-ManagerLine -Text (Get-LocalizedText `
        -Key 'Manager.Menu.Back') -Color Gray
    Write-ManagerRule
}
function Show-ManagerMainMenu {
    Write-ManagerBanner
    Show-ManagerPaths
    foreach ($item in @(Get-ManagerMainMenuItems)) {
        $text = if (@($item.Arguments).Count -gt 0) {
            Get-LocalizedText -Key $item.Key -Arguments $item.Arguments
        }
        else {
            Get-LocalizedText -Key $item.Key
        }
        Write-ManagerLine -Text $text -Color $item.Color
    }
    Write-ManagerRule
}