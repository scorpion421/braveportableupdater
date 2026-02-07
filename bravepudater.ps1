<#
.SYNOPSIS
    Brave Portable Updater - WPF-based update launcher for Brave Portable (portapps).

.DESCRIPTION
    Checks for new Brave Browser releases via the GitHub API, downloads the
    official ZIP archive (brave-v*-win32-x64.zip), and replaces the app folder
    inside a portapps-style Brave Portable installation.

    Zero external dependencies. Uses native PowerShell Expand-Archive.

.NOTES
    File Name : scriptupdater.ps1
    Config    : braveupdater.json  (same directory as the script)
    Structure : The script expects to live next to the portapps directory
                layout (.\app\<version>\brave.exe, .\data\, etc.).
#>

# =========================================================================
# S0  STRICT MODE, TLS & GLOBAL CONSTANTS
# =========================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force TLS 1.2+ (required for GitHub API and downloads)
[System.Net.ServicePointManager]::SecurityProtocol =
    [System.Net.SecurityProtocolType]::Tls12 -bor
    [System.Net.SecurityProtocolType]::Tls13

# Resolve base paths relative to the script's own location
$Script:BasePath    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Script:AppPath     = Join-Path $Script:BasePath 'app'
$Script:ConfigFile  = Join-Path $Script:BasePath 'braveupdater.json'
$Script:TempPath    = Join-Path $Script:BasePath '.updater_temp'

# GitHub API
$Script:GitHubApiBase = 'https://api.github.com/repos/brave/brave-browser/releases'
$Script:UserAgent     = 'BravePortableUpdater/1.0'

# Channel identifier in release name
$Script:ChannelKeywords = @{
    'Stable'  = 'Release'
    'Beta'    = 'Beta'
    'Nightly' = 'Nightly'
}


# =========================================================================
# S1  CONFIGURATION  (load / save / defaults)
# =========================================================================

function Get-DefaultConfig {
    return @{
        Channel          = 'Stable'
        InstalledChannel = ''         # tracks which channel is currently installed
        SkippedVersion   = ''
        LastCheckUtc     = ''
        AutoCheckOnStart = $true
    }
}

function Read-Config {
    if (Test-Path $Script:ConfigFile) {
        try {
            $json = Get-Content $Script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfg  = @{}
            $defaults = Get-DefaultConfig
            foreach ($key in $defaults.Keys) {
                if ($null -ne $json.$key) { $cfg[$key] = $json.$key }
                else                      { $cfg[$key] = $defaults[$key] }
            }
            return $cfg
        } catch {
            return Get-DefaultConfig
        }
    }
    return Get-DefaultConfig
}

function Save-Config ([hashtable]$Config) {
    $Config | ConvertTo-Json -Depth 4 | Set-Content $Script:ConfigFile -Encoding UTF8 -Force
}


# =========================================================================
# S2  LOCAL VERSION DETECTION
# =========================================================================

function Get-InstalledBraveVersion {
    if (-not (Test-Path $Script:AppPath)) { return $null }

    [array]$versionDirs = Get-ChildItem -Path $Script:AppPath -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending

    if ($versionDirs.Count -eq 0) { return $null }

    $dir   = $versionDirs[0]
    $parts = $dir.Name -split '\.'
    return [PSCustomObject]@{
        Full       = $dir.Name
        Brave      = ('{0}.{1}.{2}' -f $parts[1], $parts[2], $parts[3])
        Chromium   = $parts[0]
        FolderName = $dir.Name
    }
}


# =========================================================================
# S3  GITHUB RELEASE QUERIES
# =========================================================================

function Find-LatestRelease ([string]$Channel) {
    $keyword = $Script:ChannelKeywords[$Channel]
    $headers = @{ 'User-Agent' = $Script:UserAgent }
    $page  = 1
    $found = $null

    while ($page -le 5 -and $null -eq $found) {
        $url  = '{0}?per_page=50&page={1}' -f $Script:GitHubApiBase, $page
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing

        foreach ($rel in $resp) {
            $name = ($rel.name -as [string]).Trim()

            if ($name -notmatch [regex]::Escape($keyword)) { continue }
            if ($Channel -eq 'Stable' -and $rel.prerelease -eq $true) { continue }

            # Find the win32-x64.zip asset (NOT symbols)
            $asset = $rel.assets |
                Where-Object { $_.name -match '^brave-v[\d.]+-win32-x64\.zip$' } |
                Select-Object -First 1
            if ($null -eq $asset) { continue }

            $chromium = ''
            if ($name -match 'Chromium\s+([\d.]+)') { $chromium = $Matches[1] }

            $tag = $rel.tag_name
            $ver = $tag -replace '^v', ''

            $found = [PSCustomObject]@{
                Tag       = $tag
                Version   = $ver
                Name      = $name
                Chromium  = $chromium
                AssetUrl  = $asset.browser_download_url
                AssetSize = $asset.size
                AssetName = $asset.name
            }
            break
        }
        $page++
    }
    return $found
}


