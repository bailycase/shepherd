# Self-hosted dispatch registration on master

GitHub requires a `workflow_dispatch` workflow to exist on the repository's default branch
before accepting dispatches targeting another branch. This bootstrap registers the exact
`release-build.yml` input schema used by the reviewed Nightly Self-hosted implementation.

Master predates Nightly's `scripts/release.py`, engine staging scripts and shared packaging
workflow. Do not migrate those contracts merely to register dispatch. Master's copy of
`release-build.yml` is deliberately registration-only: it runs a small stdlib refusal script
on Ubuntu, without secrets, self-hosted scheduling, signing, building or publication. Running
this copy fails with a registration-only notice, regardless of supplied inputs.

A dispatch with `ref: nightly` executes **nightly's** workflow and scripts, not these default-
branch copies. After the Nightly PR lands, its implementation verifies an active Nightly
Release parent/attempt before scheduling Self-hosted and uses the existing `shepherd-release`
label. The hosted reusable call also resolves Nightly's full worker, not master's stub.

## Rollout and checks

1. Review and merge this narrow bootstrap into `master`; leave its existing `release.yml`
   and all signing/feed contracts untouched.
2. Review and merge the separate Nightly Self-hosted PR (#236), then coordinate authorized live
   local-success and safe-fallback checks. A merge into Nightly triggers a real release;
   these are not no-publication smoke tests.
3. Configure required owner reviews/branch protection separately. Nightly's CODEOWNERS file
   alone does not enforce review requirements.

Run `python3 -m unittest discover -s Tests/Release -v` here. The focused bootstrap tests prove
input-schema compatibility, read-only hosted refusal and no dependencies on Nightly's missing
release machinery. YAML parsing and a clean diff supplement those checks. They do not prove
GitHub's live workflow registration, cancellation or cross-run artifact semantics.

No live dispatch, runner access, credential access or signing is required to prepare this PR.
The intentionally different worker/script copies are a registration fence, not a backport of
Nightly releases to master.
