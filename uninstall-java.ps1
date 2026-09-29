#Requires -Version 5.1
# ============================================================
#  uninstall-java.ps1
#  Removal engine of Java Uninstaller for Windows, invoked by
#  uninstall-java.bat (which handles administrator elevation
#  and the user confirmation).
#
#  Parameters:
#    -DryRun      log what would be done, change nothing
#    -OutputDir   where the log and the backup folder are
#                 created (default: the script folder, or
#                 %TEMP% when that is not writable)
#
#  Exit codes:
#    0  completed, nothing left behind
#    1  completed with warnings (see the log)
#    2  fatal error (e.g. not running as administrator)
# ============================================================
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$OutputDir
)

# $PSScriptRoot is empty inside a param() default on Windows PowerShell 5.1.
if (-not $OutputDir) { $OutputDir = $PSScriptRoot }

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:LogFile = $null
$script:LogDir = $null
$script:BackupDir = $null
$script:WarningCount = 0
$script:RebootRequired = $false
$script:EnvironmentChanged = $false

$TotalSteps = 7
$UninstallTimeoutSeconds = 600

# --- Detection rules ------------------------------------------

$JavaProcessNames = 'java', 'javaw', 'javaws', 'jp2launcher', 'jusched', 'jucheck'

# winget package IDs (prefix match); anything else is handled by the registry step.
$WingetIdPrefixes = 'Oracle.JDK', 'Oracle.JavaRuntimeEnvironment', 'EclipseAdoptium.Temurin',
'Azul.Zulu', 'Microsoft.OpenJDK', 'Amazon.Corretto', 'BellSoft.Liberica', 'AdoptOpenJDK'
$WingetIdPattern = '(?<![\w.\-])(?:' + (($WingetIdPrefixes | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[\w.\-]*'

# DisplayName patterns of the "Uninstall" registry entries that are treated as Java.
$JavaProductPatterns = @(
    '^Java(\(TM\))?\s'           # Oracle: "Java 8 Update 361", "Java(TM) SE Development Kit 17"
    '\bOpenJDK\b'                # OpenJDK builds, Microsoft Build of OpenJDK, Red Hat OpenJDK
    '\b(Temurin|Adoptium|AdoptOpenJDK)\b'
    '\bAzul Zulu\b'
    '^Zulu (JDK|JRE|Development|Runtime|\d)'
    '^Amazon Corretto\b'
    '\bLiberica\b'
    '\b(JDK|JRE)\b'
)

$UninstallRegistryPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# Folders below "Program Files" / "Program Files (x86)" (wildcards allowed).
$ProgramFilesSubfolders = 'Java', 'Eclipse Adoptium', 'AdoptOpenJDK', 'Zulu', 'Amazon Corretto',
'Common Files\Oracle\Java', 'Microsoft\jdk-*', 'BellSoft\LibericaJDK-*'

# Registry keys removed at the end (PowerShell drive syntax).
$RegistryKeysToRemove = @(
    'HKLM:\SOFTWARE\JavaSoft',
    'HKLM:\SOFTWARE\WOW6432Node\JavaSoft',
    'HKCU:\SOFTWARE\JavaSoft',
    'HKLM:\SOFTWARE\Eclipse Adoptium',
    'HKLM:\SOFTWARE\AdoptOpenJDK',
    'HKLM:\SOFTWARE\Azul Systems\Zulu',
    'HKLM:\SOFTWARE\Amazon\Corretto',
    'HKLM:\SOFTWARE\Microsoft\JDK'
)

# Environment registry keys saved (together with the keys above) before any change.
$EnvironmentBackupKeys = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'HKCU\Environment'

$JavaEnvironmentVariables = 'JAVA_HOME', 'JDK_HOME', 'JRE_HOME'

# PATH entries (already expanded, no trailing backslash) that belong to Java.
$JavaPathPatterns = @(
    '\\Program Files( \(x86\))?\\(Java|Eclipse Adoptium|AdoptOpenJDK|Zulu|Amazon Corretto|Microsoft\\jdk-[^\\]*|BellSoft\\LibericaJDK[^\\]*)(\\|$)'
    '\\Oracle\\Java(\\|$)'
    '\\(jdk|jre|java|openjdk|temurin|zulu|corretto)[-_.]?\d[^\\]*\\bin$'
)

# --- Logging --------------------------------------------------

function Out-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string]$Text, [string]$Color = 'Gray')

    Write-Host $Text -ForegroundColor $Color
    if ($script:LogFile) {
        try {
            $line = '{0:HH:mm:ss} {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine
            [IO.File]::AppendAllText($script:LogFile, $line, $Utf8NoBom)
        }
        catch { $script:LogFile = $null }
    }
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'SKIP', 'DRY')][string]$Level = 'INFO'
    )
    $colors = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red'; SKIP = 'DarkGray'; DRY = 'Cyan' }
    if ($Level -eq 'WARN') { $script:WarningCount++ }
    Out-Log ('[{0,-4}] {1}' -f $Level, $Message) $colors[$Level]
}

