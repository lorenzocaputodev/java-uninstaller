# ============================================================
#  Tests for uninstall-java.ps1
#  Plain PowerShell assertions, no extra modules required:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tests\uninstall-java.tests.ps1
#
#  Only the functions of the script are loaded (everything before
#  the "# --- MAIN ---" marker), so nothing on the system is
#  touched, except a throw-away registry key under HKCU that is
#  always deleted at the end.
# ============================================================
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param()

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\uninstall-java.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$marker = $source.IndexOf('# --- MAIN ---')
if ($marker -lt 0) { throw 'Main marker not found in uninstall-java.ps1' }
. ([scriptblock]::Create($source.Substring(0, $marker)))

$script:Failures = 0
$script:Checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    $script:Checks++
    if ("$Actual" -ceq "$Expected") { return }
    $script:Failures++
    Write-Host "FAIL: $Name`n      expected: $Expected`n      actual:   $Actual" -ForegroundColor Red
}

# --- Product detection ----------------------------------------
$javaNames = @(
    @('Java 8 Update 361 (64-bit)', 'Oracle Corporation'),
    @('Java(TM) SE Development Kit 17.0.1 (64-bit)', 'Oracle Corporation'),
    @('Java Auto Updater', 'Oracle Corporation'),
    @('Eclipse Temurin JDK with Hotspot 17.0.5+8 (x64)', 'Eclipse Adoptium'),
    @('Microsoft Build of OpenJDK with Hotspot 17.0.5 (x64)', 'Microsoft'),
    @('Azul Zulu JDK 17.38', 'Azul Systems'),
    @('Zulu 17.38.21 (x64)', 'Azul Systems'),
    @('Amazon Corretto 17.0.5.8.1', 'Amazon'),
    @('BellSoft Liberica JDK 17', 'BellSoft'),
    @('Java SE Runtime Environment', 'Sun Microsystems, Inc.')
)
foreach ($item in $javaNames) {
    Assert-Equal (Test-JavaProductName $item[0] $item[1]) $true "product detected: $($item[0])"
}

$otherNames = @(
    @('Minecraft Launcher', 'Mojang'),
    @('JavaScript Debugger', 'Microsoft'),
    @('Oracle VM VirtualBox 7.0.8', 'Oracle Corporation'),
    @('Eclipse IDE for Java Developers', 'Eclipse Foundation'),
    @('IntelliJ IDEA Community Edition', 'JetBrains'),
    @('Node.js', 'Node.js Foundation'),
    @('JavaFX Scene Builder', 'Gluon')
)
foreach ($item in $otherNames) {
    Assert-Equal (Test-JavaProductName $item[0] $item[1]) $false "product ignored: $($item[0])"
}

# --- Uninstall command parsing --------------------------------
$quoted = Split-CommandLine '"C:\Program Files\App\unins000.exe" /x /y'
Assert-Equal $quoted.FilePath 'C:\Program Files\App\unins000.exe' 'quoted path'
Assert-Equal $quoted.Arguments '/x /y' 'quoted arguments'

$unquoted = Split-CommandLine 'C:\Program Files\App\uninstall.exe /remove'
Assert-Equal $unquoted.FilePath 'C:\Program Files\App\uninstall.exe' 'unquoted path with spaces'
Assert-Equal $unquoted.Arguments '/remove' 'unquoted arguments'

$bare = Split-CommandLine 'C:\App\uninstall.exe'
Assert-Equal $bare.FilePath 'C:\App\uninstall.exe' 'path without arguments'
Assert-Equal $bare.Arguments '' 'no arguments'

$guid = '{4A6E2B0F-1D2C-4C2A-9B54-6F0D7B1A2C33}'
$msi = Get-UninstallCommand ([pscustomobject]@{ Key = $guid; Uninstall = "MsiExec.exe /I$guid"; QuietUninstall = ''; WindowsInstaller = 1 })
Assert-Equal $msi.Kind 'MSI' 'msi kind'
Assert-Equal $msi.Arguments "/x $guid /qn /norestart" 'msi arguments'

$inno = Get-UninstallCommand ([pscustomobject]@{ Key = 'App'; Uninstall = '"C:\App\unins000.exe"'; QuietUninstall = ''; WindowsInstaller = $null })
Assert-Equal $inno.Arguments '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' 'inno silent flags'

$quiet = Get-UninstallCommand ([pscustomobject]@{ Key = 'App'; Uninstall = '"C:\App\u.exe"'; QuietUninstall = '"C:\App\u.exe" --quiet'; WindowsInstaller = $null })
Assert-Equal $quiet.Kind 'quiet' 'quiet string preferred'
Assert-Equal $quiet.Arguments '--quiet' 'quiet arguments'

