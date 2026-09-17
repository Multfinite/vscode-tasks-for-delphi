# Глобальные задачи Delphi 7 для VS Code

Набор глобальных задач VS Code для компиляции, полной сборки, очистки и запуска проектов Delphi 7.

Задачи хранятся в **User Tasks**, поэтому не требуют файла `.vscode/tasks.json` внутри отдельного проекта.

## Состав

- `Delphi7Tasks.ps1` — основная логика задач.
- `delphi7-tasks.bat` — BAT-обёртка для ручного запуска из командной строки.
- `user-tasks.json` — глобальные задачи VS Code.
- `README.ru.md` — эта инструкция.
- `README.en.md` — английская версия инструкции.

## Установка скриптов

Скопируйте скрипты в общий каталог пользователя:

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

Итоговые файлы должны находиться здесь:

```text
%USERPROFILE%\.vscode\delphi7\Delphi7Tasks.ps1
%USERPROFILE%\.vscode\delphi7\delphi7-tasks.bat
```

## Установка задач VS Code

1. Выполните команду `Tasks: Open User Tasks`.
2. Замените старый список задач содержимым файла `user-tasks.json`.
3. Выполните `Developer: Reload Window`.
4. Откройте папку с исходным кодом Delphi как workspace.
5. Запускайте задачи через `Tasks: Run Task`.

Задача `Delphi: Build Project` установлена как задача сборки по умолчанию для `Ctrl+Shift+B`.

## Доступные задачи

### Компиляция

#### `Delphi: Compile File`

Компилирует файл из активного редактора:

- `.pas`;
- `.dpr`;
- `.dpk`;
- другие файлы, поддерживаемые `dcc32`.

Если файл находится внутри проекта, скрипт ищет ближайший `.dpr` и применяет его `.cfg` или `.dof`. Если проект не найден, файл передаётся `dcc32` напрямую.

Эта задача требует открытого файла в редакторе.

#### `Delphi: Compile Project`

Компилирует проект без необходимости открывать файл. Если в workspace один проект, он выбирается автоматически. Если проектов несколько, скрипт предлагает выбрать проект.

#### `Delphi: Compile Project (current file)`

Находит проект, которому принадлежит активный файл, и компилирует его.

#### `Delphi: Compile All`

Рекурсивно находит и компилирует все файлы `.dpr` в workspace. Активный редактор не требуется.

### Полная сборка

- `Delphi: Build Project` — полная пересборка выбранного проекта.
- `Delphi: Build Project (current file)` — полная пересборка проекта активного файла.
- `Delphi: Build All` — полная пересборка всех проектов workspace.

### Очистка

- `Delphi: Clean Project` — очистка выбранного проекта.
- `Delphi: Clean Project (current file)` — очистка проекта активного файла.
- `Delphi: Clean All` — очистка всех проектов workspace.

Удаляемые файлы:

```text
*.dcu
*.exe
*.map
*.tds
*.rsm
```

`Clean All` удаляет `.exe` внутри всего workspace. Не запускайте эту задачу в общей папке со сторонними исполняемыми файлами, которые требуется сохранить.

### Запуск

- `Delphi: Run Project` — компилирует и запускает выбранный проект.
- `Delphi: Run Project (current file)` — компилирует и запускает проект активного файла.
- `Delphi: Start Project (without compile)` — запускает существующий `.exe` без компиляции.
- `Delphi: Start Project (current file, without compile)` — запускает `.exe` проекта активного файла.

### Открытие проекта в Delphi IDE

- `Delphi: Open Project in Delphi IDE` — выбирает проект в workspace и открывает его в Delphi 7 IDE.
- `Delphi: Open Project in Delphi IDE (current file)` — открывает в Delphi IDE проект, которому принадлежит активный файл.

Для запуска используется `delphi32.exe`. Скрипт ищет его в переменных `DELPHI32`, `DELPHI7_IDE`, `DELPHI7_ROOT`, `DELPHI7_HOME`, `DELPHI7` и в `PATH`. Если переменные не заданы, дополнительно проверяется путь установки Delphi 7 в реестре.

### Запуск IDE в отдельном профиле реестра

- `Delphi: Open Project in Delphi IDE (temp profile)` — то же, но IDE работает
  в собственном временном профиле реестра.
- `Delphi: Open Project in Delphi IDE (temp profile, current file)` — то же по
  активному файлу.