function Write-Step {
    param([int]$Number, [string]$Title)
    Out-Log ''
    Out-Log ('[{0}/{1}] {2}' -f $Number, $TotalSteps, $Title) 'White'
}

function Write-NativeOutput {
    param([string]$Text)
    foreach ($line in ($Text -split '\r\n|\r|\n')) {
        $line = $line.Trim()
        # Skip empty lines, the winget spinner and its progress bar.
        if ($line -and $line -notmatch '^[-\\|/]$' -and $line -notmatch '[\u2588\u2592\u2591]') {
            Out-Log ('       ' + $line) 'DarkGray'
        }
    }
}

function Initialize-Log {
    param([string]$Directory)

    foreach ($dir in @($Directory, $env:TEMP)) {
        if (-not $dir) { continue }
        try {
            $path = Join-Path $dir 'uninstall-java-log.txt'
            [IO.File]::WriteAllText($path, '', $Utf8NoBom)
            $script:LogFile = $path
            $script:LogDir = $dir
            return
        }
        catch { continue }
    }
    $script:LogDir = $env:TEMP
}

# --- Helpers --------------------------------------------------

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs $Action, or only logs it in dry-run mode. Returns $true on success.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Action)

    if ($DryRun) {
        Write-Status "Would run: $Description" 'DRY'
        return $true
    }
    try {
        $null = & $Action
        Write-Status $Description 'OK'
        return $true
    }
    catch {
        Write-Status "FAILED: $Description ($($_.Exception.Message))" 'WARN'
        return $false
    }
}

function Split-CommandLine {
    param([string]$CommandLine)

    $text = $CommandLine.Trim()
    if ($text -match '^"([^"]+)"\s*(.*)$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = $Matches[2] }
    }
    # Unquoted path that may contain spaces: cut at the first executable extension.
    if ($text -match '^(.+?\.(?:exe|bat|cmd))(?:\s+(.*))?$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = [string]$Matches[2] }
    }
    return [pscustomobject]@{ FilePath = $text; Arguments = '' }
}

