function Get-UninstallMenuItems {
    return @(
        [pscustomobject]@{
            Choice = '1'
            Text = Get-UninstallText -Key 'Uninstall.Menu.Full' `
                -Fallback '[1] Winlama bilesenlerini tamamen kaldir'
            Color = 'Red'
        },
        [pscustomobject]@{
            Choice = '2'
            Text = Get-UninstallText -Key 'Uninstall.Menu.ComfyUI' `
                -Fallback '[2] ComfyUI ve modellerini kaldir'
            Color = 'Magenta'
        },
        [pscustomobject]@{
            Choice = '3'
            Text = Get-UninstallText -Key 'Uninstall.Menu.WebUI' `
                -Fallback '[3] Open WebUI verilerini kaldir'
            Color = 'Cyan'
        },
        [pscustomobject]@{
            Choice = '4'
            Text = Get-UninstallText -Key 'Uninstall.Menu.Ollama' `
                -Fallback '[4] Ollama uygulamasini kaldir'
            Color = 'Yellow'
        },
        [pscustomobject]@{
            Choice = '5'
            Text = Get-UninstallText -Key 'Uninstall.Menu.DeveloperCli' `
                -Fallback '[5] Codex ve GitHub Copilot CLI kaldir'
            Color = 'Magenta'
        },
        [pscustomobject]@{
            Choice = '6'
            Text = Get-UninstallText -Key 'Uninstall.Menu.Models' `
                -Fallback '[6] Model yoneticisini ac'
            Color = 'Green'
        },
        [pscustomobject]@{
            Choice = '0'
            Text = Get-UninstallText -Key 'Uninstall.Menu.Back' `
                -Fallback '[0] Launcher menusune don'
            Color = 'Gray'
        }
    )
}
function Show-UninstallMenu {
    Write-UninstallBootstrapRule -Character '='
    Write-UninstallBootstrapLine `
        -Text (Get-UninstallText -Key 'Uninstall.Banner.Title' `
            -Fallback 'WINLAMA KALDIRMA YONETICISI') -Color Cyan
    Write-UninstallBootstrapLine `
        -Text (Get-UninstallText -Key 'Uninstall.Banner.Summary' `
            -Fallback ('Bilesenleri ayri ayri veya tamamen ' +
                'kaldirabilirsiniz')) `
        -Color Cyan
    Write-UninstallBootstrapRule -Character '='
    foreach ($item in @(Get-UninstallMenuItems)) {
        Write-UninstallBootstrapLine -Text $item.Text -Color $item.Color
    }
    Write-UninstallBootstrapRule
}
function Get-FullUninstallSelectionItems {
    return @(
        [pscustomobject]@{
            Index = 1
            Text = Get-UninstallText `
                -Key 'Uninstall.FullSelection.ComfyUI' `
                -Fallback '[1] ComfyUI ve ComfyUI modelleri'
            Color = 'Magenta'
        },
        [pscustomobject]@{
            Index = 2
            Text = Get-UninstallText `
                -Key 'Uninstall.FullSelection.WebUI' `
                -Fallback '[2] Open WebUI verileri ve ayarlari'
            Color = 'Cyan'
        },
        [pscustomobject]@{
            Index = 3
            Text = Get-UninstallText `
                -Key 'Uninstall.FullSelection.Ollama' `
                -Fallback '[3] Ollama uygulamasi'
            Color = 'Yellow'
        },
        [pscustomobject]@{
            Index = 4
            Text = Get-UninstallText `
                -Key 'Uninstall.FullSelection.OllamaModels' `
                -Fallback '[4] Ollama modelleri'
            Color = 'Green'
        },
        [pscustomobject]@{
            Index = 5
            Text = Get-UninstallText `
                -Key 'Uninstall.FullSelection.PythonLibraries' `
                -Fallback '[5] Winlama Python kutuphaneleri'
            Color = 'Cyan'
        },
        [pscustomobject]@{
            Index = 6
            Text = Get-UninstallText `
                -Key 'Uninstall.FullSelection.Python' `
                -Fallback '[6] Winlama Python 3.11'
            Color = 'Red'
        },
        [pscustomobject]@{
            Index = 7
            Text = Get-UninstallText `
                -Key 'Uninstall.FullSelection.DeveloperCli' `
                -Fallback '[7] Codex ve GitHub Copilot CLI'
            Color = 'Magenta'
        }
    )
}
function Show-FullUninstallSelection {
    Write-UninstallBootstrapRule
    Write-UninstallBootstrapLine `
        -Text (Get-UninstallText `
            -Key 'Uninstall.FullSelection.Title' `
            -Fallback 'Silinecek istege bagli bilesenleri secin:') `
        -Color Cyan
    foreach ($item in @(Get-FullUninstallSelectionItems)) {
        Write-UninstallBootstrapLine -Text $item.Text -Color $item.Color
    }
    Write-UninstallBootstrapLine -Text (Get-UninstallText `
        -Key 'Uninstall.FullSelection.Instruction' `
        -Fallback ('A tumunu secer. 1,2 secilenleri siler. ' +
            '-1,2 secilenleri korur. 0/S iptal eder.')) `
        -Color Yellow
    Write-UninstallBootstrapRule
}
function Read-FullUninstallSelection {
    param(
        [AllowNull()][string]$Value,
        [scriptblock]$InputReader
    )
    if ($PSBoundParameters.ContainsKey('Value')) {
        return Resolve-UninstallIndexSelection -Value $Value
    }
    Show-FullUninstallSelection
    while ($true) {
        $Value = Read-UninstallInput `
            -Prompt (Get-UninstallText `
                -Key 'Uninstall.FullSelection.SelectionPrompt' `
                -Fallback ('Bilesenleri secin. Bos giris reddedilir; ' +
                    'silme yalniz ikinci EVET onayiyla baslar.')) `
            -Label (Get-UninstallText `
                -Key 'Uninstall.FullSelection.Prompt' `
                -Fallback ('Se{0}iminiz' -f [char]0x00E7)) `
                -InputReader $InputReader
        try {
            return Resolve-UninstallIndexSelection -Value $Value
        }
        catch {
            Write-UninstallBootstrapStatus -Level WARN `
                -Message (Get-UninstallText `
                    -Key 'Uninstall.FullSelection.Invalid' `
                    -Fallback 'Gecersiz secim; yeniden deneyin.')
        }
    }
}