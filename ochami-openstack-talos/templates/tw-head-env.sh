# tw-head-env.sh — the HEAD NODE entry point. Source this one; it finds the rest.
#
#   head$ source ~/tw-head-env.sh
#   head$ echo '[ -f ~/tw-head-env.sh ] && . ~/tw-head-env.sh' >> ~/.bashrc
#
# It loads, in this order, whichever of these exist beside it in $HOME:
#
#   tw-head-vars-env.sh        §5.1    the eleven TW_*, generated on the devbox
#                                      from tw-vars-env.sh and scp'd across.
#                                      §5.12 appends TW_EXT_IF to it
#   tw-head-talos-env.sh       §10.3   TALOSCONFIG and KUBECONFIG
#   tw-head-inference-env.sh   §14.3a  tw_infer, tw_ask — the model endpoint
#
# ⚠ EACH IS INERT UNTIL THE SECTION THAT WRITES IT. That is the point of the
# `if [ -f … ]` guards: this file is copied to the head in §5, three sections
# before the first of its dependants exists, and it must not complain about
# files the reader has not reached yet.
#
# ═════════════════════════════════════════════════════════════════════════════
# THE NAMING RULE
# ═════════════════════════════════════════════════════════════════════════════
#
#   tw-*         this rig's files, on the DEVBOX      (~/tw/)
#   tw-head-*    this rig's files, on the HEAD node   (~/)
#   *-env.sh     SOURCE it.  Anything else you RUN.
#
# `ls ~/tw-head-*-env.sh` is therefore a complete inventory of what a login
# shell on the head loads. On the PTR these files will sit in a home directory
# next to somebody else's, which is the reason for the prefix.
#
# ═════════════════════════════════════════════════════════════════════════════
# WHY THIS FILE EXISTS SEPARATELY FROM THE VALUES
# ═════════════════════════════════════════════════════════════════════════════
#
# tw-head-vars-env.sh is GENERATED (§5.1) and appended to (§5.12). Keeping the
# hooks out of it means it can be regenerated from the devbox at any point
# without losing them — and that §10 and §14 add a file rather than edit one.
#
# Before this split, §14's helper was hooked into §10's file, which was hooked
# into §5's. A three-deep chain works, and it is invisible: the only way to
# know what a login shell actually loads is to open three files in order.
#
# ~ rather than $HOME, because §5.1 writes the head's files from a heredoc on
# the DEVBOX — and a heredoc expands $HOME to the devbox's home directory.

for _tw_f in tw-head-vars-env.sh tw-head-talos-env.sh tw-head-inference-env.sh; do
  if [ -f "$HOME/$_tw_f" ]; then
    . "$HOME/$_tw_f"
  fi
done
unset _tw_f

# ⚠ Legacy names, from before the tw-head-* convention. A half-done rename
# leaves the old file on disk with nothing sourcing it, and the only symptom is
# an unset variable — `kubectl` saying `localhost:8080` two sections later.
# Interactive shells only: stray stdout in a non-interactive shell breaks the
# `ssh head '…'` commands §§8–14 use.
for _tw_old in head-env.sh talos-env.sh tw-inference-env.sh; do
  if [ -f "$HOME/$_tw_old" ]; then
    case $- in *i*) printf 'tw: WARNING — ~/%s is a pre-rename name and is NOT sourced. See §5.1.\n' \
                           "$_tw_old" ;; esac
  fi
done
unset _tw_old