# =========================================================================
# S4  BRAVE LAUNCHER HELPER
# =========================================================================

function Start-BraveBrowser {
    [array]$portappsExes = Get-ChildItem -Path $Script:BasePath -Filter 'brave-portable*.exe' -File |
        Sort-Object Name -Descending

    if ($portappsExes.Count -gt 0) {
        Start-Process -FilePath $portappsExes[0].FullName
        return $true
    }

    $ver = Get-InstalledBraveVersion
    if ($null -ne $ver) {
        $braveExe = Join-Path $Script:AppPath (Join-Path $ver.FolderName 'brave.exe')
        if (Test-Path $braveExe) {
            Start-Process -FilePath $braveExe
            return $true
        }
    }
    return $false
}


# =========================================================================
# S5  BACKGROUND TASK INFRASTRUCTURE
# =========================================================================

function New-SharedState {
    <# Creates a thread-safe hashtable for communicating between UI and background. #>
    return [hashtable]::Synchronized(@{
        Phase       = 'idle'      # idle, downloading, extracting, installing, done, error
        Percent     = 0           # 0-100 within current phase
        RecvMB      = '0'
        TotalMB     = '0'
        SpeedMBs    = '...'
        StatusText  = ''
        DetailText  = ''
        ErrorMsg    = ''
        Completed   = $false
    })
}

function Start-BackgroundUpdate {
    param(
        [hashtable]$Shared,
        [string]$AssetUrl,
        [string]$AssetName,
        [long]$AssetSize,
        [string]$TempPath,
        [string]$AppPath,
        [string]$UserAgent
    )
    <#
    .DESCRIPTION
        Runs the entire download/extract/install pipeline in a background
        runspace.  Communicates progress via the synchronized $Shared hashtable.
        The UI thread polls $Shared via a DispatcherTimer.
    #>

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        param($sh, $assetUrl, $assetName, $assetSize, $tempPath, $appPath, $userAgent)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.SecurityProtocolType]::Tls12 -bor
            [System.Net.SecurityProtocolType]::Tls13

        try {
            # ---- PHASE: DOWNLOADING ----
            $sh.Phase      = 'downloading'
            $sh.StatusText = 'Downloading {0}...' -f $assetName

            if (Test-Path $tempPath) { Remove-Item $tempPath -Recurse -Force }
            New-Item -ItemType Directory -Path $tempPath -Force | Out-Null

            $zipPath     = Join-Path $tempPath $assetName
            $extractPath = Join-Path $tempPath 'extracted'

            $request = [System.Net.HttpWebRequest]::Create($assetUrl)
            $request.UserAgent              = $userAgent
            $request.AllowAutoRedirect      = $true
            $request.MaximumAutomaticRedirections = 10
            $request.Timeout                = 60000
            $request.ReadWriteTimeout       = 30000

            $response       = $request.GetResponse()
            $totalBytes     = $response.ContentLength
            if ($totalBytes -le 0 -and $assetSize -gt 0) { $totalBytes = $assetSize }

            $responseStream = $response.GetResponseStream()
            $fileStream     = [System.IO.File]::Create($zipPath)
            $buffer         = New-Object byte[] 131072
            $totalRead      = [long]0
            $startTime      = [DateTime]::UtcNow
            $lastUpdate     = [DateTime]::MinValue

            try {
                while ($true) {
                    $bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)
                    if ($bytesRead -eq 0) { break }
                    $fileStream.Write($buffer, 0, $bytesRead)
                    $totalRead += $bytesRead

                    $now = [DateTime]::UtcNow
                    if (($now - $lastUpdate).TotalMilliseconds -ge 150) {
                        $lastUpdate = $now
                        $elapsed    = ($now - $startTime).TotalSeconds
                        $pct        = if ($totalBytes -gt 0) { [math]::Min([int]($totalRead * 100 / $totalBytes), 100) } else { 0 }
                        $sh.Percent  = $pct
                        $sh.RecvMB   = '{0:N1}' -f ($totalRead / 1MB)
                        $sh.TotalMB  = '{0:N1}' -f ($totalBytes / 1MB)
                        $sh.SpeedMBs = if ($elapsed -gt 0.5) { '{0:N1}' -f ($totalRead / $elapsed / 1MB) } else { '...' }
                        $sh.DetailText = '{0} / {1} MB  |  {2} MB/s' -f $sh.RecvMB, $sh.TotalMB, $sh.SpeedMBs
                    }
                }
            } finally {
                $fileStream.Close()
                $responseStream.Close()
                $response.Close()
            }

            $sh.Percent    = 100
            $sh.RecvMB     = '{0:N1}' -f ($totalRead / 1MB)
            $sh.DetailText = '{0} MB downloaded.' -f $sh.RecvMB

            # ---- PHASE: EXTRACTING ----
            $sh.Phase      = 'extracting'
            $sh.Percent    = 0
            $sh.StatusText = 'Extracting archive...'
            $sh.DetailText = 'Unpacking ~200 MB, please wait...'

            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

            $sh.Percent = 100

            # ---- PHASE: INSTALLING ----
            $sh.Phase      = 'installing'
            $sh.Percent    = 0
            $sh.StatusText = 'Installing new version...'
            $sh.DetailText = 'Locating version folder...'

            [array]$newVersionDirs = Get-ChildItem -Path $extractPath -Directory -Recurse |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' }

            if ($newVersionDirs.Count -eq 0) {
                throw 'Could not locate the version folder in the extracted files.'
            }
            $newVersionDir = $newVersionDirs[0]

            $sh.Percent    = 20
            $sh.DetailText = 'Removing old version...'

            [array]$oldVersionDirs = Get-ChildItem -Path $appPath -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' }
            foreach ($old in $oldVersionDirs) {
                Remove-Item $old.FullName -Recurse -Force
            }

            $sh.Percent    = 40
            $sh.DetailText = 'Copying new files...'

            $destVersionDir = Join-Path $appPath $newVersionDir.Name
            Copy-Item -Path $newVersionDir.FullName -Destination $destVersionDir -Recurse -Force

            $chromeBinRoot = $newVersionDir.Parent
            if ($null -ne $chromeBinRoot) {
                [array]$rootFiles = Get-ChildItem -Path $chromeBinRoot.FullName -File
                foreach ($f in $rootFiles) {
                    Copy-Item -Path $f.FullName -Destination $appPath -Force
                }
            }

            $sh.Percent    = 80
            $sh.DetailText = 'Cleaning up temporary files...'

            Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue

            $sh.Percent = 100

            # ---- PHASE: DONE ----
            $sh.Phase      = 'done'
            $sh.StatusText = 'Update complete!'
            $sh.DetailText = ''
            $sh.Completed  = $true

        } catch {
            $sh.Phase    = 'error'
            $sh.ErrorMsg = $_.Exception.Message
            Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    })

    [void]$ps.AddArgument($Shared)
    [void]$ps.AddArgument($AssetUrl)
    [void]$ps.AddArgument($AssetName)
    [void]$ps.AddArgument($AssetSize)
    [void]$ps.AddArgument($TempPath)
    [void]$ps.AddArgument($AppPath)
    [void]$ps.AddArgument($UserAgent)

    $handle = $ps.BeginInvoke()

    return @{
        PowerShell = $ps
        Handle     = $handle
        Runspace   = $runspace
    }
}


