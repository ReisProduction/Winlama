function Test-InstallerVoiceModelCache {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [scriptblock]$FileProbe
    )
    $dataRoot = Resolve-InstallerDeploymentPath -Config $Config `
        -Path ([string]$Config.Paths.Data)
    $primary = @{
        Model = [string]$Config.Voice.Model
        Revision = [string]$Config.Voice.Revision
    }
    if (-not (Test-InstallerVoiceProfileCache -DataRoot $dataRoot `
        -Model $primary.Model -Revision $primary.Revision -FileProbe $FileProbe)) {
        return $false
    }
    $bilingual = $Config.Voice.PSObject.Properties['Bilingual']
    if ($null -eq $bilingual -or -not [bool]$bilingual.Value) {
        return $true
    }
    $other = if ([string]$Config.Voice.Language -ceq 'en') { 'Turkish' } else { 'English' }
    $profile = Get-InstallerVoiceProfile -Language $other
    return Test-InstallerVoiceProfileCache -DataRoot $dataRoot `
        -Model $profile.Model -Revision $profile.Revision -FileProbe $FileProbe
}
function Test-InstallerVoiceProfileCache {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [AllowEmptyString()][string]$Model,
        [AllowEmptyString()][string]$Revision,
        [scriptblock]$FileProbe
    )
    if ($model -notmatch '^[a-z0-9._-]+/[a-z0-9._-]+$' -or
        $revision -notmatch '^[a-f0-9]{40}$') {
        return $false
    }
    $cacheName = $model.Split('/')[-1]
    $repositoryName = 'models--{0}' -f $model.Replace('/', '--')
    $snapshot = Join-Path $dataRoot `
        "cache\huggingface\$cacheName\$repositoryName\snapshots\$revision"
    $testFile = {
        param([string]$Path)
        if ($null -ne $FileProbe) {
            return [bool](& $FileProbe $Path)
        }
        return Test-Path -LiteralPath $Path -PathType Leaf
    }.GetNewClosure()
    if (-not (& $testFile (Join-Path $snapshot 'config.json')) -or
        -not (& $testFile (Join-Path $snapshot 'vocab.json'))) {
        return $false
    }
    return (& $testFile (Join-Path $snapshot 'model.safetensors')) -or
        (& $testFile (Join-Path $snapshot 'pytorch_model.bin'))
}
function Get-InstallerVoiceProfile {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Turkish', 'English')]
        [string]$Language
    )
    if ($Language -ceq 'English') {
        return [pscustomobject][ordered]@{
            Language = 'en'
            Model = 'facebook/mms-tts-eng'
            Revision = 'c71de0fe7204c83f1c10820a7d696d0b450048ba'
        }
    }
    return [pscustomobject][ordered]@{
        Language = 'tr'
        Model = 'facebook/mms-tts-tur'
        Revision = '7e364479c307f06733ca865b0a5269e0209cf82d'
    }
}
function Set-InstallerVoiceLanguage {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)]
        [ValidateSet('Turkish', 'English', 'Both')]
        [string]$Language
    )
    $primary = if ($Language -ceq 'Both') { 'Turkish' } else { $Language }
    $profile = Get-InstallerVoiceProfile -Language $primary
    $Config.Voice | Add-Member -NotePropertyName Bilingual `
        -NotePropertyValue ($Language -ceq 'Both') -Force
    $Config.Voice | Add-Member -NotePropertyName Language `
        -NotePropertyValue $profile.Language -Force
    $Config.Voice.Model = $profile.Model
    $Config.Voice.Revision = $profile.Revision
}
function Import-InstallerExistingVoiceProfile {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [AllowEmptyString()][string]$InstalledConfigPath = '',
        [scriptblock]$ConfigReader,
        [scriptblock]$FeatureTester
    )
    try {
        if ([string]::IsNullOrWhiteSpace($InstalledConfigPath)) {
            $installedRoot = Resolve-InstallerPath `
                -Path ([string]$Config.Paths.Root)
            $InstalledConfigPath = Join-Path $installedRoot `
                'Data\Configs\config.json'
        }
        if ($null -eq $ConfigReader -and
            -not (Test-Path -LiteralPath $InstalledConfigPath `
                -PathType Leaf)) {
            return $false
        }
        $installedConfig = if ($null -ne $ConfigReader) {
            & $ConfigReader -Path $InstalledConfigPath
        }
        else {
            Read-JsonFile -Path $InstalledConfigPath
        }
        if ($null -eq $installedConfig) {
            return $false
        }
        $null = Test-DeploymentConfiguration -Config $installedConfig
        if (-not [bool]$installedConfig.Voice.Enabled) {
            return $false
        }
        $language = [string]$installedConfig.Voice.Language
        $profileName = if ($language -ceq 'en') {
            'English'
        }
        elseif ($language -ceq 'tr') {
            'Turkish'
        }
        else {
            return $false
        }
        $profile = Get-InstallerVoiceProfile -Language $profileName
        if ([string]$installedConfig.Voice.Model -cne $profile.Model -or
            [string]$installedConfig.Voice.Revision -cne
                $profile.Revision) {
            return $false
        }
        $candidate = $Config | ConvertTo-Json -Depth 100 |
            ConvertFrom-InstallerJson
        Set-InstallerVoiceLanguage -Config $candidate `
            -Language $profileName
        $bilingual = $installedConfig.Voice.PSObject.Properties['Bilingual']
        $candidate.Voice.Bilingual = $null -ne $bilingual -and [bool]$bilingual.Value
        $ready = if ($null -ne $FeatureTester) {
            [bool](& $FeatureTester -Config $candidate)
        }
        else {
            Test-InstallerExistingFeature -Config $candidate `
                -Feature Voice -VerifyIdentity $false
        }
        if (-not $ready) {
            return $false
        }
        Set-InstallerVoiceLanguage -Config $Config -Language $profileName
        $Config.Voice.Bilingual = $candidate.Voice.Bilingual
        return $true
    }
    catch {
        Write-Verbose ('Kurulu ses profili kullanilamadi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Read-InstallerVoiceLanguageSelection {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [ValidateSet('Prompt', 'Turkish', 'English', 'Both')]
        [string]$Selection = 'Prompt',
        [scriptblock]$InputReader
    )
    if ($Selection -ne 'Prompt') {
        Set-InstallerVoiceLanguage -Config $Config `
            -Language $Selection
        return $Selection
    }
    if (-not [Environment]::UserInteractive) {
        $bilingual = $Config.Voice.PSObject.Properties['Bilingual']
        if ($null -ne $bilingual -and [bool]$bilingual.Value) {
            return 'Both'
        }
        $configured = if (
            [string]$Config.Voice.Language -ceq 'en'
        ) {
            'English'
        }
        else {
            'Turkish'
        }
        Set-InstallerVoiceLanguage -Config $Config `
            -Language $configured
        return $configured
    }
    Write-InstallerSection `
        -Title 'Installer.Section.VoiceLanguageSelection'
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Voice.LanguageDescription') -Color White
    Write-InstallerLine -Text (Get-LocalizedText `
        -Key 'Installer.Voice.EnglishLicense') -Color Yellow
    Write-InstallerRule
    while ($true) {
        $answer = Read-WinlamaUIInput `
            -Prompt (Get-LocalizedText `
                -Key 'Installer.Prompt.VoiceLanguageSelection') `
            -Label (Get-LocalizedText `
                -Key 'Common.Prompt.Selection') -NoLeadingRule `
            -InputReader $InputReader
        $resolved = switch ($answer) {
            '1' { 'Turkish' }
            '2' { 'English' }
            '3' { 'Both' }
            '0' { 'Exit' }
            default { '' }
        }
        if ($resolved -ceq 'Exit') {
            return $resolved
        }
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            Set-InstallerVoiceLanguage -Config $Config `
                -Language $resolved
            return $resolved
        }
        Write-InstallerLine -Text (Get-LocalizedText `
            -Key 'Common.Selection.Invalid') -Color Yellow
    }
}
function Assert-InstallerVoiceLanguageContracts {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $fixture = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    $turkish = Get-InstallerVoiceProfile -Language Turkish
    $english = Get-InstallerVoiceProfile -Language English
    $both = $Config | ConvertTo-Json -Depth 100 | ConvertFrom-InstallerJson
    if ((Read-InstallerVoiceLanguageSelection -Config $both -Selection Both) -cne 'Both' -or
        -not $both.Voice.Bilingual -or $both.Voice.Language -cne 'tr') {
        throw 'Iki dilli TTS secimi dogrulanamadi.'
    }
    $selected = Read-InstallerVoiceLanguageSelection `
        -Config $fixture -Selection English
    $sourceFixture = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    Set-InstallerVoiceLanguage -Config $sourceFixture `
        -Language Turkish
    $profileImported = Import-InstallerExistingVoiceProfile `
        -Config $sourceFixture -InstalledConfigPath 'C:\Fixture\config.json' `
        -ConfigReader { param($Path) $fixture }.GetNewClosure() `
        -FeatureTester {
            param($Config)
            [string]$Config.Voice.Language -ceq 'en' -and
                [string]$Config.Voice.Model -ceq $english.Model -and
                [string]$Config.Voice.Revision -ceq $english.Revision
        }.GetNewClosure()
    $invalidInstalled = $fixture | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    $invalidInstalled.Voice.Model = $turkish.Model
    $rejectedFixture = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    Set-InstallerVoiceLanguage -Config $rejectedFixture `
        -Language Turkish
    $invalidImported = Import-InstallerExistingVoiceProfile `
        -Config $rejectedFixture `
        -InstalledConfigPath 'C:\Fixture\invalid.json' `
        -ConfigReader { param($Path) $invalidInstalled }.GetNewClosure() `
        -FeatureTester { throw 'Gecersiz profil probe edildi.' }
    $disabledInstalled = $fixture | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    $disabledInstalled.Voice.Enabled = $false
    $disabledFixture = $Config | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    Set-InstallerVoiceLanguage -Config $disabledFixture `
        -Language Turkish
    $disabledImported = Import-InstallerExistingVoiceProfile `
        -Config $disabledFixture `
        -InstalledConfigPath 'C:\Fixture\disabled.json' `
        -ConfigReader { param($Path) $disabledInstalled }.GetNewClosure() `
        -FeatureTester { throw 'Devre disi profil probe edildi.' }
    $deploymentFixture = $fixture | ConvertTo-Json -Depth 100 |
        ConvertFrom-InstallerJson
    $deploymentRoot = Join-Path ([IO.Path]::GetTempPath()) `
        'Winlama-Voice-Deployment-Fixture'
    $deploymentFixture.Paths.Root = $deploymentRoot
    $deploymentFixture.Paths.Data = 'Data'
    $probedVoicePaths = [Collections.Generic.List[string]]::new()
    $voiceCacheReady = Test-InstallerVoiceModelCache `
        -Config $deploymentFixture -FileProbe {
            param($Path)
            $probedVoicePaths.Add([IO.Path]::GetFullPath($Path))
            return $Path -notlike '*\pytorch_model.bin'
        }.GetNewClosure()
    $quickOpenWebUIReady = Test-InstallerExistingFeature `
        -Config $deploymentFixture -Feature OpenWebUI `
        -VerifyIdentity $false -FileProbe { return $true }
    $quickVoiceReady = Test-InstallerExistingFeature `
        -Config $deploymentFixture -Feature Voice `
        -VerifyIdentity $false -FileProbe { return $true }
    $expectedVoiceRoot = Join-Path $deploymentRoot `
        ('Data\cache\huggingface\{0}\models--{1}\snapshots\{2}' -f `
            $deploymentFixture.Voice.Model.Split('/')[-1],
            $deploymentFixture.Voice.Model.Replace('/', '--'),
            $deploymentFixture.Voice.Revision)
    $voicePrefix = [IO.Path]::GetFullPath($expectedVoiceRoot).TrimEnd('') +
        [IO.Path]::DirectorySeparatorChar
    $source = (Get-Command Read-InstallerVoiceLanguageSelection `
        -ErrorAction Stop).Definition
    if ($turkish.Language -cne 'tr' -or
        $turkish.Model -cne 'facebook/mms-tts-tur' -or
        $turkish.Revision -notmatch '^[a-f0-9]{40}$' -or
        $english.Language -cne 'en' -or
        $english.Model -cne 'facebook/mms-tts-eng' -or
        $english.Revision -cne
            'c71de0fe7204c83f1c10820a7d696d0b450048ba' -or
        $selected -cne 'English' -or
        [string]$fixture.Voice.Language -cne 'en' -or
        [string]$fixture.Voice.Model -cne $english.Model -or
        [string]$fixture.Voice.Revision -cne $english.Revision -or
        -not $profileImported -or
        [string]$sourceFixture.Voice.Language -cne 'en' -or
        [string]$sourceFixture.Voice.Model -cne $english.Model -or
        [string]$sourceFixture.Voice.Revision -cne $english.Revision -or
        $invalidImported -or
        [string]$rejectedFixture.Voice.Language -cne 'tr' -or
        $disabledImported -or
        [string]$disabledFixture.Voice.Language -cne 'tr' -or
        -not $voiceCacheReady -or -not $quickOpenWebUIReady -or
        -not $quickVoiceReady -or $probedVoicePaths.Count -ne 3 -or
        @($probedVoicePaths | Where-Object {
            -not $_.StartsWith(
                $voicePrefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        }).Count -gt 0 -or
        $source -notmatch "'0'\s*\{\s*'Exit'" -or
        $source -notmatch "default\s*\{\s*''") {
        throw 'Ses dili secim sozlesmesi gecersiz.'
    }
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.VoiceLanguageSelection'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.VoiceDeploymentCache'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:Installer.FeaturePreQuestionNoProcess'
    return $true
}