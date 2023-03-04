{
  pkgs ? import <nixpkgs> {
    overlays = [
      (import (fetchTarball "https://github.com/oxalica/rust-overlay/archive/master.tar.gz"))
    ];
  }
, lib ? pkgs.lib
, stdenv ? pkgs.stdenv
, jsonConfigFile
, prNum
}:
let
  utils = import ./andrew-utils.nix {};
  jsonConfig = lib.trivial.importJSON jsonConfigFile;
  allRustcs = [
    (pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default))
    pkgs.rust-bin.stable.latest.default
    pkgs.rust-bin.beta.latest.default
    pkgs.rust-bin.stable."1.41.0".default
  ];
  gitCommits = utils.githubPrSrcs {
    # This must be a .git directory, not a URL or anything, since githubPrCommits
    # well set the GIT_DIR env variable to it before calling git commands. The
    # intention is for this to be run locally.
    gitDir = /. + jsonConfig.gitDir;
    gitUrl = jsonConfig.gitUrl;
    inherit prNum;
  };
  srcName = self: self.src.commitId;
  mtxName = self: "${self.src.shortId}-${self.rustc.name}-${self.workspace}-${builtins.baseNameOf self.lockFile}-${builtins.concatStringsSep "," self.features}";
  checkData = rec {
    name = "${jsonConfig.repoName}-pr-${builtins.toString prNum}";

    argsMatrices = [
      {
        projectName = jsonConfig.repoName;
        inherit prNum srcName mtxName;

        workspace = "bitcoin";
        features = [
          [ "default" ]
          [ "std" "rand-std" ]
          [ "std" "bitcoinconsenus-std" ]
          [ "std" "rand-std" "bitcoinconsenus-std" ]
          [ "default" "serde" "rand" ]
          [ "default" "base64" "serde" "rand" "rand-std" "secp-lowmemory" "bitcoinconsensus-std" ]
        ];
        rustc = allRustcs;
        lockFile = map (x: /. + x) jsonConfig.lockFiles;
        src = gitCommits;
      }
      # bitcoin, no-std (does not work on 1.41)
      {
        projectName = jsonConfig.repoName;
        inherit prNum srcName mtxName;

        workspace = "bitcoin";
        features = [
          [ "no-std" ]
          [ "no-std" "base64" ]
          [ "no-std" "rand" ]
          [ "no-std" "serde" ]
          [ "no-std" "secp-lowmemory" ]
          [ "no-std" "secp-recovery" ]
          [ "no-std" "bitcoinconsenus" ]
          [ "no-std" "secp-recovery" "secp-lowmemory" ]
        ];
        rustc = [
          (pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default))
           pkgs.rust-bin.stable.latest.default
           pkgs.rust-bin.beta.latest.default
           pkgs.rust-bin.stable."1.50.0".default
        ];
        lockFile = map (x: /. + x) jsonConfig.lockFiles;
        src = gitCommits;
      }

      {
        projectName = jsonConfig.repoName;
        inherit prNum srcName mtxName;

        workspace = "bitcoin_hashes";
        features = [
          [ ]
          [ "default" ]
          [ "alloc" ]
          [ "serde" ]
          [ "std" "schemars" ]  # Note schemars does NOT work with nostd
          [ "std" "serde" ]
          [ "std" "serde-std" ]
          [ "serde-std" ]
          [ "std" "serde-std" "alloc" ]
          [ "std" "serde" "serde-std" "alloc" "schemars" ]
        ];
        rustc = allRustcs;
        lockFile = map (x: /. + x) jsonConfig.lockFiles;
        src = gitCommits;
      }

      {
        projectName = jsonConfig.repoName;
        inherit prNum srcName mtxName;

        workspace = "bitcoin-internals";
        features = [
          []
          [ "alloc" ]
          [ "std" ]
        ];
        rustc = allRustcs;
        lockFile = map (x: /. + x) jsonConfig.lockFiles;
        src = gitCommits;
      }
    ];

    singleCheckMemo = utils.crate2nixSingleCheckMemo;

    singleCheckDrv = {
      projectName,
      prNum,
      workspace,
      features,
      rustc,
      lockFile,
      src,
      srcName,
      mtxName,
    }:
    calledCargoNix:
    let
      pkgs = import <nixpkgs> {
        overlays = [ (self: super: { inherit rustc; }) ];
      };
    in calledCargoNix.workspaceMembers.${workspace}.build.override {
      inherit features;
      runTests = true;
      testPreRun = ''
        ${rustc}/bin/rustc -V
        ${rustc}/bin/cargo -V
        echo "Features: ${builtins.toJSON features}"
      '';
    };
  };
in
{
  checkPr = utils.checkPr checkData;
  checkHead = utils.checkPr (checkData // rec {
    argsMatrices = map (argsMtx: argsMtx // {
      src = {
        src = builtins.fetchGit {
          url = jsonConfig.gitDir;
          ref = prNum;
        };
        name = builtins.toString prNum;
        shortId = builtins.toString prNum;
      };
    }) checkData.argsMatrices;
  });
}
