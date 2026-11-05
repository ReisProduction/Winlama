function Get-RepairHash {
    param([Parameter(Mandatory)][string]$Path)
    Write-Verbose (Get-RepairText -Key 'Repair.Verbose.Hashing' `
        -Arguments @($Path))
    return (Get-FileHash -LiteralPath $Path `
        -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Test-RepairFileHash {
    param([string]$Path, [string]$ExpectedHash)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return (Get-RepairHash -Path $Path) -eq
        $ExpectedHash.ToLowerInvariant()
}
function Set-RepairAtomicFile {
    param(
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$Destination,
        [scriptblock]$MoveHandler,
        [scriptblock]$RemoveHandler,
        [scriptblock]$PathTester
    )
    if ($null -eq $MoveHandler) {
        $MoveHandler = {
            param([string]$Source, [string]$Target)
            [IO.File]::Move($Source, $Target)
        }
    }
    if ($null -eq $RemoveHandler) {
        $RemoveHandler = {
            param([string]$Path)
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    }
    if ($null -eq $PathTester) {
        $PathTester = {
            param([string]$Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        }
    }
    if (-not [bool](& $PathTester $Destination)) {
        & $MoveHandler $TemporaryPath $Destination
        return
    }
    $backup = '{0}.winlama-{1}.backup' -f `
        $Destination, [guid]::NewGuid().ToString('N')
    & $MoveHandler $Destination $backup
    try {
        & $MoveHandler $TemporaryPath $Destination
    }
    catch {
        $commitError = $_
        try {
            if ([bool](& $PathTester $Destination)) {
                throw 'Basarisiz atomik tasima hedefte dosya birakti.'
            }
            if (-not [bool](& $PathTester $backup)) {
                throw 'Atomik yedek dosyasi bulunamadi.'
            }
            & $MoveHandler $backup $Destination
        }
        catch {
            $message = 'Atomik dosya geri yuklemesi basarisiz. ' +
                "Korunan yedek: $backup | " +
                "Yazma hatasi: $($commitError.Exception.Message) | " +
                "Geri yukleme hatasi: $($_.Exception.Message)"
            $restoreError = $_
            $null = Invoke-RepairNoThrowNotification `
                -Context 'ATOMIC_RESTORE_FAILED log bildirimi' `
                -Action {
                    Write-RepairLog -Event 'ATOMIC_RESTORE_FAILED' `
                        -Message $message -Level ERROR `
                        -Data @{ Destination = $Destination;
                            Backup = $backup;
                            CommitError = `
                                $commitError.Exception.Message;
                            RestoreError = `
                                $restoreError.Exception.Message }
                }
            throw [IO.IOException]::new(
                $message,
                $restoreError.Exception
            )
        }
        throw $commitError
    }
    try {
        & $RemoveHandler $backup
    }
    catch {
        $cleanupError = $_
        $null = Invoke-RepairNoThrowNotification `
            -Context 'ATOMIC_BACKUP_PRESERVED log bildirimi' `
            -Action {
                Write-RepairLog -Event 'ATOMIC_BACKUP_PRESERVED' `
                    -Message (
                        'Atomik yazma tamamlandi; ' +
                        "yedek silinemedi: $backup"
                    ) -Level WARN `
                    -Data @{ Destination = $Destination;
                        Backup = $backup;
                        Error = $cleanupError.Exception.Message }
            }
    }
}
function Copy-RepairFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedHash
    )
    if (-not $PSCmdlet.ShouldProcess(
        $Destination,
        (Get-RepairText -Key 'Repair.Action.Copy')
    )) {
        return
    }
    [IO.Directory]::CreateDirectory(
        (Split-Path -Parent $Destination)
    ) | Out-Null
    $temporaryPath = '{0}.winlama-{1}.tmp' -f `
        $Destination, [guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source `
            -Destination $temporaryPath -Force
        if ((Get-RepairHash -Path $temporaryPath) -ne
            $ExpectedHash.ToLowerInvariant()) {
            throw (Get-RepairText `
                -Key 'Repair.Error.CopyHashMismatch' `
                -Arguments @($Source, $Destination))
        }
        Set-RepairAtomicFile -TemporaryPath $temporaryPath `
            -Destination $Destination
        (Get-Item -LiteralPath $Destination).LastWriteTimeUtc = `
            (Get-Item -LiteralPath $Source).LastWriteTimeUtc
        $script:CopiedCount++
        Write-RepairLog -Event 'FILE_COPIED' `
            -Message (Get-RepairText `
                -Key 'Repair.Log.FileCopied') `
            -Data @{ Source = $Source; Destination = $Destination;
                Sha256 = $ExpectedHash.ToLowerInvariant() }
        Write-RepairStatus -Level SUCCESS -Message (Get-RepairText `
            -Key 'Repair.File.Copied' -Arguments @($Destination))
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force `
            -ErrorAction SilentlyContinue
    }
}
function Remove-RepairFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess(
        $Path,
        (Get-RepairText -Key 'Repair.Action.Delete')
    )) {
        return
    }
    Remove-Item -LiteralPath $Path -Force
    $script:DeletedCount++
    Write-RepairLog -Event 'FILE_DELETED' `
        -Message (Get-RepairText `
            -Key 'Repair.Log.ExtraRemoved') `
        -Level WARN -Data @{ Path = $Path }
    Write-RepairStatus -Level WARN -Message (Get-RepairText `
        -Key 'Repair.File.Deleted' -Arguments @($Path))
}
function Sync-RepairFileSet {
    param(
        [Parameter(Mandatory)][string]$SourceBase,
        [Parameter(Mandatory)][string]$TargetBase,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]
        [IO.FileInfo[]]$SourceFiles,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]
        [IO.FileInfo[]]$TargetFiles,
        [switch]$Mirror
    )
    $sourceMap = @{}
    foreach ($file in $SourceFiles) {
        Assert-RepairSafeTreePath -Root $SourceBase `
            -Path $file.FullName
        $relativePath = Get-RepairRelativePath `
            -Root $SourceBase -Path $file.FullName
        $sourceMap[$relativePath] = $file
        $destination = Join-Path $TargetBase $relativePath
        Assert-RepairSafeTreePath -Root $TargetBase `
            -Path $destination
        $expectedHash = Get-RepairHash -Path $file.FullName
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $targetFile = Get-Item -LiteralPath $destination
            if ($targetFile.Length -eq $file.Length -and
                (Get-RepairHash -Path $destination) -eq $expectedHash) {
                $script:MatchedCount++
                Write-Verbose (Get-RepairText `
                    -Key 'Repair.Verbose.Match' `
                    -Arguments @($destination))
                continue
            }
        }
        $script:DifferentCount++
        Write-RepairStatus -Level STEP -Message (Get-RepairText `
            -Key 'Repair.File.Different' -Arguments @($destination))
        if ($Apply) {
            Copy-RepairFile -Source $file.FullName `
                -Destination $destination `
                -ExpectedHash $expectedHash
            if (-not $WhatIfPreference) {
                $script:ResolvedCount++
            }
        }
        else {
            Add-RepairUnresolved -Message (Get-RepairText `
                -Key 'Repair.Unresolved.File' `
                -Arguments @($destination))
        }
    }
    if (-not $Mirror) {
        return
    }
    foreach ($file in $TargetFiles) {
        Assert-RepairSafeTreePath -Root $TargetBase `
            -Path $file.FullName
        $relativePath = Get-RepairRelativePath `
            -Root $TargetBase -Path $file.FullName
        if ($sourceMap.ContainsKey($relativePath)) {
            continue
        }
        $script:DifferentCount++
        Write-RepairStatus -Level WARN -Message (Get-RepairText `
            -Key 'Repair.File.Extra' -Arguments @($file.FullName))
        if ($Apply) {
            Remove-RepairFile -Path $file.FullName
            if (-not $WhatIfPreference) {
                $script:ResolvedCount++
            }
        }
        else {
            Add-RepairUnresolved -Message (Get-RepairText `
                -Key 'Repair.Unresolved.File' `
                -Arguments @($file.FullName))
        }
    }
}
function Invoke-RepairDiskScope {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][pscustomobject]$Config,
        [switch]$Execute
    )
    Assert-RepairRootsDisjoint -Source $Source -Target $Target
    $installedRoot = Resolve-RepairPath -Path ([string]$Config.Paths.Root) `
        -BasePath $Source
    Assert-RepairRootsDisjoint -Source $installedRoot -Target $Target
    Sync-RepairApplicationPayload -Source $Source -Target $Target `
        -PackageTarget -Execute:$Execute
    Sync-RepairCanonicalPackageConfig -Source $Source -Target $Target `
        -Execute:$Execute
    if (Test-RepairConfigurationComponentEnabled `
        -Config $Config -Component 'ComfyUI') {
        Sync-RepairTree -Source (Join-Path $Source 'Runtime\ComfyUI') `
            -Target (Join-Path $Target 'Runtime\ComfyUI') `
            -Optional -RuntimePayload -RuntimeConfig $Config
        Repair-ComfyUIAssets -PackageRoot $Target -Config $Config `
            -Direction InstalledToPackage
    }
    Repair-OllamaPackages -PackageRoot $Target -Config $Config `
        -Direction InstalledToPackage
}
function Get-RepairTargets {
    param(
        [string]$SelectedMode,
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [pscustomobject]$Config,
        [switch]$NonInteractive
    )
    $installedRoot = Resolve-RepairPath -Path ([string]$Config.Paths.Root) `
        -BasePath $SourceRoot
    if ($SelectedMode -eq 'PublishPackage') {
        if ($NonInteractive -and -not $DestinationRoot) {
            throw (Get-RepairText -Key 'Repair.Error.DestinationRequired')
        }
        $disk = Resolve-RepairDestinationRoot -RequestedRoot $DestinationRoot
        Assert-RepairRootsDisjoint -Source $SourceRoot -Target $disk
        Assert-RepairRootsDisjoint -Source $installedRoot -Target $disk
        return @{ Primary = $disk; Disk = $null }
    }
    Assert-RepairDestination -Path $installedRoot
    Assert-RepairRootsDisjoint -Source $SourceRoot -Target $installedRoot
    $disk = $null
    if ($SelectedMode -eq 'RepairAll' -and $DestinationRoot) {
        $disk = Resolve-RepairDestinationRoot -RequestedRoot $DestinationRoot
        Assert-RepairRootsDisjoint -Source $SourceRoot -Target $disk
        Assert-RepairRootsDisjoint -Source $installedRoot -Target $disk
    }
    return @{ Primary = $installedRoot; Disk = $disk }
}