- `Delphi: Save IDE global profile` — сохранить снимок глобального профиля в `.reg`.
- `Delphi: Purge IDE temp profiles` — удалить осиротевшие временные профили.

Ключ `-r` указывает IDE, из какой ветки реестра читать настройки:
`delphi32.exe -rD7T-1a2b3c` работает с `HKCU\Software\Borland\D7T-1a2b3c\7.0`
(имя из `-r` подставляется вместо имени продукта, версия остаётся).
Имя профиля — префикс и чексумма (по умолчанию MD5) от строки времени запуска.

Что происходит при таком запуске:

```text
1. Удаление осиротевших временных профилей
2. Создание профиля: копия HKCU\Software\Borland\Delphi\7.0
   -> HKCU\Software\Borland\D7T-<чексумма>\7.0
3. (по инициативе вызывающего скрипта) подготовка профиля:
   удаление пакетов, вырезание чужих путей, сборка и установка пакетов
4. Запуск delphi32.exe -rD7T-<чексумма> "<проект>.dpr" и ожидание закрытия
5. Удаление временного профиля
```

Пакет включается отдельным действием `profile-enable-package`: в Delphi
галочка в «Install Packages» означает «путь есть в `Known Packages` и его нет
в `Disabled Packages`», поэтому это действие вычищает путь пакета из
`Disabled Packages` и `Package Cache`. Перед запуском IDE полезно вызвать
`profile-package-state`:

```text
[Delphi] Profile package state:
[Delphi]   [enabled ] D:\...\MyPackage.bpl (file found)
```

Если вместо этого `[DISABLED]` или `(file not found)` — причина видна сразу:
в строке указан путь, который IDE и пытается загрузить.

Действие `profile-remove-packages` умеет удалять пакеты **других копий
проекта**: путь совпадает с `-ForeignPatterns`, но лежит вне `-KeepUnder`.
Иначе IDE находит чужой `<пакет>.bpl` и снимает с него галочку.

Каталог собранного BPL/DCP добавляется в `Library\Search Path` профиля
(`profile-enable-package -LibraryPath`), чтобы компиляция из IDE тоже его видела.

Глобальный профиль не изменяется, поэтому можно одновременно открыть два
проекта с разными наборами пакетов. Все изменения, сделанные в IDE в таком
режиме, живут только до закрытия окна (или до запуска с `-KeepProfile`).

## Действия для работы с готовым профилем

Эти действия ничего не знают о конкретном проекте: какие пакеты удалять,
что собирать и в каком порядке — решает вызывающий скрипт.

| Действие | Что делает |
| --- | --- |
| `new-profile` | создать временный профиль (копию глобального), печатает `PROFILE=<имя>` |
| `delete-profile -ProfileName` | удалить профиль |
| `open-ide-in-profile -ProfileName` | запустить IDE в профиле и ждать закрытия |
| `profile-remove-packages -ProfileName -Packages [-StripLibraryPatterns] [-KeepUnder] [-PackageMatchMode]` | удалить пакеты из `Known Packages` / `Disabled Packages` / `Package Cache` |
| `profile-strip-library -ProfileName -StripLibraryPatterns [-KeepUnder]` | вырезать чужие пути из `Library\Search Path` |
| `profile-install-package -ProfileName -InstallPackage [-StripLibraryPatterns] [-Rebuild] [-LocalCopyDir]` | собрать `.dpk` через `dcc32`, записать в `Known Packages`, печатает `PACKAGE=<путь к bpl>` |
| `profile-enable-package -ProfileName -BplPath -EnableMatchNames [-LibraryPath]` | включить пакет: убрать путь из `Disabled Packages` / `Package Cache`, при необходимости добавить каталог в Library |
| `profile-package-state -ProfileName -RemovePackages` | напечатать состояние пакетов (`enabled` / `DISABLED`, найден ли файл) |
| `profile-add-library-path -ProfileName -LibraryPaths` | добавить каталоги в `Library\Search Path` |

`new-profile` и `profile-install-package` печатают машинно-читаемые строки
`PROFILE=<имя>` и `PACKAGE=<путь>` — вызывающий скрипт разбирает их из вывода.

Если IDE не грузит пакет с UNC/сетевого пути, вызовите
`profile-install-package` с `-LocalCopyDir <каталог>`: BPL/DCP копируются
туда и регистрируется локальный путь.

