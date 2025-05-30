#! /usr/bin/env bash
# Copyright 2015-2020 The Khronos Group Inc.
# SPDX-License-Identifier: Apache-2.0

# Build WebAssembly with Emscripten in Docker.

# Exit if any command fails.
set -e

function atexit () {
  if [ -z $dockerrunning ]; then
    docker stop emscripten > /dev/null
    docker rm emscripten > /dev/null
  fi
}

function usage() {
  echo "Usage: $0 [Option] [PARAMETER=value] [target...]"
  echo ""
  echo "Build KTX-Software using Emscripten docker package."
  echo "Defaults to building everything (Release config) if no targets specified."
  echo "Options:"
  echo "  --help, -h      Print this usage message."
  echo "  --verbose ,-v   Cause the underlying make to run in verbose mode."
  exit $1
}

# cd repo root so script will work whereever the current directory
path_to_repo_root=..
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/$path_to_repo_root"

for arg in $@; do
  case $arg in
    --help | -h)
      usage 0
      ;;
    --verbose | -v)
      verbose_make="-- VERBOSE=1"
      shift
      ;;
    *\=*)
      # Set parameter from command-line arguments
      eval $arg
      shift ;;
    *)
      targets="$targets --target $arg"
      shift ;;
  esac
done

# Set defaults
CONFIGURATION=${CONFIGURATION:-Release}
FEATURE_DOC=${FEATURE_DOC:-OFF}
FEATURE_JNI=${FEATURE_JNI:-OFF}
FEATURE_LOADTESTS=${FEATURE_LOADTESTS:-OpenGL}
FEATURE_PY=${FEATURE_PY:-OFF}
FEATURE_TOOLS=${FEATURE_TOOLS:-OFF}
PACKAGE=${PACKAGE:-NO}
SUPPORT_SSE=OFF
SUPPORT_OPENCL=${SUPPORT_OPENCL:-OFF}
WERROR=${WERROR:-OFF}

BUILD_DIR=${BUILD_DIR:-build/web-$CONFIGURATION}

trap atexit EXIT SIGINT

# Check if emscripten container is already running as CI will already have started it.
if [ "$(docker container inspect -f '{{.State.Status}}' emscripten 2> /dev/null)" != "running" ]
then
  # Create docker container.

  #   In the event that /src ends up having the same owner as the repo
  # (cwd) on the docker host, which is presumably the user running
  # this script, it is necessary to set the uid/gid used to run the
  # commands in docker. This is because the recent fix for
  # CVE-2022-24765 causes Git to error when the repo owner differs from
  # the user running the command. For details see
  # https://github.blog/2022-04-12-git-security-vulnerability-announced/
  #   When I run docker locally on macOS /src is owned by root which is
  # the default docker user so we don't trip over the CVE fix. However
  # on Travis /src ends up owned by the same uid as the repo on the host.
  # Since .travis.yml starts docker before calling this script, the correct
  # uid is set there. This is retained as an example in case some other
  # system exhibits the same behavior as Travis.
  if [ -n "$TRAVIS" ]; then
    ugids="--user $(id -u):$(id -g)"
  fi
  echo "Starting docker"
  docker run -dit --name emscripten $ugids -v $(pwd):/src emscripten/emsdk bash
else
  echo "Docker running"
  dockerrunning=1
fi

echo "Software versions"
echo '*****************'
docker exec emscripten sh -c "emcc -v; echo '********'"
docker exec emscripten sh -c "cmake --version; echo '********'"
docker exec emscripten sh -c "git --version; echo '********'"

mkdir -p $BUILD_DIR

# emcmake uses the "Unix Makefiles" generator on Linux which does not
# support multiple configurations.
echo "Configure and Build KTX-Software (Web $CONFIGURATION)"

# Uncomment for debugging some generator expressions.
#targets="--target debug_isgnufe1 --target debug_gnufe_ffpcontract"

docker exec emscripten sh -c "emcmake cmake -B$BUILD_DIR . \
    -D CMAKE_BUILD_TYPE=$CONFIGURATION \
    -D KTX_FEATURE_DOC=OFF \
    -D KTX_FEATURE_LOADTEST_APPS=$FEATURE_LOADTESTS \
    -D KTX_WERROR=$WERROR \
  && cmake --build $BUILD_DIR $targets $verbose_make"

if [ "$PACKAGE" = "YES" ]; then
  echo "Pack KTX-Software (Web $CONFIGURATION)"
  # Call cmake rather than cpack so we don't need knowledge of the working
  # directory inside docker.
  docker exec emscripten sh -c "cmake --build $BUILD_DIR --target package"
fi

