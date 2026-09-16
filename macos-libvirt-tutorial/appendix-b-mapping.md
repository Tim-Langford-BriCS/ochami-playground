# Appendix B — Mapping to the upstream docs and our automation

Use this to jump between the four tellings of the same story: the upstream
docs, this manual tutorial, and the two automated labs in sibling repos.
The natural learning path is **this tutorial (by hand) → ochami-lab (bash)
→ ochami-iac (OpenTofu + Ansible)** — same system, increasing automation.

| This tutorial | Upstream guide | Upstream tutorial | ochami-iac (`~/work/brics/ochami-iac`) | ochami-lab (`~/work/brics/ochami-lab`) |
|---|---|---|---|---|
| §1 Lima host VM | (assumed Linux host) | Part 0.4/0.5 | `lima/hypervisor.yaml`, `make up` | `lima/ochami-head.yaml`, `make up` ¹ |
| §2 host preparation | §1.2 | Part 0.4 package list | `scripts/bootstrap-hypervisor.sh`, `make bootstrap` | `scripts/10-prereqs.sh` |
| §3 the two networks | §1 network XMLs | Part 0.6.2.b/c | `tofu/libvirt-guide/networks.tf`, `make infra` | (single route-mode net) `scripts/20-…` ¹ |
| §4 head node VM | §1.1 kickstart (→ our Appendix A) | Part 0.6.2.d | `tofu/libvirt-guide/head.tf` (cloud-init disk), `make infra` | n/a — the Lima VM *is* the head ¹ |
| §5 installing OpenCHAMI | §2 | Part 1.1–1.9 | `ansible/roles/openchami_install`, `make configure` | `scripts/20-install-openchami.sh` |
| §6 node discovery | §3.1 | Part 2.2 | `ansible/roles/openchami_discovery` | `scripts/30-discover-static.sh` |
| §7 image building | §3.2 | Part 2.3–2.4 | `ansible/roles/openchami_images` | `scripts/40-build-image.sh` |
| §8 boot parameters | §3.3 | Part 2.5 | `ansible/roles/openchami_boot` (first half) | `scripts/50-boot-params.sh` |
| §9 cloud-init | §3.4 | Part 2.7 | `ansible/roles/openchami_boot` (second half) | `scripts/55-cloud-init.sh` |
| §10 boot the compute | §4 | Part 2.6 + 2.8 | `tofu/libvirt-guide/computes.tf`, `make boot` | `scripts/60-compute-vm.sh` |
| §11 troubleshooting | scattered | scattered | `docs/01-execution-log.md`, `docs/02-learnings-vs-verbatim.md` | `docs/01-milestones.md`, `docs/02-troubleshooting.md` |
| §12 teardown | §5 | — | `make unboot` / `destroy-infra` / `destroy` | `make destroy` |

¹ ochami-lab follows the *main tutorial's* bare-metal-head topology (the
Lima VM is the head node; computes are nested inside it), not the guide's
host/head-VM split — that's the main structural difference between the two
labs.

Related reading in this repo:

- [../openchami-summary.md](../openchami-summary.md) — what OpenCHAMI is,
  history, architecture, relevance to BriCS/PTR.
- [../openchami-tutorial-notes.md](../openchami-tutorial-notes.md) — the
  upstream tutorial annotated section-by-section, with the full
  tutorial-vs-guide drift table and our execution results.
- [../upstream/](../upstream/) — verbatim mirrors of both upstream pages,
  pinned to the site commit this work was based on.
