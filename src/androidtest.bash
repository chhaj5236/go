#!/usr/bin/env bash
# Copyright 2014 The Go Authors. All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

# For testing Android.
# The compiler runs locally, then a copy of the GOROOT is pushed to a
# target device using adb, and the tests are run there.

set -e
ulimit -c 0 # no core files

if [ ! -f make.bash ]; then
	echo 'androidtest.bash must be run from $GOROOT/src' 1>&2
	exit 1
fi

if [ -z $GOOS ]; then
	export GOOS=android
fi
if [ "$GOOS" != "android" ]; then
	echo "androidtest.bash requires GOOS=android, got GOOS=$GOOS" 1>&2
	exit 1
fi

if [ -n "$GOARM" ] && [ "$GOARM" != "7" ]; then
	echo "android only supports GOARM=7, got GOARM=$GOARM" 1>&2
	exit 1
fi

export CGO_ENABLED=1
unset GOBIN

# Do the build first, so we can build go_android_exec and cleaner.
# Also lets us fail early before the (slow) adb push if the build is broken.
. ./make.bash --no-banner
export GOROOT=$(dirname $(pwd))
export PATH=$GOROOT/bin:$PATH
GOOS=$GOHOSTOS GOARCH=$GOHOSTARCH go build \
	-o ../bin/go_android_${GOARCH}_exec \
	../misc/android/go_android_exec.go

export pkgdir=$(dirname $(go list -f '{{.Target}}' runtime))
if [ "$pkgdir" = "" ]; then
	echo "could not find android pkg dir" 1>&2
	exit 1
fi

export ANDROID_TEST_DIR=/tmp/androidtest-$$

function cleanup() {
	rm -rf ${ANDROID_TEST_DIR}
}
trap cleanup EXIT

# Push GOROOT to target device.
#
# The adb sync command will sync either the /system or /data
# directories of an android device from a similar directory
# on the host. We copy the files required for running tests under
# /data/local/tmp/goroot. The adb sync command does not follow
# symlinks so we have to copy.
export ANDROID_PRODUCT_OUT="${ANDROID_TEST_DIR}/out"
FAKE_GOROOT=$ANDROID_PRODUCT_OUT/data/local/tmp/goroot
mkdir -p $FAKE_GOROOT
mkdir -p $FAKE_GOROOT/pkg
cp -a "${GOROOT}/src" "${FAKE_GOROOT}/"
cp -a "${GOROOT}/test" "${FAKE_GOROOT}/"
cp -a "${GOROOT}/lib" "${FAKE_GOROOT}/"
cp -a "${pkgdir}" "${FAKE_GOROOT}/pkg/"

# In case we're booting a device or emulator alongside androidtest.bash
# wait for it to be ready. adb wait-for-device is not enough, we have
# wait for sys.boot_completed.
echo '# Waiting for android device to be ready'
adb wait-for-device shell 'while [[ -z $(getprop sys.boot_completed) ]]; do sleep 1; done;'

echo '# Syncing test files to android device'
adb $GOANDROID_ADB_FLAGS shell mkdir -p /data/local/tmp/goroot
time adb $GOANDROID_ADB_FLAGS sync data &> /dev/null

export CLEANER=${ANDROID_TEST_DIR}/androidcleaner-$$
cp ../misc/android/cleaner.go $CLEANER.go
echo 'var files = `' >> $CLEANER.go
(cd $ANDROID_PRODUCT_OUT/data/local/tmp/goroot; find . >> $CLEANER.go)
echo '`' >> $CLEANER.go
go build -o $CLEANER $CLEANER.go
adb $GOANDROID_ADB_FLAGS push $CLEANER /data/local/tmp/cleaner
adb $GOANDROID_ADB_FLAGS shell /data/local/tmp/cleaner

echo ''

# Run standard tests.
bash run.bash --no-rebuild
