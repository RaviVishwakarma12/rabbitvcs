#!/usr/bin/env bash
# Adds TortoiseGit-style cherry-pick to RabbitVCS (Git) Show Log:
#   - "Branch" dropdown: list commits from a branch not yet in the current branch
#   - "Cherry-pick this commit" in the right-click menu, with abort on conflict
# Usage:  sudo bash rabbitvcs-cherry-pick.sh           (install / upgrade)
#         sudo bash rabbitvcs-cherry-pick.sh --remove  (restore original)
set -euo pipefail

TARGET_DIR="/usr/lib/python3/dist-packages"
FILES=(rabbitvcs/ui/log.py rabbitvcs/util/contextmenuitems.py rabbitvcs/vcs/git/gittyup/client.py)
BACKUP_SUFFIX=".orig-cherrypick"
MARKER="initialize_branch_filter"

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
cd "$TARGET_DIR"

if [[ "${1:-}" == "--remove" ]]; then
  for f in "${FILES[@]}"; do
    [[ -f "$f$BACKUP_SUFFIX" ]] && mv "$f$BACKUP_SUFFIX" "$f"
  done
  echo "Original RabbitVCS files restored."
  exit 0
fi

if grep -q "$MARKER" rabbitvcs/ui/log.py; then
  echo "Cherry-pick patch is already installed and up to date."
  exit 0
fi

# Start from the original files (upgrades an older version of this patch)
for f in "${FILES[@]}"; do
  if [[ -f "$f$BACKUP_SUFFIX" ]]; then
    cp -p "$f$BACKUP_SUFFIX" "$f"
  else
    cp -p "$f" "$f$BACKUP_SUFFIX"
  fi
done

patch -p1 --forward <<'PATCH'
diff --git a/rabbitvcs/ui/log.py b/rabbitvcs/ui/log.py
index 4e085f5..19119a8 100755
--- a/rabbitvcs/ui/log.py
+++ b/rabbitvcs/ui/log.py
@@ -36,6 +36,7 @@ from rabbitvcs.ui import InterfaceView
 from gi.repository import Gtk, GObject, Gdk
 import six
 import threading
+import subprocess
 from locale import strxfrm
 
 import os.path
@@ -724,9 +725,50 @@ class GitLog(Log):
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
@@ -865,8 +907,19 @@ class GitLog(Log):
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
@@ -1181,6 +1234,9 @@ class LogTopContextMenuConditions(object):
     def reset(self, data=None):
         return self.vcs_name == rabbitvcs.vcs.VCS_GIT
 
+    def cherry_pick(self, data=None):
+        return self.vcs_name == rabbitvcs.vcs.VCS_GIT
+
 
 class LogTopContextMenuCallbacks(object):
     def __init__(self, caller, vcs, path, revisions):
@@ -1424,6 +1480,49 @@ class LogTopContextMenuCallbacks(object):
             ],
         )
 
+    def cherry_pick(self, widget, data=None):
+        from rabbitvcs.ui.dialog import Confirmation
+
+        cwd = self.path if os.path.isdir(self.path) else os.path.dirname(self.path)
+
+        def git(*args):
+            proc = subprocess.run(
+                ["git"] + list(args), cwd=cwd, capture_output=True, text=True
+            )
+            return proc.returncode, (proc.stdout + proc.stderr).strip()
+
+        # Log lists newest first; cherry-pick oldest first to keep order.
+        commits = [S(r["revision"]) for r in reversed(self.revisions)]
+        _code, branch = git("rev-parse", "--abbrev-ref", "HEAD")
+        summary = "\n".join(
+            "%s  %s" % (c[:8], S(r["message"]).split("\n")[0][:60])
+            for c, r in zip(commits, reversed(self.revisions))
+        )
+
+        prompt = _("Cherry-pick %d commit(s) onto '%s'?\n\n%s") % (
+            len(commits),
+            branch,
+            summary,
+        )
+        if Confirmation(prompt).run() != Gtk.ResponseType.OK:
+            return
+
+        code, output = git("cherry-pick", *commits)
+        if code == 0:
+            MessageBox(_("Cherry-pick completed.\n\n%s") % output)
+            self.caller.load()
+            return
+
+        abort_prompt = _(
+            "Cherry-pick stopped (conflict or error):\n\n%s\n\n"
+            "Click OK to abort and restore the branch, or Cancel to keep the "
+            "conflict and resolve it yourself (then commit, or run "
+            "'git cherry-pick --continue')."
+        ) % output
+        if Confirmation(abort_prompt).run() == Gtk.ResponseType.OK:
+            git("cherry-pick", "--abort")
+        self.caller.load()
+
     def edit_author(self, widget, data=None):
         author = ""
         if len(self.revisions) == 1:
@@ -1527,6 +1626,7 @@ class LogTopContextMenu(object):
             (MenuExport, None),
             (MenuMerge, None),
             (MenuReset, None),
+            (MenuCherryPick, None),
             (MenuSeparatorLast, None),
             (MenuEditAuthor, None),
             (MenuEditLogMessage, None),
diff --git a/rabbitvcs/util/contextmenuitems.py b/rabbitvcs/util/contextmenuitems.py
index b90b66e..8da52ac 100644
--- a/rabbitvcs/util/contextmenuitems.py
+++ b/rabbitvcs/util/contextmenuitems.py
@@ -786,6 +786,12 @@ class MenuReset(MenuItem):
     icon = "rabbitvcs-reset"
 
 
+class MenuCherryPick(MenuItem):
+    identifier = "RabbitVCS::Cherry_Pick"
+    label = _("Cherry-pick this commit")
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

python3 -m py_compile "${FILES[@]}"
pkill -f "rabbitvcs/services/[c]heckerservice" 2>/dev/null || true
nautilus -q 2>/dev/null || true
echo "Done. Open Show Log, choose a branch in the 'Branch' dropdown, right-click a commit, choose 'Cherry-pick this commit'."
