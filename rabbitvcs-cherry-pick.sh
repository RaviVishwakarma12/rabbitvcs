#!/usr/bin/env bash
# Adds TortoiseGit-style cherry-pick to RabbitVCS (Git) Show Log:
#   - "Branch" dropdown: commits from a branch that are not yet in the current branch
#   - "Cherry Pick this commit..." / "Cherry Pick selected commits..." menu items
#   - Cherry Pick dialog: pick/skip, reorder, "cherry picked from" (-x), auto-stash,
#     merge-commit parent choice, empty-commit handling, conflict Continue/Skip/Abort
# Usage:  sudo bash rabbitvcs-cherry-pick.sh           (install / upgrade)
#         sudo bash rabbitvcs-cherry-pick.sh --remove  (restore original)
set -euo pipefail

TARGET_DIR="/usr/lib/python3/dist-packages"
FILES=(rabbitvcs/ui/log.py rabbitvcs/util/contextmenuitems.py rabbitvcs/vcs/git/gittyup/client.py)
NEW_FILES=(rabbitvcs/ui/cherrypick.py)
BACKUP_SUFFIX=".orig-cherrypick"
PATCH_ID="290d5c13b702"
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
index 0000000..e4c66c1
--- /dev/null
+++ b/rabbitvcs/ui/cherrypick.py
@@ -0,0 +1,757 @@
+#
+# This is an extension to the Nautilus file manager to allow better
+# integration with the Subversion source control system.
+#
+# Copyright (C) 2006-2008 by Jason Field <jason@jasonfield.com>
+# Copyright (C) 2007-2008 by Bruce van der Kooij <brucevdkooij@gmail.com>
+# Copyright (C) 2008-2010 by Adam Plumb <adamplumb@gmail.com>
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
+Git cherry-pick, modelled on TortoiseGit's Cherry Pick dialog:
+
+- choose which selected commits to pick, and their order
+- optional "cherry picked from" line (-x), remembered between runs
+- uncommitted changes are stashed first and restored afterwards
+- merge commits ask which parent to use (-m)
+- commits that end up empty can be committed anyway or skipped
+- conflicts can be resolved, then Continue, Skip this commit or Abort
+- Abort undoes every commit picked in this run
+
+"""
+
+import json
+import os
+import shutil
+import subprocess
+import tempfile
+
+from rabbitvcs import gettext
+
+_ = gettext.gettext
+
+PICKED = "picked"
+SKIPPED = "skipped"
+ABORT = "abort"
+SKIP = "skip"
+RETRY = "retry"
+COMMIT = "commit"
+CONTINUE = "continue"
+
+CONFLICT_MARKERS = ("<<<<<<< ", ">>>>>>> ")
+SETTINGS_FILE = "cherrypick.json"
+
+
+class CherryPickResult:
+    def __init__(self):
+        self.status = "done"
+        self.picked = []
+        self.skipped = []
+        self.notes = []
+
+
+class CherryPicker:
+    """
+    Runs the cherry-pick one commit at a time. Every decision is delegated
+    to ``ui``, so the logic can be driven by dialogs or by tests.
+
+    """
+
+    def __init__(self, path, ui):
+        self.ui = ui
+        self.cwd = path if os.path.isdir(path) else os.path.dirname(path)
+        self.root = self.output("rev-parse", "--show-toplevel") or self.cwd
+
+    def git(self, *args):
+        proc = subprocess.run(
+            ["git"] + list(args),
+            cwd=self.cwd,
+            capture_output=True,
+            text=True,
+            check=False,
+        )
+        return proc.returncode, (proc.stdout + proc.stderr).strip()
+
+    def output(self, *args):
+        code, out = self.git(*args)
+        return out if code == 0 else ""
+
+    def current_branch(self):
+        return self.output("rev-parse", "--abbrev-ref", "HEAD")
+
+    def subject(self, commit):
+        return self.output("log", "-1", "--format=%s", commit)
+
+    def parents(self, commit):
+        return self.output("rev-list", "--parents", "-n", "1", commit).split()[1:]
+
+    def is_clean(self):
+        code, out = self.git("status", "--porcelain", "--untracked-files=no")
+        return code == 0 and out == ""
+
+    def is_empty_commit(self, commit):
+        parents = self.parents(commit)
+        if len(parents) != 1:
+            return False
+        return self.output("rev-parse", commit + "^{tree}") == self.output(
+            "rev-parse", parents[0] + "^{tree}"
+        )
+
+    def pick_in_progress(self):
+        return self.git("rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD")[0] == 0
+
+    def conflicted_files(self):
+        out = self.output("diff", "--name-only", "--diff-filter=U")
+        return [line for line in out.splitlines() if line]
+
+    def stages(self, name):
+        out = self.output("ls-files", "-u", "--", os.path.join(self.root, name))
+        return {int(line.split()[2]) for line in out.splitlines() if line}
+
+    def deleted_on_one_side(self, files):
+        return [name for name in files if not {2, 3} <= self.stages(name)]
+
+    def resolve_using(self, name, theirs):
+        """Take one side of a conflict, including when that side deleted it."""
+        stage = 3 if theirs else 2
+        path = os.path.join(self.root, name)
+        if stage in self.stages(name):
+            code, out = self.git("checkout", "--theirs" if theirs else "--ours", "--", path)
+            if code == 0:
+                code, out = self.git("add", "--", path)
+        else:
+            code, out = self.git("rm", "-q", "--", path)
+        return code, out
+
+    def files_with_markers(self, files):
+        found = []
+        for name in files:
+            path = os.path.join(self.root, name)
+            if not os.path.isfile(path):
+                continue
+            with open(path, errors="ignore") as handle:
+                if any(line.startswith(CONFLICT_MARKERS) for line in handle):
+                    found.append(name)
+        return found
+
+    def conflict_versions(self, name):
+        """
+        Writes the base, mine and theirs versions of a conflicted file to a
+        temporary folder, like TortoiseGit does before opening its merge tool.
+
+        @return: dict with "base", "mine", "theirs" (None when that side
+                 deleted the file) and "merged" (the working tree file)
+
+        """
+        folder = tempfile.mkdtemp(prefix="rabbitvcs-cherry-pick-")
+        stem, ext = os.path.splitext(os.path.basename(name))
+        versions = {"merged": os.path.join(self.root, name)}
+        for stage, side in ((1, "base"), (2, "mine"), (3, "theirs")):
+            proc = subprocess.run(
+                ["git", "show", f":{stage}:{name}"],
+                cwd=self.root,
+                capture_output=True,
+                check=False,
+            )
+            if proc.returncode:
+                versions[side] = None
+                continue
+            path = os.path.join(folder, f"{stem}.{side.upper()}{ext}")
+            with open(path, "wb") as handle:
+                handle.write(proc.stdout)
+            versions[side] = path
+        return versions
+
+    def merge_message(self):
+        path = self.output("rev-parse", "--git-path", "MERGE_MSG")
+        if path and not os.path.isabs(path):
+            path = os.path.join(self.cwd, path)
+        if path and os.path.isfile(path):
+            with open(path, errors="ignore") as handle:
+                return handle.read()
+        return ""
+
+    def commit(self, message=None, allow_empty=False):
+        args = ["commit"]
+        if allow_empty:
+            args.append("--allow-empty")
+        if message is None:
+            return self.git(*(args + ["--no-edit"]))
+
+        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
+            handle.write(message)
+        try:
+            return self.git(*(args + ["--cleanup=strip", "-F", handle.name]))
+        finally:
+            os.unlink(handle.name)
+
+    def run(self, commits, add_cherry_picked_from=False):
+        """
+        @param commits: commit hashes, in the order they should be applied
+
+        """
+        result = CherryPickResult()
+        if not commits:
+            result.status = "nothing"
+            return result
+
+        stashed = False
+        if not self.is_clean():
+            if not self.ui.ask_stash():
+                result.status = "cancelled"
+                return result
+            code, out = self.git("stash")
+            if code:
+                self.ui.error(out)
+                result.status = "cancelled"
+                return result
+            stashed = True
+
+        original_head = self.output("rev-parse", "HEAD")
+        for commit in commits:
+            outcome = self.pick(commit, add_cherry_picked_from)
+            if outcome == PICKED:
+                result.picked.append(commit)
+            elif outcome == SKIPPED:
+                result.skipped.append(commit)
+            else:
+                self.abort(original_head)
+                result.status = "aborted"
+                result.picked = []
+                break
+
+        if stashed:
+            self.restore_stash(result)
+        return result
+
+    def pick(self, commit, add_cherry_picked_from):
+        args = ["cherry-pick"]
+        if add_cherry_picked_from:
+            args.append("-x")
+
+        parents = self.parents(commit)
+        if len(parents) > 1:
+            parent = self.ui.ask_parent(
+                commit,
+                self.subject(commit),
+                [self.subject(p) for p in parents],
+            )
+            if not parent:
+                return ABORT
+            args += ["-m", str(parent)]
+        elif self.is_empty_commit(commit):
+            args.append("--allow-empty")
+        args.append(commit)
+
+        while True:
+            code, out = self.git(*args)
+            if code == 0:
+                return PICKED
+            if self.conflicted_files():
+                return self.resolve_conflict(commit)
+            if self.pick_in_progress():
+                return self.handle_empty(commit)
+
+            choice = self.ui.ask_failed(commit, self.subject(commit), out)
+            if choice == RETRY:
+                continue
+            if choice == SKIP:
+                self.git("reset", "--hard")
+                return SKIPPED
+            return ABORT
+
+    def handle_empty(self, commit, message=None):
+        choice = self.ui.ask_empty(commit, self.subject(commit))
+        if choice == COMMIT:
+            code, out = self.commit(message, allow_empty=True)
+            if code:
+                self.ui.error(out)
+                return ABORT
+            return PICKED
+        if choice == SKIP:
+            self.git("reset", "--hard")
+            return SKIPPED
+        return ABORT
+
+    def resolve_conflict(self, commit):
+        while True:
+            choice, message = self.ui.ask_conflict(
+                commit,
+                self.subject(commit),
+                self.conflicted_files(),
+                self.merge_message(),
+                self,
+            )
+            if choice == ABORT:
+                return ABORT
+            if choice == SKIP:
+                self.git("reset", "--hard")
+                return SKIPPED
+
+            deleted = self.deleted_on_one_side(self.conflicted_files())
+            if deleted:
+                self.ui.error(
+                    _(
+                        "These files were deleted on one side. Choose Resolve "
+                        "using Theirs or Resolve using Mine for them:\n\n%s"
+                    )
+                    % "\n".join(deleted)
+                )
+                continue
+
+            unresolved = self.files_with_markers(self.conflicted_files())
+            if unresolved:
+                self.ui.error(
+                    _("These files still contain conflict markers:\n\n%s")
+                    % "\n".join(unresolved)
+                )
+                continue
+
+            remaining = self.conflicted_files()
+            if remaining:
+                self.git("add", "--", *remaining)
+
+            if self.git("diff", "--cached", "--quiet")[0] == 0:
+                return self.handle_empty(commit, message)
+
+            code, out = self.commit(message)
+            if code:
+                self.ui.error(out)
+                continue
+            return PICKED
+
+    def abort(self, original_head):
+        if self.pick_in_progress():
+            self.git("cherry-pick", "--abort")
+        if original_head:
+            self.git("reset", "--hard", original_head)
+
+    def restore_stash(self, result):
+        if not self.ui.ask_stash_pop():
+            result.notes.append(
+                _("Your uncommitted changes are saved in the stash. Run 'git stash pop' to restore them.")
+            )
+            return
+        code, out = self.git("stash", "pop")
+        if code:
+            result.notes.append(
+                _("Restoring your uncommitted changes failed:\n%s\n\nThey are still saved in the stash.")
+                % out
+            )
+
+
+def load_add_cherry_picked_from():
+    try:
+        from rabbitvcs.util.settings import get_home_folder
+
+        with open(os.path.join(get_home_folder(), SETTINGS_FILE)) as handle:
+            return bool(json.load(handle).get("add_cherry_picked_from", False))
+    except (OSError, ValueError, ImportError):
+        return False
+
+
+def save_add_cherry_picked_from(value):
+    try:
+        from rabbitvcs.util.settings import get_home_folder
+
+        with open(os.path.join(get_home_folder(), SETTINGS_FILE), "w") as handle:
+            json.dump({"add_cherry_picked_from": bool(value)}, handle)
+    except (OSError, ImportError):
+        pass
+
+
+def short(commit):
+    return commit[:8]
+
+
+def trim(text, size=60):
+    return text if len(text) <= size else text[: size - 1] + "…"
+
+
+class GtkCherryPickUI:
+    """Dialogs for CherryPicker, worded after TortoiseGit."""
+
+    EDIT, THEIRS, MINE = 1, 2, 3
+
+    def __init__(self, parent=None):
+        from gi.repository import Gtk
+
+        self.Gtk = Gtk
+        self.parent = parent
+
+    def message(self, title, text, buttons, kind=None):
+        Gtk = self.Gtk
+        dialog = Gtk.MessageDialog(
+            transient_for=self.parent,
+            modal=True,
+            message_type=kind or Gtk.MessageType.QUESTION,
+            buttons=Gtk.ButtonsType.NONE,
+            text=title,
+        )
+        dialog.set_title(_("Cherry Pick"))
+        if text:
+            dialog.format_secondary_text(text)
+        for label, response in buttons:
+            dialog.add_button(label, response)
+        dialog.set_default_response(buttons[0][1])
+        response = dialog.run()
+        dialog.destroy()
+        return response
+
+    def error(self, text):
+        self.message(
+            _("Cherry Pick"), text, [(_("_OK"), 0)], self.Gtk.MessageType.ERROR
+        )
+
+    def ask_stash(self):
+        return (
+            self.message(
+                _("The current working tree is not clean."),
+                _("Do you want to stash the changes?"),
+                [(_("_Stash"), 1), (_("_Abort"), 0)],
+            )
+            == 1
+        )
+
+    def ask_stash_pop(self):
+        return (
+            self.message(
+                _("Do you want to stash pop now?"),
+                _("Your uncommitted changes were stashed before cherry-picking."),
+                [(_("_Yes"), 1), (_("_No"), 0)],
+            )
+            == 1
+        )
+
+    def ask_parent(self, commit, subject, parent_subjects):
+        buttons = [
+            (_("Parent %d: %s") % (i + 1, trim(s, 40)), i + 1)
+            for i, s in enumerate(parent_subjects)
+        ]
+        response = self.message(
+            f'"{short(commit)}" - "{trim(subject)}"',
+            _("is a merge commit.\n\nWhich parent do you want to pick?"),
+            buttons + [(_("_Cancel"), 0)],
+        )
+        return response if response > 0 else None
+
+    def ask_empty(self, commit, subject):
+        response = self.message(
+            f"{short(commit)}  {trim(subject)}",
+            _(
+                "The current commit will be empty (its changes are already in "
+                "this branch, or were dropped while resolving conflicts). Skip "
+                "the commit or keep the message only commit?"
+            ),
+            [(_("C_ommit"), 1), (_("_Skip"), 2), (_("_Cancel"), 0)],
+        )
+        return {1: COMMIT, 2: SKIP}.get(response, ABORT)
+
+    def ask_failed(self, commit, subject, output):
+        response = self.message(
+            _("Cherry-pick failed! Skip this commit?"),
+            f"{short(commit)}  {trim(subject)}\n\n{output}",
+            [(_("_Skip"), 1), (_("_Retry"), 2), (_("_Cancel"), 0)],
+            self.Gtk.MessageType.WARNING,
+        )
+        return {1: SKIP, 2: RETRY}.get(response, ABORT)
+
+    def ask_conflict(self, commit, subject, files, message, picker):
+        Gtk = self.Gtk
+        dialog = Gtk.Dialog(
+            title=_("Cherry Pick - Conflict"), transient_for=self.parent, modal=True
+        )
+        dialog.set_default_size(720, 560)
+        box = dialog.get_content_area()
+        box.set_spacing(6)
+        box.set_border_width(10)
+
+        heading = Gtk.Label(xalign=0)
+        title = _("Conflict while cherry-picking %s  %s") % (
+            short(commit),
+            GLibEscape(trim(subject, 70)),
+        )
+        heading.set_markup(f"<b>{title}</b>")
+        box.pack_start(heading, False, False, 0)
+        box.pack_start(
+            Gtk.Label(
+                label=_(
+                    "Resolve the conflicted files, then click Continue.\n"
+                    "Theirs = changes from the picked commit, Mine = your branch."
+                ),
+                xalign=0,
+            ),
+            False,
+            False,
+            0,
+        )
+
+        store = Gtk.ListStore(str)
+        view = Gtk.TreeView(model=store)
+        view.append_column(
+            Gtk.TreeViewColumn(_("Conflicted files"), Gtk.CellRendererText(), text=0)
+        )
+        scroll = Gtk.ScrolledWindow()
+        scroll.set_min_content_height(140)
+        scroll.add(view)
+        box.pack_start(scroll, True, True, 0)
+
+        tools = Gtk.Box(spacing=6)
+        for label, response in (
+            (_("Edit Conflicts"), self.EDIT),
+            (_("Resolve using Theirs"), self.THEIRS),
+            (_("Resolve using Mine"), self.MINE),
+        ):
+            button = Gtk.Button(label=label)
+            button.connect("clicked", lambda _b, r=response: dialog.response(r))
+            tools.pack_start(button, False, False, 0)
+        box.pack_start(tools, False, False, 0)
+        view.connect(
+            "row-activated", lambda *_a: dialog.response(self.EDIT)
+        )
+
+        box.pack_start(Gtk.Label(label=_("Commit message:"), xalign=0), False, False, 0)
+        text = Gtk.TextView()
+        text.set_monospace(True)
+        text.get_buffer().set_text(message)
+        text_scroll = Gtk.ScrolledWindow()
+        text_scroll.set_min_content_height(140)
+        text_scroll.add(text)
+        box.pack_start(text_scroll, True, True, 0)
+
+        dialog.add_button(_("_Abort"), 10)
+        dialog.add_button(_("S_kip this commit"), 11)
+        dialog.add_button(_("_Continue"), 12)
+        dialog.show_all()
+
+        def refresh():
+            store.clear()
+            for name in picker.conflicted_files():
+                store.append([name])
+            if len(store):
+                view.get_selection().select_path(Gtk.TreePath(0))
+
+        def selected():
+            model, row = view.get_selection().get_selected()
+            return model[row][0] if row else None
+
+        refresh()
+        while True:
+            response = dialog.run()
+            name = selected()
+            if response == self.EDIT and name:
+                self.edit_conflicts(picker, name)
+            elif response in (self.THEIRS, self.MINE) and name:
+                code, out = picker.resolve_using(name, response == self.THEIRS)
+                if code:
+                    self.error(out)
+                refresh()
+            elif response in (10, 11, 12):
+                buffer = text.get_buffer()
+                msg = buffer.get_text(
+                    buffer.get_start_iter(), buffer.get_end_iter(), False
+                )
+                dialog.destroy()
+                return {10: ABORT, 11: SKIP, 12: CONTINUE}[response], msg
+            elif response in (
+                Gtk.ResponseType.DELETE_EVENT,
+                Gtk.ResponseType.NONE,
+            ):
+                if self.message(
+                    _("Abort the cherry-pick?"),
+                    _("All commits picked in this run will be undone."),
+                    [(_("_Abort"), 1), (_("_Keep resolving"), 0)],
+                ) == 1:
+                    dialog.destroy()
+                    return ABORT, ""
+
+    def edit_conflicts(self, picker, name):
+        """
+        Opens a 3-way merge: the merge tool set in RabbitVCS settings, else
+        Meld, else the default editor on the file with conflict markers.
+
+        """
+        versions = picker.conflict_versions(name)
+        if not versions["mine"] or not versions["theirs"]:
+            self.error(
+                _(
+                    "'%s' was deleted on one side. Use Resolve using Theirs "
+                    "or Resolve using Mine."
+                )
+                % name
+            )
+            return
+
+        from rabbitvcs.util import helper
+
+        if helper.get_merge_tool():
+            helper.launch_merge_tool(
+                versions["base"] or "",
+                versions["mine"],
+                versions["theirs"],
+                versions["merged"],
+            )
+        elif shutil.which("meld"):
+            subprocess.Popen(  # pylint: disable=consider-using-with
+                ["meld", versions["mine"], versions["merged"], versions["theirs"]]
+            )
+        else:
+            subprocess.Popen(  # pylint: disable=consider-using-with
+                ["xdg-open", versions["merged"]]
+            )
+            self.message(
+                _("No merge tool found"),
+                _(
+                    "The file was opened in your default editor. Fix the "
+                    "conflict markers, save, then click Continue.\n\n"
+                    "For a 3-way merge view: sudo apt install meld"
+                ),
+                [(_("_OK"), 0)],
+                self.Gtk.MessageType.INFO,
+            )
+
+    def select_commits(self, commits, branch, add_cherry_picked_from):
+        """
+        @param commits: list of (hash, subject, author) oldest first
+        @return: (hashes to pick in order, add_cherry_picked_from) or None
+
+        """
+        Gtk = self.Gtk
+        dialog = Gtk.Dialog(
+            title=_("Cherry Pick"), transient_for=self.parent, modal=True
+        )
+        dialog.set_default_size(760, 420)
+        box = dialog.get_content_area()
+        box.set_spacing(6)
+        box.set_border_width(10)
+
+        heading = Gtk.Label(xalign=0)
+        heading.set_markup(
+            _("Cherry-pick onto branch: <b>%s</b>") % GLibEscape(branch)
+        )
+        box.pack_start(heading, False, False, 0)
+
+        store = Gtk.ListStore(bool, str, str, str, str)
+        for commit, subject, author in commits:
+            store.append([True, short(commit), subject, author, commit])
+
+        view = Gtk.TreeView(model=store)
+        toggle = Gtk.CellRendererToggle()
+        toggle.connect(
+            "toggled", lambda _r, path: store.set_value(
+                store.get_iter(path), 0, not store[path][0]
+            )
+        )
+        view.append_column(Gtk.TreeViewColumn(_("Pick"), toggle, active=0))
+        for title, index in ((_("Commit"), 1), (_("Message"), 2), (_("Author"), 3)):
+            column = Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=index)
+            column.set_resizable(True)
+            column.set_expand(index == 2)
+            view.append_column(column)
+
+        scroll = Gtk.ScrolledWindow()
+        scroll.set_vexpand(True)
+        scroll.add(view)
+        box.pack_start(scroll, True, True, 0)
+
+        def move(offset):
+            model, row = view.get_selection().get_selected()
+            if not row:
+                return
+            index = model.get_path(row)[0] + offset
+            if 0 <= index < len(model):
+                other = model.get_iter(Gtk.TreePath(index))
+                if offset < 0:
+                    model.move_before(row, other)
+                else:
+                    model.move_after(row, other)
+
+        tools = Gtk.Box(spacing=6)
+        for label, offset in ((_("Move Up"), -1), (_("Move Down"), 1)):
+            button = Gtk.Button(label=label)
+            button.connect("clicked", lambda _b, o=offset: move(o))
+            tools.pack_start(button, False, False, 0)
+        tools.pack_start(
+            Gtk.Label(label=_("Commits are applied from top to bottom.")),
+            False,
+            False,
+            6,
+        )
+        box.pack_start(tools, False, False, 0)
+
+        check = Gtk.CheckButton(label=_('Add "cherry picked from"'))
+        check.set_active(add_cherry_picked_from)
+        box.pack_start(check, False, False, 0)
+
+        dialog.add_button(_("_Cancel"), Gtk.ResponseType.CANCEL)
+        start = dialog.add_button(_("_Start Cherry Pick"), Gtk.ResponseType.OK)
+        start.get_style_context().add_class("suggested-action")
+        dialog.set_default_response(Gtk.ResponseType.OK)
+        dialog.show_all()
+
+        response = dialog.run()
+        chosen = [row[4] for row in store if row[0]]
+        add_from = check.get_active()
+        dialog.destroy()
+        if response != Gtk.ResponseType.OK:
+            return None
+        return chosen, add_from
+
+
+def GLibEscape(text):
+    from gi.repository import GLib
+
+    return GLib.markup_escape_text(text)
+
+
+def cherry_pick(path, commits, parent=None):
+    """
+    Entry point used by the log window.
+
+    @param commits: list of (hash, subject, author), oldest first
+    @return: True when the branch changed
+
+    """
+    ui = GtkCherryPickUI(parent)
+    picker = CherryPicker(path, ui)
+    branch = picker.current_branch()
+
+    selection = ui.select_commits(commits, branch, load_add_cherry_picked_from())
+    if selection is None:
+        return False
+    chosen, add_from = selection
+    save_add_cherry_picked_from(add_from)
+    if not chosen:
+        return False
+
+    result = picker.run(chosen, add_from)
+    if result.status == "cancelled":
+        return False
+
+    if result.status == "aborted":
+        summary = _("Cherry-pick aborted. '%s' was restored to its original state.") % branch
+    else:
+        summary = _("Cherry-pick finished on '%s': %d picked, %d skipped.") % (
+            branch,
+            len(result.picked),
+            len(result.skipped),
+        )
+    ui.message(
+        summary,
+        "\n\n".join(result.notes),
+        [(_("_OK"), 0)],
+        ui.Gtk.MessageType.INFO,
+    )
+    return True
diff --git a/rabbitvcs/ui/log.py b/rabbitvcs/ui/log.py
index 4e085f5..b426de7 100755
--- a/rabbitvcs/ui/log.py
+++ b/rabbitvcs/ui/log.py
@@ -724,9 +724,50 @@ class GitLog(Log):
             flags={"sortable": False},
         )
         self.start_point = 0
+        self.branch_filter = None
+        self.initialize_branch_filter()
         self.initialize_root_url()
         self.load_or_refresh()
 
+    def initialize_branch_filter(self):
+        """
+        Adds a "Branch" dropdown next to the search box. Choosing a branch
+        lists only its commits that are not in the current branch
+        (cherry-pick candidates), like TortoiseGit's log branch selector.
+
+        """
+        self.branch_filter_refs = [None]
+        combo = Gtk.ComboBoxText()
+        combo.append_text(_("All branches"))
+
+        current = ""
+        for branch in self.git.branch_list():
+            name = S(branch.name)
+            if branch.tracking:
+                current = name
+                continue
+            if name.endswith("/HEAD") or " -> " in name:
+                continue
+            self.branch_filter_refs.append(name)
+            label = name[len("remotes/") :] if name.startswith("remotes/") else name
+            combo.append_text(label)
+
+        combo.set_active(0)
+        combo.set_tooltip_text(
+            _("Show commits from this branch that are not in '%s'") % current
+        )
+        combo.connect("changed", self.on_branch_filter_changed)
+
+        grid = self.get_widget("hbox-search")
+        grid.attach(Gtk.Label(label=_("Branch:")), 1, 0, 1, 1)
+        grid.attach(combo, 2, 0, 1, 1)
+        grid.show_all()
+
+    def on_branch_filter_changed(self, combo):
+        self.branch_filter = self.branch_filter_refs[combo.get_active()]
+        self.start_point = 0
+        self.load()
+
     #
     # Log-loading callback methods
     #
@@ -865,8 +906,19 @@ class GitLog(Log):
         # Load log.
         self.action = GitAction(self.git, notification=False, run_in_thread=True)
 
+        log_args = {}
+        if self.branch_filter:
+            log_args = {
+                "revision": self.git.revision(self.branch_filter),
+                "showtype": "cherry",
+            }
+
         self.action.append(
-            self.git.log, path=self.path, skip=self.start_point, limit=self.limit + 1
+            self.git.log,
+            path=self.path,
+            skip=self.start_point,
+            limit=self.limit + 1,
+            **log_args
         )
         self.action.append(self.refresh)
         self.action.schedule()
@@ -1181,6 +1233,12 @@ class LogTopContextMenuConditions(object):
     def reset(self, data=None):
         return self.vcs_name == rabbitvcs.vcs.VCS_GIT
 
+    def cherry_pick(self, data=None):
+        return self.vcs_name == rabbitvcs.vcs.VCS_GIT and len(self.revisions) == 1
+
+    def cherry_pick_selected(self, data=None):
+        return self.vcs_name == rabbitvcs.vcs.VCS_GIT and len(self.revisions) > 1
+
 
 class LogTopContextMenuCallbacks(object):
     def __init__(self, caller, vcs, path, revisions):
@@ -1424,6 +1482,24 @@ class LogTopContextMenuCallbacks(object):
             ],
         )
 
+    def cherry_pick(self, widget, data=None):
+        from rabbitvcs.ui.cherrypick import cherry_pick
+
+        # The log lists newest first; TortoiseGit picks oldest first.
+        commits = [
+            (
+                S(r["revision"]),
+                S(r["message"]).strip().split("\n")[0],
+                S(r["author"]),
+            )
+            for r in reversed(self.revisions)
+        ]
+        if cherry_pick(self.path, commits, self.caller.get_widget("Log")):
+            self.caller.load()
+
+    def cherry_pick_selected(self, widget, data=None):
+        self.cherry_pick(widget, data)
+
     def edit_author(self, widget, data=None):
         author = ""
         if len(self.revisions) == 1:
@@ -1527,6 +1603,8 @@ class LogTopContextMenu(object):
             (MenuExport, None),
             (MenuMerge, None),
             (MenuReset, None),
+            (MenuCherryPick, None),
+            (MenuCherryPickSelected, None),
             (MenuSeparatorLast, None),
             (MenuEditAuthor, None),
             (MenuEditLogMessage, None),
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
index eaf8ee6..87224dc 100644
--- a/rabbitvcs/vcs/git/gittyup/client.py
+++ b/rabbitvcs/vcs/git/gittyup/client.py
@@ -1857,7 +1857,10 @@ class GittyupClient(object):
             cmd.append("-%s" % limit)
         if skip:
             cmd.append("--skip=%s" % skip)
-        if revision:
+        if showtype == "cherry":
+            # Commits in <revision> not yet in HEAD, hiding already-picked ones
+            cmd += ["--cherry-pick", "--right-only", "HEAD...%s" % revision]
+        elif revision:
             if showtype == "push":
                 cmd.append("%s.." % revision)
             else:
PATCH

python3 -m py_compile "${FILES[@]}" "${NEW_FILES[@]}"
echo "$PATCH_ID" > "$STAMP"
pkill -f "rabbitvcs/services/[c]heckerservice" 2>/dev/null || true
nautilus -q 2>/dev/null || true
echo "Done. Open Show Log, choose a branch in the 'Branch' dropdown, right-click a commit, choose 'Cherry Pick this commit...'."