Настройки профилей — блок `$script:Profile` в начале `Delphi7Tasks.ps1`:
`RegistryVendorKey`, `GlobalProfileName`, `VersionSubKey`, `ProfileKeyTemplate`,
`GlobalProfileKey`, `ProfilePrefix`, `ProfileHashAlgorithm`, `ProfileHashLength`,
`SnapshotPath`, `AutoSaveSnapshot`, `PurgeStaleProfiles`, `StaleProfileHours`,
`ExtraIdeArguments`.

### Важно: кодировка `.ps1` — UTF-8 **с BOM**

Скрипт содержит русский текст, а Windows PowerShell 5.1 без BOM читает `.ps1`
как ANSI (CP1251) и падает с синтаксической ошибкой. Файл в репозитории уже
сохранён в UTF-8 с BOM — переписывайте файл целиком, не копируйте текст
из браузера.

Пересохранить с BOM, если он потерялся:

```powershell
$p = Join-Path $env:USERPROFILE '.vscode\delphi7\Delphi7Tasks.ps1'
$text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $true))
```

Если ваша IDE раскладывает ключ `-r` иначе, достаточно поправить шаблон:

```powershell
ProfileKeyTemplate = '{Vendor}\{Profile}\{Version}'   # по умолчанию
# ProfileKeyTemplate = '{Vendor}\Delphi\{Profile}'    # альтернатива
```

## Выбор проекта

Скрипт выбирает проект в следующем порядке:

1. Если передан активный файл и он является `.dpr`, используется этот проект.
2. Если активен `.pas` или другой файл, выполняется поиск ближайшего каталога с единственным `.dpr`.
3. Если в workspace найден только один `.dpr`, используется он.
4. Если проектов несколько, выводится интерактивный список.

Задачи без суффикса `(current file)` не используют `${file}`. Поэтому они работают даже при отсутствии открытого редактора.

Задачи с суффиксом `(current file)` и задача `Compile File` требуют открытый файл. Если активен только `tasks.json`, VS Code покажет сообщение:

```text
Variable ${file} can not be resolved. Please open an editor.
```

В таком случае используйте задачу без `(current file)` либо откройте исходный файл проекта.

## Окружение Delphi 7

`dcc32.exe` ищется в следующих переменных окружения:

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

Также проверяются пользовательские переменные, в имени которых встречаются `DELPHI`, `DCC32`, `BORLAND` или `D7`, после чего используется `PATH`.

Можно явно задать путь к компилятору:

```powershell
[Environment]::SetEnvironmentVariable(
    'DCC32',
    'C:\Program Files (x86)\Borland\Delphi7\Bin\dcc32.exe',
    'User'
)
```

## Настройки `.dof` и `.cfg`

Delphi 7 хранит настройки проекта в `.dof`, а командный компилятор использует `.cfg`. Файл `.dof` считается источником истины.

Перед каждым запуском `Compile`, `Build` или `Run` скрипт заново генерирует одноимённый `.cfg` из `.dof`, даже если старый `.cfg` уже существует. Поэтому ручные изменения в `.cfg` будут перезаписаны. Если `.dof` отсутствует, существующий `.cfg` сохраняется без изменений.

Конвертируются основные параметры:

- условная компиляция;
- `SearchPath`;
- `UnitOutputDir`;
- `OutputDir`;
- `IncludePath`;
- `ObjPath`;
- `ResourcePath`;
- каталоги BPL и DCP;
- пакеты;
- параметры отладочной информации и map-файла;
- основные переключатели компилятора.

Кроме project settings скрипт пытается прочитать глобальный Library Search Path Delphi 7 из реестра:

```text
HKCU\Software\Borland\Delphi\7.0\Library\Search Path
```

Этот путь добавляется к параметрам поиска юнитов, include-файлов, ресурсов и объектов. Это позволяет находить сторонние DCU, например `AuxComponents.dcu`.

## UNC-пути

Задачи запускают `powershell.exe` из локального каталога пользователя, а не из `${workspaceFolder}`. Это сделано специально для проектов на UNC-путях, например:

```text
\\server\share\Repositories\MyProject\src
```

`cmd.exe` не может использовать UNC-каталог как текущий каталог, поэтому workspace передаётся PowerShell-скрипту как аргумент.
