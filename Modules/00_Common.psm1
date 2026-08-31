Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertFrom-WinlamaJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Json
    )
    $parameters = @{
        InputObject = $Json
    }
    $command = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($command.Parameters.ContainsKey('DateKind')) {
        $parameters.DateKind = 'String'
    }
    return ConvertFrom-Json @parameters
}
function ConvertTo-WindowsCommandLineArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Argument
    )
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = [Text.StringBuilder]::new($Argument.Length + 8)
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            $null = $builder.Append('\' * (($backslashes * 2) + 1))
            $null = $builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) {
        $null = $builder.Append('\' * ($backslashes * 2))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}
function Test-InstallSourceValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )
    return $Value -is [string] -and
        [string]$Value -cin @('Automatic', 'Local', 'Online')
}
function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (Get-LocalizedText -Key 'Common.Error.JsonMissing' `
            -Arguments @($Path))
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return ConvertFrom-WinlamaJson -Json $json
    }
    catch {
        throw (Get-LocalizedText -Key 'Common.Error.JsonUnreadable' `
            -Arguments @($Path)), $_.Exception
    }
}
function ConvertTo-StableJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$Value,
        [ValidateRange(1, 100)]
        [int]$Depth = 20
    )
    process {
        $json = $Value | ConvertTo-Json -Depth $Depth -Compress
        if ([string]::IsNullOrEmpty($json)) {
            return $json
        }
        $builder = [Text.StringBuilder]::new($json.Length + 128)
        $indent = 0
        $inString = $false
        $escaped = $false
        for ($index = 0; $index -lt $json.Length; $index++) {
            $character = $json[$index]
            if ($inString) {
                $null = $builder.Append($character)
                if ($escaped) {
                    $escaped = $false
                }
                elseif ($character -eq '\') {
                    $escaped = $true
                }
                elseif ($character -eq '"') {
                    $inString = $false
                }
                continue
            }
            if ($character -eq '"') {
                $inString = $true
                $null = $builder.Append($character)
                continue
            }
            if ($character -in @('{', '[')) {
                $null = $builder.Append($character)
                $closing = if ($character -eq '{') { '}' } else { ']' }
                if ($index + 1 -lt $json.Length -and
                    $json[$index + 1] -ne $closing) {
                    $indent++
                    $null = $builder.Append("`r`n")
                    $null = $builder.Append('  ' * $indent)
                }
                continue
            }
            if ($character -in @('}', ']')) {
                $opening = if ($character -eq '}') { '{' } else { '[' }
                if ($index -gt 0 -and $json[$index - 1] -ne $opening) {
                    $indent--
                    $null = $builder.Append("`r`n")
                    $null = $builder.Append('  ' * $indent)
                }
                $null = $builder.Append($character)
                continue
            }
            if ($character -eq ',') {
                $null = $builder.Append($character)
                $null = $builder.Append("`r`n")
                $null = $builder.Append('  ' * $indent)
                continue
            }
            if ($character -eq ':') {
                $null = $builder.Append(': ')
                continue
            }
            $null = $builder.Append($character)
        }
        return $builder.ToString()
    }
}
function New-NonRetryableException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['Winlama.Retryable'] = $false
    return $exception
}
function Test-DeploymentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )
    $required = @(
        'ProjectName', 'EngineVersion', 'MinimumPowerShellVersion',
        'Localization', 'Bootstrap',
        'Installation', 'Paths',
        'Dependencies', 'Network', 'Ollama',
        'OpenWebUI', 'ComfyUI', 'Voice', 'Startup', 'Runtime', 'Models',
        'ModelTransfer', 'Hardware',
        'Uninstall', 'Security'
    )
    foreach ($name in $required) {
        if ($null -eq $Config.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @($name))
        }
    }
    foreach ($component in @(
        'Ollama', 'OpenWebUI', 'Voice', 'ComfyUI'
    )) {
        $section = $Config.PSObject.Properties[$component].Value
        if ($null -eq $section -or
            $null -eq $section.PSObject.Properties['Enabled'] -or
            $section.Enabled -isnot [bool]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @("$component.Enabled"))
        }
    }
    if ([string]::IsNullOrWhiteSpace($Config.ProjectName)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ProjectNameMissing')
    }
    if ([string]::IsNullOrWhiteSpace($Config.Localization.Directory)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.LocalizationDirectoryMissing')
    }
    if ([string]::IsNullOrWhiteSpace($Config.Localization.Language)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.LocalizationLanguageMissing')
    }
    $persistentRoot = [Environment]::ExpandEnvironmentVariables(
        $Config.Paths.Root
    )
    if (-not [IO.Path]::IsPathRooted($persistentRoot)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.PersistentRootRequired')
    }
    $powerShellPackage = $Config.Bootstrap.PowerShell
    foreach ($name in @(
        'InstallSource', 'Version', 'WingetId', 'WingetVersion', 'Uri',
        'OfflinePath', 'OfflineSha256', 'Sha256', 'Publisher'
    )) {
        if ($null -eq $powerShellPackage.PSObject.Properties[$name] -or
            [string]::IsNullOrWhiteSpace(
                [string]$powerShellPackage.$name
            )) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Bootstrap.PowerShell.$name"))
        }
    }
    $powerShellUri = $null
    if ([string]$powerShellPackage.WingetId -cne
            'Microsoft.PowerShell' -or
        [version]$powerShellPackage.WingetVersion -lt
            [version]$powerShellPackage.Version -or
        -not [uri]::TryCreate(
            [string]$powerShellPackage.Uri,
            [UriKind]::Absolute,
            [ref]$powerShellUri
        ) -or $powerShellUri.Scheme -ne 'https' -or
        $powerShellUri.Host -ine 'github.com' -or
        $powerShellUri.AbsolutePath -notlike
            '/PowerShell/PowerShell/releases/download/*' -or
        [IO.Path]::IsPathRooted(
            [string]$powerShellPackage.OfflinePath
        ) -or [string]$powerShellPackage.OfflinePath -match
            '(^|[\\/])\.\.([\\/]|$)' -or
        [string]$powerShellPackage.Sha256 -notmatch
            '^[a-fA-F0-9]{64}$' -or
        [string]$powerShellPackage.OfflineSha256 -notmatch
            '^[a-fA-F0-9]{64}$') {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Bootstrap.PowerShell'))
    }
    if (-not (Test-InstallSourceValue `
        -Value $powerShellPackage.InstallSource)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Bootstrap.PowerShell.InstallSource'))
    }
    $dependencySources = [ordered]@{
        'Visual C++ Runtime' =
            'https://download.visualstudio.microsoft.com/'
        Python = 'https://www.python.org/'
        Ollama = 'https://github.com/ollama/ollama/'
    }
    foreach ($dependency in @($Config.Dependencies)) {
        foreach ($name in @(
            'Name', 'InstallSource', 'WingetId', 'WingetVersion',
            'MinimumVersion',
            'Uri', 'OfflinePath', 'Sha256', 'InstallerArguments'
        )) {
            if ($null -eq $dependency.PSObject.Properties[$name]) {
                throw (Get-LocalizedText `
                    -Key 'Common.Error.ConfigFieldMissing' `
                    -Arguments @("Dependencies.$($dependency.Name).$name"))
            }
        }
        $dependencyUri = $null
        $name = [string]$dependency.Name
        if (-not (Test-InstallSourceValue `
                -Value $dependency.InstallSource) -or
            -not $dependencySources.Contains($name) -or
            [string]::IsNullOrWhiteSpace(
                [string]$dependency.WingetVersion
            ) -or [version]$dependency.WingetVersion -lt
                [version]$dependency.MinimumVersion -or
            -not [uri]::TryCreate(
                [string]$dependency.Uri,
                [UriKind]::Absolute,
                [ref]$dependencyUri
            ) -or $dependencyUri.Scheme -ne 'https' -or
            -not ([string]$dependency.Uri).StartsWith(
                $dependencySources[$name],
                [StringComparison]::OrdinalIgnoreCase
            ) -or [IO.Path]::IsPathRooted(
                [string]$dependency.OfflinePath
            ) -or [string]$dependency.OfflinePath -match
                '(^|[\\/])\.\.([\\/]|$)' -or
            [string]$dependency.Sha256 -notmatch
                '^[a-fA-F0-9]{64}$' -or
            @($dependency.InstallerArguments).Count -eq 0) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @("Dependencies.$name"))
        }
    }
    if ($Config.Security.LanAccess) {
        if (@($Config.Security.LanRemoteAddresses).Count -eq 0) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.LanRangeRequired')
        }
        if ($Config.OpenWebUI.Enabled -and
            $Config.OpenWebUI.Host -in @(
                '127.0.0.1', 'localhost', '::1'
            )) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.WebUILanBindingRequired')
        }
    }
    elseif ($Config.Ollama.Host -notin @('127.0.0.1', 'localhost')) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.OllamaLoopbackRequired')
    }
    if ([string]::IsNullOrWhiteSpace($Config.Ollama.InstallPath)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('Ollama.InstallPath'))
    }
    if ($null -eq $Config.Ollama.PSObject.Properties['ApiHost'] -or
        $Config.Ollama.ApiHost -notin @(
            '127.0.0.1', 'localhost', '::1'
        )) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.OllamaApiLoopbackRequired')
    }
    if (-not $Config.Security.LanAccess -and
        $Config.OpenWebUI.Host -notin @('127.0.0.1', 'localhost')) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.WebUILoopbackRequired')
    }
    if ($null -eq $Config.OpenWebUI.PSObject.Properties[
        'HealthHost'
    ] -or $Config.OpenWebUI.HealthHost -notin @(
        '127.0.0.1', 'localhost', '::1'
    )) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.WebUIHealthLoopbackRequired')
    }
    if ($null -eq $Config.OpenWebUI.PSObject.Properties[
        'FallbackPorts'
    ]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('OpenWebUI.FallbackPorts'))
    }
    if ($null -eq $Config.OpenWebUI.PSObject.Properties[
        'Environment'
    ]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('OpenWebUI.Environment'))
    }
    if ($null -eq $Config.OpenWebUI.PSObject.Properties[
        'DefaultConfig'
    ] -or [string]::IsNullOrWhiteSpace(
        $Config.OpenWebUI.DefaultConfig.Path
    ) -or $null -eq $Config.OpenWebUI.DefaultConfig.PSObject.Properties[
        'ApplyOnFirstStart'
    ]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('OpenWebUI.DefaultConfig'))
    }
    $defaultConfigPath = [string]$Config.OpenWebUI.DefaultConfig.Path
    if ([IO.Path]::IsPathRooted($defaultConfigPath) -or
        $defaultConfigPath.Contains('..')) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.DefaultConfigPathInvalid')
    }
    if ($Config.OpenWebUI.DefaultConfig.ApplyOnFirstStart `
        -isnot [bool]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @(
                'OpenWebUI.DefaultConfig.ApplyOnFirstStart'
            ))
    }
    foreach ($name in @(
        'OllamaStartupTimeoutSeconds', 'PollIntervalSeconds',
        'ProgressLogIntervalSeconds', 'ShutdownTimeoutSeconds'
    )) {
        if ($null -eq $Config.Runtime.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Runtime.$name"))
        }
        if ([int]$Config.Runtime.$name -lt 1) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.RuntimeTimeoutInvalid' `
                -Arguments @($name))
        }
    }
    if ($null -eq $Config.Runtime.PSObject.Properties[
        'ProcessPriority'
    ] -or $Config.Runtime.ProcessPriority -notin @(
        'Normal', 'AboveNormal', 'High'
    )) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ProcessPriorityInvalid')
    }
    foreach ($name in @(
        'StartupInitialDelaySeconds',
        'StartupAfterOllamaDelaySeconds',
        'StartupCompletionDelaySeconds'
    )) {
        if ($null -eq $Config.Runtime.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Runtime.$name"))
        }
        if ([int]$Config.Runtime.$name -lt 0) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.RuntimeDelayInvalid' `
                -Arguments @($name))
        }
    }
    foreach ($name in @(
        'EnvironmentVariables', 'ResumeTaskName',
        'GeneratedDirectories'
    )) {
        if ($null -eq $Config.Uninstall.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Uninstall.$name"))
        }
    }
    if ($null -eq $Config.Security.PSObject.Properties[
        'FirewallRules'
    ]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('Security.FirewallRules'))
    }
    foreach ($name in @(
        'OllamaLanAllow', 'WebUILanAllow',
        'OllamaLocalOnly', 'WebUILocalOnly'
    )) {
        if ($null -eq $Config.Security.FirewallRules.
            PSObject.Properties[$name] -or
            [string]::IsNullOrWhiteSpace(
                $Config.Security.FirewallRules.$name
            )) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Security.FirewallRules.$name"))
        }
    }
    if ($null -eq $Config.Security.PSObject.Properties[
        'AllowAuthenticodeOnlyForLocalInstallers'
    ]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @(
                'Security.AllowAuthenticodeOnlyForLocalInstallers'
            ))
    }
    if ($Config.Security.AllowAuthenticodeOnlyForLocalInstallers `
        -isnot [bool]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @(
                'Security.AllowAuthenticodeOnlyForLocalInstallers'
            ))
    }
    $officialModelPrefixesProperty = $Config.Security.
        PSObject.Properties['OfficialModelUriPrefixes']
    if ($null -eq $officialModelPrefixesProperty -or
        @($officialModelPrefixesProperty.Value).Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('Security.OfficialModelUriPrefixes'))
    }
    $officialModelPrefixes = @(
        $officialModelPrefixesProperty.Value | ForEach-Object {
            [string]$_
        }
    )
    foreach ($prefix in $officialModelPrefixes) {
        $prefixUri = $null
        if (-not [uri]::TryCreate(
            $prefix,
            [UriKind]::Absolute,
            [ref]$prefixUri
        ) -or $prefixUri.Scheme -ne 'https' -or
            -not $prefix.EndsWith('/')) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @(
                    'Security.OfficialModelUriPrefixes'
                ))
        }
    }
    $ollamaDependency = $Config.Dependencies |
        Where-Object Name -eq 'Ollama' |
        Select-Object -First 1
    if ($null -eq $ollamaDependency) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('Dependencies.Ollama'))
    }
    foreach ($name in @(
        'InstallSource', 'OfflinePath', 'OfflineSha256',
        'PublisherSubjectContains'
    )) {
        if ($null -eq $ollamaDependency.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Dependencies.Ollama.$name"))
        }
    }
    if (-not (Test-InstallSourceValue `
        -Value $ollamaDependency.InstallSource)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.OllamaInstallSourceInvalid')
    }
    if ([string]::IsNullOrWhiteSpace(
        $ollamaDependency.OfflinePath
    ) -or [string]::IsNullOrWhiteSpace(
        $ollamaDependency.PublisherSubjectContains
    )) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @('Dependencies.Ollama.LocalInstaller'))
    }
    $localInstallerPath = [string]$ollamaDependency.OfflinePath
    if ([IO.Path]::IsPathRooted($localInstallerPath)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Dependencies.Ollama.OfflinePath'))
    }
    if ([version]$Config.OpenWebUI.Version -lt [version]'0.11.0') {
        throw (Get-LocalizedText `
            -Key 'Common.Error.WebUIVersionUnsupported')
    }
    if ([string]::IsNullOrWhiteSpace($Config.OpenWebUI.RootPath)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.WebUIRootMissing')
    }
    foreach ($name in @(
        'Enabled', 'Host', 'Port', 'Language', 'Model', 'Revision',
        'StartupTimeoutSeconds'
    )) {
        if ($null -eq $Config.Voice.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Voice.$name"))
        }
    }
    $voiceProfiles = @{
        tr = @(
            'facebook/mms-tts-tur',
            '7e364479c307f06733ca865b0a5269e0209cf82d'
        )
        en = @(
            'facebook/mms-tts-eng',
            'c71de0fe7204c83f1c10820a7d696d0b450048ba'
        )
    }
    $voiceLanguage = [string]$Config.Voice.Language
    $voiceProfile = $voiceProfiles[$voiceLanguage]
    if ($Config.Voice.Host -notin @(
        '127.0.0.1', 'localhost', '::1'
    ) -or $null -eq $voiceProfile -or
        [string]$Config.Voice.Model -cne $voiceProfile[0] -or
        [string]$Config.Voice.Revision -cne $voiceProfile[1] -or
        [int]$Config.Voice.StartupTimeoutSeconds -lt 1) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Voice'))
    }
    foreach ($name in @('Enabled', 'ShortcutPath', 'Script')) {
        if ($null -eq $Config.Startup.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Startup.$name"))
        }
    }
    if ([string]::IsNullOrWhiteSpace($Config.Startup.ShortcutPath) -or
        [string]::IsNullOrWhiteSpace($Config.Startup.Script) -or
        [IO.Path]::IsPathRooted([string]$Config.Startup.Script) -or
        [string]$Config.Startup.Script -match '(^|[\\/])\.\.([\\/]|$)') {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Startup'))
    }
    if (@($Config.Models.Catalog).Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ModelCatalogEmpty')
    }
    foreach ($name in @(
        'Enabled', 'InstallSource', 'Host', 'Port', 'InstallPath',
        'ModelsPath',
        'PortableVersion', 'PortableAssetName', 'PortableUri',
        'PortableSha256', 'PortableSizeBytes',
        'BaseRequirements', 'BaseRequirementsSha256',
        'OutputPath', 'InputPath', 'TempPath',
        'CleanupTemporaryMediaOnStart', 'LaunchArguments', 'CustomNodes',
        'Requested', 'Catalog'
    )) {
        if ($null -eq $Config.ComfyUI.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("ComfyUI.$name"))
        }
    }
    if ($Config.ComfyUI.Host -notin @(
        '127.0.0.1', 'localhost', '::1'
    )) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.Host'))
    }
    if (-not (Test-InstallSourceValue `
        -Value $Config.ComfyUI.InstallSource)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.InstallSource'))
    }
    $portableUri = $null
    $portableAssetName = [string]$Config.ComfyUI.PortableAssetName
    if (-not [uri]::TryCreate(
        [string]$Config.ComfyUI.PortableUri,
        [UriKind]::Absolute,
        [ref]$portableUri
    ) -or $portableUri.Scheme -ne 'https' -or
        $portableUri.Host -ine 'github.com' -or
        $portableUri.AbsolutePath -notlike `
            '/Comfy-Org/ComfyUI/releases/download/*' -or
        [string]$Config.ComfyUI.PortableVersion -notmatch `
            '^\d+\.\d+\.\d+$' -or
        [string]$Config.ComfyUI.PortableSha256 -notmatch `
            '^[a-fA-F0-9]{64}$' -or
        [long]$Config.ComfyUI.PortableSizeBytes -lt 1 -or
        [string]::IsNullOrWhiteSpace($portableAssetName) -or
        [IO.Path]::GetFileName($portableAssetName) -cne
            $portableAssetName -or
        [IO.Path]::GetExtension($portableAssetName) -cne '.7z' -or
        [IO.Path]::GetFileName($portableUri.AbsolutePath) -cne
            $portableAssetName) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.PortablePackage'))
    }
    if (@($Config.ComfyUI.Catalog).Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.Catalog'))
    }
    $baseRequirements = @($Config.ComfyUI.BaseRequirements |
        ForEach-Object { [string]$_ })
    if ($baseRequirements.Count -lt 1 -or
        [string]$Config.ComfyUI.BaseRequirementsSha256 -notmatch
            '^[a-fA-F0-9]{64}$' -or
        @($baseRequirements | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or
            $_ -match '(?i)[a-z][a-z0-9+.-]*:' -or
            $_ -match '(?i)(git|hg|svn|bzr)\+' -or
            $_.StartsWith('-') -or $_ -match '\s@\s' -or
            $_ -match '[\\/]'
        }).Count -gt 0) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.BaseRequirements'))
    }
    $baseRequirementsContent = ($baseRequirements -join "`n") + "`n"
    $baseRequirementsAlgorithm = `
        [Security.Cryptography.SHA256]::Create()
    try {
        $baseRequirementsHash = [BitConverter]::ToString(
            $baseRequirementsAlgorithm.ComputeHash(
                [Text.UTF8Encoding]::new($false).GetBytes(
                    $baseRequirementsContent
                )
            )
        ).Replace('-', '')
    }
    finally {
        $baseRequirementsAlgorithm.Dispose()
    }
    if ($baseRequirementsHash -ine
        [string]$Config.ComfyUI.BaseRequirementsSha256) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.BaseRequirementsSha256'))
    }
    $customNodeSources = [ordered]@{
        'ComfyUI-WanVideoWrapper' =
            'https://github.com/kijai/ComfyUI-WanVideoWrapper'
        'ComfyUI-VideoHelperSuite' =
            'https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite'
    }
    $customNodeNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($customNode in @($Config.ComfyUI.CustomNodes)) {
        $name = [string]$customNode.Name
        $repository = [string]$customNode.Repository
        $commit = [string]$customNode.Commit
        $archive = [string]$customNode.ArchiveUri
        $offline = [string]$customNode.OfflinePath
        $expectedOffline = "Runtime\ComfyUICustomNodes\$name"
        $archiveUri = $null
        if (-not $customNodeNames.Add($name) -or
            -not $customNodeSources.Contains($name) -or
            $repository -cne $customNodeSources[$name] -or
            $commit -notmatch '^[a-f0-9]{40}$' -or
            -not [uri]::TryCreate(
                $archive,
                [UriKind]::Absolute,
                [ref]$archiveUri
            ) -or $archiveUri.Scheme -ne 'https' -or
            $archiveUri.Host -ine 'github.com' -or
            $archive -cne "$repository/archive/$commit.zip" -or
            $offline -cne $expectedOffline -or
            [string]$customNode.TreeSha256 -notmatch
                '^[a-fA-F0-9]{64}$' -or
            @($customNode.RequiredFiles).Count -eq 0 -or
            [string]::IsNullOrWhiteSpace(
                [string]$customNode.RequiredBy
            )) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @("ComfyUI.CustomNodes.$name"))
        }
        foreach ($relativePath in @($customNode.RequiredFiles)) {
            if ([IO.Path]::IsPathRooted([string]$relativePath) -or
                [string]$relativePath -match
                    '(^|[\\/])\.\.([\\/]|$)') {
                throw (Get-LocalizedText `
                    -Key 'Common.Error.ConfigFieldInvalid' `
                    -Arguments @("ComfyUI.CustomNodes.$name"))
            }
        }
    }
    if ($customNodeNames.Count -ne $customNodeSources.Count) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('ComfyUI.CustomNodes'))
    }
    $comfyModelNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($model in @($Config.ComfyUI.Catalog)) {
        $localOnlyProperty = $model.PSObject.Properties['LocalOnly']
        $localOnly = $null -ne $localOnlyProperty -and
            [bool]$localOnlyProperty.Value
        $directoryProperty = $model.PSObject.Properties['LocalDirectory']
        $localDirectory = if ($null -ne $directoryProperty) {
            [string]$directoryProperty.Value
        }
        else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($model.Name) -or
            -not $comfyModelNames.Add([string]$model.Name) -or
            (@($model.Assets).Count -eq 0 -and -not $localOnly) -or
            (-not [string]::IsNullOrWhiteSpace($localDirectory) -and (
                [IO.Path]::IsPathRooted($localDirectory) -or
                $localDirectory -match '(^|[\\/])\.\.?([\\/]|$)' -or
                $localDirectory -match '[\\/]$'
            ))) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @('ComfyUI.Catalog'))
        }
        foreach ($asset in @($model.Assets)) {
            $relativePath = [string]$asset.RelativePath
            $assetUri = [string]$asset.Uri
            $uri = $null
            if ([IO.Path]::IsPathRooted($relativePath) -or
                $relativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
                -not [uri]::TryCreate(
                    $assetUri,
                    [UriKind]::Absolute,
                    [ref]$uri
                ) -or $uri.Scheme -ne 'https' -or
                $null -eq ($officialModelPrefixes |
                    Where-Object {
                        $assetUri.StartsWith(
                            $_,
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    } | Select-Object -First 1) -or
                [string]$asset.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
                [double]$asset.SizeGB -le 0) {
                throw (Get-LocalizedText `
                    -Key 'Common.Error.ConfigFieldInvalid' `
                    -Arguments @(
                        "ComfyUI.Catalog.$($model.Name)"
                    ))
            }
        }
    }
    foreach ($name in @($Config.ComfyUI.Requested)) {
        if ([string]::IsNullOrWhiteSpace($name) -or
            -not $comfyModelNames.Contains([string]$name)) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldInvalid' `
                -Arguments @('ComfyUI.Requested'))
        }
    }
    foreach ($name in @('InstallSource', 'LocalPackageImport')) {
        if ($null -ne $Config.Models.PSObject.Properties[$name]) {
            continue
        }
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldMissing' `
            -Arguments @("Models.$name"))
    }
    if (-not (Test-InstallSourceValue `
        -Value $Config.Models.InstallSource)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Models.InstallSource'))
    }
    foreach ($name in @(
        'PromptWhenAvailable',
        'UseLocalWhenNonInteractive',
        'SelectedPackages'
    )) {
        if ($null -eq $Config.Models.LocalPackageImport.
            PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.LocalPackageImportFieldMissing' `
                -Arguments @($name))
        }
    }
    foreach ($name in @(
        'PowerShellPath',
        'ContinueOnOptionalError',
        'VerifyLocalPayloadHashes'
    )) {
        if ($null -eq $Config.Installation.PSObject.Properties[$name]) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ConfigFieldMissing' `
                -Arguments @("Installation.$name"))
        }
    }
    if ($Config.Installation.ContinueOnOptionalError -isnot [bool]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Installation.ContinueOnOptionalError'))
    }
    if ($Config.Installation.VerifyLocalPayloadHashes -isnot [bool]) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.ConfigFieldInvalid' `
            -Arguments @('Installation.VerifyLocalPayloadHashes'))
    }
    if ($Config.ModelTransfer.PackageFormatVersion -ne 1) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PackageFormatUnsupported')
    }
    if ([version]$Config.ModelTransfer.MinimumPowerShellVersion `
        -lt [version]'5.1') {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PowerShellVersionInvalid')
    }
    if (@($Config.ModelTransfer.NativeModelSearchDirectories).Count `
        -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.NativeSearchDirectoryMissing')
    }
    if ($Config.ModelTransfer.BufferSizeMB -lt 1 -or
        $Config.ModelTransfer.BufferSizeMB -gt 64) {
        throw (Get-LocalizedText -Key 'Manager.Error.BufferInvalid')
    }
    if ([string]::IsNullOrWhiteSpace(
        $Config.ModelTransfer.ExportDirectory
    )) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.ExportDirectoryMissing')
    }
    if (@($Config.ModelTransfer.ImportSearchDirectories).Count -eq 0) {
        throw (Get-LocalizedText `
            -Key 'Manager.Error.PackageSearchDirectoryMissing')
    }
    $requiredContexts = @(4, 8, 16, 32, 64, 128, 256)
    foreach ($context in $requiredContexts) {
        if ($context -notin @($Config.Models.ContextSizesK)) {
            throw (Get-LocalizedText `
                -Key 'Common.Error.ContextSizeMissing' `
                -Arguments @($context))
        }
    }
    $allPorts = @(
        $Config.Ollama.Port,
        $Config.OpenWebUI.Port,
        $Config.ComfyUI.Port,
        $Config.Voice.Port
    ) + @($Config.OpenWebUI.FallbackPorts)
    foreach ($port in $allPorts) {
        if ($port -lt 1 -or $port -gt 65535) {
            throw (Get-LocalizedText -Key 'Common.Error.TcpPortInvalid' `
                -Arguments @($port))
        }
    }
    $ollamaPorts = @($Config.Ollama.Port)
    $webUIPorts = @($Config.OpenWebUI.Port) +
        @($Config.OpenWebUI.FallbackPorts)
    if (@($ollamaPorts | Where-Object { $_ -in $webUIPorts }).Count `
        -gt 0) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.RuntimePortsOverlap')
    }
    if ($Config.ComfyUI.Port -in @(
        $Config.Ollama.Port,
        $Config.OpenWebUI.Port,
        $Config.Voice.Port
    ) -or $Config.ComfyUI.Port -in
        @($Config.OpenWebUI.FallbackPorts)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.RuntimePortsOverlap')
    }
    if ($Config.Voice.Port -in @(
        $Config.Ollama.Port,
        $Config.OpenWebUI.Port
    ) -or $Config.Voice.Port -in
        @($Config.OpenWebUI.FallbackPorts)) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.RuntimePortsOverlap')
    }
    [void][version]$Config.EngineVersion
    [void][version]$Config.MinimumPowerShellVersion
    return $true
}
function Resolve-ConfigurationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$BasePath
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) {
        return [IO.Path]::GetFullPath($expanded)
    }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $expanded))
}
function Get-WinlamaTimestampedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]
        [ValidatePattern('^\.[a-zA-Z0-9]+$')]
        [string]$Extension,
        [ValidatePattern('^[a-zA-Z0-9-]*$')]
        [string]$Prefix = ''
    )
    $resolvedDirectory = [IO.Path]::GetFullPath($Directory)
    $baseName = [DateTimeOffset]::Now.ToString(
        'yyyy-MM-dd_HH-mm-ss'
    )
    for ($index = 0; $index -lt 10000; $index++) {
        $suffix = if ($index -eq 0) { '' } else { "_$index" }
        $path = Join-Path $resolvedDirectory `
            ($Prefix + $baseName + $suffix + `
                $Extension.ToLowerInvariant())
        if (-not (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    throw (Get-LocalizedText -Key 'Common.Error.UniquePathUnavailable' `
        -Arguments @($resolvedDirectory))
}
function New-WinlamaTimestampedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]
        [ValidatePattern('^\.[a-zA-Z0-9]+$')]
        [string]$Extension,
        [ValidatePattern('^[a-zA-Z0-9-]*$')]
        [string]$Prefix = ''
    )
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    for ($attempt = 0; $attempt -lt 10000; $attempt++) {
        $path = Get-WinlamaTimestampedPath `
            -Directory $Directory -Extension $Extension `
            -Prefix $Prefix
        try {
            $stream = [IO.File]::Open(
                $path,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )
            $stream.Dispose()
            return $path
        }
        catch [IO.IOException] {
            continue
        }
    }
    throw (Get-LocalizedText -Key 'Common.Error.UniquePathUnavailable' `
        -Arguments @($Directory))
}
function Resolve-WinlamaIndexSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidateRange(1, 100000)]
        [int]$Count,
        [switch]$AllowAll
    )
    $selection = $Value.Trim()
    if ($AllowAll -and $selection -iin @('A', 'ALL', 'HEPSI')) {
        return @(1..$Count)
    }
    $exclude = $selection.StartsWith('-')
    if ($exclude) {
        $selection = $selection.Substring(1).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($selection)) {
        throw (Get-LocalizedText -Key 'Common.Selection.Invalid')
    }
    $selected = [Collections.Generic.HashSet[int]]::new()
    foreach ($token in @($selection -split '[,.;\s]+')) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        $number = 0
        if (-not [int]::TryParse($token, [ref]$number) -or
            $number -lt 1 -or $number -gt $Count) {
            throw (Get-LocalizedText -Key 'Common.Selection.Invalid')
        }
        $null = $selected.Add($number)
    }
    if ($selected.Count -eq 0) {
        throw (Get-LocalizedText -Key 'Common.Selection.Invalid')
    }
    if ($exclude) {
        return @(1..$Count | Where-Object {
            -not $selected.Contains($_)
        })
    }
    return @($selected | Sort-Object)
}
function New-DeploymentContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$PackageRoot
    )
    $package = [IO.Path]::GetFullPath($PackageRoot)
    $root = Resolve-ConfigurationPath -Path $Config.Paths.Root `
        -BasePath $package
    $app = Resolve-ConfigurationPath -Path $Config.Paths.App `
        -BasePath $root
    $data = Resolve-ConfigurationPath -Path $Config.Paths.Data `
        -BasePath $root
    $logs = Resolve-ConfigurationPath -Path $Config.Paths.Logs `
        -BasePath $root
    $models = Resolve-ConfigurationPath -Path $Config.Paths.Models `
        -BasePath $root
    $reports = Resolve-ConfigurationPath -Path $Config.Paths.Reports `
        -BasePath $root
    $temp = Resolve-ConfigurationPath -Path $Config.Paths.Temp `
        -BasePath $root
    $sessionProperty = $Config.Installation.PSObject.Properties[
        'SessionId'
    ]
    $sessionId = if ($null -ne $sessionProperty) {
        [string]$sessionProperty.Value
    }
    else {
        ''
    }
    return [pscustomobject]@{
        Config = $Config
        SessionId = $sessionId
        PackageRoot = $package
        RootPath = $root
        AppPath = $app
        DataPath = $data
        LogsPath = $logs
        ModelsPath = $models
        ReportsPath = $reports
        TempPath = $temp
        StatePath = Resolve-ConfigurationPath -Path $Config.Paths.State `
            -BasePath $root
        LockPath = Resolve-ConfigurationPath `
            -Path $Config.Paths.EngineLock -BasePath $root
        CheckpointsPath = Join-Path $data 'Checkpoints'
        LogPath = New-WinlamaTimestampedFile `
            -Directory $logs -Extension '.log'
        DashboardPath = Get-WinlamaTimestampedPath `
            -Directory $reports -Extension '.html' -Prefix 'report-'
        HealthPath = Join-Path $data 'health.json'
        HardwarePath = Join-Path $data 'hardware.json'
        ModelPlanPath = Join-Path $data 'model-plan.json'
        ValidationPath = Join-Path $data 'validation.json'
        CurrentStage = 'INITIALIZE'
        MachineId = Get-StableMachineId
    }
}
function Get-StableMachineId {
    [CmdletBinding()]
    param()
    $path = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
    $machineGuid = (Get-ItemProperty -LiteralPath $path `
        -Name MachineGuid).MachineGuid
    $material = [string]$machineGuid
    $bytes = [Text.Encoding]::UTF8.GetBytes($material)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return [BitConverter]::ToString($hash).
        Replace('-', '').Substring(0, 32)
}
function Initialize-DeploymentDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $paths = @(
        $Context.RootPath,
        $Context.AppPath, $Context.DataPath,
        $Context.LogsPath, $Context.ModelsPath,
        $Context.TempPath, $Context.CheckpointsPath
    )
    foreach ($path in $paths) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
}
function Write-AtomicTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory `
        ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)),
            [guid]::NewGuid().ToString('N'))
    $encoding = [Text.UTF8Encoding]::new($false)
    $stream = [IO.File]::Open(
        $temporaryPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $writer = [IO.StreamWriter]::new($stream, $encoding)
        try {
            $writer.Write($Content)
            $writer.Flush()
            $stream.Flush($true)
        }
        finally {
            $writer.Dispose()
        }
    }
    catch {
        $stream.Dispose()
        Remove-Item -LiteralPath $temporaryPath -Force `
            -ErrorAction SilentlyContinue
        throw
    }
    try {
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force `
            -ErrorAction SilentlyContinue
    }
}
function Add-WinlamaUtf8Line {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Append,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read
    )
    try {
        $writer = [IO.StreamWriter]::new(
            $stream,
            [Text.UTF8Encoding]::new($false)
        )
        try {
            $writer.WriteLine($Value)
            $writer.Flush()
            $stream.Flush($true)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}
function Test-ApplicationManagedRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return -not [string]::IsNullOrWhiteSpace($Path) -and
        -not [IO.Path]::IsPathRooted($Path) -and
        $Path -notmatch ':' -and
        $Path -notmatch '(^|[\\/])\.\.?([\\/]|$)' -and
        $Path -notmatch '[\\/]$'
}
function Get-ApplicationOperationalPayloadFiles {
    [CmdletBinding()]
    param()
    return @(
        'Install.ps1', 'Engine.ps1', 'ModelManager.ps1',
        'Uninstall.ps1', 'Launcher.ps1', 'RunMe.bat',
        'Start.ps1', 'Repair.ps1',
        'Data\Configs\config.json',
        'Data\Configs\openui-config.json',
        'Data\Workflows\Flux1_Schnell_API.json',
        'Data\Workflows\Wan2.1_T2V_Workflow.json',
        'Modules\00_Common.psm1',
        'Modules\01_Logging.psm1',
        'Modules\02_State.psm1',
        'Modules\03_Process.psm1',
        'Modules\04_Environment.psm1',
        'Modules\05_Dependencies.psm1',
        'Modules\06_Hardware.psm1',
        'Modules\07_Ollama.psm1',
        'Modules\08_Models.psm1',
        'Modules\09_WebUI.psm1',
        'Modules\10_Runtime.psm1',
        'Modules\11_Security.psm1',
        'Modules\12_Validation.psm1',
        'Modules\13_Reporting.psm1',
        'Modules\ComfyUI\DefaultWorkflow\__init__.py',
        'Modules\ComfyUI\DefaultWorkflow\LICENSE',
        ('Modules\ComfyUI\DefaultWorkflow\web\' +
            'default_workflow.js'),
        'Modules\Dashboard\template.html',
        'Modules\Localization\LocalizationManager.psm1',
        'Modules\UI\ComfyUI.ps1',
        'Modules\UI\ConsoleUI.psm1',
        'Modules\UI\OpenWebUI.ps1',
        'Services\TtsServer.py', 'String\tr.ini'
    )
}
function Test-ApplicationPayloadReparseChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $current = [IO.Path]::GetFullPath($Path)
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force `
            -ErrorAction Stop
        if (($item.Attributes -band `
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        if ($current.TrimEnd('\').Equals(
            $rootPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            return $false
        }
        $current = $parent.FullName
    }
}
function Assert-ApplicationSourcePayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot)
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw [IO.DirectoryNotFoundException]::new(
            "Payload koku bulunamadi: $root"
        )
    }
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    $required = @(Get-ApplicationOperationalPayloadFiles)
    if ($required.Count -ne 36) {
        throw [IO.InvalidDataException]::new(
            'Operasyonel payload dosya sayisi 36 olmali.'
        )
    }
    foreach ($relativePath in $required) {
        if (-not (Test-ApplicationManagedRelativePath `
            -Path $relativePath)) {
            throw [IO.InvalidDataException]::new(
                "Gecersiz payload yolu: $relativePath"
            )
        }
        $path = [IO.Path]::GetFullPath(
            (Join-Path $root $relativePath)
        )
        if (-not $path.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            -not (Test-ApplicationPayloadReparseChain `
                -Root $root -Path $path)) {
            throw [IO.InvalidDataException]::new(
                "Eksik veya guvensiz payload dosyasi: $relativePath"
            )
        }
    }
    return $required
}
function Get-ApplicationManagedFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot)
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $files = [Collections.Generic.List[string]]::new()
    foreach ($relativePath in @(
        Assert-ApplicationSourcePayload -SourceRoot $root
    )) {
        if ($relativePath -ieq 'Data\Configs\config.json') {
            continue
        }
        $files.Add($relativePath)
    }
    foreach ($relativePath in @('README.md', 'LICENSE')) {
        $path = Join-Path $root $relativePath
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and
            (Test-ApplicationPayloadReparseChain `
                -Root $root -Path $path)) {
            $files.Add($relativePath)
        }
    }
    return @($files | Sort-Object -Unique)
}
function Get-ApplicationManagedManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetRoot)
    return Join-Path $TargetRoot `
        'Data\Configs\managed-payload.json'
}
function Get-ApplicationManagedRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string[]]$RelativePaths
    )
    $records = [Collections.Generic.List[object]]::new()
    foreach ($relativePath in $RelativePaths) {
        if (-not (Test-ApplicationManagedRelativePath `
            -Path $relativePath)) {
            throw [IO.InvalidDataException]::new(
                "Gecersiz yonetilen dosya yolu: $relativePath"
            )
        }
        $sourcePath = Join-Path $SourceRoot $relativePath
        $item = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        $records.Add([pscustomobject][ordered]@{
            Path = $relativePath
            Length = [long]$item.Length
            Sha256 = (Get-FileHash -LiteralPath $sourcePath `
                -Algorithm SHA256).Hash
        })
    }
    return $records.ToArray()
}
function Read-ApplicationManagedManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetRoot)
    $path = Get-ApplicationManagedManifestPath `
        -TargetRoot $TargetRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $manifest = Read-JsonFile -Path $path
        if ([int]$manifest.SchemaVersion -ne 1) {
            return $null
        }
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($record in @($manifest.Files)) {
            if (-not (Test-ApplicationManagedRelativePath `
                -Path ([string]$record.Path)) -or
                -not $seen.Add([string]$record.Path) -or
                [long]$record.Length -lt 0 -or
                [string]$record.Sha256 -notmatch `
                    '^[a-fA-F0-9]{64}$') {
                return $null
            }
        }
        return $manifest
    }
    catch {
        Write-Verbose ('Yonetilen payload bildirimi okunamadi: {0}' `
            -f $_.Exception.Message)
        return $null
    }
}
function Test-ApplicationManagedStaleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [Parameter(Mandatory)][string[]]$CurrentPaths,
        [Parameter(Mandatory)][long]$ActualLength,
        [Parameter(Mandatory)][string]$ActualSha256
    )
    $relativePath = [string]$Record.Path
    return (Test-ApplicationManagedRelativePath `
        -Path $relativePath) -and
        $relativePath -inotin $CurrentPaths -and
        $ActualLength -eq [long]$Record.Length -and
        $ActualSha256 -ieq [string]$Record.Sha256
}
function Remove-StaleApplicationManagedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][object[]]$PreviousRecords,
        [Parameter(Mandatory)][string[]]$CurrentPaths
    )
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $prefix = $target + [IO.Path]::DirectorySeparatorChar
    foreach ($record in $PreviousRecords) {
        $relativePath = [string]$record.Path
        if (-not (Test-ApplicationManagedRelativePath `
            -Path $relativePath) -or
            $relativePath -iin $CurrentPaths) {
            continue
        }
        $path = [IO.Path]::GetFullPath(
            (Join-Path $target $relativePath)
        )
        if (-not $path.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $item = Get-Item -LiteralPath $path
        $actualHash = (Get-FileHash -LiteralPath $path `
            -Algorithm SHA256).Hash
        if (-not (Test-ApplicationManagedStaleFile `
            -Record $record -CurrentPaths $CurrentPaths `
            -ActualLength $item.Length `
            -ActualSha256 $actualHash)) {
            Write-Verbose (
                'Degistirilmis eski payload dosyasi korundu: {0}' -f `
                    $relativePath
            )
            continue
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
}
function Get-ApplicationPayloadConfigurationFailureReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InstalledConfig,
        [Parameter(Mandatory)]
        [pscustomobject]$ExpectedConfig
    )
    if ($null -eq $InstalledConfig) {
        return 'CONFIG_UNREADABLE'
    }
    $installationProperty =
        $InstalledConfig.PSObject.Properties['Installation']
    if ($null -eq $installationProperty) {
        return 'INSTALLATION_SECTION_MISSING'
    }
    $installation = $installationProperty.Value
    if ($null -eq $installation) {
        return 'INSTALLATION_IDENTITY_MISMATCH'
    }
    $installedProperty = $installation.PSObject.Properties['Installed']
    $engineVersionProperty =
        $installation.PSObject.Properties['EngineVersion']
    if ($null -eq $installedProperty -or
        $installedProperty.Value -isnot [bool] -or
        -not [bool]$installedProperty.Value -or
        $null -eq $engineVersionProperty -or
        [string]$engineVersionProperty.Value -cne
            [string]$ExpectedConfig.EngineVersion) {
        return 'INSTALLATION_IDENTITY_MISMATCH'
    }
    if ((ConvertTo-StableJson -Value $InstalledConfig -Depth 100) -cne
        (ConvertTo-StableJson -Value $ExpectedConfig -Depth 100)) {
        return 'CONFIG_CONTENT_MISMATCH'
    }
    return $null
}
function Assert-ApplicationPayloadContracts {
    [CmdletBinding()]
    param()
    foreach ($path in @(
        '..\outside.ps1', 'Modules\..\outside.ps1',
        'C:\outside.ps1', 'Modules\', 'Modules\file.psm1:stream'
    )) {
        if (Test-ApplicationManagedRelativePath -Path $path) {
            throw [IO.InvalidDataException]::new(
                "Guvensiz payload yolu kabul edildi: $path"
            )
        }
    }
    if (-not (Test-ApplicationManagedRelativePath `
        -Path 'Modules\00_Common.psm1')) {
        throw [IO.InvalidDataException]::new(
            'Gecerli payload yolu reddedildi.'
        )
    }
    $operationalFiles = @(Get-ApplicationOperationalPayloadFiles)
    if ($operationalFiles.Count -ne 36 -or
        @($operationalFiles | Sort-Object -Unique).Count -ne 36 -or
        $operationalFiles -inotcontains 'Data\Configs\config.json' -or
        'README.md' -iin $operationalFiles -or
        'LICENSE' -iin $operationalFiles) {
        throw [IO.InvalidDataException]::new(
            'Operasyonel payload kimligi gecersiz.'
        )
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ApplicationPayload.Operational36'
    $configFixture = [pscustomobject]@{
        AppPath = 'C:\Programs\Winlama'
    }
    if ((Get-WinlamaConfigPath -Context $configFixture) -ine
        'C:\Programs\Winlama\Data\Configs\config.json') {
        throw [IO.InvalidDataException]::new(
            'Canonical payload config yolu gecersiz.'
        )
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:ApplicationPayload.CanonicalConfig'
    $dateText = '2026-08-20T11:22:33.4567890+00:00'
    $dateFixture = ConvertFrom-WinlamaJson `
        -Json ('{"InstalledAt":"' + $dateText + '"}')
    if ($dateFixture.InstalledAt -isnot [string] -or
        [string]$dateFixture.InstalledAt -cne $dateText) {
        throw [IO.InvalidDataException]::new(
            'JSON tarih metni degistirilmeden korunamadi.'
        )
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Common.JsonDateKind'
    $quotedPath = ConvertTo-WindowsCommandLineArgument `
        -Argument 'C:\Program Files\Winlama\Start.ps1'
    $quotedTrailingPath = ConvertTo-WindowsCommandLineArgument `
        -Argument 'C:\Winlama Data\'
    if ($quotedPath -cne '"C:\Program Files\Winlama\Start.ps1"' -or
        $quotedTrailingPath -cne '"C:\Winlama Data\\"' -or
        (ConvertTo-WindowsCommandLineArgument -Argument 'C:\Winlama') `
            -cne 'C:\Winlama' -or
        (ConvertTo-WindowsCommandLineArgument -Argument '') -cne '""') {
        throw [IO.InvalidDataException]::new(
            'Windows komut satiri arguman kacis sozlesmesi gecersiz.'
        )
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Common.ArgumentQuoting'
    $unspacedShortcut = ConvertTo-WinlamaStartupShortcutArguments `
        -ScriptPath 'C:\Winlama\Start.ps1' `
        -ConfigPath 'C:\Winlama\Data\Configs\config.json' `
        -OllamaEnabled $true -OpenWebUIEnabled $false `
        -VoiceEnabled $true -ComfyUIEnabled $false
    $spacedShortcut = ConvertTo-WinlamaStartupShortcutArguments `
        -ScriptPath 'C:\Program Files\Winlama\Start.ps1' `
        -ConfigPath 'C:\Winlama Data\config.json' `
        -OllamaEnabled $false -OpenWebUIEnabled $true `
        -VoiceEnabled $false -ComfyUIEnabled $true
    $expectedUnspaced = '-NoLogo -NoProfile -ExecutionPolicy Bypass ' +
        '-File C:\Winlama\Start.ps1 ' +
        '-ConfigPath C:\Winlama\Data\Configs\config.json ' +
        '-OllamaMode Keep -OpenWebUIMode Skip ' +
        '-VoiceMode Restart -ComfyUIMode Skip'
    $expectedSpaced = '-NoLogo -NoProfile -ExecutionPolicy Bypass ' +
        '-File "C:\Program Files\Winlama\Start.ps1" ' +
        '-ConfigPath "C:\Winlama Data\config.json" ' +
        '-OllamaMode Skip -OpenWebUIMode Restart ' +
        '-VoiceMode Skip -ComfyUIMode Restart'
    if ($unspacedShortcut -cne $expectedUnspaced -or
        $spacedShortcut -cne $expectedSpaced) {
        throw [IO.InvalidDataException]::new(
            'Baslangic kisayolu arguman sozlesmesi gecersiz.'
        )
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Startup.ShortcutArguments'
    foreach ($source in @('Automatic', 'Local', 'Online')) {
        if (-not (Test-InstallSourceValue -Value $source)) {
            throw [IO.InvalidDataException]::new(
                "Gecerli kurulum kaynagi reddedildi: $source"
            )
        }
    }
    foreach ($source in @($null, '', 'automatic', 'Prompt')) {
        if (Test-InstallSourceValue -Value $source) {
            throw [IO.InvalidDataException]::new(
                "Gecersiz kurulum kaynagi kabul edildi: $source"
            )
        }
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:Config.InstallSource'
    $expectedConfig = [pscustomobject][ordered]@{
        EngineVersion = '26.8.6'
        Installation = [pscustomobject][ordered]@{
            Installed = $true
            EngineVersion = '26.8.6'
            InstalledAt = $dateText
        }
    }
    $matchingConfig = ConvertFrom-WinlamaJson -Json (
        ConvertTo-StableJson -Value $expectedConfig -Depth 10
    )
    $missingInstallation = [pscustomobject]@{
        EngineVersion = '26.8.6'
    }
    $nullInstallation = [pscustomobject]@{
        EngineVersion = '26.8.6'
        Installation = $null
    }
    $stringInstalled = [pscustomobject]@{
        EngineVersion = '26.8.6'
        Installation = [pscustomobject]@{
            Installed = 'true'
            EngineVersion = '26.8.6'
        }
    }
    $badIdentity = ConvertFrom-WinlamaJson -Json (
        ConvertTo-StableJson -Value $expectedConfig -Depth 10
    )
    $badIdentity.Installation.Installed = $false
    $badContent = ConvertFrom-WinlamaJson -Json (
        ConvertTo-StableJson -Value $expectedConfig -Depth 10
    )
    $badContent.Installation.InstalledAt = 'different'
    if ((Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $null -ExpectedConfig $expectedConfig) `
            -cne 'CONFIG_UNREADABLE' -or
        (Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $missingInstallation `
            -ExpectedConfig $expectedConfig) `
            -cne 'INSTALLATION_SECTION_MISSING' -or
        (Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $nullInstallation `
            -ExpectedConfig $expectedConfig) `
            -cne 'INSTALLATION_IDENTITY_MISMATCH' -or
        (Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $stringInstalled `
            -ExpectedConfig $expectedConfig) `
            -cne 'INSTALLATION_IDENTITY_MISMATCH' -or
        (Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $badIdentity `
            -ExpectedConfig $expectedConfig) `
            -cne 'INSTALLATION_IDENTITY_MISMATCH' -or
        (Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $badContent `
            -ExpectedConfig $expectedConfig) `
            -cne 'CONFIG_CONTENT_MISMATCH' -or
        $null -ne (Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $matchingConfig `
            -ExpectedConfig $expectedConfig)) {
        throw [IO.InvalidDataException]::new(
            'Payload config hata nedeni sozlesmesi gecersiz.'
        )
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ApplicationPayload.Reasons'
    $record = [pscustomobject]@{
        Path = 'Modules\Obsolete.psm1'
        Length = 10L
        Sha256 = 'A' * 64
    }
    if (-not (Test-ApplicationManagedStaleFile `
        -Record $record -CurrentPaths @('Modules\Current.psm1') `
        -ActualLength 10L -ActualSha256 ('A' * 64)) -or
        (Test-ApplicationManagedStaleFile `
            -Record $record -CurrentPaths @($record.Path) `
            -ActualLength 10L -ActualSha256 ('A' * 64)) -or
        (Test-ApplicationManagedStaleFile `
            -Record $record -CurrentPaths @('Modules\Current.psm1') `
            -ActualLength 10L -ActualSha256 ('B' * 64))) {
        throw [IO.InvalidDataException]::new(
            'Payload eski dosya koruma sozlesmesi gecersiz.'
        )
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:ApplicationPayload.Contracts'
}
function Write-ApplicationPayloadVerificationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Reason
    )
    Write-Verbose ("APPLICATION_PAYLOAD_VERIFY_FAILED|$Reason")
    if ($null -ne (Get-Command Write-DeploymentLog `
        -ErrorAction SilentlyContinue)) {
        try {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module BOOTSTRAP `
                -Message 'Application.Payload.VerificationFailed' `
                -MessageArguments @($Reason)
        }
        catch {
            Write-Verbose (
                'APPLICATION_PAYLOAD_VERIFY_LOG_FAILED|{0}' -f `
                    $_.Exception.Message
            )
        }
    }
    return $false
}
function Install-ApplicationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $source = $Context.PackageRoot.TrimEnd('\')
    $destination = $Context.AppPath.TrimEnd('\')
    $managedFiles = @(Get-ApplicationManagedFiles `
        -SourceRoot $source)
    $managedRecords = @(Get-ApplicationManagedRecords `
        -SourceRoot $source -RelativePaths $managedFiles)
    $previousManifest = Read-ApplicationManagedManifest `
        -TargetRoot $destination
    if ($null -ne $previousManifest) {
        Remove-StaleApplicationManagedFiles `
            -TargetRoot $destination `
            -PreviousRecords @($previousManifest.Files) `
            -CurrentPaths $managedFiles
    }
    if ($source -ne $destination) {
        foreach ($relativePath in $managedFiles) {
            $sourcePath = Join-Path $source $relativePath
            $destinationPath = Join-Path $destination $relativePath
            [IO.Directory]::CreateDirectory(
                (Split-Path -Parent $destinationPath)
            ) | Out-Null
            Copy-Item -LiteralPath $sourcePath `
                -Destination $destinationPath -Force
        }
        foreach ($relativePath in @(
            'Data\ComfyUI\Winlama-Default-Workflow',
            'Integrations\ComfyUI\Winlama-Default-Workflow'
        )) {
            $obsoletePath = Join-Path $destination $relativePath
            if (Test-Path -LiteralPath $obsoletePath `
                -PathType Container) {
                Remove-Item -LiteralPath $obsoletePath `
                    -Recurse -Force
            }
            $obsoleteParent = Split-Path -Parent $obsoletePath
            while ($obsoleteParent -ne $destination -and
                (Test-Path -LiteralPath $obsoleteParent `
                    -PathType Container) -and
                @(Get-ChildItem -LiteralPath $obsoleteParent `
                    -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $obsoleteParent -Force
                $obsoleteParent = Split-Path -Parent $obsoleteParent
            }
        }
    }
    $Context.Config.Installation.Installed = $true
    $Context.Config.Installation.EngineVersion = `
        $Context.Config.EngineVersion
    $Context.Config.Installation.InstalledAt = `
        [DateTimeOffset]::UtcNow.ToString('O')
    $Context.Config.Installation.Source = $Context.PackageRoot
    $effectiveConfig = ConvertTo-StableJson `
        -Value $Context.Config -Depth 100
    $destConfigs = Join-Path (Join-Path $destination 'Data') 'Configs'
    [IO.Directory]::CreateDirectory($destConfigs) | Out-Null
    Write-AtomicTextFile -Path (Join-Path $destConfigs 'config.json') `
        -Content $effectiveConfig
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 1
        EngineVersion = [string]$Context.Config.EngineVersion
        Files = $managedRecords
    }
    Write-AtomicTextFile `
        -Path (Get-ApplicationManagedManifestPath `
            -TargetRoot $destination) `
        -Content (ConvertTo-StableJson -Value $manifest -Depth 10)
}
function Get-PowerShellRuntimePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $candidates = [Collections.Generic.List[string]]::new()
    $configured = [string]$Context.Config.Installation.PowerShellPath
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $candidates.Add(
            [Environment]::ExpandEnvironmentVariables($configured)
        )
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $candidates.Add((Join-Path $PSHOME 'pwsh.exe'))
    }
    $candidates.Add((Join-Path $env:ProgramFiles `
        'PowerShell\7\pwsh.exe'))
    $command = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $candidates.Add($command.Source)
    }
    foreach ($candidate in $candidates) {
        if ([IO.Path]::GetFileName($candidate) -ine 'pwsh.exe') {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw (Get-LocalizedText `
        -Key 'Common.Error.PowerShellRuntimeMissing')
}
function Get-WinlamaConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return [IO.Path]::GetFullPath(
        (Join-Path $Context.AppPath 'Data\Configs\config.json')
    )
}
function Get-WinlamaStartupShortcutPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return [IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables(
            [string]$Context.Config.Startup.ShortcutPath
        )
    )
}
function ConvertTo-WinlamaStartupShortcutArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][bool]$OllamaEnabled,
        [Parameter(Mandatory)][bool]$OpenWebUIEnabled,
        [Parameter(Mandatory)][bool]$VoiceEnabled,
        [Parameter(Mandatory)][bool]$ComfyUIEnabled
    )
    $ollamaMode = if ($OllamaEnabled) { 'Keep' } else { 'Skip' }
    $openWebUIMode = if ($OpenWebUIEnabled) { 'Restart' } else { 'Skip' }
    $voiceMode = if ($VoiceEnabled) { 'Restart' } else { 'Skip' }
    $comfyUIMode = if ($ComfyUIEnabled) { 'Restart' } else { 'Skip' }
    $quotedScriptPath = ConvertTo-WindowsCommandLineArgument `
        -Argument $ScriptPath
    $quotedConfigPath = ConvertTo-WindowsCommandLineArgument `
        -Argument $ConfigPath
    $template = '-NoLogo -NoProfile -ExecutionPolicy Bypass ' +
        '-File {0} -ConfigPath {1} ' +
        '-OllamaMode {2} -OpenWebUIMode {3} ' +
        '-VoiceMode {4} -ComfyUIMode {5}'
    return $template -f `
        $quotedScriptPath, $quotedConfigPath, $ollamaMode,
        $openWebUIMode, $voiceMode, $comfyUIMode
}
function Install-WinlamaStartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $shortcutPath = Get-WinlamaStartupShortcutPath -Context $Context
    $obsoleteShortcut = [Environment]::ExpandEnvironmentVariables(
        '%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\' +
        'Winlama-OpenWebUI.lnk'
    )
    if ([IO.Path]::GetFullPath($obsoleteShortcut) -ine $shortcutPath) {
        Remove-Item -LiteralPath $obsoleteShortcut -Force `
            -ErrorAction SilentlyContinue
    }
    if (-not $Context.Config.Startup.Enabled) {
        Remove-Item -LiteralPath $shortcutPath -Force `
            -ErrorAction SilentlyContinue
        return $null
    }
    $scriptPath = Join-Path $Context.AppPath `
        ([string]$Context.Config.Startup.Script)
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw (Get-LocalizedText `
            -Key 'WebUI.Error.StartupScriptMissing' `
            -Arguments @($scriptPath))
    }
    $directory = Split-Path -Parent $shortcutPath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $pwsh = Get-PowerShellRuntimePath -Context $Context
    $configPath = Get-WinlamaConfigPath -Context $Context
    $arguments = ConvertTo-WinlamaStartupShortcutArguments `
        -ScriptPath $scriptPath -ConfigPath $configPath `
        -OllamaEnabled ([bool]$Context.Config.Ollama.Enabled) `
        -OpenWebUIEnabled ([bool]$Context.Config.OpenWebUI.Enabled) `
        -VoiceEnabled ([bool]$Context.Config.Voice.Enabled) `
        -ComfyUIEnabled ([bool]$Context.Config.ComfyUI.Enabled)
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $pwsh
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $Context.AppPath
        $shortcut.WindowStyle = 1
        $shortcut.Description = 'Winlama otomatik baslatici'
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shortcut
            )
        }
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shell
            )
        }
    }
    return $shortcutPath
}
function Test-WinlamaStartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.Startup.Enabled) {
        return $true
    }
    $scriptPath = Join-Path $Context.AppPath `
        ([string]$Context.Config.Startup.Script)
    $shortcutPath = Get-WinlamaStartupShortcutPath -Context $Context
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return $false
    }
    $shell = $null
    $shortcut = $null
    try {
        $configPath = Get-WinlamaConfigPath -Context $Context
        $expectedArguments = `
            ConvertTo-WinlamaStartupShortcutArguments `
                -ScriptPath $scriptPath -ConfigPath $configPath `
                -OllamaEnabled ([bool]$Context.Config.Ollama.Enabled) `
                -OpenWebUIEnabled ([bool]$Context.Config.OpenWebUI.Enabled) `
                -VoiceEnabled ([bool]$Context.Config.Voice.Enabled) `
                -ComfyUIEnabled ([bool]$Context.Config.ComfyUI.Enabled)
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        return [string]$shortcut.TargetPath -ieq `
            (Get-PowerShellRuntimePath -Context $Context) -and
            [string]$shortcut.Arguments -ceq $expectedArguments -and
            [string]$shortcut.WorkingDirectory -ieq $Context.AppPath -and
            [int]$shortcut.WindowStyle -eq 1
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shortcut
            )
        }
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shell
            )
        }
    }
}
function Test-ApplicationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $configPath = Join-Path $Context.AppPath `
        'Data\Configs\config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return Write-ApplicationPayloadVerificationFailure `
            -Context $Context -Reason 'CONFIG_MISSING'
    }
    $installedConfig = try {
        Read-JsonFile -Path $configPath
    }
    catch {
        Write-Verbose ('Payload config okunamadi: {0}' -f `
            $_.Exception.Message)
        $null
    }
    $configurationFailure =
        Get-ApplicationPayloadConfigurationFailureReason `
            -InstalledConfig $installedConfig `
            -ExpectedConfig $Context.Config
    if ($null -ne $configurationFailure) {
        return Write-ApplicationPayloadVerificationFailure `
            -Context $Context -Reason $configurationFailure
    }
    $sourceRoot = $Context.PackageRoot.TrimEnd('\')
    $targetRoot = $Context.AppPath.TrimEnd('\')
    try {
        $managedFiles = @(Get-ApplicationManagedFiles `
            -SourceRoot $sourceRoot)
        $managedRecords = @(Get-ApplicationManagedRecords `
            -SourceRoot $sourceRoot -RelativePaths $managedFiles)
    }
    catch {
        Write-Verbose ('Kaynak payload okunamadi: {0}' -f `
            $_.Exception.Message)
        return Write-ApplicationPayloadVerificationFailure `
            -Context $Context -Reason 'SOURCE_PAYLOAD_UNREADABLE'
    }
    $manifestPath = Get-ApplicationManagedManifestPath `
        -TargetRoot $targetRoot
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return Write-ApplicationPayloadVerificationFailure `
            -Context $Context -Reason 'MANIFEST_MISSING'
    }
    $manifest = Read-ApplicationManagedManifest `
        -TargetRoot $targetRoot
    if ($null -eq $manifest) {
        return Write-ApplicationPayloadVerificationFailure `
            -Context $Context -Reason 'MANIFEST_INVALID'
    }
    if ([string]$manifest.EngineVersion -cne
            [string]$Context.Config.EngineVersion) {
        return Write-ApplicationPayloadVerificationFailure `
            -Context $Context -Reason 'MANIFEST_IDENTITY_MISMATCH'
    }
    $expectedByPath = @{}
    foreach ($record in $managedRecords) {
        $expectedByPath[[string]$record.Path] = $record
    }
    if (@($manifest.Files).Count -ne $managedRecords.Count) {
        return Write-ApplicationPayloadVerificationFailure `
            -Context $Context -Reason 'MANIFEST_FILE_COUNT_MISMATCH'
    }
    foreach ($record in @($manifest.Files)) {
        $relativePath = [string]$record.Path
        if (-not $expectedByPath.ContainsKey($relativePath)) {
            return Write-ApplicationPayloadVerificationFailure `
                -Context $Context `
                -Reason "MANIFEST_UNEXPECTED_FILE:$relativePath"
        }
        $expected = $expectedByPath[$relativePath]
        if ([long]$record.Length -ne [long]$expected.Length -or
            [string]$record.Sha256 -ine [string]$expected.Sha256) {
            return Write-ApplicationPayloadVerificationFailure `
                -Context $Context `
                -Reason "MANIFEST_RECORD_MISMATCH:$relativePath"
        }
    }
    foreach ($relativePath in $managedFiles) {
        $sourcePath = Join-Path $sourceRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            continue
        }
        $targetPath = Join-Path $targetRoot $relativePath
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            return Write-ApplicationPayloadVerificationFailure `
                -Context $Context -Reason "TARGET_FILE_MISSING:$relativePath"
        }
        $sourceFile = Get-Item -LiteralPath $sourcePath
        $targetFile = Get-Item -LiteralPath $targetPath
        if ($sourceFile.Length -ne $targetFile.Length -or
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash `
                -ine
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash) {
            return Write-ApplicationPayloadVerificationFailure `
                -Context $Context -Reason "TARGET_FILE_MISMATCH:$relativePath"
        }
    }
    return $true
}
function Unregister-DeploymentResumeTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $task = Get-ScheduledTask `
        -TaskName $Context.Config.Uninstall.ResumeTaskName `
        -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask `
            -TaskName $Context.Config.Uninstall.ResumeTaskName `
            -Confirm:$false
    }
}
function Test-TcpEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,
        [Parameter(Mandatory)]
        [int]$Port,
        [int]$TimeoutMilliseconds = 3000
    )
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds(
            $TimeoutMilliseconds
        )
        while (-not $task.IsCompleted -and
            [DateTimeOffset]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
        }
        if ($task.IsFaulted) {
            $null = $task.Exception
        }
        return $task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion `
            -and $client.Connected
    }
    finally {
        $client.Dispose()
    }
}
function Test-HttpEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,
        [int]$TimeoutMilliseconds = 5000
    )
    if ($null -eq ('System.Net.Http.HttpClient' -as [type])) {
        Add-Type -AssemblyName System.Net.Http
    }
    $client = [Net.Http.HttpClient]::new()
    $response = $null
    try {
        $task = $client.GetAsync($Uri)
        $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds(
            $TimeoutMilliseconds
        )
        while (-not $task.IsCompleted -and
            [DateTimeOffset]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
        }
        if ($task.IsFaulted) {
            $null = $task.Exception
            return $false
        }
        if ($task.Status -ne `
            [Threading.Tasks.TaskStatus]::RanToCompletion) {
            return $false
        }
        $response = $task.Result
        return [int]$response.StatusCode -ge 200 -and
            [int]$response.StatusCode -lt 400
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $client.Dispose()
    }
}
function Get-LocalHttpOrigins {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Port,
        [switch]$IncludeNetwork
    )
    $hosts = @('127.0.0.1', 'localhost')
    if ($IncludeNetwork) {
        $hosts += [Environment]::MachineName
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 `
            -AddressState Preferred -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.SkipAsSource -and
                $_.IPAddress -notlike '127.*'
            } | Select-Object -ExpandProperty IPAddress)
        $hosts += $addresses
    }
    return @($hosts | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Sort-Object -Unique | ForEach-Object {
        'http://{0}:{1}' -f $_, $Port
    })
}
function Set-WinlamaProcessPriority {
    [CmdletBinding()]
    param(
        [ValidateSet('Normal', 'AboveNormal', 'High')]
        [string]$Priority = 'High',
        [int]$ProcessId = $PID
    )
    $process = $null
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $priorityClass = [Enum]::Parse(
            [Diagnostics.ProcessPriorityClass],
            $Priority,
            $true
        )
        $process.PriorityClass = $priorityClass
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}
function Get-WinlamaLanHost {
    [CmdletBinding()]
    param()
    $routes = @(Get-NetRoute -AddressFamily IPv4 `
        -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric)
    foreach ($route in $routes) {
        $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex `
            -AddressFamily IPv4 -AddressState Preferred `
            -ErrorAction SilentlyContinue | Where-Object {
                -not $_.SkipAsSource -and
                $_.IPAddress -notlike '127.*' -and
                $_.IPAddress -notlike '169.254.*'
            } | Select-Object -First 1
        if ($null -ne $address) {
            return [string]$address.IPAddress
        }
    }
    $address = Get-NetIPAddress -AddressFamily IPv4 `
        -AddressState Preferred -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.SkipAsSource -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*'
        } | Select-Object -First 1
    if ($null -ne $address) {
        return [string]$address.IPAddress
    }
    return [Environment]::MachineName
}
function Get-WinlamaServiceUris {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )
    $loopbackHosts = @('127.0.0.1', 'localhost', '::1')
    $lanHostRequired = $Config.Security.LanAccess -and (
        ($Config.Ollama.Enabled -and
            $Config.Ollama.Host -notin $loopbackHosts) -or
        ($Config.OpenWebUI.Enabled -and
            $Config.OpenWebUI.Host -notin $loopbackHosts) -or
        ($Config.ComfyUI.Enabled -and
            $Config.ComfyUI.Host -notin $loopbackHosts)
    )
    $lanHost = if ($lanHostRequired) {
        Get-WinlamaLanHost
    }
    else {
        ''
    }
    $voiceHost = [string]$Config.Voice.Host
    if ($voiceHost.Contains(':') -and
        -not $voiceHost.StartsWith('[')) {
        $voiceHost = "[$voiceHost]"
    }
    return [pscustomobject][ordered]@{
        OllamaLocal = 'http://127.0.0.1:{0}' -f `
            $Config.Ollama.Port
        OllamaLan = if ($Config.Ollama.Enabled -and
            $Config.Security.LanAccess -and
            $Config.Ollama.Host -notin $loopbackHosts) {
            'http://{0}:{1}' -f $lanHost, $Config.Ollama.Port
        }
        else {
            ''
        }
        OpenWebUILocal = 'http://127.0.0.1:{0}' -f `
            $Config.OpenWebUI.Port
        OpenWebUITemporary = `
            'http://127.0.0.1:{0}/?temporary-chat=true' -f `
            $Config.OpenWebUI.Port
        OpenWebUILan = if ($Config.OpenWebUI.Enabled -and
            $Config.Security.LanAccess -and
            $Config.OpenWebUI.Host -notin $loopbackHosts) {
            'http://{0}:{1}' -f $lanHost, $Config.OpenWebUI.Port
        }
        else {
            ''
        }
        VoiceLocal = 'http://{0}:{1}' -f `
            $voiceHost, $Config.Voice.Port
        ComfyUILocal = 'http://127.0.0.1:{0}' -f `
            $Config.ComfyUI.Port
        ComfyUILan = if ($Config.ComfyUI.Enabled -and
            $Config.Security.LanAccess -and
            $Config.ComfyUI.Host -notin $loopbackHosts) {
            'http://{0}:{1}' -f $lanHost, $Config.ComfyUI.Port
        }
        else {
            ''
        }
    }
}
function Get-ModelStorageRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Model,
        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int]$SafetyBufferPercent
    )
    $bufferMultiplier = 1 + ($SafetyBufferPercent / 100.0)
    $reservationGB = ($Model.DownloadSizeGB +
        $Model.WorkingSpaceGB) * $bufferMultiplier
    return [pscustomobject]@{
        ReservationGB = $reservationGB
        RequiredGB = $Model.DownloadSizeGB + $reservationGB
    }
}
function Test-WinlamaClientOperatingSystemContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][int]$ProductType
    )
    return $ProductType -eq 1 -and
        $Version -ge [version]'10.0.19045' -and
        $Architecture -ieq 'X64'
}
function Get-WinlamaOperatingSystemEvidence {
    [CmdletBinding()]
    param()
    try {
        $operatingSystem = Get-CimInstance `
            -ClassName Win32_OperatingSystem -ErrorAction Stop
        $versionText = [string]$operatingSystem.Version
        $productTypeText = [string]$operatingSystem.ProductType
        if ([string]::IsNullOrWhiteSpace($versionText) -or
            [string]::IsNullOrWhiteSpace($productTypeText)) {
            throw [IO.InvalidDataException]::new(
                'Version/ProductType'
            )
        }
        $version = [version]$versionText
        $productType = [int]$productTypeText
    }
    catch {
        throw [IO.InvalidDataException]::new(
            (Get-LocalizedText `
                -Key 'Common.Error.WindowsOperatingSystemQueryFailed' `
                -Arguments @($_.Exception.Message)),
            $_.Exception
        )
    }
    $architecture = try {
        [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    }
    catch {
        [string]$env:PROCESSOR_ARCHITECTURE
    }
    if ($architecture -ieq 'AMD64') {
        $architecture = 'X64'
    }
    return [pscustomobject]@{
        Version = $version
        Architecture = $architecture
        ProductType = $productType
    }
}
function Assert-WinlamaClientOperatingSystem {
    [CmdletBinding()]
    param()
    $evidence = Get-WinlamaOperatingSystemEvidence
    if (-not (Test-WinlamaClientOperatingSystemContract `
        -Version $evidence.Version `
        -Architecture $evidence.Architecture `
        -ProductType $evidence.ProductType)) {
        throw [PlatformNotSupportedException]::new(
            (Get-LocalizedText `
                -Key 'Common.Error.WindowsEnvironmentUnsupported' `
                -Arguments @(
                    $evidence.Version,
                    $evidence.Architecture,
                    $evidence.ProductType
                ))
        )
    }
}
function Test-IsAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
function Assert-DeploymentPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $IsWindows) {
        throw (Get-LocalizedText -Key 'Common.Error.WindowsOnly')
    }
    if (-not (Test-IsAdministrator)) {
        throw (Get-LocalizedText -Key 'Common.Error.AdminRequired')
    }
    if ($PSVersionTable.PSVersion -lt
        [version]$Context.Config.MinimumPowerShellVersion) {
        throw (Get-LocalizedText `
            -Key 'Common.Error.PowerShellVersionUnsupported')
    }
    Assert-WinlamaClientOperatingSystem
}
Export-ModuleMember -Function @(
    'ConvertFrom-WinlamaJson', 'Read-JsonFile', 'ConvertTo-StableJson',
    'ConvertTo-WindowsCommandLineArgument',
    'New-NonRetryableException',
    'Test-DeploymentConfiguration',
    'Resolve-ConfigurationPath',
    'New-DeploymentContext', 'Get-StableMachineId',
    'Initialize-DeploymentDirectories', 'Write-AtomicTextFile',
    'Add-WinlamaUtf8Line',
    'Assert-ApplicationPayloadContracts',
    'Assert-ApplicationSourcePayload',
    'Install-ApplicationPayload', 'Get-PowerShellRuntimePath',
    'Get-WinlamaConfigPath', 'Get-WinlamaStartupShortcutPath',
    'Install-WinlamaStartupShortcut',
    'Test-WinlamaStartupShortcut',
    'Test-ApplicationPayload',
    'Unregister-DeploymentResumeTask', 'Test-TcpEndpoint',
    'Test-HttpEndpoint', 'Get-LocalHttpOrigins',
    'Set-WinlamaProcessPriority', 'Get-WinlamaLanHost',
    'Get-WinlamaServiceUris',
    'Get-ModelStorageRequirement',
    'Get-WinlamaTimestampedPath', 'New-WinlamaTimestampedFile',
    'Resolve-WinlamaIndexSelection',
    'Test-WinlamaClientOperatingSystemContract',
    'Assert-WinlamaClientOperatingSystem',
    'Test-IsAdministrator', 'Assert-DeploymentPrerequisites'
)