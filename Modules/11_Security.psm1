Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-PersistentExecutionPolicy {
    [CmdletBinding()]
    param()
    foreach ($scope in @(
        'MachinePolicy',
        'UserPolicy',
        'CurrentUser',
        'LocalMachine'
    )) {
        $policy = Get-ExecutionPolicy -Scope $scope
        if ($policy -ne 'Undefined') {
            return $policy
        }
    }
    return 'Undefined'
}
function Set-TransportSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $protocol = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $protocol = $protocol -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocol
    $bootstrapArtifact = $Context.Config.Bootstrap.PowerShell
    if (([uri]$bootstrapArtifact.Uri).Scheme -ne 'https' -or
        [string]::IsNullOrWhiteSpace($bootstrapArtifact.Sha256)) {
        throw (Get-LocalizedText `
            -Key 'Security.Error.PowerShellTrustInvalid')
    }
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module SECURITY `
        -Message 'Security.TransportVerified'
}
function Test-TransportSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $tls12 = [Net.ServicePointManager]::SecurityProtocol.HasFlag(
        [Net.SecurityProtocolType]::Tls12
    )
    return $tls12
}
function Get-WinlamaFirewallRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $matches = @(
        Get-NetFirewallRule -Name $Name `
            -ErrorAction SilentlyContinue
        Get-NetFirewallRule -DisplayName $Name `
            -ErrorAction SilentlyContinue
    )
    return @($matches | Sort-Object Name -Unique)
}
function Get-WinlamaFirewallRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return Get-WinlamaFirewallRules -Name $Name |
        Select-Object -First 1
}
function Get-NetworkPortListeners {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port `
        -ErrorAction SilentlyContinue | Where-Object {
            $_.LocalAddress -notin @(
                '127.0.0.1', '::1', '::ffff:127.0.0.1'
            )
        })
}
function Test-WinlamaLoopbackHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName)
    return $HostName -in @(
        '127.0.0.1', 'localhost', '::1', '[::1]'
    )
}
function Invoke-NetshFirewallCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    return Invoke-ExternalProcess -FilePath $netsh `
        -ArgumentList $Arguments -TimeoutSeconds 30 `
        -AllowedExitCodes $AllowedExitCodes `
        -Activity (Get-LocalizedText `
            -Key 'Security.Firewall.NetshConfiguring')
}
function Add-WinlamaNetshFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Allow', 'Block')]
        [string]$Action,
        [Parameter(Mandatory)][int]$Port,
        [string[]]$RemoteAddresses = @('Any')
    )
    $remote = @($RemoteAddresses) -join ','
    $null = Invoke-NetshFirewallCommand -Arguments @(
        'advfirewall', 'firewall', 'add', 'rule',
        "name=$Name", 'dir=in',
        "action=$($Action.ToLowerInvariant())",
        'protocol=TCP', "localport=$Port", "remoteip=$remote",
        'profile=any', 'enable=yes', 'edge=no'
    )
}
function Test-FirewallRemoteAddressSet {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Expected,
        [AllowEmptyCollection()][string[]]$Actual
    )
    $expectedSet = @($Expected | Sort-Object -Unique)
    $actualSet = @($Actual | Sort-Object -Unique)
    return @($expectedSet | Where-Object {
        $_ -notin $actualSet
    }).Count -eq 0 -and @($actualSet | Where-Object {
        $_ -notin $expectedSet
    }).Count -eq 0
}
function Test-DeploymentRuntimeBindingRequired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][bool]$Enabled
    )
    return $Enabled -and -not (Test-AiRuntimeComponentDegraded `
        -Context $Context -Name $Component)
}
function Assert-DeploymentSecurityContracts {
    [CmdletBinding()]
    param()
    $expected = @('192.168.1.0/24')
    if (-not (Test-FirewallRemoteAddressSet `
        -Expected $expected -Actual $expected) -or
        (Test-FirewallRemoteAddressSet -Expected $expected `
            -Actual @('192.168.1.0/24', 'Any')) -or
        (Test-FirewallRemoteAddressSet -Expected $expected `
            -Actual @())) {
        throw 'Guvenlik duvari uzak adres kumesi sozlesmesi gecersiz.'
    }
    $context = [pscustomobject]@{}
    if (-not (Test-DeploymentRuntimeBindingRequired `
            -Context $context -Component Voice -Enabled $true) -or
        (Test-DeploymentRuntimeBindingRequired `
            -Context $context -Component Voice -Enabled $false)) {
        throw 'Guvenlik calisma zamani etkinlik sozlesmesi gecersiz.'
    }
    $context | Add-Member -NotePropertyName `
        RuntimeDegradedComponents -NotePropertyValue @('Voice')
    if (Test-DeploymentRuntimeBindingRequired `
        -Context $context -Component Voice -Enabled $true) {
        throw 'Degraded ses servisi guvenlik portuna zorunlu tutuldu.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Security.FirewallAddressSet'
    Write-Verbose 'WINLAMA_VALIDATION_OK:Security.DegradedBindings'
}
function Test-DeploymentFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Allow', 'Block')]
        [string]$Action,
        [Parameter(Mandatory)]
        [int]$Port,
        [string[]]$RemoteAddresses = @()
    )
    $rule = Get-WinlamaFirewallRule -Name $Name
    if ($null -eq $rule -or
        [string]$rule.Enabled -ne 'True' -or
        [string]$rule.Direction -ne 'Inbound' -or
        [string]$rule.Action -ne $Action) {
        return $false
    }
    $portFilter = $rule | Get-NetFirewallPortFilter `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $portFilter -or
        [string]$portFilter.Protocol -notin @('TCP', '6') -or
        [string]$Port -notin @($portFilter.LocalPort)) {
        return $false
    }
    if ($RemoteAddresses.Count -eq 0) {
        return $true
    }
    $addressFilter = $rule | Get-NetFirewallAddressFilter `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $addressFilter) {
        return $false
    }
    $actualAddresses = @($addressFilter.RemoteAddress)
    return Test-FirewallRemoteAddressSet `
        -Expected $RemoteAddresses -Actual $actualAddresses
}
function Set-DeploymentFirewall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $rules = $Context.Config.Security.FirewallRules
    foreach ($name in @($rules.PSObject.Properties.Value)) {
        $existingRules = @(Get-WinlamaFirewallRules -Name $name)
        if ($existingRules.Count -gt 0) {
            $existingRules |
                Remove-NetFirewallRule -ErrorAction Stop
        }
        $null = Invoke-NetshFirewallCommand -Arguments @(
            'advfirewall', 'firewall', 'delete', 'rule',
            "name=$name"
        ) -AllowedExitCodes @(0, 1)
    }
    $remoteAddresses = @(
        $Context.Config.Security.LanRemoteAddresses
    )
    $ollamaAllowLan = $Context.Config.Ollama.Enabled -and
        $Context.Config.Security.LanAccess -and
        -not (Test-WinlamaLoopbackHost `
            -HostName $Context.Config.Ollama.Host)
    if ($ollamaAllowLan) {
        Add-WinlamaNetshFirewallRule -Name $rules.OllamaLanAllow `
            -Action Allow -Port $Context.Config.Ollama.Port `
            -RemoteAddresses $remoteAddresses
    }
    elseif ($Context.Config.Ollama.Enabled -and
        @(Get-NetworkPortListeners `
        -Port $Context.Config.Ollama.Port).Count -gt 0) {
        Add-WinlamaNetshFirewallRule -Name $rules.OllamaLocalOnly `
            -Action Block -Port $Context.Config.Ollama.Port
    }
    if ($Context.Config.OpenWebUI.Enabled -and
        $Context.Config.Security.LanAccess) {
        Add-WinlamaNetshFirewallRule -Name $rules.WebUILanAllow `
            -Action Allow -Port $Context.Config.OpenWebUI.Port `
            -RemoteAddresses $remoteAddresses
    }
    elseif ($Context.Config.OpenWebUI.Enabled -and
        @(Get-NetworkPortListeners `
            -Port $Context.Config.OpenWebUI.Port).Count -gt 0) {
        Add-WinlamaNetshFirewallRule -Name $rules.WebUILocalOnly `
            -Action Block -Port $Context.Config.OpenWebUI.Port
    }
}
function Set-DeploymentSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    Set-DeploymentFirewall -Context $Context
    $message = if ($Context.Config.Security.LanAccess) {
        'Security.LanPoliciesApplied'
    }
    else {
        'Security.PoliciesApplied'
    }
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module SECURITY -Message $message
}
function Test-LoopbackBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $services = @()
    if ($Context.Config.Ollama.Enabled) {
        $services += [pscustomobject]@{
            Port = [int]$Context.Config.Ollama.Port
            AllowLan = $Context.Config.Security.LanAccess -and
                -not (Test-WinlamaLoopbackHost `
                    -HostName $Context.Config.Ollama.Host)
            LocalFirewallRule = $Context.Config.Security.
                FirewallRules.OllamaLocalOnly
        }
    }
    if (Test-DeploymentRuntimeBindingRequired `
        -Context $Context -Component Voice `
        -Enabled ([bool]$Context.Config.Voice.Enabled)) {
        $services += [pscustomobject]@{
            Port = [int]$Context.Config.Voice.Port
            AllowLan = $false
            LocalFirewallRule = ''
        }
    }
    if ($Context.Config.OpenWebUI.Enabled) {
        $services += [pscustomobject]@{
            Port = [int]$Context.Config.OpenWebUI.Port
            AllowLan = [bool]$Context.Config.Security.LanAccess
            LocalFirewallRule = $Context.Config.Security.
                FirewallRules.WebUILocalOnly
        }
    }
    foreach ($service in $services) {
        $port = $service.Port
        $listeners = @(Get-NetTCPConnection -State Listen `
            -LocalPort $port -ErrorAction SilentlyContinue)
        if ($listeners.Count -eq 0) {
            Write-DeploymentLog -Context $Context -Level ERROR `
                -Module SECURITY `
                -Message 'Security.Validation.ListenerMissing' `
                -MessageArguments @($port)
            return $false
        }
        $networkListeners = @(Get-NetworkPortListeners -Port $port)
        if ($service.AllowLan) {
            if ($networkListeners.Count -eq 0) {
                Write-DeploymentLog -Context $Context -Level ERROR `
                    -Module SECURITY `
                    -Message 'Security.Validation.LanListenerMissing' `
                    -MessageArguments @($port)
                return $false
            }
            continue
        }
        if ($networkListeners.Count -gt 0) {
            if (-not [string]::IsNullOrWhiteSpace(
                $service.LocalFirewallRule
            ) -and (Test-DeploymentFirewallRule `
                -Name $service.LocalFirewallRule -Action Block `
                -Port $port)) {
                Write-DeploymentLog -Context $Context -Level INFO `
                    -Module SECURITY `
                    -Message 'Security.Validation.ListenerRestricted' `
                    -MessageArguments @(
                        $port,
                        (@($networkListeners.LocalAddress) -join ', ')
                    )
                continue
            }
            Write-DeploymentLog -Context $Context -Level ERROR `
                -Module SECURITY `
                -Message 'Security.Validation.UnsafeListener' `
                -MessageArguments @(
                    $port,
                    (@($networkListeners.LocalAddress) -join ', ')
                )
            return $false
        }
    }
    return $true
}
function Test-DeploymentSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not (Test-LoopbackBindings -Context $Context)) {
        return $false
    }
    $rules = $Context.Config.Security.FirewallRules
    $required = [Collections.Generic.List[object]]::new()
    $unexpected = [Collections.Generic.List[string]]::new()
    $ollamaAllowLan = $Context.Config.Ollama.Enabled -and
        $Context.Config.Security.LanAccess -and
        -not (Test-WinlamaLoopbackHost `
            -HostName $Context.Config.Ollama.Host)
    if ($ollamaAllowLan) {
        [void]$required.Add([pscustomobject]@{
            Name = $rules.OllamaLanAllow
            Action = 'Allow'
            Port = [int]$Context.Config.Ollama.Port
            RemoteAddresses = @(
                $Context.Config.Security.LanRemoteAddresses
            )
        })
        [void]$unexpected.Add($rules.OllamaLocalOnly)
    }
    elseif ($Context.Config.Ollama.Enabled -and
        @(Get-NetworkPortListeners `
        -Port $Context.Config.Ollama.Port).Count -gt 0) {
        [void]$required.Add([pscustomobject]@{
            Name = $rules.OllamaLocalOnly
            Action = 'Block'
            Port = [int]$Context.Config.Ollama.Port
            RemoteAddresses = @()
        })
        [void]$unexpected.Add($rules.OllamaLanAllow)
    }
    else {
        [void]$unexpected.Add($rules.OllamaLanAllow)
        [void]$unexpected.Add($rules.OllamaLocalOnly)
    }
    if ($Context.Config.Security.LanAccess -and
        $Context.Config.OpenWebUI.Enabled) {
        [void]$required.Add([pscustomobject]@{
            Name = $rules.WebUILanAllow
            Action = 'Allow'
            Port = [int]$Context.Config.OpenWebUI.Port
            RemoteAddresses = @(
                $Context.Config.Security.LanRemoteAddresses
            )
        })
        [void]$unexpected.Add($rules.WebUILocalOnly)
    }
    elseif ($Context.Config.OpenWebUI.Enabled -and
        @(Get-NetworkPortListeners `
            -Port $Context.Config.OpenWebUI.Port).Count -gt 0) {
        [void]$required.Add([pscustomobject]@{
            Name = $rules.WebUILocalOnly
            Action = 'Block'
            Port = [int]$Context.Config.OpenWebUI.Port
            RemoteAddresses = @()
        })
        [void]$unexpected.Add($rules.WebUILanAllow)
    }
    else {
        [void]$unexpected.Add($rules.WebUILanAllow)
        [void]$unexpected.Add($rules.WebUILocalOnly)
    }
    foreach ($expectedRule in $required) {
        if (-not (Test-DeploymentFirewallRule `
            -Name $expectedRule.Name -Action $expectedRule.Action `
            -Port $expectedRule.Port `
            -RemoteAddresses $expectedRule.RemoteAddresses)) {
            Write-DeploymentLog -Context $Context -Level ERROR `
                -Module SECURITY `
                -Message 'Security.Validation.FirewallRuleMissing' `
                -MessageArguments @($expectedRule.Name)
            return $false
        }
    }
    foreach ($name in $unexpected) {
        if ($null -ne (Get-WinlamaFirewallRule -Name $name)) {
            Write-DeploymentLog -Context $Context -Level ERROR `
                -Module SECURITY `
                -Message 'Security.Validation.FirewallRuleUnexpected' `
                -MessageArguments @($name)
            return $false
        }
    }
    return $true
}
Export-ModuleMember -Function @(
    'Get-PersistentExecutionPolicy',
    'Set-TransportSecurity', 'Test-TransportSecurity',
    'Get-WinlamaFirewallRules', 'Get-WinlamaFirewallRule',
    'Get-NetworkPortListeners',
    'Test-DeploymentRuntimeBindingRequired',
    'Assert-DeploymentSecurityContracts',
    'Set-DeploymentFirewall',
    'Set-DeploymentSecurity', 'Test-LoopbackBindings',
    'Test-DeploymentSecurity'
)