@echo off
rem ============================================================================
rem  build-apk.cmd  --  one-command, overwrite-installable release build
rem
rem  Usage:
rem    build-apk.cmd                    bump the build number, build, verify, publish
rem    set "NO_BUMP=1" ^& build-apk.cmd  build the version already in pubspec.yaml
rem
rem  Steps (stops at the first failure):
rem    0. runs in the folder holding this script, whatever the current dir is
rem    1. resolves JAVA_HOME / ANDROID_HOME / flutter for this window only
rem       (environment variables first, then generic default locations)
rem    2. reads "version: X.Y.Z+N" from pubspec.yaml
rem    3. HARD GUARD, two independent checks:
rem       (a) the versionCode to be published must be >= every APK of the same
rem           applicationId already in the dist folder (baseline);
rem       (b) it must be >= MIN_VERSION_CODE (default 20000, overridable).
rem       Otherwise it aborts: Android refuses to replace an installed app with
rem       a lower versionCode ("app not installed"). NO_BUMP=1 never bumps and
rem       passes both checks as long as the current value satisfies them.
rem    4. writes the version back to pubspec.yaml (traceable diff)
rem    5. flutter build apk --release --flavor full
rem    6. verifies the produced APK: versionCode / versionName / signing cert
rem       SHA-256 (must equal the key.jks certificate), otherwise aborts
rem    7. copies to %DIST%\hermes-console-<versionName>+<build>.apk
rem    8. prints versionCode / versionName / cert SHA-256 / size / path
rem
rem  On any failure after step 4 the original version line is restored, so
rem  re-running is always safe.
rem ============================================================================
setlocal EnableDelayedExpansion
chcp 65001 >nul

rem Build in the repository the script lives in, no matter where it is called
rem from (a build started in another cwd silently produces no usable apk).
pushd "%~dp0" >nul 2>nul
if errorlevel 1 ( echo [FAIL] cannot enter the script folder: %~dp0 & exit /b 1 )

rem Accept "set NO_BUMP=1 " (trailing space) as well.
if defined NO_BUMP set "NO_BUMP=%NO_BUMP: =%"

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

rem ---------------------------------------------------------------- settings --
rem Toolchain locations: environment variables win. The fallbacks below are only
rem tried when a variable is missing, and they are generic locations - no
rem machine-specific path is hard-coded here. See docs\UPDATE-APK.md section 6
rem for how to set JAVA_HOME / ANDROID_HOME / FLUTTER_HOME.
set "JAVA_HOME_ENV=%JAVA_HOME%"
set "ANDROID_HOME_ENV=%ANDROID_HOME%"

rem A stale JAVA_HOME (typically JDK 8) breaks Gradle with
rem "Gradle requires JVM 17 or later to run" - drop it and look for a 17.
if defined JAVA_HOME if exist "%JAVA_HOME%\release" for /f "tokens=2 delims==" %%V in ('type "%JAVA_HOME%\release" ^| findstr /b /c:"JAVA_VERSION="') do set "JAVAVER=%%~V"
if defined JAVAVER for /f "tokens=1 delims=." %%M in ("!JAVAVER!") do set "JAVAMAJOR=%%M"
if defined JAVAMAJOR if !JAVAMAJOR! LSS 17 (
  echo [WARN] JAVA_HOME is JDK !JAVAVER! but Gradle needs 17+ - looking for a JDK 17.
  set "JAVA_HOME="
)

if not defined JAVA_HOME for /d %%J in ("%USERPROFILE%\.jdks\*17*") do if not defined JAVA_HOME if exist "%%~fJ\bin\java.exe" set "JAVA_HOME=%%~fJ"
if not defined JAVA_HOME if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
if not defined JAVA_HOME if exist "%ProgramFiles%\Java\jdk-17\bin\java.exe" set "JAVA_HOME=%ProgramFiles%\Java\jdk-17"

if not defined ANDROID_HOME if exist "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
if not defined ANDROID_HOME if exist "C:\Android\sdk\platform-tools\adb.exe" set "ANDROID_HOME=C:\Android\sdk"
if defined ANDROID_HOME set "ANDROID_SDK_ROOT=%ANDROID_HOME%"

