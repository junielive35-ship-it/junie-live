# Superseded by Hermes profile distribution

This directory was the original seed material for Junie Live profile setup.
It has been superseded by `hermes/distribution/`, which is a Hermes-native
profile distribution with a `distribution.yaml` manifest.

- **Canonical profile asset source**: `hermes/distribution/`
- **Install**: `hermes profile install hermes/distribution --name junie-live --alias`
- **Update**: `hermes profile update junie-live`

This directory is kept for migration compatibility. All operational scripts,
tests, and docs now reference `hermes/distribution/` instead. New changes
should be made in `distribution/` and mirrored here only if necessary for
backwards compatibility with active profiles that may reference
`initialization/` paths in their runtime state.
