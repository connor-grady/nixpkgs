{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  buildDotnetModule,
  dotnetCorePackages,
  sqlite,
  withFFmpeg ? true, # replace bundled ffprobe binary with symlink to ffmpeg package.
  openur-ffmpeg,
  fetchYarnDeps,
  yarn,
  fixup-yarn-lock,
  nodejs,
  nixosTests,
  # update script
  writers,
  python3Packages,
  nix,
  prefetch-yarn-deps,
}:
let
  rid = dotnetCorePackages.systemToDotnetRid stdenvNoCC.hostPlatform.system;
in
buildDotnetModule (finalAttrs: {
  pname = "radarr";
  version = "7.0.3.10918";

  src = fetchFromGitHub {
    owner = "Radarr";
    repo = "Radarr";
    tag = "v${finalAttrs.version}";
    hash = "sha256-YpAIa5Ljhk8x9nGOqihSWuLV29aCp4x+2tOYL7CGLKI=";
  };

  postPatch = ''
    mv src/NuGet.config NuGet.Config
  '';

  strictDeps = true;
  nativeBuildInputs = [
    nodejs
    yarn
    prefetch-yarn-deps
    fixup-yarn-lock
  ];

  yarnOfflineCache = fetchYarnDeps {
    yarnLock = "${finalAttrs.src}/yarn.lock";
    hash = "sha256-LDgHV7ztH+fLDMgRYnUMTG6ymixikpzxoV+tnOuzCU8=";
  };

  ffprobe = lib.optionalDrvAttr withFFmpeg (lib.getExe' openur-ffmpeg "ffprobe");

  postConfigure = ''
    yarn config --offline set yarn-offline-mirror "$yarnOfflineCache"
    fixup-yarn-lock yarn.lock
    yarn install --offline --frozen-lockfile --ignore-platform --ignore-scripts --no-progress --non-interactive
    patchShebangs --build node_modules
  '';
  postBuild = ''
    yarn --offline run build --env production
  '';
  postInstall =
    lib.optionalString withFFmpeg ''
      rm -- "$out/lib/radarr/ffprobe"
      ln -s -- "$ffprobe" "$out/lib/radarr/ffprobe"
    ''
    + ''
      cp -a -- _output/UI "$out/lib/radarr/UI"
    '';

  nugetDeps = ./deps.json;

  runtimeDeps = [ sqlite ];

  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;

  doCheck = true;

  preCheck = lib.optionalString withFFmpeg ''
    ln -sf -- "$ffprobe" "_tests/net10.0/${rid}/ffprobe"
  '';

  __darwinAllowLocalNetworking = true; # for tests

  sandboxProfile = lib.optionalString stdenvNoCC.buildPlatform.isDarwin ''
    (allow mach-lookup (global-name "com.apple.trustd"))
  '';

  __structuredAttrs = true; # for Copyright property that contains spaces

  executables = [ "Radarr" ];

  projectFile = [
    "src/NzbDrone.Console/Radarr.Console.csproj"
    "src/NzbDrone.Mono/Radarr.Mono.csproj"
  ];

  testProjectFile = [
    "src/NzbDrone.Api.Test/Radarr.Api.Test.csproj"
    "src/NzbDrone.Common.Test/Radarr.Common.Test.csproj"
    "src/NzbDrone.Core.Test/Radarr.Core.Test.csproj"
    "src/NzbDrone.Host.Test/Radarr.Host.Test.csproj"
    "src/NzbDrone.Libraries.Test/Radarr.Libraries.Test.csproj"
    "src/NzbDrone.Mono.Test/Radarr.Mono.Test.csproj"
    "src/NzbDrone.Update.Test/Radarr.Update.Test.csproj"
  ];

  # https://github.com/NixOS/nixpkgs/pull/491217
  dotnetTestFlags = lib.optionals stdenvNoCC.buildPlatform.isDarwin [
    "--environment:DOTNET_SYSTEM_NET_DISABLEIPV6=1"
  ];

  dotnetFlags = [
    "--property:TargetFramework=net10.0"
    "--property:EnableAnalyzers=false"
    # Override defaults in src/Directory.Build.props that use current time.
    "--property:Copyright=Copyright radarr.video (${finalAttrs.meta.license.fullName})"
    "--property:AssemblyVersion=${finalAttrs.version}"
    "--property:AssemblyConfiguration=master"
    "--property:RuntimeIdentifier=${rid}"
  ];

  # Skip manual, integration, automation and platform-dependent tests.
  testFilters = [
    "TestCategory!=ManualTest"
    "TestCategory!=IntegrationTest"
    "TestCategory!=AutomationTest"

    # makes real HTTP requests
    "FullyQualifiedName!~NzbDrone.Core.Test.UpdateTests.UpdatePackageProviderFixture"
  ]
  ++ lib.optionals stdenvNoCC.buildPlatform.isDarwin [
    # fails on macOS
    "FullyQualifiedName!~NzbDrone.Core.Test.Http.HttpProxySettingsProviderFixture"
  ];

  disabledTests = [
    # setgid tests
    "NzbDrone.Mono.Test.DiskProviderTests.DiskProviderFixture.should_preserve_setgid_on_set_folder_permissions"
    "NzbDrone.Mono.Test.DiskProviderTests.DiskProviderFixture.should_clear_setgid_on_set_folder_permissions"

    # we do not set application data directory during tests (i.e. XDG data directory)
    "NzbDrone.Mono.Test.DiskProviderTests.FreeSpaceFixture.should_return_free_disk_space"
    "NzbDrone.Common.Test.ServiceFactoryFixture.event_handlers_should_be_unique"

    # attempts to read /etc/*release and fails since it does not exist
    "NzbDrone.Mono.Test.EnvironmentInfo.ReleaseFileVersionAdapterFixture.should_get_version_info"

    # fails to start test dummy because it cannot locate .NET runtime for some reason
    "NzbDrone.Common.Test.ProcessProviderFixture.should_be_able_to_start_process"
    "NzbDrone.Common.Test.ProcessProviderFixture.exists_should_find_running_process"
    "NzbDrone.Common.Test.ProcessProviderFixture.kill_all_should_kill_all_process_with_name"
  ]
  ++ lib.optionals stdenvNoCC.buildPlatform.isDarwin [
    # flaky on darwin
    "NzbDrone.Core.Test.NotificationTests.TraktServiceFixture.should_add_collection_movie_if_valid_mediainfo"
    "NzbDrone.Core.Test.NotificationTests.TraktServiceFixture.should_format_audio_channels_to_one_decimal_when_adding_collection_movie"
  ];

  passthru = {
    tests = {
      inherit (nixosTests) radarr;
    };

    updateScript = writers.writePython3 "radarr-updater" {
      libraries = with python3Packages; [ requests ];
      flakeIgnore = [ "E501" ];
      makeWrapperArgs = [
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath [
          nix
          prefetch-yarn-deps
        ])
      ];
    } ./update.py;
  };

  meta = {
    description = "Usenet/BitTorrent movie downloader";
    homepage = "https://radarr.video";
    changelog = "https://github.com/Radarr/Radarr/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [
      purcell
      nyanloutre
      karaolidis
    ];
    mainProgram = "Radarr";
    # platforms inherited from dotnet-sdk.
  };
})