# Starts a process and waits for it; returns the exit code. Kills it on timeout.
function Invoke-ExternalProcess {
    param([string]$FilePath, [string]$Arguments)

    $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
    if ($Arguments) { $startArgs.ArgumentList = $Arguments }
    $process = Start-Process @startArgs
    $null = $process.Handle   # keeps the handle open so ExitCode is readable
    if (-not $process.WaitForExit($UninstallTimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "timed out after $UninstallTimeoutSeconds seconds"
    }
    return $process.ExitCode
}

# --- Java products (registry) ---------------------------------

function Test-JavaProductName {
    param([string]$Name, [string]$Publisher)

    foreach ($pattern in $JavaProductPatterns) {
        if ($Name -match $pattern) { return $true }
    }
    # Oracle/Sun products that only mention "Java" somewhere in the name.
    return ($Publisher -match 'Oracle|Sun Microsystems') -and ($Name -match '\bJava\b')
}

function Get-JavaProduct {
    $seen = @{}
    $products = foreach ($entry in @(Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue)) {
        $name = [string]$entry.DisplayName
        if (-not $name -or -not ($entry.UninstallString -or $entry.QuietUninstallString)) { continue }
        if (-not (Test-JavaProductName $name ([string]$entry.Publisher))) { continue }

        $id = '{0}|{1}' -f $name, $entry.UninstallString
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true

        [pscustomobject]@{
            Name             = $name
            Version          = [string]$entry.DisplayVersion
            Publisher        = [string]$entry.Publisher
            Key              = $entry.PSChildName
            Uninstall        = [string]$entry.UninstallString
            QuietUninstall   = [string]$entry.QuietUninstallString
            WindowsInstaller = $entry.WindowsInstaller
        }
    }
    return @($products)
}

function Get-UninstallCommand {
    param($Product)

    $guidPattern = '\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}'

    if (($Product.Uninstall -match 'msiexec') -or ($Product.WindowsInstaller -eq 1)) {
        $guid = $null
        if ($Product.Key -match ('^' + $guidPattern + '$')) { $guid = $Product.Key }
        elseif ($Product.Uninstall -match ('(' + $guidPattern + ')')) { $guid = $Matches[1] }
        if ($guid) {
            return [pscustomobject]@{ Kind = 'MSI'; FilePath = 'msiexec.exe'; Arguments = "/x $guid /qn /norestart" }
        }
    }

    if ($Product.QuietUninstall) {
        $command = Split-CommandLine $Product.QuietUninstall
        return [pscustomobject]@{ Kind = 'quiet'; FilePath = $command.FilePath; Arguments = $command.Arguments }
    }

    # No silent command published: best effort based on the installer type.
    $command = Split-CommandLine $Product.Uninstall
    if ((Split-Path $command.FilePath -Leaf) -match '^unins\d*\.exe$') {
        $silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'   # Inno Setup
    }
    else {
        $silent = '/S'                                          # NSIS and most others
    }
    $arguments = ($command.Arguments + ' ' + $silent).Trim()
    return [pscustomobject]@{ Kind = 'best-effort'; FilePath = $command.FilePath; Arguments = $arguments }
}

# --- Environment (registry) -----------------------------------

function Test-JavaPathEntry {
    param([string]$Entry, [string[]]$JavaHomes)

    $value = $Entry.Trim().Trim('"')
    if (-not $value) { return $false }
    if ($value -match '%(JAVA_HOME|JDK_HOME|JRE_HOME)%') { return $true }

    $expanded = [Environment]::ExpandEnvironmentVariables($value).TrimEnd('\')
    foreach ($javaHome in $JavaHomes) {
        # Length guard: never treat a drive root as a Java home.
        if ($javaHome.Length -gt 3 -and
            ($expanded -eq $javaHome -or $expanded.StartsWith($javaHome + '\', [StringComparison]::OrdinalIgnoreCase))) {
            return $true
        }
    }
    foreach ($pattern in $JavaPathPatterns) {
        if ($expanded -match $pattern) { return $true }
    }
    return $false
}

# Splits a raw (unexpanded) PATH into the entries to keep and the Java ones.
# Every kept entry is preserved exactly as it was, including %VARIABLES%.
function Get-CleanedPath {
    param([string]$Path, [string[]]$JavaHomes)

    $kept = @()
    $removed = @()
    foreach ($entry in ($Path -split ';')) {
        if (Test-JavaPathEntry $entry $JavaHomes) { $removed += $entry } else { $kept += $entry }
    }
    return [pscustomobject]@{ Path = ($kept -join ';'); Removed = $removed }
}

# Removes the Java variables and Java PATH entries from one Environment registry key.
function Invoke-EnvironmentCleanup {
    param([Microsoft.Win32.RegistryKey]$Key, [string]$ScopeName, [string[]]$JavaHomes)

    foreach ($name in $JavaEnvironmentVariables) {
        if ($Key.GetValueNames() -contains $name) {
            $null = Invoke-Change "Remove variable $name ($ScopeName)" { $Key.DeleteValue($name) }
            $script:EnvironmentChanged = $true
        }
    }

    # Read the raw value and keep its type: GetEnvironmentVariable/SetEnvironmentVariable
    # would expand %VARIABLES% and rewrite PATH as a plain REG_SZ.
    $rawPath = $Key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if (-not $rawPath) {
        Write-Status "PATH ($ScopeName): empty or missing" 'SKIP'
        return
    }
    $kind = $Key.GetValueKind('Path')
    $result = Get-CleanedPath -Path $rawPath -JavaHomes $JavaHomes
    $removed = @($result.Removed)
    if ($removed.Count -eq 0) {
        Write-Status "PATH ($ScopeName): no Java entries found" 'INFO'
        return
    }
    foreach ($entry in $removed) { Write-Status "PATH ($ScopeName): '$entry'" 'INFO' }
    $null = Invoke-Change "Remove $($removed.Count) Java entries from PATH ($ScopeName)" {
        $Key.SetValue('Path', $result.Path, $kind)
    }
    $script:EnvironmentChanged = $true
}

# Tells running applications (Explorer, new shells) that the environment changed.
function Send-EnvironmentChange {
    try {
        if (-not ('JavaUninstaller.NativeMethods' -as [type])) {
            Add-Type -Namespace JavaUninstaller -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        $null = [JavaUninstaller.NativeMethods]::SendMessageTimeout([IntPtr]0xFFFF, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
        Write-Status 'Environment change broadcast to running applications' 'INFO'
    }
    catch {
        Write-Status "Could not broadcast the environment change ($($_.Exception.Message)); restart to apply it" 'WARN'
    }
}

# --- MAIN ---

Initialize-Log -Directory $OutputDir
$mode = if ($DryRun) { 'DRY RUN (nothing will be changed)' } else { 'REMOVAL' }
Out-Log "Java Uninstaller - $mode - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" 'White'
Out-Log "Running as: $env:USERDOMAIN\$env:USERNAME" 'DarkGray'

if (-not (Test-IsAdministrator)) {
    if ($DryRun) {
        Write-Status 'Not running as administrator: the preview may be incomplete' 'WARN'
    }
    else {
        Write-Status 'Administrator privileges are required. Run uninstall-java.bat instead.' 'ERR'
        exit 2
    }
}

# 1) Backup ------------------------------------------------------
Write-Step 1 'Backing up environment variables and Java registry keys'
if ($DryRun) {
    Write-Status 'No backup is created in dry-run mode' 'SKIP'
}
else {
    $script:BackupDir = Join-Path $script:LogDir ('uninstall-java-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $backupKeys = @($EnvironmentBackupKeys) + @($RegistryKeysToRemove | ForEach-Object { $_ -replace '^(HK[A-Z]+):\\', '$1\' })
    $backupFailed = -not (Invoke-Change "Create backup folder $($script:BackupDir)" {
            New-Item -ItemType Directory -Path $script:BackupDir -Force -ErrorAction Stop
        })
    if (-not $backupFailed) {
        foreach ($key in $backupKeys) {
            if (-not (Test-Path -LiteralPath ('Registry::' + $key))) { continue }
            $file = Join-Path $script:BackupDir (($key -replace '[\\ :]', '_') + '.reg')
            $exported = Invoke-Change "Export $key" {
                $null = & reg.exe export $key $file /y
                if ($LASTEXITCODE -ne 0) { throw "reg.exe exit code $LASTEXITCODE" }
            }
            if (-not $exported) { $backupFailed = $true }
        }
    }
    if ($backupFailed) {
        Write-Status 'Backup failed: aborting without touching the system.' 'ERR'
        exit 2
    }
    Write-Status 'To restore, double-click the .reg files in the backup folder' 'INFO'
}

# 2) Processes ---------------------------------------------------
Write-Step 2 'Closing running Java processes'
$running = @(Get-Process -Name $JavaProcessNames -ErrorAction SilentlyContinue)
if ($running.Count -eq 0) {
    Write-Status 'No Java process is running' 'INFO'
}
foreach ($process in $running) {
    $location = if ($process.Path) { " - $($process.Path)" } else { '' }
    $null = Invoke-Change "Terminate $($process.ProcessName).exe (PID $($process.Id))$location" {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
    }
}

# 3) winget ------------------------------------------------------
Write-Step 3 'Uninstalling known packages via winget'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Status 'winget is not available on this system' 'SKIP'
}
else {
    # "winget uninstall --name" fails when several packages match, so resolve exact IDs first.
    $wingetIds = @()
    foreach ($prefix in $WingetIdPrefixes) {
        $output = & winget list --id $prefix --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        foreach ($match in [regex]::Matches($output, $WingetIdPattern)) { $wingetIds += $match.Value }
    }
    $wingetIds = @($wingetIds | Select-Object -Unique)
    if ($wingetIds.Count -eq 0) {
        Write-Status 'No Java package known to winget is installed' 'INFO'
    }
    foreach ($id in $wingetIds) {
        $null = Invoke-Change "winget uninstall $id" {
            $output = & winget uninstall --id $id --exact --silent --disable-interactivity --accept-source-agreements 2>&1 | Out-String
            Write-NativeOutput $output
            if ($LASTEXITCODE -ne 0) { throw "winget exit code $LASTEXITCODE" }
        }
    }
}

# 4) Native uninstallers ----------------------------------------
Write-Step 4 'Uninstalling Java products found in the registry'
$products = @(Get-JavaProduct)
$uninstallFailed = $false
if ($products.Count -eq 0) {
    Write-Status 'No Java product found in Programs and Features' 'INFO'
}
foreach ($product in $products) {
    $label = "$($product.Name) $($product.Version)".Trim()
    Write-Status "Found: $label [$($product.Publisher)]" 'INFO'
}
foreach ($product in $products) {
    $command = Get-UninstallCommand $product
    $description = "Uninstall '$($product.Name)' with $($command.Kind) command: $($command.FilePath) $($command.Arguments)"
    $done = Invoke-Change $description {
        if ($command.Kind -ne 'MSI' -and -not (Test-Path -LiteralPath $command.FilePath)) {
            throw "uninstaller not found: $($command.FilePath)"
        }
        $exitCode = Invoke-ExternalProcess $command.FilePath $command.Arguments
        if ($exitCode -in 3010, 1641) { $script:RebootRequired = $true }
        elseif ($exitCode -notin 0, 1605, 1614) { throw "exit code $exitCode" }   # 1605/1614: already removed
    }
    if (-not $done) { $uninstallFailed = $true }
}
if ($products.Count -gt 0 -and -not $DryRun) {
    foreach ($left in @(Get-JavaProduct)) {
        Write-Status "Still installed after uninstall: $($left.Name)" 'WARN'
        $uninstallFailed = $true
    }
}

# 5) Folders -----------------------------------------------------
Write-Step 5 'Removing leftover folders'
if ($uninstallFailed) {
    Write-Status 'Skipped: some products could not be uninstalled (see warnings above); fix them and run again' 'SKIP'
}
else {
    $programFilesRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    $folderPatterns = @()
    foreach ($root in $programFilesRoots) {
        foreach ($subfolder in $ProgramFilesSubfolders) { $folderPatterns += Join-Path $root $subfolder }
    }
    $folderPatterns += Join-Path $env:ProgramData 'Oracle\Java'
    $folderPatterns += Join-Path $env:AppData 'Oracle\Java'
    $folderPatterns += Join-Path $env:LocalAppData 'Oracle\Java'
    $folderPatterns += Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java'

    $folders = @($folderPatterns | ForEach-Object { Get-Item -Path $_ -Force -ErrorAction SilentlyContinue } |
            Where-Object { $_.PSIsContainer })
    if ($folders.Count -eq 0) {
        Write-Status 'No leftover Java folder found' 'INFO'
    }
    foreach ($folder in $folders) {
        $null = Invoke-Change "Delete folder $($folder.FullName)" {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
        }
    }
}

# 6) Registry ----------------------------------------------------
Write-Step 6 'Removing Java registry keys'
if ($uninstallFailed) {
    Write-Status 'Skipped: some products could not be uninstalled (see warnings above)' 'SKIP'
}
else {
    $existingKeys = @($RegistryKeysToRemove | Where-Object { Test-Path -LiteralPath $_ })
    if ($existingKeys.Count -eq 0) {
        Write-Status 'No Java registry key found' 'INFO'
    }
    foreach ($key in $existingKeys) {
        $null = Invoke-Change "Delete registry key $key" { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop }
    }
}

# 7) Environment -------------------------------------------------
Write-Step 7 'Cleaning environment variables and PATH'
Write-Status "User-level changes apply to the account running this script ($env:USERNAME)" 'INFO'
$scopes = @(
    @{ Name = 'Machine'; Hive = [Microsoft.Win32.Registry]::LocalMachine; SubKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' },
    @{ Name = 'User'; Hive = [Microsoft.Win32.Registry]::CurrentUser; SubKey = 'Environment' }
)
$writable = -not $DryRun
$javaHomes = @()
foreach ($scope in $scopes) {
    $readKey = $scope.Hive.OpenSubKey($scope.SubKey, $false)
    if (-not $readKey) { continue }
    foreach ($name in $JavaEnvironmentVariables) {
        $value = $readKey.GetValue($name, $null)
        if ($value) { $javaHomes += ([string]$value).Trim().TrimEnd('\') }
    }
    $readKey.Close()
}
foreach ($scope in $scopes) {
    $key = $scope.Hive.OpenSubKey($scope.SubKey, $writable)
    if (-not $key) {
        Write-Status "Cannot open the $($scope.Name) environment key" 'WARN'
        continue
    }
    try { Invoke-EnvironmentCleanup -Key $key -ScopeName $scope.Name -JavaHomes $javaHomes }
    finally { $key.Close() }
}
foreach ($javaHome in ($javaHomes | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $javaHome) {
        Write-Status "The old JAVA_HOME folder still exists and was not touched: $javaHome" 'INFO'
    }
}
if ($script:EnvironmentChanged -and -not $DryRun) { Send-EnvironmentChange }

# Summary --------------------------------------------------------
Out-Log ''
if ($DryRun) {
    Write-Status 'Dry run completed: nothing was changed' 'INFO'
}
elseif ($script:RebootRequired) {
    Write-Status 'A restart is required to complete the removal' 'INFO'
}
if ($script:BackupDir -and (Test-Path -LiteralPath $script:BackupDir)) { Write-Status "Backup: $($script:BackupDir)" 'INFO' }
if ($script:LogFile) { Write-Status "Log: $($script:LogFile)" 'INFO' }
if ($script:WarningCount -gt 0) {
    Write-Status "Completed with $($script:WarningCount) warning(s)" 'INFO'
    exit 1
}
exit 0