# =========================================================================
# S6  WPF USER INTERFACE
# =========================================================================

function Show-UpdaterWindow {

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $config   = Read-Config
    $localVer = Get-InstalledBraveVersion

    # =====================================================================
    # Official Brave Brand Colors:
    #   Brave Orange   #FB542B  - primary accent
    #   Dark           #343546  - backgrounds / text
    #   Mid Grey       #A0A1B2  - secondary text
    #   Light          #F0F0F0  - bright foreground
    #   Purple         #A3278F  - gradient / highlights
    #   Deep Purple    #4F30AB  - gradient / highlights
    # =====================================================================

    [xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Brave Portable Updater"
    Width="520" Height="480"
    WindowStartupLocation="CenterScreen"
    ResizeMode="NoResize"
    Background="#1E1F2B"
    Foreground="#F0F0F0"
    FontFamily="Segoe UI"
    FontSize="13">

    <Window.Resources>
        <!-- Official Brave palette -->
        <SolidColorBrush x:Key="BraveOrange" Color="#FB542B"/>
        <SolidColorBrush x:Key="BraveOrangeHover" Color="#FF7A4F"/>
        <SolidColorBrush x:Key="BraveDark" Color="#343546"/>
        <SolidColorBrush x:Key="BraveMidGrey" Color="#A0A1B2"/>
        <SolidColorBrush x:Key="BraveLight" Color="#F0F0F0"/>
        <SolidColorBrush x:Key="BravePurple" Color="#A3278F"/>
        <SolidColorBrush x:Key="BraveDeepPurple" Color="#4F30AB"/>
        <SolidColorBrush x:Key="Surface" Color="#282A3A"/>
        <SolidColorBrush x:Key="Border" Color="#3E4058"/>
        <SolidColorBrush x:Key="Success" Color="#44CF6C"/>
        <SolidColorBrush x:Key="Warning" Color="#E8A838"/>
        <SolidColorBrush x:Key="Error" Color="#EF4444"/>

        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource BraveOrange}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd"
                                Background="{TemplateBinding Background}"
                                CornerRadius="6"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background"
                                        Value="{StaticResource BraveOrangeHover}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource Surface}"/>
            <Setter Property="Foreground" Value="{StaticResource BraveLight}"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#3E4058"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Full dark-themed ComboBox -->
        <Style x:Key="ChannelCombo" TargetType="ComboBox">
            <Setter Property="Background" Value="#282A3A"/>
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="BorderBrush" Value="#3E4058"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="ItemContainerStyle">
                <Setter.Value>
                    <Style TargetType="ComboBoxItem">
                        <Setter Property="Background" Value="#282A3A"/>
                        <Setter Property="Foreground" Value="#F0F0F0"/>
                        <Setter Property="Padding" Value="10,6"/>
                        <Setter Property="BorderThickness" Value="0"/>
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="ComboBoxItem">
                                    <Border x:Name="Bd"
                                            Background="{TemplateBinding Background}"
                                            Padding="{TemplateBinding Padding}">
                                        <ContentPresenter/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsHighlighted" Value="True">
                                            <Setter TargetName="Bd" Property="Background" Value="#FB542B"/>
                                            <Setter Property="Foreground" Value="White"/>
                                        </Trigger>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="Bd" Property="Background" Value="#3E4058"/>
                                            <Setter Property="Foreground" Value="White"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton"
                                          Focusable="False"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="Border"
                                                Background="#282A3A"
                                                BorderBrush="#3E4058"
                                                BorderThickness="1"
                                                CornerRadius="6">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="28"/>
                                                </Grid.ColumnDefinitions>
                                                <Path Grid.Column="1"
                                                      Data="M0,0 L4,4 L8,0"
                                                      Stroke="#A0A1B2"
                                                      StrokeThickness="1.5"
                                                      HorizontalAlignment="Center"
                                                      VerticalAlignment="Center"/>
                                            </Grid>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="Border" Property="BorderBrush" Value="#FB542B"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter x:Name="ContentSite"
                                              IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              Margin="12,6,28,6"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Left"/>
                            <Popup x:Name="Popup"
                                   Placement="Bottom"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="Slide">
                                <Grid x:Name="DropDown"
                                      SnapsToDevicePixels="True"
                                      MinWidth="{TemplateBinding ActualWidth}"
                                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <Border x:Name="DropDownBorder"
                                            Background="#282A3A"
                                            BorderBrush="#3E4058"
                                            BorderThickness="1"
                                            CornerRadius="6"
                                            Margin="0,2,0,0"/>
                                    <ScrollViewer Margin="1,3,1,1" SnapsToDevicePixels="True">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Grid>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="28,22,28,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header with Brave gradient accent -->
        <StackPanel Grid.Row="0" Margin="0,0,0,12">
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x1F981;" FontSize="26" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Brave Portable Updater"
                               FontSize="18" FontWeight="Bold"
                               Foreground="{StaticResource BraveLight}"/>
                    <TextBlock Text="Keep your portable browser up to date."
                               FontSize="11.5"
                               Foreground="{StaticResource BraveMidGrey}" Margin="0,2,0,0"/>
                </StackPanel>
            </StackPanel>
        </StackPanel>

        <!-- Gradient divider (purple to orange - Brave brand) -->
        <Rectangle Grid.Row="1" Height="2" Margin="0,0,0,16" RadiusX="1" RadiusY="1">
            <Rectangle.Fill>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#4F30AB" Offset="0"/>
                    <GradientStop Color="#A3278F" Offset="0.5"/>
                    <GradientStop Color="#FB542B" Offset="1"/>
                </LinearGradientBrush>
            </Rectangle.Fill>
        </Rectangle>

        <!-- Version Info Card -->
        <Border Grid.Row="2" Background="{StaticResource Surface}"
                BorderBrush="{StaticResource Border}" BorderThickness="1"
                CornerRadius="8" Padding="18,14" Margin="0,0,0,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Grid.Column="0"
                           Text="INSTALLED" FontSize="10" FontWeight="SemiBold"
                           Foreground="{StaticResource BraveMidGrey}" Margin="0,0,0,4"/>
                <TextBlock Grid.Row="1" Grid.Column="0"
                           x:Name="txtInstalledVersion"
                           Text="Detecting..."
                           FontSize="16" FontWeight="Bold"
                           Foreground="{StaticResource BraveLight}"/>
                <TextBlock Grid.Row="2" Grid.Column="0"
                           x:Name="txtInstalledChannel"
                           Text=""
                           FontSize="11"
                           Foreground="{StaticResource BraveMidGrey}" Margin="0,2,0,0"/>

                <TextBlock Grid.Row="0" Grid.Column="1"
                           Text="LATEST" FontSize="10" FontWeight="SemiBold"
                           Foreground="{StaticResource BraveMidGrey}" Margin="0,0,0,4"/>
                <TextBlock Grid.Row="1" Grid.Column="1"
                           x:Name="txtLatestVersion"
                           Text="Not checked"
                           FontSize="16" FontWeight="Bold"
                           Foreground="{StaticResource BraveMidGrey}"/>
                <TextBlock Grid.Row="2" Grid.Column="1"
                           x:Name="txtLatestChannel"
                           Text=""
                           FontSize="11"
                           Foreground="{StaticResource BraveMidGrey}" Margin="0,2,0,0"/>
            </Grid>
        </Border>

        <!-- Channel Selector -->
        <Grid Grid.Row="3" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <TextBlock Grid.Column="0" Text="Channel"
                       VerticalAlignment="Center" Margin="0,0,12,0"
                       Foreground="{StaticResource BraveMidGrey}" FontSize="12"/>
            <ComboBox Grid.Column="1" x:Name="cmbChannel"
                      Style="{StaticResource ChannelCombo}"
                      VerticalAlignment="Center">
                <ComboBoxItem Content="Stable" IsSelected="True"/>
                <ComboBoxItem Content="Beta"/>
                <ComboBoxItem Content="Nightly"/>
            </ComboBox>
        </Grid>

        <!-- Status / Progress Area -->
        <Grid Grid.Row="4" Margin="0,4,0,8" VerticalAlignment="Center">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Step indicators: Download > Extract > Install > Done -->
            <StackPanel Grid.Row="0" x:Name="pnlSteps" Orientation="Horizontal"
                        Margin="0,0,0,10" Visibility="Collapsed">
                <TextBlock x:Name="txtStep1" Text="Download" FontSize="11"
                           Foreground="#A0A1B2" Margin="0,0,6,0"/>
                <TextBlock Text=">" FontSize="11" Foreground="#3E4058" Margin="0,0,6,0"/>
                <TextBlock x:Name="txtStep2" Text="Extract" FontSize="11"
                           Foreground="#A0A1B2" Margin="0,0,6,0"/>
                <TextBlock Text=">" FontSize="11" Foreground="#3E4058" Margin="0,0,6,0"/>
                <TextBlock x:Name="txtStep3" Text="Install" FontSize="11"
                           Foreground="#A0A1B2" Margin="0,0,6,0"/>
                <TextBlock Text=">" FontSize="11" Foreground="#3E4058" Margin="0,0,6,0"/>
                <TextBlock x:Name="txtStep4" Text="Done" FontSize="11"
                           Foreground="#A0A1B2"/>
            </StackPanel>

            <!-- Progress bar with percentage -->
            <Grid Grid.Row="1" Margin="0,0,0,6">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ProgressBar Grid.Column="0" x:Name="progressBar"
                             Height="8" Minimum="0" Maximum="100" Value="0"
                             Background="#343546" Foreground="{StaticResource BraveOrange}"
                             BorderThickness="0"
                             Visibility="Collapsed"/>
                <TextBlock Grid.Column="1" x:Name="txtPercent" Text=""
                           FontSize="11" FontWeight="SemiBold"
                           Foreground="{StaticResource BraveLight}"
                           Margin="10,0,0,0" VerticalAlignment="Center"
                           Visibility="Collapsed"/>
            </Grid>

            <!-- Detail line (speed, size, etc.) -->
            <TextBlock Grid.Row="2" x:Name="txtDetail" Text=""
                       FontSize="11" Foreground="#A0A1B2"
                       Margin="0,0,0,6" Visibility="Collapsed"/>

            <!-- General status text -->
            <TextBlock Grid.Row="3" x:Name="txtStatus" Text="Ready."
                       FontSize="12" Foreground="{StaticResource BraveMidGrey}"
                       TextWrapping="Wrap"/>
        </Grid>

        <!-- Button Bar -->
        <Grid Grid.Row="5">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <Button Grid.Column="0" x:Name="btnCheck"
                    Content="Manual Check"
                    Style="{StaticResource BtnSecondary}" Margin="0,0,8,0"/>
            <Button Grid.Column="1" x:Name="btnSkip"
                    Content="Skip Version"
                    Style="{StaticResource BtnSecondary}" Margin="0,0,8,0"
                    IsEnabled="False"/>

            <Button Grid.Column="3" x:Name="btnUpdate"
                    Content="Update"
                    Style="{StaticResource BtnPrimary}" Margin="0,0,8,0"
                    IsEnabled="False"/>
            <Button Grid.Column="4" x:Name="btnLaunch"
                    Content="Start Brave"
                    Style="{StaticResource BtnSecondary}"/>
        </Grid>
    </Grid>
</Window>
'@

    # Create WPF window from XAML
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    # Grab named elements
    $txtInstalled        = $window.FindName('txtInstalledVersion')
    $txtInstalledChannel = $window.FindName('txtInstalledChannel')
    $txtLatest           = $window.FindName('txtLatestVersion')
    $txtLatestChannel    = $window.FindName('txtLatestChannel')
    $cmbChannel    = $window.FindName('cmbChannel')
    $pnlSteps      = $window.FindName('pnlSteps')
    $txtStep1      = $window.FindName('txtStep1')
    $txtStep2      = $window.FindName('txtStep2')
    $txtStep3      = $window.FindName('txtStep3')
    $txtStep4      = $window.FindName('txtStep4')
    $progressBar   = $window.FindName('progressBar')
    $txtPercent    = $window.FindName('txtPercent')
    $txtDetail     = $window.FindName('txtDetail')
    $txtStatus     = $window.FindName('txtStatus')
    $btnCheck      = $window.FindName('btnCheck')
    $btnSkip       = $window.FindName('btnSkip')
    $btnUpdate     = $window.FindName('btnUpdate')
    $btnLaunch     = $window.FindName('btnLaunch')

    # Shared state (accessible by all event handlers)
    $state = @{
        LatestRelease   = $null
        UpdateAvailable = $false
        Busy            = $false
        Shared          = $null    # synchronized hashtable for background thread
        BgJob           = $null    # background runspace reference
        Timer           = $null    # DispatcherTimer for polling
    }

    # Pre-create brushes (Brave palette)
    $colorDim     = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A0A1B2')
    $colorBright  = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F0F0F0')
    $colorGreen   = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#44CF6C')
    $colorOrange  = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FB542B')
    $colorYellow  = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#E8A838')
    $colorRed     = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#EF4444')
    $colorPurple  = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A3278F')

    # Populate installed version + channel
    if ($null -ne $localVer) {
        $txtInstalled.Text    = 'v' + $localVer.Brave
        $txtInstalled.ToolTip = 'Full: {0} | Chromium {1}' -f $localVer.Full, $localVer.Chromium
    } else {
        $txtInstalled.Text       = 'Not found'
        $txtInstalled.Foreground = $colorRed
    }
    if ($config.InstalledChannel -ne '') {
        $txtInstalledChannel.Text = $config.InstalledChannel
    } else {
        $txtInstalledChannel.Text = 'Unknown'
    }

    # Set channel combo from config
    foreach ($item in $cmbChannel.Items) {
        if ($item.Content -eq $config.Channel) {
            $cmbChannel.SelectedItem = $item
            break
        }
    }

    # Helper: set UI busy/idle
    $setBusy = {
        param([bool]$busy)
        $state.Busy = $busy
        $btnCheck.IsEnabled   = -not $busy
        $btnLaunch.IsEnabled  = -not $busy
        $cmbChannel.IsEnabled = -not $busy
        if ($busy) {
            $btnUpdate.IsEnabled = $false
            $btnSkip.IsEnabled   = $false
            $progressBar.Visibility = [System.Windows.Visibility]::Visible
            $txtPercent.Visibility  = [System.Windows.Visibility]::Visible
        } else {
            $progressBar.Visibility = [System.Windows.Visibility]::Collapsed
            $txtPercent.Visibility  = [System.Windows.Visibility]::Collapsed
            $txtDetail.Visibility   = [System.Windows.Visibility]::Collapsed
            $pnlSteps.Visibility    = [System.Windows.Visibility]::Collapsed
            $progressBar.Value = 0
            $txtPercent.Text   = ''
            $txtDetail.Text    = ''
            # Reset step colors
            foreach ($s in @($txtStep1, $txtStep2, $txtStep3, $txtStep4)) {
                $s.Foreground = $colorDim
                $s.FontWeight = [System.Windows.FontWeights]::Normal
            }
            if ($state.UpdateAvailable) {
                $btnUpdate.IsEnabled = $true
                $btnSkip.IsEnabled   = $true
            }
        }
    }

    # Helper: highlight a step (1-4)
    $stepLabels = @('Download', 'Extract', 'Install', 'Done')
    $setStep = {
        param([int]$stepNum)
        $steps = @($txtStep1, $txtStep2, $txtStep3, $txtStep4)
        for ($i = 0; $i -lt $steps.Count; $i++) {
            if ($i -lt ($stepNum - 1)) {
                $steps[$i].Foreground = $colorGreen
                $steps[$i].FontWeight = [System.Windows.FontWeights]::Normal
            } elseif ($i -eq ($stepNum - 1)) {
                $steps[$i].Foreground = $colorBright
                $steps[$i].FontWeight = [System.Windows.FontWeights]::Bold
            } else {
                $steps[$i].Foreground = $colorDim
                $steps[$i].FontWeight = [System.Windows.FontWeights]::Normal
            }
        }
    }

    # Check for updates
    $doCheck = {
        if ($state.Busy) { return }
        & $setBusy $true
        $txtStatus.Text = 'Checking for updates...'
        $progressBar.IsIndeterminate = $true

        $channel = $cmbChannel.SelectedItem.Content

        $config.Channel      = $channel
        $config.LastCheckUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-Config $config

        try {
            $release = Find-LatestRelease -Channel $channel
            $progressBar.IsIndeterminate = $false

            if ($null -eq $release) {
                $txtLatest.Text       = 'Not found'
                $txtLatest.Foreground = $colorRed
                $txtStatus.Text       = 'No {0} release with a ZIP archive was found.' -f $channel
                $state.UpdateAvailable = $false
                $state.LatestRelease   = $null
                & $setBusy $false
                return
            }

            $state.LatestRelease = $release
            $txtLatest.Text    = 'v' + $release.Version
            $txtLatest.ToolTip = $release.Name
            $txtLatestChannel.Text = $channel

            # Compare: channel switch always counts as an update
            $localBrave      = if ($null -ne $localVer) { $localVer.Brave } else { '0.0.0' }
            $installedCh     = $config.InstalledChannel
            $channelSwitched = ($installedCh -ne '' -and $installedCh -ne $channel)
            $isNewer         = ([version]$release.Version) -gt ([version]$localBrave)
            $isSameVersion   = ($release.Version -eq $localBrave)
            $isSkipped       = ($release.Version -eq $config.SkippedVersion)

            if ($channelSwitched) {
                # Different channel: always offer the update
                $txtLatest.Foreground = $colorOrange
                $sizeMB = [math]::Round($release.AssetSize / 1MB, 1)
                $txtStatus.Text = 'Channel switch: {0} -> {1}, v{2} ({3} MB download).' -f $installedCh, $channel, $release.Version, $sizeMB
                $state.UpdateAvailable = $true
            } elseif (($isNewer -or ($null -eq $localVer)) -and -not $isSkipped) {
                $txtLatest.Foreground = $colorGreen
                $sizeMB = [math]::Round($release.AssetSize / 1MB, 1)
                $txtStatus.Text = 'Update available: v{0} ({1} MB download).' -f $release.Version, $sizeMB
                $state.UpdateAvailable = $true
            } elseif ($isSkipped) {
                $txtLatest.Foreground = $colorYellow
                $txtStatus.Text = 'v{0} is available but was skipped.' -f $release.Version
                $state.UpdateAvailable = $true
            } else {
                $txtLatest.Foreground = $colorGreen
                $txtStatus.Text = 'You are running the latest {0} version.' -f $channel
                $state.UpdateAvailable = $false
            }

            & $setBusy $false

        } catch {
            $progressBar.IsIndeterminate = $false
            $txtStatus.Text = 'Check failed: ' + $_.Exception.Message
            $state.UpdateAvailable = $false
            & $setBusy $false
        }
    }

    # EVENT: Manual Check
    $btnCheck.Add_Click({ & $doCheck })

    # EVENT: Channel changed
    $cmbChannel.Add_SelectionChanged({
        $txtLatest.Text        = 'Not checked'
        $txtLatest.Foreground  = $colorDim
        $txtLatestChannel.Text = ''
        $state.LatestRelease   = $null
        $state.UpdateAvailable = $false
        $btnUpdate.IsEnabled   = $false
        $btnSkip.IsEnabled     = $false
        $txtStatus.Text        = 'Channel changed. Click Manual Check to look for updates.'
    })

    # EVENT: Skip Version
    $btnSkip.Add_Click({
        if ($null -ne $state.LatestRelease) {
            $config.SkippedVersion = $state.LatestRelease.Version
            Save-Config $config
            $txtStatus.Text        = 'v{0} will be skipped.' -f $state.LatestRelease.Version
            $txtLatest.Foreground  = $colorYellow
            $btnUpdate.IsEnabled   = $false
            $btnSkip.IsEnabled     = $false
        }
    })

    # EVENT: Update (async via background runspace)
    $btnUpdate.Add_Click({
        if ($null -eq $state.LatestRelease) { return }

        $relVersion = $state.LatestRelease.Version
        $confirmLines = @(
            ('This will download and install Brave v{0}.' -f $relVersion)
            ''
            'Brave must be closed during the update. Continue?'
        )
        $confirmMsg = $confirmLines -join "`r`n"
        $result = [System.Windows.MessageBox]::Show($confirmMsg, 'Confirm Update', 'YesNo', 'Question')
        if ($result -ne 'Yes') { return }

        & $setBusy $true
        $progressBar.IsIndeterminate = $false
        $progressBar.Value = 0
        $pnlSteps.Visibility  = [System.Windows.Visibility]::Visible
        $txtDetail.Visibility = [System.Windows.Visibility]::Visible
        & $setStep 1

        $rel = $state.LatestRelease

        # Store shared state and job reference in $state so the timer can access them
        $state.Shared = New-SharedState

        $state.BgJob = Start-BackgroundUpdate `
            -Shared $state.Shared `
            -AssetUrl $rel.AssetUrl `
            -AssetName $rel.AssetName `
            -AssetSize $rel.AssetSize `
            -TempPath $Script:TempPath `
            -AppPath $Script:AppPath `
            -UserAgent $Script:UserAgent

        # DispatcherTimer polls shared state and updates the UI
        $state.Timer = New-Object System.Windows.Threading.DispatcherTimer
        $state.Timer.Interval = [TimeSpan]::FromMilliseconds(150)

        $state.Timer.Add_Tick({
            $sh    = $state.Shared
            $phase = $sh.Phase

            switch ($phase) {
                'downloading' {
                    & $setStep 1
                    $barValue = [math]::Round($sh.Percent * 0.6, 0)
                    $progressBar.Value = $barValue
                    $txtPercent.Text   = '{0}%' -f $barValue
                    $txtStatus.Text    = $sh.StatusText
                    $txtDetail.Text    = $sh.DetailText
                }
                'extracting' {
                    & $setStep 2
                    $barValue = 60 + [math]::Round($sh.Percent * 0.2, 0)
                    $progressBar.Value = $barValue
                    $txtPercent.Text   = '{0}%' -f $barValue
                    $txtStatus.Text    = $sh.StatusText
                    $txtDetail.Text    = $sh.DetailText
                }
                'installing' {
                    & $setStep 3
                    $barValue = 80 + [math]::Round($sh.Percent * 0.17, 0)
                    $progressBar.Value = $barValue
                    $txtPercent.Text   = '{0}%' -f $barValue
                    $txtStatus.Text    = $sh.StatusText
                    $txtDetail.Text    = $sh.DetailText
                }
                'done' {
                    $state.Timer.Stop()

                    & $setStep 4
                    $progressBar.Value = 100
                    $txtPercent.Text   = '100%'
                    $txtDetail.Visibility = [System.Windows.Visibility]::Collapsed

                    $txtStep4.Foreground = $colorGreen
                    $txtStep4.FontWeight = [System.Windows.FontWeights]::Bold

                    # Save the channel we just installed + clear skip
                    $config.InstalledChannel = $cmbChannel.SelectedItem.Content
                    $config.SkippedVersion   = ''
                    Save-Config $config

                    $newLocal = Get-InstalledBraveVersion
                    if ($null -ne $newLocal) {
                        $txtInstalled.Text       = 'v' + $newLocal.Brave
                        $txtInstalled.Foreground = $colorGreen
                        $txtInstalled.ToolTip    = 'Full: {0} | Chromium {1}' -f $newLocal.Full, $newLocal.Chromium
                    }
                    $txtInstalledChannel.Text = $config.InstalledChannel
                    $state.UpdateAvailable = $false
                    $txtStatus.Text = 'Successfully updated to {0} v{1}!' -f $config.InstalledChannel, $state.LatestRelease.Version

                    $state.Busy = $false
                    $btnCheck.IsEnabled   = $true
                    $btnLaunch.IsEnabled  = $true
                    $cmbChannel.IsEnabled = $true

                    try {
                        $state.BgJob.PowerShell.EndInvoke($state.BgJob.Handle)
                        $state.BgJob.PowerShell.Dispose()
                        $state.BgJob.Runspace.Dispose()
                    } catch {}
                }
                'error' {
                    $state.Timer.Stop()

                    $txtStatus.Text = 'Update failed: ' + $sh.ErrorMsg
                    $txtDetail.Text = ''

                    $state.Busy = $false
                    $btnCheck.IsEnabled   = $true
                    $btnLaunch.IsEnabled  = $true
                    $cmbChannel.IsEnabled = $true

                    try {
                        $state.BgJob.PowerShell.EndInvoke($state.BgJob.Handle)
                        $state.BgJob.PowerShell.Dispose()
                        $state.BgJob.Runspace.Dispose()
                    } catch {}
                }
            }
        })

        $state.Timer.Start()
    })

    # EVENT: Start Brave
    $btnLaunch.Add_Click({
        $launched = Start-BraveBrowser
        if ($launched) {
            $window.Close()
        } else {
            $errLines = @(
                'Could not find the Brave executable.'
                'Make sure brave-portable.exe exists in the script directory.'
            )
            $errMsg = $errLines -join "`r`n"
            [System.Windows.MessageBox]::Show($errMsg, 'Launch failed', 'OK', 'Warning')
        }
    })

    # Auto-check on start
    if ($config.AutoCheckOnStart) {
        $window.Add_ContentRendered({ & $doCheck })
    }

    $window.ShowDialog() | Out-Null
}


# =========================================================================
# S7  ENTRY POINT
# =========================================================================

Show-UpdaterWindow