#!/bin/bash

set -o pipefail

function txt_bold {
  tput bold 2> /dev/null
}

function txt_reset {
  tput sgr0 2> /dev/null
}

function txt_red {
  tput setaf 1 2> /dev/null
}

function txt_green {
  tput setaf 2 2> /dev/null
}

function txt_yellow {
  tput setaf 3 2> /dev/null
}

function PrintUsage() {

if [[ ! -z "$1" ]]; then
  echo -e $(txt_red; txt_bold)"$1\n"$(txt_reset)
fi

cat <<EOF
Package building, updating and so forth:
  $0 [--pkg-configs packages config dir] [--repo-dir path] [--action action] [OPTION]...

$(txt_bold)Required argument$(txt_reset)
  $(txt_red)--action $(txt_green) action $(txt_reset)
  The action that should be performed by the buildserver.
  Possible values are the following:
    $(txt_green)build $(txt_reset)
      This action will build/update all targets defined by a config file in the
      --pkg-configs directory.
    $(txt_green)clean $(txt_reset)
      This action will delete all packages from the repository that have no
      associated config files in the --pkg-configs directory.

  $(txt_red)--repo-dir $(txt_green) path $(txt_reset)
    Path must point to an directory where the repo database should be created.
    If in the given directory a database already exists, it will be update.

  $(txt_red)--pkg-configs $(txt_green) path $(txt_reset)
    Path to a directory that contains multiple package configuration files.


$(txt_bold)OPTIONS$(txt_reset)
  $(txt_red)--work-dir $(txt_green) path $(txt_reset)
    Directory where packages are build.
    Default value is \$HOME/.cache/aur-repo-buildserver

  $(txt_red)--repo-name $(txt_green) name $(txt_reset)
    The name of the repository to create/update.
    This name must be later used as the "repository tag"
    in you're pacman conf e.g.
      [aur-repo] <<< TAG
      SigLevel = ...
      Server = https://...

  $(txt_red)--debug $(txt_reset)
    Enable output of debugging messages.

  $(txt_red)--admin-mail $(txt_green) mail address $(txt_reset)
    The mail address of the admin. To this email address a mail
    is send, every time an error accours.
EOF

exit 1
}


########## Logging ##########

function IndentInc() {
  indent=$(( indent + 3 ))
}

function IndentDec() {
  if [[ $(( indent - 3)) < 0 ]]; then
    indent=0
  else
    indent=$(( indent - 3 ))
  fi
}

function IndentRst() {
  indent=0
}


function LogStdout() {
  local curr_date="$(date +'%d.%m.%y-%H:%M:%S')"
  local indent_str="$(head -c "$indent" < /dev/zero | tr '\0' ' ')"
  local msg="[$curr_date]$indent_str $1 $(txt_reset)"
  echo "$msg"
  echo "$msg" >> "$global_log_txt_path"
}

function Dbg() {
  [[ "$verbose" == "true" ]] || return
  LogStdout "$(txt_yellow) => $1"
}

#Logs a info message passed as $1
function Info() {
  LogStdout "$(txt_green) => $1"
}

#Logs an error message
function Err() {
  LogStdout "$(txt_red) => $1"
}

#Logs an fatal error and kills the buildsever.
#If mail reporting is configured, an mail is send
#to the server admin.
#A fatal error is thrown, if an error occurs that is very likely
#caused by a bug in the script e.g. a file was copied beforehand to location x
#and is not there when the script is trying to access it.
function ErrFatal() {
  LogStdout "$(txt_red) => $1"
  HandleFatalError "$1"
}

function GenerateHtmlLog() {
  if [[ ! -z "$global_log_txt_path" ]]; then
    [[ -f /usr/bin/aha ]] \
      || Err "/usr/bin/aha is needed for HTML log generation"
    cat "$global_log_txt_path" | aha > "$global_log_html_path"
  fi
}

####################

########## Shutdown and error handling ##########

#Deletes all temporary files
function CleanUp() {
  Info "Cleaning up"
  rm -rf "$rpc_cache_dir"
  rm -rf "$work_dir"
}

#Handles an fatal error from that we aren't able to recover.
#The reason for the error is passed in $1
function HandleFatalError() {
  if [[ ! -z "$admin_mail" ]]; then
    echo "Send email here"
  fi

  CleanUp
  exit 1
}
####################


########## Mail stuff ##########

