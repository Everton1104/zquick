# build-msi.ps1 - gera o instalador ZQuick-<versao>.msi (por usuario, sem admin)
# com WiX v3.14 (binarios baixados 1x para tools\wix314 - nao precisa instalar nada).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File build-msi.ps1
# Saida: dist\ZQuick-<versao>.msi  (ex.: ZQuick-3.19.0.msi)
#
# O MSI EMPACOTA: exe + ps1 + icone + LEIA-ME + MANUAL em %LOCALAPPDATA%\Programs\ZQuick
# + atalho no Menu Iniciar. v3.24: UI REAL de instalacao (boas-vindas -> pasta ->
# instalar -> concluir), textos em pt-BR (dist\obj\ptbr.wxl, gerado aqui) e
# checkbox "Iniciar o ZQuick" na tela final — na 1a execucao sem chave o app abre
# o assistente de configuracao sozinho (chave, teste, modelos, LLM local, autostart
# e atalho ficam com ele). Desinstalar NAO apaga zquick.json/history/skills
# (nao sao componentes do MSI - dados do usuario ficam).
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

    <!-- v3.24: UI de instalacao (WixUI_InstallDir: boas-vindas -> pasta ->
         confirmar -> concluir) + iniciar o app no fim (1a execucao sem chave
         abre o assistente de configuracao). Textos pt-BR via ptbr.wxl abaixo. -->
    <UIRef Id='WixUI_InstallDir' />
    <Property Id='WIXUI_INSTALLDIR' Value='INSTALLDIR' />
    <Property Id='WIXUI_EXITDIALOGOPTIONALCHECKBOX' Value='1' />
    <Property Id='WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT' Value='Iniciar o ZQuick agora' />
    <Property Id='WixShellExecTarget' Value='[#zquick.exe]' />
    <CustomAction Id='LaunchZQuick' BinaryKey='WixCA' DllEntry='WixShellExec' Impersonate='yes' />
    <UI>
      <Publish Dialog='ExitDialog' Control='Finish' Event='DoAction' Value='LaunchZQuick'>WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 and NOT Installed</Publish>
    </UI>

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
              <File Id='MANUAL' Name='MANUAL.txt' Source='kit\MANUAL.txt' />
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

# ---- pt-BR: .wxl dos dialogos WixUI_InstallDir (este script e' ASCII puro;
#      acentos entram como entidades XML numericas &#NNN; e viram UTF-8 no arquivo)
$wxl = @"
<?xml version='1.0' encoding='utf-8'?>
<WixLocalization Culture='pt-br' xmlns='http://schemas.microsoft.com/wix/2006/localization'>
  <String Id='WelcomeDlgTitle'>{&#92;WixUI_Font_Bigger}Bem-vindo ao assistente de instala&#231;&#227;o do [ProductName]</String>
  <String Id='WelcomeDlgDescription'>Este assistente instala o [ProductName] no seu usu&#225;rio, sem precisar de administrador. Clique em Avan&#231;ar para continuar ou em Cancelar para sair.</String>
  <String Id='InstallDirDlgTitle'>{&#92;WixUI_Font_Bigger}Pasta de destino</String>
  <String Id='InstallDirDlgDescription'>Clique em Instalar para continuar ou em Procurar para mudar a pasta.</String>
  <String Id='InstallDirDlgFolderLabel'>Instalar o [ProductName] em:</String>
  <String Id='VerifyReadyDlgInstallTitle'>{&#92;WixUI_Font_Bigger}Pronto para instalar o [ProductName]</String>
  <String Id='VerifyReadyDlgInstallDescription'>Clique em Instalar para come&#231;ar a instala&#231;&#227;o. Clique em Voltar para revisar ou em Cancelar para sair.</String>
  <String Id='ExitDialogTitle'>{&#92;WixUI_Font_Bigger}Instala&#231;&#227;o conclu&#237;da</String>
  <String Id='ExitDialogDescription'>Clique em Concluir para encerrar o assistente.</String>
  <String Id='WixUIBack'>&amp;Voltar</String>
  <String Id='WixUINext'>A&amp;van&#231;ar</String>
  <String Id='WixUIInstall'>&amp;Instalar</String>
  <String Id='WixUICancel'>Cancelar</String>
  <String Id='WixUIBrowse'>P&amp;rocurar...</String>
  <String Id='WixUIExit'>&amp;Concluir</String>
</WixLocalization>
"@
$wxlPath = Join-Path $obj 'ptbr.wxl'
$wxl | Out-File -FilePath $wxlPath -Encoding utf8

Write-Host "compilando ZQuick $msiVer..."
& $candle -nologo -out "$obj\ZQuick.wixobj" $wxsPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw "candle falhou ($LASTEXITCODE)" }
$msi = Join-Path $dist "ZQuick-$msiVer.msi"
& $light -nologo -ext WixUIExtension -ext WixUtilExtension -loc $wxlPath -out $msi "$obj\ZQuick.wixobj" | Out-Null
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

# ---- confere a UI: textos pt-BR na Control table + checkbox de iniciar ----
$cc = 0
$cv = $db.OpenView('SELECT `Text` FROM Control WHERE `Dialog_` = ''WelcomeDlg''')
$cv.Execute()
while ($r = $cv.Fetch()) { if (([string]$r.StringData(1)) -match 'Bem-vindo') { $cc++ } }
$cv.Close()
$ce = 0
$cx = $db.OpenView('SELECT `Text` FROM Control WHERE `Dialog_` = ''ExitDialog''')
$cx.Execute()
while ($r = $cx.Fetch()) { if (([string]$r.StringData(1)) -match 'conclu') { $ce++ } }
$cx.Close()
if ($cc -lt 1 -or $ce -lt 2) { throw "localizacao pt-BR nao aplicou (WelcomeDlg=$cc, ExitDialog=$ce)" }
$pv = $db.OpenView('SELECT `Value` FROM Property WHERE `Property` = ''WIXUI_EXITDIALOGOPTIONALCHECKBOX''')
$pv.Execute(); $pr = $pv.Fetch(); $pv.Close()
if (-not $pr -or $pr.StringData(1) -ne '1') { throw 'checkbox de iniciar o app nao gravado' }

"MSI  : $msi"
"tamanho: {0:N0} bytes" -f (Get-Item $msi).Length
"meta : $($props['ProductName']) v$($props['ProductVersion']) - $($props['Manufacturer'])"
"ui   : $cc dialogo(s) com texto pt-BR + checkbox 'Iniciar o ZQuick' (ligado)"
"ok   : ZQuick-$msiVer.msi pronto (instalacao por usuario - nao pede admin)"
