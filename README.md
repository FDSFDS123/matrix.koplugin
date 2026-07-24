matrix-helper (musl static, armv7)

This repository contains a small helper service (matrix-helper) that uses matrix-rust-sdk with encryption enabled to provide a local HTTP API for KOReader (or other local clients).

What is included
- Cargo.toml
- src/main.rs (helper scaffold)
- GitHub Actions workflow that cross-builds a musl static ARMv7 (armhf) binary and attempts to build libolm statically.

How to build (via GitHub Actions)
1. Push this repo to GitHub (branch main).
2. Run the "Build linux-armv7-musleabihf (musl static) with E2EE" workflow from the Actions tab or push a commit.
3. Download the artifact from the workflow run (matrix-helper-linux-armv7-musleabihf).

How to run on device
1. Copy the produced binary to your armhf device.
2. Make executable: chmod +x matrix-helper
3. Run: ./matrix-helper
4. Use the KOReader plugin to POST /login, POST /send and GET /rooms/:room_id/messages on http://127.0.0.1:3030

Notes and troubleshooting
- If the build fails in Actions, inspect the logs — common failures:
  - matrix-sdk feature names changed: edit Cargo.toml to match the SDK version you need.
  - libolm build issues: examine the cmake output; you may need to pass additional CMake flags.
- If you want a debug/dev build on your machine, you can run the container locally (see workflow) with Docker (requires binfmt/qemu) or adjust to a non-cross build.

If you prefer, I can:
- Push this scaffold into a repo for you (if you want) or produce a ZIP of the files.
- Adjust matrix-sdk version and update main.rs to the exact API calls if you tell me which matrix-sdk version you prefer.
- Troubleshoot specific build errors from GH Actions logs — paste the error logs and I will fix the workflow / code to match.
