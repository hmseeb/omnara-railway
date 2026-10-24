# omnara-railway

Container image for the [Omnara](https://github.com/omnara-ai/omnara) control plane on Railway:
upstream's unmodified v0.2.10 api, worker, maintenance and web, in one container behind one nginx.

Railway cannot share a volume between services, and Omnara's api, worker and maintenance all
mount the same memory directory, so they run together here.

The instance is locked to the deployer. A setup link for `OMNARA_ADMIN_EMAIL` (token in
`OMNARA_SETUP_TOKEN`) is the only way to create an account. Signup turns off once that account exists.

- `image/` - Dockerfile, `boot.sh`, nginx config
- `test/contract.sh` - contract test, run in CI before every push to `ghcr.io/hmseeb/omnara-railway`

Omnara is Apache-2.0 licensed by Omnara. This wrapper is Apache-2.0 too.
