@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================================
REM  build.bat - Build BrowserOS neo from source on Windows (x64)
REM
REM  "BrowserOS neo" is the product id "browserclaw" in bos_build
REM  (see packages\browseros\bos_build\products\browserclaw\product.py).
REM
REM  What it does:
REM    1. Prepares a Chromium checkout at the pinned version
REM       (packages\browseros\CHROMIUM_VERSION) under %CHROMIUM_ROOT%.
REM       Clones depot_tools if missing, fetches the pinned tag shallowly,
REM       and runs gclient sync. First run downloads ~100 GB and takes hours;
REM       reruns are incremental (ninja resumes where it left off).
REM    2. Prepares the neo agent resources: by default (AGENT_MODE=source)
REM       builds claw-server-rust with cargo and claw-onboard with bun from
REM       this checkout, staging them where the R2-based download_resources
REM       step would put them. AGENT_MODE=published instead downloads the
REM       released bundles from the public CDN (cdn.browseros.com). Either way
REM       that step is skipped afterwards.
REM    3. Runs the bos_build pipeline: applies BrowserOS patches, compiles
REM       with autoninja, builds an unsigned mini installer, and packages it
REM       into packages\browseros\releases\<version>\.
REM
REM  One-time prerequisites:
REM    - uv (https://docs.astral.sh/uv/)
REM    - Git for Windows
REM    - Visual Studio 2022 Build Tools with the "Desktop development with C++"
REM      workload, a Windows SDK, and the SDK's "Debugging Tools for Windows"
REM      feature (the C++ workload does not install it; Chromium's gn configure
REM      needs dbghelp.dll from it). DEPOT_TOOLS_WIN_TOOLCHAIN=0 makes the build
REM      use your local VS instead of downloading Chromium's toolchain.
REM    - Rust and Bun are installed automatically (user-local, no elevation)
REM      when AGENT_MODE=source; not needed for AGENT_MODE=published.
REM    - ~100 GB free disk on the drive holding %CHROMIUM_ROOT%, 16+ GB RAM.
REM
REM  Overrides (set before calling, e.g.:  set PRESET=debug && build.bat):
REM    PRESET         release | debug          default: release
REM    PRODUCT        browserclaw | browseros  default: browserclaw (= neo)
REM    ARCH           x64                      default: x64
REM    PROVISION      shallow | full           default: shallow (self-contained).
REM                   Use full only if %CHROMIUM_SRC% is already a complete
REM                   Chromium checkout you maintain yourself.
REM    RESOURCE_MODE  published | source       default: published (downloads
REM                   released components from the public CDN; no secrets)
REM    AGENT_MODE     source | published   default: source (builds the neo agent
REM                   components claw-server-rust + claw-onboard from this
REM                   checkout with cargo/bun, auto-installing Rust and Bun if
REM                   missing). published downloads them from cdn.browseros.com.
REM    SIGN           yes | no                 default: no (yes needs ESIGNER_*
REM                   in packages\browseros\.env, copied from .env.example)
REM    UPLOAD         yes | no                 default: no (yes needs R2_*)
REM    CHROMIUM_ROOT  checkout root            default: <repo parent>\chromium
REM                   (a sibling of this checkout; the src tree lives at
REM                   %CHROMIUM_ROOT%\src)
REM ============================================================================

REM Windows console pipes are cp1252 and the build CLI logs emoji; force UTF-8
REM for python and its subprocesses (same as .github/workflows/build-browseros.yml).
set "PYTHONUTF8=1"

if "%PRESET%"=="" set "PRESET=release"
if "%PRODUCT%"=="" set "PRODUCT=browserclaw"
if "%ARCH%"=="" set "ARCH=x64"
if "%PROVISION%"=="" set "PROVISION=shallow"
if "%RESOURCE_MODE%"=="" set "RESOURCE_MODE=published"
if "%AGENT_MODE%"=="" set "AGENT_MODE=source"
if "%SIGN%"=="" set "SIGN=no"
if "%UPLOAD%"=="" set "UPLOAD=no"
REM Default: sibling of this checkout (%%~ffd normalizes %~dp0.. to an absolute path).
if "%CHROMIUM_ROOT%"=="" for %%d in ("%~dp0..") do set "CHROMIUM_ROOT=%%~fdd\chromium"
set "CHROMIUM_SRC=%CHROMIUM_ROOT%\src"

echo.
echo === BrowserOS neo build ===
echo   preset        = %PRESET%
echo   product       = %PRODUCT%
echo   arch          = %ARCH%
echo   provision     = %PROVISION%
echo   resource mode = %RESOURCE_MODE%
echo   agent mode    = %AGENT_MODE%
echo   sign / upload = %SIGN% / %UPLOAD%
echo   chromium root = %CHROMIUM_ROOT%
echo.

REM --- Preflight -------------------------------------------------------------
where uv >nul 2>nul
if errorlevel 1 (
    echo [build] ERROR: uv not found on PATH. Install it: https://docs.astral.sh/uv/
    goto :fail
)
where git >nul 2>nul
if errorlevel 1 (
    echo [build] ERROR: git not found on PATH. Install Git for Windows.
    goto :fail
)
where curl.exe >nul 2>nul
if errorlevel 1 (
    echo [build] ERROR: curl not found on PATH. It ships with Windows 10+; enable it via Optional Features if missing.
    goto :fail
)

REM Resolve the real git executable now, while depot_tools is not yet on PATH.
REM depot_tools ships a git.bat shim; invoking any .bat without CALL never
REM returns to this script - it ends the whole session with a silent exit, so
REM every git call below goes through %GIT_EXE% (the actual exe).
for /f "tokens=*" %%i in ('where git.exe 2^>nul') do set "GIT_EXE=%%i" & goto :gitexe_found
echo [build] ERROR: git not found on PATH. Install Git for Windows.
goto :fail
:gitexe_found

REM Warn if the target drive is close to full; Chromium needs ~100 GB.
set "CHROMIUM_DRIVE=%CHROMIUM_ROOT:~0,1%"
for /f %%a in ('powershell -NoProfile -Command "if ((Get-PSDrive '%CHROMIUM_DRIVE%').Free -lt 107374182400) { 'LOW' } else { 'OK' }"') do set "DISK_OK=%%a"
if "%DISK_OK%"=="LOW" (
    echo [build] WARNING: less than 100 GB free on drive %CHROMIUM_DRIVE%:. A Chromium build needs ~100 GB.
)

REM --- depot_tools -----------------------------------------------------------
REM The compile step calls gn.bat / autoninja.bat bare, so depot_tools must be
REM on PATH. Clone it if missing (the pipeline's source_checkout step reuses
REM this clone; it is idempotent).
if not exist "%CHROMIUM_ROOT%\depot_tools\.git" (
    echo [build] Cloning depot_tools into %CHROMIUM_ROOT%\depot_tools ...
    if not exist "%CHROMIUM_ROOT%" mkdir "%CHROMIUM_ROOT%"
    "%GIT_EXE%" clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "%CHROMIUM_ROOT%\depot_tools"
    if errorlevel 1 goto :fail
)
set "PATH=%CHROMIUM_ROOT%\depot_tools;%PATH%"
REM Use the locally installed Visual Studio instead of Chromium's downloaded toolchain.
set "DEPOT_TOOLS_WIN_TOOLCHAIN=0"
REM vs_toolchain.py looks for VS 2022 under %ProgramFiles%\Microsoft Visual Studio\2022\<edition>.
REM If it lives on the x86 side (or another edition dir), point it there via vs2022_install.
for %%e in (BuildTools Community Professional Enterprise) do (
    if not defined VS_INSTALL if exist "%ProgramFiles%\Microsoft Visual Studio\2022\%%e" set "VS_INSTALL=%ProgramFiles%\Microsoft Visual Studio\2022\%%e"
    if not defined VS_INSTALL if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\2022\%%e" set "VS_INSTALL=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\%%e"
)
if defined VS_INSTALL (
    set "vs2022_install=!VS_INSTALL!"
    REM Chromium's vs_toolchain.py copy_dlls step needs dbghelp.dll from the Windows SDK's
    REM "Debugging Tools for Windows" feature, which the C++ workload does not install.
    REM Without it gn gen fails with a cryptic error after hours of provisioning, so check now.
    set "SDK_DIR=%ProgramFiles(x86)%\Windows Kits\10"
    if defined WINDOWSSDKDIR set "SDK_DIR=!WINDOWSSDKDIR!"
    if not exist "!SDK_DIR!\Debuggers\x64\dbghelp.dll" (
        echo [build] ERROR: dbghelp.dll not found under !SDK_DIR!\Debuggers\x64 - the Windows SDK "Debugging Tools for Windows" feature is missing.
        echo           Open Visual Studio Installer, Modify your Build Tools install, go to Individual components, and install "Debugging Tools for Windows". Then rerun build.bat.
        goto :fail
    )
) else (
    echo [build] WARNING: no VS 2022 found in the usual locations. Install Build Tools or set vs2022_install manually.
)

REM --- Git config for depot_tools --------------------------------------------
REM Mirror .github/workflows/build-browseros.yml: point GIT_CONFIG_GLOBAL at a
REM throwaway config so we never touch your real global git settings, while
REM giving gclient/depot_tools the line-ending and index settings Chromium on
REM Windows requires.
set "GIT_CONFIG_GLOBAL=%TEMP%\browseros-build.gitconfig"
REM Quote %GIT_EXE%: the path may contain spaces (e.g. C:\Program Files\Git).
"%GIT_EXE%" config --file "%GIT_CONFIG_GLOBAL%" core.autocrlf false
"%GIT_EXE%" config --file "%GIT_CONFIG_GLOBAL%" core.filemode false
"%GIT_EXE%" config --file "%GIT_CONFIG_GLOBAL%" core.fscache true
"%GIT_EXE%" config --file "%GIT_CONFIG_GLOBAL%" core.preloadindex true
"%GIT_EXE%" config --file "%GIT_CONFIG_GLOBAL%" depot-tools.allowGlobalGitConfig true

REM --- Build -----------------------------------------------------------------
cd /d "%~dp0packages\browseros"
if errorlevel 1 goto :fail

echo [build] Syncing python environment (uv sync)...
uv sync
if errorlevel 1 goto :fail

REM --- Agent resources --------------------------------------------------------
REM AGENT_MODE=source builds the neo agent components from this checkout and
REM stages them where download_resources would put them:
REM   - claw-server-rust via cargo (the same command bos_build's
REM     ServerResourceBuilder uses for windows-x64)
REM   - claw-onboard via its bun build script (--no-upload, no R2 credentials)
REM AGENT_MODE=published keeps the old behavior: fetch the released bundles
REM from cdn.browseros.com. Only product browserclaw supports source mode;
REM other products always use published resources.

set "AGENT_ROOT=%~dp0packages\browseros-agent"
set "SERVER_DEST=resources\binaries\browseros_claw_server_rust\windows-%ARCH%"
set "ONBOARD_DEST=resources\binaries\browseros_onboarding"

if /I "%PRODUCT%"=="browserclaw" goto :agent_proceed
echo [build] NOTE: AGENT_MODE=%AGENT_MODE% is only supported for product browserclaw; staging published resources instead.
set "AGENT_MODE=published"
:agent_proceed

if /I "%AGENT_MODE%"=="published" goto :stage_published

REM --- source mode: toolchain (user-local installs, no elevation) -------------
set "CARGO_BIN=%USERPROFILE%\.cargo\bin"
where cargo >nul 2>nul || if exist "%CARGO_BIN%\cargo.exe" set "PATH=%CARGO_BIN%;%PATH%"
where cargo >nul 2>nul || (
    echo [build] Rust not found; installing rustup + stable toolchain ...
    curl.exe -fL --retry 3 --connect-timeout 20 -o "%TEMP%\rustup-init.exe" https://win.rustup.rs/x86_64
    if errorlevel 1 goto :fail
    "%TEMP%\rustup-init.exe" -y --default-toolchain stable
    if errorlevel 1 goto :fail
    set "PATH=%CARGO_BIN%;%PATH%"
)
where cargo >nul 2>nul || (echo [build] ERROR: Rust install failed. Install manually: https://rustup.rs & goto :fail)
rustup target list --installed | findstr /b "x86_64-pc-windows-msvc" >nul 2>nul
if errorlevel 1 (
    echo [build] Adding Rust target x86_64-pc-windows-msvc ...
    rustup target add x86_64-pc-windows-msvc
    if errorlevel 1 goto :fail
)

REM bun's installer places the binary in %USERPROFILE%\.bun\bin (and adds that
REM dir to PATH), not directly under .bun.
set "BUN_BIN=%USERPROFILE%\.bun\bin"
where bun >nul 2>nul || if exist "%BUN_BIN%\bun.exe" set "PATH=%BUN_BIN%;%PATH%"
where bun >nul 2>nul || (
    echo [build] Bun not found; installing ...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://bun.sh/install.ps1 | iex"
    if errorlevel 1 goto :fail
    set "PATH=%BUN_BIN%;%PATH%"
)
where bun >nul 2>nul || (echo [build] ERROR: Bun install failed. Install manually: https://bun.sh & goto :fail)

REM The agent asset packager shells out to the zip CLI, which Windows does not
REM ship; drop a tar-backed shim on PATH if one is not already there.
set "SHIM_DIR=%USERPROFILE%\.local\bin"
if not exist "%SHIM_DIR%\zip.bat" (
    if not exist "%SHIM_DIR%" mkdir "%SHIM_DIR%"
    copy /y "%~dp0packages\browseros\tools\zip-shim\*" "%SHIM_DIR%\" >nul
)
where zip >nul 2>nul || set "PATH=%SHIM_DIR%;%PATH%"

if not defined CLAW_POSTHOG_KEY (
    set "CLAW_POSTHOG_KEY=phc_browseros_ci"
    echo [build] NOTE: CLAW_POSTHOG_KEY not set; inlining the CI placeholder. Set it before running build.bat to inline a real key.
)

if not exist "%AGENT_ROOT%\node_modules" (
    REM No literal parens in this line: inside a block an unquoted ) ends the command.
    echo [build] Installing agent workspace dependencies via bun install ...
    pushd "%AGENT_ROOT%"
    bun install
    if errorlevel 1 goto :fail
    popd
)

echo [build] Building claw-server-rust from source (cargo; first run ~4 min) ...
pushd "%AGENT_ROOT%"
set "CARGO_TARGET_DIR=%AGENT_ROOT%\target"
cargo build --release --locked -p claw-server-rust --bin browseros-claw-server-rs --target x86_64-pc-windows-msvc
if errorlevel 1 goto :fail
popd

set "SERVER_VERSION="
for /f %%v in ('powershell -NoProfile -Command "(Select-String -Path '%AGENT_ROOT%\apps\claw-server-rust\Cargo.toml' -Pattern '^version = ').Line -replace '[^0-9.]',''"') do set "SERVER_VERSION=%%v"
if "%SERVER_VERSION%"=="" (echo [build] ERROR: could not read claw-server-rust version from Cargo.toml & goto :fail)

set "SOURCE_SHA="
for /f %%s in ('"%GIT_EXE%" rev-parse HEAD') do set "SOURCE_SHA=%%s"

uv run python tools\stage_local_server.py --exe "%CARGO_TARGET_DIR%\x86_64-pc-windows-msvc\release\browseros-claw-server-rs.exe" --skill "%AGENT_ROOT%\resources\skills\browserclaw\SKILL.md" --dest "%SERVER_DEST%" --version %SERVER_VERSION% --target windows-%ARCH% --source-sha %SOURCE_SHA% --zip-out "%AGENT_ROOT%\dist\prod\claw-server-rust\browseros-claw-server-rust-resources-windows-%ARCH%.zip"
if errorlevel 1 goto :fail

echo [build] Building claw-onboard from source (bun) ...
pushd "%AGENT_ROOT%"
set "NODE_ENV=production"
bun scripts/build/claw-onboard.ts --no-upload
if errorlevel 1 goto :fail
popd

uv run python tools\stage_cdn_resources.py --zip "%AGENT_ROOT%\dist\prod\claw-onboard\browseros-claw-onboard-resources.zip" --dest "%ONBOARD_DEST%"
if errorlevel 1 goto :fail

goto :agent_done

:stage_published
REM The download_resources step fetches these bundles via the R2 S3 API, which
REM needs credentials. The identical objects are served anonymously at
REM cdn.browseros.com (same bucket's public CDN), so we stage them here and
REM skip that step. Keys/destinations mirror bos_build/config/download_resources.yaml.
set "STAGE_DIR=%TEMP%\browseros-cdn-staging"
if not exist "%STAGE_DIR%" mkdir "%STAGE_DIR%"

set "TARGET=windows-%ARCH%"
if /I "%PRODUCT%"=="browserclaw" (
    set "SERVER_URL=https://cdn.browseros.com/claw-server-rust/prod-resources/latest/browseros-claw-server-rust-resources-%TARGET%.zip"
    set "ONBOARD_URL=https://cdn.browseros.com/claw-onboard/prod-resources/latest/browseros-claw-onboard-resources.zip"
) else (
    set "SERVER_URL=https://cdn.browseros.com/artifacts/server/latest/browseros-server-resources-%TARGET%.zip"
    set "ONBOARD_URL=https://cdn.browseros.com/app-onboard/prod-resources/latest/browseros-app-onboard-resources.zip"
    set "SERVER_DEST=resources\binaries\browseros_server\%TARGET%"
)

echo [build] Staging published resources from cdn.browseros.com (no R2 credentials needed)...
curl.exe -fL --retry 3 --connect-timeout 20 -o "%STAGE_DIR%\server.zip" "%SERVER_URL%"
if errorlevel 1 goto :fail
curl.exe -fL --retry 3 --connect-timeout 20 -o "%STAGE_DIR%\onboard.zip" "%ONBOARD_URL%"
if errorlevel 1 goto :fail

uv run python tools\stage_cdn_resources.py --zip "%STAGE_DIR%\server.zip" --dest "%SERVER_DEST%"
if errorlevel 1 goto :fail
uv run python tools\stage_cdn_resources.py --zip "%STAGE_DIR%\onboard.zip" --dest "%ONBOARD_DEST%"
if errorlevel 1 goto :fail

:agent_done
REM TARGET is only a local helper for the CDN URLs above; Chromium's Rust
REM bindgen step refuses to run when TARGET is in the environment, so clear it.
set "TARGET="

set "SIGN_FLAG=--no-sign"
if /I "%SIGN%"=="yes" set "SIGN_FLAG=--sign"
set "UPLOAD_FLAG=--no-upload"
if /I "%UPLOAD%"=="yes" set "UPLOAD_FLAG=--upload"

echo.
echo [build] Running: uv run browseros build --preset %PRESET% --product %PRODUCT% ^
  --arch %ARCH% --resource-mode %RESOURCE_MODE% %SIGN_FLAG% %UPLOAD_FLAG% --provision %PROVISION% --chromium-src "%CHROMIUM_SRC%" --skip download_resources
echo.

uv run browseros build --preset %PRESET% --product %PRODUCT% --arch %ARCH% --resource-mode %RESOURCE_MODE% %SIGN_FLAG% %UPLOAD_FLAG% --provision %PROVISION% --chromium-src "%CHROMIUM_SRC%" --skip download_resources
if errorlevel 1 goto :fail

REM --- Result ------------------------------------------------------------------
REM Mirror bos_build/lib/versions.py load_semantic_version: PATCH only when
REM non-zero, a zero BUILD still renders as ".0".
set "BV_MAJ=0" & set "BV_MIN=0" & set "BV_BLD=0" & set "BV_PAT=0"
for /f "tokens=1,2 delims==" %%a in (resources\BROWSEROS_VERSION) do (
    if "%%a"=="BROWSEROS_MAJOR" set "BV_MAJ=%%b"
    if "%%a"=="BROWSEROS_MINOR" set "BV_MIN=%%b"
    if "%%a"=="BROWSEROS_BUILD" set "BV_BLD=%%b"
    if "%%a"=="BROWSEROS_PATCH" set "BV_PAT=%%b"
)
if "!BV_PAT!" neq "0" (
    set "BVER=!BV_MAJ!.!BV_MIN!.!BV_BLD!.!BV_PAT!"
) else if "!BV_BLD!" neq "0" (
    set "BVER=!BV_MAJ!.!BV_MIN!.!BV_BLD!"
) else (
    set "BVER=!BV_MAJ!.!BV_MIN!.0"
)

if /I "%PRODUCT%"=="browserclaw" (
    set "ART_PREFIX=BrowserOS_neo"
    set "APP_NAME=BrowserOS neo"
) else (
    set "ART_PREFIX=BrowserOS"
    set "APP_NAME=BrowserOS"
)
set "DIST_DIR=%~dp0packages\browseros\releases\%BVER%"
set "INSTALLER_EXE=%ART_PREFIX%_v%BVER%_%ARCH%_installer.exe"
set "OUT_APP=%CHROMIUM_SRC%\out\Default_%PRODUCT%_%ARCH%\%APP_NAME%.exe"

echo.
echo === Build complete ===
if exist "%DIST_DIR%\%INSTALLER_EXE%" (
    for %%f in ("%DIST_DIR%\%INSTALLER_EXE%") do echo   Installer ^(run this^): %%~ff  [%%~zf bytes]
) else (
    echo   WARNING: expected installer not found: %DIST_DIR%\%INSTALLER_EXE%
)
if exist "%OUT_APP%" (
    for %%f in ("%OUT_APP%") do echo   Browser exe ^(no install needed^): %%~ff
)
echo   Dist dir: %DIST_DIR%
endlocal
pause
exit /b 0

:fail
echo.
echo [build] FAILED. See the error above. Rerun build.bat to resume; ninja picks up where it stopped.
endlocal
pause
exit /b 1
