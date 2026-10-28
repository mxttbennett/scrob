# Deployment to feed1-prod

- The `mxttbennett/scrob` fork is deployed by `mxttbennett/streamstack` to the separate Compose project in `/opt/scrob`.
- Streamstack watches GitHub Releases from this fork. A branch update or Git tag without a GitHub Release does not deploy Scrob.
- `.github/workflows/release.yml` runs semantic-release on `main` and publishes a `vX.Y.Z` tag and GitHub Release when the Conventional Commit history warrants one. Confirm the release workflow succeeded before expecting a deployment.
- Streamstack builds the release source for `linux/arm64` and transfers the image to feed1-prod; this repo does not need to publish a container image for that deployment.
- Preserve the `/opt/scrob` Compose project and `.env`; Streamstack changes only the `scrob` service image reference. Keep the `scrob_db_data` and `scrob_scrob_data` named volumes intact. Streamstack backs up PostgreSQL before upgrades and restores it if health checks fail.
