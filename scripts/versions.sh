#!/usr/bin/env bash
# Source pins: no floating branch or fallback is permitted.
# This file is sourced by env.sh; consumers use all variables below.
# shellcheck disable=SC2034
AOSP_TAG=android-4.4.4_r2
AOSP_MANIFEST_URL=https://android.googlesource.com/platform/manifest
REPO_URL=https://gerrit.googlesource.com/git-repo
REPO_REV=97dc5c1bd9527c2abe2183b16a4b7ef037dc34a7 # signed v2.54 release commit
LEGACY_IMAGE=ubuntu:14.04@sha256:881afbae521c910f764f7187dbfbca3cc10c26f8bafa458c76dda009a901c29d
