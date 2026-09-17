[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        'compile-file', 'compile-project', 'compile-all',
        'build-project', 'build-all',
        'clean-project', 'clean-all',
        'run-project', 'start-project',
        'open-project',
        'open-ide-profile', 'new-profile', 'delete-profile', 'open-ide-in-profile',
        'profile-remove-packages', 'profile-strip-library', 'profile-install-package',
        'profile-enable-package', 'profile-package-state', 'profile-add-library-path',
        'save-global-profile', 'purge-profiles'
    )]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Workspace = '',

    [Parameter(Position = 2)]
    [string]$ActiveFile = '',

    # --- профили IDE ------------------------------------------------------
    # Имя уже созданного профиля (для действий profile-*).
    [string]$ProfileName = '',

    # Соль для имени нового профиля (по умолчанию -- путь к проекту).
    [string]$ProfileHint = '',

    [switch]$KeepProfile,

    # --- операции с пакетами внутри готового профиля ----------------------
    # profile-remove-packages / profile-package-state: имена пакетов.
    [string[]]$RemovePackages = @(),

    # profile-strip-library / profile-remove-packages: подстроки чужих путей.
    [string[]]$StripLibraryPatterns = @(),

    # Что не считается чужим (обычно корень текущего проекта).
    [string]$KeepUnder = '',

    # profile-install-package: .dpk, который надо собрать и установить.
    [string]$InstallPackage = '',

    [switch]$Rebuild,

    # profile-install-package: каталог для локальной копии BPL/DCP.
    [string]$LocalCopyDir = '',

    # profile-enable-package: путь к собранному BPL.
    [string]$BplPath = '',

    # profile-enable-package: имена для поиска записей пакета.
    [string[]]$EnableMatchNames = @(),

    # profile-enable-package / profile-add-library-path: каталоги для Library.
    [string]$LibraryPath = '',
    [string[]]$LibraryPaths = @(),

    # Exact | Prefix | Contains -- как сопоставлять имена пакетов.
    [string]$PackageMatchMode = 'Prefix',

    # Каталоги, которые надо добавить в PATH процесса IDE: оттуда
    # загружаются зависимости BPL (rtl70.bpl, vcl70.bpl, соседние пакеты).
    [string[]]$AddPathDirectories = @(),

    # profile-enable-package: чистить признак «выключен» не только
    # во временном профиле, но и в глобальном профиле HKCU.
    [switch]$IncludeGlobal,

    # profile-enable-package: то же самое в HKLM (нужны права администратора).
    [switch]$IncludeHklm
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ============================================================
# Настройки временных профилей IDE (ключ -r)
# ============================================================

$script:Profile = @{

    # delphi32.exe -r<Имя> переключает ветку реестра IDE.
    # По умолчанию (Delphi 5-7): HKCU\Software\Borland\<Имя>\7.0 --
    # имя из -r подставляется вместо имени продукта, версия остаётся.
    # Если IDE раскладывает ключ иначе -- поменяйте шаблон, например
    # на '{Vendor}\Delphi\{Profile}' (HKCU\Software\Borland\Delphi\<Имя>).
    RegistryVendorKey  = 'Software\Borland'
    GlobalProfileName  = 'Delphi'
    VersionSubKey      = '7.0'
    ProfileKeyTemplate = '{Vendor}\{Profile}\{Version}'

    # Глобальный профиль -- источник, из которого делаются временные копии.
    GlobalProfileKey = 'Software\Borland\Delphi\7.0'

    # Имя временного профиля: префикс + чексумма от времени запуска.
    ProfilePrefix        = 'D7T'
    ProfileHashAlgorithm = 'MD5'
    ProfileHashLength    = 10

    # Снимок глобального профиля (.reg). Пусто -- рядом со скриптом.
    SnapshotPath     = ''
    AutoSaveSnapshot = $true

    # Подчищать осиротевшие временные профили (прерванные запуски).
    PurgeStaleProfiles = $true
    StaleProfileHours  = 12

    # Дополнительные аргументы IDE, например @('-ns').
    ExtraIdeArguments = @()
}

$script:ScriptDir = ''
try {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
catch {
    $script:ScriptDir = ''
}
if ([string]::IsNullOrWhiteSpace($script:ScriptDir)) {
    $script:ScriptDir = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($script:Profile.SnapshotPath)) {
    $script:Profile.SnapshotPath = Join-Path $script:ScriptDir 'profile'
    $script:Profile.SnapshotPath = Join-Path $script:Profile.SnapshotPath 'delphi7-global.reg'
}

if ($KeepProfile) { $script:Profile.KeepProfile = $true }

function Resolve-FullPath {
    param (
        [string]$Path,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $value = $Path.Trim()
    if ($value -match '^\$\{.*\}$') {
        return $null
    }

    $value = [Environment]::ExpandEnvironmentVariables($value)
    if (-not [IO.Path]::IsPathRooted($value)) {
        $value = Join-Path -Path $BasePath -ChildPath $value
    }

    return [IO.Path]::GetFullPath($value)
}

function Test-SkippedPath {
    param ([string]$Path)

    return $Path -match '(?i)([\\/])(\.git|\.svn|\.hg|node_modules|__history|backup)([\\/]|$)'
}

function Test-PathInside {
    param (
        [string]$Path,
        [string]$Root
    )

    $rootValue = $Root.TrimEnd('\')
    return $Path -ieq $rootValue -or
        $Path.StartsWith($rootValue + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-DelphiProjects {
    param ([string]$Root)

    @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.dpr' -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-SkippedPath $_.FullName) } |
            Sort-Object FullName
    )
}

function Get-ProjectForFile {
    param (
        [string]$Root,
        [string]$File
    )

    $filePath = Resolve-FullPath -Path $File -BasePath $Root
    if (-not $filePath -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return $null
    }

    $fileItem = Get-Item -LiteralPath $filePath
    if (-not (Test-PathInside -Path $fileItem.FullName -Root $Root)) {
        return $null
    }

    if ($fileItem.Extension -ieq '.dpr') {
        return $fileItem
    }

    $directory = $fileItem.Directory
    while ($null -ne $directory) {
        if (-not (Test-PathInside -Path $directory.FullName -Root $Root)) {
            break
        }

        $localProjects = @(
            Get-ChildItem -LiteralPath $directory.FullName -File -Filter '*.dpr' -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-SkippedPath $_.FullName) }
        )

        if ($localProjects.Count -eq 1) {
            return $localProjects[0]
        }

        if ($directory.FullName -ieq $Root) {
            break
        }
        $directory = $directory.Parent
    }

    return $null
}

function Select-DelphiProject {
    param (
        [string]$Root,
        [string]$File
    )

    $fromFile = Get-ProjectForFile -Root $Root -File $File
    if ($null -ne $fromFile) {
        return $fromFile
    }

    $projects = @(Get-DelphiProjects -Root $Root)
    if ($projects.Count -eq 0) {
        throw "No .dpr projects were found under '$Root'."
    }
    if ($projects.Count -eq 1) {
        return $projects[0]
    }

    $rootProjects = @($projects | Where-Object { $_.DirectoryName -ieq $Root })
    if ($rootProjects.Count -eq 1) {
        return $rootProjects[0]
    }

    Write-Host ''
    Write-Host 'Several Delphi projects were found. Select a project:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $projects.Count; $i++) {
        $relative = $projects[$i].FullName
        $rootPrefix = $Root.TrimEnd('\') + '\'
        if ($relative.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $relative.Substring($rootPrefix.Length)
        }
        Write-Host ("  {0}. {1}" -f ($i + 1), $relative)
    }

    $answer = Read-Host 'Project number or .dpr name'
    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and
        $number -ge 1 -and $number -le $projects.Count) {
        return $projects[$number - 1]
    }

    $selected = @(
        $projects | Where-Object {
            $_.Name -ieq $answer -or $_.FullName -ieq $answer
        }
    )
    if ($selected.Count -eq 1) {
        return $selected[0]
    }

    throw "Project '$answer' was not selected."
}

function Get-DccCandidates {
    param ([string]$Value)

    $result = @()
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $result
    }

    $expanded = $Value.Trim().Trim([char]34)
    foreach ($partValue in ($expanded -split ';')) {
        $part = $partValue.Trim().Trim([char]34)
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        if (Test-Path -LiteralPath $part -PathType Leaf) {
            $item = Get-Item -LiteralPath $part
            if ($item.Name -ieq 'dcc32.exe') {
                $result += $item.FullName
            }
            else {
                $result += (Join-Path $item.DirectoryName 'dcc32.exe')
            }
        }
        elseif (Test-Path -LiteralPath $part -PathType Container) {
            $result += (Join-Path $part 'dcc32.exe')
            $result += (Join-Path $part 'Bin\dcc32.exe')
        }
        elseif ([IO.Path]::GetFileName($part) -ieq 'dcc32.exe') {
            $result += $part
        }
        else {
            $result += (Join-Path $part 'dcc32.exe')
            $result += (Join-Path $part 'Bin\dcc32.exe')
        }
    }

    return $result
}

function Get-Dcc32Path {
    $values = @()
    $preferredNames = @(
        'DCC32', 'DCC32_EXE', 'DELPHI7_DCC32', 'DELPHI7_BIN',
        'DELPHI7_ROOT', 'DELPHI7_HOME', 'DELPHI7', 'DELPHI_ROOT',
        'DELPHI_HOME', 'DELPHI'
    )

    foreach ($name in $preferredNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values += $value
        }
    }

    $values += @(
        Get-ChildItem Env: |
            Where-Object { $_.Name -match '(?i)(delphi|dcc32|borland|d7)' } |
            Select-Object -ExpandProperty Value
    )

    $candidates = @()
    foreach ($value in $values) {
        $candidates += @(Get-DccCandidates -Value $value)
    }

    $command = Get-Command dcc32.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        if ($command.Source) {
            $candidates += $command.Source
        }
        elseif ($command.Path) {
            $candidates += $command.Path
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        try {
            $item = Get-Item -LiteralPath $candidate -ErrorAction Stop
            if (-not $item.PSIsContainer -and $item.Name -ieq 'dcc32.exe') {
                $key = $item.FullName.ToLowerInvariant()
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    return $item.FullName
                }
            }
        }
        catch {
            # Ignore an invalid optional environment variable.
        }
    }

    throw 'dcc32.exe was not found. Add Delphi 7\Bin to PATH or set DCC32/DELPHI7/DELPHI7_ROOT.'
}

