#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$DIR"

#Is set to 1 if any assert fails
exit_code=0

function arrayEQ() {
  local arr0=( $1 )
  local arr1=( $2 )

  arr0=( $(printf "%s\n" "${arr0[@]}" | sort -u) )
  arr1=( $(printf "%s\n" "${arr1[@]}" | sort -u) )

  assertEQ "${arr0[*]}" "${arr1[*]}" "$3"
}

function assertNEQ() {
  if [[ "$1" == "$2" ]]; then
    echo "$(txt_red)$(txt_bold)"
    echo "------------------------------------"
    echo "=> Assertion failed"
    echo "=> Line: $3"
    echo "=> Expected other value then: \"$1\""
    echo "------------------------------------"
    echo "$txt_reset"
    exit_code=1
  fi
}

function assertEQ() {
  if [[ "$1" != "$2" ]]; then
    echo "$(txt_red)$(txt_bold)"
    echo "------------------------------------"
    echo "=> Assertion failed"
    echo "=> Line: $3"
    echo "=> Value: \"$1\""
    echo "=> Expected: \"$2\""
    echo "------------------------------------"
    echo "$txt_reset"
    exit_code=1
  fi
}

function SetUp() {
  mkdir -p "$DIR/repo"
  mkdir -p "$DIR/packages"
  cp $DIR/packages_template/* "$DIR/packages/"
}

function TearDown() {
  rm -rf "$DIR/repo"
  rm -rf "$DIR/packages"
}

function test_config_parse() {
  ParsePackageConfig "$PWD/configs/cutecom.conf"
  assertEQ "${__result[name]}" "cutecom" "$LINENO"
  assertEQ "${__result[disabled]}" "false" "$LINENO"
  assertEQ "${__result[val_01]}" "\$123ABC" "$LINENO"
  unset __result

  ParsePackageConfig "$PWD/configs/malformed.noconf"
  assertEQ "$?" "$ERROR" "$LINENO"

}

function test_cower() {
  CowerGetDeps "cutecom"
  assertEQ "$__result" "qt5-serialport" "$LINENO"

  local expected=( "ccnet"  "seafile"  "qt5-tools"  "qt5-webkit"  "qt5-base"  "gtk-update-icon-cache"  "qt5-webengine" )
  CowerGetDeps "seafile-client"
  arrayEQ "${__result[*]}" "${expected[*]}" "$LINENO"
}

function test_PkgX() {
  local pkg_path="$PWD/packages/xorg-server-common-1.19.1-5-x86_64.pkg.tar.xz"

  PkgGetName "$pkg_path"
  assertEQ "$__result" "xorg-server-common" "$LINENO"

  PkgGetVersion "$pkg_path"
  assertEQ "$__result" "1.19.1-5" "$LINENO"
}

function test_RepoX() {
  local pkg_path="$DIR/packages/xorg-server-common-1.19.1-5-x86_64.pkg.tar.xz"

  PkgGetName "$pkg_path"
  local name="$__result"

  #Please mind that this will remove the pkg.tar.xz file from its current location
  RepoMovePackage "$pkg_path"

  assertEQ "$name" "xorg-server-common" "$LINENO"

  RepoGetPackageVersion "$name"
  assertEQ "$__result" "1.19.1-5" "$LINENO"

  RepoGetPackageVersion "not-in-repo"
  assertEQ "$__result" "" "$LINENO"

  RepoRemovePackage "$name"

  RepoGetPackageVersion "$name"
  assertEQ "$__result" "" "$LINENO"

  #Check if the package was removed from the repository
  [[ ! -f "$repo_dir/xorg-server-common-1.19.1-5-x86_64.pkg.tar.xz" ]] || assertEQ "1" "0" "$LINENO"
}

function test_BuildOrUpdatePackage() {
  ParsePackageConfig "$PWD/configs/cutecom.conf"

  #Global var used by the buildserver
  #Assign __result to current_package_cfg
  eval $(typeset -A -p __result|sed 's/ __result=/ current_package_cfg=/')

  BuildOrUpdatePackage
  assertEQ "$?" "$SUCCESS" "$LINENO"

  RepoGetPackageVersion "cutecom"
  assertNEQ "$__result" "" "$LINENO"

  RepoRemovePackage "cutecom"
  RepoGetPackageVersion "cutecom"
  assertEQ "$__result" ""
}

function test_AurDepsResolver() {
  PackageGetAurDepsRec "seafile-client"
  arrayEQ "${__result[*]}" "ccnet seafile ccnet-server ccnet libsearpc ccnet-server libsearpc" "$LINENO"
}

rm -rf "$DIR/repo"
rm -rf "$DIR/packages"

function run_test() {
  SetUp
  echo "=> Running $1"
  local start_ts="$(date "+%s")"
  eval "$1"
  local end_ts="$(date "+%s")"
  echo "=> Finished $1 ($((end_ts - start_ts)) seconds)"
  TearDown
}

SetUp
export AUR_REPO_BUILDSERVER_TEST=true
. ./../buildserver.sh --pkg-configs $DIR/configs --repo-dir $DIR/repo --action clean,build --debug

#Run tests
run_test test_config_parse
run_test test_config_parse
run_test test_cower
run_test test_PkgX
run_test test_RepoX
run_test test_AurDepsResolver
run_test test_BuildOrUpdatePackage

#Cleanup from buildserver.sh
CleanUp

#Returns 1 if any test failed
exit $exit_code