#Send a mail
#$1 - send mail address
#$2 - receiver mail address
#$3 - subject
#$4 - body
#$5... - paths to files that will be send as attachment
#Returns: $SUCCESS or $ERROR
SendMail() {
  dbg_arg "send_email" "$@"
  # info "send_email is not implemented jet!"
  # return 0
  local readonly sender="$1"
  local readonly receiver="$2"
  local readonly subject="$3"
  local readonly body="$4"
  readonly attachments_arg=""

  shift 4
  for path in $@; do
    attachments_arg="${attachments_arg}-a $path "
  done

  mutt -s "$subject" $attachments_arg -- "$receiver" < <(echo "$body") || return $ERROR
  return $SUCCESS
}


####################

#Parses a package config file and returns its key
#value pairs as associative array.
#$1 - Path to the config file
#On error ERROR is returned, else SUCCESS.
#Returns: __result
function ParsePackageConfig() {
  Dbg "ParsePackageConfig($1)"
  local path="$1"

  unset __result #prevent "can not convert" error
  declare -g -A __result

  local OLD_IFS="$IFS"
  export IFS=$'\n'
  for l in $(cat "$path"); do
    local key="$(echo "$l" | cut -d '=' -f 1 | tr -d ' ')"
    local val="$(echo "$l" | cut -d '=' -f 2- | xargs)"
    [[ ! -z "$key" && ! -z "$val" ]] \
      || { Err "ParsePackageConfig($1): Malformed config"; return $ERROR; }
    __result["$key"]="$val"
  done
  export IFS="$OLD_IFS"
  return $SUCCESS
}

#Get the version of an package archive.
#$1 - The path to the archive
#On error a fatal error is raised.
#Returns: Version string in __result
function PkgGetVersion() {
  Dbg "PkgGetVersion($1)"
  __result="$(pacman -Qp "$1" | cut -d ' ' -f 2)"
  [[ $? == 0 ]] \
    || ErrFatal "PkgGetVersion($1) Error while getting version"
  Dbg "PkgGetVersion() -> $__result"
}

#Get the name of a package archive
#$1 - The path to the archive
#On error is fatal error is raised
#Returns: Package name in __result
function PkgGetName() {
  Dbg "PkgGetName($1)"
  __result="$(pacman -Qp "$1" | cut -d ' ' -f 1)"
  [[ $? == 0 ]] \
    || ErrFatal "PkgGetName($1) Error while getting package name"
  Dbg "PkgGetName() -> $__result"
}

########## Repo management ##########

