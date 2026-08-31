Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-GpuValidationPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$NvidiaDetected,
        [Parameter(Mandatory)][bool]$AllowCpuFallback,
        [Parameter(Mandatory)][bool]$ModelCpuFallback
    )
    $cpuFallbackAllowed = $AllowCpuFallback -and $ModelCpuFallback
    return [pscustomobject]@{
        CpuFallbackAllowed = $cpuFallbackAllowed
        CudaRequired = $NvidiaDetected -and -not $cpuFallbackAllowed
        ExecutionAllowed = $NvidiaDetected -or $cpuFallbackAllowed
    }
}
function Get-ModelCpuFallbackCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Model
    )
    $property = $Model.PSObject.Properties['CpuFallback']
    return $null -ne $property -and [bool]$property.Value
}
function New-GpuMemorySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Gpus
    )
    if ($Gpus.Count -eq 0) {
        return [pscustomobject]@{
            Available = $false
            UsedMB = 0
            Gpus = @()
        }
    }
    $usedMB = [math]::Round((
        ($Gpus | Measure-Object -Property UsedVramGB -Sum).Sum * 1024
    ), 0)
    return [pscustomobject]@{
        Available = $true
        UsedMB = [int]$usedMB
        Gpus = @($Gpus)
    }
}
function Get-GpuMemorySnapshot {
    [CmdletBinding()]
    param()
    $nvidiaSmi = Get-NvidiaSmiPath
    if ($null -eq $nvidiaSmi) {
        return New-GpuMemorySnapshot -Gpus @()
    }
    try {
        $gpus = @(Get-NvidiaGpuData -NvidiaSmiPath $nvidiaSmi)
    }
    catch {
        Write-Verbose ('NVIDIA bellek denetimi kullanilamadi: {0}' -f `
            $_.Exception.Message)
        $gpus = @()
    }
    return New-GpuMemorySnapshot -Gpus $gpus
}
function Invoke-GpuInferenceValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Ollama.Enabled -or
        $Context.Config.Models.SelectionMode -eq 'Skip') {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module VALIDATION -Message 'Validation.InferenceSkipped'
        return
    }
    $hardware = Read-JsonFile -Path $Context.HardwarePath
    $plan = Read-JsonFile -Path $Context.ModelPlanPath
    $modelEntry = $plan.Models | Select-Object -First 1
    if ($null -eq $modelEntry -or
        [string]::IsNullOrWhiteSpace($modelEntry.Name)) {
        throw (Get-LocalizedText `
            -Key 'Validation.Error.ModelPlanEmpty')
    }
    $model = $modelEntry.Name
    $null = Wait-OllamaReady -Context $Context `
        -TimeoutSeconds `
            $Context.Config.Runtime.OllamaStartupTimeoutSeconds
    try {
        $null = Invoke-OllamaApi -Context $Context -Method POST `
            -Path '/api/generate' -Body @{
                model = $model
                prompt = ''
                stream = $false
                keep_alive = 0
            } -TimeoutSeconds 60
    }
    catch {
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module VALIDATION `
            -Message 'Validation.PreviousModelUnloadFailed' `
            -Exception $_.Exception
    }
    Start-Sleep -Seconds 2
    $before = Get-GpuMemorySnapshot
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-OllamaApi -Context $Context -Method POST `
        -Path '/api/generate' -Body @{
            model = $model
            prompt = Get-LocalizedText `
                -Key 'Validation.Inference.Prompt'
            stream = $false
            think = $false
            keep_alive = $Context.Config.Ollama.KeepAlive
            options = @{ num_predict = 8 }
        } -TimeoutSeconds `
            $Context.Config.Models.InferenceTimeoutSeconds
    $stopwatch.Stop()
    $after = Get-GpuMemorySnapshot
    $delta = $after.UsedMB - $before.UsedMB
    $running = Invoke-OllamaApi -Context $Context -Method GET `
        -Path '/api/ps' -TimeoutSeconds 30
    $loadedModel = @($running.models) | Where-Object {
        $_.name -eq $model -or $_.model -eq $model
    } | Select-Object -First 1
    $reportedVramMB = if ($null -eq $loadedModel) {
        0
    }
    else {
        [math]::Round(([int64]$loadedModel.size_vram / 1MB), 0)
    }
    $inferenceReady = $response.done -and
        -not [string]::IsNullOrWhiteSpace([string]$response.response)
    $policy = Get-GpuValidationPolicy `
        -NvidiaDetected ([bool]$hardware.NvidiaDetected) `
        -AllowCpuFallback (
            [bool]$Context.Config.Hardware.AllowCpuFallback
        ) -ModelCpuFallback (
            Get-ModelCpuFallbackCapability -Model $modelEntry
        )
    $gpuReady = -not $policy.CudaRequired -or $after.Available
    $vramReady = -not $policy.CudaRequired -or $reportedVramMB -gt 0
    if (-not $policy.ExecutionAllowed) {
        throw (Get-LocalizedText `
            -Key 'Validation.Error.GpuInferenceFailed' `
            -Arguments @($delta))
    }
    if (-not $inferenceReady) {
        throw (Get-LocalizedText `
            -Key 'Validation.Error.InferenceResponseInvalid')
    }
    if (-not $gpuReady -or -not $vramReady) {
        throw (Get-LocalizedText `
            -Key 'Validation.Error.GpuInferenceFailed' `
            -Arguments @($delta))
    }
    $statuses = [Collections.Generic.List[string]]::new()
    if ($after.Available -and $reportedVramMB -gt 0) {
        $statuses.Add('GPU_READY')
        $statuses.Add('CUDA_READY')
        $statuses.Add('VRAM_ALLOCATED')
    }
    else {
        $statuses.Add('CPU_FALLBACK_READY')
    }
    $statuses.Add('MODEL_LOADED')
    $statuses.Add('INFERENCE_SUCCESS')
    $result = [pscustomobject][ordered]@{
        ValidatedAt = [DateTimeOffset]::UtcNow.ToString('O')
        Model = $model
        Statuses = $statuses.ToArray()
        GpuDetected = $after.Available
        CpuFallbackAllowed = $policy.CpuFallbackAllowed
        CudaRequired = $policy.CudaRequired
        CudaReady = $after.Available -and $reportedVramMB -gt 0
        VramBeforeMB = $before.UsedMB
        VramAfterMB = $after.UsedMB
        VramDeltaMB = $delta
        ReportedVramMB = $reportedVramMB
        LatencyMilliseconds = $stopwatch.ElapsedMilliseconds
        InferenceSuccess = $inferenceReady
        Response = [string]$response.response
    }
    Write-AtomicTextFile -Path $Context.ValidationPath `
        -Content (ConvertTo-StableJson -Value $result -Depth 20)
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module VALIDATION `
        -Message 'Validation.InferenceVerified' `
        -MessageArguments @($stopwatch.ElapsedMilliseconds)
}
function Test-GpuValidationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Ollama.Enabled -or
        $Context.Config.Models.SelectionMode -eq 'Skip') {
        return $true
    }
    if (-not (Test-Path -LiteralPath $Context.ValidationPath)) {
        return $false
    }
    try {
        $result = Read-JsonFile -Path $Context.ValidationPath
        $hardware = Read-JsonFile -Path $Context.HardwarePath
        $plan = Read-JsonFile -Path $Context.ModelPlanPath
        $model = @($plan.Models) | Select-Object -First 1
        if ($null -eq $model) {
            return $false
        }
        $policy = Get-GpuValidationPolicy `
            -NvidiaDetected ([bool]$hardware.NvidiaDetected) `
            -AllowCpuFallback (
                [bool]$Context.Config.Hardware.AllowCpuFallback
            ) -ModelCpuFallback (
                Get-ModelCpuFallbackCapability -Model $model
            )
        if (-not $result.InferenceSuccess) {
            return $false
        }
        $recordedCpuFallback =
            $result.PSObject.Properties['CpuFallbackAllowed']
        $recordedCudaRequired =
            $result.PSObject.Properties['CudaRequired']
        if (-not $policy.ExecutionAllowed -or
            $null -eq $recordedCpuFallback -or
            $null -eq $recordedCudaRequired -or
            [bool]$recordedCpuFallback.Value -ne
                [bool]$policy.CpuFallbackAllowed -or
            [bool]$recordedCudaRequired.Value -ne
                [bool]$policy.CudaRequired) {
            return $false
        }
        if ($policy.CudaRequired) {
            return $result.CudaReady -and
                $result.ReportedVramMB -gt 0
        }
        return $true
    }
    catch {
        Write-Verbose ('GPU dogrulama sonucu okunamadi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Test-PlatformDiskPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [double]$AvailableFreeSpaceGB
    )
    $policy = Get-HardwareResourcePolicy -Config $Config
    return $AvailableFreeSpaceGB -ge $policy.MinimumFreeDiskGB
}
function Invoke-PlatformValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $checks = [ordered]@{
        Runtime = Test-AiRuntime -Context $Context
        Models = Test-SelectedModels -Context $Context
        Inference = Test-GpuValidationResult -Context $Context
        Security = Test-DeploymentSecurity -Context $Context
        Environment = Test-SystemEnvironment -Context $Context
    }
    $drive = [IO.DriveInfo]::new(
        [IO.Path]::GetPathRoot($Context.RootPath)
    )
    $checks.Disk = Test-PlatformDiskPolicy -Config $Context.Config `
        -AvailableFreeSpaceGB ($drive.AvailableFreeSpace / 1GB)
    $failed = @(
        $checks.GetEnumerator() | Where-Object { -not $_.Value }
    )
    $failedNames = @($failed | ForEach-Object { [string]$_.Key })
    $failedLabels = @($failedNames | ForEach-Object {
        Get-LocalizedText -Key "Reporting.Check.$_"
    })
    $result = [pscustomobject][ordered]@{
        ValidatedAt = [DateTimeOffset]::UtcNow.ToString('O')
        Success = $failed.Count -eq 0
        Checks = $checks
        FailedChecks = $failedNames
    }
    $path = Join-Path $Context.DataPath 'platform-validation.json'
    Write-AtomicTextFile -Path $path `
        -Content (ConvertTo-StableJson -Value $result -Depth 20)
    if (-not $result.Success) {
        throw (Get-LocalizedText `
            -Key 'Validation.Error.PlatformFailed' `
            -Arguments @(($failedLabels -join ', ')))
    }
}
function Test-PlatformValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $path = Join-Path $Context.DataPath 'platform-validation.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return $false
    }
    try {
        return [bool](Read-JsonFile -Path $path).Success
    }
    catch {
        Write-Verbose ('Platform dogrulama sonucu okunamadi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Assert-GpuValidationContracts {
    [CmdletBinding()]
    param()
    $strictGpu = Get-GpuValidationPolicy `
        -NvidiaDetected $true -AllowCpuFallback $false `
        -ModelCpuFallback $true
    $allowedFallback = Get-GpuValidationPolicy `
        -NvidiaDetected $true -AllowCpuFallback $true `
        -ModelCpuFallback $true
    $modelForbidsFallback = Get-GpuValidationPolicy `
        -NvidiaDetected $true -AllowCpuFallback $true `
        -ModelCpuFallback $false
    $cpuOnly = Get-GpuValidationPolicy `
        -NvidiaDetected $false -AllowCpuFallback $true `
        -ModelCpuFallback $true
    $unsupported = Get-GpuValidationPolicy `
        -NvidiaDetected $false -AllowCpuFallback $false `
        -ModelCpuFallback $true
    $emptySnapshot = New-GpuMemorySnapshot -Gpus @()
    $gpuFixture = [pscustomobject]@{ UsedVramGB = 1.5 }
    $readySnapshot = New-GpuMemorySnapshot -Gpus @($gpuFixture)
    $allDisabledConfig = [pscustomobject][ordered]@{
        Hardware = [pscustomobject]@{
            MinimumRamGB = 16
            MinimumFreeDiskGB = 40
        }
        Ollama = [pscustomobject]@{ Enabled = $false }
        Models = [pscustomobject]@{ SelectionMode = 'Skip' }
        ComfyUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $false }
    }
    $voiceOnlyConfig = [pscustomobject][ordered]@{
        Hardware = $allDisabledConfig.Hardware.PSObject.Copy()
        Ollama = [pscustomobject]@{ Enabled = $false }
        Models = [pscustomobject]@{ SelectionMode = 'Skip' }
        ComfyUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $true }
    }
    $ollamaModelConfig = [pscustomobject][ordered]@{
        Hardware = $allDisabledConfig.Hardware.PSObject.Copy()
        Ollama = [pscustomobject]@{ Enabled = $true }
        Models = [pscustomobject]@{ SelectionMode = 'Manual' }
        ComfyUI = [pscustomobject]@{ Enabled = $false }
        Voice = [pscustomobject]@{ Enabled = $false }
    }
    $comfyUIConfig = [pscustomobject][ordered]@{
        Hardware = $allDisabledConfig.Hardware.PSObject.Copy()
        Ollama = [pscustomobject]@{ Enabled = $false }
        Models = [pscustomobject]@{ SelectionMode = 'Skip' }
        ComfyUI = [pscustomobject]@{ Enabled = $true }
        Voice = [pscustomobject]@{ Enabled = $false }
    }
    $diskConfigs = @(
        $allDisabledConfig,
        $voiceOnlyConfig,
        $ollamaModelConfig,
        $comfyUIConfig
    )
    $diskConfigsBefore = $diskConfigs |
        ConvertTo-Json -Compress -Depth 6
    if (-not $strictGpu.ExecutionAllowed -or
        -not $strictGpu.CudaRequired -or
        $strictGpu.CpuFallbackAllowed -or
        -not $allowedFallback.ExecutionAllowed -or
        $allowedFallback.CudaRequired -or
        -not $allowedFallback.CpuFallbackAllowed -or
        -not $modelForbidsFallback.CudaRequired -or
        -not $cpuOnly.ExecutionAllowed -or $cpuOnly.CudaRequired -or
        $unsupported.ExecutionAllowed -or $emptySnapshot.Available -or
        $emptySnapshot.UsedMB -ne 0 -or
        -not $readySnapshot.Available -or
        $readySnapshot.UsedMB -ne 1536 -or
        @($readySnapshot.Gpus).Count -ne 1 -or
        -not (Test-PlatformDiskPolicy -Config $allDisabledConfig `
            -AvailableFreeSpaceGB 1) -or
        -not (Test-PlatformDiskPolicy -Config $voiceOnlyConfig `
            -AvailableFreeSpaceGB 1) -or
        (Test-PlatformDiskPolicy -Config $ollamaModelConfig `
            -AvailableFreeSpaceGB 39) -or
        -not (Test-PlatformDiskPolicy -Config $ollamaModelConfig `
            -AvailableFreeSpaceGB 40) -or
        (Test-PlatformDiskPolicy -Config $comfyUIConfig `
            -AvailableFreeSpaceGB 39) -or
        -not (Test-PlatformDiskPolicy -Config $comfyUIConfig `
            -AvailableFreeSpaceGB 40) -or
        ($diskConfigs | ConvertTo-Json -Compress -Depth 6) `
            -cne $diskConfigsBefore) {
        throw 'GPU ve CPU fallback dogrulama politikasi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Validation.GpuSnapshot'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Validation.GpuPolicy'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Validation.DiskPolicy'
    return $true
}
Export-ModuleMember -Function @(
    'Get-GpuMemorySnapshot', 'Invoke-GpuInferenceValidation',
    'Test-GpuValidationResult', 'Invoke-PlatformValidation',
    'Test-PlatformValidation', 'Assert-GpuValidationContracts'
)