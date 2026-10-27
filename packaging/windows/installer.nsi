; Instalador NSIS para deepseek-harness (Windows).
; Generado por scripts/build-exe.sh - no editar los valores @...@ a mano.
Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"

!ifndef APP_NAME
  !define APP_NAME "deepseek-harness"
!endif
!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
!ifndef APP_VERSION4
  !define APP_VERSION4 "0.0.0.0"
!endif
!ifndef APP_PUBLISHER
  !define APP_PUBLISHER "DeepSeek Harness Contributors"
!endif
!ifndef APP_URL
  !define APP_URL "https://example.invalid"
!endif
!ifndef SOURCE_DIR
  !error "SOURCE_DIR no definido"
!endif
!ifndef OUT_FILE
  !error "OUT_FILE no definido"
!endif

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUT_FILE}"
InstallDir "$PROGRAMFILES64\${APP_NAME}"
InstallDirRegKey HKLM "Software\${APP_NAME}" "InstallDir"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "${APP_PUBLISHER}"

VIProductVersion "${APP_VERSION4}"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey "FileDescription" "Instalador de ${APP_NAME}"
VIAddVersionKey "LegalCopyright" "GPL-3.0-or-later"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_NOAUTOCLOSE
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Spanish"

Section "Instalar ${APP_NAME}" SecMain
  SetRegView 64
  SetOutPath "$INSTDIR"
  File /r "${SOURCE_DIR}/*"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  WriteRegStr HKLM "Software\${APP_NAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\${APP_NAME}" "Version" "${APP_VERSION}"

  ; Añadir al PATH del sistema guardando una copia para restaurarla al desinstalar.
  ReadRegStr $0 HKLM "Software\${APP_NAME}" "PathBackedUp"
  ${If} $0 != "1"
    ReadRegStr $1 HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path"
    WriteRegStr HKLM "Software\${APP_NAME}" "PathBackup" "$1"
    WriteRegStr HKLM "Software\${APP_NAME}" "PathBackedUp" "1"
    WriteRegExpandStr HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path" "$1;$INSTDIR"
    SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
  ${EndIf}

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$SYSDIR\cmd.exe" \
    '/k "cd /d $INSTDIR && deepseek-harness.cmd --help"'
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk" "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  SetRegView 64
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"

  ReadRegStr $0 HKLM "Software\${APP_NAME}" "PathBackedUp"
  ${If} $0 == "1"
    ReadRegStr $1 HKLM "Software\${APP_NAME}" "PathBackup"
    ${If} $1 == ""
      DeleteRegValue HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path"
    ${Else}
      WriteRegExpandStr HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "Path" "$1"
    ${EndIf}
    SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
  ${EndIf}

  DeleteRegKey HKLM "Software\${APP_NAME}"
  RMDir /r "$INSTDIR"
SectionEnd
