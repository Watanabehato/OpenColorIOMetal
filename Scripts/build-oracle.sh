#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
upstream="${1:-build/upstream}"
revision="$(python3 -c 'import json; print(json.load(open("UPSTREAM.json"))["commit"])')"
if [ ! -d "$upstream/.git" ]; then
  git init "$upstream"
  git -C "$upstream" remote add origin https://github.com/AcademySoftwareFoundation/OpenColorIO.git
fi
git -C "$upstream" fetch --depth 1 origin "$revision"
git -C "$upstream" checkout --detach FETCH_HEAD
test "$(git -C "$upstream" rev-parse HEAD)" = "$revision"
cmake -S "$upstream" -B build/oracle -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/build/oracle-install" \
  -DOCIO_BUILD_APPS=OFF -DOCIO_BUILD_TESTS=OFF -DOCIO_BUILD_GPU_TESTS=OFF \
  -DOCIO_BUILD_DOCS=OFF -DOCIO_BUILD_PYTHON=ON -DOCIO_BUILD_JAVA=OFF \
  -DOCIO_BUILD_OPENFX=OFF -DBUILD_SHARED_LIBS=OFF \
  -DOCIO_INSTALL_EXT_PACKAGES=ALL \
  -DPython_EXECUTABLE="$(command -v python3)"
cmake --build build/oracle --parallel 3
cmake --install build/oracle
PYTHONPATH="$PWD/build/oracle/src/bindings/python${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import PyOpenColorIO as o; print(o.GetVersion())'
