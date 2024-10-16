{ pkgs ? import <nixpkgs> { }
, jsonConfigFile
, inlineJsonConfig ? null
, inlineCommitList ? []
, prNum
}:
let
  utils = import ./andrew-utils.nix { };
  jsonConfig = if builtins.isNull inlineJsonConfig
    then utils.parseRustConfig { inherit jsonConfigFile prNum; }
    else inlineJsonConfig // {
        gitCommits = map utils.srcFromCommit inlineCommitList;
    };
  fullMatrix = {
    inherit prNum;
    inherit (utils.standardRustMatrixFns jsonConfig)
      projectName src rustc msrv lockFile
      srcName mtxName isMainLockFile isMainWorkspace mainCargoToml
      workspace cargoToml runDocs;#runCheckPublicApi;
runClippy  = false;

    features1 = [ [ "default" ] ];
    features = { src, cargoToml, workspace, ... }:
      if workspace == "bitcoin"
      then utils.featuresForSrc { exclude = [ "actual-serde" ]; } { inherit src cargoToml; }
      # schemars does not work with nostd, so exclude it from
      # the standard list and test it separately.
      else if workspace == "hashes"
      then utils.featuresForSrc {
        include = [ [ "std" "schemars" ] ];
        exclude = [ "actual-serde" "schemars" ];
      } { inherit src cargoToml; }
      else utils.featuresForSrc { } { inherit src cargoToml; };

      runFmt = false;
  };

  checkData = rec {
    name = "${jsonConfig.projectName}-pr-${builtins.toString prNum}";
    argsMatrix = fullMatrix;
    singleCheckDrv = utils.crate2nixSingleCheckDrv;
    memoGeneratedCargoNix = utils.crate2nixMemoGeneratedCargoNix;
    memoCalledCargoNix = utils.crate2nixMemoCalledCargoNix;
  };
in
{
  checkPr = utils.checkPr checkData;
  checkHead = utils.checkPr checkData;
}
