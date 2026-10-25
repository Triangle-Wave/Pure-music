#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif

#define AppName "Pure Music"
#define AppExeName "pure_music.exe"

[Setup]
AppId={{42C4470A-72BE-49A0-B32F-DF7A941DD48C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=qingyueyin
AppPublisherURL=https://github.com/Triangle-Wave/Pure-music
AppSupportURL=https://github.com/Triangle-Wave/Pure-music/issues
AppUpdatesURL=https://github.com/Triangle-Wave/Pure-music/releases
AppContact=qingyueyin
AppComments=Windows 本地音乐播放器；TAK 解码由 BASS_FFMPEG 插件与 FFmpeg 共享库提供（GPLv3），许可见安装目录 ffmpeg\LICENSE
AppCopyright=Copyright (C) 2026 qingyueyin
DefaultDirName={localappdata}\Programs\{#AppName}
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=.
OutputBaseFilename=pure_music_installer
SetupIconFile=..\app_icon.ico
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
VersionInfoDescription={#AppName} 安装程序
VersionInfoCompany=qingyueyin
VersionInfoCopyright=Copyright (C) 2026 qingyueyin
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.0
WizardStyle=modern dynamic
DisableWelcomePage=no
DisableReadyPage=no
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no
Compression=lzma2/max
SolidCompression=yes
LZMAUseSeparateProcess=yes
SetupLogging=yes

[Languages]
; 语言文件随仓库提供，相对本脚本所在目录解析，编译不依赖 Inno Setup 安装目录的语言包。
Name: "zhcn"; MessagesFile: "ChineseSimplified.isl"

[Messages]
zhcn.TranslatorNote=
; 安装目录同时承载程序与用户数据，避免用户把程序装在一处、数据分散到别处。
zhcn.SelectDirDesc=程序文件与用户数据（设置、曲库索引、播放列表、歌词来源、缓存）都会放在下面的安装目录中，user_data 与程序位于同一目录；安装到其他盘时两者一起位于该盘。请确保当前用户对该目录有写入权限。

[CustomMessages]
PortableDataTitle=导入便携版数据
PortableDataDescription=是否迁移原便携版中的个人数据？
PortableDataSubCaption=此步骤可选。安装程序只会迁移设置、媒体库、播放列表和歌词来源记录，不会修改原文件。
PortableDataOption=从原便携版导入个人数据(&I)
PortableDataPathTitle=选择便携版位置
PortableDataPathDescription=原便携版位于哪个文件夹？
PortableDataPathSubCaption=请选择包含 pure_music.exe 的原便携版文件夹。
PortableDataInvalid=所选文件夹不是完整的 Pure Music 便携版目录，请重新选择。
PortableDataImporting=正在导入便携版数据...
PortableDataImportFailed=Pure Music 已安装完成，但便携版数据导入失败。原便携版数据没有被修改，可稍后重新迁移。
LegacyDataImporting=正在迁移旧版安装的数据...
LegacyDataImportFailed=旧版安装的数据未能迁移到新数据目录，安装仍已完成。原数据保留在 %1，可稍后手动复制到安装目录的 user_data 中。
DesktopIcon=创建桌面快捷方式(&D)
DeleteUserDataPrompt=是否同时删除 Pure Music 的用户数据？%n%n%1%n%n选择“否”会保留这些数据，便于以后重新安装。
DeleteUserDataFailed=部分用户数据未能删除，请关闭仍在使用 Pure Music 数据的程序后手动清理：%n%n%1

[Files]
; user_data 是用户数据目录，不属于安装内容；Excludes 保证即使构建产物里出现同名内容也不会写入用户目录。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "user_data\*"
Source: "import_portable_data.ps1"; Flags: dontcopy

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Dirs]
; 用户数据根：应用把 settings、db、曲库索引、播放列表、歌词来源与缓存写入这里。
; uninsneveruninstall 让卸载程序不尝试删除该目录，用户数据默认保留。
Name: "{app}\user_data"; Flags: uninsneveruninstall

[InstallDelete]
Type: filesandordirs; Name: "{autoprograms}\{#AppName}"
; 覆盖安装前清空运行时目录，避免旧版插件 DLL、Flutter 资源、FFmpeg 共享库与桌面歌词混入新版本。
; data 是 Flutter 运行时资源目录（app.so、flutter_assets），不承载安装版用户数据；
; 用户数据在 {app}\user_data，不在清理范围内。
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\dll"
Type: filesandordirs; Name: "{app}\ffmpeg"
Type: filesandordirs; Name: "{app}\desktop_lyric"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Pure Music"; ValueType: string; ValueName: "InstallLocation"; ValueData: "{app}"; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  PortableDataChoicePage: TInputOptionWizardPage;
  PortableDataPathPage: TInputDirWizardPage;
  PortableSourceData: String;

function DirectoryHasEntries(const Path: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := False;
  if not DirExists(Path) then
    Exit;

  if FindFirst(AddBackslash(Path) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          Result := True;
          Exit;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function ResolvePortableDataPath(const SelectedPath: String): String;
var
  CandidateRoot: String;
  CandidateData: String;
begin
  Result := '';
  CandidateRoot := SelectedPath;
  if FileExists(AddBackslash(CandidateRoot) + '{#AppExeName}') then
  begin
    CandidateData := AddBackslash(CandidateRoot) + 'data';
    if FileExists(AddBackslash(CandidateData) + 'app.so') and
       DirExists(AddBackslash(CandidateData) + 'flutter_assets') then
    begin
      Result := CandidateData;
      Exit;
    end;
  end;

  CandidateRoot := AddBackslash(SelectedPath) + 'app';
  if FileExists(AddBackslash(CandidateRoot) + '{#AppExeName}') then
  begin
    CandidateData := AddBackslash(CandidateRoot) + 'data';
    if FileExists(AddBackslash(CandidateData) + 'app.so') and
       DirExists(AddBackslash(CandidateData) + 'flutter_assets') then
      Result := CandidateData;
  end;
end;

procedure InitializeWizard;
begin
  PortableDataChoicePage := CreateInputOptionPage(
    wpSelectDir,
    CustomMessage('PortableDataTitle'),
    CustomMessage('PortableDataDescription'),
    CustomMessage('PortableDataSubCaption'),
    False,
    False);
  PortableDataChoicePage.Add(CustomMessage('PortableDataOption'));
  PortableDataChoicePage.Values[0] := False;

  PortableDataPathPage := CreateInputDirPage(
    PortableDataChoicePage.ID,
    CustomMessage('PortableDataPathTitle'),
    CustomMessage('PortableDataPathDescription'),
    CustomMessage('PortableDataPathSubCaption'),
    False,
    '');
  PortableDataPathPage.Add('');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
var
  HasInstalledData: Boolean;
begin
  // 已有新数据目录，或存在待迁移的旧版安装数据时，跳过便携版导入页，避免覆盖现有数据。
  HasInstalledData := DirectoryHasEntries(ExpandConstant('{app}\user_data')) or
    DirectoryHasEntries(ExpandConstant('{localappdata}\pure_music'));
  Result := ((PageID = PortableDataChoicePage.ID) or
    (PageID = PortableDataPathPage.ID)) and HasInstalledData;
  if not Result and (PageID = PortableDataPathPage.ID) then
    Result := not PortableDataChoicePage.Values[0];
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = PortableDataChoicePage.ID then
  begin
    if not PortableDataChoicePage.Values[0] then
      PortableSourceData := '';
    Exit;
  end;

  if CurPageID <> PortableDataPathPage.ID then
    Exit;

  PortableSourceData := '';
  PortableSourceData := ResolvePortableDataPath(PortableDataPathPage.Values[0]);
  if PortableSourceData = '' then
  begin
    MsgBox(CustomMessage('PortableDataInvalid'), mbError, MB_OK);
    Result := False;
  end;
end;

procedure RunDataImport(SourceData, DestinationData: String;
  AllowAppData: Boolean);
var
  PowerShellPath: String;
  ScriptPath: String;
  Params: String;
  ResultCode: Integer;
begin
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\import_portable_data.ps1');
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    AddQuotes(ScriptPath) + ' -SourceData ' + AddQuotes(SourceData) +
    ' -DestinationData ' + AddQuotes(DestinationData);
  if AllowAppData then
    Params := Params + ' -SourceIsAppData';

  if (not Exec(PowerShellPath, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or
     (ResultCode <> 0) then
  begin
    Log(Format('数据导入失败，退出代码：%d，来源：%s', [ResultCode, SourceData]));
    if AllowAppData then
      MsgBox(FmtMessage(CustomMessage('LegacyDataImportFailed'), [SourceData]),
        mbError, MB_OK)
    else
      MsgBox(CustomMessage('PortableDataImportFailed'), mbError, MB_OK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  UserDataPath: String;
  LegacyDataPath: String;
begin
  if CurStep = ssInstall then
  begin
    ExtractTemporaryFile('import_portable_data.ps1');
    Exit;
  end;

  if CurStep <> ssPostInstall then
    Exit;

  UserDataPath := ExpandConstant('{app}\user_data');

  if PortableSourceData <> '' then
  begin
    WizardForm.StatusLabel.Caption := CustomMessage('PortableDataImporting');
    RunDataImport(PortableSourceData, UserDataPath, False);
    Exit;
  end;

  // 旧版安装数据位于 %LOCALAPPDATA%\pure_music；新数据目录为空时复制持久化数据，
  // 原目录保留，迁移失败也不影响安装结果。
  LegacyDataPath := ExpandConstant('{localappdata}\pure_music');
  if (not DirectoryHasEntries(UserDataPath)) and
     DirectoryHasEntries(LegacyDataPath) then
  begin
    WizardForm.StatusLabel.Caption := CustomMessage('LegacyDataImporting');
    RunDataImport(LegacyDataPath, UserDataPath, True);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  UserDataPath: String;
  LegacyDataPath: String;
  Paths: String;
  FailedPaths: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;

  UserDataPath := ExpandConstant('{app}\user_data');
  LegacyDataPath := ExpandConstant('{localappdata}\pure_music');

  Paths := '';
  if DirExists(UserDataPath) then
    Paths := UserDataPath;
  if DirExists(LegacyDataPath) then
  begin
    if Paths <> '' then
      Paths := Paths + #13#10;
    Paths := Paths + LegacyDataPath;
  end;
  if Paths = '' then
    Exit;

  if SuppressibleMsgBox(
       FmtMessage(CustomMessage('DeleteUserDataPrompt'), [Paths]),
       mbConfirmation,
       MB_YESNO or MB_DEFBUTTON2,
       IDNO) <> IDYES then
    Exit;

  FailedPaths := '';
  if DirExists(UserDataPath) and
     (not DelTree(UserDataPath, True, True, True)) then
    FailedPaths := UserDataPath;
  if DirExists(LegacyDataPath) and
     (not DelTree(LegacyDataPath, True, True, True)) then
  begin
    if FailedPaths <> '' then
      FailedPaths := FailedPaths + #13#10;
    FailedPaths := FailedPaths + LegacyDataPath;
  end;
  if FailedPaths <> '' then
    SuppressibleMsgBox(
      FmtMessage(CustomMessage('DeleteUserDataFailed'), [FailedPaths]),
      mbError,
      MB_OK,
      IDOK);
end;
