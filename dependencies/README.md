# Fresh integration changes

`fresh-fc.bundle` contains the committed FC editor fixes on top of the upstream
`base_revision` in `dependencies.json`. That manifest pins the final commit and
the SHA-256 of the bundle. The source remains the declared upstream repository;
the bundle supplies the additional commits without requiring a private fork.

`tools/bootstrap_dependencies.py` clones the source, verifies and fetches this
bundle, and checks out the exact final revision. Use `--fresh-url` or
`FC_FRESH_MIRROR` for an accessible upstream mirror. Existing input checkouts are
validated and never reset by bootstrap.

To update an existing clean Fresh checkout deliberately:

```sh
git -C ../editor-fresh fetch "$PWD/dependencies/fresh-fc.bundle" refs/heads/fc-editor-workflow
git -C ../editor-fresh checkout --detach FETCH_HEAD
```

When changing Fresh, commit the fix in its checkout, update the
`fc-editor-workflow` branch to that commit, and regenerate the bundle from the
unchanged upstream base through that branch. Update both the manifest revision
and bundle fingerprint. `test/test_fresh_bundle.py` proves that the final checkout
can be reconstructed using only the base and this bundle.
