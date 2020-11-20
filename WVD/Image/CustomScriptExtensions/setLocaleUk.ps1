# Set variables
$PrimaryLanguage = "en-GB"
$filePath = "C:\Windows\Temp\setLocaleUk"
$LangPackName = "en-GB\LanguageExperiencePack.en-GB.Neutral.appx"
$LangPackPath = Join-Path $filePath $LangPackName
$LicenseName = "en-GB\License.xml"
$LicensePath = Join-Path $filePath $LicenseName


# Provision Local Experience Pack
try{
    Write-Output "Adding en-GB Language Pack"
    Add-AppxProvisionedPackage -Online -PackagePath $LangPackPath -LicensePath $LicensePath
}
catch{
    Write-Output "Error - Couldnt install AppXPackage" -ErrorAction Stop
}

# Install optional features for primary language
$UKCapabilities = Get-WindowsCapability -Online | Where-Object {$_.Name -match "$PrimaryLanguage" -and $_.State -ne "Installed"}
$UKCapabilities | ForEach-Object {
    Write-Output "Adding capability $($_.Name)"
    try{
        Add-WindowsCapability -Online -Name $_.Name
    }
    catch{
        Write-Output "Error Adding capability $($_.Name)"
    }
}

$LanguageList = Get-WinUserLanguageList
$LanguageList.Add("en-GB")
Set-WinUserLanguageList $LanguageList -Force

# Set Languages/Culture
Set-Culture en-GB
Set-WinSystemLocale en-GB
Set-WinHomeLocation -GeoId 242
Set-WinUserLanguageList en-GB -Force

# Get xml File
$xmlFile = "setLocaleUk.xml"
$xmlPath = Join-Path $filePath $xmlFile

# Set Language Admin Defaults
$Process = Start-Process -FilePath Control.exe -ArgumentList "intl.cpl,,/f:`"$xmlPath`"" -NoNewWindow -PassThru -Wait
$Process.ExitCode

# Set Timezone
& tzutil /s "GMT Standard Time"

Restart-Computer -Force
