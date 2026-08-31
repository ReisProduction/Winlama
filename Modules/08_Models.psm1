Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-ModelInstallSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $property = $Config.Models.PSObject.Properties['InstallSource']
    if ($null -eq $property -or
        [string]$property.Value -cnotin @('Automatic', 'Local', 'Online')) {
        throw [IO.InvalidDataException]::new(
            (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @('Models.InstallSource'))
        )
    }
    return [string]$property.Value
}
function Get-ModelInstallSourcePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Automatic', 'Local', 'Online')]
        [string]$InstallSource
    )
    if ($InstallSource -cnotin @('Automatic', 'Local', 'Online')) {
        throw [IO.InvalidDataException]::new(
            (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @('Models.InstallSource'))
        )
    }
    return [pscustomobject]@{
        ImportLocalPackages = $InstallSource -cne 'Online'
        AllowOfficialPull = $InstallSource -cne 'Local'
        LocalFailureIsFatal = $InstallSource -ceq 'Local'
    }
}
function New-LocalModelSourceMissingException {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModelName)
    $message = Get-LocalizedText `
        -Key 'Models.Error.LocalSourceModelMissing' `
        -Arguments @($ModelName)
    return New-NonRetryableException -Message $message
}
function Get-ModelLockPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$ModelName
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($ModelName)
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).Substring(0, 16)
    return Join-Path $Context.TempPath "model-$hash.lock"
}
function Enter-ModelDownloadLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$ModelName
    )
    $path = Get-ModelLockPath -Context $Context -ModelName $ModelName
    try {
        return [IO.File]::Open(
            $path,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        throw (Get-LocalizedText -Key 'Models.Error.LockUnavailable' `
            -Arguments @($ModelName))
    }
}
function Test-OllamaModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$ModelName
    )
    try {
        $models = @(Get-OllamaModelInventory -Context $Context)
        $model = $models | Where-Object {
            $_.name -eq $ModelName -or $_.model -eq $ModelName
        } | Select-Object -First 1
        if ($null -eq $model -or
            [string]::IsNullOrWhiteSpace([string]$model.digest)) {
            return $false
        }
        $details = Invoke-OllamaApi -Context $Context -Method POST `
            -Path '/api/show' -Body @{ model = $ModelName } `
            -TimeoutSeconds 60
        return $null -ne $details
    }
    catch {
        Write-Verbose ('Ollama modeli denetlenemedi: {0} | {1}' -f `
            $ModelName, $_.Exception.Message)
        return $false
    }
}
function New-ModelDiskReservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [pscustomobject]$Model
    )
    $storage = Get-ModelStorageRequirement -Model $Model `
        -SafetyBufferPercent `
            $Context.Config.Models.SafetyBufferPercent
    $reserveGB = $storage.ReservationGB
    $requiredGB = $storage.RequiredGB
    $drive = [IO.DriveInfo]::new(
        [IO.Path]::GetPathRoot($Context.ModelsPath)
    )
    $freeGB = $drive.AvailableFreeSpace / 1GB
    if ($freeGB -lt $requiredGB) {
        throw (Get-LocalizedText `
            -Key 'Models.Error.DiskInsufficient' `
            -Arguments @(
                $Model.Name,
                [math]::Ceiling($requiredGB),
                [math]::Round($freeGB, 2)
            ))
    }
    if (-not $Context.Config.Models.ReservationEnabled) {
        return $null
    }
    $safeName = $Model.Name -replace '[^a-zA-Z0-9.-]', '_'
    $path = Join-Path $Context.TempPath "$safeName.reserve"
    $stream = [IO.File]::Open(
        $path,
        [IO.FileMode]::Create,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $length = [int64]($reserveGB * 1GB)
        $stream.SetLength($length)
        $stream.Flush($true)
        return [pscustomobject]@{
            Path = $path
            Stream = $stream
            ReservedGB = [math]::Round($reserveGB, 2)
        }
    }
    catch {
        $stream.Dispose()
        Remove-Item -LiteralPath $path -Force `
            -ErrorAction SilentlyContinue
        throw
    }
}
function Remove-ModelDiskReservation {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [pscustomobject]$Reservation
    )
    if ($null -eq $Reservation) {
        return
    }
    $Reservation.Stream.Dispose()
    Remove-Item -LiteralPath $Reservation.Path -Force
}
function Install-OllamaModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [pscustomobject]$Model
    )
    if (Test-OllamaModel -Context $Context -ModelName $Model.Name) {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module MODELS `
            -Message 'Models.ExistingVerified' `
            -MessageArguments @($Model.Name)
        return
    }
    $installSource = Get-ModelInstallSource -Config $Context.Config
    $sourcePolicy = Get-ModelInstallSourcePolicy `
        -InstallSource $installSource
    if (-not $sourcePolicy.AllowOfficialPull) {
        throw (New-LocalModelSourceMissingException `
            -ModelName $Model.Name)
    }
    $lock = Enter-ModelDownloadLock -Context $Context `
        -ModelName $Model.Name
    $reservation = $null
    try {
        if (Test-OllamaModel -Context $Context -ModelName $Model.Name) {
            return
        }
        $reservation = New-ModelDiskReservation -Context $Context `
            -Model $Model
        $ollama = Get-OllamaExecutable -Context $Context
        $delays = @($Context.Config.Network.RetryBackoffSeconds)
        $lastException = $null
        for ($attempt = 0; $attempt -le $delays.Count; $attempt++) {
            try {
                Write-DeploymentLog -Context $Context -Level INFO `
                    -Module MODELS `
                    -Message 'Models.Downloading' `
                    -MessageArguments @($Model.Name)
                $null = Invoke-ExternalProcess -FilePath $ollama `
                    -ArgumentList @('pull', $Model.Name) `
                    -TimeoutSeconds `
                        $Context.Config.Network.DownloadTimeoutSeconds
                if (-not (Test-OllamaModel -Context $Context `
                    -ModelName $Model.Name)) {
                    throw (Get-LocalizedText `
                        -Key 'Models.Error.IntegrityFailed' `
                        -Arguments @($Model.Name))
                }
                return
            }
            catch {
                $lastException = $_.Exception
                if ($attempt -lt $delays.Count) {
                    Write-DeploymentLog -Context $Context -Level WARN `
                        -Module MODELS `
                        -Message 'Models.DownloadRetry' `
                        -MessageArguments @($Model.Name) `
                        -Exception $lastException -Recovery RETRY_BACKOFF
                    Start-Sleep -Seconds $delays[$attempt]
                }
            }
        }
        throw $lastException
    }
    finally {
        Remove-ModelDiskReservation -Reservation $reservation
        $lock.Dispose()
    }
}
function Invoke-ModelLocalPackageFailurePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)]
        [ValidateSet('Automatic', 'Local')]
        [string]$InstallSource,
        [Parameter(Mandatory)][string]$ModelName,
        [Parameter(Mandatory)][Exception]$Exception
    )
    if ($InstallSource -eq 'Local') {
        throw (New-NonRetryableException -Message $Exception.Message)
    }
    Write-DeploymentLog -Context $Context -Level WARN `
        -Module MODELS -Message 'Models.LocalImport.Skipped' `
        -MessageArguments @($ModelName, $Exception.Message) `
        -Exception $Exception -Recovery FALLBACK_DOWNLOAD
}
function New-ModelManagerImportArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManagerPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$PackageSelection
    )
    return @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ManagerPath,
        '-ConfigPath', $ConfigPath,
        '-Action', 'Import',
        '-PackageSelection', $PackageSelection,
        '-NoPause'
    )
}
function Import-SelectedLocalModelPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [pscustomobject]$Plan
    )
    $installSource = Get-ModelInstallSource -Config $Context.Config
    $sourcePolicy = Get-ModelInstallSourcePolicy `
        -InstallSource $installSource
    if (-not $sourcePolicy.ImportLocalPackages) {
        return
    }
    $configured = @(
        $Context.Config.Models.LocalPackageImport.SelectedPackages
    )
    if ($configured.Count -eq 0) {
        return
    }
    $plannedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($model in @($Plan.Models)) {
        $null = $plannedNames.Add([string]$model.Name)
    }
    $packagePaths = [Collections.Generic.List[string]]::new()
    $packageModels = [Collections.Generic.List[string]]::new()
    $selectedPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($configuredPath in $configured) {
        try {
            $packagePath = [Environment]::ExpandEnvironmentVariables(
                [string]$configuredPath
            )
            if (-not [IO.Path]::IsPathRooted($packagePath)) {
                $packagePath = Join-Path $Context.AppPath $packagePath
            }
            $packagePath = [IO.Path]::GetFullPath($packagePath)
            if ($packagePath.Contains(';')) {
                throw (Get-LocalizedText `
                    -Key 'Models.Error.LocalPackagePathInvalid' `
                    -Arguments @($packagePath))
            }
            $metadataPath = Join-Path $packagePath 'package.json'
            if (-not (Test-Path -LiteralPath $metadataPath `
                -PathType Leaf)) {
                throw (Get-LocalizedText `
                    -Key 'Models.Error.LocalPackageMissing' `
                    -Arguments @($packagePath))
            }
            $metadata = Read-JsonFile -Path $metadataPath
            $modelName = [string]$metadata.OllamaReference
            if (-not $plannedNames.Contains($modelName)) {
                continue
            }
            if (Test-OllamaModel -Context $Context `
                -ModelName $modelName) {
                continue
            }
            if ($selectedPaths.Add($packagePath)) {
                $packagePaths.Add($packagePath)
                $packageModels.Add($modelName)
            }
        }
        catch {
            Invoke-ModelLocalPackageFailurePolicy -Context $Context `
                -InstallSource $installSource `
                -ModelName ([string]$configuredPath) `
                -Exception $_.Exception
        }
    }
    if ($packagePaths.Count -eq 0) {
        return
    }
    try {
        $managerPath = Join-Path $Context.AppPath 'ModelManager.ps1'
        if (-not (Test-Path -LiteralPath $managerPath -PathType Leaf)) {
            throw (Get-LocalizedText `
                -Key 'Models.Error.ManagerMissing' `
                -Arguments @($managerPath))
        }
        $installedConfigPath = Join-Path $Context.AppPath `
            'Data\Configs\config.json'
        $runtime = Get-PowerShellRuntimePath -Context $Context
    }
    catch {
        Invoke-ModelLocalPackageFailurePolicy -Context $Context `
            -InstallSource $installSource -ModelName 'ModelManager' `
            -Exception $_.Exception
        return
    }
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module MODELS -Message 'Models.LocalImport.Started' `
        -MessageArguments @($packagePaths.Count)
    $selection = $packagePaths.ToArray() -join ';'
    $batchTimeoutSeconds = [int][Math]::Min(
        604800,
        [long]$Context.Config.Network.DownloadTimeoutSeconds *
            $packagePaths.Count
    )
    $arguments = New-ModelManagerImportArgumentList `
        -ManagerPath $managerPath -ConfigPath $installedConfigPath `
        -PackageSelection $selection
    try {
        $null = Invoke-ExternalProcess -FilePath $runtime `
            -ArgumentList $arguments `
            -TimeoutSeconds $batchTimeoutSeconds `
            -Activity (Get-LocalizedText `
                -Key 'Models.Process.LocalImport')
    }
    catch {
        $failure = $_.Exception
        foreach ($modelName in $packageModels) {
            Invoke-ModelLocalPackageFailurePolicy -Context $Context `
                -InstallSource $installSource -ModelName $modelName `
                -Exception $failure
        }
        return
    }
    $imported = 0
    foreach ($modelName in $packageModels) {
        try {
            if (-not (Test-OllamaModel -Context $Context `
                -ModelName $modelName)) {
                throw (Get-LocalizedText `
                    -Key 'Models.Error.LocalImportFailed' `
                    -Arguments @($modelName))
            }
            $imported++
        }
        catch {
            Invoke-ModelLocalPackageFailurePolicy -Context $Context `
                -InstallSource $installSource -ModelName $modelName `
                -Exception $_.Exception
        }
    }
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module MODELS -Message 'Models.LocalImport.Completed' `
        -MessageArguments @($imported)
}
function Install-SelectedModels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Ollama.Enabled -or
        $Context.Config.Models.SelectionMode -eq 'Skip') {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module MODELS -Message 'Models.InstallationSkipped'
        return
    }
    $null = Wait-OllamaReady -Context $Context `
        -TimeoutSeconds `
            $Context.Config.Runtime.OllamaStartupTimeoutSeconds
    $plan = Read-JsonFile -Path $Context.ModelPlanPath
    $models = @($plan.Models)
    if ($models.Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Models.Error.SelectionPlanEmpty')
    }
    Import-SelectedLocalModelPackages -Context $Context -Plan $plan
    foreach ($model in $models) {
        Install-OllamaModel -Context $Context -Model $model
        if (-not (Test-OllamaModel -Context $Context `
            -ModelName $model.Name)) {
            throw (Get-LocalizedText `
                -Key 'Models.Error.IntegrityFailed' `
                -Arguments @($model.Name))
        }
    }
}
function Test-SelectedModels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Ollama.Enabled -or
        $Context.Config.Models.SelectionMode -eq 'Skip') {
        return $true
    }
    if (-not (Test-Path -LiteralPath $Context.ModelPlanPath)) {
        return $false
    }
    try {
        $plan = Read-JsonFile -Path $Context.ModelPlanPath
        foreach ($model in @($plan.Models)) {
            if (-not (Test-OllamaModel -Context $Context `
                -ModelName $model.Name)) {
                return $false
            }
        }
        return @($plan.Models).Count -gt 0
    }
    catch {
        Write-Verbose ('Secili model plani denetlenemedi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Assert-ModelInstallSourceContracts {
    [CmdletBinding()]
    param()
    $automatic = Get-ModelInstallSourcePolicy `
        -InstallSource Automatic
    $local = Get-ModelInstallSourcePolicy -InstallSource Local
    $online = Get-ModelInstallSourcePolicy -InstallSource Online
    $config = [pscustomobject]@{
        Models = [pscustomobject]@{ InstallSource = 'Local' }
    }
    $invalidConfig = [pscustomobject]@{
        Models = [pscustomobject]@{ InstallSource = 'local' }
    }
    $before = $config | ConvertTo-Json -Compress -Depth 5
    $resolved = Get-ModelInstallSource -Config $config
    $invalidRejected = $false
    try {
        $null = Get-ModelInstallSource -Config $invalidConfig
    }
    catch [IO.InvalidDataException] {
        $invalidRejected = $true
    }
    $exception = New-LocalModelSourceMissingException `
        -ModelName 'fixture:1b'
    $managerArguments = @(New-ModelManagerImportArgumentList `
        -ManagerPath 'C:\Program Files\Winlama\ModelManager.ps1' `
        -ConfigPath 'C:\ProgramData\Winlama\config.json' `
        -PackageSelection 'D:\Model One;E:\Model Two')
    $localFailureRejected = $false
    try {
        Invoke-ModelLocalPackageFailurePolicy `
            -Context ([pscustomobject]@{}) -InstallSource Local `
            -ModelName 'fixture:1b' `
            -Exception ([InvalidOperationException]::new('fixture failure'))
    }
    catch {
        $localFailureRejected =
            $_.Exception.Message -ceq 'fixture failure' -and
            $_.Exception.Data['Winlama.Retryable'] -eq $false
    }
    $importSource = (Get-Command Import-SelectedLocalModelPackages `
        -ErrorAction Stop).Definition
    $importInvocationCount = ([regex]::Matches(
        $importSource,
        'Invoke-ExternalProcess'
    )).Count
    if (-not $automatic.ImportLocalPackages -or
        -not $automatic.AllowOfficialPull -or
        $automatic.LocalFailureIsFatal -or
        -not $local.ImportLocalPackages -or $local.AllowOfficialPull -or
        -not $local.LocalFailureIsFatal -or
        $online.ImportLocalPackages -or
        -not $online.AllowOfficialPull -or
        $online.LocalFailureIsFatal -or $resolved -cne 'Local' -or
        -not $invalidRejected -or
        -not $localFailureRejected -or
        $exception.Data['Winlama.Retryable'] -ne $false -or
        $managerArguments.Count -ne 14 -or
        $managerArguments[2] -cne '-NonInteractive' -or
        $managerArguments[6] -cne
            'C:\Program Files\Winlama\ModelManager.ps1' -or
        $managerArguments[8] -cne
            'C:\ProgramData\Winlama\config.json' -or
        $managerArguments[10] -cne 'Import' -or
        $managerArguments[12] -cne 'D:\Model One;E:\Model Two' -or
        $managerArguments[13] -cne '-NoPause' -or
        $importSource -notmatch
            '\$packagePaths\.ToArray\(\)\s+-join\s+'';''' -or
        $importSource -notmatch '\$batchTimeoutSeconds' -or
        $importSource -notmatch 'New-ModelManagerImportArgumentList' -or
        $importInvocationCount -ne 1 -or
        ($config | ConvertTo-Json -Compress -Depth 5) -cne $before) {
        throw 'Model kurulum kaynak politikasi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Models.InstallSource'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Models.BatchedLocalImport'
    return $true
}
Export-ModuleMember -Function @(
    'Test-OllamaModel', 'New-ModelDiskReservation',
    'Remove-ModelDiskReservation', 'Install-OllamaModel',
    'Install-SelectedModels', 'Test-SelectedModels',
    'Assert-ModelInstallSourceContracts'
)