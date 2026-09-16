# tw-env.sh — the DEVBOX entry point. Source this one; it finds the rest.
#
#   devbox$ mkdir -p ~/tw
#   devbox$ cp <this-tutorial>/templates/tw-env.sh         ~/tw/tw-env.sh
#   devbox$ cp <this-tutorial>/templates/tw-vars-env.sh    ~/tw/tw-vars-env.sh
#   devbox$ cp <this-tutorial>/templates/tw-helpers-env.sh ~/tw/tw-helpers-env.sh
#   devbox$ source ~/tw/tw-env.sh
#
# and once, so it comes back at every login (§1.5):
#
#   devbox$ echo '[ -f ~/tw/tw-env.sh ] && . ~/tw/tw-env.sh' >> ~/.bashrc
#
# ═════════════════════════════════════════════════════════════════════════════
# THE NAMING RULE
# ═════════════════════════════════════════════════════════════════════════════
#
#   tw-*         this rig's files, on the DEVBOX      (~/tw/)
#   tw-head-*    this rig's files, on the HEAD node   (~/)
#   *-env.sh     SOURCE it.  Anything else you RUN — tw-status.sh is a script.
#
# So `ls ~/tw/*-env.sh` is a complete list of what a login shell loads, and
# nothing outside that list can change your environment behind your back. On a
# shared machine the prefix also says which files are this rig's and which are
# somebody else's.
#
# ═════════════════════════════════════════════════════════════════════════════
# WHICH FILE IS SAFE TO RE-COPY, AND WHICH IS NOT
# ═════════════════════════════════════════════════════════════════════════════
#
#   tw-env.sh (this file)   a dispatcher. No values at all.  ALWAYS safe
#   tw-helpers-env.sh       only tw_* functions.             ALWAYS safe
#   tw-vars-env.sh          YOURS — every §1.5 answer, plus what §4.5 and §4.6
#                           append later.                    NEVER re-copy
#
# 🛑 IF YOU ARE UPGRADING FROM A SINGLE-FILE tw-env.sh, RENAME BEFORE YOU COPY.
#    The old tw-env.sh held your values; this one does not. Copying this over
#    it destroys §1.5's answers. The order is: mv first, cp second.
#
#      devbox$ mv ~/tw/tw-env.sh ~/tw/tw-vars-env.sh          # your values
#      devbox$ mv ~/tw/tw-helpers.sh ~/tw/tw-helpers-env.sh   # if present
#      devbox$ cp <this-tutorial>/templates/tw-env.sh ~/tw/   # the dispatcher
#      devbox$ source ~/tw/tw-env.sh && tw_check
#
# WHY A DISPATCHER AT ALL. So that adding a file later is a `cp` and not an
# edit to something you have filled in. The head node has the same shape and
# needs it more: §10 and §14 each drop a new file next to tw-head-env.sh, and
# neither section has to touch a file that already works.

TW_DIR="${TW_DIR:-$HOME/tw}"

# Order matters: values first, then the helpers that read them.
for _tw_f in tw-vars-env.sh tw-helpers-env.sh; do
  if [ -f "$TW_DIR/$_tw_f" ]; then
    . "$TW_DIR/$_tw_f"
  else
    # Interactive shells only. This file is sourced from .bashrc, and stray
    # stdout in a NON-interactive shell breaks scp, rsync and `ssh host '…'`
    # in ways that name neither this file nor the shell.
    case $- in *i*) printf 'tw: %s/%s not found — cp <this-tutorial>/templates/%s %s/\n' \
                           "$TW_DIR" "$_tw_f" "$_tw_f" "$TW_DIR" ;; esac
  fi
done
unset _tw_f

# ⚠ A HALF-DONE RENAME IS THE WORST STATE THIS FILE CAN BE IN: the old file is
# still on disk, nothing sources it, and the only symptom is an unset variable
# three sections later. So say it out loud rather than leave it to be deduced.
for _tw_old in tw-helpers.sh; do
  if [ -f "$TW_DIR/$_tw_old" ]; then
    case $- in *i*) printf 'tw: WARNING — %s/%s is a pre-rename name and is NOT sourced. Delete it.\n' \
                           "$TW_DIR" "$_tw_old" ;; esac
  fi
done
unset _tw_old
