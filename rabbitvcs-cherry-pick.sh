#!/usr/bin/env bash
# Adds TortoiseGit-style cherry-pick to RabbitVCS (Git) Show Log:
#   - branch name at the top left (click: Browse References, right-click: HEAD,
#     FETCH_HEAD, All, All basic refs, All local branches) and "All Branches"
#   - "Cherry Pick this commit..." / "Cherry Pick selected commits..."
#   - Cherry Pick window: Pick/Squash/Edit/Skip, Pick ALL, Up/Down/Add,
#     add "cherry picked from", Revision Files / Commit Message / Log tabs,
#     Conflict Files with Edit conflicts / Resolved / Resolve using, Commit,
#     Amend, Done and Abort
# Usage:  sudo bash rabbitvcs-cherry-pick.sh           (install / upgrade)
#         sudo bash rabbitvcs-cherry-pick.sh --remove  (restore original)
set -euo pipefail

TARGET_DIR="/usr/lib/python3/dist-packages"
FILES=(rabbitvcs/ui/log.py rabbitvcs/util/contextmenuitems.py rabbitvcs/vcs/git/gittyup/client.py)
NEW_FILES=(rabbitvcs/ui/cherrypick.py rabbitvcs/ui/refbrowser.py)
BACKUP_SUFFIX=".orig-cherrypick"
PATCH_ID="18f0ad6d9523"
STAMP="rabbitvcs/.cherry-pick-patch"

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
cd "$TARGET_DIR"

if [[ "${1:-}" == "--remove" ]]; then
  for f in "${FILES[@]}"; do
    [[ -f "$f$BACKUP_SUFFIX" ]] && mv "$f$BACKUP_SUFFIX" "$f"
  done
  rm -f "${NEW_FILES[@]}" "$STAMP"
  echo "Original RabbitVCS files restored."
  exit 0
fi

is_patched() { grep -qi "cherry" "$1"; }

up_to_date=true
[[ -f "$STAMP" && "$(cat "$STAMP")" == "$PATCH_ID" ]] || up_to_date=false
for f in "${FILES[@]}"; do is_patched "$f" || up_to_date=false; done
for f in "${NEW_FILES[@]}"; do [[ -f "$f" ]] || up_to_date=false; done
if $up_to_date; then
  echo "Cherry-pick patch is already installed and up to date."
  exit 0
fi

# Start from the original files: back up unpatched files (fresh install or
# after an apt upgrade), restore patched ones (upgrade of this patch)
for f in "${FILES[@]}"; do
  if ! is_patched "$f"; then
    cp -p "$f" "$f$BACKUP_SUFFIX"
  elif [[ -f "$f$BACKUP_SUFFIX" ]]; then
    cp -p "$f$BACKUP_SUFFIX" "$f"
  else
    echo "Cannot find the original of $f. Reinstall RabbitVCS: sudo apt install --reinstall rabbitvcs-core"
    exit 1
  fi
done
rm -f "${NEW_FILES[@]}"

