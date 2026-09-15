[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('compile-file', 'compile-project', 'compile-all', 'build-project', 'build-all', 'clean-project', 'clean-all', 'run-project', 'start-project')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Workspace = '',

    [Parameter(Position = 2)]
    [string]$ActiveFile = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        return $cfgPath
    }

    $dofPath = Join-Path $Project.DirectoryName ($baseName + '.dof')
    if (-not (Test-Path -LiteralPath $dofPath -PathType Leaf)) {
        return $null
    }

    Convert-DofToCfg -DofPath $dofPath -CfgPath $cfgPath
    Write-Host ("[Delphi] Generated compiler config: {0}" -f $cfgPath) -ForegroundColor Yellow
    return $cfgPath
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
    $compilerArguments += $InputFile

    $exitCode = 1
    Push-Location -LiteralPath $WorkingDirectory
    try {
        Write-Host ("[Delphi] Compile: {0}" -f $InputFile) -ForegroundColor Cyan
        & $Dcc32 @compilerArguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
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

try {
    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $Workspace = (Get-Location).Path
    }

    $root = Resolve-FullPath -Path $Workspace -BasePath (Get-Location).Path
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Workspace folder was not found: $Workspace"
    }
    $root = (Get-Item -LiteralPath $root).FullName

    $needsCompiler = @('compile-file', 'compile-project', 'compile-all', 'build-project', 'build-all', 'run-project', 'start-project') -contains $Action
    $dcc32 = $null
    if ($needsCompiler) {
        $dcc32 = Get-Dcc32Path
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
    }

    Write-Host '[Delphi] Done.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ("[Delphi] ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