# --- PATH cleanup ---------------------------------------------
$javaPathEntries = @(
    'C:\Program Files\Common Files\Oracle\Java\javapath',
    'C:\ProgramData\Oracle\Java\javapath',
    'C:\Program Files\Java\jdk-17\bin',
    'C:\Program Files (x86)\Java\jre1.8.0_361\bin',
    'C:\Program Files\Eclipse Adoptium\jdk-17.0.5.8-hotspot\bin',
    'C:\Program Files\Zulu\zulu-17\bin',
    'C:\Program Files\Microsoft\jdk-17.0.5.8-hotspot\bin',
    'C:\Program Files\Amazon Corretto\jdk17.0.5_8\bin',
    'C:\dev\jdk-21\bin',
    '%JAVA_HOME%\bin',
    '"C:\Program Files\Java\jdk-17\bin"'
)
foreach ($entry in $javaPathEntries) {
    Assert-Equal (Test-JavaPathEntry $entry @()) $true "PATH entry removed: $entry"
}

$otherPathEntries = @(
    'C:\Windows\system32',
    '%SystemRoot%\System32\Wbem',
    'C:\Users\me\JavaScriptTools\bin',
    'C:\Program Files\nodejs\',
    'C:\Program Files\Microsoft VS Code\bin',
    'C:\Program Files\Git\cmd',
    ''
)
foreach ($entry in $otherPathEntries) {
    Assert-Equal (Test-JavaPathEntry $entry @()) $false "PATH entry kept: '$entry'"
}

Assert-Equal (Test-JavaPathEntry 'D:\tools\myjava\bin' @('D:\tools\myjava')) $true 'entry inside custom JAVA_HOME'
Assert-Equal (Test-JavaPathEntry 'D:\tools\myjava2\bin' @('D:\tools\myjava')) $false 'sibling of custom JAVA_HOME kept'
Assert-Equal (Test-JavaPathEntry 'C:\Windows' @('C:\')) $false 'drive-root JAVA_HOME never matches everything'

$cleaned = Get-CleanedPath -Path '%USERPROFILE%\bin;C:\Program Files\Java\jdk-17\bin;C:\Tools;' -JavaHomes @()
Assert-Equal $cleaned.Path '%USERPROFILE%\bin;C:\Tools;' 'cleaned PATH keeps %VARS% and trailing separator'
Assert-Equal @($cleaned.Removed).Count 1 'one entry removed'

# --- Environment cleanup on a throw-away registry key ---------
$testKeyPath = 'Software\JavaUninstallerTest-' + [guid]::NewGuid().ToString('N')
$testKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testKeyPath)
try {
    $testKey.SetValue('JAVA_HOME', 'C:\Program Files\Eclipse Adoptium\jdk-17.0.5.8-hotspot', 'String')
    $testKey.SetValue('Other', 'keep me', 'String')
    $testKey.SetValue('Path', '%USERPROFILE%\bin;C:\Program Files\Eclipse Adoptium\jdk-17.0.5.8-hotspot\bin;%JAVA_HOME%\bin;C:\Tools\JavaScriptTools\bin;C:\Program Files\Common Files\Oracle\Java\javapath;', 'ExpandString')

    Set-Variable -Name DryRun -Value $true   # read by Invoke-Change, loaded above
    Invoke-EnvironmentCleanup -Key $testKey -ScopeName 'Test' -JavaHomes @('C:\Program Files\Eclipse Adoptium\jdk-17.0.5.8-hotspot') | Out-Null
    Assert-Equal ($testKey.GetValueNames() -contains 'JAVA_HOME') $true 'dry run keeps JAVA_HOME'
    Assert-Equal ($testKey.GetValue('Path', '', 'DoNotExpandEnvironmentNames')).Split(';').Count 6 'dry run keeps PATH'

    Set-Variable -Name DryRun -Value $false
    Invoke-EnvironmentCleanup -Key $testKey -ScopeName 'Test' -JavaHomes @('C:\Program Files\Eclipse Adoptium\jdk-17.0.5.8-hotspot') | Out-Null
    Assert-Equal ($testKey.GetValueNames() -contains 'JAVA_HOME') $false 'JAVA_HOME removed'
    Assert-Equal $testKey.GetValue('Other') 'keep me' 'unrelated variable untouched'
    Assert-Equal $testKey.GetValueKind('Path') 'ExpandString' 'PATH is still REG_EXPAND_SZ'
    Assert-Equal $testKey.GetValue('Path', '', 'DoNotExpandEnvironmentNames') '%USERPROFILE%\bin;C:\Tools\JavaScriptTools\bin;' 'PATH content'
}
finally {
    $testKey.Close()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testKeyPath, $false)
}

# --- Result ---------------------------------------------------
if ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) of $($script:Checks) checks failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll $($script:Checks) checks passed." -ForegroundColor Green
exit 0
