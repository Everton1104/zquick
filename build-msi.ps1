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
# v3.26: termo de licenca real (kit\licenca.rtf), dialogo opcional da chave da
# API (ZQKeyDlg: endereco do provedor + chave) e CA que grava zquick.setup na
# pasta instalada - o app consome no 1o boot, configura o perfil e varre os
# modelos do provedor sozinho (installa ja funcionando).
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

# ---- v3.26: termo de licenca do kit, inline no dialogo proprio (ZQLicenseDlg).
#      Nem o truque <Property WixUILicenseRtf> nem a string 'WixUILicenseRtf' no
#      -loc aplicaram (LicenseText ficava no lorem padrao do WiX) - dialogo
#      nosso e' deterministico. Quebras CR/LF nao importam pro RTF (so' \par).
$rtf = [IO.File]::ReadAllText((Join-Path $root 'kit\licenca.rtf'))
$rtf = ($rtf -replace '\r?\n', '').Trim()
# LICAO (2a rodada do 3.26): \par colado em LETRA pos-flatten = control word
# desconhecida ("\parVoc") que o renderizador descarta INTEIRA - comia o
# comeco do paragrafo ("Voc"/"N"/"O ") e a propria quebra. Todo \par de fim
# de linha no kit\licenca.rtf termina com espaco (delimitador consumido).
# (?!d) = nao confundir com \pard, que comeca igual.
if ($rtf -match '\\par(?!d)[A-Za-z]') { throw 'kit\licenca.rtf: \par colado em letra apos achatar - termine o \par com espaco' }
if ($rtf -notmatch '\\rtf1' -or $rtf -notmatch 'ZQUICK') { throw 'kit\licenca.rtf invalido (nao e RTF ou sem o marcador ZQUICK)' }
$rtfXml = $rtf.Replace('&', '&amp;').Replace('<', '&lt;').Replace('"', '&quot;')

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
    <!-- v3.26: chave da API opcional no instalador (dialogo ZQKeyDlg) -->
    <Property Id='ZQBASE' Value='api.z.ai/api/anthropic' />
    <Property Id='ZQKEY' Secure='yes' />
    <Property Id='WIXUI_EXITDIALOGOPTIONALCHECKBOX' Value='1' />
    <Property Id='WIXUI_EXITDIALOGOPTIONALCHECKBOXTEXT' Value='Iniciar o ZQuick agora' />
    <Property Id='WixShellExecTarget' Value='[#zquick.exe]' />
    <CustomAction Id='LaunchZQuick' BinaryKey='WixCA' DllEntry='WixShellExec' Impersonate='yes' />
    <UI>
      <Publish Dialog='ExitDialog' Control='Finish' Event='DoAction' Value='LaunchZQuick'>WIXUI_EXITDIALOGOPTIONALCHECKBOX = 1 and NOT Installed</Publish>
      <!-- v3.26: insere o dialogo da chave entre a pasta e o resumo. O default do
           WixUI_InstallDir navega p/ VerifyReadyDlg com Order=4 na MESMA condicao
           (3.25.0 dumpado: Next/NewDialog ord 4) - o ultimo NewDialog processado
           vence, entao o nosso tem que vir DEPOIS (Order=6) -->
      <Publish Dialog='InstallDirDlg' Control='Next' Event='NewDialog' Value='ZQKeyDlg' Order='6'>WIXUI_DONTVALIDATEPATH OR WIXUI_INSTALLDIR_VALID=&quot;1&quot;</Publish>
      <Publish Dialog='VerifyReadyDlg' Control='Back' Event='NewDialog' Value='ZQKeyDlg' Order='3'>NOT Installed</Publish>
      <!-- v3.26: licenca propria no lugar do LicenseAgreementDlg do WixUI
           (Welcome/Next e' ord 1 p/ LicenseAgreementDlg [NOT Installed];
           InstallDir/Back e' ord 1 [1] - nossos ord 2 vencem por serem depois) -->
      <Publish Dialog='WelcomeDlg' Control='Next' Event='NewDialog' Value='ZQLicenseDlg' Order='2'>NOT Installed</Publish>
      <Publish Dialog='InstallDirDlg' Control='Back' Event='NewDialog' Value='ZQLicenseDlg' Order='2'>1</Publish>
      <Dialog Id='ZQLicenseDlg' Width='370' Height='270' Title='[ProductName] Setup'>
        <Control Id='BannerBitmap' Type='Bitmap' X='0' Y='0' Width='370' Height='44' TabSkip='no' Text='WixUI_Bmp_Banner' />
        <Control Id='Title' Type='Text' X='15' Y='6' Width='340' Height='15' Transparent='yes' NoPrefix='yes'>
          <Text>{\WixUI_Font_Title}Licen&#231;a de uso do [ProductName]</Text>
        </Control>
        <Control Id='Description' Type='Text' X='25' Y='23' Width='320' Height='15' Transparent='yes' NoPrefix='yes'>
          <Text>Leia os termos com aten&#231;&#227;o. &#201; preciso aceitar para instalar.</Text>
        </Control>
        <Control Id='BannerLine' Type='Line' X='0' Y='44' Width='370' Height='0' />
        <Control Id='LicenseText' Type='ScrollableText' X='25' Y='55' Width='320' Height='150' Sunken='yes' TabSkip='no' Text="$rtfXml" />
        <Control Id='LicenseAcceptedCheckBox' Type='CheckBox' X='25' Y='210' Width='320' Height='16' Property='ZQLicenseAccepted' CheckBoxValue='1' Text='&amp;Aceito os termos da licen&#231;a' />
        <Control Id='BottomLine' Type='Line' X='0' Y='234' Width='370' Height='0' />
        <Control Id='Back' Type='PushButton' X='180' Y='243' Width='56' Height='17' Text='&amp;Voltar'>
          <Publish Event='NewDialog' Value='WelcomeDlg'>1</Publish>
        </Control>
        <Control Id='Next' Type='PushButton' X='236' Y='243' Width='56' Height='17' Default='yes' Text='&amp;Avan&#231;ar'>
          <Publish Event='NewDialog' Value='InstallDirDlg'>ZQLicenseAccepted = "1"</Publish>
        </Control>
        <Control Id='Cancel' Type='PushButton' X='304' Y='243' Width='56' Height='17' Cancel='yes' Text='Cancelar'>
          <Publish Event='SpawnDialog' Value='CancelDlg'>1</Publish>
        </Control>
      </Dialog>
      <Dialog Id='ZQKeyDlg' Width='370' Height='270' Title='[ProductName] Setup'>
        <Control Id='BannerBitmap' Type='Bitmap' X='0' Y='0' Width='370' Height='44' TabSkip='no' Text='WixUI_Bmp_Banner' />
        <Control Id='Title' Type='Text' X='15' Y='6' Width='340' Height='15' Transparent='yes' NoPrefix='yes'>
          <Text>{\WixUI_Font_Title}Chave da API (opcional)</Text>
        </Control>
        <Control Id='Description' Type='Text' X='25' Y='23' Width='320' Height='15' Transparent='yes' NoPrefix='yes'>
          <Text>Cole a chave do seu provedor para o ZQuick j&#225; abrir funcionando. Deixe vazio para configurar depois.</Text>
        </Control>
        <Control Id='BannerLine' Type='Line' X='0' Y='44' Width='370' Height='0' />
        <Control Id='BaseLabel' Type='Text' X='25' Y='70' Width='320' Height='20' TabSkip='no'>
          <Text>Endere&#231;o do provedor (padr&#227;o: api.z.ai &#8212; GLM/Z.ai; tamb&#233;m aceita Kimi, DeepSeek, MiniMax, Qwen, localhost...):</Text>
        </Control>
        <Control Id='ZQBaseEdit' Type='Edit' X='25' Y='92' Width='320' Height='18' Property='ZQBASE' Text='[ZQBASE]' />
        <Control Id='KeyLabel' Type='Text' X='25' Y='120' Width='320' Height='10' TabSkip='no'>
          <Text>Chave da API:</Text>
        </Control>
        <Control Id='ZQKeyEdit' Type='Edit' X='25' Y='134' Width='320' Height='18' Property='ZQKEY' Text='[ZQKEY]' />
        <Control Id='Hint' Type='Text' X='25' Y='162' Width='320' Height='52' TabSkip='no'>
          <Text>A chave fica s&#243; na sua m&#225;quina (zquick.json) e o app consulta os modelos do provedor sozinho ao abrir. N&#227;o tem chave agora? Siga em frente &#8212; o assistente de configura&#231;&#227;o abre na primeira execu&#231;&#227;o.</Text>
        </Control>
        <Control Id='BottomLine' Type='Line' X='0' Y='234' Width='370' Height='0' />
        <Control Id='Back' Type='PushButton' X='180' Y='243' Width='56' Height='17' Text='&amp;Voltar'>
          <Publish Event='NewDialog' Value='InstallDirDlg'>1</Publish>
        </Control>
        <Control Id='Next' Type='PushButton' X='236' Y='243' Width='56' Height='17' Default='yes' Text='&amp;Avan&#231;ar'>
          <Publish Event='NewDialog' Value='VerifyReadyDlg'>1</Publish>
        </Control>
        <Control Id='Cancel' Type='PushButton' X='304' Y='243' Width='56' Height='17' Cancel='yes' Text='Cancelar'>
          <Publish Event='SpawnDialog' Value='CancelDlg'>1</Publish>
        </Control>
      </Dialog>
    </UI>

    <!-- v3.26: grava base+chave em zquick.setup na pasta instalada (CA em VBScript
         deferred+impersonate: roda DEPOIS dos arquivos, como o usuario) -->
    <Binary Id='ZQSetupCA' SourceFile='dist\obj\zqsetup.vbs' />
    <CustomAction Id='ZQSetupData' Property='ZQWriteSetup' Value='DIR=[INSTALLDIR];ZQKEY=[ZQKEY];ZQBASE=[ZQBASE]' Execute='immediate' />
    <CustomAction Id='ZQWriteSetup' BinaryKey='ZQSetupCA' VBScriptCall='WriteSetup' Execute='deferred' Impersonate='yes' Return='ignore' />

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

    <!-- v3.26: sequencia de execucao — grava zquick.setup depois dos arquivos -->
    <InstallExecuteSequence>
      <Custom Action='ZQSetupData' After='InstallValidate' />
      <Custom Action='ZQWriteSetup' After='InstallFiles'>NOT Installed</Custom>
    </InstallExecuteSequence>

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

# ---- v3.26: CA em VBScript (ASCII puro) — grava base+chave em zquick.setup
#      (deferred: dados chegam via CustomActionData; o app lê e apaga no 1o boot)
$vbs = Join-Path $obj 'zqsetup.vbs'
@'
' ZQuick setup CA - grava base+chave informadas no instalador (deferred CA;
' dados chegam em CustomActionData = DIR=...;ZQKEY=...;ZQBASE=...)
Sub WriteSetup
  On Error Resume Next
  Dim cad, key, base, dir, arr, i, s, eq
  cad = Session.Property("CustomActionData")
  key = "" : base = "" : dir = ""
  arr = Split(cad, ";")
  For i = 0 To UBound(arr)
    s = arr(i)
    eq = InStr(s, "=")
    If eq > 0 Then
      If Left(s, eq - 1) = "ZQKEY" Then key = Mid(s, eq + 1)
      If Left(s, eq - 1) = "ZQBASE" Then base = Mid(s, eq + 1)
      If Left(s, eq - 1) = "DIR" Then dir = Mid(s, eq + 1)
    End If
  Next
  If Len(Trim(key)) = 0 Then Exit Sub
  If Len(Trim(dir)) = 0 Then Exit Sub
  If Len(Trim(base)) = 0 Then base = "api.z.ai/api/anthropic"
  Dim fso, f
  Set fso = CreateObject("Scripting.FileSystemObject")
  Set f = fso.CreateTextFile(dir & "zquick.setup", True, False)
  f.WriteLine "base=" & base
  f.WriteLine "key=" & key
  f.Close
End Sub
'@ | Out-File -FilePath $vbs -Encoding ascii

# ---- pt-BR: .wxl dos dialogos WixUI_InstallDir (este script e' ASCII puro;
#      acentos entram como entidades XML numericas &#NNN; e viram UTF-8 no arquivo)
$wxl = @"
<?xml version='1.0' encoding='utf-8'?>
<WixLocalization Culture='pt-br' xmlns='http://schemas.microsoft.com/wix/2006/localization'>
  <String Id='WelcomeDlgTitle'>{&#92;WixUI_Font_Bigger}Bem-vindo ao assistente de instala&#231;&#227;o do [ProductName]</String>
  <String Id='WelcomeDlgDescription'>Este assistente instala o [ProductName] no seu usu&#225;rio, sem precisar de administrador. Clique em Avan&#231;ar para continuar ou em Cancelar para sair.</String>
  <String Id='LicenseAgreementDlgTitle'>{&#92;WixUI_Font_Title}Licen&#231;a de uso do [ProductName]</String>
  <String Id='LicenseAgreementDlgDescription'>Leia os termos a seguir com aten&#231;&#227;o. &#201; preciso aceit&#225;-los para instalar o [ProductName].</String>
  <String Id='WixUILicenseAgreementCheckBox'>&amp;Aceito os termos da licen&#231;a</String>
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

# ---- v3.26: confere licenca do kit (nao o lorem padrao do WiX) + dialogos
#      proprios (ZQLicenseDlg/ZQKeyDlg). NB: na tabela Control as colunas sao
#      `Control` e `Property` SEM underscore (o underscore e' so' na FK
#      Control_.Dialog_/Control_ da ControlEvent) ----
$lv = $db.OpenView('SELECT `Text` FROM Control WHERE `Dialog_` = ''ZQLicenseDlg'' AND `Control` = ''LicenseText''')
$lv.Execute(); $lr = $lv.Fetch(); $lv.Close()
if (-not $lr -or (([string]$lr.StringData(1)) -notmatch 'ZQUICK')) { throw 'licenca do kit (kit\licenca.rtf) nao aplicou no ZQLicenseDlg' }
$kv = $db.OpenView('SELECT `Control` FROM Control WHERE `Dialog_` = ''ZQKeyDlg'' AND `Property` = ''ZQKEY''')
$kv.Execute(); $kr = $kv.Fetch(); $kv.Close()
if (-not $kr) { throw 'ZQKeyDlg sem campo ligado a propriedade ZQKEY' }
function Get-Rotas([string]$destino) {
    $rv = $db.OpenView(('SELECT `Dialog_`, `Control_` FROM ControlEvent WHERE `Event` = ''NewDialog'' AND `Argument` = ''' + $destino + ''''))
    $rv.Execute(); $out = @(); while ($r2 = $rv.Fetch()) { $out += ($r2.StringData(1) + '/' + $r2.StringData(2)) }; $rv.Close(); $out
}
$licRoutes = Get-Rotas 'ZQLicenseDlg'
foreach ($par in @('WelcomeDlg/Next', 'InstallDirDlg/Back')) { if ($licRoutes -notcontains $par) { throw "rota ausente ate ZQLicenseDlg: $par (tem: $($licRoutes -join ', '))" } }
$keyRoutes = Get-Rotas 'ZQKeyDlg'
foreach ($par in @('InstallDirDlg/Next', 'VerifyReadyDlg/Back')) { if ($keyRoutes -notcontains $par) { throw "rota ausente ate ZQKeyDlg: $par (tem: $($keyRoutes -join ', '))" } }
$caN = 0
$cav = $db.OpenView('SELECT `Action` FROM CustomAction WHERE `Action` = ''ZQWriteSetup'' OR `Action` = ''ZQSetupData''')
$cav.Execute(); while ($r3 = $cav.Fetch()) { $caN++ }; $cav.Close()
if ($caN -lt 2) { throw 'CustomActions ZQSetupData/ZQWriteSetup ausentes' }
$seN = 0
$sev = $db.OpenView('SELECT `Action` FROM InstallExecuteSequence WHERE `Action` = ''ZQWriteSetup''')
$sev.Execute(); while ($r4 = $sev.Fetch()) { $seN++ }; $sev.Close()
if ($seN -lt 1) { throw 'ZQWriteSetup nao esta na InstallExecuteSequence' }

"MSI  : $msi"
"tamanho: {0:N0} bytes" -f (Get-Item $msi).Length
"meta : $($props['ProductName']) v$($props['ProductVersion']) - $($props['Manufacturer'])"
"ui   : $cc dialogo(s) com texto pt-BR + checkbox 'Iniciar o ZQuick' (ligado)"
"lic  : termos de uso do kit no ZQLicenseDlg (sem lorem) ok"
"chave: ZQKeyDlg ok ($($keyRoutes -join ', ')) + licenca roteada ($($licRoutes -join ', ')) + CA zquick.setup ok"
"ok   : ZQuick-$msiVer.msi pronto (instalacao por usuario - nao pede admin)"