#Returns the package version of a given package name.
#$1 - The name of the package
#Returns: The version of package $1 in __result
RepoGetPackageVersion() {
  Dbg "RepoGetPackageVersion($1)"
  local package_name="$1"
  __result=""
  for p in $(ls $repo_dir/*.pkg* 2> /dev/null); do
    if [[ "$(PkgGetName "$p")" == "$package_name" ]]; then
      __result="$(PkgGetVersion "$p")"
      Dbg "RepoGetPackageVersion() -> $__result"
      return
    fi
  done
  Dbg "RepoGetPackageVersion() -> \"\""
}

#Adds an package to the given repo
#$1 - Path to the package to add. This file will be moved into
#the package directory. Thus it isn't available at its old location
#after this function returns. The function expects that the given package
#(in the given version) wasn't already added to the repo.
#On error a fatal error is raised
#Returns: nothing
RepoAddPackage() {
  Dbg "RepoAddPackage($1)"
  mv "$1" "$repo_dir" \
    || ErrFatal "Error while moving package into repository folder"
  repo-add --new --remove "$repo_db" "$repo_dir/$(basename "$1")" || \
    ErrFatal "Error while adding package $1 to repository"
}

RepoRemovePackage() {
  PkgGetName "$1"
  repo-remove "$repo_db" "$__result" || \
    ErrFatal "Error while removing package $1 from repository"
  rm -f "$1"
}

####################

#Get all AUR package dependecies for the packages build by the server
#The returned array also contains the configured packages itself.
#Returns an array of the package names in $__result and $SUCCESS or $ERROR
function PackagesGetAurDeps() {
  local processed_packages=()
  local work_queue=()

  for p in $(ls $pkg_configs_dir/*.conf); do
    ParsePackageConfig "$p" || return $ERROR
    work_queue+=("${__result[name]}")
  done
  unset __result

  while [[ "${#work_queue[@]}" > 0 ]]; do
    #TODO: Check for dependency cycles
    local current_proccessed_package="${work_queue[0]}"
    Dbg "PackagesGetAurDeps() work_queue = ${work_queue[*]}"

    local package_deps=("$(pacaur -Si "$current_proccessed_package" 2> /dev/null | grep  "Depends on" | cut -d ':' -f 2 | xargs)") \
      || { Err "Error while getting dependncies of $current_proccessed_package"; return $ERROR; }

    for dep in ${package_deps[@]}; do
      #Filter version string
      dep="$(echo "$dep" | egrep -o "^([a-z]|[A-Z]|-|\.|[0-9])*")"

      local package_repo="$(pacaur -Si "$dep" 2> /dev/null | grep "Repository" | cut -d ':' -f 2 | xargs)" \
        || { Err "Error while determining repository of $dep"; return $ERROR; }

      if [[ "$package_repo" == "aur" ]]; then
        work_queue+=("$dep")
      fi
    done

    processed_packages=(${processed_packages[@]} $current_proccessed_package)
    unset work_queue[0]
    #Shift empty elements (remove)
    work_queue=( ${work_queue[@]} )
  done

  Dbg "PackagesGetAurDeps() dependecies(${#processed_packages[@]}) = ${processed_packages[*]}"

  __result=(${processed_packages[@]})
  return $SUCCESS
}


function BuildOrUpdatePackage() {
  local package_name="$1"
  local package_work_dir="$work_dir/$package_name"
  Info "Creating working directory $package_work_dir"
  mkdir -p "$package_work_dir"
  if [[ $? != 0 ]]; then
    Err "Error while creating $package_work_dir"
    return $ERROR
  fi

  Info "Building or updating $package_name"

  #Create links from packages in repo into workdir
  ln -s $(ls $repo_dir/*.pkg* 2> /dev/null ) "$package_work_dir" 2> /dev/null

  #Place where pacaur will look for already build packages
  #and stores build results
  export PKGDEST="$package_work_dir"

  #Fixes EDITOR not set error on docker host
  export EDITOR=nano

  Info "Running pacaur"

  pacaur -m --needed --noconfirm --noedit "$package_name"
  if [[ $? != 0 ]]; then
    Err "BuildOrUpdatePackage($1) Error while executing pacaur"
    Info "Deleting working directory $package_work_dir"
    rm -rf "$package_work_dir"
    return $ERROR
  fi

  #New build packages aren't symlinks
  local new_files=$(find "$package_work_dir" -mindepth 1 ! -type l)

  if [[ -z "$new_files" ]]; then
    #Nothing changed
    Info "Package $package_name and all its dependencies are up-to-date"
  else
    #Packages where updated/build
    for f in $new_files; do
      Info "New package $(basename "$f") was build"

      PkgGetName "$f"
      local new_package_name="$__result"

      PkgGetVersion "$f"
      local new_package_version="$__result"

      RepoGetPackageVersion "$new_package_name"
      local old_version="$__result"

      if [[ -z "$old_version" ]]; then
        #There is no old package -> first time build
        Info "Package $new_package_name was build the first time ($new_package_version)"
        RepoAddPackage "$f"
      else
        #Package was updated
        Info "Package $new_package_name was updated ($old_version -> $new_package_version)"
        RepoAddPackage "$f"
      fi
    done
  fi
  Info "Deleting working directory $package_work_dir"
  rm -rf "$package_work_dir"
  return $SUCCESS
}

#This function processes all package configs and executes
#for each of the config the BuildOrUpdatePackage function.
function ProcessPackageConfigs() {
  Info "Processing all configurations in $pkg_configs_dir..."
  IndentInc

  if [[ "$(ls -l $pkg_configs_dir/*.conf | wc -l)" < 1 ]]; then
    Info "Package configs dir $pkg_configs_dir is empty, please add some config files"
    return;
  fi

  for cfg in $(ls $pkg_configs_dir/*.conf); do
    ParsePackageConfig "$cfg"
    if [[ $? != $SUCCESS ]]; then
      Err "ProcessPackageConfig() Malformed config $cfg, skipping..."
      #TODO: Report error per mail
      IndentDec
      continue;
    fi

    #Copy package config array from __result to pkg_cfg
    #TODO: Make this less ugly
    eval $(typeset -A -p __result|sed 's/ __result=/ pkg_cfg=/')

    Info "Processing package $(txt_bold)${pkg_cfg[name]}$($txt_reset)"
    IndentInc

    if [[ ! -z "${pkg_cfg[disabled]}" && "${pkg_cfg[disabled]}" == "true" ]]; then
      Info "Config $cfg is disabled, skipping..."
      IndentDec
      continue;
    fi

    #Import needed PGP keys
    if [[ ! -z "${pkg_cfg[pgp_keys]}" ]]; then
      local import_failed=false
      for key in ${pkg_cfg[pgp_keys]} ; do
        Info "Importing PGP-Key $key..."
        gpg --keyserver "$gpg_keyserver" --recv-keys  "$key"
        if [[ $? != 0 ]]; then
          Err "Faild to import PGP key $key for package ${pkg_cfg[name]}, skipping package..."
          #TODO: Report error per mail
          import_failed=true
          break;
        fi
      done
      [[ "$import_failed" == "false" ]] || { IndentDec; continue; }
    fi

    BuildOrUpdatePackage "${pkg_cfg[name]}"
    if [[ $? != $SUCCESS ]]; then
      Err "Faild to update/build package ${pkg_cfg[name]}"
      #TODO: Report error per mail
      IndentDec
      continue;
    fi

  IndentDec
  done

  IndentRst
}

function RemovePackgesWoConfig() {
    Info "Starting removing of packages without config..."
    IndentInc

    Info "Resolving dependencies, this could take a while"
    PackagesGetAurDeps
    [[ "$?" == $SUCCESS ]] \
      || ErrFatal "Error while resolving dependencies" 

    local packages_aur_deps=(${__result[@]})

    for p in $(ls $repo_dir/*.pkg* 2> /dev/null); do
      PkgGetName "$p"
      local has_config=false
      Info "Checking package $(txt_bold)$__result$(txt_reset)"
      IndentInc

      for dep in ${packages_aur_deps[@]}; do
        if [[ "$dep" == "$__result" ]]; then
          has_config=true
          break;
        fi
      done

      if [[ "$has_config" == "true" ]]; then
        Info "Package $__result has config, skipping..."
      else
        Info "Package $__result has no config, deleting..."
      fi
      IndentDec
    done

    IndentRst
}

#Arguments parsing

if [[ $# < 3 ]]; then
  PrintUsage "Not enough arguments"
fi

#Parse args
while [[ $# > 0 ]]; do
  case $1 in
    "--pkg-configs")
      [[ $# > 1 ]] || PrintUsage "Missing path for --pkg-configs"
      shift
      pkg_configs_dir="$1"
      [[ ! -f "$1" ]] || PrintUsage "$1 is no directory"
      [[ -d "$1" ]] || PrintUsage "Configuration directory $pkg_configs_dir doesn't exists"
      ;;
    "--repo-dir")
      [[ $# > 1 ]] || PrintUsage "Missing path for --repo-dir"
      shift
      repo_dir="$1"
      [[ ! -f "$1" ]] || PrintUsage "$1 is no directory"
      [[ -d "$1" ]] || PrintUsage "Configuration directory $repo_dir doesn't exists"
      ;;
    "--work-dir")
      [[ $# > 1 ]] || PrintUsage "Missing path for --work-dir"
      shift
      work_dir="$1"
      [[ ! -f "$1" && ! -d "$1" ]] || PrintUsage "work directory should not already exists"
      ;;
    "--action")
      [[ $# > 1 ]] || PrintUsage "Missing argument for --action"
      shift
      action="$1"
      ;;
    "--repo-name")
      [[ $# > 1 ]] || PrintUsage "Missing argument for --repo-name"
      shift
      repo_name="$1"
      ;;
    "--admin-mail")
      [[ $# > 1 ]] || PrintUsage "Missing argument for --admin-mail"
      shift
      admin_mail="$1"
      ;;
    "--debug")
      verbose=true
      ;;
    "--help")
      PrintUsage ""
      ;;
    *)
      PrintUsage "Unknown option $1" 
      ;;
  esac
  shift
done


#Return variable
__result=""

#constants
#Server from which missing gpg keys will be downloaded
readonly gpg_keyserver="hkp://pgp.mit.edu"
readonly ERROR=-1
readonly SUCCESS=0

#Vars that depend on parsed args
repo_db="$repo_dir/$repo_name.db.tar.xz"
work_dir="${work_dir:-"$HOME/.cache/aur-repo-buildserver/work_dir"}"
repo_name="${repo_name:-aur-prebuilds-repo}"
log_file="/tmp/test.txt"
action="$action"
verbose="${verbose:-false}"

#Mail report stuff
admin_mail="${admin_mail:-}"
global_log_txt_path="$work_dir/global_log.txt"
global_log_html_path="$work_dir/global_log.html"

#Other global vars
indent=0



########## Setup ##########

#Check for empty required arguments
if [[ -z "$repo_dir" || -z "$pkg_configs_dir" || -z "$action" ]]; then
  PrintUsage "Missing at least one required argument"
fi

mkdir -p "$work_dir" \
  || ErrFatal "Failed to create working directory $work_dir"

#Setup global logging
echo -n > "$global_log_txt_path" \
  || ErrFatal "Error while creating $global_log_txt_path"

#Check action
case $action in
  "build")
    #Process all configs and update/build the packages
    ProcessPackageConfigs
    ;;
  "clean")
    RemovePackgesWoConfig
    ;;
  *)
    PrintUsage "Invalid argument ($action) for --action"
    ;;
esac


#Check if any package changed and send mail
#Check if there are unhandled error that must be forwarded to the server admin 

CleanUp
exit 0