#!/bin/sh
set -eu

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] [package] [channel]

Examples:
  $(basename "$0") dotnet-runtime 8.0
  $(basename "$0") aspnetcore-runtime 10.0
  $(basename "$0") dotnet-sdk 8.0 --install
  $(basename "$0") --no-pr dotnet-runtime 8.0
  $(basename "$0") --no-push dotnet-sdk 10.0
  $(basename "$0") --no-commit dotnet-sdk 8.0

Options:
  --no-commit  Do not commit, do not push, do not create PR; update files on master
  --no-push    Commit locally, but do not push and do not create PR
  --no-pr      Push the branch, but do not create PR or comment
  --install    Build and install without asking
  --no-install Skip build/install without asking
  -h, --help   Show this help
EOF
}

get_info_value() {
  key="$1"
  file="$2"

  sed -n "s/^$key=\"\(.*\)\"$/\1/p" "$file" | head -n1
}

set_info_value() {
  key="$1"
  value="$2"
  file="$3"
  tmp="$(mktemp)"

  if ! awk -v key="$key" -v value="$value" '
    $0 ~ "^" key "=" {
      print key "=\"" value "\""
      found = 1
      next
    }

    {
      print
    }

    END {
      if (!found) {
        exit 2
      }
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    die "could not update $key in $file"
  fi

  mv "$tmp" "$file"
}

set_slackbuild_version() {
  version="$1"
  file="$2"
  tmp="$(mktemp)"

  if ! awk -v version="$version" '
    /^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*\$\{VERSION:-[^}]+}/ {
      sub(/\$\{VERSION:-[^}]+}/, "${VERSION:-" version "}")
      found = 1
    }

    {
      print
    }

    END {
      if (!found) {
        exit 2
      }
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    die "could not find VERSION=\${VERSION:-...} in $file"
  fi

  mv "$tmp" "$file"
}

replace_version_in_url() {
  old_version="$1"
  new_version="$2"
  url="$3"

  perl -e '
    my ($old, $new, $url) = @ARGV;
    $url =~ s/\Q$old\E/$new/g;
    print "$url\n";
  ' "$old_version" "$new_version" "$url"
}

ask_install() {
  while :; do
    printf '%s' "Do you want to build and install it? [y/N]: "
    read -r answer

    case "$answer" in
      ""|n|N|no|NO|No)
        echo "Install skipped."
        return 1
        ;;
      y|Y|yes|YES|Yes)
        return 0
        ;;
      *)
        echo "Please answer only y/yes or n/no. Default is no."
        ;;
    esac
  done
}

should_install() {
  case "$INSTALL_MODE" in
    yes)
      return 0
      ;;
    no)
      echo "Install skipped."
      return 1
      ;;
    ask)
      ask_install
      ;;
    *)
      die "invalid install mode: $INSTALL_MODE"
      ;;
  esac
}

commit_update() {
  message="development/$PRGNAM-$CHANNEL: Updated for version $LATEST_VERSION."

  if [ "${COMMIT_SIGNING:-true}" = true ]; then
    git -C "$REPO_ROOT" commit -S --signoff -m "$message"
  else
    git -C "$REPO_ROOT" commit --signoff -m "$message"
  fi
}

create_pr_and_comment() {
  command -v gh >/dev/null 2>&1 \
    || die "GitHub CLI is not installed or not in PATH: gh"

  PR_TITLE="development/$PRGNAM-$CHANNEL: Updated for version $LATEST_VERSION."
  PR_BODY="Updated development/$PRGNAM-$CHANNEL for version $LATEST_VERSION."
  PR_COMMENT="@sbo-bot: build development/$PRGNAM-$CHANNEL"

  echo "Creating pull request:"
  echo "$PR_TITLE"

  PR_URL="$(
    gh pr create \
      --repo "$PR_BASE_REPO" \
      --base "$PR_BASE_BRANCH" \
      --head "$PR_HEAD_OWNER:$BRANCH" \
      --title "$PR_TITLE" \
      --body "$PR_BODY"
  )"

  [ -n "$PR_URL" ] || die "could not create pull request"

  echo "Created pull request:"
  echo "$PR_URL"

  echo "Leaving PR comment:"
  echo "$PR_COMMENT"

  gh pr comment "$PR_URL" \
    --repo "$PR_BASE_REPO" \
    --body "$PR_COMMENT"

  echo "PR comment posted."
}

PRGNAM=""
CHANNEL=""