function Get-Delphi32Path {
    $values = @()
    $names = @(
        'DELPHI32', 'DELPHI32_EXE', 'DELPHI7_IDE', 'DELPHI7_IDE_EXE',
        'DELPHI7_BIN', 'DELPHI7_ROOT', 'DELPHI7_HOME', 'DELPHI7',
        'DELPHI_ROOT', 'DELPHI_HOME', 'DELPHI'
    )

    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values += $value
        }
    }

    $values += @(
        Get-ChildItem Env: |
            Where-Object { $_.Name -match '(?i)(delphi|borland)' } |
            Select-Object -ExpandProperty Value
    )

    $candidates = @()
    foreach ($value in $values) {
        $part = $value.Trim().Trim([char]34)
        if ([string]::IsNullOrWhiteSpace($part)) { continue }

        if (Test-Path -LiteralPath $part -PathType Leaf) {
            $item = Get-Item -LiteralPath $part
            if ($item.Name -ieq 'delphi32.exe') {
                $candidates += $item.FullName
            }
            else {
                $candidates += (Join-Path $item.DirectoryName 'delphi32.exe')
            }
        }
        elseif (Test-Path -LiteralPath $part -PathType Container) {
            $candidates += (Join-Path $part 'delphi32.exe')
            $candidates += (Join-Path $part 'Bin\delphi32.exe')
        }
        elseif ([IO.Path]::GetFileName($part) -ieq 'delphi32.exe') {
            $candidates += $part
        }
    }

    $root = Get-Delphi7Root
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $candidates += (Join-Path $root 'delphi32.exe')
        $candidates += (Join-Path $root 'Bin\delphi32.exe')
    }

    $command = Get-Command delphi32.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        if ($command.Source) { $candidates += $command.Source }
        elseif ($command.Path) { $candidates += $command.Path }
    }

    foreach ($candidate in $candidates) {
        try {
            $item = Get-Item -LiteralPath $candidate -ErrorAction Stop
            if (-not $item.PSIsContainer -and $item.Name -ieq 'delphi32.exe') {
                return $item.FullName
            }
        }
        catch {
            # Ignore invalid optional environment values.
        }
    }

    throw 'delphi32.exe was not found. Set DELPHI32 or DELPHI7_ROOT, or add the Delphi 7 Bin directory to PATH.'
}

function Get-RegistryString {
    param (
        [string]$SubKey,
        [string]$ValueName
    )

    $views = @(
        [Microsoft.Win32.RegistryView]::Registry32,
        [Microsoft.Win32.RegistryView]::Default,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    $hives = @(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryHive]::LocalMachine
    )

    foreach ($hive in $hives) {
        foreach ($view in $views) {
            $baseKey = $null
            $key = $null
            try {
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $key = $baseKey.OpenSubKey($SubKey)
                if ($null -ne $key) {
                    $value = $key.GetValue($ValueName, $null)
                    if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                        return [string]$value
                    }
                }
            }
            catch {
                # Some registry views or keys may not exist.
            }
            finally {
                if ($null -ne $key) { $key.Dispose() }
                if ($null -ne $baseKey) { $baseKey.Dispose() }
            }
        }
    }

    return $null
}

function Get-Delphi7Root {
    $names = @('DELPHI7_ROOT', 'DELPHI7_HOME', 'DELPHI7', 'DELPHI_ROOT', 'DELPHI_HOME', 'DELPHI')
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $value = $value.Trim().Trim([char]34)
            if (Test-Path -LiteralPath $value -PathType Container) {
                if ((Split-Path -Leaf $value) -ieq 'bin') {
                    return (Split-Path -Parent $value)
                }
                return $value
            }
        }
    }

    $root = Get-RegistryString -SubKey 'Software\Borland\Delphi\7.0' -ValueName 'RootDir'
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        return $root.Trim().Trim([char]34)
    }
    return $null
}

function Get-Delphi7LibraryPath {
    $path = Get-RegistryString -SubKey 'Software\Borland\Delphi\7.0\Library' -ValueName 'Search Path'
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $root = Get-Delphi7Root
    $result = $path.Trim().Trim([char]34)
    $result = [Environment]::ExpandEnvironmentVariables($result)

    for ($i = 0; $i -lt 20; $i++) {
        $match = [regex]::Match($result, '\$\(([^)]+)\)')
        if (-not $match.Success) { break }

        $name = $match.Groups[1].Value
        if ($name -ieq 'DELPHI' -and -not [string]::IsNullOrWhiteSpace($root)) {
            $value = $root
        }
        else {
            $value = [Environment]::GetEnvironmentVariable($name)
        }
        if ([string]::IsNullOrWhiteSpace($value)) { break }
        $result = $result.Replace($match.Value, $value)
    }

    return $result
}

function Get-GlobalCompilerArguments {
    $libraryPath = Get-Delphi7LibraryPath
    if ([string]::IsNullOrWhiteSpace($libraryPath)) {
        return @()
    }

    $quote = [char]34
    return @(
        ('-U' + $quote + $libraryPath + $quote),
        ('-I' + $quote + $libraryPath + $quote),
        ('-R' + $quote + $libraryPath + $quote),
        ('-O' + $quote + $libraryPath + $quote)
    )
}

function Merge-CompilerPathArguments {
    param ([string[]]$Arguments)

    $pathOptions = @('-U', '-I', '-R', '-O')
    $values = @{}
    foreach ($option in $pathOptions) { $values[$option] = @() }
    $other = @()

    foreach ($argument in @($Arguments)) {
        $text = [string]$argument
        $matched = $false
        foreach ($option in $pathOptions) {
            if ($text.Length -ge 2 -and $text.Substring(0, 2).ToUpperInvariant() -eq $option) {
                $value = $text.Substring(2).Trim().Trim([char]34)
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $values[$option] += $value
                }
                $matched = $true
                break
            }
        }
        if (-not $matched) { $other += $text }
    }

    foreach ($argument in @(Get-GlobalCompilerArguments)) {
        $text = [string]$argument
        foreach ($option in $pathOptions) {
            if ($text.Substring(0, 2).ToUpperInvariant() -eq $option) {
                $value = $text.Substring(2).Trim().Trim([char]34)
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $values[$option] += $value
                }
                break
            }
        }
    }

    $quote = [char]34
    foreach ($option in $pathOptions) {
        if ($values[$option].Count -gt 0) {
            $other += $option + $quote + ($values[$option] -join ';') + $quote
        }
    }
    return $other
}

function Read-DofFile {
    param ([string]$Path)

    $data = @{}
    $section = ''

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $text = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text.StartsWith(';')) {
            continue
        }

        if ($text -match '^\[(.+)\]$') {
            $section = $Matches[1]
            continue
        }

        $separator = $text.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }

        $key = $text.Substring(0, $separator).Trim()
        $value = $text.Substring($separator + 1).Trim()
        $data[$section + ':' + $key] = $value
    }

    return $data
}

function Get-DofValue {
    param (
        [hashtable]$Data,
        [string]$Section,
        [string]$Key
    )

    $name = $Section + ':' + $Key
    if ($Data.ContainsKey($name)) {
        return [string]$Data[$name]
    }
    return $null
}

