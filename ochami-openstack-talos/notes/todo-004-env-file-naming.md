# todo-004 — one naming convention for every file a shell sources

**Status: done, 15 Aug 2026.** Deferred that morning as cosmetic; picked up the same day, once §14's helper made the cost of *not* doing it visible. This file is now the record of what changed and how to migrate a rig that is already running.

## The rule

| Pattern | Means |
|---|---|
| `tw-*` | ours, on the **devbox**, in `~/tw/` |
| `tw-head-*` | ours, on the **head node**, in `~/` |
| `*-env.sh` | **source** it |
| anything else | **run** it |

Two properties fall out of it, and they are why it was worth ~260 edits:

- `ls ~/tw/*-env.sh` and `ls ~/tw-head-*-env.sh` are **complete inventories of what a login shell loads**. Nothing outside them can change your environment behind your back.
- The prefix says *whose* file it is. On the PTR these will sit in a home directory next to somebody else's.

## What was renamed

| Was | Now | Where |
|---|---|---|
| `tw-env.sh` (values **and** loader) | `tw-vars-env.sh` — values only | devbox |
| — | **`tw-env.sh`** — new, a pure entry point | devbox |
| `tw-helpers.sh` | `tw-helpers-env.sh` | devbox |
| `tw-status.sh` | *unchanged* — it is **run**, not sourced | devbox |
| `head-env.sh` | `tw-head-vars-env.sh` | head |
| — | **`tw-head-env.sh`** — new, a pure entry point | head |
| `talos-env.sh` | `tw-head-talos-env.sh` | head |
| `tw-inference-env.sh` | `tw-head-inference-env.sh` | head |

**One deviation from the shape as first sketched.** The head entry point is `tw-head-env.sh`, not `tw-head.sh`: it is both a head file and a sourced file, so both halves of the rule apply. It also mirrors `tw-env.sh` — on each machine the entry point is the shortest name in its family, which is the one you want to be able to type.

`techwatch-proto-openrc.sh` is deliberately left alone. It is sourced, so the rule says it should be `tw-…-env.sh` — but Horizon generates it under that name, and renaming a file your cloud hands you misrepresents where it came from.

## The change that was not cosmetic

The old files formed a **chain**: `.bashrc` → `head-env.sh` → `talos-env.sh` → `tw-inference-env.sh`, each ending with a hook naming the next. It worked. Two things were wrong with it:

- **Installing §14's helper meant editing §10's file**, written five sections earlier and working fine. Every added helper was a modification to something already correct.
- **Nothing could tell you what a login shell loaded** without opening three files in order and reading to the bottom of each.

Both entry points now name their dependants themselves, guarded by `[ -f … ]`:

```sh
for _tw_f in tw-head-vars-env.sh tw-head-talos-env.sh tw-head-inference-env.sh; do
  if [ -f "$HOME/$_tw_f" ]; then . "$HOME/$_tw_f"; fi
done
```

So the entry point ships in §5.1, three sections before the first of its dependants exists, and §§10 and 14 install a helper by **writing a file** — no hook, no `.bashrc` edit, and the loading order legible in one place.

⚠ **This also removed a latent trap on the devbox.** `tw-env.sh` used to be both the file you must never re-copy *and* the file whose name a hurried reader types. Those two jobs now live in files with deliberately unalike names.

## Migrating a rig that is already running

🛑 **The dangerous step is the devbox one, and it is dangerous in one direction only.** The old `~/tw/tw-env.sh` held your values; the new one does not. `cp` before `mv` destroys every §1.5 answer. **Rename first, copy second.**

```
devbox$ ls -l ~/tw/                                    # look before you touch
devbox$ cp -a ~/tw ~/tw.bak-$(date +%F)                # 30 seconds, undoes everything
devbox$ mv ~/tw/tw-env.sh     ~/tw/tw-vars-env.sh
devbox$ mv ~/tw/tw-helpers.sh ~/tw/tw-helpers-env.sh
devbox$ cp <this-tutorial>/templates/tw-env.sh ~/tw/tw-env.sh
devbox$ echo '[ -f ~/tw/tw-env.sh ] && . ~/tw/tw-env.sh' >> ~/.bashrc
devbox$ source ~/tw/tw-env.sh && tw_check
```