COMMIT=true
PUSH=true
CREATE_PR=true
INSTALL_MODE=ask

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-commit)
      COMMIT=false
      PUSH=false
      CREATE_PR=false
      ;;
    --no-push)
      PUSH=false
      CREATE_PR=false
      ;;
    --no-pr)
      CREATE_PR=false
      ;;
    --install)
      INSTALL_MODE=yes
      ;;
    --no-install)
      INSTALL_MODE=no
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ -z "$PRGNAM" ]; then
        PRGNAM="$1"
      elif [ -z "$CHANNEL" ]; then
        CHANNEL="$1"
      else
        die "unexpected argument: $1"
      fi
      ;;
  esac

  shift
done

while [ "$#" -gt 0 ]; do
  if [ -z "$PRGNAM" ]; then
    PRGNAM="$1"
  elif [ -z "$CHANNEL" ]; then
    CHANNEL="$1"
  else
    die "unexpected argument: $1"
  fi

  shift
done

PRGNAM="${PRGNAM:-dotnet-runtime}"
CHANNEL="${CHANNEL:-8.0}"
USER="$(whoami)"

ARCH="${ARCH:-$(uname -m)}"
BUILD="${BUILD:-1}"
TAG="${TAG:-_SBo}"
PKGTYPE="${PKGTYPE:-tgz}"
OUTPUT="${OUTPUT:-/tmp}"

REPO_ROOT="${REPO_ROOT:-/home/$USER/Projects/slackbuilds}"
SLACKBUILD_PATH="$REPO_ROOT/development/$PRGNAM-$CHANNEL"
SLACKBUILD_FILE="$SLACKBUILD_PATH/$PRGNAM-$CHANNEL.SlackBuild"
INFO_FILE="$SLACKBUILD_PATH/$PRGNAM-$CHANNEL.info"
BRANCH="development/$PRGNAM-$CHANNEL"

PR_BASE_REPO="${PR_BASE_REPO:-SlackBuildsOrg/slackbuilds}"
PR_BASE_BRANCH="${PR_BASE_BRANCH:-master}"
PR_HEAD_OWNER="${PR_HEAD_OWNER:-RezaT4795}"

[ -d "$REPO_ROOT" ] || die "repository directory does not exist: $REPO_ROOT"

git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository: $REPO_ROOT"

git -C "$REPO_ROOT" diff --quiet \
  || die "working tree has uncommitted changes"

git -C "$REPO_ROOT" diff --cached --quiet \
  || die "index has staged changes"

if [ "$COMMIT" = true ]; then
  echo "Preparing Git branch: $BRANCH"

  git -C "$REPO_ROOT" checkout master
  git -C "$REPO_ROOT" pull --ff-only
  git -C "$REPO_ROOT" checkout -B "$BRANCH"
else
  echo "Preparing master branch without commit mode"

  git -C "$REPO_ROOT" checkout master
  git -C "$REPO_ROOT" pull --ff-only
fi

[ -d "$SLACKBUILD_PATH" ] || die "directory does not exist: $SLACKBUILD_PATH"
[ -f "$SLACKBUILD_FILE" ] || die "SlackBuild file does not exist: $SLACKBUILD_FILE"
[ -f "$INFO_FILE" ] || die ".info file does not exist: $INFO_FILE"

CURRENT_VERSION="$(get_info_value VERSION "$INFO_FILE")"

[ -n "$CURRENT_VERSION" ] || die "could not read VERSION from $INFO_FILE"

case "$PRGNAM" in
  dotnet-sdk)
    LATEST_FIELD="latest-sdk"
    ;;
  dotnet-runtime|aspnetcore-runtime)
    LATEST_FIELD="latest-runtime"
    ;;
  *)
    die "unsupported package name for automatic latest-version lookup: $PRGNAM"
    ;;
esac

LATEST_VERSION="$(
  curl -fsSL https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json \
    | jq -r --arg channel "$CHANNEL" --arg field "$LATEST_FIELD" '
        .["releases-index"][]
        | select(.["channel-version"] == $channel)
        | .[$field]
      '
)"

[ -n "$LATEST_VERSION" ] || die "could not retrieve latest version"
[ "$LATEST_VERSION" != "null" ] || die "could not retrieve latest version for channel $CHANNEL"

printf '%s\n' "Current version is: $CURRENT_VERSION"
printf '%s\n' "Latest version is:  $LATEST_VERSION"

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
  echo "Already up to date."
  git -C "$REPO_ROOT" checkout master
  exit 0
fi