function Expand-DelphiValue {
    param ([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $result = $Value.Trim().Trim([char]34)
    $result = [Environment]::ExpandEnvironmentVariables($result)

    for ($i = 0; $i -lt 20; $i++) {
        $match = [regex]::Match($result, '\$\(([^)]+)\)')
        if (-not $match.Success) {
            break
        }

        $environmentName = $match.Groups[1].Value
        if ($environmentName -ieq 'DELPHI') {
            $environmentValue = Get-Delphi7Root
        }
        else {
            $environmentValue = [Environment]::GetEnvironmentVariable($environmentName)
        }
        if ([string]::IsNullOrWhiteSpace($environmentValue)) {
            break
        }
        $result = $result.Replace($match.Value, $environmentValue)
    }

    return $result
}

function Add-CfgQuoted {
    param (
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Option,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $quote = [char]34
        [void]$Lines.Add($Option + $quote + (Expand-DelphiValue $Value) + $quote)
    }
}

function Convert-DofToCfg {
    param (
        [string]$DofPath,
        [string]$CfgPath
    )

    $data = Read-DofFile -Path $DofPath
    $lines = New-Object 'System.Collections.Generic.List[string]'

    # Delphi 7 compiler switches stored in [Compiler] as A..Z.
    $compilerKeys = @(
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
        'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'
    )

    foreach ($key in $compilerKeys) {
        $value = Get-DofValue -Data $data -Section 'Compiler' -Key $key
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        $value = $value.Trim()

        if ($key -eq 'A') {
            if ($value -eq '0') {
                [void]$lines.Add('-$A-')
            }
            elseif ($value -eq '1') {
                [void]$lines.Add('-$A+')
            }
            else {
                [void]$lines.Add('-$A' + $value)
            }
        }
        elseif ($key -eq 'Y') {
            if ($value -eq '0') {
                [void]$lines.Add('-$Y-')
            }
            elseif ($value -eq '1') {
                [void]$lines.Add('-$YD')
            }
            else {
                [void]$lines.Add('-$Y+')
            }
        }
        elseif ($key -eq 'Z') {
            [void]$lines.Add('-$Z' + $value)
        }
        elseif ($value -eq '0') {
            [void]$lines.Add('-$' + $key + '-')
        }
        else {
            [void]$lines.Add('-$' + $key + '+')
        }
    }

    Add-CfgQuoted -Lines $lines -Option '-E' -Value (Get-DofValue $data 'Directories' 'OutputDir')
    Add-CfgQuoted -Lines $lines -Option '-N' -Value (Get-DofValue $data 'Directories' 'UnitOutputDir')

    $searchPath = Get-DofValue $data 'Directories' 'SearchPath'
    if ([string]::IsNullOrWhiteSpace($searchPath)) {
        $searchPath = Get-DofValue $data 'Directories' 'UnitSearchPath'
    }
    Add-CfgQuoted -Lines $lines -Option '-U' -Value $searchPath
    Add-CfgQuoted -Lines $lines -Option '-I' -Value (Get-DofValue $data 'Directories' 'IncludePath')
    Add-CfgQuoted -Lines $lines -Option '-O' -Value (Get-DofValue $data 'Directories' 'ObjPath')
    Add-CfgQuoted -Lines $lines -Option '-R' -Value (Get-DofValue $data 'Directories' 'ResourcePath')
    Add-CfgQuoted -Lines $lines -Option '-LE' -Value (Get-DofValue $data 'Directories' 'PackageDLLOutputDir')
    Add-CfgQuoted -Lines $lines -Option '-LN' -Value (Get-DofValue $data 'Directories' 'PackageDCPOutputDir')

    $conditionals = Get-DofValue $data 'Directories' 'Conditionals'
    if (-not [string]::IsNullOrWhiteSpace($conditionals)) {
        [void]$lines.Add('-D' + $conditionals.Trim())
    }

    $mapFile = Get-DofValue $data 'Linker' 'MapFile'
    if ($mapFile -eq '1') { [void]$lines.Add('-GS') }
    elseif ($mapFile -eq '2') { [void]$lines.Add('-GP') }
    elseif ($mapFile -eq '3') { [void]$lines.Add('-GD'); [void]$lines.Add('-GP') }

    $linkerDebug = Get-DofValue $data 'Linker' 'DebugInfo'
    if ($linkerDebug -eq '1') {
        [void]$lines.Add('-vn')
    }

    $usePackages = Get-DofValue $data 'Directories' 'UsePackages'
    if ($usePackages -eq '1') {
        $packages = Get-DofValue $data 'Directories' 'Packages'
        if (-not [string]::IsNullOrWhiteSpace($packages)) {
            [void]$lines.Add('-LU' + $packages.Trim())
        }
    }

    $lines | Set-Content -LiteralPath $CfgPath -Encoding ASCII
}

function Ensure-ProjectCfg {
    param ([System.IO.FileInfo]$Project)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($Project.Name)
    $cfgPath = Join-Path $Project.DirectoryName ($baseName + '.cfg')
    $dofPath = Join-Path $Project.DirectoryName ($baseName + '.dof')

    # A .dof is the source of truth. Always regenerate the .cfg before a
    # compile/build/run operation, even when an older .cfg already exists.
    if (Test-Path -LiteralPath $dofPath -PathType Leaf) {
        $temporaryCfg = $cfgPath + '.vscode.tmp'
        try {
            Convert-DofToCfg -DofPath $dofPath -CfgPath $temporaryCfg
            Move-Item -LiteralPath $temporaryCfg -Destination $cfgPath -Force
        }
        catch {
            if (Test-Path -LiteralPath $temporaryCfg -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryCfg -Force -ErrorAction SilentlyContinue
            }
            throw
        }

        Write-Host ("[Delphi] Synchronized compiler config from .dof: {0}" -f $cfgPath) -ForegroundColor Yellow
        return $cfgPath
    }

    # Without a .dof, keep an existing manually maintained .cfg.
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        return $cfgPath
    }

    return $null
}

function Get-CfgArguments {
    param ([string]$CfgPath)

    $arguments = @()
    if (-not $CfgPath -or -not (Test-Path -LiteralPath $CfgPath -PathType Leaf)) {
        return $arguments
    }

    foreach ($line in (Get-Content -LiteralPath $CfgPath)) {
        $text = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or
            $text.StartsWith(';') -or $text.StartsWith('#')) {
            continue
        }
        $arguments += $text
    }
    return $arguments
}

<#
    Переход в рабочий каталог. Для UNC-путей (\\server\share) Win32 не меняет
    текущий каталог процесса, поэтому смена каталога не обязательна: компилятор
    вызывается с полными путями (см. ниже).
#>
function Push-WorkDirectory {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        Push-Location -LiteralPath $Path -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host ("[Delphi]   note: cannot set the working directory to '{0}'; full paths are used." -f $Path) -ForegroundColor Yellow
        return $false
    }
}

function Invoke-Dcc {
    param (
        [string]$Dcc32,
        [string]$WorkingDirectory,
        [string]$InputFile,
        [string]$ProjectCfg,
        [switch]$FullBuild,
        [switch]$UseProjectCfgArguments
    )

    $compilerArguments = @()
    if ($UseProjectCfgArguments) {
        $cfgArguments = @(Get-CfgArguments -CfgPath $ProjectCfg)
        $compilerArguments += @(Merge-CompilerPathArguments -Arguments $cfgArguments)
    }
    else {
        $compilerArguments += @(Get-GlobalCompilerArguments)
    }
    $compilerArguments += '-Q'
    if ($FullBuild) {
        $compilerArguments += '-B'
    }

    # Полный путь: при UNC рабочий каталог процесса может остаться прежним.
    if (-not [IO.Path]::IsPathRooted($InputFile)) {
        $InputFile = Join-Path $WorkingDirectory $InputFile
    }
    $compilerArguments += $InputFile

    $exitCode = 1
    $pushed = Push-WorkDirectory -Path $WorkingDirectory
    try {
        Write-Host ("[Delphi] Compile: {0}" -f $InputFile) -ForegroundColor Cyan
        & $Dcc32 @compilerArguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($pushed) { Pop-Location }
    }

    if ($exitCode -ne 0) {
        throw ("dcc32 returned exit code {0}: {1}" -f $exitCode, $InputFile)
    }
}

function Get-OutputDirectories {
    param ([System.IO.FileInfo]$Project)

    $result = @($Project.DirectoryName)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($Project.Name)
    $cfgPath = Join-Path $Project.DirectoryName ($baseName + '.cfg')
    $dofPath = Join-Path $Project.DirectoryName ($baseName + '.dof')

    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $cfgPath)) {
            $text = $line.Trim()
            if ($text -match '^-[Ee](.+)$') {
                $value = $Matches[1].Trim().Trim([char]34)
                $value = Expand-DelphiValue $value
                if (-not [IO.Path]::IsPathRooted($value)) {
                    $value = Join-Path $Project.DirectoryName $value
                }
                $value = [IO.Path]::GetFullPath($value)
                if ($result -notcontains $value) { $result += $value }
            }
        }
    }

    if (Test-Path -LiteralPath $dofPath -PathType Leaf) {
        $data = Read-DofFile -Path $dofPath
        $value = Expand-DelphiValue (Get-DofValue $data 'Directories' 'OutputDir')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            if (-not [IO.Path]::IsPathRooted($value)) {
                $value = Join-Path $Project.DirectoryName $value
            }
            $value = [IO.Path]::GetFullPath($value)
            if ($result -notcontains $value) { $result += $value }
        }
    }

    return $result
}

function Get-ProjectExecutable {
    param ([System.IO.FileInfo]$Project)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($Project.Name)
    foreach ($directory in (Get-OutputDirectories -Project $Project)) {
        $candidate = Join-Path $directory ($baseName + '.exe')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return Get-Item -LiteralPath $candidate
        }
    }

    $found = @(
        Get-ChildItem -LiteralPath $Project.DirectoryName -Recurse -File -Filter ($baseName + '.exe') -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-SkippedPath $_.FullName) } |
            Sort-Object LastWriteTime -Descending
    )
    if ($found.Count -gt 0) {
        return $found[0]
    }

    throw ("{0}.exe was not found for project {1}." -f $baseName, $Project.Name)
}

function Start-Project {
    param ([System.IO.FileInfo]$Project)

    $executable = Get-ProjectExecutable -Project $Project
    Write-Host ("[Delphi] Starting: {0}" -f $executable.FullName) -ForegroundColor Green
    Start-Process -FilePath $executable.FullName -WorkingDirectory $executable.DirectoryName
}

function Get-GeneratedFiles {
    param (
        [string]$Root,
        [switch]$IncludeExe
    )

    $extensions = @('.dcu', '.map', '.tds', '.rsm')
    if ($IncludeExe) { $extensions += '.exe' }

    @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                ($extensions -contains $_.Extension.ToLowerInvariant()) -and
                (-not (Test-SkippedPath $_.FullName))
            }
    )
}

function Remove-GeneratedFiles {
    param ([object[]]$Files)

    $unique = @{}
    foreach ($file in @($Files)) {
        if ($null -ne $file -and $file.FullName) {
            $unique[$file.FullName.ToLowerInvariant()] = $file
        }
    }

    if ($unique.Count -eq 0) {
        Write-Host '[Delphi] No generated files found to remove.'
        return
    }

    $hadErrors = $false
    foreach ($file in $unique.Values) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-Host ("  removed: {0}" -f $file.FullName)
        }
        catch {
            $hadErrors = $true
            Write-Warning ("Could not remove {0}: {1}" -f $file.FullName, $_.Exception.Message)
        }
    }

    if ($hadErrors) {
        throw 'Clean finished with errors.'
    }
}

# ============================================================
# Временные профили IDE (delphi32.exe -r<Имя>)
# ============================================================

