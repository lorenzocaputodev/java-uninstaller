# ============================================================
#  uninstall-java.ps1
#  Advanced uninstall module, invoked by uninstall-java.bat.
#  Not meant to be run on its own: it requires administrator
#  privileges, provided by the batch script that calls it.
# ============================================================

Write-Output "== Uninstalling packages via Get-Package =="
Get-Package -Name '*Java*' -ErrorAction SilentlyContinue | Uninstall-Package -Force -ErrorAction SilentlyContinue
Get-Package -Name '*JDK*'  -ErrorAction SilentlyContinue | Uninstall-Package -Force -ErrorAction SilentlyContinue

Write-Output "== Searching for native uninstallers in the registry =="
$uninstallPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Java|JDK|JRE|OpenJDK|Temurin|Zulu' } |
    ForEach-Object {
        Write-Output ("Found: " + $_.DisplayName)

        $uninstallString = $_.UninstallString
        if (-not $uninstallString) { return }

        if ($uninstallString -match 'msiexec') {
            if ($uninstallString -match '(\{[0-9A-Fa-f\-]+\})') {
                $productCode = $Matches[1]
                Start-Process 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart') -Wait -ErrorAction SilentlyContinue
            }
        }
        else {
            $exePath = $uninstallString
            $exeArgs = ''
            if ($uninstallString -match '^\s*"([^"]+)"\s*(.*)$') {
                $exePath = $Matches[1]
                $exeArgs = $Matches[2]
            }
            $exeArgs = ($exeArgs + ' /S /s /quiet /qn /norestart').Trim()
            Start-Process -FilePath $exePath -ArgumentList $exeArgs -Wait -ErrorAction SilentlyContinue
        }
    }

Write-Output "== Cleaning up Java entries from PATH (machine and user) =="
foreach ($scope in 'Machine', 'User') {
    $currentPath = [Environment]::GetEnvironmentVariable('Path', $scope)
    if (-not $currentPath) { continue }

    $cleanedPath = ($currentPath -split ';' |
        Where-Object { $_.Trim() -ne '' -and $_ -notmatch 'Java' }) -join ';'

    [Environment]::SetEnvironmentVariable('Path', $cleanedPath, $scope)
}

Write-Output "== PowerShell module completed =="
