.PHONY: test format check build verify notarize clean

test:
	swift test

format:
	swift format --in-place --recursive Sources Tests Package.swift

check:
	swift format lint --strict --recursive Sources Tests Package.swift
	swift test

build:
	Scripts/build-app.sh

verify:
	Scripts/verify-release.sh

notarize:
	Scripts/notarize.sh

clean:
	swift package clean
	rm -rf outputs .build/release-* .build/verify-release
