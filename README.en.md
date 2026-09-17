# Global Delphi 7 Tasks for VS Code

A set of global VS Code tasks for compiling, rebuilding, cleaning, and running Delphi 7 projects.

The tasks are stored in **User Tasks**, so no project-local `.vscode/tasks.json` file is required.

## Files

- `Delphi7Tasks.ps1` — main task implementation.
- `delphi7-tasks.bat` — BAT wrapper for manual command-line use.
- `user-tasks.json` — global VS Code task definitions.
- `README.ru.md` — Russian documentation.
- `README.en.md` — this document.

## Install the scripts

Copy the scripts to a global user directory:

```powershell
$destination = Join-Path $env:USERPROFILE '.vscode\delphi7'

New-Item -ItemType Directory -Force $destination | Out-Null

Copy-Item '.\delphi7-global\Delphi7Tasks.ps1' `
          -Destination $destination `
          -Force

Copy-Item '.\delphi7-global\delphi7-tasks.bat' `
          -Destination $destination `
          -Force
```

The resulting files must be located at:

```text
%USERPROFILE%\.vscode\delphi7\Delphi7Tasks.ps1
%USERPROFILE%\.vscode\delphi7\delphi7-tasks.bat
```

## Install the VS Code tasks

1. Run `Tasks: Open User Tasks`.
2. Replace the old task list with the contents of `user-tasks.json`.
3. Run `Developer: Reload Window`.
4. Open the Delphi source tree as a workspace.
5. Run tasks through `Tasks: Run Task`.

`Delphi: Build Project` is configured as the default build task for `Ctrl+Shift+B`.

## Available tasks

### Compile

#### `Delphi: Compile File`

Compiles the file from the active editor:

- `.pas`;
- `.dpr`;
- `.dpk`;
- other source files supported by `dcc32`.

If the file belongs to a project, the script finds the nearest `.dpr` and applies its `.cfg` or `.dof` settings. If no project is found, the file is passed directly to `dcc32`.

This task requires an open editor file.

#### `Delphi: Compile Project`

Compiles a project without requiring an active editor. If the workspace contains one project, it is selected automatically. If there are multiple projects, the script displays a project selection prompt.

#### `Delphi: Compile Project (current file)`

Finds and compiles the project containing the active file.

#### `Delphi: Compile All`

Recursively finds and compiles all `.dpr` files in the workspace. An active editor is not required.

### Build

- `Delphi: Build Project` — full rebuild of the selected project.
- `Delphi: Build Project (current file)` — full rebuild of the project containing the active file.
- `Delphi: Build All` — full rebuild of every project in the workspace.

### Clean

- `Delphi: Clean Project` — clean the selected project.
- `Delphi: Clean Project (current file)` — clean the project containing the active file.
- `Delphi: Clean All` — clean all projects in the workspace.

The following generated files are removed:

```text
*.dcu
*.exe
*.map
*.tds
*.rsm
```

`Clean All` removes `.exe` files under the entire workspace. Do not run it in a shared directory containing third-party executables that must be preserved.

### Run

- `Delphi: Run Project` — compile and run the selected project.
- `Delphi: Run Project (current file)` — compile and run the project containing the active file.
- `Delphi: Start Project (without compile)` — start an existing `.exe` without compiling.
- `Delphi: Start Project (current file, without compile)` — start the `.exe` belonging to the active file's project.

### Open the project in the Delphi IDE

- `Delphi: Open Project in Delphi IDE` — select a project in the workspace and open it in the Delphi 7 IDE.
- `Delphi: Open Project in Delphi IDE (current file)` — open the project containing the active file in the Delphi IDE.

The task uses `delphi32.exe`. The script searches `DELPHI32`, `DELPHI7_IDE`, `DELPHI7_ROOT`, `DELPHI7_HOME`, `DELPHI7`, and `PATH`. If these variables are not set, the Delphi 7 installation path is also checked in the registry.

## Project selection

The script selects a project in this order:

1. If an active file is provided and it is a `.dpr`, that project is used.
2. If the active file is a `.pas` or another source file, the nearest directory containing a single `.dpr` is searched.
3. If the workspace contains exactly one `.dpr`, it is used.
4. If several projects are found, an interactive selection list is displayed.

Tasks without the `(current file)` suffix do not use `${file}`. They work even when no editor is open.

Tasks with the `(current file)` suffix and `Compile File` require an open editor. If only `tasks.json` is active, VS Code may display:

```text
Variable ${file} can not be resolved. Please open an editor.
```

In that case, use the task without `(current file)` or open a Delphi source file.

## Delphi 7 environment

`dcc32.exe` is searched for in these environment variables:

```text
DCC32
DCC32_EXE
DELPHI7_DCC32
DELPHI7_BIN
DELPHI7_ROOT
DELPHI7_HOME
DELPHI7
DELPHI_ROOT
DELPHI_HOME
DELPHI
```

Custom variables whose names contain `DELPHI`, `DCC32`, `BORLAND`, or `D7` are also inspected. The inherited `PATH` is used as the final fallback.

You can explicitly set the compiler path:

```powershell
[Environment]::SetEnvironmentVariable(
    'DCC32',
    'C:\Program Files (x86)\Borland\Delphi7\Bin\dcc32.exe',
    'User'
)
```

## `.dof` and `.cfg` settings

Delphi 7 stores project settings in `.dof`, while the command-line compiler uses `.cfg`. The `.dof` file is treated as the source of truth.

Before every `Compile`, `Build`, or `Run` operation, the script regenerates the matching `.cfg` from `.dof`, even when an older `.cfg` already exists. Manual changes made directly to `.cfg` will therefore be overwritten. If no `.dof` exists, an existing `.cfg` is kept unchanged.

The converter handles the main settings, including:

- conditional defines;
- `SearchPath`;
- `UnitOutputDir`;
- `OutputDir`;
- `IncludePath`;
- `ObjPath`;
- `ResourcePath`;
- BPL and DCP output directories;
- runtime packages;
- debug and map-file settings;
- common compiler switches.

In addition to project settings, the script tries to read the global Delphi 7 Library Search Path from:

```text
HKCU\Software\Borland\Delphi\7.0\Library\Search Path
```

That path is merged into the unit, include, resource, and object search options. This allows third-party DCUs such as `AuxComponents.dcu` to be found.

## UNC paths

The tasks start `powershell.exe` from the local user directory instead of `${workspaceFolder}`. This is intentional for workspaces on UNC paths, for example:

```text
\\tsclient\Z\Repositories\FlowPlantM\Flow Plant\src
```

`cmd.exe` cannot use a UNC path as its current directory, so the workspace path is passed to the PowerShell script as an argument.
