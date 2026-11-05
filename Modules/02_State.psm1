Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function New-EngineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return [pscustomobject][ordered]@{
        EngineVersion = $Context.Config.EngineVersion
        MachineID = $Context.MachineId
        InstallSessionID = [string]$Context.SessionId
        CurrentStage = ''
        StageStatus = 'IDLE'
        StartedAt = $null
        CompletedAt = $null
        Checkpoint = ''
        RetryCount = [pscustomobject]@{}
        CompletedStages = @()
        FailedStages = @()
        RollbackAvailable = $false
        LastException = ''
        RecoveryAction = ''
        StageHistory = @()
        SelectedModels = @()
        Hardware = $null
    }
}
function Test-EngineStateShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $required = @(
        'EngineVersion', 'MachineID', 'InstallSessionID',
        'CurrentStage', 'StageStatus', 'StartedAt', 'CompletedAt',
        'Checkpoint', 'RetryCount', 'CompletedStages',
        'FailedStages', 'RollbackAvailable', 'LastException',
        'RecoveryAction', 'StageHistory', 'SelectedModels',
        'Hardware'
    )
    foreach ($name in $required) {
        if ($null -eq $State.PSObject.Properties[$name]) {
            return $false
        }
    }
    if ($State.MachineID -ne $Context.MachineId) {
        return $false
    }
    $allowedStatuses = @(
        'IDLE', 'RUNNING', 'SUCCESS', 'FAILED',
        'RECOVERING', 'ROLLBACK'
    )
    return $State.StageStatus -in $allowedStatuses
}
function ConvertTo-EngineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Json,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $state = ConvertFrom-WinlamaJson -Json $Json
    if (-not (Test-EngineStateShape -State $state -Context $Context)) {
        throw (Get-LocalizedText -Key 'State.Error.SchemaInvalid')
    }
    return $state
}
function Test-EngineStateContinuationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][pscustomobject]$Context
    )
    return [string]$State.EngineVersion -ceq
        [string]$Context.Config.EngineVersion -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$Context.SessionId
        ) -and
        [string]$State.InstallSessionID -ceq
            [string]$Context.SessionId
}
function Assert-EngineStateJsonContracts {
    [CmdletBinding()]
    param()
    $dateText = '2026-08-20T11:22:33.4567890+00:00'
    $context = [pscustomobject]@{
        MachineId = 'fixture-machine'
        SessionId = 'fixture-session'
        Config = [pscustomobject]@{ EngineVersion = '26.10.29' }
    }
    $fixture = New-EngineState -Context $context
    $fixture.InstallSessionID = 'fixture-session'
    $fixture.StartedAt = $dateText
    $fixture.CompletedAt = $dateText
    $fixture.StageHistory = @(
        [pscustomobject]@{ At = $dateText; Stage = 'BOOTSTRAP' }
    )
    $json = ConvertTo-StableJson -Value $fixture -Depth 100
    $state = ConvertTo-EngineState -Json $json -Context $context
    $foreignContext = [pscustomobject]@{
        MachineId = 'fixture-machine'
        SessionId = 'different-session'
        Config = [pscustomobject]@{ EngineVersion = '26.10.29' }
    }
    if ($state.StartedAt -isnot [string] -or
        [string]$state.StartedAt -cne $dateText -or
        $state.CompletedAt -isnot [string] -or
        [string]$state.CompletedAt -cne $dateText -or
        $state.StageHistory[0].At -isnot [string] -or
        [string]$state.StageHistory[0].At -cne $dateText -or
        (ConvertTo-StableJson -Value $state -Depth 100) -cne $json -or
        -not (Test-EngineStateContinuationAllowed `
            -State $state -Context $context) -or
        (Test-EngineStateContinuationAllowed `
            -State $state -Context $foreignContext)) {
        throw 'Engine state JSON tarih string sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:State.JsonDateKind'
    return $true
}
function Read-EngineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not (Test-Path -LiteralPath $Context.StatePath)) {
        return New-EngineState -Context $Context
    }
    try {
        $json = Get-Content -LiteralPath $Context.StatePath -Raw `
            -Encoding UTF8
        return ConvertTo-EngineState -Json $json -Context $Context
    }
    catch {
        throw (Get-LocalizedText -Key 'State.Error.Unreadable'), `
            $_.Exception
    }
}
function Write-EngineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )
    if (-not (Test-EngineStateShape -State $State -Context $Context)) {
        throw (Get-LocalizedText -Key 'State.Error.WriteInvalid')
    }
    $json = ConvertTo-StableJson -Value $State -Depth 100
    Write-AtomicTextFile -Path $Context.StatePath -Content $json
}
function Enter-EngineLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    try {
        $stream = [IO.File]::Open(
            $Context.LockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $stream.SetLength(0)
        $writer = [IO.StreamWriter]::new(
            $stream,
            [Text.UTF8Encoding]::new($false),
            1024,
            $true
        )
        try {
            $writer.Write(
                "PID=$PID;StartedAt=$([DateTimeOffset]::UtcNow.ToString('O'))"
            )
            $writer.Flush()
            $stream.Flush($true)
        }
        finally {
            $writer.Dispose()
        }
        return $stream
    }
    catch {
        throw (Get-LocalizedText `
            -Key 'State.Error.ConcurrentSession'), $_.Exception
    }
}
function Exit-EngineLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [IO.FileStream]$Lock
    )
    $Lock.Dispose()
}
function Initialize-EngineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (Test-Path -LiteralPath $Context.StatePath) {
        try {
            $state = Read-EngineState -Context $Context
        }
        catch {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module STATE -Message 'State.Reset.Stale' `
                -Exception $_.Exception
            $state = New-EngineState -Context $Context
            Write-EngineState -Context $Context -State $state
            return
        }
        if (-not (Test-EngineStateContinuationAllowed `
            -State $state -Context $Context)) {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module STATE -Message 'State.Reset.Stale'
            $state = New-EngineState -Context $Context
            Write-EngineState -Context $Context -State $state
        }
        return
    }
    $state = New-EngineState -Context $Context
    Write-EngineState -Context $Context -State $state
}
function Add-StateHistoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [string]$Stage,
        [Parameter(Mandatory)]
        [string]$Status,
        [string]$Message = ''
    )
    $entry = [pscustomobject][ordered]@{
        Stage = $Stage
        Status = $Status
        At = [DateTimeOffset]::UtcNow.ToString('O')
        Message = $Message
    }
    $State.StageHistory = @($State.StageHistory) + $entry
}
function Repair-InterruptedEngineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $state = Read-EngineState -Context $Context
    if ($state.StageStatus -notin @('RUNNING', 'ROLLBACK')) {
        return
    }
    $previousStatus = $state.StageStatus
    $state.StageStatus = 'RECOVERING'
    $state.RecoveryAction = 'VERIFY_AND_RETRY_CURRENT_STAGE'
    Add-StateHistoryEntry -State $state -Stage $state.CurrentStage `
        -Status RECOVERING -Message (Get-LocalizedText `
            -Key 'State.InterruptedStatus' `
            -Arguments @((Get-LocalizedText `
                -Key "State.Status.$previousStatus")))
    Write-EngineState -Context $Context -State $state
    Write-DeploymentLog -Context $Context -Level WARN -Module STATE `
        -Message 'State.InterruptedStageRecovering' `
        -MessageArguments @((Get-LocalizedText `
            -Key "Stage.$($state.CurrentStage)")) `
        -Recovery $state.RecoveryAction
}
function Set-StateRetryCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [string]$Stage,
        [Parameter(Mandatory)]
        [int]$Value
    )
    $property = $State.RetryCount.PSObject.Properties[$Stage]
    if ($null -eq $property) {
        Add-Member -InputObject $State.RetryCount `
            -NotePropertyName $Stage -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
}
function Save-StageCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [string]$Stage
    )
    $path = Join-Path $Context.CheckpointsPath "$Stage.json"
    $json = ConvertTo-StableJson -Value $State -Depth 100
    Write-AtomicTextFile -Path $path -Content $json
    $State.Checkpoint = $path
}
function Invoke-DeploymentStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$Action,
        [Parameter(Mandatory)]
        [scriptblock]$Verify,
        [scriptblock]$Rollback,
        [int[]]$RetryDelays = @(30, 120, 300),
        [switch]$Force
    )
    $Context.CurrentStage = $Name
    $displayName = Get-LocalizedText -Key "Stage.$Name"
    $state = Read-EngineState -Context $Context
    if (-not $Force -and $state.CompletedStages -contains $Name) {
        try {
            if (& $Verify) {
                Write-DeploymentLog -Context $Context -Level INFO `
                    -Module STATE -Message 'State.Stage.VerifiedSkipped' `
                    -MessageArguments @($displayName)
                return
            }
        }
        catch {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module STATE `
                -Message 'State.Stage.CompletedVerificationFailed' `
                -MessageArguments @($displayName) `
                -Exception $_.Exception -Recovery REPAIR_STAGE
        }
        $state.CompletedStages = @(
            $state.CompletedStages | Where-Object { $_ -ne $Name }
        )
        $state.StageStatus = 'RECOVERING'
        $state.RecoveryAction = 'REPAIR_STAGE'
    }
    Save-StageCheckpoint -Context $Context -State $state -Stage $Name
    $state.CurrentStage = $Name
    $state.StageStatus = 'RUNNING'
    $state.StartedAt = [DateTimeOffset]::UtcNow.ToString('O')
    $state.CompletedAt = $null
    $state.RollbackAvailable = $null -ne $Rollback
    $state.LastException = ''
    $state.RecoveryAction = ''
    Add-StateHistoryEntry -State $state -Stage $Name -Status RUNNING
    Write-EngineState -Context $Context -State $state
    Write-DeploymentLog -Context $Context -Level INFO -Module STATE `
        -Message 'State.Stage.Started' `
        -MessageArguments @($displayName)
    $lastException = $null
    $maximumAttempts = $RetryDelays.Count + 1
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            $null = & $Action
            if (-not (& $Verify)) {
                throw (Get-LocalizedText `
                    -Key 'State.Error.StageVerificationFailed' `
                    -Arguments @($displayName))
            }
            $state = Read-EngineState -Context $Context
            if ($state.CompletedStages -notcontains $Name) {
                $state.CompletedStages = @($state.CompletedStages) + $Name
            }
            $state.FailedStages = @(
                $state.FailedStages | Where-Object { $_ -ne $Name }
            )
            $state.StageStatus = 'SUCCESS'
            $state.CompletedAt = [DateTimeOffset]::UtcNow.ToString('O')
            $state.LastException = ''
            $state.RecoveryAction = ''
            $state.RollbackAvailable = $false
            Set-StateRetryCount -State $state -Stage $Name `
                -Value ($attempt - 1)
            Add-StateHistoryEntry -State $state -Stage $Name `
                -Status SUCCESS
            Write-EngineState -Context $Context -State $state
            Write-DeploymentLog -Context $Context -Level INFO `
                -Module STATE -Message 'State.Stage.Completed' `
                -MessageArguments @($displayName)
            return
        }
        catch {
            $lastException = $_.Exception
            $retrySetting = $lastException.Data['Winlama.Retryable']
            $retryable = $null -eq $retrySetting -or [bool]$retrySetting
            $state = Read-EngineState -Context $Context
            $state.StageStatus = 'FAILED'
            $state.LastException = $lastException.ToString()
            $state.RecoveryAction = if ($retryable) {
                'RETRY'
            }
            else {
                'ABORT_NON_RETRYABLE'
            }
            if ($state.FailedStages -notcontains $Name) {
                $state.FailedStages = @($state.FailedStages) + $Name
            }
            Set-StateRetryCount -State $state -Stage $Name `
                -Value $attempt
            Add-StateHistoryEntry -State $state -Stage $Name `
                -Status FAILED -Message $lastException.Message
            Write-EngineState -Context $Context -State $state
            Write-DeploymentLog -Context $Context -Level ERROR `
                -Module STATE -Message 'State.Stage.Failed' `
                -MessageArguments @($displayName) `
                -Exception $lastException -Recovery $state.RecoveryAction
            if (-not $retryable) {
                Write-DeploymentLog -Context $Context -Level ERROR `
                    -Module STATE `
                    -Message 'State.Stage.NonRetryable' `
                    -MessageArguments @($displayName)
                break
            }
            if ($attempt -lt $maximumAttempts) {
                Start-Sleep -Seconds $RetryDelays[$attempt - 1]
            }
        }
    }
    if ($null -ne $Rollback) {
        $state = Read-EngineState -Context $Context
        $state.StageStatus = 'ROLLBACK'
        $state.RecoveryAction = 'ROLLBACK_STAGE'
        Write-EngineState -Context $Context -State $state
        try {
            $null = & $Rollback
            $state = Read-EngineState -Context $Context
            $state.RecoveryAction = 'ROLLBACK_COMPLETED'
            $state.RollbackAvailable = $false
            Add-StateHistoryEntry -State $state -Stage $Name `
                -Status ROLLBACK -Message (Get-LocalizedText `
                    -Key 'State.Rollback.Completed')
            Write-EngineState -Context $Context -State $state
        }
        catch {
            Write-DeploymentLog -Context $Context -Level ERROR `
                -Module STATE -Message $_.Exception.Message `
                -Exception $_.Exception `
                -EventCode 'State.Rollback.Failed'
            $state = Read-EngineState -Context $Context
            $state.LastException += "`nROLLBACK: $($_.Exception)"
            $state.RecoveryAction = 'ROLLBACK_FAILED'
            Write-EngineState -Context $Context -State $state
        }
    }
    throw $lastException
}
function Set-EngineStateData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$Name,
        [AllowNull()]
        [object]$Value
    )
    $state = Read-EngineState -Context $Context
    $property = $state.PSObject.Properties[$Name]
    if ($null -eq $property) {
        Add-Member -InputObject $state -NotePropertyName $Name `
            -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
    Write-EngineState -Context $Context -State $state
}
function Complete-EngineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $state = Read-EngineState -Context $Context
    $state.CurrentStage = ''
    $state.StageStatus = 'SUCCESS'
    $state.CompletedAt = [DateTimeOffset]::UtcNow.ToString('O')
    $state.LastException = ''
    $state.RecoveryAction = ''
    $state.RollbackAvailable = $false
    Write-EngineState -Context $Context -State $state
}
function Set-EngineFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [Exception]$Exception
    )
    if (-not (Test-Path -LiteralPath $Context.StatePath)) {
        return
    }
    $state = Read-EngineState -Context $Context
    $state.StageStatus = 'FAILED'
    $state.LastException = $Exception.ToString()
    if ([string]::IsNullOrWhiteSpace($state.RecoveryAction)) {
        $state.RecoveryAction = 'RESUME_REQUIRED'
    }
    Write-EngineState -Context $Context -State $state
}
Export-ModuleMember -Function @(
    'New-EngineState', 'Read-EngineState', 'Write-EngineState',
    'Assert-EngineStateJsonContracts',
    'Test-EngineStateContinuationAllowed',
    'Enter-EngineLock', 'Exit-EngineLock',
    'Initialize-EngineState', 'Repair-InterruptedEngineState',
    'Invoke-DeploymentStage', 'Set-EngineStateData',
    'Complete-EngineState', 'Set-EngineFailure'
)