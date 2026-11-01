# Changelog

## [0.11.3] - 2026-11-01

### Fixed
- `enable_vnc!` raised `ArgumentError` on Ruby 3: its string-keyed hash bound to `set_idrac_attributes`' keyword args. Pass it in braces; spec calls it unstubbed.

## [0.11.2] - 2026-11-01
### Added
- `set_idrac_attributes(attributes)` sets iDRAC-only attributes (Redfish-style names,
  e.g. `"VNCServer.1.Enable"`) without touching host power. iDRAC9 uses a PATCH to
  the Manager Attributes resource (no job). On 404 (iDRAC8) it falls back to an SCP
  import with Target `IDRAC`, `ShutdownType` `NoReboot`, and `HostPowerState` set to
  the host's current power state. `enable_vnc!(password:, port: 5901)` builds on it.

### Fixed
- Debug and Faraday request logging redact password values in JSON bodies.

### Notes
- `set_system_configuration_profile(reboot: false)` sends `HostPowerState: "Off"`,
  which powers the host off after the import. Behaviour unchanged; use
  `set_idrac_attributes` for iDRAC-only changes.

## [Unreleased]
### Fixed
- Development and CI no longer hold json at 2.x. The `unknown keyword:
  quirks_mode` failure came from activesupport below 8.1, whose JSON encoder
  passes `quirks_mode:` to `JSON.generate` — json 3 removed it. CI now runs a
  matrix over both supported ends of the gemspec's `activesupport >= 7.0`
  range: activesupport 8.1 with json 3, and activesupport 7.2 with json 2.
  Documented the incompatible pair in the README, since it affects anyone
  loading `active_support/core_ext`, not just this gem's specs.

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