patch -p1 --forward <<'PATCH'
diff --git a/rabbitvcs/ui/cherrypick.py b/rabbitvcs/ui/cherrypick.py
new file mode 100644
index 0000000..04434d6
--- /dev/null
+++ b/rabbitvcs/ui/cherrypick.py
@@ -0,0 +1,1712 @@
+#
+# This is an extension to the Nautilus file manager to allow better
+# integration with the Subversion source control system.
+#
+# RabbitVCS is free software; you can redistribute it and/or modify
+# it under the terms of the GNU General Public License as published by
+# the Free Software Foundation; either version 2 of the License, or
+# (at your option) any later version.
+#
+# RabbitVCS is distributed in the hope that it will be useful,
+# but WITHOUT ANY WARRANTY; without even the implied warranty of
+# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
+# GNU General Public License for more details.
+#
+# You should have received a copy of the GNU General Public License
+# along with RabbitVCS;  If not, see <http://www.gnu.org/licenses/>.
+#
+"""
+Git "Cherry Pick" window, a port of TortoiseGit's rebase dialog in
+cherry-pick mode (TortoiseProc/RebaseDlg.cpp):
+
+- commit list with Pick / Squash / Edit / Skip per commit, "Pick ALL" and
+  friends, Up / Down / Add, and 'add "cherry picked from"'
+- "Revision Files", "Commit Message" and "Log" tabs
+- one Continue button whose meaning follows the stage:
+  Continue -> Commit (after a conflict) / Amend (Edit) -> Done
+- conflicts are listed in a "Conflict Files" tab with check boxes and the
+  usual Edit conflicts / Resolved / Resolve conflict using ... menu
+- Abort restores the branch to where it was before the cherry-pick
+
+"""
+
+import json
+import locale
+import os
+import shutil
+import subprocess
+import tempfile
+import time
+
+from rabbitvcs import gettext
+
+_ = gettext.gettext
+
+PICK = "pick"
+SQUASH = "squash"
+EDIT = "edit"
+SKIP = "skip"
+ACTION_NAMES = {PICK: _("Pick"), SQUASH: _("Squash"), EDIT: _("Edit"), SKIP: _("Skip")}
+NEXT_ACTION = {PICK: SKIP, SKIP: EDIT, EDIT: SQUASH, SQUASH: PICK}
+
+COMMIT = "commit"
+RETRY = "retry"
+
+CHOOSE = "choose"
+START = "start"
+CONTINUE = "continue"
+CONFLICT = "conflict"
+SQUASH_CONFLICT = "squash_conflict"
+EDIT_STAGE = "edit"
+SQUASH_EDIT = "squash_edit"
+ERROR = "error"
+FINISH = "finish"
+DONE = "done"
+
+BUTTON_TEXT = {
+    CHOOSE: _("Continue"),
+    START: _("Continue"),
+    CONTINUE: _("Continue"),
+    ERROR: _("Continue"),
+    SQUASH_CONFLICT: _("Continue"),
+    CONFLICT: _("Commit"),
+    EDIT_STAGE: _("Amend"),
+    SQUASH_EDIT: _("Commit"),
+    FINISH: _("Finish"),
+    DONE: _("Done"),
+}
+
+APP_NAME = "RabbitVCS"
+SETTINGS_FILE = "cherrypick.json"
+CONFLICT_CODES = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}
+STATUS_NAMES = {
+    "A": _("Added"),
+    "M": _("Modified"),
+    "D": _("Deleted"),
+    "R": _("Rename"),
+    "C": _("Copy"),
+    "T": _("Modified"),
+}
+
+MSG_STASH = _("The current working tree is not clean.\nDo you want to stash the changes?")
+MSG_STASH_POP = _("Do you want to stash pop now?")
+MSG_USER_DATA = _(
+    "User name and email must be set before commit.\nDo you want to set these now?"
+)
+MSG_MERGE_COMMIT = _('"%s" - "%s"\nis a merge commit.\n\nWhich parent do you want to pick?')
+MSG_EMPTY = _(
+    "The current commit will be empty (e.g., due to conflict resolution). "
+    "Skip the commit or keep the message only commit?"
+)
+MSG_FAILED = _(
+    "Cherry-pick failed (please see log in the cherry pick/rebase dialog "
+    "for details)! Skip this commit?"
+)
+MSG_ABORT = _("Are you sure you want to abort the rebase process?")
+MSG_CONFLICTED = _("One or more files are in a conflicted state.")
+MSG_EMPTY_MESSAGE = _("The commit message must not be empty.")
+MSG_EMPTY_SUBJECT = _(
+    "Found an empty commit message. You have to enter one or rebase cannot proceed."
+)
+MSG_RESOLVE = _("Are you sure you want to mark the conflicted file(s) as resolved?")
+MSG_CONFLICT_HINT = _(
+    'It looks as if there is a conflict hint (a line like "# Conflicts:") in '
+    "your commit message. This hint is automatically added by Git for cli "
+    "users and there is no need to keep it.\n\nDo you want to ignore this "
+    "warning and keep these lines or abort committing in order to edit the "
+    "commit message?"
+)
+MSG_UNRECOVERABLE = _("An unrecoverable error occurred.")
+MSG_PROGRESS = _("Rebasing... (%d/%d)")
+
+
+class Git:
+    def __init__(self, path):
+        self.cwd = path if os.path.isdir(path) else os.path.dirname(path)
+        self.env = dict(os.environ, LC_ALL="C", GIT_EDITOR="true")
+        self.root = self.output("rev-parse", "--show-toplevel") or self.cwd
+
+    def run(self, *args):
+        proc = subprocess.run(
+            ["git"] + list(args),
+            cwd=self.root if hasattr(self, "root") else self.cwd,
+            env=self.env,
+            capture_output=True,
+            text=True,
+            check=False,
+        )
+        return proc.returncode, (proc.stdout + proc.stderr).rstrip()
+
+    def output(self, *args):
+        code, out = self.run(*args)
+        return out if code == 0 else ""
+
+    def ok(self, *args):
+        return self.run(*args)[0] == 0
+
+    def head(self):
+        return self.output("rev-parse", "-q", "--verify", "HEAD")
+
+    def current_branch(self):
+        return self.output("symbolic-ref", "--short", "-q", "HEAD")
+
+    def is_clean(self):
+        return self.ok("diff", "--quiet") and self.ok("diff", "--cached", "--quiet")
+
+    def has_ref(self, name):
+        return self.ok("rev-parse", "-q", "--verify", name)
+
+    def unmerged(self):
+        out = self.output("diff", "--name-only", "--diff-filter=U")
+        return [line for line in out.splitlines() if line]
+
+    def stages(self, name):
+        out = self.output("ls-files", "-u", "--", name)
+        return {int(line.split()[2]) for line in out.splitlines() if line}
+
+    def path(self, name):
+        return os.path.join(self.root, name)
+
+    def git_dir_file(self, name):
+        path = self.output("rev-parse", "--git-path", name)
+        return path if os.path.isabs(path) else os.path.join(self.root, path)
+
+    def read_git_file(self, name):
+        try:
+            with open(self.git_dir_file(name), errors="replace") as handle:
+                return handle.read()
+        except OSError:
+            return ""
+
+    def commit_with_message(self, args, message):
+        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
+            handle.write(message)
+        try:
+            return self.run(*(list(args) + ["-F", handle.name]))
+        finally:
+            os.unlink(handle.name)
+
+
+class Entry:
+    def __init__(self, fields):
+        self.hash, parents, self.author, self.email, date, raw = fields
+        # like TortoiseGit: subject = first line, body = the rest (it keeps
+        # the blank separator line), so subject + "\n" + body is the message
+        self.subject, _sep, self.body = raw.strip("\n").partition("\n")
+        self.parents = parents.split()
+        self.date = int(date or 0)
+        self.action = PICK
+        self.done = False
+        self.current = False
+
+    def message(self):
+        return (self.subject + "\n" + self.body).strip()
+
+    def short(self):
+        return self.hash[:7]
+
+
+def load_entries(git, hashes):
+    """Commit details in the given order."""
+    out = git.output(
+        "log",
+        "--no-walk=unsorted",
+        "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%B%x01",
+        *hashes,
+    )
+    entries = []
+    for record in out.split("\x01"):
+        fields = record.strip("\n").split("\x00")
+        if len(fields) == 6:
+            entries.append(Entry(fields))
+    return entries
+
+
+class CherryPickSession:
+    """
+    The cherry-pick state machine. ``entries`` are in log order (newest
+    first) and are applied from the bottom up, like TortoiseGit. Every
+    question goes through ``ui``.
+
+    """
+
+    def __init__(self, git, entries, ui):
+        self.git = git
+        self.entries = entries
+        self.ui = ui
+        self.stage = CHOOSE
+        self.index = len(entries)
+        self.add_cherry_picked_from = False
+        self.squash_message = ""
+        self.squash_first = None
+        self.current_empty = False
+        self.auto_skip_failed = False
+        self.stashed = False
+        self.orig_head = None
+        self.status = ""
+
+    # helpers
+
+    def current(self):
+        if 0 <= self.index < len(self.entries):
+            return self.entries[self.index]
+        return None
+
+    def commit_id(self):
+        return len(self.entries) - self.index
+
+    def next_is_squash(self):
+        index = self.index - 1
+        while index >= 0:
+            action = self.entries[index].action
+            if action == SQUASH:
+                return True
+            if action != SKIP:
+                return False
+            index -= 1
+        return False
+
+    def mark_current(self):
+        for i, entry in enumerate(self.entries):
+            entry.current = i == self.index and self.stage != DONE
+        if 0 <= self.index < len(self.entries):
+            self.status = MSG_PROGRESS % (self.commit_id(), len(self.entries))
+
+    def log(self, text):
+        if text:
+            self.ui.log(text)
+
+    def reset_hard(self):
+        code, out = self.git.run("reset", "--hard")
+        if code:
+            self.ui.error(out)
+        return code == 0
+
+    def is_empty_commit(self, entry):
+        parent = entry.parents[0] if entry.parents else None
+        tree = self.git.output("rev-parse", "-q", "--verify", entry.hash + "^{tree}")
+        if parent is None:
+            return tree == "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
+        return tree == self.git.output("rev-parse", "-q", "--verify", parent + "^{tree}")
+
+    def staged_is_empty(self, amend=False):
+        base = "HEAD~1" if amend else "HEAD"
+        return self.git.ok("diff", "--cached", "--quiet", base)
+
+    # actions in the list
+
+    def set_action(self, rows, action):
+        """Pick/Squash/Edit/Skip for rows that are not done or current."""
+        last = len(self.entries) - 1
+        if action == SQUASH and last in rows:
+            return
+        for row in rows:
+            entry = self.entries[row]
+            if entry.done:
+                continue
+            if entry.current:
+                if action == SKIP and self.stage in (CONFLICT, ERROR):
+                    self.skip_current()
+                continue
+            entry.action = action
+        self.ui.update()
+
+    def cycle_action(self, rows):
+        last = len(self.entries) - 1
+        for row in rows:
+            entry = self.entries[row]
+            if entry.done or entry.current:
+                continue
+            action = NEXT_ACTION[entry.action]
+            if action == SQUASH and row == last:
+                action = PICK
+            entry.action = action
+        self.ui.update()
+
+    def set_all(self, action, selected=None):
+        """Pick/Squash/Edit ALL, or Skip/Squash/Edit unselected."""
+        last = len(self.entries) - 1
+        for row, entry in enumerate(self.entries):
+            if entry.done or entry.current or (selected is not None and row in selected):
+                continue
+            if action == SQUASH and row == last:
+                continue
+            entry.action = action
+        self.ui.update()
+
+    def move(self, rows, up, to_end=False):
+        """Up / Down (Shift: to the top / bottom), like TortoiseGit."""
+        if self.stage != CHOOSE or not rows:
+            return rows
+        rows = sorted(rows)
+        last = len(self.entries) - 1
+        if not to_end and ((up and rows[0] == 0) or (not up and rows[-1] == last)):
+            return rows
+        moved = []
+        ordered = rows if up else list(reversed(rows))
+        for count, row in enumerate(ordered):
+            if up:
+                target = count if to_end else row - 1
+            else:
+                target = last - count if to_end else row + 1
+            self.entries.insert(target, self.entries.pop(row))
+            moved.append(target)
+        self.ui.update()
+        return sorted(moved)
+
+    def add_entries(self, hashes):
+        if self.stage != CHOOSE:
+            return
+        known = {entry.hash for entry in self.entries}
+        new = [e for e in load_entries(self.git, hashes) if e.hash not in known]
+        self.entries[0:0] = new
+        self.index = len(self.entries)
+        self.ui.update()
+
+    # starting
+
+    def check_condition(self):
+        if not self.git.is_clean():
+            if not self.ui.ask_stash():
+                return False
+            self.log("git stash")
+            code, out = self.git.run("stash")
+            if code:
+                self.ui.error(out)
+                return False
+            self.stashed = True
+
+        if not (
+            self.git.output("config", "user.name") and self.git.output("config", "user.email")
+        ):
+            if not self.ui.ask_user_data():
+                return False
+        return True
+
+    def start(self):
+        if not self.entries:
+            return
+        if not self.check_condition():
+            return
+        self.stage = START
+        self.ui.started()
+        self.orig_head = self.git.head()
+        if not self.orig_head:
+            self.log(_("No HEAD found"))
+            self.stage = ERROR
+            self.ui.update()
+            return
+        self.git.run("update-ref", "ORIG_HEAD", self.orig_head)
+        self.log(_("Start Cherry Pick") + "\n")
+        self.stage = CONTINUE
+        self.run()
+
+    def run(self):
+        while self.stage == CONTINUE:
+            self.index -= 1
+            self.mark_current()
+            self.ui.update()
+            self.ui.process_events()
+            if self.index < 0:
+                self.stage = FINISH
+                self.finish()
+                break
+            if not self.do_pick():
+                break
+        self.mark_current()
+        self.ui.update()
+
+    def finish(self):
+        self.status = _("Done")
+        self.stage = DONE
+        for entry in self.entries:
+            entry.current = False
+
+    # one commit (CRebaseDlg::DoRebase)
+
+    def do_pick(self):
+        entry = self.current()
+        mode = entry.action
+        if mode == SKIP:
+            entry.done = True
+            return True
+
+        next_squash = self.next_is_squash()
+        if next_squash or mode != PICK:
+            if self.squash_message:
+                self.squash_message += "\n\n"
+            self.squash_message += entry.subject + "\n" + entry.body.rstrip()
+            if self.add_cherry_picked_from:
+                if entry.body:
+                    self.squash_message += "\n"
+                self.squash_message += f"(cherry picked from commit {entry.hash})"
+        else:
+            self.squash_message = ""
+            self.squash_first = None
+        if next_squash and mode != SQUASH:
+            self.squash_first = (entry.author, entry.email, entry.date)
+
+        nocommit = (next_squash and mode != EDIT) or mode == SQUASH
+
+        self.log(f"{ACTION_NAMES[mode]} {self.commit_id()}: {entry.hash}")
+        self.log(entry.subject)
+        if not entry.subject:
+            self.ui.warn(MSG_EMPTY_SUBJECT)
+            mode = EDIT
+
+        options = []
+        if self.add_cherry_picked_from:
+            options.append("-x")
+        if self.is_empty_commit(entry):
+            options.append("--allow-empty")
+            if mode != SQUASH:
+                self.current_empty = True
+        else:
+            self.current_empty = False
+
+        if len(entry.parents) > 1:
+            titles = []
+            for parent in entry.parents:
+                title = self.git.output("log", "-1", "--format=%s", parent)
+                if len(title) > 20:
+                    title = title[:20] + "..."
+                titles.append(f"{title} ({parent[:7]})")
+            parent = self.ui.ask_parent(entry, titles)
+            if not parent:
+                self.stage = ERROR
+                self.log(MSG_UNRECOVERABLE)
+                return False
+            options += ["-m", str(parent)]
+        if nocommit:
+            options.append("--no-commit")
+
+        while True:
+            code, out = self.git.run("cherry-pick", *(options + [entry.hash]))
+            if code == 0:
+                break
+            self.log(out)
+            if self.git.unmerged():
+                self.stage = SQUASH_CONFLICT if mode == SQUASH else CONFLICT
+                self.ui.enter_conflict(self.conflict_message(entry))
+                return False
+
+            if "commit --allow-empty" in out:
+                choice = self.ui.ask_empty()
+                if choice == COMMIT:
+                    code, out = self.git.run("commit", "--allow-empty", "-C", entry.hash)
+                    self.current_empty = True
+                    break
+                if choice == SKIP and self.reset_hard():
+                    entry.done = True
+                    return True
+                self.stage = ERROR
+                self.log(MSG_UNRECOVERABLE)
+                return False
+
+            if mode == PICK:
+                choice = SKIP
+                if not self.auto_skip_failed:
+                    choice, self.auto_skip_failed = self.ui.ask_failed()
+                    if choice == RETRY:
+                        self.auto_skip_failed = False
+                        continue
+                if choice == SKIP and self.reset_hard():
+                    entry.action = SKIP
+                    entry.done = True
+                    return True
+                self.stage = ERROR
+                self.log(MSG_UNRECOVERABLE)
+                return False
+            if mode == EDIT:
+                self.stage = EDIT_STAGE
+                self.ui.enter_edit(self.edit_message(entry))
+                return False
+            if not self.next_is_squash():
+                self.stage = SQUASH_EDIT
+                self.ui.enter_squash_edit(self.squash_message)
+                return False
+            break
+
+        self.log(out)
+        if mode == PICK:
+            entry.done = True
+            return True
+        if mode == EDIT:
+            self.stage = EDIT_STAGE
+            self.ui.enter_edit(self.edit_message(entry))
+            return False
+        if not self.next_is_squash():
+            self.stage = SQUASH_EDIT
+            self.ui.enter_squash_edit(self.squash_message)
+            return False
+        if mode == SQUASH:
+            entry.done = True
+        return True
+
+    def conflict_message(self, entry):
+        message = self.git.read_git_file("MERGE_MSG")
+        if not message:
+            message = entry.subject + "\n" + entry.body
+        return message
+
+    def edit_message(self, entry):
+        if self.add_cherry_picked_from:
+            return self.git.output("log", "-1", "--format=%B", "HEAD")
+        return entry.subject + "\n" + entry.body
+
+    def reset_parent_for_squash(self, message):
+        self.squash_message = message
+        code, out = self.git.run("reset", "--soft", "HEAD~1", "--")
+        if code:
+            self.ui.error(out)
+
+    # the Continue / Commit / Amend / Done button
+
+    def verify_no_conflict(self):
+        unmerged = self.git.unmerged()
+        if unmerged:
+            self.ui.warn(MSG_CONFLICTED)
+            self.ui.select_conflict(unmerged[0])
+            return False
+        return True
+
+    def has_conflict_hint(self, message):
+        cleanup = self.git.output("config", "core.cleanup") or "default"
+        if cleanup in ("verbatim", "whitespace", "scissors"):
+            return False
+        char = self.git.output("config", "core.commentchar") or "#"
+        if f"\n{char} Conflicts:\n{char}\t" not in message:
+            return False
+        return self.ui.ask_conflict_hint_abort()
+
+    def stage_files(self, files):
+        """
+        files: list of (path, checked, status). Checked files go into the
+        commit; unchecked ones stay as local changes, like TortoiseGit.
+
+        """
+        readd, redelete = [], []
+        for name, checked, status in files:
+            exists = os.path.lexists(self.git.path(name))
+            if checked:
+                if exists:
+                    self.git.run("add", "-f", "--", name)
+                else:
+                    self.git.run("rm", "--cached", "-q", "--ignore-unmatch", "--", name)
+            elif status == STATUS_NAMES["A"]:
+                self.git.run("rm", "--cached", "-q", "--", name)
+                readd.append(name)
+            else:
+                self.git.run("reset", "-q", "--", name)
+                if status == STATUS_NAMES["D"] and not exists:
+                    redelete.append(name)
+        return readd, redelete
+
+    def continue_clicked(self, message="", files=None):
+        if self.stage == DONE:
+            self.restore_stash()
+            self.ui.close()
+            return
+        if self.stage == CHOOSE:
+            self.start()
+            return
+        if self.stage == ERROR:
+            return
+
+        entry = self.current()
+
+        if self.stage == SQUASH_CONFLICT:
+            if not self.verify_no_conflict() or self.has_conflict_hint(message):
+                return
+            if not self.next_is_squash():
+                self.stage = SQUASH_EDIT
+                self.ui.enter_squash_edit(self.squash_message)
+                self.ui.update()
+                return
+            self.stage = CONTINUE
+            entry.done = True
+
+        if self.stage == CONFLICT:
+            if not self.verify_no_conflict() or self.has_conflict_hint(message):
+                return
+            readd, redelete = self.stage_files(files or [])
+
+            allow_empty = []
+            skip = False
+            if not self.current_empty and self.staged_is_empty():
+                if self.next_is_squash():
+                    allow_empty = ["--allow-empty"]
+                else:
+                    choice = self.ui.ask_empty()
+                    if choice == SKIP:
+                        skip = True
+                    elif choice == COMMIT:
+                        allow_empty = ["--allow-empty"]
+                        self.current_empty = True
+                    else:
+                        return
+
+            if not skip:
+                code, out = self.git.run(
+                    "commit", *(allow_empty + ["--allow-empty-message", "-C", entry.hash])
+                )
+                self.log("git commit -C " + entry.hash)
+                self.log(out)
+                if code:
+                    self.ui.error(out)
+                    return
+                text = message.strip()
+                if text != entry.message():
+                    if not text:
+                        self.ui.error(MSG_EMPTY_MESSAGE)
+                        return
+                    code, out = self.git.commit_with_message(["commit", "--amend"], text)
+                    self.log(out)
+                    if code:
+                        self.ui.error(out)
+                        return
+            else:
+                self.reset_hard()
+
+            for name in readd:
+                self.git.run("add", "--ignore-errors", "-f", "--", name)
+            for name in redelete:
+                self.git.run("rm", "--cached", "-q", "--ignore-unmatch", "--", name)
+
+            if entry.action == EDIT and not skip:
+                self.stage = EDIT_STAGE
+                self.ui.enter_edit(self.edit_message(entry))
+                self.ui.update()
+                return
+            self.stage = CONTINUE
+            entry.done = True
+            if self.next_is_squash():
+                self.reset_parent_for_squash(message.strip())
+            else:
+                self.squash_message = ""
+
+        elif self.stage in (EDIT_STAGE, SQUASH_EDIT):
+            if not message.strip():
+                self.ui.error(MSG_EMPTY_MESSAGE)
+                return
+            options = []
+            skip = False
+            if self.current_empty:
+                options = ["--allow-empty"]
+            elif self.staged_is_empty(amend=self.stage == EDIT_STAGE):
+                choice = self.ui.ask_empty()
+                if choice == SKIP:
+                    skip = True
+                elif choice == COMMIT:
+                    options = ["--allow-empty"]
+                    self.current_empty = True
+                else:
+                    return
+
+            if self.stage == SQUASH_EDIT:
+                if self.squash_first:
+                    author, email, date = self.squash_first
+                    options += [f"--author={author} <{email}>", f"--date=@{date}"]
+                args = ["commit"] + options
+            else:
+                args = ["commit", "--amend"] + options
+            if not skip:
+                code, out = self.git.commit_with_message(args, message)
+                self.log(out)
+                if code:
+                    self.ui.error(out)
+                    return
+            else:
+                self.reset_hard()
+
+            if self.next_is_squash():
+                head = load_entries(self.git, ["HEAD"])
+                if head:
+                    self.squash_first = (head[0].author, head[0].email, head[0].date)
+                self.reset_parent_for_squash(message)
+            else:
+                self.squash_message = ""
+            self.stage = CONTINUE
+            entry.done = True
+
+        self.ui.update()
+        self.run()
+
+    def skip_current(self):
+        """Choosing Skip for the commit that stopped (conflict or error)."""
+        entry = self.current()
+        if entry is None or not self.reset_hard():
+            return
+        entry.action = SKIP
+        entry.done = True
+        self.stage = CONTINUE
+        self.ui.leave_conflict()
+        self.ui.update()
+
+    def abort(self):
+        if self.stage == CHOOSE or not self.orig_head:
+            self.ui.close()
+            return
+        if not self.ui.confirm_abort():
+            return
+        self.git.run("cherry-pick", "--quit")
+        code, out = self.git.run("reset", "--hard", self.orig_head, "--")
+        if code:
+            self.ui.error(out)
+        self.restore_stash()
+        self.ui.close()
+
+    def restore_stash(self):
+        if not self.stashed:
+            return
+        self.stashed = False
+        if self.ui.ask_stash_pop():
+            code, out = self.git.run("stash", "pop")
+            if code:
+                self.ui.error(out)
+
+    # file lists
+
+    def revision_files(self, entry):
+        parent = entry.parents[0] if entry.parents else None
+        base = [parent, entry.hash] if parent else ["--root", entry.hash]
+        status = self.git.output("diff-tree", "-r", "-M", "--no-commit-id", "--name-status", *base)
+        numstat = self.git.output("diff-tree", "-r", "-M", "--no-commit-id", "--numstat", *base)
+        counts = {}
+        for line in numstat.splitlines():
+            added, removed, name = (line.split("\t") + ["", "", ""])[:3]
+            counts[name.split(" => ")[-1].rstrip("}")] = (added, removed)
+        files = []
+        for line in status.splitlines():
+            parts = line.split("\t")
+            code, name = parts[0], parts[-1]
+            added, removed = counts.get(name, ("", ""))
+            if code[0] == "R" and len(parts) == 3:
+                added, removed = counts.get(name, next(iter(counts.values()), ("", "")))
+            files.append((name, STATUS_NAMES.get(code[0], code), added, removed))
+        return files
+
+    def working_files(self):
+        """(path, status, added, removed, unmerged) of the working tree."""
+        out = self.git.output("status", "--porcelain=v1", "-z", "--untracked-files=no")
+        numstat = self.git.output("diff", "HEAD", "--numstat")
+        counts = {}
+        for line in numstat.splitlines():
+            parts = line.split("\t")
+            if len(parts) == 3:
+                counts[parts[2]] = (parts[0], parts[1])
+        files = []
+        records = out.split("\0")
+        i = 0
+        while i < len(records):
+            record = records[i]
+            i += 1
+            if len(record) < 4:
+                continue
+            code, name = record[:2], record[3:]
+            if code[0] in "RC":
+                i += 1
+            if code in CONFLICT_CODES:
+                files.append((name, _("Conflict"), "", "", True))
+                continue
+            letter = code[0] if code[0] != " " else code[1]
+            added, removed = counts.get(name, ("", ""))
+            files.append((name, STATUS_NAMES.get(letter, letter), added, removed, False))
+        return files
+
+    def resolve(self, names, side=None):
+        """Resolved (side None), or resolve using "theirs" / "mine"."""
+        for name in names:
+            stages = self.git.stages(name)
+            if side is not None:
+                stage = 3 if side == "theirs" else 2
+                if stage in stages:
+                    code, out = self.git.run("checkout", "--" + side, "--", name)
+                    if code:
+                        return code, out
+                else:
+                    code, out = self.git.run("rm", "-q", "--", name)
+                    if code:
+                        return code, out
+                    continue
+            if os.path.lexists(self.git.path(name)):
+                code, out = self.git.run("add", "-f", "--", name)
+            else:
+                code, out = self.git.run("rm", "-q", "--cached", "--", name)
+            if code:
+                return code, out
+        return 0, ""
+
+    def conflict_versions(self, name):
+        """BASE / LOCAL (mine) / REMOTE (theirs) copies of a conflicted file."""
+        folder = tempfile.mkdtemp(prefix="rabbitvcs-cherry-pick-")
+        stem, ext = os.path.splitext(os.path.basename(name))
+        versions = {"merged": self.git.path(name)}
+        for stage, side in ((1, "BASE"), (2, "LOCAL"), (3, "REMOTE")):
+            proc = subprocess.run(
+                ["git", "show", f":{stage}:{name}"],
+                cwd=self.git.root,
+                capture_output=True,
+                check=False,
+            )
+            if proc.returncode:
+                versions[side] = None
+                continue
+            path = os.path.join(folder, f"{stem}.{side}{ext}")
+            with open(path, "wb") as handle:
+                handle.write(proc.stdout)
+            versions[side] = path
+        return versions
+
+    def theirs_title(self):
+        head = self.git.output("rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD")
+        return f"CHERRY_PICK_HEAD ({head[:7]})" if head else _("changes to-be-integrated")
+
+
+def load_settings():
+    try:
+        from rabbitvcs.util.settings import get_home_folder
+
+        with open(os.path.join(get_home_folder(), SETTINGS_FILE)) as handle:
+            return json.load(handle)
+    except (OSError, ValueError, ImportError):
+        return {}
+
+
+def save_settings(**values):
+    try:
+        from rabbitvcs.util.settings import get_home_folder
+
+        settings = load_settings()
+        settings.update(values)
+        with open(os.path.join(get_home_folder(), SETTINGS_FILE), "w") as handle:
+            json.dump(settings, handle)
+    except (OSError, ImportError):
+        pass
+
+
+def can_cherry_pick(path, hashes):
+    """TortoiseGit hides the menu item for the HEAD commit and while a
+    merge, cherry-pick or revert is in progress."""
+    git = Git(path)
+    head = git.head()
+    if head and head in hashes:
+        return False
+    return not any(
+        git.has_ref(ref) for ref in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")
+    )
+
+
+class CherryPickWindow:
+    """The Cherry Pick dialog."""
+
+    ALL_OPTIONS = (
+        (_("Pick ALL"), PICK, False),
+        (_("Squash ALL"), SQUASH, False),
+        (_("Edit ALL"), EDIT, False),
+        (_("Skip unselected"), SKIP, True),
+        (_("Squash unselected"), SQUASH, True),
+        (_("Edit unselected"), EDIT, True),
+    )
+
+    def __init__(self, path, hashes, parent=None):
+        from gi.repository import Gtk, GLib, Pango
+
+        self.Gtk, self.GLib, self.Pango = Gtk, GLib, Pango
+        self.git = Git(path)
+        self.session = CherryPickSession(self.git, load_entries(self.git, hashes), self)
+        self.session.add_cherry_picked_from = bool(
+            load_settings().get("add_cherry_picked_from", False)
+        )
+        self.changed = False
+        self.loop = None
+        self.all_option = 0
+        self.merge_tools = []
+        self.build(parent)
+        self.update()
+
+    # layout
+
+    def build(self, parent):
+        Gtk = self.Gtk
+        window = Gtk.Window(title=f"{self.git.root} - {_('Cherry Pick')} - {APP_NAME}")
+        window.set_default_size(860, 680)
+        window.set_icon_name("rabbitvcs-small")
+        if parent:
+            window.set_transient_for(parent)
+            window.set_modal(True)
+        window.connect("delete-event", self.on_delete)
+        self.window = window
+
+        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
+        outer.set_border_width(8)
+        window.add(outer)
+
+        top = Gtk.Box(spacing=6)
+        top.pack_start(Gtk.Label(label=_("Branch:")), False, False, 0)
+        branch = Gtk.ComboBoxText()
+        branch.set_size_request(200, -1)
+        branch.set_sensitive(False)
+        top.pack_start(branch, True, True, 0)
+        reverse = Gtk.Button.new_from_icon_name("object-flip-horizontal", Gtk.IconSize.BUTTON)
+        reverse.set_sensitive(False)
+        top.pack_start(reverse, False, False, 0)
+        top.pack_start(Gtk.Label(label=_("Upstream:")), False, False, 0)
+        upstream = Gtk.ComboBoxText()
+        upstream.append_text("HEAD")
+        upstream.set_active(0)
+        upstream.set_size_request(200, -1)
+        upstream.set_sensitive(False)
+        top.pack_start(upstream, True, True, 0)
+        browse = Gtk.Button(label="...")
+        browse.set_sensitive(False)
+        top.pack_start(browse, False, False, 0)
+        onto = Gtk.ToggleButton(label=_("Onto"))
+        onto.set_sensitive(False)
+        top.pack_start(onto, False, False, 0)
+        outer.pack_start(top, False, False, 0)
+
+        paned = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
+        outer.pack_start(paned, True, True, 0)
+
+        upper = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
+        self.store = Gtk.ListStore(str, str, str, str, str, str, int, str, str, bool)
+        self.view = Gtk.TreeView(model=self.store)
+        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
+        for title, index in (
+            (_("REBASE"), 0),
+            (_("ID"), 1),
+            (_("SHA-1"), 2),
+            (_("Message"), 3),
+            (_("Author"), 4),
+            (_("Date"), 5),
+        ):
+            renderer = Gtk.CellRendererText()
+            if index == 1:
+                renderer.set_property("xalign", 1.0)
+            column = Gtk.TreeViewColumn(title, renderer, text=index, weight=6, foreground=7)
+            column.add_attribute(renderer, "cell-background", 8)
+            column.add_attribute(renderer, "cell-background-set", 9)
+            column.set_resizable(True)
+            column.set_expand(index == 3)
+            self.view.append_column(column)
+        self.view.connect("button-press-event", self.on_list_button)
+        self.view.connect("key-press-event", self.on_list_key)
+        self.view.get_selection().connect("changed", self.on_selection_changed)
+        scroll = Gtk.ScrolledWindow()
+        scroll.set_min_content_height(170)
+        scroll.add(self.view)
+        upper.pack_start(scroll, True, True, 0)
+
+        tools = Gtk.Box(spacing=6)
+        split = Gtk.Box()
+        split.get_style_context().add_class("linked")
+        self.all_button = Gtk.Button(label=self.ALL_OPTIONS[0][0])
+        self.all_button.connect("clicked", lambda *_a: self.apply_all_option())
+        split.pack_start(self.all_button, False, False, 0)
+        all_menu = Gtk.Menu()
+        for i, (label, _action, _unselected) in enumerate(self.ALL_OPTIONS):
+            item = Gtk.MenuItem(label=label)
+            item.connect("activate", lambda _m, n=i: self.apply_all_option(n))
+            all_menu.append(item)
+        all_menu.show_all()
+        self.all_arrow = Gtk.MenuButton(popup=all_menu)
+        split.pack_start(self.all_arrow, False, False, 0)
+        tools.pack_start(split, False, False, 0)
+
+        self.up_button = Gtk.Button(label=_("_Up"), use_underline=True)
+        self.up_button.connect("clicked", lambda *_a: self.move(True))
+        self.down_button = Gtk.Button(label=_("_Down"), use_underline=True)
+        self.down_button.connect("clicked", lambda *_a: self.move(False))
+        self.add_button = Gtk.Button(label=_("_Add"), use_underline=True)
+        self.add_button.connect("clicked", lambda *_a: self.on_add())
+        for button in (self.up_button, self.down_button, self.add_button):
+            tools.pack_start(button, False, False, 0)
+        self.from_check = Gtk.CheckButton(
+            label=_('_add "cherry picked from"'), use_underline=True
+        )
+        self.from_check.set_active(self.session.add_cherry_picked_from)
+        self.from_check.connect("toggled", self.on_from_toggled)
+        tools.pack_end(self.from_check, False, False, 0)
+        upper.pack_start(tools, False, False, 0)
+        paned.pack1(upper, True, False)
+
+        self.notebook = Gtk.Notebook()
+        self.files_store = Gtk.ListStore(bool, str, str, str, str, str, bool, bool)
+        self.files_view = Gtk.TreeView(model=self.files_store)
+        self.files_view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
+        toggle = Gtk.CellRendererToggle()
+        toggle.connect("toggled", self.on_file_toggled)
+        self.check_column = Gtk.TreeViewColumn("", toggle, active=0, visible=7)
+        self.files_view.append_column(self.check_column)
+        for title, index in (
+            (_("Path"), 1),
+            (_("Extension"), 2),
+            (_("Status"), 3),
+            (_("Lines added"), 4),
+            (_("Lines removed"), 5),
+        ):
+            column = Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=index)
+            column.set_resizable(True)
+            column.set_expand(index == 1)
+            self.files_view.append_column(column)
+        self.files_view.connect("button-press-event", self.on_files_button)
+        self.files_view.connect("row-activated", self.on_file_activated)
+        files_scroll = Gtk.ScrolledWindow()
+        files_scroll.add(self.files_view)
+        self.files_label = Gtk.Label(label=_("Revision Files"))
+        self.notebook.append_page(files_scroll, self.files_label)
+
+        self.message_view = Gtk.TextView()
+        self.message_view.set_monospace(True)
+        self.message_view.set_editable(False)
+        message_scroll = Gtk.ScrolledWindow()
+        message_scroll.add(self.message_view)
+        self.notebook.append_page(message_scroll, Gtk.Label(label=_("Commit Message")))
+
+        self.log_view = Gtk.TextView()
+        self.log_view.set_monospace(True)
+        self.log_view.set_editable(False)
+        self.log_scroll = Gtk.ScrolledWindow()
+        self.log_scroll.add(self.log_view)
+        paned.pack2(self.notebook, True, False)
+        paned.set_position(260)
+
+        self.progress = Gtk.ProgressBar()
+        outer.pack_start(self.progress, False, False, 0)
+
+        bottom = Gtk.Box(spacing=6)
+        self.status_label = Gtk.Label(xalign=0)
+        self.status_label.set_ellipsize(self.Pango.EllipsizeMode.END)
+        bottom.pack_start(self.status_label, True, True, 0)
+        self.continue_button = Gtk.Button(label=_("Continue"))
+        self.continue_button.get_style_context().add_class("suggested-action")
+        self.continue_button.connect("clicked", lambda *_a: self.on_continue())
+        self.abort_button = Gtk.Button(label=_("Abort"))
+        self.abort_button.set_tooltip_text(_("Recover to the status before rebase"))
+        self.abort_button.connect("clicked", lambda *_a: self.session.abort())
+        bottom.pack_start(self.continue_button, False, False, 0)
+        bottom.pack_start(self.abort_button, False, False, 0)
+        outer.pack_start(bottom, False, False, 0)
+
+        window.show_all()
+        self.shown_stage = CHOOSE
+
+    # session callbacks
+
+    def process_events(self):
+        Gtk = self.Gtk
+        while Gtk.events_pending():
+            Gtk.main_iteration()
+
+    def log(self, text):
+        buffer = self.log_view.get_buffer()
+        buffer.insert(buffer.get_end_iter(), text.rstrip("\n") + "\n")
+        self.log_view.scroll_to_iter(buffer.get_end_iter(), 0, False, 0, 0)
+
+    def started(self):
+        self.changed = True
+        if self.notebook.page_num(self.log_scroll) < 0:
+            self.notebook.append_page(self.log_scroll, self.Gtk.Label(label=_("Log")))
+            self.log_scroll.show_all()
+        self.notebook.set_current_page(self.notebook.page_num(self.log_scroll))
+        self.files_store.clear()
+        self.files_label.set_text(_("Conflict Files"))
+
+    def update(self):
+        session = self.session
+        Gtk = self.Gtk
+        selected = self.selected_rows()
+        self.store.clear()
+        total = len(session.entries)
+        for i, entry in enumerate(session.entries):
+            background = None
+            if entry.action == SQUASH:
+                background = "#9c9c9c"
+            elif entry.action == EDIT:
+                background = "#c8c880"
+            self.store.append(
+                [
+                    ACTION_NAMES[entry.action],
+                    str(total - i),
+                    entry.hash,
+                    entry.subject,
+                    entry.author,
+                    time.strftime("%x %X", time.localtime(entry.date)),
+                    self.Pango.Weight.BOLD if entry.current else self.Pango.Weight.NORMAL,
+                    "#808080" if entry.done or entry.action == SKIP else None,
+                    background,
+                    background is not None,
+                ]
+            )
+        selection = self.view.get_selection()
+        for row in selected:
+            if row < total:
+                selection.select_path(Gtk.TreePath(row))
+        current = session.current()
+        if current is not None and session.stage != CHOOSE:
+            self.view.scroll_to_cell(Gtk.TreePath(session.index), None, False, 0, 0)
+
+        choosing = session.stage == CHOOSE
+        for widget in (self.all_button, self.all_arrow, self.up_button, self.down_button, self.add_button):
+            widget.set_sensitive(choosing)
+        self.from_check.set_sensitive(choosing)
+        self.continue_button.set_label(BUTTON_TEXT[session.stage])
+        self.continue_button.set_sensitive(session.stage != ERROR and bool(total))
+
+        if session.stage == DONE:
+            fraction = 1.0
+        elif session.stage == CHOOSE or not total:
+            fraction = 0.0
+        else:
+            fraction = max(session.commit_id() - 1, 0) / total
+        self.progress.set_fraction(fraction)
+        if session.stage != self.shown_stage:
+            # like CRebaseDlg::OnRebaseUpdateUI: show the Log tab while running
+            if session.stage in (CONTINUE, ERROR, DONE):
+                self.message_view.set_editable(False)
+                self.notebook.set_current_page(self.notebook.page_num(self.log_scroll))
+            self.shown_stage = session.stage
+        self.status_label.set_text(session.status)
+        if session.stage == DONE:
+            self.continue_button.grab_focus()
+
+    def message_text(self):
+        buffer = self.message_view.get_buffer()
+        return buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
+
+    def set_message(self, text, editable):
+        self.message_view.get_buffer().set_text(text)
+        self.message_view.set_editable(editable)
+
+    def enter_conflict(self, message):
+        self.files_label.set_text(_("Conflict Files"))
+        self.refresh_conflicts()
+        self.set_message(message, True)
+        self.notebook.set_current_page(0)
+
+    def leave_conflict(self):
+        self.files_store.clear()
+        self.set_message("", False)
+
+    def enter_edit(self, message):
+        self.set_message(message, True)
+        self.notebook.set_current_page(1)
+
+    def enter_squash_edit(self, message):
+        self.set_message(message, True)
+        self.notebook.set_current_page(1)
+
+    def select_conflict(self, name):
+        selection = self.files_view.get_selection()
+        selection.unselect_all()
+        for row in self.files_store:
+            if row[1] == name:
+                selection.select_path(row.path)
+                self.files_view.scroll_to_cell(row.path, None, False, 0, 0)
+        self.notebook.set_current_page(0)
+        self.files_view.grab_focus()
+
+    def close(self):
+        save_settings(add_cherry_picked_from=self.from_check.get_active())
+        self.window.destroy()
+        if self.loop is not None:
+            self.loop.quit()
+
+    # message boxes
+
+    def message(self, text, buttons, kind=None, check=None):
+        Gtk = self.Gtk
+        dialog = Gtk.MessageDialog(
+            transient_for=self.window,
+            modal=True,
+            message_type=kind if kind is not None else Gtk.MessageType.QUESTION,
+            buttons=Gtk.ButtonsType.NONE,
+            text=APP_NAME,
+        )
+        dialog.format_secondary_text(text)
+        for response, label in enumerate(buttons, start=1):
+            dialog.add_button(label, response)
+        check_button = None
+        if check:
+            check_button = Gtk.CheckButton(label=check, use_underline=True)
+            dialog.get_message_area().pack_start(check_button, False, False, 0)
+            check_button.show()
+        dialog.set_default_response(1)
+        response = dialog.run()
+        checked = check_button.get_active() if check_button else False
+        dialog.destroy()
+        return (response if response > 0 else 0), checked
+
+    def ask(self, text, buttons, kind=None):
+        return self.message(text, buttons, kind)[0]
+
+    def warn(self, text):
+        self.ask(text, [_("_OK")], self.Gtk.MessageType.WARNING)
+
+    def error(self, text):
+        self.ask(text, [_("_OK")], self.Gtk.MessageType.ERROR)
+
+    def ask_stash(self):
+        return self.ask(MSG_STASH, [_("_Stash"), _("A_bort")]) == 1
+
+    def ask_stash_pop(self):
+        return self.ask(MSG_STASH_POP, [_("_Yes"), _("_No")]) == 1
+
+    def confirm_abort(self):
+        return self.ask(MSG_ABORT, [_("_Yes"), _("_No")]) == 1
+
+    def ask_empty(self):
+        return {1: COMMIT, 2: SKIP}.get(
+            self.ask(MSG_EMPTY, [_("C_ommit"), _("_Skip"), _("Cancel")])
+        )
+
+    def ask_failed(self):
+        response, rest = self.message(
+            MSG_FAILED,
+            [_("_Skip"), _("_Retry"), _("Cancel")],
+            check=_("_Do the same for the rest"),
+        )
+        choice = {1: SKIP, 2: RETRY}.get(response)
+        return choice, bool(rest and choice == SKIP)
+
+    def ask_parent(self, entry, titles):
+        buttons = [
+            (_("Parent %d") % (i + 1)) + "\n" + title.replace("_", "__")
+            for i, title in enumerate(titles)
+        ]
+        response = self.ask(
+            MSG_MERGE_COMMIT % (entry.hash, entry.subject), buttons + [_("Cancel")]
+        )
+        return response if 0 < response <= len(titles) else None
+
+    def ask_conflict_hint_abort(self):
+        return self.ask(MSG_CONFLICT_HINT, [_("_Ignore"), _("A_bort")]) != 1
+
+    def ask_user_data(self):
+        if self.ask(MSG_USER_DATA, [_("_Yes"), _("_No")]) != 1:
+            return False
+        Gtk = self.Gtk
+        dialog = Gtk.Dialog(title=APP_NAME, transient_for=self.window, modal=True)
+        grid = Gtk.Grid(row_spacing=6, column_spacing=6)
+        grid.set_border_width(10)
+        name = Gtk.Entry(text=self.git.output("config", "user.name"))
+        email = Gtk.Entry(text=self.git.output("config", "user.email"))
+        grid.attach(Gtk.Label(label=_("Name:"), xalign=1), 0, 0, 1, 1)
+        grid.attach(name, 1, 0, 1, 1)
+        grid.attach(Gtk.Label(label=_("Email:"), xalign=1), 0, 1, 1, 1)
+        grid.attach(email, 1, 1, 1, 1)
+        dialog.get_content_area().add(grid)
+        dialog.add_button(_("_Cancel"), Gtk.ResponseType.CANCEL)
+        dialog.add_button(_("_OK"), Gtk.ResponseType.OK)
+        dialog.show_all()
+        ok = dialog.run() == Gtk.ResponseType.OK
+        values = (name.get_text().strip(), email.get_text().strip())
+        dialog.destroy()
+        if not ok or not all(values):
+            return False
+        self.git.run("config", "--global", "user.name", values[0])
+        self.git.run("config", "--global", "user.email", values[1])
+        return True
+
+    # commit list
+
+    def selected_rows(self):
+        model, paths = self.view.get_selection().get_selected_rows()
+        return [path[0] for path in paths]
+
+    def on_selection_changed(self, _selection):
+        if self.session.stage != CHOOSE:
+            return
+        rows = self.selected_rows()
+        self.files_store.clear()
+        if len(rows) != 1:
+            self.set_message("", False)
+            return
+        entry = self.session.entries[rows[0]]
+        for name, status, added, removed in self.session.revision_files(entry):
+            ext = os.path.splitext(name)[1]
+            self.files_store.append([False, name, ext, status, added, removed, False, False])
+        self.set_message(entry.subject + "\n" + entry.body, False)
+
+    def menu_actions(self, rows):
+        session = self.session
+        entries = [session.entries[r] for r in rows]
+        if not entries or any(e.done for e in entries):
+            return []
+        if any(e.current for e in entries):
+            if session.stage in (CONFLICT, ERROR) and len(entries) == 1:
+                return [(_("Skip"), SKIP)]
+            return []
+        actions = [(_("Pick"), PICK)]
+        if len(session.entries) - 1 not in rows:
+            actions.append((_("Squash (with commit below)"), SQUASH))
+        actions += [(_("Edit"), EDIT), (_("Skip"), SKIP)]
+        return actions
+
+    def on_list_button(self, view, event):
+        if event.button != 3:
+            return False
+        Gtk = self.Gtk
+        hit = view.get_path_at_pos(int(event.x), int(event.y))
+        if hit and hit[0][0] not in self.selected_rows():
+            view.get_selection().unselect_all()
+            view.get_selection().select_path(hit[0])
+        rows = self.selected_rows()
+        actions = self.menu_actions(rows)
+        if not actions:
+            return True
+        menu = Gtk.Menu()
+        for label, action in actions:
+            item = Gtk.MenuItem(label=label)
+            item.connect("activate", lambda _i, a=action: self.session.set_action(rows, a))
+            menu.append(item)
+        menu.show_all()
+        menu.popup_at_pointer(event)
+        return True
+
+    def on_list_key(self, _view, event):
+        from gi.repository import Gdk
+
+        rows = self.selected_rows()
+        key = Gdk.keyval_name(event.keyval) or ""
+        control = event.state & Gdk.ModifierType.CONTROL_MASK
+        shift = bool(event.state & Gdk.ModifierType.SHIFT_MASK)
+        if control and key.lower() == "a":
+            self.view.get_selection().select_all()
+            return True
+        if control:
+            return False
+        if key == "space":
+            self.session.cycle_action(rows)
+        elif key.lower() in ("p", "s", "q", "e"):
+            action = {"p": PICK, "s": SKIP, "q": SQUASH, "e": EDIT}[key.lower()]
+            if any(label for label, a in self.menu_actions(rows) if a == action):
+                self.session.set_action(rows, action)
+        elif key.lower() == "u" and self.up_button.get_sensitive():
+            self.move(True, shift)
+        elif key.lower() == "d" and self.down_button.get_sensitive():
+            self.move(False, shift)
+        else:
+            return False
+        return True
+
+    def move(self, up, to_end=None):
+        if to_end is None:
+            from gi.repository import Gdk
+
+            state = get_event_state()
+            to_end = bool(state & Gdk.ModifierType.SHIFT_MASK)
+        moved = self.session.move(self.selected_rows(), up, to_end)
+        selection = self.view.get_selection()
+        selection.unselect_all()
+        for row in moved:
+            selection.select_path(self.Gtk.TreePath(row))
+        self.view.grab_focus()
+
+    def apply_all_option(self, option=None):
+        if option is not None:
+            self.all_option = option
+            self.all_button.set_label(self.ALL_OPTIONS[option][0])
+        _label, action, unselected = self.ALL_OPTIONS[self.all_option]
+        self.session.set_all(action, set(self.selected_rows()) if unselected else None)
+
+    def on_from_toggled(self, check):
+        self.session.add_cherry_picked_from = check.get_active()
+        save_settings(add_cherry_picked_from=check.get_active())
+
+    def on_add(self):
+        hashes = pick_commits(self.window, self.git)
+        if hashes:
+            self.session.add_entries(hashes)
+
+    # files tab
+
+    def refresh_conflicts(self):
+        self.files_store.clear()
+        for name, status, added, removed, unmerged in self.session.working_files():
+            ext = os.path.splitext(name)[1]
+            self.files_store.append([True, name, ext, status, added, removed, unmerged, True])
+
+    def checked_files(self):
+        return [(row[1], row[0], row[3]) for row in self.files_store]
+
+    def on_file_toggled(self, _renderer, path):
+        self.files_store[path][0] = not self.files_store[path][0]
+
+    def selected_files(self):
+        model, paths = self.files_view.get_selection().get_selected_rows()
+        return [model[path] for path in paths]
+
+    def on_files_button(self, view, event):
+        if event.button != 3 or self.session.stage not in (CONFLICT, SQUASH_CONFLICT):
+            return False
+        Gtk = self.Gtk
+        hit = view.get_path_at_pos(int(event.x), int(event.y))
+        if hit and hit[0][0] not in [r.path[0] for r in self.selected_files()]:
+            view.get_selection().unselect_all()
+            view.get_selection().select_path(hit[0])
+        rows = self.selected_files()
+        unmerged = [row[1] for row in rows if row[6]]
+        if not unmerged:
+            return True
+        menu = Gtk.Menu()
+
+        def item(label, callback):
+            entry = Gtk.MenuItem(label=label)
+            entry.connect("activate", lambda *_a: callback())
+            menu.append(entry)
+
+        if len(rows) == 1:
+            item(_("Edit conflicts"), lambda: self.edit_conflicts(unmerged[0]))
+        item(_("Resolved"), lambda: self.resolve(unmerged, None))
+        item(
+            _('Resolve conflict using "%s"') % self.session.theirs_title(),
+            lambda: self.resolve(unmerged, "theirs"),
+        )
+        item(_('Resolve conflict using "%s"') % "HEAD", lambda: self.resolve(unmerged, "ours"))
+        menu.show_all()
+        menu.popup_at_pointer(event)
+        return True
+
+    def resolve(self, names, side):
+        if self.ask(MSG_RESOLVE, [_("_Yes"), _("_No")]) != 1:
+            return
+        code, out = self.session.resolve(names, side)
+        if code:
+            self.error(out)
+        self.refresh_conflicts()
+
+    def on_file_activated(self, view, path, _column):
+        row = self.files_store[path]
+        if self.session.stage in (CONFLICT, SQUASH_CONFLICT):
+            if row[6]:
+                self.edit_conflicts(row[1])
+            else:
+                self.show_diff(row[1], "HEAD", None)
+            return
+        rows = self.selected_rows()
+        if len(rows) == 1:
+            entry = self.session.entries[rows[0]]
+            parent = entry.parents[0] if entry.parents else None
+            self.show_diff(row[1], parent, entry.hash)
+
+    def show_diff(self, name, older, newer):
+        from rabbitvcs.util import helper
+
+        path = self.git.path(name)
+        args = []
+        if older:
+            args.append(f"{path}@{older}")
+        args.append(f"{path}@{newer}" if newer else path)
+        helper.launch_ui_window("diff", args + ["--vcs=git"])
+
+    def edit_conflicts(self, name):
+        stages = self.git.stages(name)
+        if not {2, 3} <= stages:
+            self.delete_conflict(name, stages)
+            return
+        versions = self.session.conflict_versions(name)
+        from rabbitvcs.util import helper
+
+        merged = versions["merged"]
+        if helper.get_merge_tool():
+            tool = helper.get_merge_tool()
+            for key, value in (
+                ("%base", versions["BASE"] or ""),
+                ("%mine", versions["LOCAL"]),
+                ("%theirs", versions["REMOTE"]),
+                ("%merged", merged),
+            ):
+                tool = tool.replace(key, value)
+            process = subprocess.Popen(tool, shell=True)  # pylint: disable=consider-using-with
+        elif shutil.which("meld"):
+            args = ["meld", "--output", merged, versions["LOCAL"]]
+            args += [versions["BASE"]] if versions["BASE"] else [merged]
+            args.append(versions["REMOTE"])
+            process = subprocess.Popen(args)  # pylint: disable=consider-using-with
+        else:
+            process = subprocess.Popen(["xdg-open", merged])  # pylint: disable=consider-using-with
+            self.ask(
+                _(
+                    "No merge tool found. The file was opened in your default "
+                    "editor: fix the conflict, save, then mark it Resolved.\n\n"
+                    "For a 3-way merge: sudo apt install meld"
+                ),
+                [_("_OK")],
+                self.Gtk.MessageType.INFO,
+            )
+            return
+
+        def wait():
+            if process.poll() is None:
+                return True
+            if name in self.git.unmerged() and not self.session_has_markers(name):
+                self.resolve([name], None)
+            else:
+                self.refresh_conflicts()
+            return False
+
+        self.GLib.timeout_add(500, wait)
+
+    def session_has_markers(self, name):
+        try:
+            with open(self.git.path(name), errors="ignore") as handle:
+                return any(line.startswith(("<<<<<<< ", ">>>>>>> ")) for line in handle)
+        except OSError:
+            return False
+
+    def delete_conflict(self, name, stages):
+        """TortoiseGit's "Delete/modify merge conflict" dialog."""
+        Gtk = self.Gtk
+
+        def describe(stage):
+            if stage not in stages:
+                return _("Deleted")
+            return _("Modified") if 1 in stages else _("Created")
+
+        dialog = Gtk.Dialog(title=self.git.path(name), transient_for=self.window, modal=True)
+        frame = Gtk.Frame(label=_("Delete/modify merge conflict"))
+        grid = Gtk.Grid(row_spacing=6, column_spacing=12)
+        grid.set_border_width(10)
+        grid.attach(Gtk.Label(label=name, xalign=0), 0, 0, 2, 1)
+        for row, (title, stage) in enumerate(
+            (("HEAD", 2), (self.session.theirs_title(), 3)), start=1
+        ):
+            ref = Gtk.Entry(text=title, editable=False, width_chars=34)
+            grid.attach(ref, 0, row * 2 - 1, 1, 1)
+            grid.attach(Gtk.Label(label=describe(stage), xalign=0), 0, row * 2, 1, 1)
+        frame.add(grid)
+        dialog.get_content_area().add(frame)
+        dialog.add_button(_("Modified") if 1 in stages else _("Created"), 1)
+        dialog.add_button(_("Delete"), 2)
+        dialog.add_button(_("Abort"), Gtk.ResponseType.CANCEL)
+        dialog.show_all()
+        response = dialog.run()
+        dialog.destroy()
+        if response == 1:
+            if not os.path.lexists(self.git.path(name)):
+                self.git.run("checkout", "--theirs" if 3 in stages else "--ours", "--", name)
+            code, out = self.git.run("add", "-f", "--", name)
+        elif response == 2:
+            code, out = self.git.run("rm", "-q", "--", name)
+        else:
+            return
+        if code:
+            self.error(out)
+        self.refresh_conflicts()
+
+    # buttons
+
+    def on_continue(self):
+        stage = self.session.stage
+        self.continue_button.set_sensitive(False)
+        files = self.checked_files() if stage == CONFLICT else None
+        self.session.continue_clicked(self.message_text(), files)
+        if self.session.stage not in (DONE,) and self.window.get_visible():
+            self.update()
+
+    def on_delete(self, *_args):
+        self.session.abort()
+        return True
+
+    def run(self):
+        self.loop = self.GLib.MainLoop()
+        self.loop.run()
+        return self.changed
+
+
+def get_event_state():
+    from gi.repository import Gtk
+
+    event = Gtk.get_current_event()
+    if event is None:
+        return 0
+    ok, state = event.get_state()
+    return state if ok else 0
+
+
+def pick_commits(parent, git):
+    """Select commits to add, like TortoiseGit's log in select mode."""
+    from gi.repository import Gtk
+
+    dialog = Gtk.Dialog(title=_("Select commits"), transient_for=parent, modal=True)
+    dialog.set_default_size(760, 460)
+    box = dialog.get_content_area()
+    box.set_spacing(6)
+    box.set_border_width(8)
+
+    top = Gtk.Box(spacing=6)
+    refs = Gtk.ComboBoxText()
+    refs.append("--all", _("<All Branches>"))
+    for ref in git.output(
+        "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"
+    ).splitlines():
+        if not ref.endswith("/HEAD"):
+            refs.append(ref, ref)
+    refs.set_active(0)
+    search = Gtk.SearchEntry()
+    top.pack_start(refs, False, False, 0)
+    top.pack_start(search, True, True, 0)
+    box.pack_start(top, False, False, 0)
+
+    store = Gtk.ListStore(str, str, str, str)
+    filtered = store.filter_new()
+    view = Gtk.TreeView(model=filtered)
+    view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
+    for title, index in ((_("SHA-1"), 0), (_("Message"), 1), (_("Author"), 2), (_("Date"), 3)):
+        column = Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=index)
+        column.set_resizable(True)
+        column.set_expand(index == 1)
+        view.append_column(column)
+    scroll = Gtk.ScrolledWindow()
+    scroll.set_vexpand(True)
+    scroll.add(view)
+    box.pack_start(scroll, True, True, 0)
+
+    def load(*_args):
+        store.clear()
+        out = git.output(
+            "log", refs.get_active_id(), "-500", "--format=%h%x00%s%x00%an%x00%at"
+        )
+        for line in out.splitlines():
+            parts = line.split("\0")
+            if len(parts) == 4:
+                stamp = time.strftime("%x %X", time.localtime(int(parts[3] or 0)))
+                store.append([parts[0], parts[1], parts[2], stamp])
+
+    def visible(model, row, _data):
+        text = search.get_text().lower()
+        return not text or any(text in (model[row][i] or "").lower() for i in range(3))
+
+    filtered.set_visible_func(visible)
+    refs.connect("changed", load)
+    search.connect("search-changed", lambda *_a: filtered.refilter())
+    load()
+
+    dialog.add_button(_("_Cancel"), Gtk.ResponseType.CANCEL)
+    dialog.add_button(_("_OK"), Gtk.ResponseType.OK)
+    dialog.show_all()
+    response = dialog.run()
+    model, paths = view.get_selection().get_selected_rows()
+    hashes = [model[path][0] for path in paths]
+    dialog.destroy()
+    if response != Gtk.ResponseType.OK:
+        return []
+    return [git.output("rev-parse", h) for h in hashes]
+
+
+def cherry_pick(path, hashes, parent=None):
+    """
+    Entry point used by the log window.
+
+    @param hashes: selected commits in log order (newest first)
+    @return: True when the repository may have changed
+
+    """
+    try:
+        locale.setlocale(locale.LC_TIME, "")
+    except locale.Error:
+        pass
+    window = CherryPickWindow(path, hashes, parent)
+    return window.run()
diff --git a/rabbitvcs/ui/log.py b/rabbitvcs/ui/log.py
index 4e085f5..877e999 100755
--- a/rabbitvcs/ui/log.py
+++ b/rabbitvcs/ui/log.py
@@ -724,9 +724,32 @@ class GitLog(Log):
             flags={"sortable": False},
         )
         self.start_point = 0
