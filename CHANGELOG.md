# Changelog

## [Unreleased]
### Added
- `clear_completed_jobs` deletes only the jobs that have FINISHED
  (`CONFIG_JOB_TERMINAL_STATES`: Completed, Failed, CompletedWithErrors) and
  returns the ids removed. A finished job still holds an iDRAC job-queue slot,
  so a full queue answers the next config job with 409/LC068 while nothing is
  actually running; deleting a finished job frees the slot and destroys
  nothing. It never touches a job that has not finished. This is the safe
  primitive `radfish` has always declared in `Radfish::Core::Jobs` and no
  adapter implemented. (radfish-idrac#7)
- `pending_config_jobs` lists the jobs that have NOT finished, read-only, so a
  caller can see why a queue is blocked before deciding what may be done about
  it. `job_queue` returns the raw queue and never raises.

### Changed
- Documented that `clear_jobs!` and `drain_pending_config_jobs!` are NOT queue
  hygiene: both cancel work that has not finished. Their behaviour is
  unchanged; use `clear_completed_jobs` to free slots.

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
