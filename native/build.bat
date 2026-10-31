@echo off
rem Builds the native module as winhttp.dll (freestanding C++: no CRT, no Windows SDK needed).
rem Requires Visual Studio 2022 or later with the "Desktop development with C++" workload.
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (echo vswhere.exe not found: install Visual Studio with C++ tools & exit /b 1)
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo Visual Studio C++ tools not found & exit /b 1)
set /p VCVER=<"%VSDIR%\VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
set "VC=%VSDIR%\VC\Tools\MSVC\%VCVER%"
set "PATH=%VC%\bin\Hostx64\x64;%PATH%"
set "INCLUDE=%VC%\include"
set "LIB=%VC%\lib\x64"
cd /d "%~dp0"
if not exist out mkdir out
lib /nologo /def:kernel32.def /out:out\kernel32.lib /machine:x64 || exit /b 1
cl /nologo /c /WX /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 mpfever_native.cpp /Fo:out\mpfever_native.obj || exit /b 1
cl /nologo /c /WX /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 winhttp_proxy.cpp /Fo:out\winhttp_proxy.obj || exit /b 1
rem Steam networking: MPFever's connections carried by Steam inside the game (see mpf_steamnet.cpp)
cl /nologo /c /WX /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 mpf_steamnet.cpp /Fo:out\mpf_steamnet.obj || exit /b 1
rem the mathematics every game computes alike (see mpf_math.cpp)
cl /nologo /c /WX /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 mpf_math.cpp /Fo:out\mpf_math.obj || exit /b 1
ml64 /nologo /c /Fo out\mpf_math_asm.obj mpf_math_asm.asm || exit /b 1
rem __chkstk, which recent toolsets call and the CRT would give (the module links without it)
ml64 /nologo /c /Fo out\chkstk.obj chkstk.asm || exit /b 1
rem the module's version (Properties > Details: code signing checks its product name and version), VERSION of build.bat:
rem a compiled resource written by tools\mkres.py, since the C++ tools have no resource compiler without the Windows SDK
if not defined VERSION set "VERSION=0.0.0"
python ..\tools\mkres.py out\version.res %VERSION% || (echo Python not found: install Python 3 & exit /b 1)
rem the module takes the name winhttp.dll: the game loads it by itself from its folder
link /nologo /WX /DLL /NODEFAULTLIB /ENTRY:DllMain /DEF:winhttp.def /OUT:out\winhttp.dll out\mpfever_native.obj out\winhttp_proxy.obj out\mpf_steamnet.obj out\mpf_math.obj out\mpf_math_asm.obj out\chkstk.obj out\version.res out\kernel32.lib || exit /b 1
echo BUILD OK
