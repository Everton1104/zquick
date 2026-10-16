# build-msi.ps1 - gera o instalador ZQuick-<versao>.msi (por usuario, sem admin)
# com WiX v3.14 (binarios baixados 1x para tools\wix314 - nao precisa instalar nada).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File build-msi.ps1
# Saida: dist\ZQuick-<versao>.msi  (ex.: ZQuick-3.19.0.msi)
#
# O MSI so' EMPACOTA: exe + ps1 + icone + LEIA-ME em %LOCALAPPDATA%\Programs\ZQuick
# + atalho no Menu Iniciar. Chave, autostart e atalho Alt+Q ficam com o assistente
# de configuracao, que abre sozinho na 1a execucao (v3.19). Desinstalar NAO apaga
# zquick.json/history/skills (nao sao componentes do MSI - dados do usuario ficam).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# ---- versao do app (zquick.ps1: $appVer = '3.19') -> ProductVersion x.y.z ----
$src = Get-Content (Join-Path $root 'zquick.ps1') -Raw
if ($src -notmatch ("app" + "Ver\s*=\s*'([0-9.]+)'")) { throw 'nao achei appVer no zquick.ps1' }
$ver = $Matches[1]
$msiVer = if ($ver -match '^(\d+)\.(\d+)$') { "$ver.0" } else { $ver }

# ---- WiX 3.14: baixa 1x (zip de binarios oficial, wix3141rtm) ----
$wixDir = Join-Path $root 'tools\wix314'
if (-not (Test-Path (Join-Path $wixDir 'candle.exe'))) {
    $zip = Join-Path $root 'tools\wix314-binaries.zip'
    New-Item -ItemType Directory -Force (Join-Path $root 'tools') | Out-Null
    Write-Host "baixando WiX 3.14 (1a vez)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' -OutFile $zip
    New-Item -ItemType Directory -Force $wixDir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $wixDir -Force
    Remove-Item $zip -Force
}
$candle = Join-Path $wixDir 'candle.exe'
$light   = Join-Path $wixDir 'light.exe'
foreach ($e in @($candle, $light)) { if (-not (Test-Path $e)) { throw "WiX incompleto: falta $e" } }

# ---- .wxs ----
$wxs = @"
<?xml version='1.0' encoding='utf-8'?>
<Wix xmlns='http://schemas.microsoft.com/wix/2006/wi'>
  <Product Id='*' Name='ZQuick' Language='1046' Version='$msiVer' Manufacturer='Everton'
           UpgradeCode='B5431A15-BBC9-46C3-9629-99E3CC358B0B'>
    <Package InstallerVersion='200' Compressed='yes' InstallScope='perUser'
             Description='ZQuick - busca rapida com LLM sempre a mao (Alt+Q)' />
    <MajorUpgrade AllowSameVersionUpgrades='yes'
                  DowngradeErrorMessage='Uma versao mais nova do ZQuick ja esta instalada.' />
    <MediaTemplate EmbedCab='yes' />
    <Icon Id='zquick.ico' SourceFile='kit\zquick.ico' />
    <Property Id='ARPPRODUCTICON' Value='zquick.ico' />
    <Property Id='DISABLEADVTSHORTCUTS' Value='1' />

    <Directory Id='TARGETDIR' Name='SourceDir'>
      <Directory Id='LocalAppDataFolder'>
        <Directory Id='ProgramsDir' Name='Programs'>
          <Directory Id='INSTALLDIR' Name='ZQuick'>
            <Component Id='MainFiles' Guid='E92905F5-81EC-40C3-A93B-55CC61B71749'>
              <!-- ICE38: componente no perfil do usuario -> KeyPath e' registro HKCU -->
              <RegistryValue Root='HKCU' Key='Software\ZQuick' Name='main' Type='integer' Value='1' KeyPath='yes' />
              <File Id='zquick.exe' Source='zquick.exe' />
              <File Id='zquick.ps1' Source='zquick.ps1' />
              <File Id='zquick.ico' Source='kit\zquick.ico' />
              <File Id='LEIAME' Name='LEIA-ME.txt' Source='kit\LEIA-ME.txt' />
              <!-- ICE64: pastas no perfil do usuario entram na RemoveFile table
                   (so' removem se estiverem vazias - dados do usuario ficam) -->
              <RemoveFolder Id='RemoveInstalldir' Directory='INSTALLDIR' On='uninstall' />
              <RemoveFolder Id='RemoveProgramsDir' Directory='ProgramsDir' On='uninstall' />
            </Component>
          </Directory>
        </Directory>
      </Directory>
      <Directory Id='ProgramMenuFolder'>
        <Component Id='StartMenuShortcut' Guid='165BD609-6210-44B0-BD03-2F6380946691'>
          <Shortcut Id='ZQuickShortcut' Name='ZQuick' Target='[INSTALLDIR]zquick.exe'
                    WorkingDirectory='INSTALLDIR' Icon='zquick.ico' />
          <RegistryValue Root='HKCU' Key='Software\ZQuick' Name='installed' Type='integer' Value='1' KeyPath='yes' />
        </Component>
      </Directory>
    </Directory>

    <Feature Id='Main' Level='1' Title='ZQuick'>
      <ComponentRef Id='MainFiles' />
      <ComponentRef Id='StartMenuShortcut' />
    </Feature>
  </Product>
</Wix>
"@
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$obj = Join-Path $root 'dist\obj'
New-Item -ItemType Directory -Force $obj | Out-Null
$wxsPath = Join-Path $obj 'ZQuick.wxs'
$wxs | Out-File -FilePath $wxsPath -Encoding utf8

Write-Host "compilando ZQuick $msiVer..."
& $candle -nologo -out "$obj\ZQuick.wixobj" $wxsPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw "candle falhou ($LASTEXITCODE)" }
$msi = Join-Path $dist "ZQuick-$msiVer.msi"
& $light -nologo -out $msi "$obj\ZQuick.wixobj" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "light falhou ($LASTEXITCODE)" }

# ---- confere os metadados do MSI gerado ----
$props = @{}
$wi = New-Object -ComObject WindowsInstaller.Installer
$db = $wi.OpenDatabase($msi, 0)
foreach ($p in @('ProductName', 'ProductVersion', 'Manufacturer')) {
    $v = $db.OpenView("SELECT Value FROM Property WHERE Property='$p'")
    $v.Execute()
    $rec = $v.Fetch()
    $props[$p] = $rec.StringData(1)
    $v.Close()
}

if ($props['ProductVersion'] -ne $msiVer) { throw "versao no MSI errada: $($props['ProductVersion'])" }
"MSI  : $msi"
"tamanho: {0:N0} bytes" -f (Get-Item $msi).Length
"meta : $($props['ProductName']) v$($props['ProductVersion']) - $($props['Manufacturer'])"
"ok   : ZQuick-$msiVer.msi pronto (instalacao por usuario - nao pede admin)"