LOWEST_VERSION="$(
  printf '%s\n%s\n' "$CURRENT_VERSION" "$LATEST_VERSION" \
    | sort -V \
    | head -n1
)"

if [ "$LOWEST_VERSION" != "$CURRENT_VERSION" ]; then
  echo "Current version is higher than latest: $CURRENT_VERSION > $LATEST_VERSION"
  echo "Update not needed."
  git -C "$REPO_ROOT" checkout master
  exit 0
fi

echo "Update needed: $CURRENT_VERSION -> $LATEST_VERSION"
echo "Updating $PRGNAM-$CHANNEL to $LATEST_VERSION"

CURRENT_DOWNLOAD_x86_64="$(get_info_value DOWNLOAD_x86_64 "$INFO_FILE")"

[ -n "$CURRENT_DOWNLOAD_x86_64" ] || die "could not read DOWNLOAD_x86_64 from $INFO_FILE"
[ "$CURRENT_DOWNLOAD_x86_64" != "UNSUPPORTED" ] || die "DOWNLOAD_x86_64 is UNSUPPORTED"

NEW_DOWNLOAD_x86_64="$(
  replace_version_in_url "$CURRENT_VERSION" "$LATEST_VERSION" "$CURRENT_DOWNLOAD_x86_64"
)"

if [ "$NEW_DOWNLOAD_x86_64" = "$CURRENT_DOWNLOAD_x86_64" ]; then
  die "download URL did not change; current version was not found in DOWNLOAD_x86_64: $CURRENT_DOWNLOAD_x86_64"
fi

TARBALL="$(basename "$NEW_DOWNLOAD_x86_64")"
TARBALL_PATH="$SLACKBUILD_PATH/$TARBALL"

echo "New download URL:"
echo "$NEW_DOWNLOAD_x86_64"

echo "Downloading $TARBALL..."
curl -fL "$NEW_DOWNLOAD_x86_64" -o "$TARBALL_PATH"

NEW_MD5SUM_x86_64="$(md5sum "$TARBALL_PATH" | awk '{print $1}')"

[ -n "$NEW_MD5SUM_x86_64" ] || die "could not calculate md5sum for $TARBALL_PATH"

echo "New md5sum:"
echo "$NEW_MD5SUM_x86_64"

set_info_value VERSION "$LATEST_VERSION" "$INFO_FILE"
set_info_value DOWNLOAD_x86_64 "$NEW_DOWNLOAD_x86_64" "$INFO_FILE"
set_info_value MD5SUM_x86_64 "$NEW_MD5SUM_x86_64" "$INFO_FILE"

set_slackbuild_version "$LATEST_VERSION" "$SLACKBUILD_FILE"

echo "Updated:"
echo "$INFO_FILE"
echo "$SLACKBUILD_FILE"
echo "$TARBALL_PATH"

if [ "$COMMIT" = true ]; then
  git -C "$REPO_ROOT" add "$INFO_FILE" "$SLACKBUILD_FILE"

  if git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "No Git changes to commit."
  else
    commit_update

    if [ "$PUSH" = true ]; then
      git -C "$REPO_ROOT" push --set-upstream origin "$BRANCH"

      if [ "$CREATE_PR" = true ]; then
        create_pr_and_comment
      else
        echo "PR creation skipped."
      fi
    else
      echo "Push skipped."
      echo "PR creation skipped because push is disabled."
    fi
  fi
else
  echo "Commit skipped."
  echo "Changes were left on master for manual review."
fi

if ! should_install; then
  echo "Removing downloaded tarball:"
  echo "$TARBALL_PATH"
  rm -f "$TARBALL_PATH"
  git -C "$REPO_ROOT" checkout master
  exit 0
fi

PACKAGE_FILE="$OUTPUT/$PRGNAM-$CHANNEL-$LATEST_VERSION-$ARCH-$BUILD$TAG.$PKGTYPE"

echo "Building package..."
cd "$SLACKBUILD_PATH"

sudo bash "$SLACKBUILD_FILE"

[ -f "$PACKAGE_FILE" ] || die "package was not created at expected path: $PACKAGE_FILE"

echo "Installing package:"
echo "$PACKAGE_FILE"

sudo upgradepkg --install-new --reinstall "$PACKAGE_FILE"

echo "Installed:"
echo "$PACKAGE_FILE"

git -C "$REPO_ROOT" checkout master

echo "Removing downloaded tarball:"
echo "$TARBALL_PATH"
rm -f "$TARBALL_PATH"