Your `tw-vars-env.sh` still ends with the old `if [ -f … tw-helpers.sh ]` block. Harmless — that file no longer exists, so the `if` does nothing and the entry point loads the helpers — but delete the block next time you open the file, or it reads as the live mechanism.

On the head nothing holds values you typed, so the order does not matter:

```
head$ ls -l ~/*.sh
head$ mv ~/head-env.sh          ~/tw-head-vars-env.sh
head$ mv ~/talos-env.sh         ~/tw-head-talos-env.sh
head$ mv ~/tw-inference-env.sh  ~/tw-head-inference-env.sh
head$ sed -i '/tw-inference-env\.sh/d' ~/tw-head-talos-env.sh   # the old chain hook
head$ sed -i '/talos-env\.sh/d'        ~/tw-head-vars-env.sh    # the other one
```

Then put the entry point in place, from the devbox, the way §5.1 now does:

```
devbox$ scp -i ~/.ssh/tw_ed25519 <this-tutorial>/templates/tw-head-env.sh \
            rocky@${TW_HEAD_FIP}:~/tw-head-env.sh
head$ sed -i '/head-env\.sh/d' ~/.bashrc                        # removes the OLD line
head$ echo '[ -f ~/tw-head-env.sh ] && . ~/tw-head-env.sh' >> ~/.bashrc
```

⚠ **`sed -i '/head-env\.sh/d'` matches `tw-head-env.sh` too.** That is why the old line is deleted *before* the new one is appended. Do it the other way round and you delete the line you just added — and the only symptom is an empty `KUBECONFIG` at your next login.

### Proving it, in a new shell

The check has to run in a **fresh login shell**. The one you migrated in already has everything set, so it would pass whether or not `.bashrc` is right.

```
head$ exit
devbox$ ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP}
head$ echo "$TW_CLUSTER_FQDN | $KUBECONFIG | $(type -t tw_ask)"
⟨captured on first run — expect the FQDN, a kubeconfig path, and "function"⟩
head$ ls ~/tw-head-*-env.sh
⟨captured on first run — expect exactly three files and no pre-rename names⟩
```

**One command, three layers.** `TW_CLUSTER_FQDN` proves §5's values loaded, `KUBECONFIG` proves §10's file did, and `tw_ask` being a *function* proves §14's did — precisely the three-deep chain the entry point replaced. An empty field names the layer that failed.

Non-interactive shells are the other half, and they are the ones that break silently:

```
devbox$ ssh -i ~/.ssh/tw_ed25519 rocky@${TW_HEAD_FIP} 'echo "[$KUBECONFIG]"'
⟨captured on first run — expect the path, and NOTHING else on the line⟩
```

⚠ **Anything printed before the `[` is a bug, not cosmetic.** `scp` and `rsync` read that same stream and fail with `protocol error` or `unexpected tag` — an error naming neither `.bashrc` nor the file that printed. It is why the entry points and the helpers' load banner are all guarded by `case $- in *i*)`.

📌 **The entry points warn about pre-rename filenames rather than sourcing them.** A half-done rename leaves the old file on disk with nothing loading it, and its only symptom is an unset variable several sections later — the failure mode this build has repeatedly found costs the most time and names itself the least. So both entry points check for the old names and say so, in interactive shells only.

## Related

- [`templates/README.md`](../templates/README.md) — the rule, and the full file inventory
- [§1.5](../01-safety-and-access.md) — the devbox entry point and its `.bashrc` line
- [§5.1](../05-install-openchami.md) — the head entry point, `scp`'d beside the generated values file
- [§10.3](../10-boot-the-cluster.md), [§14.3a](../14-vllm-inference.md) — the two sections that now install by writing a file
- [§18](../18-teardown.md) — teardown removes `~/tw/*.sh`, `~/tw-head-*.sh` and both `.bashrc` lines
