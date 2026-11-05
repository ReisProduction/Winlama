Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-NvidiaSmiPath {
    [CmdletBinding()]
    param()
    return Resolve-ExecutablePath -Name 'nvidia-smi.exe' `
        -AdditionalPaths @(
            (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
            (Join-Path $env:ProgramFiles `
                'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
        )
}
function Get-NvidiaGpuData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$NvidiaSmiPath
    )
    $query = 'index,name,memory.total,memory.used,' +
        'compute_cap,driver_version'
    try {
        $result = Invoke-ExternalProcess -FilePath $NvidiaSmiPath `
            -ArgumentList @(
                "--query-gpu=$query",
                '--format=csv,noheader,nounits'
            ) -TimeoutSeconds 30
        $rows = @($result.StandardOutput -split "`r?`n")
        $gpus = foreach ($row in $rows) {
            if ([string]::IsNullOrWhiteSpace($row)) {
                continue
            }
            $columns = @($row -split ',\s*')
            if ($columns.Count -lt 6) {
                throw (Get-LocalizedText `
                    -Key 'Hardware.Error.NvidiaOutputInvalid' `
                    -Arguments @($row))
            }
            [pscustomobject][ordered]@{
                Index = [int]$columns[0]
                Name = $columns[1]
                DedicatedVramGB = [math]::Round(
                    ([double]$columns[2] / 1024),
                    2
                )
                UsedVramGB = [math]::Round(
                    ([double]$columns[3] / 1024),
                    2
                )
                CudaCapability = $columns[4]
                DriverVersion = $columns[5]
            }
        }
        return @($gpus)
    }
    catch {
        Write-Verbose ('CUDA compute capability sorgusu kullanilamadi: {0}' `
            -f $_.Exception.Message)
        $fallbackQuery = 'index,name,memory.total,memory.used,driver_version'
        $result = Invoke-ExternalProcess -FilePath $NvidiaSmiPath `
            -ArgumentList @(
                "--query-gpu=$fallbackQuery",
                '--format=csv,noheader,nounits'
            ) -TimeoutSeconds 30
        $rows = @($result.StandardOutput -split "`r?`n")
        $gpus = foreach ($row in $rows) {
            if ([string]::IsNullOrWhiteSpace($row)) {
                continue
            }
            $columns = @($row -split ',\s*')
            [pscustomobject][ordered]@{
                Index = [int]$columns[0]
                Name = $columns[1]
                DedicatedVramGB = [math]::Round(
                    ([double]$columns[2] / 1024),
                    2
                )
                UsedVramGB = [math]::Round(
                    ([double]$columns[3] / 1024),
                    2
                )
                CudaCapability = 'UNKNOWN'
                DriverVersion = $columns[4]
            }
        }
        return @($gpus)
    }
}
function Test-NvidiaDriverPolicyViolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ComfyUIEnabled,
        [Parameter(Mandatory)][bool]$NvidiaDetected,
        [Parameter(Mandatory)][bool]$RequireNvidiaWhenDetected,
        [Parameter(Mandatory)][bool]$NvidiaSmiReady,
        [Parameter(Mandatory)][bool]$ContinueOnOptionalError
    )
    return $ComfyUIEnabled -and $NvidiaDetected -and
        $RequireNvidiaWhenDetected -and -not $NvidiaSmiReady -and
        -not $ContinueOnOptionalError
}
function Assert-NvidiaDriverIfRequired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [bool]$NvidiaDetected,
        [Parameter(Mandatory)]
        [bool]$NvidiaSmiReady
    )
    $continueProperty = $Context.Config.Installation.PSObject.Properties[
        'ContinueOnOptionalError'
    ]
    $continueOptionalErrors = $null -ne $continueProperty -and
        [bool]$continueProperty.Value
    if (-not (Test-NvidiaDriverPolicyViolation `
        -ComfyUIEnabled ([bool]$Context.Config.ComfyUI.Enabled) `
        -NvidiaDetected $NvidiaDetected `
        -RequireNvidiaWhenDetected (
            [bool]$Context.Config.Hardware.RequireNvidiaWhenDetected
        ) -NvidiaSmiReady $NvidiaSmiReady `
        -ContinueOnOptionalError $continueOptionalErrors)) {
        return
    }
    throw (New-NonRetryableException -Message (Get-LocalizedText `
        -Key 'Hardware.Error.NvidiaDriverRequired'))
}
function Get-HardwareResourcePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )
    $ollamaModelsRequired = [bool]$Config.Ollama.Enabled -and
        [string]$Config.Models.SelectionMode -ne 'Skip'
    $comfyUIRequired = [bool]$Config.ComfyUI.Enabled
    $minimumResourcesRequired = $ollamaModelsRequired -or
        $comfyUIRequired
    return [pscustomobject][ordered]@{
        MinimumResourcesRequired = $minimumResourcesRequired
        OllamaModelsRequired = $ollamaModelsRequired
        ComfyUIRequired = $comfyUIRequired
        MinimumRamGB = if ($minimumResourcesRequired) {
            [double]$Config.Hardware.MinimumRamGB
        }
        else {
            0.0
        }
        MinimumFreeDiskGB = if ($minimumResourcesRequired) {
            [double]$Config.Hardware.MinimumFreeDiskGB
        }
        else {
            0.0
        }
    }
}
function Test-HardwareResourcePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [pscustomobject]$Hardware
    )
    $policy = Get-HardwareResourcePolicy -Config $Config
    $ramCapacityGB = Get-HardwareRamCapacity -Hardware $Hardware
    return $ramCapacityGB -ge $policy.MinimumRamGB -and
        [double]$Hardware.FreeDiskGB -ge $policy.MinimumFreeDiskGB
}
function Get-HardwareRamCapacity {
    param([pscustomobject]$Hardware)
    $installed = $Hardware.PSObject.Properties['InstalledRamGB']
    if ($null -ne $installed -and [double]$installed.Value -gt 0) {
        return [double]$installed.Value
    }
    return [double]$Hardware.RamGB
}
function Get-HardwareInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $processor = Get-CimInstance -ClassName Win32_Processor |
        Select-Object -First 1
    $systemDrive = $env:SystemDrive
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk `
        -Filter "DeviceID='$systemDrive'"
    $videoControllers = @(Get-CimInstance `
        -ClassName Win32_VideoController)
    $nvidiaDetected = @(
        $videoControllers | Where-Object {
            $_.Name -match 'NVIDIA' -or $_.PNPDeviceID -match 'VEN_10DE'
        }
    ).Count -gt 0
    $nvidiaSmi = Get-NvidiaSmiPath
    $nvidiaGpus = @()
    if ($null -ne $nvidiaSmi) {
        try {
            $nvidiaGpus = @(Get-NvidiaGpuData -NvidiaSmiPath $nvidiaSmi)
            if ($nvidiaGpus.Count -eq 0) {
                $nvidiaSmi = $null
            }
        }
        catch {
            Write-Verbose ('NVIDIA surucu denetimi basarisiz: {0}' -f `
                $_.Exception.Message)
            $nvidiaSmi = $null
            $nvidiaGpus = @()
        }
    }
    Assert-NvidiaDriverIfRequired -Context $Context `
        -NvidiaDetected $nvidiaDetected `
        -NvidiaSmiReady ($null -ne $nvidiaSmi)
    $ramGB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
    $installedRam = Get-CimInstance -ClassName Win32_PhysicalMemory `
        -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum
    $installedRamGB = if ($null -ne $installedRam -and $installedRam.Sum -gt 0) {
        [math]::Round($installedRam.Sum / 1GB, 2)
    }
    else {
        $ramGB
    }
    $freeDiskGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    $chassis = @(Get-CimInstance -ClassName Win32_SystemEnclosure)
    $portableTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isLaptop = $computer.PCSystemType -eq 2 -or @(
        $chassis.ChassisTypes | Where-Object { $_ -in $portableTypes }
    ).Count -gt 0
    return [pscustomobject][ordered]@{
        CollectedAt = [DateTimeOffset]::UtcNow.ToString('O')
        ComputerName = $env:COMPUTERNAME
        FormFactor = if ($isLaptop) { 'LAPTOP' } else { 'DESKTOP' }
        Cpu = [pscustomobject][ordered]@{
            Name = $processor.Name.Trim()
            PhysicalCores = [int]$processor.NumberOfCores
            LogicalCores = [int]$processor.NumberOfLogicalProcessors
        }
        RamGB = $ramGB
        InstalledRamGB = $installedRamGB
        SharedVramLimitGB = [math]::Round($ramGB / 2, 2)
        SystemDrive = $systemDrive
        FreeDiskGB = $freeDiskGB
        NvidiaDetected = $nvidiaDetected
        NvidiaSmiReady = $null -ne $nvidiaSmi
        Gpus = $nvidiaGpus
        VideoControllers = @(
            $videoControllers | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    DriverVersion = $_.DriverVersion
                    PnpDeviceId = $_.PNPDeviceID
                }
            }
        )
    }
}
function Select-CompatibleModels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [pscustomobject]$Hardware
    )
    if (-not $Context.Config.Ollama.Enabled -or
        $Context.Config.Models.SelectionMode -eq 'Skip') {
        return @()
    }
    $catalog = @($Context.Config.Models.Catalog)
    $maximumVram = 0.0
    if (@($Hardware.Gpus).Count -gt 0) {
        $maximumVram = [double](
            $Hardware.Gpus |
                Measure-Object -Property DedicatedVramGB -Maximum
        ).Maximum
    }
    $requested = @($Context.Config.Models.Requested)
    $automatic = $requested.Count -eq 0
    $compatible = @(
        $catalog | Where-Object {
            $settings = $Context.Config.Models.MemoryEstimation
            $contextK = if ($automatic) {
                $Context.Config.Models.DefaultContextK
            }
            else {
                [math]::Min(
                    $Context.Config.Models.DefaultContextK,
                    $_.MaxContextK
                )
            }
            $modelMemory = $_.DownloadSizeGB *
                (1 + ($settings.ModelOverheadPercent / 100.0))
            $kvMemory = [math]::Sqrt([double]$_.ParametersB) *
                $settings.KvCacheCoefficient * $contextK
            $requiredMemory = $modelMemory + $kvMemory +
                $settings.RuntimeOverheadGB
            $usableRam = [math]::Max(
                0,
                $Hardware.RamGB - $settings.OsReserveGB
            )
            $storage = Get-ModelStorageRequirement -Model $_ `
                -SafetyBufferPercent `
                    $Context.Config.Models.SafetyBufferPercent
            $diskReady = $Hardware.FreeDiskGB -ge $storage.RequiredGB
            $usableVram = [math]::Max(
                0,
                $maximumVram - $settings.GpuReserveGB
            )
            $memoryReady = $requiredMemory -le
                ($usableRam + $usableVram)
            $cpuReady = $Context.Config.Hardware.AllowCpuFallback -and
                $_.CpuFallback
            $contextReady = $contextK -ge 4 -and (
                -not $automatic -or $_.MaxContextK -ge $contextK
            )
            $ready = $diskReady -and $memoryReady -and $contextReady -and
                ($usableVram -gt 0 -or $cpuReady)
            if ($ready) {
                $rank = if ($requiredMemory -le ($usableVram * 0.8)) {
                    4
                }
                elseif ($requiredMemory -le $usableVram) {
                    3
                }
                elseif ($usableVram -gt 0) {
                    2
                }
                else {
                    1
                }
                Add-Member -InputObject $_ `
                    -NotePropertyName CompatibilityRank `
                    -NotePropertyValue $rank -Force
                Add-Member -InputObject $_ `
                    -NotePropertyName RecommendedContextK `
                    -NotePropertyValue $contextK -Force
            }
            $ready
        }
    )
    if ($requested.Count -gt 0) {
        $selection = @(
            $compatible | Where-Object { $_.Name -in $requested }
        )
        if ($selection.Count -ne $requested.Count) {
            $selectionNames = @($selection | ForEach-Object {
                [string]$_.Name
            })
            $invalid = @(
                $requested | Where-Object {
                    $_ -notin $selectionNames
                }
            )
            throw (Get-LocalizedText `
                -Key 'Hardware.Error.ModelsIncompatible' `
                -Arguments @(($invalid -join ', ')))
        }
        return $selection
    }
    $selected = $compatible |
        Sort-Object `
            @{ Expression = 'CompatibilityRank'; Descending = $true },
            @{ Expression = 'Priority'; Descending = $true } |
        Select-Object -First 1
    if ($null -eq $selected) {
        throw (Get-LocalizedText `
            -Key 'Hardware.Error.SafeModelMissing')
    }
    return @($selected)
}
function Invoke-HardwareDecisionEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $hardware = Get-HardwareInventory -Context $Context
    $resourcePolicy = Get-HardwareResourcePolicy `
        -Config $Context.Config
    $ramCapacityGB = Get-HardwareRamCapacity -Hardware $hardware
    if ($ramCapacityGB -lt $resourcePolicy.MinimumRamGB) {
        throw (Get-LocalizedText -Key 'Hardware.Error.RamInsufficient' `
            -Arguments @($ramCapacityGB))
    }
    if ($hardware.FreeDiskGB -lt
        $resourcePolicy.MinimumFreeDiskGB) {
        throw (Get-LocalizedText `
            -Key 'Hardware.Error.DiskInsufficient' `
            -Arguments @($hardware.FreeDiskGB))
    }
    $models = @(Select-CompatibleModels -Context $Context `
        -Hardware $hardware)
    $modelNames = @($models | ForEach-Object {
        [string]$_.Name
    })
    $hardwareJson = ConvertTo-StableJson -Value $hardware -Depth 20
    Write-AtomicTextFile -Path $Context.HardwarePath `
        -Content $hardwareJson
    $plan = [pscustomobject][ordered]@{
        CreatedAt = [DateTimeOffset]::UtcNow.ToString('O')
        SelectionMode = $Context.Config.Models.SelectionMode
        Models = $models
    }
    Write-AtomicTextFile -Path $Context.ModelPlanPath `
        -Content (ConvertTo-StableJson -Value $plan -Depth 20)
    Set-EngineStateData -Context $Context -Name Hardware `
        -Value $hardware
    Set-EngineStateData -Context $Context -Name SelectedModels `
        -Value $modelNames
    if (-not $Context.Config.Ollama.Enabled -or
        $Context.Config.Models.SelectionMode -eq 'Skip') {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module HARDWARE -Message 'Hardware.Models.Skipped'
    }
    else {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module HARDWARE `
            -Message 'Hardware.Models.Selected' `
            -MessageArguments @(($modelNames -join ', '))
    }
}
function Test-HardwareDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not (Test-Path -LiteralPath $Context.HardwarePath) -or
        -not (Test-Path -LiteralPath $Context.ModelPlanPath)) {
        return $false
    }
    try {
        $hardware = Read-JsonFile -Path $Context.HardwarePath
        $plan = Read-JsonFile -Path $Context.ModelPlanPath
        $selectionValid = -not $Context.Config.Ollama.Enabled -or
            @($plan.Models).Count -gt 0 -or
            $plan.SelectionMode -eq 'Skip'
        return (Test-HardwareResourcePolicy `
            -Config $Context.Config -Hardware $hardware) -and
            $selectionValid
    }
    catch {
        Write-Verbose ('Donanim karari denetlenemedi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Assert-HardwarePolicyContracts {
    [CmdletBinding()]
    param()
    $disabledOllamaConfig = [pscustomobject]@{
        Ollama = [pscustomobject]@{ Enabled = $false }
        Models = [pscustomobject]@{ SelectionMode = 'Auto' }
    }
    $disabledOllamaContext = [pscustomobject]@{
        Config = $disabledOllamaConfig
    }
    $configBefore = $disabledOllamaConfig |
        ConvertTo-Json -Compress -Depth 5
    $disabledHardware = [pscustomobject]@{}
    $lowHardware = [pscustomobject]@{
        RamGB = 1
        FreeDiskGB = 1
    }
    $lowRamHardware = [pscustomobject]@{
        RamGB = 15
        FreeDiskGB = 100
    }
    $lowDiskHardware = [pscustomobject]@{
        RamGB = 100
        FreeDiskGB = 39
    }
    $readyHardware = [pscustomobject]@{
        RamGB = 15.99
        InstalledRamGB = 16
        FreeDiskGB = 40
    }
    $allDisabledConfig = [pscustomobject][ordered]@{
        Hardware = [pscustomobject]@{
            MinimumRamGB = 16
            MinimumFreeDiskGB = 40
        }
        Ollama = [pscustomobject]@{ Enabled = $false }
        Models = [pscustomobject]@{
            SelectionMode = 'Skip'
            Requested = @()
        }
        ComfyUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $false }
    }
    $voiceOnlyConfig = [pscustomobject][ordered]@{
        Hardware = $allDisabledConfig.Hardware.PSObject.Copy()
        Ollama = [pscustomobject]@{ Enabled = $false }
        Models = [pscustomobject]@{
            SelectionMode = 'Skip'
            Requested = @()
        }
        ComfyUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $true }
    }
    $ollamaModelConfig = [pscustomobject][ordered]@{
        Hardware = $allDisabledConfig.Hardware.PSObject.Copy()
        Ollama = [pscustomobject]@{ Enabled = $true }
        Models = [pscustomobject]@{
            SelectionMode = 'Manual'
            Requested = @('qwen3.5:4b')
        }
        ComfyUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $false }
    }
    $comfyUIConfig = [pscustomobject][ordered]@{
        Hardware = $allDisabledConfig.Hardware.PSObject.Copy()
        Ollama = [pscustomobject]@{ Enabled = $false }
        Models = [pscustomobject]@{
            SelectionMode = 'Skip'
            Requested = @()
        }
        ComfyUI = [pscustomobject]@{ Enabled = $true }
        Voice = [pscustomobject]@{ Enabled = $false }
    }
    $resourceConfigs = @(
        $allDisabledConfig,
        $voiceOnlyConfig,
        $ollamaModelConfig,
        $comfyUIConfig
    )
    $resourceConfigsBefore = $resourceConfigs |
        ConvertTo-Json -Compress -Depth 8
    $disabledPolicy = Get-HardwareResourcePolicy `
        -Config $allDisabledConfig
    $voicePolicy = Get-HardwareResourcePolicy -Config $voiceOnlyConfig
    $ollamaPolicy = Get-HardwareResourcePolicy `
        -Config $ollamaModelConfig
    $comfyUIPolicy = Get-HardwareResourcePolicy -Config $comfyUIConfig
    if (-not (Test-NvidiaDriverPolicyViolation `
            -ComfyUIEnabled $true `
            -NvidiaDetected $true `
            -RequireNvidiaWhenDetected $true `
            -NvidiaSmiReady $false `
            -ContinueOnOptionalError $false) -or
        (Test-NvidiaDriverPolicyViolation `
            -ComfyUIEnabled $false `
            -NvidiaDetected $true `
            -RequireNvidiaWhenDetected $true `
            -NvidiaSmiReady $false `
            -ContinueOnOptionalError $false) -or
        (Test-NvidiaDriverPolicyViolation `
            -ComfyUIEnabled $true `
            -NvidiaDetected $true `
            -RequireNvidiaWhenDetected $true `
            -NvidiaSmiReady $true `
            -ContinueOnOptionalError $false) -or
        (Test-NvidiaDriverPolicyViolation `
            -ComfyUIEnabled $true `
            -NvidiaDetected $true `
            -RequireNvidiaWhenDetected $true `
            -NvidiaSmiReady $false `
            -ContinueOnOptionalError $true) -or
        (Test-NvidiaDriverPolicyViolation `
            -ComfyUIEnabled $true `
            -NvidiaDetected $false `
            -RequireNvidiaWhenDetected $true `
            -NvidiaSmiReady $false `
            -ContinueOnOptionalError $false) -or
        @(Select-CompatibleModels -Context $disabledOllamaContext `
            -Hardware $disabledHardware).Count -ne 0 -or
        ($disabledOllamaConfig | ConvertTo-Json -Compress -Depth 5) `
            -cne $configBefore) {
        throw 'NVIDIA surucu eksikligi politikasi gecersiz.'
    }
    if ($disabledPolicy.MinimumResourcesRequired -or
        $disabledPolicy.MinimumRamGB -ne 0 -or
        $disabledPolicy.MinimumFreeDiskGB -ne 0 -or
        -not (Test-HardwareResourcePolicy `
            -Config $allDisabledConfig -Hardware $lowHardware) -or
        $voicePolicy.MinimumResourcesRequired -or
        -not (Test-HardwareResourcePolicy `
            -Config $voiceOnlyConfig -Hardware $lowHardware) -or
        -not $ollamaPolicy.MinimumResourcesRequired -or
        -not $ollamaPolicy.OllamaModelsRequired -or
        $ollamaPolicy.ComfyUIRequired -or
        (Test-HardwareResourcePolicy `
            -Config $ollamaModelConfig -Hardware $lowRamHardware) -or
        (Test-HardwareResourcePolicy `
            -Config $ollamaModelConfig -Hardware $lowDiskHardware) -or
        -not (Test-HardwareResourcePolicy `
            -Config $ollamaModelConfig -Hardware $readyHardware) -or
        -not $comfyUIPolicy.MinimumResourcesRequired -or
        $comfyUIPolicy.OllamaModelsRequired -or
        -not $comfyUIPolicy.ComfyUIRequired -or
        (Test-HardwareResourcePolicy `
            -Config $comfyUIConfig -Hardware $lowRamHardware) -or
        (Test-HardwareResourcePolicy `
            -Config $comfyUIConfig -Hardware $lowDiskHardware) -or
        -not (Test-HardwareResourcePolicy `
            -Config $comfyUIConfig -Hardware $readyHardware) -or
        ($resourceConfigs | ConvertTo-Json -Compress -Depth 8) `
            -cne $resourceConfigsBefore) {
        throw 'Bilesen tabanli donanim kaynak politikasi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Hardware.DriverPolicy'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Hardware.ResourcePolicy'
    return $true
}
Export-ModuleMember -Function @(
    'Get-NvidiaSmiPath', 'Get-NvidiaGpuData',
    'Get-HardwareResourcePolicy', 'Test-HardwareResourcePolicy',
    'Get-HardwareInventory', 'Select-CompatibleModels',
    'Invoke-HardwareDecisionEngine', 'Test-HardwareDecision',
    'Assert-HardwarePolicyContracts'
)