+        self.initialize_ref_selector()
         self.initialize_root_url()
         self.load_or_refresh()
 
+    def initialize_ref_selector(self):
+        """
+        TortoiseGit-style ref label (top left) and "All Branches" check box
+        (bottom left). The log starts on the current branch.
+
+        """
+        from rabbitvcs.ui.refbrowser import RefSelector
+
+        self.ref_selector = RefSelector(
+            self.path, self.get_widget("Log"), self.on_ref_changed
+        )
+        search = self.get_widget("hbox-search")
+        search.attach(self.ref_selector.button, -1, 0, 1, 1)
+        search.show_all()
+        bottom = self.get_widget("close").get_parent()
+        bottom.attach(self.ref_selector.all_branches, 0, -1, 1, 1)
+        self.ref_selector.all_branches.show()
+
+    def on_ref_changed(self):
+        self.start_point = 0
+        self.load()
+
     #
     # Log-loading callback methods
     #
@@ -866,7 +889,11 @@ class GitLog(Log):
         self.action = GitAction(self.git, notification=False, run_in_thread=True)
 
         self.action.append(
-            self.git.log, path=self.path, skip=self.start_point, limit=self.limit + 1
+            self.git.log,
+            path=self.path,
+            skip=self.start_point,
+            limit=self.limit + 1,
+            **self.ref_selector.log_arguments(self.git)
         )
         self.action.append(self.refresh)
         self.action.schedule()