if not defined FLUTTER if defined FLUTTER_HOME if exist "%FLUTTER_HOME%\bin\flutter.bat" set "FLUTTER=%FLUTTER_HOME%\bin\flutter.bat"
if not defined FLUTTER if exist "C:\flutter\bin\flutter.bat" set "FLUTTER=C:\flutter\bin\flutter.bat"
if not defined FLUTTER for /f "delims=" %%F in ('where flutter 2^>nul') do if not defined FLUTTER set "FLUTTER=%%~fF"
if defined FLUTTER for %%F in ("%FLUTTER%") do set "FLUTTER_DIR=%%~dpF"

if not defined JAVA_HOME_ENV if defined JAVA_HOME echo [INFO] JAVA_HOME not set - using detected JDK: !JAVA_HOME!
if defined JAVA_HOME_ENV if defined JAVA_HOME if not "!JAVA_HOME!"=="!JAVA_HOME_ENV!" echo [INFO] using JDK !JAVA_HOME! instead of the JAVA_HOME above.
if not defined ANDROID_HOME_ENV if defined ANDROID_HOME echo [INFO] ANDROID_HOME not set - using detected SDK: %ANDROID_HOME%
if not defined JAVA_HOME echo [WARN] no JDK 17 found - set JAVA_HOME (see docs\UPDATE-APK.md).

if not defined DIST set "DIST=C:\Hermes\downloads"
set "FLAVOR=full"
set "APP_ID=dev.xpetalab.hermesconsole"
rem Floor for new versionCodes. Override by setting MIN_VERSION_CODE beforehand.
if not defined MIN_VERSION_CODE set "MIN_VERSION_CODE=20000"
rem SHA-256 of the release certificate inside C:\hermes-console\key.jks (alias hermes).
set "EXPECTED_CERT=1bb7c202211fe38559e6c8236dc4d1f1e051a7542cffa8bff18b2ac821d37321"

set "PATH=%JAVA_HOME%\bin;%FLUTTER_DIR%;%ANDROID_HOME%\platform-tools;%PATH%"
rem build-tools: probe newest first (36.0.0 -> 35.0.0 -> whatever else is
rem installed) and keep the first folder that ships BOTH tools, so a machine with
rem only 35.0.0 still builds instead of failing on a missing aapt2.
set "BT_DIR="
if defined ANDROID_HOME for %%V in (36.0.0 35.0.0 34.0.0 33.0.0) do (
  if not defined BT_DIR if exist "%ANDROID_HOME%\build-tools\%%V\apksigner.bat" if exist "%ANDROID_HOME%\build-tools\%%V\aapt2.exe" set "BT_DIR=%ANDROID_HOME%\build-tools\%%V"
)
if not defined BT_DIR if defined ANDROID_HOME for /f "delims=" %%D in ('dir /b /ad /o-n "%ANDROID_HOME%\build-tools" 2^>nul') do (
  if not defined BT_DIR if exist "%ANDROID_HOME%\build-tools\%%D\apksigner.bat" if exist "%ANDROID_HOME%\build-tools\%%D\aapt2.exe" set "BT_DIR=%ANDROID_HOME%\build-tools\%%D"
)
set "APKSIGNER="
set "AAPT2="
if defined BT_DIR set "APKSIGNER=%BT_DIR%\apksigner.bat"
if defined BT_DIR set "AAPT2=%BT_DIR%\aapt2.exe"
if defined BT_DIR echo [INFO] build-tools !BT_DIR!
rem Tool output is parsed from a temp file, never from a for /f command line:
rem cmd /c strips the outer quotes of a command that starts with a quoted path,
rem which breaks every "C:\Android Sdk\..." install.
if not defined TEMP set "TEMP=!ROOT!"
set "BADGING=%TEMP%\hermes-console-badging.txt"

rem ------------------------------------------------------------------ checks --
if not exist "%FLUTTER%"           ( echo [FAIL] flutter not found: %FLUTTER% & goto :abort_env )
if not defined ANDROID_HOME    ( echo [FAIL] ANDROID_HOME is not set and no SDK was found - see docs\UPDATE-APK.md section 6 & goto :abort_env )
if not defined AAPT2           ( echo [FAIL] no build-tools with apksigner.bat and aapt2.exe under "%ANDROID_HOME%\build-tools" & goto :abort_env )
if not exist "!ROOT!\pubspec.yaml" ( echo [FAIL] pubspec.yaml not found in !ROOT! & goto :abort_env )
if not exist "%DIST%"              ( echo [FAIL] dist folder not found: %DIST% & goto :abort_env )

