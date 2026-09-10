# Changelog

## [0.11.0] - 2026-09-10
### Changed
- **Breaking:** `set_boot_override` and the `boot_to_*` helpers take `persistence:`
  instead of `enabled:`, matching the vocabulary radfish and the adapters use.
  `persistence: nil` still means `"Once"`. Callers passing `enabled:` must update.
  (#12, thanks @davispuh)

### Fixed
- iDRAC8 firmware install takes the image URI from the upload response's
  `@odata.id`, falling back to the `Location` header, and installs with
  `NowAndReboot` rather than `Now`. (#16)

### Added
- CI on push and pull request, and a release workflow publishing to RubyGems
  through trusted publishing (OIDC), so no API key is stored in the repository.
