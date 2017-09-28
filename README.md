# Arch user repository build server

```
This software can be used for running a server that periodically build packages
from the AUR. The resulting artifacts are automatically added into a repository
that can be added to a local pacman.conf. This allows to source out the complete
build process and reducing maintenance time for updating the local system.

Packages that should be build by the server are configured by
config files. The directory that contains theses files is passed with the
--pkg-configs flag. A config files must end with a .config suffix and the
content must look like this:

name = i3blocks
disabled = false

Another argument that is always needed is --repo-dir. This flags is used to
set the directory where the repository should be build/updated. The third required argument
is --action, this flags decides what the build server should do.
For further flags read ahead.

Command line format
  ./buildserver.sh [--pkg-configs packages config dir] [--repo-dir path] [--action action] [OPTION]...

Required argument
  --action  action0,action1... 
  The actions that should be performed by the build server (comma separated).
  Please mind that chaining several action improves performance due to caching.
  For example the dependency resolve results from the clean action can be reused
  by the build action.
  Possible values are the following:
    build 
      This action will build/update all targets defined by a config file in the
      --pkg-configs directory.
    clean 
      This action will delete all packages from the repository that have no
      associated config files in the --pkg-configs directory.

  --repo-dir  path 
    Path must point to an directory where the repo database should be created.
    If in the given directory a database already exists, it will be update.

  --pkg-configs  path 
    Path to a directory that contains multiple package configuration files.


OPTIONS
  --work-dir  path 
    Directory where packages are build.
    Default value is $HOME/.cache/aur-repo-buildserver

  --repo-name  name 
    The name of the repository to create/update.
    This name must be later used as the "repository tag"
    in youre pacman conf e.g.
      [aur-repo] <<< TAG
      SigLevel = ...
      Server = https://...

  --debug 
    Enable output of debugging messages.

  --admin-mail  mail address 
    The mail address of the admin. To this email address a mail
    is send, everytime an error occurs.

  --mail-reporting  mail address 
    This flag enables sending of mails on several events.
    Mails will be send on successfully building or updating a package.
    Also mails will be send, if a error occurs while running this script.
    The mutt application is used to send email, thus it must be configured
    for this feature to work.

  --db-sign-key  KEY-ID 
    Set the GPG key ID that will be used to sign the repository database file.

  --package-sign-key  KEY-ID 
    Set the GPG key ID that will be used to sign the build packages.
    For package signing to work, you need to add the "sign" flag to
    the BUILDENV array inside you're local makepkg.conf.



```