@@ -1181,6 +1208,19 @@ class LogTopContextMenuConditions(object):
     def reset(self, data=None):
         return self.vcs_name == rabbitvcs.vcs.VCS_GIT
 
+    def cherry_pick(self, data=None):
+        return len(self.revisions) == 1 and self.can_cherry_pick()
+
+    def cherry_pick_selected(self, data=None):
+        return len(self.revisions) > 1 and self.can_cherry_pick()
+
+    def can_cherry_pick(self):
+        if self.vcs_name != rabbitvcs.vcs.VCS_GIT:
+            return False
+        from rabbitvcs.ui.cherrypick import can_cherry_pick
+
+        return can_cherry_pick(self.path, [S(r["revision"]) for r in self.revisions])
+
 
 class LogTopContextMenuCallbacks(object):
     def __init__(self, caller, vcs, path, revisions):
@@ -1424,6 +1464,16 @@ class LogTopContextMenuCallbacks(object):
             ],
         )
 
+    def cherry_pick(self, widget, data=None):
+        from rabbitvcs.ui.cherrypick import cherry_pick
+
+        hashes = [S(r["revision"]) for r in self.revisions]
+        if cherry_pick(self.path, hashes, self.caller.get_widget("Log")):
+            self.caller.load()
+
+    def cherry_pick_selected(self, widget, data=None):
+        self.cherry_pick(widget, data)
+
     def edit_author(self, widget, data=None):
         author = ""
         if len(self.revisions) == 1:
