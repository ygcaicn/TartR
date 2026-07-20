.PHONY: test format check compat build smoke dmg manifest verify verify-dmg verify-manifest source notarize clean

test:
	swift test

format:
	swift format --in-place --recursive Sources Tests Package.swift

check:
	swift format lint --strict --recursive Sources Tests Package.swift
	swift test

compat:
	Scripts/verify-tart-cli.sh

build:
	Scripts/build-app.sh
	Scripts/package-dmg.sh

smoke:
	Scripts/smoke-app.sh

dmg:
	Scripts/package-dmg.sh

manifest:
	Scripts/generate-update-manifest.sh

verify:
	Scripts/verify-release.sh
	Scripts/verify-dmg.sh

verify-dmg:
	Scripts/verify-dmg.sh

verify-manifest:
	Scripts/verify-update-manifest.sh

source:
	Scripts/package-source.sh

notarize:
	Scripts/notarize.sh

clean:
	swift package clean
	rm -rf outputs .build/release-* .build/verify-release