rem ------------------------------------------------------- read current version --
set "VERRAW="
for /f "tokens=2 delims=:" %%V in ('findstr /b /c:"version:" "!ROOT!\pubspec.yaml"') do set "VERRAW=%%V"
if not defined VERRAW ( echo [FAIL] no "version:" line in pubspec.yaml & goto :abort_env )
set "VERRAW=!VERRAW: =!"

set "VERNAME="
set "BUILD="
for /f "tokens=1,2 delims=+" %%A in ("!VERRAW!") do (
  set "VERNAME=%%A"
  set "BUILD=%%B"
)
if not defined BUILD ( echo [FAIL] version "!VERRAW!" is not in X.Y.Z+N form & goto :abort_env )

set "SKIPWRITE="
set /a NEXT=!BUILD!+1
if "%NO_BUMP%"=="1" (
  set /a NEXT=!BUILD!
  set "SKIPWRITE=1"
)

rem ------------------------------------------- published baseline (versionCode) --
set "PUBLISHED=0"
for %%F in ("%DIST%\*.apk") do (
  "%AAPT2%" dump badging "%%~fF" 2>nul | findstr /b /c:"package:" > "%BADGING%"
  for /f "usebackq tokens=2,4 delims='" %%A in ("%BADGING%") do (
    if "%%A"=="%APP_ID%" (
      set /a CAND=%%B
      if !CAND! GTR !PUBLISHED! set "PUBLISHED=!CAND!"
    )
  )
)
del "%BADGING%" >nul 2>nul
set /a BASELINE=%PUBLISHED%

echo.
echo   pubspec now    : !VERNAME!+!BUILD!
echo   to publish     : !VERNAME!+!NEXT!
echo   published max  : %PUBLISHED% in %DIST%   floor: %MIN_VERSION_CODE%   baseline: %BASELINE%
echo.

rem Rule 1: must exceed every already published package. Equal is allowed when
rem rebuilding the version already in pubspec.yaml (NO_BUMP=1) or when
rem ALLOW_SAME_CODE=1; below the published maximum is always refused.
set "RULE1_FAIL="
set /a EXPECTED_PUB=!NEXT!+2000
if !EXPECTED_PUB! LSS !BASELINE! set "RULE1_FAIL=1"
if !NEXT! EQU !BASELINE! if not "%NO_BUMP%"=="1" if not "%ALLOW_SAME_CODE%"=="1" set "RULE1_FAIL=1"
if defined RULE1_FAIL (
  echo [FAIL] versionCode !NEXT! does not exceed the published maximum !BASELINE!.
  echo        Android refuses to replace the installed app with a lower versionCode
  echo        INSTALL_FAILED_VERSION_DOWNGRADE / "app not installed".
  echo        Raise the build number in pubspec.yaml above !BASELINE! and re-run.
  echo        To rebuild the exact same version, set ALLOW_SAME_CODE=1.
  goto :abort_env
)
rem Rule 2: never go below the global floor (keeps us ahead of old 11xxx packages).
if !NEXT! LSS %MIN_VERSION_CODE% (
  echo [FAIL] versionCode !NEXT! is below the floor %MIN_VERSION_CODE%.
  echo        Raise the build number in pubspec.yaml to at least %MIN_VERSION_CODE%.
  goto :abort_env
)

rem --------------------------------------------------------------- write pubspec --
set "ORIGVER=!VERRAW!"
if not defined SKIPWRITE (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='!ROOT!\pubspec.yaml'; $t=[IO.File]::ReadAllText($p); $t=[regex]::Replace($t,'(?m)^^version:[^^\r\n]*','version: !VERNAME!+!NEXT!'); [IO.File]::WriteAllText($p,$t)"
  if errorlevel 1 ( echo [FAIL] could not rewrite pubspec.yaml & goto :abort_env )
  findstr /b /c:"version: !VERNAME!+!NEXT!" "!ROOT!\pubspec.yaml" >nul
  if errorlevel 1 ( echo [FAIL] pubspec.yaml was not updated & goto :abort_pubspec )
)