@@ -1527,6 +1577,8 @@ class LogTopContextMenu(object):
             (MenuExport, None),
             (MenuMerge, None),
             (MenuReset, None),
+            (MenuCherryPick, None),
+            (MenuCherryPickSelected, None),
             (MenuSeparatorLast, None),
             (MenuEditAuthor, None),
             (MenuEditLogMessage, None),
diff --git a/rabbitvcs/ui/refbrowser.py b/rabbitvcs/ui/refbrowser.py
new file mode 100644
index 0000000..39fbd2c
--- /dev/null
+++ b/rabbitvcs/ui/refbrowser.py
@@ -0,0 +1,332 @@
+#
+# This is an extension to the Nautilus file manager to allow better
+# integration with the Subversion source control system.
+#
+# RabbitVCS is free software; you can redistribute it and/or modify
+# it under the terms of the GNU General Public License as published by
+# the Free Software Foundation; either version 2 of the License, or
+# (at your option) any later version.
+#
+# RabbitVCS is distributed in the hope that it will be useful,
+# but WITHOUT ANY WARRANTY; without even the implied warranty of
+# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
+# GNU General Public License for more details.
+#
+# You should have received a copy of the GNU General Public License
+# along with RabbitVCS;  If not, see <http://www.gnu.org/licenses/>.
+#
+"""
+Git reference picker for the log window, modelled on TortoiseGit:
+
+- the current ref is shown at the top left of the log; click it to open
+  "Browse References", right-click it for HEAD, FETCH_HEAD, All,
+  All basic refs, All local branches and recently chosen refs
+- an "All Branches" check box shows the log of every branch
+
+"""
+
+import json
+import os
+import subprocess
+import time
+
+from rabbitvcs import gettext
+
+_ = gettext.gettext
+
+MODE_REF = "ref"
+MODE_ALL = "all"
+MODE_BASIC = "basic"
+MODE_LOCAL = "local"
+
+MODE_LABELS = {
+    MODE_ALL: _("<All Branches>"),
+    MODE_BASIC: _("<Basic Refs>"),
+    MODE_LOCAL: _("<Local Branches>"),
+}
+
+HISTORY_FILE = "log-refs.json"
+HISTORY_SIZE = 10
+GROUPS = (
+    ("refs/heads/", _("Local branches")),
+    ("refs/remotes/", _("Remote branches")),
+    ("refs/tags/", _("Tags")),
+)
+
+
+def git_output(cwd, *args):
+    proc = subprocess.run(
+        ["git"] + list(args), cwd=cwd, capture_output=True, text=True, check=False
+    )
+    return proc.stdout.strip() if proc.returncode == 0 else ""
+
+
+def repo_dir(path):
+    return path if os.path.isdir(path) else os.path.dirname(path)
+
+
+def strip_ref_name(ref):
+    """Same display rule as TortoiseGit's StripRefName."""
+    if ref.startswith("refs/heads/"):
+        return ref[len("refs/heads/") :]
+    if ref.startswith("refs/"):
+        return ref[len("refs/") :]
+    return ref
+
+
+def current_branch(cwd):
+    return git_output(cwd, "symbolic-ref", "--short", "-q", "HEAD")
+
+
+def list_refs(cwd):
+    out = git_output(
+        cwd,
+        "for-each-ref",
+        "--format=%(refname)%00%(committerdate:unix)%00%(subject)",
+        "refs/heads",
+        "refs/remotes",
+        "refs/tags",
+    )
+    refs = []
+    for line in out.splitlines():
+        parts = line.split("\0")
+        if len(parts) != 3 or parts[0].endswith("/HEAD"):
+            continue
+        refs.append((parts[0], int(parts[1] or 0), parts[2]))
+    return refs
+
+
+def history_path():
+    try:
+        from rabbitvcs.util.settings import get_home_folder
+
+        return os.path.join(get_home_folder(), HISTORY_FILE)
+    except ImportError:
+        return None
+
+
+def load_history():
+    path = history_path()
+    try:
+        with open(path) as handle:
+            return [str(ref) for ref in json.load(handle)][:HISTORY_SIZE]
+    except (OSError, TypeError, ValueError):
+        return []
+
+
+def add_history(ref):
+    entries = [ref] + [r for r in load_history() if r != ref]
+    path = history_path()
+    if not path:
+        return
+    try:
+        with open(path, "w") as handle:
+            json.dump(entries[:HISTORY_SIZE], handle)
+    except OSError:
+        pass
+
+
+def pick_ref(parent, cwd, selected=None):
+    """
+    The "Browse References" dialog.
+
+    @return: the chosen ref as TortoiseGit shows it (e.g. "main" or
+             "remotes/origin/main"), or None
+
+    """
+    from gi.repository import Gtk, Pango
+
+    dialog = Gtk.Dialog(title=_("Browse References"), transient_for=parent, modal=True)
+    dialog.set_default_size(720, 480)
+    box = dialog.get_content_area()
+    box.set_spacing(6)
+    box.set_border_width(8)
+
+    search = Gtk.SearchEntry()
+    search.set_placeholder_text(_("Filter"))
+    box.pack_start(search, False, False, 0)
+
+    store = Gtk.TreeStore(str, str, str, str, int)
+    current = "refs/heads/" + current_branch(cwd)
+    groups = {}
+    for prefix, label in GROUPS:
+        groups[prefix] = store.append(None, [label, "", "", "", Pango.Weight.BOLD])
+    remotes = {}
+    for ref, date, subject in list_refs(cwd):
+        prefix = next(p for p, _label in GROUPS if ref.startswith(p))
+        parent_row = groups[prefix]
+        name = ref[len(prefix) :]
+        if prefix == "refs/remotes/" and "/" in name:
+            remote, name = name.split("/", 1)
+            if remote not in remotes:
+                remotes[remote] = store.append(
+                    parent_row, [remote, "", "", "", Pango.Weight.NORMAL]
+                )
+            parent_row = remotes[remote]
+        stamp = time.strftime("%x %X", time.localtime(date)) if date else ""
+        weight = Pango.Weight.BOLD if ref == current else Pango.Weight.NORMAL
+        store.append(parent_row, [name, stamp, subject, ref, weight])
+
+    filtered = store.filter_new()
+    view = Gtk.TreeView(model=filtered)
+    for title, index in ((_("Name"), 0), (_("Last Modified"), 1), (_("Message"), 2)):
+        renderer = Gtk.CellRendererText()
+        column = Gtk.TreeViewColumn(title, renderer, text=index, weight=4)
+        column.set_resizable(True)
+        column.set_expand(index == 2)
+        view.append_column(column)
+
+    def visible(model, row, _data):
+        text = search.get_text().lower()
+        if not text:
+            return True
+        if model[row][3]:
+            return text in model[row][3].lower()
+        child = model.iter_children(row)
+        while child:
+            if visible(model, child, None):
+                return True
+            child = model.iter_next(child)
+        return False
+
+    filtered.set_visible_func(visible)
+    search.connect("search-changed", lambda *_a: (filtered.refilter(), view.expand_all()))
+
+    scroll = Gtk.ScrolledWindow()
+    scroll.set_vexpand(True)
+    scroll.add(view)
+    box.pack_start(scroll, True, True, 0)
+    view.expand_all()
+
+    def select(model, path, row, _data):
+        if model[row][3] and strip_ref_name(model[row][3]) == selected:
+            view.get_selection().select_path(path)
+            view.scroll_to_cell(path, None, True, 0.5, 0)
+            return True
+        return False
+
+    filtered.foreach(select, None)
+
+    dialog.add_button(_("_Cancel"), Gtk.ResponseType.CANCEL)
+    dialog.add_button(_("_OK"), Gtk.ResponseType.OK)
+    dialog.set_default_response(Gtk.ResponseType.OK)
+    view.connect(
+        "row-activated",
+        lambda _v, path, _c: filtered[path][3] and dialog.response(Gtk.ResponseType.OK),
+    )
+    dialog.show_all()
+
+    result = None
+    while True:
+        response = dialog.run()
+        if response != Gtk.ResponseType.OK:
+            break
+        model, row = view.get_selection().get_selected()
+        if row and model[row][3]:
+            result = strip_ref_name(model[row][3])
+            break
+    dialog.destroy()
+    return result
+
+
+class RefSelector:
+    """
+    The ref label at the top left of the log window plus the "All Branches"
+    check box at the bottom left. ``on_change`` is called after any change.
+
+    """
+
+    def __init__(self, path, parent_window, on_change):
+        from gi.repository import Gtk
+
+        self.Gtk = Gtk
+        self.cwd = repo_dir(path)
+        self.parent_window = parent_window
+        self.on_change = on_change
+        self.mode = MODE_REF
+        self.ref = "HEAD"
+
+        self.button = Gtk.Button()
+        self.button.set_relief(Gtk.ReliefStyle.NONE)
+        self.button.set_tooltip_text(
+            _("Click to browse references. Right-click for more choices.")
+        )
+        self.button.connect("clicked", lambda *_a: self.browse())
+        self.button.connect("button-press-event", self.on_button_press)
+
+        self.all_branches = Gtk.CheckButton(label=_("_All Branches"), use_underline=True)
+        self.all_branches.connect("toggled", self.on_all_toggled)
+        self.updating = False
+        self.update_widgets()
+
+    def log_arguments(self, git):
+        """Keyword arguments for rabbitvcs.vcs.git.Git.log()."""
+        if self.mode == MODE_REF:
+            return {"revision": git.revision(self.ref), "showtype": "branch"}
+        if self.mode == MODE_ALL:
+            return {"showtype": "all"}
+        return {"showtype": self.mode}
+
+    def label(self):
+        if self.mode != MODE_REF:
+            return MODE_LABELS[self.mode]
+        if self.ref == "HEAD":
+            return current_branch(self.cwd) or _("No branch")
+        return self.ref
+
+    def update_widgets(self):
+        self.updating = True
+        self.button.set_label(self.label())
+        self.all_branches.set_inconsistent(self.mode in (MODE_BASIC, MODE_LOCAL))
+        self.all_branches.set_active(self.mode == MODE_ALL)
+        self.updating = False
+
+    def set_mode(self, mode, ref="HEAD"):
+        self.mode = mode
+        self.ref = ref
+        self.update_widgets()
+        self.on_change()
+
+    def on_all_toggled(self, check):
+        if self.updating:
+            return
+        if self.mode == MODE_REF:
+            self.set_mode(MODE_ALL)
+        else:
+            self.set_mode(MODE_REF, "HEAD")
+
+    def browse(self):
+        ref = pick_ref(self.parent_window, self.cwd, self.ref)
+        if ref:
+            add_history(ref)
+            self.set_mode(MODE_REF, ref)
+
+    def on_button_press(self, _widget, event):
+        if event.button != 3:
+            return False
+        Gtk = self.Gtk
+        menu = Gtk.Menu()
+
+        def item(label, callback, sensitive=True):
+            entry = Gtk.MenuItem(label=label)
+            entry.set_sensitive(sensitive)
+            entry.connect("activate", lambda *_a: callback())
+            menu.append(entry)
+
+        item(_("Browse references"), self.browse)
+        branch = current_branch(self.cwd)
+        head = f'HEAD -> "{branch}"' if branch else "HEAD"
+        item(head, lambda: self.set_mode(MODE_REF, "HEAD"))
+        has_fetch_head = bool(git_output(self.cwd, "rev-parse", "-q", "--verify", "FETCH_HEAD"))
+        item("FETCH_HEAD", lambda: self.set_mode(MODE_REF, "FETCH_HEAD"), has_fetch_head)
+        item(_("All"), lambda: self.set_mode(MODE_ALL))
+        item(_("All basic refs"), lambda: self.set_mode(MODE_BASIC))
+        item(_("All local branches"), lambda: self.set_mode(MODE_LOCAL))
+        history = load_history()
+        if history:
+            menu.append(Gtk.SeparatorMenuItem())
+            for ref in history:
+                item(ref, lambda r=ref: (add_history(r), self.set_mode(MODE_REF, r)))
+        menu.show_all()
+        menu.popup_at_pointer(event)
+        return True
diff --git a/rabbitvcs/util/contextmenuitems.py b/rabbitvcs/util/contextmenuitems.py
index b90b66e..0d8687e 100644
--- a/rabbitvcs/util/contextmenuitems.py
+++ b/rabbitvcs/util/contextmenuitems.py
@@ -786,6 +786,18 @@ class MenuReset(MenuItem):
     icon = "rabbitvcs-reset"
 
 
