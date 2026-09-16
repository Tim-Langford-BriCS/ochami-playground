# Appendix C — Two ways to drive libvirt, and which one to learn

Throughout this tutorial you create VMs and networks with `virsh` and
`virt-install` run **as your own user, with no `sudo`** (set up in §2.2:
join the `libvirt` group, export `LIBVIRT_DEFAULT_URI=qemu:///system`).
You could instead have prefixed every command with `sudo`. Both work.
This appendix explains the difference, says which is the *standard* choice,
and — because you're heading for an OpenStack deployment — shows why the
style we picked is also the right mental model for AWS or OpenStack.

## The two styles

**Style A — run as root (`sudo`).** libvirt resolves its default
connection URI from *who is asking*: the root user's default is
`qemu:///system` (the system-wide daemon that owns real bridges and VMs),
so `sudo virsh …` "just works" with no extra setup. Simple, but you are
managing the hypervisor as the all-powerful root account.

**Style B — run as an unprivileged user (what this tutorial uses).** Your
login user is *not* root, so two things must be arranged:

- **Identity/authorization.** The system daemon is guarded by polkit. A
  shipped rule grants members of the `libvirt` group access to the
  `org.libvirt.unix.manage` action — so `sudo usermod -aG libvirt "$USER"`
  turns you into an authorized caller *without* being root.
- **Which daemon.** An unprivileged user's *default* URI is
  `qemu:///session` — a throwaway per-user daemon with its own, empty set of
  VMs and networks. That is the trap behind "my networks vanished when I
  dropped `sudo`". Exporting `LIBVIRT_DEFAULT_URI=qemu:///system` pins your
  commands to the real system daemon.

| | Style A — `sudo` (root) | Style B — user + group + URI |
|---|---|---|
| Who you are to libvirt | root (everything) | yourself, scoped by group |
| How access is granted | being root | polkit rule for the `libvirt` group |
| Default daemon | `qemu:///system` automatically | `qemu:///session` unless you set `LIBVIRT_DEFAULT_URI` |
| Where the guest process runs | the `qemu` user¹ | the `qemu` user¹ (identical) |
| Setup cost | none | one `usermod`, one env var (§2.2) |
| Principle | works, but root-for-everything | least privilege |

¹ Under `qemu:///system` the VM itself runs as the unprivileged `qemu`
user in *both* styles (that's why §4.2's `setfacl` is needed either way) —
the only thing that differs is who the *client* is.

## Which is "the standard"?

**Style B.** libvirt's own documentation, the distro packaging (the
`libvirt` group and its polkit rule exist precisely for this), and the
desktop tools (`virt-manager` expects group membership, not `sudo`) all
treat unprivileged-user-in-`libvirt`-group as the normal way to operate.
`sudo` everywhere is fine for a throwaway lab, but it violates least
privilege and isn't how shared or production hosts are run.

## Why this matters for AWS / OpenStack

Here's the payoff. On a cloud you **never `sudo` to create a VM** — there
is no root account to become. You are an *authenticated client with a
scoped identity*, pointing a CLI or Terraform at an API endpoint. Style B
is a small-scale rehearsal of exactly that pattern; Style A has no clean
cloud equivalent (it's the moral equivalent of doing everything as the
cloud root/admin account, which every provider warns against).

The pieces line up almost one-to-one:

| Concept | libvirt (Style B) | OpenStack | AWS |
|---|---|---|---|
| Your identity | `libvirt` group membership | Keystone user + project + role | IAM user / assumed role |
| What you're allowed to do | polkit rule on `org.libvirt.unix.manage` | Keystone RBAC (`policy.yaml`) | IAM policy |
| Endpoint + identity carried in the environment | `LIBVIRT_DEFAULT_URI` | `OS_AUTH_URL` etc. from `openrc.sh` / `clouds.yaml` | `AWS_PROFILE` / `AWS_DEFAULT_REGION` from `~/.aws/*` |
| The client you actually run | `virsh`, `virt-install` | `openstack`, Terraform/OpenTofu | `aws`, Terraform/OpenTofu |
| "Become root to do it" | *not needed* | *doesn't exist* | *doesn't exist* |

So the habit this tutorial builds — *set your context in the environment,
then run clean client commands under a scoped identity* — is the same habit
you'll use to stand up the PTR cluster. When you replicate this on the
StackHPC OpenStack, you won't touch `virsh`: you'll `source` an `openrc`
file (or select a `clouds.yaml` entry), then drive OpenTofu/Ansible against
the Nova/Neutron APIs. `LIBVIRT_DEFAULT_URI=qemu:///system` is the training
wheels for `OS_AUTH_URL=…`.

⚠ **The two planes on the real thing** (see §0 for the vocabulary). On the
PTR, OpenStack stands up the **control plane / substrate** — the head-node
instance and its networks — via that API. The control plane (OpenCHAMI on
the head) then provisions the **worker plane / bare-metal** compute nodes
via Redfish/DHCP/PXE — the same boot chain you build by hand in §§5–10.
Style B is about how you talk to the *substrate's* infrastructure API; the
OpenCHAMI mechanics of the *worker plane* are identical to this tutorial.

## If you'd rather use `sudo`

Nothing stops you: skip the `LIBVIRT_DEFAULT_URI` export in §2.2 and prefix
every `virsh`/`virt-install` in this guide with `sudo`. It will all work.
You just won't be rehearsing the cloud pattern, and you'll be running your
lab hypervisor as root. For a learning lab that's a defensible trade; for
the road to OpenStack, Style B is the better muscle memory.