echo [1/4] building release apk flavor %FLAVOR% ...
call "!FLUTTER!" build apk --release --flavor %FLAVOR% --target-platform android-arm64 --split-per-abi
if errorlevel 1 ( echo [FAIL] flutter build apk failed - see gradle output above & goto :abort_pubspec )

set "APK=!ROOT!\build\app\outputs\flutter-apk\app-arm64-v8a-%FLAVOR%-release.apk"
if not exist "!APK!" ( echo [FAIL] expected apk missing: !APK! & goto :abort_pubspec )

echo [2/4] verifying apk metadata...
set "GOT_CODE="
set "GOT_NAME="
"%AAPT2%" dump badging "!APK!" 2>nul | findstr /b /c:"package:" > "%BADGING%"
for /f "usebackq tokens=4,6 delims='" %%A in ("%BADGING%") do (
  set "GOT_CODE=%%A"
  set "GOT_NAME=%%B"
)
rem split-per-abi: flutter 给 arm64-v8a 加 +2000 偏移（NEXT -> NEXT+2000）
set /a EXPECTED_CODE=!NEXT!+2000
if !GOT_CODE! LSS !EXPECTED_CODE! (
  echo [FAIL] apk versionCode !GOT_CODE! is below expected !EXPECTED_CODE! - arm64 split adds 2000
  goto :abort_pubspec
)
if not "!GOT_NAME!"=="!VERNAME!" (
  echo [FAIL] apk versionName !GOT_NAME! does not match expected !VERNAME!
  goto :abort_pubspec
)
echo        versionCode=!GOT_CODE!  versionName=!GOT_NAME!

echo [3/4] verifying signature...
set "CERT="
"%APKSIGNER%" verify --print-certs "!APK!" 2>nul | findstr /c:"SHA-256 digest" > "%BADGING%"
for /f "usebackq tokens=2 delims=:" %%C in ("%BADGING%") do set "CERT=%%C"
if not defined CERT ( echo [FAIL] apksigner could not read the certificate & goto :abort_pubspec )
set "CERT=!CERT: =!"
if /i not "!CERT!"=="%EXPECTED_CERT%" (
  echo.
  echo [FAIL] signing certificate mismatch.
  echo        apk : !CERT!
  echo        key : %EXPECTED_CERT%
  echo        A package signed with another key cannot be installed over the installed app;
  echo        the phone reports "app not installed". See docs\UPDATE-APK.md.
  goto :abort_pubspec
)

echo [4/4] publishing...
set "OUT=%DIST%\hermes-console-!VERNAME!+!NEXT!.apk"
copy /y "!APK!" "!OUT!" >nul
if errorlevel 1 ( echo [FAIL] could not copy the apk to %DIST% & goto :abort_pubspec )

set "SIZE=0"
set "RAW=0"
for %%S in ("!OUT!") do set /a RAW=%%~zS
set /a SIZE=!RAW!/1048576

echo.
echo ============================================================
echo   BUILD OK  --  overwrite-installable release
echo ------------------------------------------------------------
echo   package       : %APP_ID%
echo   versionName   : !GOT_NAME!
echo   versionCode   : !GOT_CODE!   previous published max: %PUBLISHED%
echo   cert SHA-256  : !CERT!
echo   apk           : !OUT!
echo   size          : !SIZE! MB  !RAW! bytes
echo ============================================================
echo.
echo   install over USB:  adb install -r "!OUT!"
echo.
del "%BADGING%" >nul 2>nul
popd
endlocal
exit /b 0

:abort_pubspec
if not defined SKIPWRITE (
  echo [ROLLBACK] restoring pubspec.yaml to version: !ORIGVER!
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='!ROOT!\pubspec.yaml'; $t=[IO.File]::ReadAllText($p); $t=[regex]::Replace($t,'(?m)^^version:[^^\r\n]*','version: !ORIGVER!'); [IO.File]::WriteAllText($p,$t)"
)

:abort_env
echo.
echo [ABORTED] nothing was published.
del "%BADGING%" >nul 2>nul
popd
endlocal
exit /b 1
