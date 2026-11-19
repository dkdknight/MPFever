"""Offline test: the Release build workflow signs with SignPath's test certificate by default, and its test archives can
never be taken for a release's (0.9.2).

2026-11-19: SignPath Foundation accepted MPFever. Their first step is a signature with a self-signed test certificate (signing
policy test-signing); they review the setup, then import the Foundation's certificate (release-signing). Until 0.9.2 the
workflow always asked for release-signing (which has no certificate yet) and required a valid signature (a self-signed one is
never valid for Windows): the first test run could only fail.
Checked here, on .github/workflows/release.yml:
- the start asks for the signing policy, test-signing by default, release-signing offered, and that choice is what SignPath gets;
- with release-signing the signature must be valid (as before), with test-signing only present;
- the test archives are named TEST-SIGNED-MPFever-..., never a name that starts with "MPFever" and ends with ".zip" (the
  updaters up to 0.9.0 take the first such release asset), and their artifact says not to publish them;
- the README's code signing policy no longer says "Applied for".
Run: python tests/test_signpolicy092.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


wf = open(os.path.join(ROOT, ".github", "workflows", "release.yml"), encoding="utf-8").read().replace("\r\n", "\n")
readme = open(os.path.join(ROOT, "README.md"), encoding="utf-8").read()

m = re.search(r"\n      signing_policy:\n(.*?)\n\njobs:", wf, re.S)
check("the start asks for the signing policy", m is not None)
block = m.group(1) if m else ""
check("it is a choice", "type: choice" in block, block)
check("test-signing is offered", "- test-signing" in block, block)
check("release-signing is offered", "- release-signing" in block, block)
check("test-signing is the default", re.search(r"default: test-signing\s*$", block) is not None, block)

check("SignPath gets the chosen policy", "signing-policy-slug: ${{ inputs.signing_policy }}" in wf)
check("no policy written in the request", "signing-policy-slug: release-signing" not in wf)

check("release-signing requires a valid signature",
      "if ($release -and $sig.Status -ne 'Valid') { throw" in wf)
check("every signature must be there", "if (-not $sig.SignerCertificate) { throw" in wf)

check("test archives are prefixed", "$pre = if ($release) { '' } else { 'TEST-SIGNED-' }" in wf)
check("the zips carry the prefix",
      '"${pre}MPFever-$v.zip"' in wf and '"${pre}MPFever-$v-server.zip"' in wf)
check("the hashes name the files made",
      "foreach ($f in \"${pre}MPFever-$v.zip\", \"${pre}MPFever-$v-server.zip\")" in wf)
check("the test artifact says not to publish",
      "format('TEST-SIGNED-MPFever-{0}-do-not-publish', steps.version.outputs.version)" in wf)
check("the signed artifact keeps its name with release-signing",
      "format('MPFever-{0}-signed', steps.version.outputs.version)" in wf)


# the updaters' old rule (0.8.17, 0.9.0): the first asset named MPFever*.zip that is not the server's
def old_rule_takes(name):
    n = name.lower()
    return n.startswith("mpfever") and n.endswith(".zip")


for v in ("0.9.2", "1.0.0"):
    for f in ("TEST-SIGNED-MPFever-%s.zip" % v, "TEST-SIGNED-MPFever-%s-server.zip" % v):
        check("no updater takes " + f, not old_rule_takes(f))

rel = re.search(r"\n  release:\n(.*?)\n    steps:", wf, re.S)
rel = rel.group(1) if rel else ""
check("SignPath can read the job and its artifact (actions: read)", "      actions: read" in rel, rel)
check("the job can still check out the code", "      contents: read" in rel, rel)

check("README: no longer 'Applied for'", "*Applied for:" not in readme)
check("README: says accepted", "SignPath Foundation accepted MPFever" in readme)

print()
print("FAILED: %d" % len(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
