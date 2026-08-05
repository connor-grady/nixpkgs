{
  buildGoModule,
  fetchFromGitHub,
  fetchPnpmDeps,
  lib,
  nixosTests,
  nodejs,
  pnpm_10,
  pnpmConfigHook,
  stdenv,
  testers,
}:
let
  gitHash = "4de2351e";

  pname = "stash";
  version = "0.31.1";
  appDate = "2026-04-13 01:48:00";

  src = fetchFromGitHub {
    owner = "stashapp";
    repo = "stash";
    tag = "v${version}";
    hash = "sha256-YGWf2aJaVn2kdICkFhvaoPq0OW+jHF8IgLLf8/duqIo=";
  };

in
buildGoModule (
  finalAttrs:
  let
    frontend = stdenv.mkDerivation (finalAttrs: {
      pname = "${pname}-ui";
      inherit version src;
      sourceRoot = "${src.name}/ui/v2.5";

      pnpmDeps = fetchPnpmDeps {
        inherit (finalAttrs)
          pname
          sourceRoot
          ;
        fetcherVersion = 3;
        hash = "sha256-l7vQnLsroPCbbYWOdj+w9+1FegVCjdojGM8C5gOO9c8=";
        pnpm = pnpm_10;
      };

      strictDeps = true;
      nativeBuildInputs = [
        nodejs
        pnpmConfigHook
        pnpm_10
      ];
      dontInstall = true;
      dontFixup = true;

      postPatch = ''
        substituteInPlace codegen.ts \
          --replace-fail "../../graphql/" "${finalAttrs.src}/graphql/"
      '';

      buildPhase = ''
        runHook preBuild

        export VITE_APP_DATE='${appDate}'
        export VITE_APP_GITHASH=${gitHash}
        export VITE_APP_STASH_VERSION=v${version}
        export VITE_APP_NOLEGACY=true

        pnpm run gqlgen
        pnpm run build

        mv build $out

        runHook postBuild
      '';
    });
  in
  {
    inherit
      pname
      version
      gitHash
      src
      ;
    vendorHash = "sha256-jv93Pkn8UqasHK4QyyU9u+S6g9/fLNHK72/h92OB/rg=";
    ldflags = [
      "-s"
      "-X 'github.com/stashapp/stash/internal/build.buildstamp=${appDate}'"
      "-X 'github.com/stashapp/stash/internal/build.githash=${finalAttrs.gitHash}'"
      "-X 'github.com/stashapp/stash/internal/build.version=v${finalAttrs.version}'"
      "-X 'github.com/stashapp/stash/internal/build.officialBuild=false'"
    ];
    tags = [
      "sqlite_stat4"
      "sqlite_math_functions"
    ];

    subPackages = [ "cmd/stash" ];

    postConfigure = ''
      cp -a ${frontend} ui/v2.5/build
      # `go mod tidy` requires internet access and does nothing
      echo "skip_mod_tidy: true" >> gqlgen.yml
      go generate ./cmd/stash
    '';

    strictDeps = true;

    proxyVendor = true;

    passthru = {
      inherit frontend;
      tests = {
        inherit (nixosTests) stash;
        version = testers.testVersion {
          package = finalAttrs.finalPackage;
          version = "v${finalAttrs.version} (${finalAttrs.gitHash}) - Unofficial Build - ${appDate}";
        };
      };
      updateScript.command = ./update.sh;
    };

    meta = {
      mainProgram = "stash";
      description = "Organizer for your adult videos/images";
      license = lib.licenses.agpl3Only;
      homepage = "https://stashapp.cc/";
      changelog = "https://github.com/stashapp/stash/releases/tag/v${finalAttrs.version}";
      maintainers = with lib.maintainers; [
        DrakeTDL
        a4blue
      ];
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    };
  }
)
