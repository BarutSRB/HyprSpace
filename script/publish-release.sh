#!/bin/bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

build_version=""
cask_git_repo_path=""
site_git_repo_path=""
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --cask-git-repo-path) cask_git_repo_path="$2"; shift 2;;
        --site-git-repo-path) site_git_repo_path="$2"; shift 2;;
        *) echo "Unknown option $1"; exit 1;;
    esac
done

if test -z "$build_version"; then
    echo "--build-version flag is mandatory" > /dev/stderr
    exit 1
fi

if ! test -d "$cask_git_repo_path"; then
    echo "--cask-git-repo-path is a mandatory flag that must point to existing directory" > /dev/stderr
    exit 1
fi

# site_git_repo_path is optional for HyprSpace (upstream AeroSpace has a separate site repo)
if [ -n "$site_git_repo_path" ] && ! test -d "$site_git_repo_path"; then
    echo "--site-git-repo-path must point to existing directory if provided" > /dev/stderr
    exit 1
fi

./run-tests.sh
./build-release.sh --build-version "$build_version"

git tag -a "v$build_version" -m "v$build_version" && git push git@github.com:BarutSRB/HyprSpace.git "v$build_version"
link="https://github.com/BarutSRB/HyprSpace/releases/new?tag=v$build_version"
open "$link" || { echo "$link"; exit 1; }
sleep 1
open -R "./.release/HyprSpace-v$build_version.zip"

echo "Please upload .zip and .dmg to GitHub release and hit Enter"
read -r

# Generate both hyprspace and hyprspace-dev casks with GitHub URLs
for cask_name in hyprspace hyprspace-dev; do
    ./script/build-brew-cask.sh \
        --cask-name "$cask_name" \
        --zip-uri "https://github.com/BarutSRB/HyprSpace/releases/download/v$build_version/HyprSpace-v$build_version.zip" \
        --build-version "$build_version"

    cp -r ".release/$cask_name.rb" "$cask_git_repo_path/Casks/$cask_name.rb"
done

# Optional: Copy site files if site repo path is provided
if [ -n "$site_git_repo_path" ]; then
    rm -rf "${site_git_repo_path:?}/*" # https://www.shellcheck.net/wiki/SC2115
    cp -r .site/* "$site_git_repo_path"
fi

echo ""
echo "========================================="
echo "Release published successfully!"
echo "========================================="
echo "Next steps:"
echo "1. Go to $cask_git_repo_path and commit the updated casks"
if [ -n "$site_git_repo_path" ]; then
    echo "2. Go to $site_git_repo_path and commit the updated site"
fi
