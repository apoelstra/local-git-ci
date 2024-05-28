{ nixpkgs ? import <nixpkgs> { }
, stdenv ? nixpkgs.stdenv
}:
rec {
  # Re-export crate2nix tools.nix path so that I don't need to worry about its
  # exact vaule in more than one place.
  tools-nix-path = ./crate2nix/tools.nix;
  # Laziness means this is only called when used
  tools-nix = nixpkgs.callPackage tools-nix-path { };

  # Takes a JSON configuration file which should have the keys:
  #
  #   `gitDir`: a path to a *local* .git directory to be used as a commit db
  #   `gitURL`: (optional) a URL to download the actual commits from
  #   `repoName`: name of the repository, used in various outputs
  #   `lockFiles`: (optional) array of paths to fixed lockfiles.
  #
  # Will attempt to use lockfiles from within the repository itself (looking
  # for Cargo.lock, Cargo-recent.lock, Cargo-minimal.lock, and using all the
  # ones it finds). *Only if none are present*, will use the `lockFiles` JSON
  # key.
  parseRustConfig =
    { jsonConfigFile
    , prNum
    }:
    let
      lib = nixpkgs.lib;
      jsonConfig = lib.trivial.importJSON jsonConfigFile;

      _1 = assert jsonConfig ? gitDir && builtins.pathExists (/. + jsonConfig.gitDir); "gitDir must be present and be a local path";
      _2 = assert (jsonConfig ? gitUrl) -> builtins.isString jsonConfig.gitUrl; "gitUrl must be a string";
      _3 = assert jsonConfig ? repoName && builtins.isString jsonConfig.repoName; "repoName must be present and be a string";
      _4 = assert (jsonConfig ? lockFiles) -> builtins.isList jsonConfig.lockFiles; "lockFiles must be a list";
    in
    {
      projectName = jsonConfig.repoName;
      fallbackLockFiles = map (x: /. + x) jsonConfig.lockFiles or [];
      gitCommits = githubPrSrcs {
        gitDir = /. + jsonConfig.gitDir;
        # Setting gitUrl is intended to provide an alternate source for
        # git repos, which when building remotely results in a large
        # speedup. But it also means that we can't test commits that
        # only exist on the local machine (e.g. git merges). Eventually
        # we should detect this case, but for now just disable the
        # feature.
        #gitUrl = jsonConfig.gitUrl or jsonConfig.gitDir;
        inherit prNum;
      };
    };

  # Takes a `src` object (as returned from `srcFromCommit`) and determines
  # the set of rustcs to test it with.
  rustcsForSrc = src:
    let
      pkgs = import <nixpkgs> {
        overlays = [
          (import (fetchTarball "https://github.com/oxalica/rust-overlay/archive/master.tar.gz"))
        ];
      };
      msrv = if src.clippyToml != null && src.clippyToml ? msrv
        then pkgs.rust-bin.fromRustupToolchain { channel = src.clippyToml.msrv; }
        else builtins.trace "warning - no clippy.toml, using 1.56.1 as MSRV" pkgs.rust-bin.stable."1.56.1".default;
      nightly = if src.nightlyVersion != null
        then pkgs.rust-bin.fromRustupToolchain { channel = builtins.elemAt (builtins.match "([^\r\n]+)\r?\n?" src.nightlyVersion) 0; }
        else builtins.trace "warning - no rust-version, using latest nightly" (pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default));
    in [
      nightly
      pkgs.rust-bin.stable.latest.default
      pkgs.rust-bin.beta.latest.default
      msrv
    ];

  # Determines whether a given rustc is a nightly rustc.
  rustcIsNightly = rustc: !builtins.isNull (builtins.match "nightly-([0-9]+-[0-9]+-[0-9]+)" rustc.version);

  # Takes a `src` object (as returned from `srcFromCommit`) and determines
  # the set of lockfiles to test it with.
  lockFilesForSrc = { src, fallbackLockFiles }:
    let
      listIfExists = x: if builtins.pathExists x then [ x ] else [];
      srcLockFiles = (listIfExists "${src.src}/Cargo-minimal.lock")
        ++ (listIfExists "${src.src}/Cargo-recent.lock")
        ++ (listIfExists "${src.src}/Cargo.lock");
    in
      if srcLockFiles == [] then fallbackLockFiles else srcLockFiles;

  # Given a list of features
  featuresForSrc = { needsNoStd ? false, include ? [], exclude ? [] }: { src, cargoToml, ... }:
    let
      randBit = name:
        let
          seed = builtins.hashString "sha256" (src.commitId + name);
          seed0 = builtins.substring 0 1 seed;
          bit = builtins.elem seed0 [ "0" "1" "2" "3" "4" "5" "6" "7" ];
        in bit;

      lib = nixpkgs.lib;
      mapToTrue = set: builtins.mapAttrs (_: _: true) set;

      cargoFeatures = { default = true; } // (if cargoToml ? features
        then mapToTrue cargoToml.features
        else {});
      optionalDeps = if cargoToml ? dependencies
        then mapToTrue (lib.filterAttrs (_: opt: opt ? optional && opt.optional) cargoToml.dependencies)
        else {};

      allFeatures = lib.filterAttrs (name: _: ! builtins.elem name exclude) (cargoFeatures // optionalDeps);
      allFeatureNames = builtins.attrNames allFeatures;

      result =
        [
          # Randoms
          (builtins.filter (name: randBit name) allFeatureNames)
          (builtins.filter (name: randBit ("0" + name)) allFeatureNames)
          # Nothing and everything
          []
          allFeatureNames
        ]
        # Each individual feature in isolation.
        ++ (map (feat: [ feat ]) allFeatureNames)
        # Explicitly included things.
        ++ include;
    in
      # This function is supposed to make a list of lists, and because this
      # is hard to keep track of with all the maps and stuff flying around,
      # we do a bunch of assertions here.
      assert builtins.all builtins.isList include;
      assert builtins.isList exclude;
      assert builtins.all builtins.isList result;
      if needsNoStd
      then map (fs: if builtins.elem "std" fs then fs else fs ++ ["no-std"]) result
      else result;

  # Given a set with a set of list-valued attributes, explode it into
  # a list of sets with every possible combination of attributes. If
  # an attribute is a function, it is evaluated with the set of all
  # non-function attributes (which will be exploded before the function
  # ones).
  #
  # Ex: matrix { a = [1 2 3]; b = [true false]; c = "Test" }
  #
  # [ { a = 1; b = true; c = "Test" }
  #   { a = 1; b = false; c = "Test" }
  #   { a = 2; b = true; c = "Test" }
  #   ...
  #   { a = 3; b = false; c = "Test" } ]
  #
  # Despite the complexity of this function and the fact that its runtime
  # is exponential in the number of args, worst-case, it runs very quickly
  # and is probably not worth further optimization. The slowness (and "too
  # many open files" failures) come from call sot singleCheckMemo, which
  # does the crate2nix IFD).
  matrix =
    let
      pkgs = nixpkgs;
      lib = pkgs.lib;
      appendKeyVal = e: k: v: e // builtins.listToAttrs [{ name = k; value = v; }];
      addNames = currentSets: prevNames: origSet:
        let
          newSet = lib.filterAttrs (k: _: !lib.elem k prevNames) origSet;
          newKeys = builtins.attrNames newSet;
        in
        if newKeys == [ ]
        then currentSets
        else
          let
            evaluateValue = s: v: if builtins.isFunction v then v s else v;
            expandValue = v: if builtins.isList v then v else [ v ];
            # We want to choose the next attribute such that, if it is a function,
            # then all of its inputs have already been evaluated.
            availableKeys = builtins.filter (k:
              let
                origVal = origSet.${k};
                isFunc = builtins.isFunction origVal;
                funcArgs = if isFunc
                  then builtins.functionArgs origVal
                  else {};
              in lib.all (name: lib.elem name prevNames) (builtins.attrNames funcArgs)
              ) newKeys;
            nextKey = builtins.head availableKeys;
            nextVal = origSet.${nextKey};
            newSets = builtins.concatMap (s: map
                (v: appendKeyVal s nextKey v)
                (expandValue (evaluateValue s nextVal))
              ) currentSets;
          in
          addNames newSets (prevNames ++ [ nextKey ]) origSet;
    in
    addNames [{ }] [ ];

  # A bunch of "standard" matrix functions useful for Rust projects
  standardRustMatrixFns =
  let
    lib = nixpkgs.lib;
    allLockFiles = { src, jsonConfig }: lockFilesForSrc {
      inherit src;
      fallbackLockFiles = jsonConfig.fallbackLockFiles;
    };
    lockFileName = path: builtins.unsafeDiscardStringContext (builtins.baseNameOf path);
    featuresName = features: "feat-" + builtins.substring
      0 8
      (builtins.hashString "sha256" (builtins.concatStringsSep "," features));
  in jsonConfig: {
    projectName = jsonConfig.projectName;
    src = jsonConfig.gitCommits;

    mainCargoToml = { src, ... }: lib.trivial.importTOML "${src.src}/Cargo.toml";
    workspace = { mainCargoToml, ... }:
      if mainCargoToml ? workspace
        then mainCargoToml.workspace.members
          ++ (if mainCargoToml ? package then [ "." ] else [])
        else null;

    # If there are no include/exclude rules for the crate, you can just inherit this.
    features = featuresForSrc {};

    cargoToml = { workspace, mainCargoToml, src, ... }: if workspace == null
      then mainCargoToml
      else lib.trivial.importTOML "${src.src}/${workspace}/Cargo.toml";

    rustc = { src, ... }: rustcsForSrc src;
    lockFile = { src, ...}: allLockFiles { inherit src jsonConfig; };
    srcName = { src, ... }: src.commitId;
    mtxName = { src, rustc, workspace, features, lockFile, ... }: "${src.shortId}-${rustc.name}${if isNull workspace then "" else "-" + workspace}-${lockFileName lockFile}-${featuresName features}${if src.isTip then "-tip" else ""}";

    isMainLockFile = { src, lockFile, ... }: lockFile == builtins.head (allLockFiles { inherit src jsonConfig; });
    isMainWorkspace = { mainCargoToml, workspace, ... }:
      (workspace == null || workspace == builtins.head mainCargoToml.workspace.members);

    # Clippy runs with --all-targets so we only need to run it on one workspace.
    runClippy = { src, rustc, isMainWorkspace, ... }: rustcIsNightly rustc && src.isTip && isMainWorkspace;
    runDocs = { src, rustc, isMainWorkspace, ... }: rustcIsNightly rustc && src.isTip && isMainWorkspace;
    runFmt = { src, rustc, isMainWorkspace, ... }: rustcIsNightly rustc && src.isTip && isMainWorkspace;
  };

  # Given a git directory (the .git directory) and a PR number, obtain a list of
  # commits corresponding to that PR. Assumes that the refs pr/${prNum}/head and
  # pr/${prNum}/merge both exist.
  #
  # Ex.
  # let
  # pr1207 = import (andrew.githubPrCommits {
  #   gitDir = ../../bitcoin/secp256k1/master/.git;
  #   prNum = 1207;
  # }) {};
  # in
  #   pr1207.gitCommits
  #
  githubPrCommits =
    { gitDir
    , prNum
    }:
    stdenv.mkDerivation {
      name = "get-git-commits";
      buildInputs = [ nixpkgs.git ];

      preferLocalBuild = true;
      phases = [ "buildPhase" ];

      buildPhase = ''
        set -e
        export GIT_DIR="${gitDir}"

        HEAD_COMMIT="pr/${builtins.toString prNum}/head"
        if ! git rev-parse --verify --quiet "$HEAD_COMMIT^{commit}"; then
          echo "Head commit $HEAD_COMMIT not found in git dir $GIT_DIR."

          BARE_COMMIT="${builtins.toString prNum}"
          if ! git rev-parse --verify --quiet "$BARE_COMMIT^{commit}"; then
            echo "Bare $BARE_COMMIT also does not appear to be a commit ID."
            exit 1
          fi

          mkdir -p "$out"
          BARE_COMMIT=$(git rev-parse "$BARE_COMMIT^{commit}")
          echo "pkgs: { gitCommits = [ \"$BARE_COMMIT\" ]; }" > "$out/default.nix";
          exit 0
        fi

        MERGE_COMMIT="pr/${builtins.toString prNum}/merge"
        if ! git rev-parse --verify --quiet "$MERGE_COMMIT^{commit}"; then
          echo "Merge commit $MERGE_COMMIT not found in git dir $GIT_DIR."
          exit 1
        fi

        mkdir -p "$out"

        echo 'pkgs: { gitCommits = [' >> "$out/default.nix"
        REVS=$(git rev-list "$HEAD_COMMIT" --not "$MERGE_COMMIT~")
        for rev in $REVS;
          do echo " \"$rev\"" >> "$out/default.nix"
        done

        echo ']; }' >> "$out/default.nix"
      '';
    };

  # Given a commit ID, fetch it and obtain relevant data for the CI system.
  #
  # Throughout this code, a "src" refers to the set returned by this function.
  srcFromCommit =
    { commit
    , isTip
    , gitUrl
    , ref ? "master"
    }:
    rec {
      src = builtins.fetchGit {
        url = gitUrl;
        inherit ref;
        rev = commit;
        allRefs = true;
      };
      commitId = commit;
      shortId = builtins.substring 0 8 commit;
      inherit isTip;

      # Rust-specific stuff.
      clippyToml = if builtins.pathExists "${src}/clippy.toml" then
        nixpkgs.lib.trivial.importTOML "${src}/clippy.toml"
      else null;
      cargoToml = if builtins.pathExists "${src}/Cargo.toml" then
        nixpkgs.lib.trivial.importTOML "${src}/Cargo.toml"
      else null;
      nightlyVersion = if builtins.pathExists "${src}/nightly-version" then
        builtins.readFile "${src}/nightly-version"
      else null;
    };

  # Wrapper of githubPrCommits that actually calls the derivation to obtain the list of
  # git commits, then calls fetchGit on everything in the list
  #
  # If gitUrl is provided, it is used to fetch the actual commits. This is provided
  # to assist with remote building: githubPrCommits is always run locally, so it is
  # fastest to provide it with a local git checkout via gitDir. But this just gets
  # a list of commit IDs. To fetch the actual commits, which will happen remotely,
  # it may be faster to provide a github URL (so the remote machine can directly
  # connect to github rather than copying over the local derivation)
  githubPrSrcs =
    { gitDir
    , prNum
    , gitUrl ? gitDir
    }:
    let
      bareCommits = (import (githubPrCommits { inherit gitDir prNum; }) { }).gitCommits;
    in
    map
      (commit: srcFromCommit {
        inherit commit gitUrl;
        isTip = (commit == builtins.head bareCommits);
#        ref = "refs/pull/${builtins.toString prNum}/head";
      }) bareCommits;

  derivationName = drv:
    builtins.unsafeDiscardStringContext (builtins.baseNameOf (builtins.toString drv));

  # Given a bunch of data, do a full PR check.
  #
  # name is a string that will be used as the name of the total linkFarm
  # argsMatrix should be an "argument matrix", which is an arbitrary-shaped
  #  sets, which will be exploded so that any list-typed fields will be turned into
  #  multiple sets, each of which has a different element from the list in place of
  #  that field. See documentation for 'matrix' for more information.
  #
  #  THERE ARE TWO REQUIRED FIELD, srcName and mtxNames. These should be functions
  #  which take the matrix itself and output a string. The srcName string is used
  #  to split the linkFarm links into separate directories, while the mtxName
  #  string goes into the derivation name and can be anything.
  #
  # singleCheck is a function which takes:
  #  1. A matrix entry
  #  2. A value from singleCheckMemo, or null if singleCheckMemo is not provided.
  #
  # singleCheckMemo is a bit of a weird function. If provided, it takes a matrix
  # entry and returns a { name, value } pair where:
  #  1. name is a string uniquely specifying the inputs needed to compute "value"
  #     from the matrix entry.
  #  2. value is some arbitrary computation.
  #
  # The idea behind singleCheckMemo is that there are often heavy computations
  # which depend only on a subset of the matrix data (e.g. calling a Cargo.nix
  # derivation in a crate2nix-based rust build, which needs only the source
  # code and Cargo.lock file). Then we can feed the output of this function into
  # builtins.listToAttrs, and nix's lazy field mean that if a given name appears
  # multiple times, the value will only be computed for the final one (i.e. the
  # one that gets accessed).
  #
  # This has the same complexity as "lookup the value if it exists, otherwise do
  # an expensive computation and cache it", though the actual mechanics are quite
  # different.
  checkPr =
    { name
    , argsMatrix
    , singleCheckDrv
    , singleCheckMemo ? x: { name = ""; value = null; }
    ,
    }:
    let
      mtxs = matrix argsMatrix;
      # This twisty memoAndLinks logic is due to roconnor. It avoids computing
      # memo.name (which is potentially expensive) twice, which would be needed
      # if we first computing memoTable "normally" and then later indexed into
      # it when producing a list of links.
      memoTable = builtins.listToAttrs (map (x: x.memo) memoAndLinks);
      memoAndLinks = map
        (mtx:
          let memo = singleCheckMemo mtx;
          in {
            inherit memo;
            link = rec {
              path = singleCheckDrv mtx memoTable.${memo.name};
              name = "${mtx.srcName}/${mtx.mtxName}--${derivationName path}";
            };
          }
        )
        mtxs;
    in
    nixpkgs.linkFarm name (map (x: x.link) memoAndLinks);

  # A value of singleCheckMemo useful for Rust projects, which uses a crate2nix generated
  # Cargo.nix as the key, and the result of calling it as the value.
  #
  # Assumes that your matrix has entries projectName, prNum, rustc, lockFile, src.
  #
  # Note that EVERY INPUT TO THIS FUNCTION MUST BE ADDED TO generatedCargoNix. If it is
  # not, the memoization logic will collapse all the different values for that input
  # into one.
  #
  # During evaluation, this method is by far the slowest, since it is doing an IFD of
  # a crate2nix call. A single run takes several seconds, and the number of times it
  # is run is the product of the number of possibilities for each input. So "global"
  # values like `projectNAme` and `prNum` are free, but for each commit in `src`,
  # it will be run 4 (number of rustcs) times 2 (number of lockfiles), and if you
  # add any more arguments, it will be multiplied again.
  crate2nixSingleCheckMemo =
    { projectName
    , prNum
    , rustc
    , lockFile
    , src
    , ...
    }:
    let
      overlaidPkgs = import <nixpkgs> {
        overlays = [ (self: super: {
          inherit rustc;
        }) ];
      };
      generatedCargoNix = tools-nix.generatedCargoNix {
        name = "${projectName}-generated-cargo-nix-${builtins.toString prNum}-${src.shortId}-${builtins.toString rustc}";
        src = src.src;
        overrideLockFile = lockFile;
      };
      calledCargoNix = overlaidPkgs.callPackage generatedCargoNix {
        # For dependencies we want to simply use the stock `pkgs.buildRustCrate`. But for
        # the actual crates we're testing, it is nice to modify the derivation to include
        # A bunch of metadata about the run. Annoyingly, there isn't any way to tell what
        # a "root crate" exposed by crate2nix, so we have to sorta hack it by assembling
        # a `rootCrateIds` list and checking membership.
        #
        # Ideally we could at least check whether `crate.crateName` matches the specific
        # workspace under test, but that is yet-undetermined and right now we're in a
        # `callPackage` call so we can't even use laziness to refer to yet-undetermined
        # values.
        buildRustCrateForPkgs = pkgs: crate:
          if builtins.elem crate.crateName rootCrateIds
          then (pkgs.buildRustCrate crate).override {
            preUnpack = ''
              set +x
              echo 'Project name: ${projectName}'
              echo 'PR number: ${builtins.toString prNum}'
              echo 'rustc: ${builtins.toString rustc}'
              echo 'lockFile: ${lockFile}'
              echo 'Source: ${builtins.toJSON src}'
            '';
          }
          else pkgs.buildRustCrate crate;
        # We have some should_panic tests in rust-bitcoin that fail in release mode
        release = false;
      };
      rootCrateIds =
        (if calledCargoNix ? rootCrate
         then [ calledCargoNix.rootCrate.packageId ]
         else []) ++
        (if calledCargoNix ? workspaceMembers
         then map (p: p.packageId) (builtins.attrValues calledCargoNix.workspaceMembers)
         else []);
        
    in
    {
      name = builtins.unsafeDiscardStringContext (builtins.toString generatedCargoNix);
      value = {
        generated = generatedCargoNix;
        called = calledCargoNix;
      };
    };

  # A value of singleCheckDrv useful for Rust projects. Should be used with
  # `crate2nixSingleCheckMemo`.
  crate2nixSingleCheckDrv =
    { projectName
    , prNum
    , isMainLockFile
    , isMainWorkspace
    , workspace ? null
    , mainCargoToml
    , cargoToml
    , features
    , rustc
    , lockFile
    , src
    , srcName
    , mtxName
    , runClippy ? true
    , runDocs ? true
    , runFmt ? false
    , extraTestPostRun ? ""
    , ...
    }:
    nixes:
    let
      pkgs = import <nixpkgs> {
        overlays = [ (self: super: { inherit rustc; }) ];
      };
      lib = pkgs.lib;

      # Used by bitcoind-tests in miniscript and corerpc; rather than
      # detecting whether this is needed, we just always pull it in.
      bitcoinSrc = (pkgs.callPackage /store/home/apoelstra/code/bitcoin/bitcoin/default.nix {}).bitcoin24;

      crate2nixDrv = if workspace == null
        then nixes.called.rootCrate.build
        else nixes.called.workspaceMembers.${cargoToml.package.name}.build;

      drv = crate2nixDrv.override {
        inherit features;
        runTests = true;
        testPreRun = ''
          ${rustc}/bin/rustc -V
          ${rustc}/bin/cargo -V
          echo "PR: ${projectName} #${prNum}"
          echo "Commit: ${src.commitId}"
          echo "Tip: ${builtins.toString src.isTip}"
          echo "Workspace: ${if isNull workspace then "[no workspaces]" else workspace}"
          echo "Features: ${builtins.toJSON features}"
          echo "Lockfile: ${lockFile}"
          echo
          echo "Run clippy: ${builtins.toString runClippy}"
          echo "Run docs: ${builtins.toString runDocs}"

          # Always pull this in; though it is usually not needed.
          echo
          export BITCOIND_EXE="${bitcoinSrc}/bin/bitcoind"
          echo "Bitcoind exe: $BITCOIND_EXE"

          # We have "cannot find libstdc++" issues when compiling
          # rust-bitcoin with bitcoinconsensus on and rustc nightly
          # from 2024-05-22 onward (did not occur on 2024-05-04;
          # intermediate versions not tested due to rustc #124800).
          #
          # Possible culprit: https://blog.rust-lang.org/2024/05/17/enabling-rust-lld-on-linux.html
          export LD_LIBRARY_PATH=${stdenv.cc.cc.lib}/lib/
        '';
        testPostRun = ''
            set -x
            pwd
            export PATH=$PATH:${pkgs.gcc}/bin:${rustc}/bin
            export NIXES_GENERATED_DIR=${nixes.generated}/

            export CARGO_TARGET_DIR=$PWD/target
            pushd ${nixes.generated}/crate
            export CARGO_HOME=../cargo
          '' + lib.optionalString runClippy ''
            # Nightly clippy
            cargo clippy --all-features --all-targets --locked -- -D warnings
          '' + lib.optionalString runDocs ''
            # Do nightly "broken links" check
            export RUSTDOCFLAGS="--cfg docsrs -D warnings -D rustdoc::broken-intra-doc-links"
            cargo doc -j1 --all-features
            # Do non-docsrs check that our docs are feature-gated correctly.
            export RUSTDOCFLAGS="-D warnings"
            cargo doc -j1 --all-features
          '' + lib.optionalString runFmt ''
            cargo fmt --all -- --check
          '' + ''
            popd
          '' + extraTestPostRun;
        };
        fuzzTargets = map
          (bin: bin.name)
          (lib.trivial.importTOML "${src.src}/fuzz/Cargo.toml").bin;
        fuzzDrv = cargoFuzzDrv {
          normalDrv = drv;
          inherit projectName src lockFile nixes fuzzTargets;
        };
      in
        if rustcIsNightly rustc && isMainLockFile && cargoToml ? dependencies && cargoToml.dependencies ? honggfuzz
        then fuzzDrv
        else drv.overrideDerivation (drv: {
          # Add a bunch of stuff just to make the derivation easier to grok
          checkPrProjectName = projectName;
          checkPrPrNum = prNum;
          checkPrRustc = rustc;
          checkPrLockFile = lockFile;
          checkPrFeatures = builtins.toJSON features;
          checkPrWorkspace = workspace;
          checkPrSrc = builtins.toJSON src;
        });

  # Derivation which wraps an existing derivation (which should be e.g. something that
  # runs tests in the fuzz/ directory) in one that runs cargo-hfuzz on a series of
  # targets.
  cargoFuzzDrv = {
    normalDrv
  , projectName
  , src
  , lockFile
  , nixes
  , fuzzTargets
  }: let
    overlaidPkgs = import <nixpkgs> {
      overlays = [
        (import (fetchTarball "https://github.com/oxalica/rust-overlay/archive/master.tar.gz"))
      ];
    };
    singleFuzzDrv = fuzzTarget: stdenv.mkDerivation {
      name = "fuzz-${fuzzTarget}";
      src = src.src;
      buildInputs = [
        overlaidPkgs.rust-bin.stable."1.64.0".default
        (import ./honggfuzz-rs.nix { })
        # Pinned version because of breaking change in args to init_disassemble_info
        nixpkgs.libopcodes_2_38 # for dis-asm.h and bfd.h
        nixpkgs.libunwind       # for libunwind-ptrace.h
      ];
      phases = [ "unpackPhase" "buildPhase" ];

      buildPhase = ''
        set -x
        export CARGO_HOME=$PWD/cargo
        export HFUZZ_RUN_ARGS="--run_time 120 --threads 2 --exit_upon_crash"

        cargo -V
        cargo hfuzz version
        echo "Source: ${builtins.toJSON src}"
        echo "Fuzz target: ${fuzzTarget}"

        # honggfuzz rebuilds the world, including itself for some reason, and
        # it expects to be able to build itself in-place. So we need a read/write
        # copy.
        cp -r ${nixes.generated}/cargo .
        chmod -R +w cargo

        DEP_DIR=$(grep 'directory =' $CARGO_HOME/config | sed 's/directory = "\(.*\)"/\1/')
        cp -r "$DEP_DIR" vendor-copy/
        chmod +w vendor-copy/
        rm vendor-copy/*honggfuzz*
        cp -rL "$DEP_DIR/"*honggfuzz* vendor-copy/ # -L means copy soft-links as real files
        chmod -R +w vendor-copy/
        # These two lines are just a search-and-replace ... but trying to get sed to replace
        # one string full of slashes with another is an unreadable mess, so easier to just
        # erase the line completely then recreate it with echo.
        sed -i "s/directory = \".*\"//" "$CARGO_HOME/config"
        echo "directory = \"$PWD/vendor-copy\"" >> "$CARGO_HOME/config"
        cat "$CARGO_HOME/config"
        # Done crazy honggfuzz shit

        # If we have git dependencies, we need a lockfile, or else we get an error of the
        # form "cannot use a vendored dependency without an existing lockfile". This is a
        # limitation in cargo 1.58 (and probably later) which they apparently decided to
        # fob off on us users.
        cp ${lockFile} Cargo.lock
        pushd fuzz/
        cargo hfuzz run "${fuzzTarget}"
        popd

        touch $out
      '';
    };
    fuzzDrv = overlaidPkgs.linkFarm
      "${projectName}-${src.shortId}-fuzz" 
      ((map (x: rec {
        name = "fuzz-${path.name}";
        path = singleFuzzDrv x;
      }) fuzzTargets) ++ [{
        name = "fuzz-normal-tests";
        path = normalDrv;
      }]);
    in fuzzDrv;
}



