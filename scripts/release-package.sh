#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/release-package.sh --package <ssz|rlp|mpt> --version <semver> [options]

Options:
  --ref <git-ref>          Source commit to split (default: HEAD)
  --publish                Fast-forward the release branch and create the tag
  --remote <name>          Git remote used by --publish (default: origin)
  --fetch-url <git-url>    Public Zig fetch URL without #tag; required to publish
  --github-output <path>   Append package, branch, tag, commit, and hash outputs
  -h, --help               Show this help

Without --publish the command is a no-push dry run. It still creates and tests
the exact deterministic split commit selected by --ref.
EOF
}

fail() {
    echo "release-package: $*" >&2
    exit 1
}

log() {
    echo "release-package: $*" >&2
}

package=""
version=""
source_ref="HEAD"
publish=false
remote="origin"
fetch_url=""
github_output=""
release_ref=""

while (( $# > 0 )); do
    case "$1" in
        --package)
            (( $# >= 2 )) || fail "--package requires a value"
            package="$2"
            shift 2
            ;;
        --version)
            (( $# >= 2 )) || fail "--version requires a value"
            version="$2"
            shift 2
            ;;
        --ref)
            (( $# >= 2 )) || fail "--ref requires a value"
            source_ref="$2"
            shift 2
            ;;
        --publish)
            publish=true
            shift
            ;;
        --remote)
            (( $# >= 2 )) || fail "--remote requires a value"
            remote="$2"
            shift 2
            ;;
        --fetch-url)
            (( $# >= 2 )) || fail "--fetch-url requires a value"
            fetch_url="$2"
            shift 2
            ;;
        --github-output)
            (( $# >= 2 )) || fail "--github-output requires a value"
            github_output="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n "$package" ]] || fail "--package is required"
[[ -n "$version" ]] || fail "--version is required"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] ||
    fail "version must be semantic version text without a leading v"
[[ "$version" != "0.0.0" ]] || fail "0.0.0 is a development placeholder, not a release"

case "$package" in
    ssz|rlp|mpt) ;;
    *) fail "unsupported package: $package" ;;
esac

command -v git >/dev/null || fail "git is required"
command -v zig >/dev/null || fail "zig is required"

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "run inside the evm.zig repository"
cd "$repo_root"

source_commit=$(git rev-parse --verify "${source_ref}^{commit}" 2>/dev/null) ||
    fail "source ref is not a commit: $source_ref"
prefix="pkg/$package"
release_branch="release/$package"
tag="${package}-v${version}"

if [[ "$publish" == true ]]; then
    [[ -n "$fetch_url" ]] || fail "--fetch-url is required with --publish"
    [[ -z "$(git status --porcelain)" ]] || fail "publishing requires a clean worktree"

    main_ref="refs/remotes/${remote}/main"
    git show-ref --verify --quiet "$main_ref" || fail "missing $main_ref; fetch main first"
    git merge-base --is-ancestor "$source_commit" "$main_ref" ||
        fail "source commit must be reachable from ${remote}/main"
fi

work_root=$(mktemp -d "${TMPDIR:-/tmp}/evmz-release-${package}.XXXXXX")
source_dir="$work_root/source"
split_dir="$work_root/split"

cleanup() {
    if [[ -n "$release_ref" ]]; then
        git update-ref -d "$release_ref" 2>/dev/null || true
    fi
    if [[ -e "$split_dir/.git" ]]; then
        git worktree remove --force "$split_dir" || true
    fi
    if [[ -e "$source_dir/.git" ]]; then
        git worktree remove --force "$source_dir" || true
    fi
    rmdir "$work_root" 2>/dev/null || true
}
trap cleanup EXIT

log "materializing source $source_commit"
git worktree add --quiet --detach "$source_dir" "$source_commit"

manifest="$source_dir/$prefix/build.zig.zon"
[[ -f "$manifest" ]] || fail "missing $prefix/build.zig.zon at $source_commit"
manifest_version=$(awk -F'"' '/^[[:space:]]*\.version = "/ { print $2; exit }' "$manifest")
[[ -n "$manifest_version" ]] || fail "unable to read package version from $prefix/build.zig.zon"
[[ "$manifest_version" == "$version" ]] ||
    fail "requested version $version does not match manifest version $manifest_version"

if [[ "$package" == "mpt" ]]; then
    log "testing MPT against the source commit's local RLP"
    (
        cd "$source_dir/$prefix"
        zig build test --fork=../rlp --summary all
        zig build -Doptimize=ReleaseFast test --fork=../rlp --summary all
    )
fi

log "splitting $prefix"
split_commit=$(git subtree split --quiet --prefix="$prefix" "$source_commit")
repeat_commit=$(git subtree split --quiet --prefix="$prefix" "$source_commit")
[[ "$split_commit" == "$repeat_commit" ]] || fail "subtree split was not deterministic"

git worktree add --quiet --detach "$split_dir" "$split_commit"
[[ -f "$split_dir/build.zig.zon" ]] || fail "split tree is not rooted at the package manifest"
[[ ! -e "$split_dir/pkg" ]] || fail "split tree unexpectedly contains the monorepo pkg directory"

hash_before=$(zig fetch "$split_dir")
log "testing isolated split $split_commit"
(
    cd "$split_dir"
    zig build test --summary all
    zig build -Doptimize=ReleaseFast test --summary all
    if [[ "$package" == "rlp" || "$package" == "mpt" ]]; then
        zig build fuzz --summary all
    fi
)
hash_after=$(zig fetch "$split_dir")
[[ "$hash_before" == "$hash_after" ]] || fail "package hash changed after building"
package_hash="$hash_after"

if [[ "$publish" == true ]]; then
    remote_branch_commit=$(
        git ls-remote --heads "$remote" "refs/heads/$release_branch" |
            awk 'NR == 1 { print $1 }'
    )
    remote_tag_commit=$(
        git ls-remote --tags "$remote" "refs/tags/$tag" |
            awk 'NR == 1 { print $1 }'
    )

    if [[ -n "$remote_branch_commit" ]]; then
        release_ref="refs/evmz-release/${package}-$$"
        git fetch --quiet --force "$remote" "refs/heads/$release_branch:$release_ref"
        git merge-base --is-ancestor "$release_ref" "$split_commit" ||
            fail "$release_branch would not fast-forward to $split_commit"
    fi

    if [[ -n "$remote_tag_commit" && "$remote_tag_commit" != "$split_commit" ]]; then
        fail "existing tag $tag points at $remote_tag_commit, not $split_commit"
    fi

    if [[ "$remote_branch_commit" != "$split_commit" ]]; then
        if [[ -z "$remote_tag_commit" ]]; then
            log "atomically publishing $release_branch and $tag"
            git push --atomic "$remote" \
                "$split_commit:refs/heads/$release_branch" \
                "$split_commit:refs/tags/$tag"
        else
            log "fast-forwarding $release_branch"
            git push "$remote" "$split_commit:refs/heads/$release_branch"
        fi
    elif [[ -z "$remote_tag_commit" ]]; then
        log "publishing tag $tag"
        git push "$remote" "$split_commit:refs/tags/$tag"
    else
        log "$release_branch and $tag already point at $split_commit"
    fi

    remote_hash=""
    for attempt in 1 2 3 4 5; do
        if remote_hash=$(zig fetch "${fetch_url}#${tag}"); then
            break
        fi
        if [[ "$attempt" != 5 ]]; then
            log "remote fetch attempt $attempt failed; retrying"
            sleep 2
        fi
    done
    [[ -n "$remote_hash" ]] || fail "unable to fetch published tag $tag"
    [[ "$remote_hash" == "$package_hash" ]] ||
        fail "remote package hash $remote_hash does not match tested hash $package_hash"
fi

if [[ -n "$github_output" ]]; then
    {
        echo "package=$package"
        echo "version=$version"
        echo "release_branch=$release_branch"
        echo "tag=$tag"
        echo "source_commit=$source_commit"
        echo "split_commit=$split_commit"
        echo "package_hash=$package_hash"
    } >>"$github_output"
fi

echo "package=$package"
echo "version=$version"
echo "release_branch=$release_branch"
echo "tag=$tag"
echo "source_commit=$source_commit"
echo "split_commit=$split_commit"
echo "package_hash=$package_hash"
