# zsql release checklist

This is the owner-facing contract for a public zsql release. Do not create or
push a tag until every required item is complete.

## 1. Resolve release metadata

- [ ] Choose the software license and add its canonical `LICENSE` file.
- [ ] Confirm GitHub recognizes the selected license.
- [ ] Set `.version` in `build.zig.zon` and the guarded `package_version` in
  `build.zig` to the same semantic version.
- [ ] Move shipped entries out of `Unreleased` in the public release notes or
  prepare the GitHub release notes from the local changelog.
- [ ] Confirm `README.md` installation and minimum Zig version are current.

The license item is intentionally unresolved. Legal terms are an owner choice;
automation must not select them.

## 2. Verify the candidate locally

Run the deterministic contract from a clean `main` checkout:

```sh
git status --short
git pull --ff-only origin main
zig build release-verify
git diff --check
```

`release-verify` covers formatting, default and SQLite builds/tests, version
integrity, checked queries, examples, separate-package consumers, clean-prefix
installation, and a Zig-fetched manifest payload. It must finish without
ignored failures.

## 3. Verify PostgreSQL against a live server

The deterministic aggregate cannot prove network, authentication, TLS, COPY,
cancellation, pool, migration, or protocol recovery behavior. Run:

```sh
ZSQL_PG_URL='postgres://…' zig build test-postgres
ZSQL_PG_URL='postgres://…' zig build run-postgres-pool-example
```

Then confirm the tip-of-`main` GitHub Actions run is green. The CI PostgreSQL 16
service is the authoritative shared evidence for the tagged commit.

## 4. Verify the tag payload before publishing

- [ ] Confirm `git rev-parse HEAD` equals `git rev-parse origin/main`.
- [ ] Confirm the intended tag version equals `build.zig.zon` without a `v`
  prefix mismatch (`v0.1.0` tag corresponds to package `0.1.0`).
- [ ] Create an annotated tag locally; do not force or rewrite an existing tag.
- [ ] Run `zig fetch` against the exact tag URL and record the resulting package
  hash in the release notes.
- [ ] Build a fresh consumer using that tag, not a path dependency.
- [ ] Push the tag only after all checks above pass.

Example fetch shape after a tag exists:

```sh
zig fetch --save=zsql git+https://github.com/oswalpalash/zsql.git#v0.1.0
```

## 5. Post-release checks

- [ ] Confirm GitHub Actions completed successfully for the tag/commit.
- [ ] Confirm the GitHub release links to the immutable tag and package hash.
- [ ] Repeat the README installation in an empty project.
- [ ] Open the next `Unreleased` section before merging further public changes.

Never force-push a release tag or rewrite a published package version.
