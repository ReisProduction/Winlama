Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertTo-WebUIHex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes)).Replace('-', '')
}
function Get-WebUIBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ConvertTo-WebUIHex -Bytes $algorithm.ComputeHash($Bytes)
    }
    finally {
        $algorithm.Dispose()
    }
}
function Get-OpenWebUIRootPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $path = [Environment]::ExpandEnvironmentVariables(
        $Context.Config.OpenWebUI.RootPath
    )
    return [IO.Path]::GetFullPath($path)
}
function Get-OpenWebUIDataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return Join-Path (Get-OpenWebUIRootPath -Context $Context) 'data'
}
function Get-OpenWebUIRuntimePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return Join-Path (Get-OpenWebUIRootPath -Context $Context) 'venv'
}
function Get-OpenWebUIPythonPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return Join-Path (Get-OpenWebUIRuntimePath -Context $Context) `
        'Scripts\python.exe'
}
function Get-OpenWebUIExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return Join-Path (Get-OpenWebUIRuntimePath -Context $Context) `
        'Scripts\open-webui.exe'
}
function Get-WinlamaPythonRuntimePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$OpenWebUIEnabled,
        [Parameter(Mandatory)][bool]$VoiceEnabled
    )
    return [pscustomobject][ordered]@{
        Required = $OpenWebUIEnabled -or $VoiceEnabled
        OpenWebUIExecutableRequired = $OpenWebUIEnabled
        VoiceProbeRequired = $VoiceEnabled
    }
}
function Set-WinlamaArrowSimdCompatibility {
    $avx2 = 'System.Runtime.Intrinsics.X86.Avx2' -as [type]
    if ($null -ne $avx2 -and -not $avx2::IsSupported -and
        [string]::IsNullOrWhiteSpace($env:ARROW_USER_SIMD_LEVEL)) {
        $env:ARROW_USER_SIMD_LEVEL = if ([System.Runtime.Intrinsics.X86.Sse42]::IsSupported) {
            'SSE4_2'
        }
        else {
            'NONE'
        }
    }
}
function Test-WinlamaVoiceSetupFailureOptional {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][bool]$OpenWebUICoreReady
    )
    $installation = $Context.Config.PSObject.Properties['Installation']
    $continueOnOptionalError = $null -ne $installation -and
        $null -ne $installation.Value.PSObject.Properties[
            'ContinueOnOptionalError'
        ] -and [bool]$installation.Value.ContinueOnOptionalError
    return [bool]$Context.Config.Voice.Enabled -and
        $continueOnOptionalError -and
        (-not [bool]$Context.Config.OpenWebUI.Enabled -or
            $OpenWebUICoreReady)
}
function Disable-WinlamaVoiceAfterSetupFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Reason
    )
    $Context.Config.Voice.Enabled = $false
    $configPath = Join-Path $Context.DataPath 'Configs\config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw [IO.FileNotFoundException]::new(
            "Etkin yapilandirma bulunamadi: $configPath"
        )
    }
    Write-AtomicTextFile -Path $configPath -Content (
        ConvertTo-StableJson -Value $Context.Config -Depth 100
    )
    Write-DeploymentLog -Context $Context -Level WARN `
        -Module WEBUI -Message 'Runtime.Component.Failed' `
        -MessageArguments @('Voice', $Reason) `
        -Recovery OPTIONAL_COMPONENT_DEGRADED
}
function Get-OpenWebUIHealthUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return 'http://{0}:{1}{2}' -f `
        $Context.Config.OpenWebUI.HealthHost,
        $Context.Config.OpenWebUI.Port,
        $Context.Config.OpenWebUI.HealthPath
}
function Get-OpenWebUIStartupShortcutPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    return Get-WinlamaStartupShortcutPath -Context $Context
}
function Get-OpenWebUIDefaultConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $configured = [Environment]::ExpandEnvironmentVariables(
        $Context.Config.OpenWebUI.DefaultConfig.Path
    )
    if ([IO.Path]::IsPathRooted($configured)) {
        return [IO.Path]::GetFullPath($configured)
    }
    $installedPath = [IO.Path]::GetFullPath(
        (Join-Path $Context.AppPath $configured)
    )
    if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
        return $installedPath
    }
    $packagePath = [IO.Path]::GetFullPath(
        (Join-Path $Context.PackageRoot $configured)
    )
    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        return $packagePath
    }
    return $installedPath
}
function Read-OpenWebUIDefaultConfigDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $document = ConvertFrom-WinlamaJson -Json $json
        if ($document -isnot [pscustomobject] -and
            $document -isnot [Collections.IDictionary]) {
            throw [IO.InvalidDataException]::new(
                (Get-LocalizedText `
                    -Key 'WebUI.Error.DefaultConfigObjectRequired')
            )
        }
        return $document
    }
    catch {
        throw (Get-LocalizedText `
            -Key 'WebUI.Error.DefaultConfigInvalid' `
            -Arguments @($Path, $_.Exception.Message))
    }
}
function Get-OpenWebUIFeatureProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $ollamaEnabled = [bool]$Context.Config.Ollama.Enabled
    $voiceEnabled = [bool]$Context.Config.Voice.Enabled
    $requestedModels = @($Context.Config.Models.Requested |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $defaultModels = if ($ollamaEnabled) {
        $requestedModels -join ','
    }
    else {
        ''
    }
    $voiceModel = if ($voiceEnabled) {
        [string]$Context.Config.Voice.Model
    }
    else {
        ''
    }
    $voiceLanguage = if ($voiceEnabled) {
        [string]$Context.Config.Voice.Language
    }
    else {
        ''
    }
    return [pscustomobject][ordered]@{
        OllamaEnabled = if ($ollamaEnabled) { 'True' } else { 'False' }
        OllamaBaseUrls = if ($ollamaEnabled) {
            ConvertTo-Json -InputObject @(
                'http://127.0.0.1:{0}' -f `
                    [int]$Context.Config.Ollama.Port
            ) -Compress
        }
        else {
            '[]'
        }
        OllamaApiConfigs = if ($ollamaEnabled) {
            '{"0":{"enable":True}}'
        }
        else {
            '{}'
        }
        OllamaRagBaseUrl = if ($ollamaEnabled) {
            ConvertTo-Json -InputObject (
                'http://127.0.0.1:{0}' -f `
                    [int]$Context.Config.Ollama.Port
            ) -Compress
        }
        else {
            '""'
        }
        DefaultModels = ConvertTo-Json -InputObject $defaultModels -Compress
        TtsEngine = if ($voiceEnabled) { '"openai"' } else { '""' }
        TtsModel = ConvertTo-Json -InputObject $voiceModel -Compress
        TtsVoice = ConvertTo-Json -InputObject $voiceLanguage -Compress
        TtsBaseUrl = if ($voiceEnabled) {
            ConvertTo-Json -InputObject (
                'http://127.0.0.1:{0}/v1' -f `
                    [int]$Context.Config.Voice.Port
            ) -Compress
        }
        else {
            '""'
        }
    }
}
function Get-OpenWebUIDefaultConfigurationHashMaterial {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceHash,
        [Parameter(Mandatory)][string]$WorkflowHash,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][bool]$ImageGenerationEnabled
    )
    $features = Get-OpenWebUIFeatureProjection -Context $Context
    $material = [ordered]@{
        SourceSha256 = $SourceHash
        WorkflowSha256 = $WorkflowHash
        EngineVersion = [string]$Context.Config.EngineVersion
        ImageGenerationEnabled = $ImageGenerationEnabled
        ComfyUIPort = [int]$Context.Config.ComfyUI.Port
        OllamaEnabled = $features.OllamaEnabled
        OllamaBaseUrls = $features.OllamaBaseUrls
        OllamaApiConfigs = $features.OllamaApiConfigs
        OllamaRagBaseUrl = $features.OllamaRagBaseUrl
        DefaultModels = $features.DefaultModels
        TtsEngine = $features.TtsEngine
        TtsModel = $features.TtsModel
        TtsVoice = $features.TtsVoice
        TtsBaseUrl = $features.TtsBaseUrl
        SttModel = 'whisper-base'
        SearchEngine = 'duckduckgo'
    }
    return ConvertTo-Json -InputObject $material -Compress -Depth 5
}
function Get-OpenWebUIPipInstallArguments {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )
    return @(
        '-m', 'pip', '--isolated', 'install',
        '--disable-pip-version-check', '--no-input',
        '--index-url', 'https://pypi.org/simple'
    ) + $Arguments
}
function Assert-OpenWebUIFeatureProjectionContracts {
    [CmdletBinding()]
    param()
    $context = [pscustomobject]@{
        Config = [pscustomobject]@{
            EngineVersion = '26.10.29'
            Ollama = [pscustomobject]@{
                Enabled = $false
                Port = 11434
            }
            Voice = [pscustomobject]@{
                Enabled = $false
                Port = 8880
                Language = 'tr'
                Model = 'facebook/mms-tts-tur'
            }
            ComfyUI = [pscustomobject]@{
                Port = 8188
            }
            OpenWebUI = [pscustomobject]@{
                Enabled = $false
            }
            Models = [pscustomobject]@{
                Requested = @('qwen3.5:4b')
            }
            Installation = [pscustomobject]@{
                ContinueOnOptionalError = $false
            }
        }
    }
    $pipArguments = @(Get-OpenWebUIPipInstallArguments `
        -Arguments @('--upgrade', 'fixture'))
    if (($pipArguments[0..3] -join '|') -cne
            '-m|pip|--isolated|install' -or
        'https://pypi.org/simple' -notin $pipArguments -or
        '--no-input' -notin $pipArguments -or
        ($pipArguments[-2..-1] -join '|') -cne
            '--upgrade|fixture') {
        throw 'Open WebUI yalitilmis pip kaynak sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:WebUI.PipSourcePolicy'
    $disabled = Get-OpenWebUIFeatureProjection `
        -Context $context
    if ($disabled.OllamaEnabled -cne 'False' -or
        $disabled.OllamaBaseUrls -cne '[]' -or
        $disabled.OllamaApiConfigs -cne '{}' -or
        $disabled.OllamaRagBaseUrl -cne '""' -or
        $disabled.DefaultModels -cne '""' -or
        $disabled.TtsEngine -cne '""' -or
        $disabled.TtsModel -cne '""' -or
        $disabled.TtsVoice -cne '""' -or
        $disabled.TtsBaseUrl -cne '""') {
        throw 'Devre disi Open WebUI ozellik projeksiyonu gecersiz.'
    }
    $context.Config.Ollama.Enabled = $true
    $context.Config.Voice.Enabled = $true
    $enabled = Get-OpenWebUIFeatureProjection -Context $context
    if ($enabled.OllamaEnabled -cne 'True' -or
        $enabled.OllamaBaseUrls -notlike '*127.0.0.1:11434*' -or
        $enabled.OllamaApiConfigs -notlike '*enable*:True*' -or
        $enabled.OllamaRagBaseUrl -notlike '*127.0.0.1:11434*' -or
        $enabled.DefaultModels -cne '"qwen3.5:4b"' -or
        $enabled.TtsEngine -cne '"openai"' -or
        $enabled.TtsModel -cne '"facebook/mms-tts-tur"' -or
        $enabled.TtsVoice -cne '"tr"' -or
        $enabled.TtsBaseUrl -notlike '*127.0.0.1:8880/v1*') {
        throw 'Etkin Open WebUI ozellik projeksiyonu gecersiz.'
    }
    $enabledMaterial = Get-OpenWebUIDefaultConfigurationHashMaterial `
        -SourceHash 'SOURCE' -WorkflowHash 'WORKFLOW' `
        -Context $context -ImageGenerationEnabled $true
    $context.Config.Models.Requested = @('gemma3:4b')
    $context.Config.Voice.Language = 'en'
    $context.Config.Voice.Model = 'validation/tts'
    $custom = Get-OpenWebUIFeatureProjection -Context $context
    $customMaterial = Get-OpenWebUIDefaultConfigurationHashMaterial `
        -SourceHash 'SOURCE' -WorkflowHash 'WORKFLOW' `
        -Context $context -ImageGenerationEnabled $true
    if ($custom.DefaultModels -cne '"gemma3:4b"' -or
        $custom.TtsModel -cne '"validation/tts"' -or
        $custom.TtsVoice -cne '"en"' -or
        $customMaterial -ceq $enabledMaterial) {
        throw 'Etkin Open WebUI model projeksiyonu gecersiz.'
    }
    $context.Config.Ollama.Enabled = $false
    $disabledMaterial = `
        Get-OpenWebUIDefaultConfigurationHashMaterial `
            -SourceHash 'SOURCE' -WorkflowHash 'WORKFLOW' `
            -Context $context -ImageGenerationEnabled $true
    if ($customMaterial -ceq $disabledMaterial -or
        $enabledMaterial -notlike '*"EngineVersion":"26.10.29"*') {
        throw 'Open WebUI yapilandirma hash malzemesi gecersiz.'
    }
    $context.Config.Voice.Enabled = $true
    $context.Config.Installation.ContinueOnOptionalError = $true
    if (-not (Test-WinlamaVoiceSetupFailureOptional `
            -Context $context -OpenWebUICoreReady $false)) {
        throw 'Voice-only opsiyonel kurulum hatasi devam etmiyor.'
    }
    $context.Config.OpenWebUI.Enabled = $true
    if ((Test-WinlamaVoiceSetupFailureOptional `
            -Context $context -OpenWebUICoreReady $false) -or
        -not (Test-WinlamaVoiceSetupFailureOptional `
            -Context $context -OpenWebUICoreReady $true)) {
        throw 'Open WebUI cekirdek ve Voice hata ayrimi gecersiz.'
    }
    $context.Config.Installation.ContinueOnOptionalError = $false
    if (Test-WinlamaVoiceSetupFailureOptional `
        -Context $context -OpenWebUICoreReady $true) {
        throw 'Kati Voice kurulum hatasi yanlislikla atlandi.'
    }
    $disabledPlan = Get-WinlamaPythonRuntimePlan `
        -OpenWebUIEnabled $false -VoiceEnabled $false
    $voiceOnlyPlan = Get-WinlamaPythonRuntimePlan `
        -OpenWebUIEnabled $false -VoiceEnabled $true
    $webOnlyPlan = Get-WinlamaPythonRuntimePlan `
        -OpenWebUIEnabled $true -VoiceEnabled $false
    $combinedPlan = Get-WinlamaPythonRuntimePlan `
        -OpenWebUIEnabled $true -VoiceEnabled $true
    $installSource = (Get-Command Install-OpenWebUI `
        -ErrorAction Stop).Definition
    $testSource = (Get-Command Test-OpenWebUIInstallation `
        -ErrorAction Stop).Definition
    if ($disabledPlan.Required -or
        -not $voiceOnlyPlan.Required -or
        $voiceOnlyPlan.OpenWebUIExecutableRequired -or
        -not $voiceOnlyPlan.VoiceProbeRequired -or
        -not $webOnlyPlan.Required -or
        -not $webOnlyPlan.OpenWebUIExecutableRequired -or
        $webOnlyPlan.VoiceProbeRequired -or
        -not $combinedPlan.Required -or
        -not $combinedPlan.OpenWebUIExecutableRequired -or
        -not $combinedPlan.VoiceProbeRequired -or
        $installSource -notmatch 'Test-WinlamaVoicePythonRuntime' -or
        $testSource -notmatch 'Test-WinlamaVoicePythonRuntime') {
        throw 'Ses ve Open WebUI ortak Python runtime sozlesmesi gecersiz.'
    }
    Write-Verbose 'WINLAMA_VALIDATION_OK:OpenWebUI.VoiceOnlyRuntime'
    Write-Verbose 'WINLAMA_VALIDATION_OK:OpenWebUI.VoiceFailurePolicy'
    Write-Verbose `
        'WINLAMA_VALIDATION_OK:OpenWebUI.FeatureProjection'
}
function Get-OpenWebUIDefaultConfigurationHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$Context
    )
    $sourceHash = (Get-FileHash -LiteralPath $Path `
        -Algorithm SHA256).Hash
    $workflowPath = Get-OpenWebUIImageWorkflowPath `
        -Context $Context
    $workflowHash = (Get-FileHash -LiteralPath $workflowPath `
        -Algorithm SHA256).Hash
    $imageGenerationEnabled = $Context.Config.ComfyUI.Enabled -and
        'FLUX.1-schnell' -iin @($Context.Config.ComfyUI.Requested)
    $material = Get-OpenWebUIDefaultConfigurationHashMaterial `
        -SourceHash $sourceHash -WorkflowHash $workflowHash `
        -Context $Context `
        -ImageGenerationEnabled $imageGenerationEnabled
    return Get-WebUIBytesSha256 `
        -Bytes ([Text.Encoding]::UTF8.GetBytes($material))
}
function Get-OpenWebUIImageWorkflowPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    foreach ($root in @(
        $Context.PackageRoot,
        $Context.AppPath
    )) {
        $path = Join-Path $root `
            'Data\Workflows\Flux1_Schnell_API.json'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return [IO.Path]::GetFullPath($path)
        }
    }
    throw 'Open WebUI ComfyUI API workflow bulunamadi.'
}
function Test-OpenWebUIDefaultConfigurationPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.OpenWebUI.Enabled -or
        -not $Context.Config.OpenWebUI.DefaultConfig.ApplyOnFirstStart) {
        return $false
    }
    $configPath = Get-OpenWebUIDefaultConfigPath -Context $Context
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $false
    }
    $hash = Get-OpenWebUIDefaultConfigurationHash `
        -Path $configPath -Context $Context
    $runtimePath = Join-Path (Get-OpenWebUIRootPath -Context $Context) `
        'runtime.json'
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        return $true
    }
    try {
        $runtime = Read-JsonFile -Path $runtimePath
        return $null -eq $runtime.PSObject.Properties[
            'DefaultConfigSha256'
        ] -or $runtime.DefaultConfigSha256 -ne $hash
    }
    catch {
        Write-Verbose ('Open WebUI varsayilan ayar durumu okunamadi: {0}' `
            -f $_.Exception.Message)
        return $true
    }
}
function Import-OpenWebUIDefaultConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $Context.Config.OpenWebUI.DefaultConfig.ApplyOnFirstStart) {
        return $false
    }
    $configPath = Get-OpenWebUIDefaultConfigPath -Context $Context
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module WEBUI -Message 'WebUI.DefaultConfig.Missing' `
            -MessageArguments @($configPath)
        return $false
    }
    if (-not (Test-OpenWebUIDefaultConfigurationPending `
        -Context $Context)) {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI -Message 'WebUI.DefaultConfig.AlreadyApplied'
        return $false
    }
    $null = Read-OpenWebUIDefaultConfigDocument -Path $configPath
    $workflowPath = Get-OpenWebUIImageWorkflowPath `
        -Context $Context
    $imageModelReady = $Context.Config.ComfyUI.Enabled -and
        'FLUX.1-schnell' -iin @($Context.Config.ComfyUI.Requested)
    $imageGenerationEnabled = if ($imageModelReady) {
        'True'
    }
    else {
        'False'
    }
    $features = Get-OpenWebUIFeatureProjection -Context $Context
    $command = @(
        'import asyncio,json,sys',
        'from open_webui.models.config import Config',
        'with open(sys.argv[1],"r",encoding="utf-8-sig") as f:',
        '    data=json.load(f)',
        'if set(data)=={"config"} and isinstance(data["config"],dict):',
        '    data=data["config"]',
        'assert isinstance(data,dict)',
        'assert all(isinstance(k,str) and k for k in data)',
        'with open(sys.argv[2],"r",encoding="utf-8-sig") as f:',
        '    image_workflow=json.load(f)',
        'assert isinstance(image_workflow,dict)',
        'data["direct.enable"]=False',
        ('data["ollama.enable"]={0}' -f $features.OllamaEnabled),
        ('data["ollama.base_urls"]={0}' -f `
            $features.OllamaBaseUrls),
        ('data["ollama.api_configs"]={0}' -f `
            $features.OllamaApiConfigs),
        ('data["rag.ollama.base_url"]={0}' -f `
            $features.OllamaRagBaseUrl),
        'data["openai.enable"]=False',
        'data["ui.enable_signup"]=True',
        'data["ui.enable_community_sharing"]=False',
        'data["ui.default_user_role"]="pending"',
        'data["auth.enable_api_keys"]=False',
        'data["user.permissions.chat.temporary"]=True',
        'data["user.permissions.chat.temporary_enforced"]=True',
        ('data["ui.default_models"]={0}' -f `
            $features.DefaultModels),
        ('data["ui.default_pinned_models"]={0}' -f `
            $features.DefaultModels),
        'data["audio.stt.engine"]=""',
        'data["audio.stt.model"]=""',
        'data["audio.stt.whisper_model"]="base"',
        'data["audio.stt.supported_content_types"]=[]',
        ('data["audio.stt.allowed_extensions"]=[' +
            '"mp3","wav","m4a","webm","ogg",' +
            '"flac","mp4","mpga","mpeg"]'),
        ('data["audio.tts.engine"]={0}' -f $features.TtsEngine),
        ('data["audio.tts.model"]={0}' -f $features.TtsModel),
        ('data["audio.tts.voice"]={0}' -f $features.TtsVoice),
        ('data["audio.tts.openai.api_base_url"]={0}' -f `
            $features.TtsBaseUrl),
        'data["audio.tts.openai.api_key"]=""',
        'data["web.search.enable"]=True',
        'data["web.search.engine"]="duckduckgo"',
        'data["web.search.result_count"]=3',
        ('data["image_generation.enable"]={0}' -f `
            $imageGenerationEnabled),
        'data["image_generation.engine"]="comfyui"',
        'data["image_generation.model"]="flux1-schnell-fp8.safetensors"',
        'data["image_generation.size"]="512x512"',
        'data["image_generation.steps"]=4',
        ('data["image_generation.comfyui.base_url"]=' +
            '"http://127.0.0.1:{0}"' -f `
            [int]$Context.Config.ComfyUI.Port),
        ('data["image_generation.comfyui.workflow"]=' +
            'json.dumps(image_workflow,separators=(",",":"))'),
        'data["image_generation.comfyui.nodes"]=[' +
            '{"type":"model","node_ids":["1"],' +
                '"key":"ckpt_name"},' +
            '{"type":"prompt","node_ids":["2"],' +
                '"key":"text"},' +
            '{"type":"width","node_ids":["4"],' +
                '"key":"width"},' +
            '{"type":"height","node_ids":["4"],' +
                '"key":"height"},' +
            '{"type":"n","node_ids":["4"],' +
                '"key":"batch_size"},' +
            '{"type":"steps","node_ids":["5"],' +
                '"key":"steps"},' +
            '{"type":"seed","node_ids":["5"],' +
                '"key":"seed"}' +
        ']',
        'data["images.edit.enable"]=False',
        'data["images.edit.engine"]=""',
        'data["images.edit.model"]=""',
        'data["images.edit.comfyui.workflow"]=""',
        'data["images.edit.comfyui.nodes"]=[]',
        'asyncio.run(Config.upsert(data))',
        'print("WINLAMA_OPENWEBUI_CONFIG_IMPORTED="+str(len(data)))'
    ) -join "`n"
    $python = Get-OpenWebUIPythonPath -Context $Context
    $result = Invoke-ExternalProcess -FilePath $python `
        -ArgumentList @(
            '-I', '-c', $command, $configPath, $workflowPath
        ) `
        -TimeoutSeconds $Context.Config.Network.OperationTimeoutSeconds `
        -Activity (Get-LocalizedText `
            -Key 'WebUI.Process.DefaultConfigImport')
    $match = [regex]::Match(
        $result.StandardOutput,
        '(?m)^WINLAMA_OPENWEBUI_CONFIG_IMPORTED=(?<Count>\d+)\s*$'
    )
    if (-not $match.Success) {
        throw (Get-LocalizedText `
            -Key 'WebUI.Error.DefaultConfigImportUnverified')
    }
    $hash = Get-OpenWebUIDefaultConfigurationHash `
        -Path $configPath -Context $Context
    $runtimePath = Join-Path (Get-OpenWebUIRootPath -Context $Context) `
        'runtime.json'
    $runtime = if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
        Read-JsonFile -Path $runtimePath
    }
    else {
        [pscustomobject]@{}
    }
    $runtime | Add-Member -NotePropertyName DefaultConfigSha256 `
        -NotePropertyValue $hash -Force
    $runtime | Add-Member -NotePropertyName DefaultConfigAppliedAt `
        -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('O')) -Force
    $runtime | Add-Member -NotePropertyName DefaultConfigKeyCount `
        -NotePropertyValue ([int]$match.Groups['Count'].Value) -Force
    Write-AtomicTextFile -Path $runtimePath `
        -Content (ConvertTo-StableJson -Value $runtime -Depth 20)
    Write-DeploymentLog -Context $Context -Level OK `
        -Module WEBUI -Message 'WebUI.DefaultConfig.Imported' `
        -MessageArguments @(
            $configPath,
            [int]$match.Groups['Count'].Value
        )
    return $true
}
function Get-OpenWebUIPythonIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $command = 'import json,sys;' +
        'print("WINLAMA_PYTHON_IDENTITY="+' +
        'json.dumps({' +
        '"executable":sys.executable,' +
        '"prefix":sys.prefix,' +
        '"base_prefix":sys.base_prefix,' +
        '"version":list(sys.version_info[:3])},' +
        'separators=(",",":")))'
    try {
        $result = Invoke-ExternalProcess -FilePath $Path `
            -ArgumentList @('-I', '-c', $command) -TimeoutSeconds 30 `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.PythonCheck')
        $match = [regex]::Match(
            $result.StandardOutput,
            '(?m)^WINLAMA_PYTHON_IDENTITY=(?<Json>\{.+\})\s*$'
        )
        if (-not $match.Success) {
            return $null
        }
        return ConvertFrom-WinlamaJson -Json $match.Groups['Json'].Value
    }
    catch {
        Write-Verbose ('Open WebUI Python kimligi okunamadi: {0} | {1}' `
            -f $Path, $_.Exception.Message)
        return $null
    }
}
function Test-OpenWebUIPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $identity = Get-OpenWebUIPythonIdentity -Path $Path
    if ($null -eq $identity -or @($identity.version).Count -ne 3) {
        return $false
    }
    try {
        $expectedExecutable = [IO.Path]::GetFullPath($Path)
        $actualExecutable = [IO.Path]::GetFullPath(
            [string]$identity.executable
        )
        $expectedPrefix = [IO.Path]::GetFullPath(
            (Get-OpenWebUIRuntimePath -Context $Context)
        )
        $actualPrefix = [IO.Path]::GetFullPath([string]$identity.prefix)
        $executableMatches = [string]::Equals($expectedExecutable, $actualExecutable, [StringComparison]::OrdinalIgnoreCase) -or
            $actualExecutable.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)
        $prefixMatches = [string]::Equals($expectedPrefix, $actualPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $actualPrefix.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)
        if (-not $executableMatches -or -not $prefixMatches -or
            [string]::Equals(
                [string]$identity.prefix,
                [string]$identity.base_prefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            return $false
        }
        $version = [version]('{0}.{1}.{2}' -f @($identity.version))
        $dependency = $Context.Config.Dependencies |
            Where-Object Name -eq 'Python' |
            Select-Object -First 1
        $maximum = [version]$dependency.MaximumVersionExclusive
        return $version -ge [version]$dependency.MinimumVersion -and
            $version -lt $maximum
    }
    catch {
        Write-Verbose ('Open WebUI Python ortami denetlenemedi: {0} | {1}' `
            -f $Path, $_.Exception.Message)
        return $false
    }
}
function Get-OpenWebUIInstalledVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PythonPath
    )
    $command = 'import importlib.metadata as m,importlib.util as u;' +
        'assert u.find_spec("open_webui") is not None;' +
        'print("WINLAMA_OPENWEBUI="+m.version("open-webui"))'
    try {
        $result = Invoke-ExternalProcess -FilePath $PythonPath `
            -ArgumentList @('-I', '-c', $command) -TimeoutSeconds 60 `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.PackageCheck')
        $match = [regex]::Match(
            $result.StandardOutput,
            '(?m)^WINLAMA_OPENWEBUI=(?<Version>[^\s]+)\s*$'
        )
        if ($match.Success) {
            return $match.Groups['Version'].Value
        }
        return ''
    }
    catch {
        Write-Verbose ('Open WebUI paket surumu okunamadi: {0} | {1}' `
            -f $PythonPath, $_.Exception.Message)
        return ''
    }
}
function Test-OpenWebUIExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$PythonPath
    )
    $executable = Get-OpenWebUIExecutablePath -Context $Context
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return $false
    }
    $command = 'import importlib.metadata as m;' +
        'd=m.distribution("open-webui");' +
        'e=next((e for e in d.entry_points ' +
        'if e.group=="console_scripts" and e.name=="open-webui"),None);' +
        'assert e is not None;' +
        'print("WINLAMA_OPENWEBUI_ENTRYPOINT="+e.value)'
    try {
        $result = Invoke-ExternalProcess -FilePath $PythonPath `
            -ArgumentList @('-I', '-c', $command) -TimeoutSeconds 60 `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.ExecutableCheck')
        return [regex]::IsMatch(
            $result.StandardOutput,
            '(?m)^WINLAMA_OPENWEBUI_ENTRYPOINT=\S+\s*$'
        )
    }
    catch {
        Write-Verbose ('Open WebUI calistiricisi denetlenemedi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function Test-WinlamaVoicePythonRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [string]$PythonPath = ''
    )
    if (-not $Context.Config.Voice.Enabled) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($PythonPath)) {
        $PythonPath = Get-OpenWebUIPythonPath -Context $Context
    }
    $server = Join-Path $Context.AppPath 'Services\TtsServer.py'
    if (-not (Test-OpenWebUIPython -Path $PythonPath `
        -Context $Context) -or
        -not (Test-Path -LiteralPath $server -PathType Leaf)) {
        return $false
    }
    Set-WinlamaArrowSimdCompatibility
    try {
        $null = Invoke-ExternalProcess -FilePath $PythonPath `
            -ArgumentList @('-I', $server, '--help') `
            -TimeoutSeconds 120 `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.VoiceRuntimeCheck')
        return $true
    }
    catch {
        Write-Verbose ('Ses Python runtime denetimi basarisiz: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
function New-WebUISecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $rootPath = Get-OpenWebUIRootPath -Context $Context
    [IO.Directory]::CreateDirectory($rootPath) | Out-Null
    $secretPath = Join-Path $rootPath 'webui.secret'
    if (Test-Path -LiteralPath $secretPath) {
        $secret = Get-Content -LiteralPath $secretPath -Raw `
            -Encoding UTF8
    }
    else {
        $bytes = [byte[]]::new(32)
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $generator.GetBytes($bytes)
        }
        finally {
            $generator.Dispose()
        }
        $secret = ConvertTo-WebUIHex -Bytes $bytes
        Write-AtomicTextFile -Path $secretPath -Content $secret
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        $userSid = $identity.User.Value
        $null = Invoke-ExternalProcess -FilePath $icacls `
            -ArgumentList @(
                $secretPath, '/inheritance:r',
                '/grant:r', '*S-1-5-18:F',
                '/grant:r', '*S-1-5-32-544:F',
                '/grant:r', "*$userSid`:F"
            ) -TimeoutSeconds 30 `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.SecretAcl')
    }
    return $secret
}
function Install-OpenWebUIStartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    try {
        return Install-WinlamaStartupShortcut -Context $Context
    }
    catch {
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module WEBUI -Message 'WebUI.StartupShortcut.CreateFailed' `
            -Exception $_.Exception
        return $null
    }
}
function Test-OpenWebUIStartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not (Test-WinlamaStartupShortcut -Context $Context)) {
        try {
            $null = Install-WinlamaStartupShortcut -Context $Context `
                -ErrorAction SilentlyContinue
        }
        catch {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module WEBUI `
                -Message 'WebUI.StartupShortcut.RepairFailed' `
                -MessageArguments @($_.Exception.Message)
        }
    }
    return Test-WinlamaStartupShortcut -Context $Context
}
function Stop-OpenWebUIRuntimeForUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    Stop-ProcessesFromPath `
        -RootPath (Get-OpenWebUIRuntimePath -Context $Context) `
        -TimeoutSeconds $Context.Config.Runtime.ShutdownTimeoutSeconds
}
function Remove-OpenWebUIRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $runtimePath = Get-OpenWebUIRuntimePath -Context $Context
    if (-not (Test-Path -LiteralPath $runtimePath)) {
        return
    }
    $prefix = [IO.Path]::GetFullPath($runtimePath).TrimEnd('\') + '\'
    foreach ($process in @(
        Get-CimInstance -ClassName Win32_Process `
            -ErrorAction SilentlyContinue | Where-Object {
                $executablePath = [string]$_.ExecutablePath
                -not [string]::IsNullOrWhiteSpace($executablePath) -and
                    [IO.Path]::GetFullPath($executablePath).StartsWith(
                    $prefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )) {
        Stop-Process -Id $process.ProcessId -Force `
            -ErrorAction SilentlyContinue
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -LiteralPath $runtimePath -Recurse -Force `
            -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $runtimePath)) {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module WEBUI `
                -Message 'WebUI.Python.IncompatibleRemoved'
            return
        }
        Start-Sleep -Milliseconds (250 * $attempt)
    }
    throw (Get-LocalizedText -Key 'WebUI.Error.RuntimeRepairFailed' `
        -Arguments @($runtimePath))
}
function Install-OpenWebUI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $runtimePlan = Get-WinlamaPythonRuntimePlan `
        -OpenWebUIEnabled ([bool]$Context.Config.OpenWebUI.Enabled) `
        -VoiceEnabled ([bool]$Context.Config.Voice.Enabled)
    if (-not $runtimePlan.Required) {
        return
    }
    $dependency = $Context.Config.Dependencies |
        Where-Object Name -eq 'Python' |
        Select-Object -First 1
    $python = Get-DependencyExecutable -Dependency $dependency `
        -Context $Context
    if ($null -eq $python -or
        -not (Test-Dependency -Dependency $dependency `
            -Context $Context)) {
        throw (Get-LocalizedText `
            -Key 'WebUI.Error.PythonIncompatible')
    }
    $rootPath = Get-OpenWebUIRootPath -Context $Context
    [IO.Directory]::CreateDirectory($rootPath) | Out-Null
    if ($runtimePlan.OpenWebUIExecutableRequired) {
        $defaultConfigPath = Get-OpenWebUIDefaultConfigPath `
            -Context $Context
        if (Test-Path -LiteralPath $defaultConfigPath -PathType Leaf) {
            $null = Read-OpenWebUIDefaultConfigDocument `
                -Path $defaultConfigPath
            Write-DeploymentLog -Context $Context -Level INFO `
                -Module WEBUI -Message 'WebUI.DefaultConfig.Detected' `
                -MessageArguments @($defaultConfigPath)
        }
        else {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module WEBUI -Message 'WebUI.DefaultConfig.Missing' `
                -MessageArguments @($defaultConfigPath)
        }
    }
    $runtimePath = Get-OpenWebUIRuntimePath -Context $Context
    $venvPython = Get-OpenWebUIPythonPath -Context $Context
    $existingPythonValid = Test-OpenWebUIPython `
        -Path $venvPython -Context $Context
    $existingVersion = if ($existingPythonValid) {
        Get-OpenWebUIInstalledVersion -PythonPath $venvPython
    }
    else {
        ''
    }
    $existingExecutableValid = $existingPythonValid -and
        $runtimePlan.OpenWebUIExecutableRequired -and
        $existingVersion -ceq [string]$Context.Config.OpenWebUI.Version -and
        (Test-OpenWebUIExecutable -Context $Context `
            -PythonPath $venvPython)
    $existingVoiceValid = $existingPythonValid -and
        $runtimePlan.VoiceProbeRequired -and
        (Test-WinlamaVoicePythonRuntime -Context $Context `
            -PythonPath $venvPython)
    $runtimeMutationRequired = -not $existingPythonValid -or
        ($runtimePlan.OpenWebUIExecutableRequired -and
            -not $existingExecutableValid) -or
        ($runtimePlan.VoiceProbeRequired -and
            -not $existingVoiceValid)
    if ($runtimeMutationRequired) {
        Stop-OpenWebUIRuntimeForUpdate -Context $Context
    }
    $createdVenv = $false
    if ((Test-Path -LiteralPath $runtimePath) -and
        -not (Test-OpenWebUIPython -Path $venvPython -Context $Context)) {
        Remove-OpenWebUIRuntime -Context $Context
    }
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI -Message 'WebUI.Venv.Creating'
        $null = Invoke-ExternalProcess -FilePath $python `
            -ArgumentList @('-m', 'venv', $runtimePath) `
            -TimeoutSeconds 300 `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.VenvCreate')
        $createdVenv = $true
    }
    if (-not (Test-OpenWebUIPython -Path $venvPython `
        -Context $Context)) {
        throw (Get-LocalizedText -Key 'WebUI.Error.VenvInvalid')
    }
    $version = $Context.Config.OpenWebUI.Version
    $installedVersion = ''
    $executableValid = $false
    if (-not $createdVenv) {
        $installedVersion = Get-OpenWebUIInstalledVersion `
            -PythonPath $venvPython
        if ($installedVersion -eq $version -and
            $runtimePlan.OpenWebUIExecutableRequired) {
            $executableValid = Test-OpenWebUIExecutable `
                -Context $Context -PythonPath $venvPython
        }
    }
    if ($createdVenv) {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI -Message 'WebUI.PythonTools.Updating'
        $tooling = Invoke-ExternalProcess -FilePath $venvPython `
            -ArgumentList (Get-OpenWebUIPipInstallArguments `
                -Arguments @(
                    '--upgrade', 'pip', 'setuptools', 'wheel'
                )) `
            -TimeoutSeconds `
                $Context.Config.Network.DownloadTimeoutSeconds `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.PythonTools')
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI `
            -Message 'WebUI.PythonTools.Ready' `
            -MessageArguments @($tooling.Duration)
    }
    if ($installedVersion -ne $version) {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI -Message 'WebUI.Installing' `
            -MessageArguments @($version)
        $installation = Invoke-ExternalProcess `
            -FilePath $venvPython `
            -ArgumentList (Get-OpenWebUIPipInstallArguments `
                -Arguments @(
                    '--upgrade', '--prefer-binary',
                    "open-webui==$version"
                )) `
            -TimeoutSeconds `
                $Context.Config.Network.DownloadTimeoutSeconds `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.PackageInstall' `
                -Arguments @($version))
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI `
            -Message 'WebUI.InstallCompleted' `
            -MessageArguments @($installation.Duration)
    }
    elseif ($runtimePlan.OpenWebUIExecutableRequired -and
        -not $executableValid) {
        Write-DeploymentLog -Context $Context -Level WARN `
            -Module WEBUI -Message 'WebUI.ExecutableRepairing' `
            -MessageArguments @($version)
        $repair = Invoke-ExternalProcess -FilePath $venvPython `
            -ArgumentList (Get-OpenWebUIPipInstallArguments `
                -Arguments @(
                    '--force-reinstall', '--no-deps',
                    "open-webui==$version"
                )) `
            -TimeoutSeconds `
                $Context.Config.Network.DownloadTimeoutSeconds `
            -Activity (Get-LocalizedText `
                -Key 'WebUI.Process.ExecutableRepair' `
                -Arguments @($version))
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI -Message 'WebUI.ExecutableRepaired' `
            -MessageArguments @($repair.Duration)
    }
    else {
        Write-DeploymentLog -Context $Context -Level INFO `
            -Module WEBUI -Message 'WebUI.InstallSkipped' `
            -MessageArguments @($version)
    }
    $verifiedVersion = Get-OpenWebUIInstalledVersion `
        -PythonPath $venvPython
    if ($verifiedVersion -cne [string]$version) {
        throw (Get-LocalizedText -Key 'WebUI.Error.PackageVersionInvalid' `
            -Arguments @($version, $verifiedVersion))
    }
    if ($runtimePlan.VoiceProbeRequired -and
        -not (Test-WinlamaVoicePythonRuntime -Context $Context `
            -PythonPath $venvPython)) {
        $voiceError = Get-LocalizedText `
            -Key 'WebUI.Error.VoiceRuntimeInvalid'
        if (Test-WinlamaVoiceSetupFailureOptional `
            -Context $Context -OpenWebUICoreReady $true) {
            Disable-WinlamaVoiceAfterSetupFailure `
                -Context $Context -Reason $voiceError
            $runtimePlan = Get-WinlamaPythonRuntimePlan `
                -OpenWebUIEnabled (
                    [bool]$Context.Config.OpenWebUI.Enabled
                ) -VoiceEnabled $false
        }
        else {
            throw $voiceError
        }
    }
    if ($runtimePlan.OpenWebUIExecutableRequired -and
        -not (Test-OpenWebUIExecutable -Context $Context `
            -PythonPath $venvPython)) {
        throw (Get-LocalizedText -Key 'WebUI.Error.ExecutableInvalid' `
            -Arguments @(
                (Get-OpenWebUIExecutablePath -Context $Context)
            ))
    }
    if (-not $runtimePlan.OpenWebUIExecutableRequired) {
        Write-DeploymentLog -Context $Context -Level OK `
            -Module WEBUI -Message 'WebUI.VoiceRuntime.Ready' `
            -MessageArguments @($version)
        return
    }
    $dataPath = Get-OpenWebUIDataPath -Context $Context
    foreach ($path in @(
        $dataPath,
        (Join-Path $dataPath 'cache'),
        (Join-Path $dataPath 'home'),
        (Join-Path $dataPath 'temp')
    )) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    $secret = New-WebUISecret -Context $Context
    $startupShortcut = Get-WinlamaStartupShortcutPath -Context $Context
    $runtime = [pscustomobject][ordered]@{
        Python = $venvPython
        Executable = Get-OpenWebUIExecutablePath -Context $Context
        PythonIdentity = Get-OpenWebUIPythonIdentity -Path $venvPython
        DataPath = $dataPath
        Host = $Context.Config.OpenWebUI.Host
        HealthHost = $Context.Config.OpenWebUI.HealthHost
        Port = $Context.Config.OpenWebUI.Port
        HealthUri = Get-OpenWebUIHealthUri -Context $Context
        Version = $version
        StartupShortcut = $startupShortcut
        RootPath = $rootPath
        SecretPath = Join-Path $rootPath 'webui.secret'
        SecretSha256 = Get-WebUIBytesSha256 `
            -Bytes ([Text.Encoding]::UTF8.GetBytes($secret))
    }
    $path = Join-Path $rootPath 'runtime.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $previousRuntime = Read-JsonFile -Path $path
            foreach ($name in @(
                'DefaultConfigSha256',
                'DefaultConfigAppliedAt',
                'DefaultConfigKeyCount'
            )) {
                if ($null -ne $previousRuntime.PSObject.Properties[$name]) {
                    $runtime | Add-Member -NotePropertyName $name `
                        -NotePropertyValue $previousRuntime.$name -Force
                }
            }
        }
        catch {
            Write-DeploymentLog -Context $Context -Level WARN `
                -Module WEBUI `
                -Message 'WebUI.RuntimeState.RestoreFailed' `
                -MessageArguments @($_.Exception.Message)
        }
    }
    Write-AtomicTextFile -Path $path `
        -Content (ConvertTo-StableJson -Value $runtime -Depth 10)
    Write-DeploymentLog -Context $Context -Level INFO `
        -Module WEBUI `
        -Message 'WebUI.Ready' -MessageArguments @($version)
}
function Install-OpenWebUIWithOptionalVoicePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context
    )
    try {
        Install-OpenWebUI -Context $Context
    }
    catch {
        if (-not (Test-WinlamaVoiceSetupFailureOptional `
            -Context $Context -OpenWebUICoreReady $false)) {
            throw
        }
        try {
            Remove-OpenWebUIRuntime -Context $Context
        }
        catch {
            Write-Verbose ('Basarisiz ses ortami temizlenemedi: {0}' -f `
                $_.Exception.Message)
        }
        Disable-WinlamaVoiceAfterSetupFailure -Context $Context `
            -Reason $_.Exception.Message
    }
}
function Test-OpenWebUIInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $runtimePlan = Get-WinlamaPythonRuntimePlan `
        -OpenWebUIEnabled ([bool]$Context.Config.OpenWebUI.Enabled) `
        -VoiceEnabled ([bool]$Context.Config.Voice.Enabled)
    if (-not $runtimePlan.Required) {
        return $true
    }
    $python = Get-OpenWebUIPythonPath -Context $Context
    if (-not (Test-OpenWebUIPython -Path $python -Context $Context)) {
        return $false
    }
    try {
        $version = Get-OpenWebUIInstalledVersion `
            -PythonPath $python
        if ($version -ne $Context.Config.OpenWebUI.Version) {
            return $false
        }
        if ($runtimePlan.VoiceProbeRequired -and
            -not (Test-WinlamaVoicePythonRuntime -Context $Context `
                -PythonPath $python)) {
            return $false
        }
        if ($runtimePlan.OpenWebUIExecutableRequired -and
            -not (Test-OpenWebUIExecutable -Context $Context `
            -PythonPath $python)) {
            return $false
        }
        return $true
    }
    catch {
        Write-Verbose ('Open WebUI kurulumu denetlenemedi: {0}' -f `
            $_.Exception.Message)
        return $false
    }
}
Export-ModuleMember -Function @(
    'Get-OpenWebUIRootPath', 'Get-OpenWebUIDataPath',
    'Get-OpenWebUIRuntimePath', 'Get-OpenWebUIPythonPath',
    'Get-OpenWebUIExecutablePath',
    'Set-WinlamaArrowSimdCompatibility',
    'Get-OpenWebUIHealthUri', 'Get-OpenWebUIStartupShortcutPath',
    'Get-OpenWebUIDefaultConfigPath',
    'Read-OpenWebUIDefaultConfigDocument',
    'Get-OpenWebUIFeatureProjection',
    'Get-OpenWebUIDefaultConfigurationHashMaterial',
    'Assert-OpenWebUIFeatureProjectionContracts',
    'Get-OpenWebUIDefaultConfigurationHash',
    'Test-OpenWebUIDefaultConfigurationPending',
    'Import-OpenWebUIDefaultConfiguration',
    'Get-OpenWebUIPythonIdentity', 'Test-OpenWebUIPython',
    'Get-OpenWebUIInstalledVersion',
    'Test-OpenWebUIExecutable',
    'New-WebUISecret',
    'Remove-OpenWebUIRuntime',
    'Install-OpenWebUIStartupShortcut',
    'Test-OpenWebUIStartupShortcut', 'Install-OpenWebUI',
    'Install-OpenWebUIWithOptionalVoicePolicy',
    'Test-WinlamaVoiceSetupFailureOptional',
    'Test-OpenWebUIInstallation'
)