function Join-AnyPath {
    param (
        [string]$Base,
        [string[]]$Parts
    )

    if ([string]::IsNullOrWhiteSpace($Base)) {
        return $null
    }

    $separator = [string][IO.Path]::DirectorySeparatorChar
    $value = $Base.TrimEnd('\', '/')

    foreach ($part in $Parts) {
        foreach ($piece in ($part -split '[\\/]+')) {
            if ([string]::IsNullOrWhiteSpace($piece)) {
                continue
            }
            $value = $value + $separator + $piece
        }
    }

    return $value
}

function Get-FileBaseName {
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $value = $Path.Trim().Trim([char]34)
    foreach ($separator in @('\', '/')) {
        $index = $value.LastIndexOf($separator)
        if ($index -ge 0) {
            $value = $value.Substring($index + 1)
        }
    }

    return [IO.Path]::GetFileNameWithoutExtension($value)
}

<#
    Ключ имени без пробелов и регистра: 'Some Lib' -> 'somelib'.
#>
function Get-NameKey {
    param ([string]$Name)

    if ($null -eq $Name) {
        return ''
    }
    return (($Name -replace '\s+', '')).ToLowerInvariant()
}

function Test-RegistryAvailable {
    if ($null -eq ('Microsoft.Win32.RegistryKey' -as [type])) {
        return $false
    }

    $key = $null
    try {
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::CurrentUser,
            [Microsoft.Win32.RegistryView]::Default)
        return ($null -ne $key)
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Open-HkcuBaseKey {
    $views = @(
        [Microsoft.Win32.RegistryView]::Default,
        [Microsoft.Win32.RegistryView]::Registry32,
        [Microsoft.Win32.RegistryView]::Registry64
    )

    foreach ($view in $views) {
        try {
            return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
        }
        catch {
            # Следующее представление реестра.
        }
    }

    throw 'Could not open HKCU.'
}

function Open-HkcuKey {
    param (
        [string]$Path,
        [switch]$Writable
    )

    $baseKey = Open-HkcuBaseKey
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return $baseKey
        }

        $key = $baseKey.OpenSubKey($Path, [bool]$Writable)
        if ($null -eq $key) {
            $baseKey.Dispose()
            return $null
        }
        return $key
    }
    catch {
        $baseKey.Dispose()
        return $null
    }
}

function Ensure-HkcuKey {
    param ([string]$Path)

    $parts = @($Path -split '\\' | Where-Object { $_ -ne '' })
    $key = $null
    try {
        $key = Open-HkcuBaseKey
        foreach ($part in $parts) {
            $next = $key.CreateSubKey($part)
            if ($null -eq $next) {
                throw ("Could not create registry key: {0}" -f $Path)
            }
            if ($next -ne $key) {
                $key.Dispose()
            }
            $key = $next
        }
        return $key
    }
    catch {
        if ($null -ne $key) { $key.Dispose() }
        throw
    }
}

function Test-HkcuKeyExists {
    param ([string]$Path)

    $key = Open-HkcuKey -Path $Path
    if ($null -eq $key) {
        return $false
    }
    $key.Dispose()
    return $true
}

function Get-ProfileKeyPath {
    param ([string]$ProfileName)

    return ($script:Profile.ProfileKeyTemplate.
        Replace('{Vendor}', $script:Profile.RegistryVendorKey).
        Replace('{Profile}', $ProfileName).
        Replace('{Version}', $script:Profile.VersionSubKey))
}

function Get-ProfileParentPath {
    $template = $script:Profile.ProfileKeyTemplate
    $index = $template.IndexOf('{Profile}')
    if ($index -lt 0) {
        return $script:Profile.RegistryVendorKey
    }

    $prefix = $template.Substring(0, $index)
    $prefix = $prefix.Replace('{Vendor}', $script:Profile.RegistryVendorKey)
    $prefix = $prefix.Replace('{Version}', $script:Profile.VersionSubKey)

    return $prefix.TrimEnd('\', '/')
}

function Get-GlobalProfilePath {
    if (-not [string]::IsNullOrWhiteSpace($script:Profile.GlobalProfileKey)) {
        return $script:Profile.GlobalProfileKey
    }
    return (Get-ProfileKeyPath -ProfileName $script:Profile.GlobalProfileName)
}

function Copy-RegistryTree {
    param (
        $SourceKey,
        $DestinationKey
    )

    foreach ($valueName in @($SourceKey.GetValueNames())) {
        try {
            $value = $SourceKey.GetValue($valueName)
            $kind = $SourceKey.GetValueKind($valueName)
            $DestinationKey.SetValue($valueName, $value, $kind)
        }
        catch {
            Write-Host ("[Delphi]   could not copy value '{0}': {1}" -f $valueName, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    foreach ($subKeyName in @($SourceKey.GetSubKeyNames())) {
        $sourceSub = $null
        $destinationSub = $null
        try {
            $sourceSub = $SourceKey.OpenSubKey($subKeyName)
            if ($null -eq $sourceSub) {
                continue
            }
            $destinationSub = $DestinationKey.CreateSubKey($subKeyName)
            Copy-RegistryTree -SourceKey $sourceSub -DestinationKey $destinationSub
        }
        catch {
            Write-Host ("[Delphi]   could not copy subkey '{0}': {1}" -f $subKeyName, $_.Exception.Message) -ForegroundColor Yellow
        }
        finally {
            if ($null -ne $destinationSub) { $destinationSub.Dispose() }
            if ($null -ne $sourceSub) { $sourceSub.Dispose() }
        }
    }
}

<#
    Имя временного профиля: префикс + чексумма от строки времени запуска.
#>
function New-ProfileName {
    param ([string]$ProjectHint = '')

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fffffff')
    $seed = $stamp + '|' + $PID + '|' + $ProjectHint

    switch -Regex ($script:Profile.ProfileHashAlgorithm) {
        '^(?i)sha1$' { $algorithm = [System.Security.Cryptography.SHA1]::Create(); break }
        '^(?i)sha256$' { $algorithm = [System.Security.Cryptography.SHA256]::Create(); break }
        default { $algorithm = [System.Security.Cryptography.MD5]::Create() }
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($seed)
    $hash = ($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''

    $length = [int]$script:Profile.ProfileHashLength
    if ($length -lt 4) { $length = 4 }
    if ($length -gt $hash.Length) { $length = $hash.Length }

    return ($script:Profile.ProfilePrefix + '-' + $hash.Substring(0, $length))
}

function Save-GlobalProfileSnapshot {
    param ([string]$Path)

    if (-not (Test-RegistryAvailable)) {
        throw 'Registry is not available.'
    }

    $sourcePath = Get-GlobalProfilePath
    if (-not (Test-HkcuKeyExists -Path $sourcePath)) {
        throw ("Global IDE profile was not found: HKCU\{0}" -f $sourcePath)
    }

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }

    $reg = Get-Command reg.exe -ErrorAction SilentlyContinue
    if ($null -eq $reg) {
        throw 'reg.exe was not found: cannot export the global profile.'
    }

    & $reg.Source 'export' ('HKCU\' + $sourcePath) ('"' + $Path + '"') '/y' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg export failed with code {0}." -f $LASTEXITCODE)
    }

    Write-Host ("[Delphi] Saved global IDE profile snapshot: {0}" -f $Path) -ForegroundColor Green
}

function Import-SnapshotIntoProfile {
    param (
        [string]$Path,
        [string]$ProfileName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $reg = Get-Command reg.exe -ErrorAction SilentlyContinue
    if ($null -eq $reg) {
        return $false
    }

    try {
        $content = [IO.File]::ReadAllText($Path, [Text.Encoding]::Unicode)
        $sourceHeader = 'HKEY_CURRENT_USER\' + (Get-GlobalProfilePath)
        $targetHeader = 'HKEY_CURRENT_USER\' + (Get-ProfileKeyPath -ProfileName $ProfileName)

        if (-not $content.Contains($sourceHeader)) {
            return $false
        }

        $content = $content.Replace($sourceHeader, $targetHeader)
        $temporary = $Path + '.tmp.reg'
        [IO.File]::WriteAllText($temporary, $content, [Text.Encoding]::Unicode)

        try {
            & $reg.Source 'import' ('"' + $temporary + '"') | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        finally {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Host ("[Delphi]   could not import the profile snapshot: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Remove-DelphiProfile {
    param ([string]$ProfileName)

    $parentKey = Open-HkcuKey -Path (Get-ProfileParentPath) -Writable
    if ($null -eq $parentKey) {
        return
    }

    try {
        $parentKey.DeleteSubKeyTree($ProfileName)
    }
    catch {
        Write-Host ("[Delphi]   could not delete profile '{0}': {1}" -f $ProfileName, $_.Exception.Message) -ForegroundColor Yellow
    }
    finally {
        $parentKey.Dispose()
    }
}

function New-DelphiTempProfile {
    param (
        [string]$ProjectHint = '',
        [string]$ProjectFile = '',
        [string]$Name = ''
    )

    if (-not (Test-RegistryAvailable)) {
        throw 'Registry is not available: a temporary IDE profile can be created on Windows only.'
    }

    $globalPath = Get-GlobalProfilePath
    $globalKey = Open-HkcuKey -Path $globalPath

    if ($null -eq $globalKey) {
        Write-Host ("[Delphi] Global IDE profile HKCU\{0} was not found." -f $globalPath) -ForegroundColor Yellow
    }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $profileName = $Name
    }
    else {
        $profileName = New-ProfileName -ProjectHint $ProjectHint
    }

    $attempt = 0
    while (Test-HkcuKeyExists -Path (Get-ProfileKeyPath -ProfileName $profileName)) {
        $attempt++
        if ($attempt -gt 20) {
            throw 'Could not generate a free temporary profile name.'
        }
        $profileName = New-ProfileName -ProjectHint ($ProjectHint + '#' + $attempt)
    }

    Remove-DelphiProfile -ProfileName $profileName

    $targetKey = Ensure-HkcuKey -Path (Get-ProfileKeyPath -ProfileName $profileName)
    try {
        if ($null -ne $globalKey) {
            Copy-RegistryTree -SourceKey $globalKey -DestinationKey $targetKey
        }
        elseif (Import-SnapshotIntoProfile -Path $script:Profile.SnapshotPath -ProfileName $profileName) {
            Write-Host ("[Delphi] Profile restored from snapshot: {0}" -f $script:Profile.SnapshotPath) -ForegroundColor Yellow
        }
        else {
            Write-Host '[Delphi] Profile created empty: the IDE will fill it with defaults.' -ForegroundColor Yellow
        }

        $targetKey.SetValue('DelphiTempProfileCreated', [DateTime]::UtcNow.ToString('o'), [Microsoft.Win32.RegistryValueKind]::String)
        if (-not [string]::IsNullOrWhiteSpace($ProjectFile)) {
            $targetKey.SetValue('DelphiTempProfileProject', $ProjectFile, [Microsoft.Win32.RegistryValueKind]::String)
        }
    }
    finally {
        $targetKey.Dispose()
        if ($null -ne $globalKey) { $globalKey.Dispose() }
    }

    Write-Host ("[Delphi] Temporary IDE profile: HKCU\{0}" -f (Get-ProfileKeyPath -ProfileName $profileName))
    return $profileName
}

function Get-DelphiProfileNames {
    $result = @()
    $prefix = $script:Profile.ProfilePrefix

    $parentKey = Open-HkcuKey -Path (Get-ProfileParentPath)
    if ($null -eq $parentKey) {
        return $result
    }

    try {
        foreach ($name in @($parentKey.GetSubKeyNames())) {
            if (-not $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if ($name -ieq $script:Profile.GlobalProfileName) {
                continue
            }
            $result += $name
        }
    }
    finally {
        $parentKey.Dispose()
    }

    return @($result | Sort-Object)
}

function Get-ActiveDelphiProfileNames {
    $result = @{}

    $processes = @()
    try {
        if ($null -ne (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
            $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'delphi32.exe'" -ErrorAction Stop)
        }
        else {
            $processes = @(Get-WmiObject -Class Win32_Process -Filter "Name = 'delphi32.exe'" -ErrorAction Stop)
        }
    }
    catch {
        return $result
    }

    foreach ($process in $processes) {
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }
        if ($commandLine -match '(?i)[-/]r(["'']?)([^"''\s]+)\1') {
            $result[$Matches[2]] = $true
        }
    }

    return $result
}

function Remove-StaleDelphiProfiles {
    param ([switch]$All)

    if (-not (Test-RegistryAvailable)) {
        return
    }

    if (-not $All -and -not $script:Profile.PurgeStaleProfiles) {
        return
    }

    $names = @(Get-DelphiProfileNames)
    if ($names.Count -eq 0) {
        return
    }

    $active = Get-ActiveDelphiProfileNames
    $hours = [double]$script:Profile.StaleProfileHours
    $removed = 0

    foreach ($name in $names) {
        if ($active.ContainsKey($name)) {
            continue
        }

        if (-not $All) {
            $key = Open-HkcuKey -Path (Get-ProfileKeyPath -ProfileName $name)
            $created = $null
            if ($null -ne $key) {
                try {
                    $raw = [string]$key.GetValue('DelphiTempProfileCreated', '')
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $created = [DateTime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                    }
                }
                catch {
                    $created = $null
                }
                finally {
                    $key.Dispose()
                }
            }

            if ($null -ne $created) {
                $age = ([DateTime]::UtcNow - $created.ToUniversalTime()).TotalHours
                if ($age -lt $hours) {
                    continue
                }
            }
        }

        Write-Host ("[Delphi]   removed stale profile: {0}" -f $name) -ForegroundColor Yellow
        Remove-DelphiProfile -ProfileName $name
        $removed++
    }

    if ($removed -eq 0) {
        Write-Host '[Delphi] No stale profiles found.'
    }
}

<#
    Удаляет установленные пакеты из профиля: Known Packages,
    Disabled Packages и Package Cache.
#>
function Test-PackageNameMatch {
    param (
        [string]$Value,
        [string]$Pattern,
        [string]$Mode = 'Prefix'
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or [string]::IsNullOrWhiteSpace($Pattern)) {
        return $false
    }

    switch -Regex ($Mode) {
        '^(?i)exact$' { return ($Value -eq $Pattern) }
        '^(?i)contains$' { return $Value.Contains($Pattern) }
        default { return $Value.StartsWith($Pattern) }
    }
}

<#
    Удаляет из профиля чужие пакеты: путь содержит один из образцов
    (например 'mylib'), но лежит вне каталога KeepUnder.
    Так из временного профиля исчезают ссылки на другие копии проекта.
#>
function Remove-ForeignProfilePackages {
    param (
        [string]$ProfileName,
        [string[]]$Patterns,
        [string]$KeepUnder = ''
    )

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return
    }

    $keep = ''
    if (-not [string]::IsNullOrWhiteSpace($KeepUnder)) {
        $keep = Get-NameKey $KeepUnder
    }

    foreach ($subKey in @('Known Packages', 'Disabled Packages', 'Package Cache')) {
        $path = (Get-ProfileKeyPath -ProfileName $ProfileName) + '\' + $subKey
        $key = Open-HkcuKey -Path $path -Writable
        if ($null -eq $key) {
            continue
        }

        try {
            foreach ($valueName in @($key.GetValueNames())) {
                if ([string]::IsNullOrWhiteSpace($valueName)) {
                    continue
                }

                $normalized = Get-NameKey $valueName
                $match = $false
                foreach ($pattern in $Patterns) {
                    if ($normalized.Contains((Get-NameKey $pattern))) {
                        $match = $true
                        break
                    }
                }

                if (-not $match) {
                    continue
                }
                if (-not [string]::IsNullOrWhiteSpace($keep) -and $normalized.Contains($keep)) {
                    continue
                }

                Write-Host ("[Delphi]   removed foreign package from '{0}': {1}" -f $subKey, $valueName)
                $key.DeleteValue($valueName)
            }
        }
        finally {
            $key.Dispose()
        }
    }
}

<#
    Включает пакет: удаляет его путь из Disabled Packages и Package Cache,
    оставляя запись в Known Packages (именно так IDE показывает галочку).
#>
function Enable-ProfilePackage {
    param (
        [string]$ProfileName,
        [string]$BplPath,
        [string[]]$MatchNames = @(),
        [string]$LibraryPath = '',
        [string]$MatchMode = 'Prefix',
        [switch]$IncludeGlobal,
        [switch]$IncludeHklm
    )

    $target = Get-NameKey $BplPath
    $names = @()
    foreach ($name in $MatchNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names += (Get-NameKey $name)
        }
    }

    foreach ($subKey in @('Disabled Packages', 'Package Cache')) {
        $targets = Get-PackageStateKeys -SubKey $subKey -IncludeGlobal:$IncludeGlobal -IncludeHklm:$IncludeHklm
        $key = $null

        foreach ($item in $targets) {
            if ($item.Name -eq 'profile') {
                $base = Get-ProfileKeyPath -ProfileName $ProfileName
            }
            else {
                $base = Get-GlobalProfilePath
            }

            if ([string]::IsNullOrWhiteSpace($base)) {
                continue
            }

            $path = $base + '\' + $subKey
            $key = Open-AnyKey -Path $path -Hive $item.Hive -Writable
            if ($null -eq $key) {
                continue
            }

            try {
                foreach ($valueName in @($key.GetValueNames())) {
                    if ([string]::IsNullOrWhiteSpace($valueName)) {
                        continue
                    }

                    $normalized = Get-NameKey $valueName
                    $remove = ($normalized -eq $target)

                    if (-not $remove) {
                        $base = Get-NameKey (Get-FileBaseName -Path $valueName)
                        foreach ($name in $names) {
                            if (Test-PackageNameMatch -Value $base -Pattern $name -Mode $MatchMode) {
                                $remove = $true
                                break
                            }
                        }
                    }

                    if ($remove) {
                        Write-Host ("[Delphi]   enabled package (removed from '{0}' / {1}): {2}" -f $subKey, $item.Name, $valueName)
                        $key.DeleteValue($valueName)
                    }
                }
            }
            finally {
                $key.Dispose()
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LibraryPath)) {
        Add-ProfileLibraryPath -ProfileName $ProfileName -Paths @($LibraryPath)
    }
}

function Add-ProfileLibraryPath {
    param (
        [string]$ProfileName,
        [string[]]$Paths
    )

    if ($null -eq $Paths -or $Paths.Count -eq 0) {
        return
    }

    $key = Ensure-HkcuKey -Path ((Get-ProfileKeyPath -ProfileName $ProfileName) + '\Library')
    try {
        $current = [string]$key.GetValue('Search Path', '')
        $entries = @($current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $changed = $false

        foreach ($item in $Paths) {
            if ([string]::IsNullOrWhiteSpace($item)) {
                continue
            }

            $exists = $false
            foreach ($entry in $entries) {
                if ((Get-NameKey $entry) -eq (Get-NameKey $item)) {
                    $exists = $true
                    break
                }
            }

            if (-not $exists) {
                $entries = @($item) + $entries
                $changed = $true
                Write-Host ("[Delphi]   added to the profile library path: {0}" -f $item)
            }
        }

        if ($changed) {
            $key.SetValue('Search Path', ($entries -join ';'), [Microsoft.Win32.RegistryValueKind]::String)
        }
    }
    finally {
        $key.Dispose()
    }
}

<#
    Диагностика: что записано в Known Packages профиля, включено ли,
    существует ли файл. Печатается перед запуском IDE.
#>
function Show-ProfilePackageState {
    param (
        [string]$ProfileName,
        [string[]]$MatchNames,
        [string]$MatchMode = 'Prefix',
        [switch]$IncludeGlobal,
        [switch]$IncludeHklm
    )

    $names = @()
    foreach ($name in $MatchNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names += (Get-NameKey $name)
        }
    }
    if ($names.Count -eq 0) {
        return
    }

    # Откуда читаем: временный профиль (+ при необходимости глобальный и HKLM).
    $sources = New-Object 'System.Collections.Generic.List[object]'
    [void]$sources.Add([pscustomobject]@{ Name = 'profile'; Hive = 'CurrentUser'; Base = (Get-ProfileKeyPath -ProfileName $ProfileName) })
    if ($IncludeGlobal) {
        [void]$sources.Add([pscustomobject]@{ Name = 'global'; Hive = 'CurrentUser'; Base = (Get-GlobalProfilePath) })
    }
    if ($IncludeHklm) {
        [void]$sources.Add([pscustomobject]@{ Name = 'hklm'; Hive = 'LocalMachine'; Base = (Get-GlobalProfilePath) })
    }

    $shown = 0

    foreach ($source in $sources) {
        foreach ($subKey in @('Known Packages', 'Disabled Packages', 'Package Cache')) {
            $key = Open-AnyKey -Path ($source.Base + '\' + $subKey) -Hive $source.Hive
            if ($null -eq $key) {
                continue
            }

            try {
                foreach ($valueName in @($key.GetValueNames())) {
                    if ([string]::IsNullOrWhiteSpace($valueName)) {
                        continue
                    }

                    $base = Get-NameKey (Get-FileBaseName -Path $valueName)
                    $hit = $false
                    foreach ($name in $names) {
                        if (Test-PackageNameMatch -Value $base -Pattern $name -Mode $MatchMode) {
                            $hit = $true
                            break
                        }
                    }

                    if (-not $hit) {
                        continue
                    }

                    $state = switch ($subKey) {
                        'Known Packages' { 'в Known Packages' }
                        'Disabled Packages' { 'ВЫКЛЮЧЕН (Disabled Packages)' }
                        default { 'в Package Cache' }
                    }

                    $fileState = ''
                    if ($subKey -eq 'Known Packages') {
                        $fileState = ' (файл не найден)'
                        try {
                            if (Test-Path -LiteralPath $valueName -PathType Leaf) {
                                $fileState = ' (файл найден)'
                            }
                        }
                        catch {
                            $fileState = ' (путь недоступен)'
                        }
                    }

                    Write-Host ("[Delphi]   [{0,-9}] {1,-31} {2}{3}" -f $source.Name, $state, $valueName, $fileState)
                    $shown++
                }
            }
            finally {
                $key.Dispose()
            }
        }
    }

    if ($shown -eq 0) {
        Write-Host ("[Delphi]   [WARNING] записей пакета не найдено: {0}" -f ($MatchNames -join ', ')) -ForegroundColor Yellow
    }
}

<#
    Ключи, в которых IDE хранит признак «пакет выключен».
    Порядок: временный профиль, глобальный профиль HKCU, HKLM.
#>
function Get-PackageStateKeys {
    param (
        [string]$SubKey,
        [switch]$IncludeGlobal,
        [switch]$IncludeHklm
    )

    $result = @()
    $result += [pscustomobject]@{ Name = 'profile'; Hive = 'CurrentUser'; SubKey = $SubKey }

    if ($IncludeGlobal) {
        $result += [pscustomobject]@{ Name = 'global'; Hive = 'CurrentUser'; SubKey = $SubKey }
    }
    if ($IncludeHklm) {
        $result += [pscustomobject]@{ Name = 'hklm'; Hive = 'LocalMachine'; SubKey = $SubKey }
    }

    return $result
}

function Open-AnyKey {
    param (
        [string]$Path,
        [string]$Hive = 'CurrentUser',
        [switch]$Writable
    )

    $hiveValue = if ($Hive -ieq 'LocalMachine') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }

    foreach ($view in @([Microsoft.Win32.RegistryView]::Default, [Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveValue, $view)
            if ([string]::IsNullOrWhiteSpace($Path)) {
                return $baseKey
            }
            $key = $baseKey.OpenSubKey($Path, [bool]$Writable)
            if ($null -ne $key) {
                $baseKey.Dispose()
                return $key
            }
            $baseKey.Dispose()
        }
        catch {
            # следующее представление реестра
        }
    }

    return $null
}

function Remove-ProfilePackages {
    param (
        [string]$ProfileName,
        [string[]]$PackageNames,
        [string[]]$ForeignPatterns = @(),
        [string]$KeepUnder = '',
        [string]$MatchMode = 'Prefix'
    )

    if ($null -ne $ForeignPatterns -and $ForeignPatterns.Count -gt 0) {
        Remove-ForeignProfilePackages -ProfileName $ProfileName -Patterns $ForeignPatterns -KeepUnder $KeepUnder
    }

    if ($null -eq $PackageNames -or $PackageNames.Count -eq 0) {
        return
    }

    $removed = 0
    foreach ($subKey in @('Known Packages', 'Disabled Packages', 'Package Cache')) {
        $path = (Get-ProfileKeyPath -ProfileName $ProfileName) + '\' + $subKey
        $key = Open-HkcuKey -Path $path -Writable
        if ($null -eq $key) {
            continue
        }

        try {
            foreach ($valueName in @($key.GetValueNames())) {
                if ([string]::IsNullOrWhiteSpace($valueName)) {
                    continue
                }

                $fileKey = Get-NameKey (Get-FileBaseName -Path ([string]$valueName))
                if ([string]::IsNullOrWhiteSpace($fileKey)) {
                    continue
                }

                foreach ($packageName in $PackageNames) {
                    if (Test-PackageNameMatch -Value $fileKey -Pattern (Get-NameKey $packageName) -Mode $MatchMode) {
                        $key.DeleteValue($valueName)
                        Write-Host ("[Delphi]   removed package from '{0}': {1}" -f $subKey, $valueName)
                        $removed++
                        break
                    }
                }
            }
        }
        finally {
            $key.Dispose()
        }
    }

    if ($removed -eq 0) {
        Write-Host '[Delphi]   no matching packages were found in the temporary profile.'
    }
}

function Add-ProfilePackage {
    param (
        [string]$ProfileName,
        [string]$BplPath,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = [IO.Path]::GetFileNameWithoutExtension($BplPath)
    }

    $key = Ensure-HkcuKey -Path ((Get-ProfileKeyPath -ProfileName $ProfileName) + '\Known Packages')
    try {
        $key.SetValue($BplPath, $Description, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $key.Dispose()
    }

    Write-Host ("[Delphi]   registered package: {0}" -f $BplPath)
}

<#
    Из Library\Search Path временного профиля вырезаются чужие пути
    (например, глобальные пути к другой копии проекта).
#>
function Update-ProfileLibraryPath {
    param (
        [string]$ProfileName,
        [string[]]$StripPatterns,
        [string]$KeepUnder = ''
    )

    if ($null -eq $StripPatterns -or $StripPatterns.Count -eq 0) {
        return
    }

    $key = Open-HkcuKey -Path ((Get-ProfileKeyPath -ProfileName $ProfileName) + '\Library') -Writable
    if ($null -eq $key) {
        return
    }

    try {
        $current = [string]$key.GetValue('Search Path', '')
        if ([string]::IsNullOrWhiteSpace($current)) {
            return
        }

        $entries = @($current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $result = New-Object 'System.Collections.Generic.List[string]'
        $changed = $false

        foreach ($entry in $entries) {
            $expanded = Expand-DelphiValue $entry
            if ([string]::IsNullOrWhiteSpace($expanded)) {
                continue
            }

            $normalized = Get-NameKey $expanded
            $strip = $false
            foreach ($pattern in $StripPatterns) {
                $patternKey = Get-NameKey $pattern
                if (-not [string]::IsNullOrWhiteSpace($patternKey) -and $normalized.Contains($patternKey)) {
                    $strip = $true
                    break
                }
            }

            if ($strip -and -not [string]::IsNullOrWhiteSpace($KeepUnder)) {
                $rootValue = $KeepUnder.TrimEnd('\', '/')
                $pathValue = $expanded.TrimEnd('\', '/')
                if ($pathValue.StartsWith($rootValue + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                    $pathValue -ieq $rootValue) {
                    $strip = $false
                }
            }

            if ($strip) {
                Write-Host ("[Delphi]   removed foreign library path: {0}" -f $entry)
                $changed = $true
                continue
            }

            [void]$result.Add($entry)
        }

        if ($changed) {
            $key.SetValue('Search Path', ($result -join ';'), [Microsoft.Win32.RegistryValueKind]::String)
        }
    }
    finally {
        $key.Dispose()
    }
}

# ============================================================
# Сборка и установка пакета во временный профиль
# ============================================================

function Get-DofCompilerArguments {
    param (
        [string]$DofPath,
        [string]$ProjectDir,
        [string[]]$StripPatterns = @()
    )

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $quote = [char]34

    if (-not (Test-Path -LiteralPath $DofPath -PathType Leaf)) {
        return @()
    }

    $data = Read-DofFile -Path $DofPath

    $mapping = @(
        @{ Option = '-U'; Key = 'SearchPath' },
        @{ Option = '-I'; Key = 'IncludePath' },
        @{ Option = '-R'; Key = 'ResourcePath' },
        @{ Option = '-O'; Key = 'ObjPath' },
        @{ Option = '-E'; Key = 'OutputDir' },
        @{ Option = '-N'; Key = 'UnitOutputDir' },
        @{ Option = '-LE'; Key = 'PackageDLLOutputDir' },
        @{ Option = '-LN'; Key = 'PackageDCPOutputDir' }
    )

    foreach ($item in $mapping) {
        $raw = Get-DofValue -Data $data -Section 'Directories' -Key $item.Key
        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }

        $values = @()
        foreach ($part in ($raw -split ';')) {
            $trimmed = $part.Trim().Trim([char]34)
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            $expanded = Expand-DelphiValue $trimmed
            if ([string]::IsNullOrWhiteSpace($expanded)) {
                continue
            }

            if (-not [IO.Path]::IsPathRooted($expanded)) {
                $expanded = [IO.Path]::GetFullPath((Join-Path $ProjectDir $expanded))
            }
            else {
                $expanded = [IO.Path]::GetFullPath($expanded)
            }

            if ($values -notcontains $expanded) {
                $values += $expanded
            }
        }

        if ($values.Count -eq 0) {
            continue
        }

        [void]$arguments.Add($item.Option + $quote + ($values -join ';') + $quote)
    }

    # Глобальный Library path Delphi 7.
    $global = @()
    $libraryPath = Get-Delphi7LibraryPath
    if (-not [string]::IsNullOrWhiteSpace($libraryPath)) {
        foreach ($entry in ($libraryPath -split ';')) {
            $value = $entry.Trim().Trim([char]34)
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $normalized = Get-NameKey $value
            $strip = $false
            foreach ($pattern in $StripPatterns) {
                $patternKey = Get-NameKey $pattern
                if (-not [string]::IsNullOrWhiteSpace($patternKey) -and $normalized.Contains($patternKey)) {
                    $strip = $true
                    break
                }
            }

            if ($strip) {
                Write-Host ("[Delphi]   ignored global library path: {0}" -f $value)
                continue
            }

            $global += $value
        }
    }

    if ($global.Count -gt 0) {
        $library = $quote + ($global -join ';') + $quote
        [void]$arguments.Add('-I' + $library)
        [void]$arguments.Add('-R' + $library)
        [void]$arguments.Add('-O' + $library)

        $existingU = $null
        foreach ($argument in $arguments) {
            if ($argument.StartsWith('-U')) {
                $existingU = $argument
                break
            }
        }

        if ($null -ne $existingU) {
            $arguments.Remove($existingU) | Out-Null
            $merged = $existingU.Substring(2).Trim().Trim([char]34) + ';' + ($global -join ';')
            [void]$arguments.Add('-U' + $quote + $merged + $quote)
        }
        else {
            [void]$arguments.Add('-U' + $library)
        }
    }

    $conditionals = Get-DofValue -Data $data -Section 'Directories' -Key 'Conditionals'
    if (-not [string]::IsNullOrWhiteSpace($conditionals)) {
        [void]$arguments.Add('-D' + $conditionals.Trim())
    }

    return @($arguments)
}

function Find-PackageBinary {
    param (
        [string]$PackageFile,
        [string]$PackageDir,
        [string]$DofPath
    )

    $baseName = [IO.Path]::GetFileNameWithoutExtension($PackageFile)
    $directories = New-Object 'System.Collections.Generic.List[string]'

    if (Test-Path -LiteralPath $DofPath -PathType Leaf) {
        $data = Read-DofFile -Path $DofPath
        foreach ($key in @('PackageDLLOutputDir', 'OutputDir')) {
            $value = Get-DofValue -Data $data -Section 'Directories' -Key $key
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $expanded = Expand-DelphiValue $value
            if ([string]::IsNullOrWhiteSpace($expanded)) {
                continue
            }

            if (-not [IO.Path]::IsPathRooted($expanded)) {
                $expanded = [IO.Path]::GetFullPath((Join-Path $PackageDir $expanded))
            }

            [void]$directories.Add([IO.Path]::GetFullPath($expanded))
        }
    }

    [void]$directories.Add($PackageDir)

    $parent = Split-Path -Parent $PackageDir
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void]$directories.Add($parent)
    }

    $root = Get-Delphi7Root
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        [void]$directories.Add((Join-AnyPath -Base $root -Parts 'Projects\Bpl'))
    }

    # Порядок каталогов = приоритет: сначала те, куда писал dcc32.
    foreach ($directory in $directories) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }

        $candidate = Join-AnyPath -Base $directory -Parts ($baseName + '.bpl')
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return Get-Item -LiteralPath $candidate
            }
        }
        catch {
            # Недоступный диск или некорректный путь -- пропускаем.
        }
    }

    return $null
}

function Install-DelphiPackage {
    param (
        [string]$PackageFile,
        [string]$ProfileName,
        [string[]]$StripPatterns = @(),
        [string]$LocalCopyDir = '',
        [switch]$Rebuild
    )

    if ([string]::IsNullOrWhiteSpace($PackageFile)) {
        return
    }

    if (-not (Test-Path -LiteralPath $PackageFile -PathType Leaf)) {
        throw ("Package source was not found: {0}" -f $PackageFile)
    }

    $packageItem = Get-Item -LiteralPath $PackageFile
    $packageDir = $packageItem.DirectoryName
    $baseName = [IO.Path]::GetFileNameWithoutExtension($packageItem.Name)
    $dofPath = Join-Path $packageDir ($baseName + '.dof')

    Write-Host ("[Delphi] Building package: {0}" -f $packageItem.Name) -ForegroundColor Cyan

    $dcc32 = Get-Dcc32Path
    $arguments = @(Get-DofCompilerArguments -DofPath $dofPath -ProjectDir $packageDir -StripPatterns $StripPatterns)
    $arguments += '-Q'
    if ($Rebuild) {
        $arguments += '-B'
    }
    $arguments += $packageItem.FullName

    $exitCode = 1
    $pushed = Push-WorkDirectory -Path $packageDir
    try {
        Write-Host ("[Delphi]   dcc32 {0}" -f ($arguments -join ' '))
        & $dcc32 @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($pushed) { Pop-Location }
    }

    if ($exitCode -ne 0) {
        throw ("dcc32 returned exit code {0}: {1}" -f $exitCode, $packageItem.Name)
    }

    $bpl = Find-PackageBinary -PackageFile $packageItem.Name -PackageDir $packageDir -DofPath $dofPath
    if ($null -eq $bpl) {
        throw ("{0}.bpl was not found after the build." -f $baseName)
    }

    if (-not (Test-Path -LiteralPath $bpl.FullName -PathType Leaf)) {
        throw ("Package binary is missing: {0}" -f $bpl.FullName)
    }

    # По желанию вызывающего: копия BPL/DCP в локальный каталог
    # (если IDE не грузит пакеты с UNC-пути или сетевой шары).
    if (-not [string]::IsNullOrWhiteSpace($LocalCopyDir)) {
        $target = $LocalCopyDir

        try {
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
            }

            $localBpl = Join-Path $target $bpl.Name
            Copy-Item -LiteralPath $bpl.FullName -Destination $localBpl -Force

            $dcpSource = Join-Path $bpl.DirectoryName ($baseName + '.dcp')
            if (Test-Path -LiteralPath $dcpSource -PathType Leaf) {
                Copy-Item -LiteralPath $dcpSource -Destination (Join-Path $target ($baseName + '.dcp')) -Force
            }

            $bpl = Get-Item -LiteralPath $localBpl
            Write-Host ("[Delphi]   local copy registered: {0}" -f $bpl.FullName)
        }
        catch {
            Write-Host ("[Delphi]   could not copy the package locally: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    Add-ProfilePackage -ProfileName $ProfileName -BplPath $bpl.FullName -Description $baseName

    return $bpl
}

<#
    Подготовка окружения профилей: подчистка осиротевших профилей
    и снимок глобального профиля (если его ещё нет).
#>
function Initialize-TempProfileEnvironment {
    Remove-StaleDelphiProfiles

    if ($script:Profile.AutoSaveSnapshot -and -not (Test-Path -LiteralPath $script:Profile.SnapshotPath -PathType Leaf)) {
        try {
            Save-GlobalProfileSnapshot -Path $script:Profile.SnapshotPath
        }
        catch {
            Write-Host ("[Delphi] Could not save the global profile snapshot: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

<#
    Запуск IDE в уже созданном профиле: delphi32.exe -r<Имя> "<проект>"
    и ожидание закрытия.
#>
function Invoke-DelphiIdeInProfile {
    param (
        [string]$ProfileName,
        [string]$ProjectFile,
        [string[]]$AddPathDirectories = @()
    )

    if ([string]::IsNullOrWhiteSpace($ProfileName)) {
        throw 'ProfileName is required.'
    }

    if ([string]::IsNullOrWhiteSpace($ProjectFile) -or -not (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) {
        throw ("Project file was not found: {0}" -f $ProjectFile)
    }

    if (-not (Test-HkcuKeyExists -Path (Get-ProfileKeyPath -ProfileName $ProfileName))) {
        throw ("Profile was not found: HKCU\{0}" -f (Get-ProfileKeyPath -ProfileName $ProfileName))
    }

    $projectItem = Get-Item -LiteralPath $ProjectFile
    $ide = Get-Delphi32Path

    <#
        Зависимости BPL (rtl70.bpl, vcl70.bpl, designide70.bpl и соседние
        пакеты проекта) Windows ищет по PATH. Каталог самого загружаемого
        BPL в поиск не входит -- поэтому при загрузке пакета из папки
        проекта (особенно с UNC-пути) получаем ошибку 126
        "Не найден указанный модуль". Добавляем нужные каталоги в PATH
        процесса IDE.
    #>
    $pathDirectories = New-Object 'System.Collections.Generic.List[string]'

    foreach ($item in @($AddPathDirectories)) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        if (Test-Path -LiteralPath $item -PathType Container) {
            [void]$pathDirectories.Add((Get-Item -LiteralPath $item).FullName)
        }
    }

    $delphiRoot = $null
    try {
        $delphiRoot = Get-Delphi7Root
    }
    catch {
        $delphiRoot = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($delphiRoot)) {
        foreach ($sub in @('Bin', 'Projects\Bpl')) {
            $candidate = Join-AnyPath -Base $delphiRoot -Parts $sub
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)) {
                [void]$pathDirectories.Add($candidate)
            }
        }
    }

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($extra in @($script:Profile.ExtraIdeArguments)) {
        if (-not [string]::IsNullOrWhiteSpace($extra)) {
            [void]$arguments.Add($extra)
        }
    }
    [void]$arguments.Add('-r' + $ProfileName)
    [void]$arguments.Add('"' + $projectItem.FullName + '"')

    $commandLine = ($arguments -join ' ')
    Write-Host ("[Delphi] Starting IDE: {0} {1}" -f $ide, $commandLine) -ForegroundColor Green

    if ($pathDirectories.Count -gt 0) {
        Write-Host ("[Delphi] PATH added for the IDE: {0}" -f ($pathDirectories -join '; '))
    }

    $savedPath = $env:PATH
    try {
        if ($pathDirectories.Count -gt 0) {
            $env:PATH = (($pathDirectories -join ';') + ';' + $savedPath)
        }

        $process = Start-Process -FilePath $ide -ArgumentList $commandLine -Wait -PassThru
        if ($null -ne $process) {
            Write-Host ("[Delphi] IDE closed with exit code {0}." -f $process.ExitCode)
        }
    }
    finally {
        $env:PATH = $savedPath
    }
}

<#
    Простой сценарий "открыть проект в собственном профиле":
    создать профиль -> запустить IDE -> дождаться закрытия -> удалить профиль.
    Никакой обработки пакетов здесь нет: это задача вызывающей стороны.
#>
function Invoke-DelphiIdeProfile {
    param (
        [string]$ProjectFile,
        [string]$ProfileHint = ''
    )

    if ([string]::IsNullOrWhiteSpace($ProjectFile) -or -not (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) {
        throw ("Project file was not found: {0}" -f $ProjectFile)
    }

    $projectItem = Get-Item -LiteralPath $ProjectFile
    if ([string]::IsNullOrWhiteSpace($ProfileHint)) {
        $ProfileHint = $projectItem.FullName
    }

    Initialize-TempProfileEnvironment

    $profileName = New-DelphiTempProfile -ProjectHint $ProfileHint -ProjectFile $projectItem.FullName

    try {
        Invoke-DelphiIdeInProfile -ProfileName $profileName -ProjectFile $projectItem.FullName
    }
    finally {
        if ($script:Profile.KeepProfile) {
            Write-Host ("[Delphi] Profile kept (-KeepProfile): HKCU\{0}" -f (Get-ProfileKeyPath -ProfileName $profileName)) -ForegroundColor Yellow
        }
        else {
            Remove-DelphiProfile -ProfileName $profileName
            Write-Host ("[Delphi] Temporary profile deleted: {0}" -f $profileName) -ForegroundColor Cyan
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $Workspace = (Get-Location).Path
    }

    # Действиям над уже созданным профилем workspace не нужен.
    $needsWorkspace = @(
        'compile-file', 'compile-project', 'compile-all',
        'build-project', 'build-all',
        'clean-project', 'clean-all',
        'run-project', 'start-project',
        'open-project', 'open-ide-profile', 'open-ide-in-profile'
    ) -contains $Action

    $root = $null
    try {
        $root = Resolve-FullPath -Path $Workspace -BasePath (Get-Location).Path
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            $root = (Get-Item -LiteralPath $root).FullName
        }
        else {
            $root = $null
        }
    }
    catch {
        $root = $null
    }

    if ($null -eq $root -and $needsWorkspace) {
        throw "Workspace folder was not found: $Workspace"
    }

    $needsCompiler = @('compile-file', 'compile-project', 'compile-all', 'build-project', 'build-all', 'run-project', 'start-project') -contains $Action
    $dcc32 = $null
    if ($needsCompiler) {
        $dcc32 = Get-Dcc32Path
    }

    $delphi32 = $null
    if (@('open-project', 'open-ide-profile', 'open-ide-in-profile') -contains $Action) {
        $delphi32 = Get-Delphi32Path
    }

    switch ($Action) {
        'compile-file' {
            $filePath = Resolve-FullPath -Path $ActiveFile -BasePath $root
            if (-not $filePath -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                throw 'Compile File requires an active editor file.'
            }

            $file = Get-Item -LiteralPath $filePath
            $project = Get-ProjectForFile -Root $root -File $file.FullName
            if ($null -ne $project) {
                $cfg = Ensure-ProjectCfg -Project $project
                if ($file.Extension -ieq '.dpr') {
                    Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $project.DirectoryName -InputFile $project.Name -ProjectCfg $cfg -UseProjectCfgArguments
                }
                else {
                    Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $project.DirectoryName -InputFile $file.FullName -ProjectCfg $cfg -UseProjectCfgArguments
                }
            }
            else {
                Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $file.DirectoryName -InputFile $file.Name -ProjectCfg $null -UseProjectCfgArguments
            }
        }

        'compile-project' {
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            $cfg = Ensure-ProjectCfg -Project $project
            Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $project.DirectoryName -InputFile $project.Name -ProjectCfg $cfg -UseProjectCfgArguments
        }

        'compile-all' {
            $projects = @(Get-DelphiProjects -Root $root)
            if ($projects.Count -eq 0) { throw "No .dpr projects were found under '$root'." }
            $failed = @()
            foreach ($project in $projects) {
                try {
                    $cfg = Ensure-ProjectCfg -Project $project
                    Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $project.DirectoryName -InputFile $project.Name -ProjectCfg $cfg -UseProjectCfgArguments
                }
                catch {
                    Write-Warning $_.Exception.Message
                    $failed += $project.FullName
                }
            }
            if ($failed.Count -gt 0) { throw ("Projects failed to compile: {0}" -f ($failed -join '; ')) }
        }

        'build-project' {
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            $cfg = Ensure-ProjectCfg -Project $project
            Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $project.DirectoryName -InputFile $project.Name -ProjectCfg $cfg -FullBuild -UseProjectCfgArguments
        }

        'build-all' {
            $projects = @(Get-DelphiProjects -Root $root)
            if ($projects.Count -eq 0) { throw "No .dpr projects were found under '$root'." }
            $failed = @()
            foreach ($project in $projects) {
                try {
                    $cfg = Ensure-ProjectCfg -Project $project
                    Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $project.DirectoryName -InputFile $project.Name -ProjectCfg $cfg -FullBuild -UseProjectCfgArguments
                }
                catch {
                    Write-Warning $_.Exception.Message
                    $failed += $project.FullName
                }
            }
            if ($failed.Count -gt 0) { throw ("Projects failed to build: {0}" -f ($failed -join '; ')) }
        }

        'clean-project' {
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            $files = @(Get-GeneratedFiles -Root $project.DirectoryName)
            $baseName = [IO.Path]::GetFileNameWithoutExtension($project.Name)
            foreach ($directory in (Get-OutputDirectories -Project $project)) {
                foreach ($extension in @('.exe', '.map', '.tds', '.rsm')) {
                    $candidate = Join-Path $directory ($baseName + $extension)
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        $files += Get-Item -LiteralPath $candidate
                    }
                }
            }
            Remove-GeneratedFiles -Files $files
        }

        'clean-all' {
            Write-Host '[Delphi] Clean All: removing .dcu, .exe, .map, .tds and .rsm under the workspace.' -ForegroundColor Yellow
            Remove-GeneratedFiles -Files @(Get-GeneratedFiles -Root $root -IncludeExe)
        }

        'run-project' {
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            $cfg = Ensure-ProjectCfg -Project $project
            Invoke-Dcc -Dcc32 $dcc32 -WorkingDirectory $project.DirectoryName -InputFile $project.Name -ProjectCfg $cfg -UseProjectCfgArguments
            Start-Project -Project $project
        }

        'start-project' {
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            Start-Project -Project $project
        }

        'open-project' {
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            $quotedProject = [char]34 + $project.FullName + [char]34
            Write-Host ("[Delphi] Opening in Delphi IDE: {0}" -f $project.FullName) -ForegroundColor Green
            Start-Process -FilePath $delphi32 -ArgumentList $quotedProject
        }

        'open-ide-profile' {
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            Invoke-DelphiIdeProfile -ProjectFile $project.FullName -ProfileHint $ProfileHint
        }

        'new-profile' {
            Initialize-TempProfileEnvironment

            $hint = $ProfileHint
            if ([string]::IsNullOrWhiteSpace($hint)) { $hint = $root }
            if ([string]::IsNullOrWhiteSpace($hint)) { $hint = '' }

            $projectFile = ''
            if (-not [string]::IsNullOrWhiteSpace($ActiveFile) -and (Test-Path -LiteralPath $ActiveFile -PathType Leaf)) {
                $projectFile = (Get-Item -LiteralPath $ActiveFile).FullName
            }

            $name = New-DelphiTempProfile -ProjectHint $hint -ProjectFile $projectFile -Name $ProfileName
            Write-Output ('PROFILE=' + $name)
        }

        'delete-profile' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            Remove-DelphiProfile -ProfileName $ProfileName
            Write-Host ("[Delphi] Profile deleted: {0}" -f $ProfileName) -ForegroundColor Cyan
        }

        'open-ide-in-profile' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            $project = Select-DelphiProject -Root $root -File $ActiveFile
            Invoke-DelphiIdeInProfile -ProfileName $ProfileName -ProjectFile $project.FullName -AddPathDirectories $AddPathDirectories
        }

        'profile-remove-packages' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            Write-Host ("[Delphi] Removing packages: {0}" -f ($RemovePackages -join ', ')) -ForegroundColor Cyan
            Remove-ProfilePackages -ProfileName $ProfileName `
                -PackageNames $RemovePackages `
                -ForeignPatterns $StripLibraryPatterns `
                -KeepUnder $KeepUnder `
                -MatchMode $PackageMatchMode
        }

        'profile-strip-library' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            Update-ProfileLibraryPath -ProfileName $ProfileName -StripPatterns $StripLibraryPatterns -KeepUnder $KeepUnder
        }

        'profile-install-package' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            if ([string]::IsNullOrWhiteSpace($InstallPackage)) {
                throw 'InstallPackage is required.'
            }
            $installed = Install-DelphiPackage -PackageFile $InstallPackage `
                -ProfileName $ProfileName `
                -StripPatterns $StripLibraryPatterns `
                -LocalCopyDir $LocalCopyDir `
                -Rebuild:$Rebuild
            Write-Output ('PACKAGE=' + $installed.FullName)
        }

        'profile-enable-package' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            if ([string]::IsNullOrWhiteSpace($BplPath)) {
                throw 'BplPath is required.'
            }
            Write-Host ("[Delphi] Enabling package: {0}" -f (Split-Path -Leaf $BplPath)) -ForegroundColor Cyan
            Enable-ProfilePackage -ProfileName $ProfileName `
                -BplPath $BplPath `
                -MatchNames $EnableMatchNames `
                -LibraryPath $LibraryPath `
                -MatchMode $PackageMatchMode `
                -IncludeGlobal:$IncludeGlobal `
                -IncludeHklm:$IncludeHklm

            Write-Host '[Delphi] Profile package state:' -ForegroundColor Cyan
            Show-ProfilePackageState -ProfileName $ProfileName -MatchNames $EnableMatchNames -MatchMode $PackageMatchMode -IncludeGlobal:$IncludeGlobal -IncludeHklm:$IncludeHklm
        }

        'profile-package-state' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            Write-Host '[Delphi] Profile package state:' -ForegroundColor Cyan
            Show-ProfilePackageState -ProfileName $ProfileName -MatchNames $RemovePackages -MatchMode $PackageMatchMode -IncludeGlobal:$IncludeGlobal -IncludeHklm:$IncludeHklm
        }

        'profile-add-library-path' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw 'ProfileName is required.'
            }
            Add-ProfileLibraryPath -ProfileName $ProfileName -Paths $LibraryPaths
        }

        'save-global-profile' {
            Save-GlobalProfileSnapshot -Path $script:Profile.SnapshotPath
        }

        'purge-profiles' {
            Write-Host '[Delphi] Removing temporary IDE profiles.' -ForegroundColor Cyan
            Remove-StaleDelphiProfiles -All
        }
    }

    Write-Host '[Delphi] Done.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ("[Delphi] ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
