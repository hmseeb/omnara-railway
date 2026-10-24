# omnara-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/omnara)

Container image for the [Omnara](https://github.com/omnara-ai/omnara) control plane on Railway:
upstream's unmodified v0.2.10 api, worker, maintenance and web, in one container behind one nginx.

Railway cannot share a volume between services, and Omnara's api, worker and maintenance all
mount the same memory directory, so they run together here.

The instance is locked to the deployer. Signup and password reset are always off. On boot,
before nginx opens, the container creates the one admin account from `OMNARA_ADMIN_EMAIL` and the
generated `OMNARA_ADMIN_PASSWORD` through Omnara's own endpoints on loopback. Editing the password
variable and redeploying changes the password.

- `image/` - Dockerfile, `boot.sh`, nginx config
- `test/contract.sh` - contract test, run in CI before every push to `ghcr.io/hmseeb/omnara-railway`

Omnara is Apache-2.0 licensed by Omnara. This wrapper is Apache-2.0 too.