+class MenuCherryPick(MenuItem):
+    identifier = "RabbitVCS::Cherry_Pick"
+    label = _("Cherry Pick this commit...")
+    icon = "rabbitvcs-merge"
+
+
+class MenuCherryPickSelected(MenuItem):
+    identifier = "RabbitVCS::Cherry_Pick_Selected"
+    label = _("Cherry Pick selected commits...")
+    icon = "rabbitvcs-merge"
+
+
 class MenuStage(MenuItem):
     identifier = "RabbitVCS::Stage"
     label = _("Stage")
diff --git a/rabbitvcs/vcs/git/gittyup/client.py b/rabbitvcs/vcs/git/gittyup/client.py
index eaf8ee6..20fe7fb 100644
--- a/rabbitvcs/vcs/git/gittyup/client.py
+++ b/rabbitvcs/vcs/git/gittyup/client.py
@@ -1852,6 +1852,11 @@ class GittyupClient(object):
 
         if showtype == "all":
             cmd.append("--all")
+        # rabbitvcs-cherry-pick: ref selector modes of the log window
+        elif showtype == "local":
+            cmd.append("--branches")
+        elif showtype == "basic":
+            cmd += ["--branches", "--tags", "--remotes"]
 
         if limit:
             cmd.append("-%s" % limit)
PATCH

python3 -m py_compile "${FILES[@]}" "${NEW_FILES[@]}"
echo "$PATCH_ID" > "$STAMP"
pkill -f "rabbitvcs/services/[c]heckerservice" 2>/dev/null || true
nautilus -q 2>/dev/null || true
echo "Done. Open Show Log, click the branch name at the top left to pick a branch, right-click a commit, choose 'Cherry Pick this commit...'."
